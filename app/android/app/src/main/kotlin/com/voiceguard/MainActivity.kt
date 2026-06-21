package com.voiceguard

import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.role.RoleManager
import androidx.core.app.NotificationCompat
import android.content.ContentValues
import android.content.pm.PackageManager
import android.content.Intent
import android.database.Cursor
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.Ringtone
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.ContactsContract
import android.telecom.TelecomManager
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import com.voiceguard.adb.AdbConnectionManager
import com.voiceguard.adb.NsdDiscovery
import com.voiceguard.adb.ShellAudioSession

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.voiceguard/calls"
    private val REQUEST_DEFAULT_DIALER = 1001
    private val VOIP_NOTIFICATION_ID = 43 // cellular uses 42 in VoiceGuardInCallService

    // VoIP ringtone managed here; cellular ringtone is in VoiceGuardInCallService
    private var voipRingtone: Ringtone? = null

    // Proximity-sensor-based screen wake lock (dims screen when phone near ear)
    private var proximityWakeLock: PowerManager.WakeLock? = null

    private val handler = Handler(Looper.getMainLooper())

    // ── Call audio recording (VOICE_RECOGNITION source, no AEC) ──────────────
    // Used for cellular call verification to capture earpiece bleed of the
    // remote caller without the system's acoustic echo cancellation stripping it.
    private var callAudioRecord: AudioRecord? = null
    private var callAudioThread: Thread? = null
    @Volatile private var isRecordingCallAudio = false
    private var currentCallAudioPath: String? = null

    // ── Shell audio (ADB VOICE_DOWNLINK bridge) ────────────────────────────────
    private var shellAudioSession: ShellAudioSession? = null
    private var shellAudioEventSink: EventChannel.EventSink? = null

    // ── Activity lifecycle ─────────────────────────────────────────────────────

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        applyCallWindowFlags(intent)
    }

    /**
     * Called when the activity is re-used (singleTop) rather than re-created.
     * Happens when VoiceGuardInCallService brings the app forward during a locked call.
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        applyCallWindowFlags(intent)
    }

    /**
     * Set window flags that allow the call UI to show above the lock screen.
     *
     *  • FLAG_SHOW_WHEN_LOCKED  — draw over the keyguard
     *  • FLAG_TURN_SCREEN_ON   — wake the screen if it was off
     *  • FLAG_DISMISS_KEYGUARD — dismiss a non-secure keyguard automatically
     *  • FLAG_KEEP_SCREEN_ON   — prevent sleep during an active call
     *
     * On API 27+ the Activity-level setShowWhenLocked / setTurnScreenOn APIs are
     * preferred over window flags (deprecated), but we also set the window flags
     * for full backward compatibility.
     */
    private fun applyCallWindowFlags(intent: Intent?) {
        if (intent?.getBooleanExtra("from_incoming_call", false) != true) return

        // Window flags (all API levels)
        @Suppress("DEPRECATION")
        window.addFlags(
            WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
            WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON   or
            WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD or
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
        )

        // API 27+ typed APIs (preferred, avoids deprecation lint)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
            val km = getSystemService(KEYGUARD_SERVICE) as KeyguardManager
            km.requestDismissKeyguard(this, null)
        }
    }

    override fun onDestroy() {
        stopVoipRingtone()
        releaseProximityWakeLock()
        stopCallSegmentRecordingInternal()
        shellAudioSession?.stop()
        shellAudioSession = null
        super.onDestroy()
    }

    // ── Flutter engine setup ───────────────────────────────────────────────────

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    "requestDefaultDialer" -> {
                        requestDefaultDialer()
                        result.success(null)
                    }

                    "isDefaultDialer" -> result.success(isDefaultDialer())

                    "makeCall" -> {
                        val number = call.argument<String>("number")
                        if (number != null) { makeCall(number); result.success(null) }
                        else result.error("INVALID_ARGUMENT", "Phone number required", null)
                    }

                    "getContacts"    -> result.success(getContacts())

                    "saveContact" -> {
                        val name = call.argument<String>("name").orEmpty()
                        val phoneNumber = call.argument<String>("phoneNumber").orEmpty()
                        val alternatePhoneNumber = call.argument<String>("alternatePhoneNumber")
                        val email = call.argument<String>("email")
                        val notes = call.argument<String>("notes")
                        val phoneLabel = call.argument<String>("phoneLabel") ?: "Mobile"
                        result.success(saveContact(name, phoneNumber, alternatePhoneNumber, email, notes, phoneLabel))
                    }

                    "openNativeContactInsert" -> {
                        val name = call.argument<String>("name").orEmpty()
                        val phoneNumber = call.argument<String>("phoneNumber").orEmpty()
                        val alternatePhoneNumber = call.argument<String>("alternatePhoneNumber")
                        val email = call.argument<String>("email")
                        val notes = call.argument<String>("notes")
                        result.success(openNativeContactInsert(name, phoneNumber, alternatePhoneNumber, email, notes))
                    }

                    "findContactName" -> {
                        val number = call.argument<String>("number")
                        result.success(if (number != null) findContactName(number) else null)
                    }

                    "endCall"    -> { VoiceGuardInCallService.instance?.endCurrentCall();    result.success(null) }
                    "acceptCall" -> { VoiceGuardInCallService.instance?.acceptCurrentCall(); result.success(null) }
                    "rejectCall" -> { VoiceGuardInCallService.instance?.rejectCurrentCall(); result.success(null) }

                    "toggleSpeaker" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        VoiceGuardInCallService.instance?.toggleSpeaker(enabled)
                        result.success(null)
                    }

                    // Returns true when Telecom has committed ROUTE_SPEAKER.
                    // Used by CellularCallService.forceSpeakerOn() to confirm
                    // the hardware is actually routing to the loudspeaker, not
                    // just that the Dart-side flag was set.
                    "querySpeakerRoute" -> {
                        val active =
                            VoiceGuardInCallService.instance?.getSpeakerActive() ?: false
                        result.success(active)
                    }

                    "toggleMute" -> {
                        val muted = call.argument<Boolean>("muted") ?: false
                        VoiceGuardInCallService.instance?.toggleMute(muted)
                        result.success(null)
                    }

                    // ── VoIP audio routing ─────────────────────────────────────
                    "setVoipSpeaker" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        setVoipSpeakerphone(enabled)
                        result.success(null)
                    }

                    // ── DTMF ──────────────────────────────────────────────────
                    "sendDtmf" -> {
                        val digit = call.argument<String>("digit")?.firstOrNull()
                        if (digit != null) {
                            VoiceGuardInCallService.instance?.sendDtmf(digit)
                        }
                        result.success(null)
                    }

                    // ── Ringtone (VoIP) ───────────────────────────────────────
                    "playRingtone"  -> { playVoipRingtone();  result.success(null) }
                    "stopRingtone"  -> { stopVoipRingtone();  result.success(null) }

                    // ── Proximity / screen control ─────────────────────────────
                    "acquireProximityWakeLock" -> {
                        acquireProximityWakeLock()
                        result.success(null)
                    }
                    "releaseProximityWakeLock" -> {
                        releaseProximityWakeLock()
                        result.success(null)
                    }

                    // ── VoIP incoming-call notification ────────────────────
                    "showVoipCallNotification" -> {
                        val callerId = call.argument<String>("callerId") ?: "Unknown"
                        showVoipIncomingNotification(callerId)
                        result.success(null)
                    }
                    "dismissVoipCallNotification" -> {
                        dismissVoipNotification()
                        result.success(null)
                    }

                    // ── Call audio recording (cellular verification) ───────────
                    "startCallSegmentRecording" -> {
                        val path = call.argument<String>("path")
                        val audioSource = call.argument<Int>("audioSource")
                            ?: MediaRecorder.AudioSource.VOICE_RECOGNITION
                        if (path != null) {
                            startCallSegmentRecording(path, audioSource, result)
                        } else {
                            result.error("INVALID_ARGUMENT", "path required", null)
                        }
                    }
                    "stopCallSegmentRecording" -> {
                        stopCallSegmentRecording()
                        result.success(null)
                    }

                    // ── ADB / shell audio setup ────────────────────────────────

                    "adbSetupStatus" -> {
                        val mgr = AdbConnectionManager.getInstance(applicationContext)
                        result.success(mapOf(
                            "isPaired" to mgr.isPaired,
                            "hasPort"  to (mgr.savedPort >= 0),
                            "port"     to mgr.savedPort
                        ))
                    }

                    "adbStartPairing" -> {
                        val pPort = call.argument<Int>("pairingPort")
                        val code  = call.argument<String>("code")
                        if (pPort == null || code == null) {
                            result.error("INVALID_ARGUMENT", "pairingPort and code required", null)
                        } else {
                            Thread {
                                val ok = AdbConnectionManager.getInstance(applicationContext)
                                    .pair(pPort, code)
                                handler.post { result.success(ok) }
                            }.also { it.isDaemon = true; it.start() }
                        }
                    }

                    "adbSetMainPort" -> {
                        val port = call.argument<Int>("port")
                        if (port == null) {
                            result.error("INVALID_ARGUMENT", "port required", null)
                        } else {
                            AdbConnectionManager.getInstance(applicationContext).savePort(port)
                            result.success(null)
                        }
                    }

                    "adbTestConnection" -> {
                        Thread {
                            val ok = AdbConnectionManager.getInstance(applicationContext)
                                .testConnection()
                            handler.post { result.success(ok) }
                        }.also { it.isDaemon = true; it.start() }
                    }

                    "adbReset" -> {
                        AdbConnectionManager.getInstance(applicationContext).reset()
                        result.success(null)
                    }

                    "adbIsAccessibilityEnabled" -> {
                        val svc = "$packageName/${AdbPairingAccessibilityService::class.java.name}"
                        val enabled = android.provider.Settings.Secure
                            .getString(contentResolver,
                                android.provider.Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)
                            ?.split(':')?.any { it.trim().equals(svc, ignoreCase = true) } == true
                        result.success(enabled)
                    }

                    "openAccessibilitySettings" -> {
                        startActivity(
                            android.content.Intent(
                                android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS
                            ).apply { addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK) }
                        )
                        result.success(null)
                    }

                    // Discover the one-time pairing port via mDNS — only broadcasts
                    // while "Pair device with pairing code" dialog is open.
                    "adbDiscoverPairingPort" -> {
                        NsdDiscovery.findPairingPort(applicationContext) { port ->
                            result.success(port)
                        }
                    }

                    // Discover the persistent ADB connection port via mDNS — always
                    // broadcasts when Wireless Debugging is enabled.
                    "adbDiscoverMainPort" -> {
                        NsdDiscovery.findMainPort(applicationContext) { port ->
                            result.success(port)
                        }
                    }

                    "startShellAudioCapture" -> {
                        shellAudioSession?.stop()
                        val mgr     = AdbConnectionManager.getInstance(applicationContext)
                        val session = ShellAudioSession(applicationContext, mgr)
                        session.onSegmentReady = { path ->
                            handler.post {
                                shellAudioEventSink?.success(mapOf("type" to "segment", "path" to path))
                            }
                        }
                        session.onBlocked = {
                            handler.post {
                                shellAudioEventSink?.success(mapOf("type" to "blocked"))
                            }
                        }
                        shellAudioSession = session
                        result.success(session.start())
                    }

                    "stopShellAudioCapture" -> {
                        shellAudioSession?.stop()
                        shellAudioSession = null
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.voiceguard/call_state")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    VoiceGuardInCallService.setEventSink(events)
                }
                override fun onCancel(arguments: Any?) {
                    VoiceGuardInCallService.setEventSink(null)
                }
            })

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.voiceguard/shell_audio")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    shellAudioEventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    shellAudioEventSink = null
                }
            })
    }

    // ── Default dialer ─────────────────────────────────────────────────────────

    private fun isDefaultDialer(): Boolean {
        val tm = getSystemService(TELECOM_SERVICE) as TelecomManager
        return tm.defaultDialerPackage == packageName
    }

    private fun requestDefaultDialer() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val rm = getSystemService(RoleManager::class.java)
            if (rm.isRoleAvailable(RoleManager.ROLE_DIALER) && !rm.isRoleHeld(RoleManager.ROLE_DIALER)) {
                startActivityForResult(rm.createRequestRoleIntent(RoleManager.ROLE_DIALER), REQUEST_DEFAULT_DIALER)
            }
        } else {
            val intent = Intent(TelecomManager.ACTION_CHANGE_DEFAULT_DIALER)
            intent.putExtra(TelecomManager.EXTRA_CHANGE_DEFAULT_DIALER_PACKAGE_NAME, packageName)
            startActivity(intent)
        }
    }

    // ── Call dialling ──────────────────────────────────────────────────────────

    private fun makeCall(number: String) {
        val uri = Uri.parse("tel:$number")
        val tm = getSystemService(TELECOM_SERVICE) as TelecomManager

        // Build the Bundle with a PhoneAccountHandle so Android knows which
        // SIM / account to use. An empty Bundle causes STATE_SELECT_PHONE_ACCOUNT
        // on multi-SIM devices (which VoiceGuardInCallService maps to "unknown"
        // and ignores), leaving InCallScreen stuck at "Calling…" forever.
        try {
            val extras = Bundle()
            val accounts = tm.callCapablePhoneAccounts
            if (accounts.isNotEmpty()) {
                extras.putParcelable(
                    TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, accounts[0]
                )
            }
            tm.placeCall(uri, extras)
            return
        } catch (e: Exception) {
            android.util.Log.w("VoiceGuard", "Telecom placeCall failed, using ACTION_CALL", e)
        }

        try {
            val intent = Intent(Intent.ACTION_CALL, uri).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
        } catch (e: Exception) {
            android.util.Log.w("VoiceGuard", "ACTION_CALL failed, opening dialer", e)
            val dialIntent = Intent(Intent.ACTION_DIAL, uri).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(dialIntent)
        }
    }

    // ── Contacts ───────────────────────────────────────────────────────────────

    private fun getContacts(): List<Map<String, String>> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            checkSelfPermission(android.Manifest.permission.READ_CONTACTS) != PackageManager.PERMISSION_GRANTED
        ) return emptyList()

        val contacts = mutableListOf<Map<String, String>>()
        val seenNumbers = mutableSetOf<String>()
        val projection = arrayOf(
            ContactsContract.CommonDataKinds.Phone.CONTACT_ID,
            ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
            ContactsContract.CommonDataKinds.Phone.NUMBER
        )
        val cursor: Cursor? = contentResolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            projection, null, null,
            "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} ASC"
        )
        cursor?.use {
            val idIdx   = it.getColumnIndex(ContactsContract.CommonDataKinds.Phone.CONTACT_ID)
            val nameIdx = it.getColumnIndex(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME)
            val numIdx  = it.getColumnIndex(ContactsContract.CommonDataKinds.Phone.NUMBER)
            while (it.moveToNext()) {
                val number     = it.getString(numIdx)?.trim().orEmpty()
                val normalized = normalizePhoneNumber(number)
                if (normalized.isEmpty() || seenNumbers.contains(normalized)) continue
                seenNumbers.add(normalized)
                contacts.add(
                    mapOf(
                        "id"          to "${it.getString(idIdx)}_$normalized",
                        "name"        to it.getString(nameIdx).orEmpty(),
                        "phoneNumber" to number
                    )
                )
            }
        }
        return contacts
    }

    private fun findContactName(number: String): String? {
        val target = normalizePhoneNumber(number)
        if (target.isEmpty()) return null
        return getContacts().firstOrNull { contact ->
            val cn = normalizePhoneNumber(contact["phoneNumber"].orEmpty())
            cn.endsWith(target.takeLast(9)) || target.endsWith(cn.takeLast(9))
        }?.get("name")
    }

    private fun normalizePhoneNumber(number: String) = number.filter { it.isDigit() }

    private fun saveContact(
        name: String,
        phoneNumber: String,
        alternatePhoneNumber: String?,
        email: String?,
        notes: String?,
        phoneLabel: String
    ): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            checkSelfPermission(android.Manifest.permission.WRITE_CONTACTS) != PackageManager.PERMISSION_GRANTED
        ) return false

        if (name.isBlank() || phoneNumber.isBlank()) return false

        return try {
            val rawContactUri = contentResolver.insert(
                ContactsContract.RawContacts.CONTENT_URI,
                ContentValues().apply {
                    putNull(ContactsContract.RawContacts.ACCOUNT_TYPE)
                    putNull(ContactsContract.RawContacts.ACCOUNT_NAME)
                }
            ) ?: return false

            val rawContactId = rawContactUri.lastPathSegment?.toLongOrNull() ?: return false

            contentResolver.insert(
                ContactsContract.Data.CONTENT_URI,
                ContentValues().apply {
                    put(ContactsContract.Data.RAW_CONTACT_ID, rawContactId)
                    put(ContactsContract.Data.MIMETYPE, ContactsContract.CommonDataKinds.StructuredName.CONTENT_ITEM_TYPE)
                    put(ContactsContract.CommonDataKinds.StructuredName.DISPLAY_NAME, name.trim())
                }
            )

            insertPhone(rawContactId, phoneNumber.trim(), phoneLabel)
            if (!alternatePhoneNumber.isNullOrBlank()) {
                insertPhone(rawContactId, alternatePhoneNumber.trim(), "Other")
            }

            if (!email.isNullOrBlank()) {
                contentResolver.insert(
                    ContactsContract.Data.CONTENT_URI,
                    ContentValues().apply {
                        put(ContactsContract.Data.RAW_CONTACT_ID, rawContactId)
                        put(ContactsContract.Data.MIMETYPE, ContactsContract.CommonDataKinds.Email.CONTENT_ITEM_TYPE)
                        put(ContactsContract.CommonDataKinds.Email.ADDRESS, email.trim())
                        put(ContactsContract.CommonDataKinds.Email.TYPE, ContactsContract.CommonDataKinds.Email.TYPE_HOME)
                    }
                )
            }

            if (!notes.isNullOrBlank()) {
                contentResolver.insert(
                    ContactsContract.Data.CONTENT_URI,
                    ContentValues().apply {
                        put(ContactsContract.Data.RAW_CONTACT_ID, rawContactId)
                        put(ContactsContract.Data.MIMETYPE, ContactsContract.CommonDataKinds.Note.CONTENT_ITEM_TYPE)
                        put(ContactsContract.CommonDataKinds.Note.NOTE, notes.trim())
                    }
                )
            }

            true
        } catch (_: Exception) {
            false
        }
    }

    private fun openNativeContactInsert(
        name: String,
        phoneNumber: String,
        alternatePhoneNumber: String?,
        email: String?,
        notes: String?
    ): Boolean {
        if (name.isBlank() || phoneNumber.isBlank()) return false
        return try {
            val intent = Intent(ContactsContract.Intents.Insert.ACTION).apply {
                type = ContactsContract.RawContacts.CONTENT_TYPE
                putExtra(ContactsContract.Intents.Insert.NAME, name.trim())
                putExtra(ContactsContract.Intents.Insert.PHONE, phoneNumber.trim())
                putExtra(ContactsContract.Intents.Insert.EMAIL, email?.trim().orEmpty())
                putExtra(ContactsContract.Intents.Insert.NOTES, notes?.trim().orEmpty())
                if (!alternatePhoneNumber.isNullOrBlank()) {
                    putExtra(ContactsContract.Intents.Insert.SECONDARY_PHONE, alternatePhoneNumber.trim())
                }
            }
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun insertPhone(rawContactId: Long, number: String, label: String) {
        val type = when (label.lowercase()) {
            "home" -> ContactsContract.CommonDataKinds.Phone.TYPE_HOME
            "work" -> ContactsContract.CommonDataKinds.Phone.TYPE_WORK
            "main" -> ContactsContract.CommonDataKinds.Phone.TYPE_MAIN
            else -> ContactsContract.CommonDataKinds.Phone.TYPE_MOBILE
        }
        contentResolver.insert(
            ContactsContract.Data.CONTENT_URI,
            ContentValues().apply {
                put(ContactsContract.Data.RAW_CONTACT_ID, rawContactId)
                put(ContactsContract.Data.MIMETYPE, ContactsContract.CommonDataKinds.Phone.CONTENT_ITEM_TYPE)
                put(ContactsContract.CommonDataKinds.Phone.NUMBER, number)
                put(ContactsContract.CommonDataKinds.Phone.TYPE, type)
            }
        )
    }

    // ── VoIP speakerphone ──────────────────────────────────────────────────────

    /**
     * Route VoIP audio between earpiece and loudspeaker.
     *
     * Key fixes vs the original implementation:
     *
     * 1. AUDIOFOCUS_GAIN (not TRANSIENT) — VoIP calls are not transient; using
     *    TRANSIENT lets other apps preempt our focus and silence the call audio.
     *
     * 2. Explicit earpiece routing on API 31+ — clearCommunicationDevice() leaves
     *    the destination undefined and on some devices (especially Android 12+)
     *    the audio ends up at an unexpected/inaudible device.  We now explicitly
     *    call setCommunicationDevice(EARPIECE) so the system always has a target.
     *
     * 3. Triple re-apply (300 ms / 1 500 ms / 3 000 ms) — WebRTC's audio engine
     *    initialises after createOffer/createAnswer and can reset AudioManager
     *    routing after our first call.  The 1 500 ms window catches the "hedgehog"
     *    AudioTrack init sequence seen in logcat.  Each new call to
     *    setVoipSpeakerphone() cancels all pending runnables so rapid toggles
     *    don't fight each other.
     */
    // Track all three delayed runnables so we can cancel ALL of them when a
    // new setVoipSpeakerphone() call arrives (not just the last one).
    private val pendingSpeakerRunnables = mutableListOf<Runnable>()

    private fun setVoipSpeakerphone(enabled: Boolean) {
        // Cancel every pending re-apply — including r300 and r1500, not only r3000.
        for (r in pendingSpeakerRunnables) handler.removeCallbacks(r)
        pendingSpeakerRunnables.clear()

        applyVoipSpeakerInternal(enabled)

        val r300  = Runnable { applyVoipSpeakerInternal(enabled) }
        val r1500 = Runnable { applyVoipSpeakerInternal(enabled) }
        val r3000 = Runnable {
            applyVoipSpeakerInternal(enabled)
            pendingSpeakerRunnables.clear() // all re-applies done
        }

        pendingSpeakerRunnables.addAll(listOf(r300, r1500, r3000))
        handler.postDelayed(r300,   300)
        handler.postDelayed(r1500, 1_500)
        handler.postDelayed(r3000, 3_000)
    }

    // Stored so we can abandon focus cleanly when the call ends.
    private var voipAudioFocusRequest: AudioFocusRequest? = null

    private fun applyVoipSpeakerInternal(enabled: Boolean) {
        val audioManager = getSystemService(AUDIO_SERVICE) as AudioManager

        // Relay-mode audio uses flutter_sound (STREAM_MUSIC), NOT WebRTC.
        //
        // The old code set MODE_IN_COMMUNICATION here, which causes two bugs:
        //   1. STREAM_MUSIC is routed to the earpiece in telephony mode —
        //      the user hears nothing through the speaker.
        //   2. Android's telephony audio policy can block the second
        //      AudioRecord session (record package), causing one-way audio.
        //
        // Fix: stay in MODE_NORMAL.  STREAM_MUSIC routes to the external
        // speaker automatically in MODE_NORMAL (no setSpeakerphoneOn needed),
        // and AudioRecord can always initialize without policy conflicts.
        audioManager.mode = AudioManager.MODE_NORMAL

        if (enabled) {
            // Request media audio focus so music/podcasts pause during the call.
            // Guard against the triple-re-apply loop calling us multiple times —
            // only request once; repeated requestAudioFocus calls leak references.
            if (voipAudioFocusRequest == null) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                        .setAudioAttributes(
                            AudioAttributes.Builder()
                                .setUsage(AudioAttributes.USAGE_MEDIA)
                                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                                .build()
                        )
                        .setAcceptsDelayedFocusGain(false)
                        .setWillPauseWhenDucked(false)
                        .build()
                    voipAudioFocusRequest = req
                    audioManager.requestAudioFocus(req)
                } else {
                    @Suppress("DEPRECATION")
                    audioManager.requestAudioFocus(
                        null, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN
                    )
                }
            }
        } else {
            // Release audio focus when the call ends.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                voipAudioFocusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
                voipAudioFocusRequest = null
            } else {
                @Suppress("DEPRECATION")
                audioManager.abandonAudioFocus(null)
            }
        }
    }

    // ── VoIP incoming-call notification ───────────────────────────────────────

    /**
     * Show a high-priority VoIP incoming-call notification with fullScreenIntent.
     * This is the VoIP equivalent of VoiceGuardInCallService.showIncomingCallNotification().
     * Called from Dart when SignalingService receives an incoming_call event so that
     * the call UI can appear even when the device is locked or the app is backgrounded.
     */
    private fun showVoipIncomingNotification(callerId: String) {
        // Ensure notification channel exists (MainActivity may start before InCallService)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(VoiceGuardInCallService.CHANNEL_CALLS) == null) {
                val channel = android.app.NotificationChannel(
                    VoiceGuardInCallService.CHANNEL_CALLS,
                    "Phone Calls",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                    setBypassDnd(true)
                }
                nm.createNotificationChannel(channel)
            }
        }

        val fullScreenIntent = PendingIntent.getActivity(
            this, 10,
            Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                putExtra("from_incoming_call", true)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(this, VoiceGuardInCallService.CHANNEL_CALLS)
            .setSmallIcon(android.R.drawable.ic_menu_call)
            .setContentTitle("Incoming VoIP Call")
            .setContentText(callerId)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setFullScreenIntent(fullScreenIntent, true)
            .setOngoing(true)
            .setAutoCancel(false)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setContentIntent(fullScreenIntent)
            .build()

        val nm = getSystemService(NotificationManager::class.java)
        nm.notify(VOIP_NOTIFICATION_ID, notification)

        // Also apply lockscreen flags so the activity surfaces above the keyguard
        applyCallWindowFlags(Intent().putExtra("from_incoming_call", true))
    }

    private fun dismissVoipNotification() {
        val nm = getSystemService(NotificationManager::class.java)
        nm.cancel(VOIP_NOTIFICATION_ID)
    }

    // ── VoIP ringtone ──────────────────────────────────────────────────────────

    private fun playVoipRingtone() {
        stopVoipRingtone()
        try {
            val audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(
                null, AudioManager.STREAM_RING, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT
            )
            val uri: Uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            voipRingtone = RingtoneManager.getRingtone(applicationContext, uri)
            voipRingtone?.play()
        } catch (_: Exception) {}
    }

    private fun stopVoipRingtone() {
        try { voipRingtone?.let { if (it.isPlaying) it.stop() } } catch (_: Exception) {}
        voipRingtone = null
    }

    // ── Proximity wake lock (screen-off near ear, on when away) ──────────────

    /**
     * Acquire a PROXIMITY_SCREEN_OFF_WAKE_LOCK.  While held, the screen turns
     * off automatically when the proximity sensor detects the phone is near the
     * user's ear, and turns back on when it's moved away.  This is the same
     * mechanism used by the stock Android dialer.
     */
    private fun acquireProximityWakeLock() {
        if (proximityWakeLock?.isHeld == true) return
        try {
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            if (pm.isWakeLockLevelSupported(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)) {
                proximityWakeLock = pm.newWakeLock(
                    PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK,
                    "VoiceGuard:ProximityWakeLock"
                )
                proximityWakeLock?.acquire(60 * 60 * 1000L /* 1 hr max */)
            }
        } catch (_: Exception) {}
    }

    private fun releaseProximityWakeLock() {
        try {
            if (proximityWakeLock?.isHeld == true) {
                // Release without timeout to let screen turn on immediately
                proximityWakeLock?.release(PowerManager.RELEASE_FLAG_WAIT_FOR_NO_PROXIMITY)
            }
        } catch (_: Exception) {}
        proximityWakeLock = null
    }

    // ── Call audio recording (VOICE_RECOGNITION — no AEC/AGC/NS) ─────────────
    //
    // Why VOICE_RECOGNITION instead of MIC or VOICE_COMMUNICATION?
    //
    //  • VOICE_COMMUNICATION  — has full AEC enabled.  AEC subtracts the
    //    earpiece signal from the mic, so the remote caller's voice is almost
    //    completely removed.  This is the source the `record` Flutter package
    //    uses by default, making call-time verification record the WRONG voice.
    //
    //  • VOICE_RECOGNITION    — AEC, AGC, and NS are all disabled.  The raw
    //    mic signal is captured, which retains the earpiece bleed of the remote
    //    caller.  VadProcessor then finds the windows where the local user is
    //    silent and extracts those windows — giving the AI primarily the
    //    caller's voice.
    //
    // The WAV file is written incrementally:
    //  1. A placeholder 44-byte header is written first.
    //  2. PCM frames are appended in a background thread.
    //  3. On stop() the header is patched with the real data size.

    /**
     * Try to create an AudioRecord for cellular call capture.
     *
     * Source priority (best audio quality for speaker-verification first):
     *   1. Caller-requested source (default: VOICE_RECOGNITION — no AEC/AGC/NS,
     *      preserves earpiece bleed of the remote caller)
     *   2. MIC — always works; has AEC but usable with speakerphone
     *   3. DEFAULT — last-resort fallback
     *
     * On Android 12+ some ROMs silently block VOICE_RECOGNITION for non-system
     * apps even when ROLE_DIALER is held. Falling back to MIC ensures we always
     * capture something; the VAD on the Dart side then filters for speech.
     */
    private fun buildAudioRecord(
        preferredSource: Int,
        sampleRate: Int,
        channelConfig: Int,
        audioFormat: Int,
        bufferSize: Int
    ): AudioRecord? {
        val fallbacks = when (preferredSource) {
            MediaRecorder.AudioSource.MIC ->
                intArrayOf(MediaRecorder.AudioSource.MIC, MediaRecorder.AudioSource.DEFAULT)
            else ->
                intArrayOf(preferredSource,
                    MediaRecorder.AudioSource.MIC,
                    MediaRecorder.AudioSource.DEFAULT)
        }
        for (src in fallbacks) {
            try {
                val ar = AudioRecord(src, sampleRate, channelConfig, audioFormat, bufferSize)
                if (ar.state == AudioRecord.STATE_INITIALIZED) {
                    android.util.Log.d("VoiceGuard", "startCallSegmentRecording: using source $src")
                    return ar
                }
                ar.release()
            } catch (e: Exception) {
                android.util.Log.w("VoiceGuard",
                    "startCallSegmentRecording: source $src failed — ${e.message}")
            }
        }
        return null
    }

    private fun startCallSegmentRecording(
        path: String,
        preferredSource: Int,
        result: MethodChannel.Result
    ) {
        // Stop any previous recording cleanly before starting a new one
        stopCallSegmentRecordingInternal()

        val sampleRate    = 16_000
        val channelConfig = AudioFormat.CHANNEL_IN_MONO
        val audioFormat   = AudioFormat.ENCODING_PCM_16BIT
        val minBuf        = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)
        val bufferSize    = maxOf(minBuf * 4, 16_384)

        if (bufferSize == AudioRecord.ERROR || bufferSize == AudioRecord.ERROR_BAD_VALUE) {
            result.error("BUFFER_ERROR", "AudioRecord buffer size query failed", null)
            return
        }

        val audioRecord = buildAudioRecord(preferredSource, sampleRate, channelConfig, audioFormat, bufferSize)
        if (audioRecord == null) {
            result.error("INIT_FAILED", "No audio source available for call recording", null)
            return
        }

        currentCallAudioPath = path
        callAudioRecord      = audioRecord
        isRecordingCallAudio = true

        audioRecord.startRecording()

        callAudioThread = Thread {
            val raf = RandomAccessFile(path, "rw")
            try {
                // Write placeholder header; sizes will be patched on stop
                writeWavHeader(raf, sampleRate, dataBytes = 0)

                val buffer      = ByteArray(bufferSize)
                var totalBytes  = 0

                while (isRecordingCallAudio) {
                    val read = audioRecord.read(buffer, 0, buffer.size)
                    if (read > 0) {
                        raf.write(buffer, 0, read)
                        totalBytes += read
                    }
                }

                // Patch the WAV header with real sizes
                raf.seek(0)
                writeWavHeader(raf, sampleRate, dataBytes = totalBytes)
            } catch (e: Exception) {
                android.util.Log.e("VoiceGuard", "Call audio thread error: ${e.message}")
            } finally {
                try { raf.close() } catch (_: Exception) {}
            }
        }.also { t ->
            t.isDaemon = true
            t.name     = "vg-call-audio"
            t.start()
        }

        result.success(null)
    }

    private fun stopCallSegmentRecording() {
        stopCallSegmentRecordingInternal()
    }

    private fun stopCallSegmentRecordingInternal() {
        isRecordingCallAudio = false

        try {
            callAudioRecord?.stop()
            callAudioRecord?.release()
        } catch (_: Exception) {}
        callAudioRecord = null

        try { callAudioThread?.join(3_000) } catch (_: Exception) {}
        callAudioThread = null
    }

    /**
     * Write (or overwrite) a standard 44-byte PCM WAV header.
     * [dataBytes] is the number of raw PCM bytes in the data chunk.
     */
    private fun writeWavHeader(raf: RandomAccessFile, sampleRate: Int, dataBytes: Int) {
        val byteRate   = sampleRate * 2   // mono × 16-bit
        val totalSize  = 36 + dataBytes

        raf.seek(0)
        raf.write("RIFF".toByteArray())
        raf.write(le32(totalSize))
        raf.write("WAVE".toByteArray())
        raf.write("fmt ".toByteArray())
        raf.write(le32(16))             // fmt chunk size
        raf.write(le16(1))              // PCM format
        raf.write(le16(1))              // mono
        raf.write(le32(sampleRate))
        raf.write(le32(byteRate))
        raf.write(le16(2))              // block align (mono × 2 bytes)
        raf.write(le16(16))             // bits per sample
        raf.write("data".toByteArray())
        raf.write(le32(dataBytes))
    }

    private fun le32(v: Int): ByteArray =
        ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(v).array()

    private fun le16(v: Int): ByteArray =
        ByteBuffer.allocate(2).order(ByteOrder.LITTLE_ENDIAN).putShort(v.toShort()).array()
}
