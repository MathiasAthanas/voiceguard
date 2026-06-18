package com.voiceguard

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.telecom.Call
import android.telecom.CallAudioState
import android.telecom.InCallService
import android.telecom.VideoProfile
import androidx.core.app.NotificationCompat
import io.flutter.plugin.common.EventChannel

class VoiceGuardInCallService : InCallService() {

    companion object {
        var instance: VoiceGuardInCallService? = null
        private var eventSink: EventChannel.EventSink? = null
        private val pendingEvents = mutableListOf<Map<String, Any>>()

        // Notification constants
        const val CALL_NOTIFICATION_ID = 42
        const val CHANNEL_CALLS = "voiceguard_calls"

        // Broadcast action constants (used by CallActionReceiver)
        const val ACTION_ANSWER = "com.voiceguard.ACTION_ANSWER"
        const val ACTION_REJECT = "com.voiceguard.ACTION_REJECT"
        const val ACTION_END    = "com.voiceguard.ACTION_END"

        fun setEventSink(sink: EventChannel.EventSink?) {
            eventSink = sink
            if (sink != null) {
                pendingEvents.forEach { sink.success(it) }
                pendingEvents.clear()
            }
        }

        fun sendEvent(event: String, data: Map<String, String>) {
            val payload = mapOf("event" to event, "data" to data)
            val sink = eventSink
            if (sink != null) {
                // Always deliver on the main thread to avoid Flutter engine assertion
                Handler(Looper.getMainLooper()).post { sink.success(payload) }
            } else {
                pendingEvents.add(payload)
            }
        }
    }

    private var currentCall: Call? = null
    private var ringtone: Ringtone? = null
    private var vibrator: Vibrator? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private val handler = Handler(Looper.getMainLooper())

    // ── Lifecycle ──────────────────────────────────────────────────────────────

    override fun onCreate() {
        super.onCreate()
        instance = this
        createNotificationChannels()
        vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (getSystemService(VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(VIBRATOR_SERVICE) as Vibrator
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        stopRinging()
        releaseWakeLock()
        instance = null
    }

    // ── Notification channels ──────────────────────────────────────────────────

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(NotificationManager::class.java)

        // High-importance channel for incoming call heads-up + lockscreen
        val callChannel = NotificationChannel(
            CHANNEL_CALLS,
            "Phone Calls",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Incoming and active phone calls"
            setShowBadge(false)
            enableVibration(false) // we drive vibration manually
            setBypassDnd(true)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        nm.createNotificationChannel(callChannel)
    }

    // ── Call callbacks ─────────────────────────────────────────────────────────

    private val callCallback = object : Call.Callback() {

        override fun onStateChanged(call: Call, state: Int) {
            super.onStateChanged(call, state)
            when (state) {
                Call.STATE_RINGING -> {
                    // Should not happen here (onCallAdded handles initial ringing)
                    startRinging(call.details?.handle?.schemeSpecificPart ?: "Unknown")
                }
                Call.STATE_ACTIVE -> {
                    stopRinging()
                    acquireCallWakeLock()
                    showOngoingCallNotification(call.details?.handle?.schemeSpecificPart ?: "Unknown")
                }
                else -> {
                    if (state != Call.STATE_RINGING) stopRinging()
                }
            }
            notifyCallState(state, call)
        }

        override fun onDetailsChanged(call: Call, details: Call.Details) {
            super.onDetailsChanged(call, details)
        }
    }

    override fun onCallAdded(call: Call) {
        super.onCallAdded(call)
        currentCall = call
        call.registerCallback(callCallback)
        notifyCallState(call.state, call)

        if (call.state == Call.STATE_RINGING) {
            val number = call.details?.handle?.schemeSpecificPart ?: "Unknown"
            startRinging(number)
            showIncomingCallNotification(number)
            bringAppToForeground()
        }
    }

    override fun onCallRemoved(call: Call) {
        super.onCallRemoved(call)
        call.unregisterCallback(callCallback)
        stopRinging()
        releaseWakeLock()
        currentCall = null

        // Remove the foreground notification
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }

        notifyFlutter("call_ended", mapOf("state" to "ended"))
    }

    // ── Notifications ──────────────────────────────────────────────────────────

    /**
     * Show a high-priority incoming-call notification with Answer and Reject buttons.
     * The fullScreenIntent pops the app above the lockscreen when the device is locked.
     */
    private fun showIncomingCallNotification(number: String) {
        val fullScreenIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                putExtra("from_incoming_call", true)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val answerPi = PendingIntent.getBroadcast(
            this, 1,
            Intent(this, CallActionReceiver::class.java).apply { action = ACTION_ANSWER },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val rejectPi = PendingIntent.getBroadcast(
            this, 2,
            Intent(this, CallActionReceiver::class.java).apply { action = ACTION_REJECT },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(this, CHANNEL_CALLS)
            .setSmallIcon(android.R.drawable.ic_menu_call)
            .setContentTitle("Incoming Call")
            .setContentText(number)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setFullScreenIntent(fullScreenIntent, true)
            .setOngoing(true)
            .setAutoCancel(false)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .addAction(android.R.drawable.ic_menu_call, "Answer", answerPi)
            .addAction(android.R.drawable.ic_delete, "Reject", rejectPi)
            .setContentIntent(fullScreenIntent)
            .build()

        startForeground(CALL_NOTIFICATION_ID, notification)
    }

    /** Replace the incoming-call notification with an ongoing-call one. */
    private fun showOngoingCallNotification(number: String) {
        val tapIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val endPi = PendingIntent.getBroadcast(
            this, 3,
            Intent(this, CallActionReceiver::class.java).apply { action = ACTION_END },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(this, CHANNEL_CALLS)
            .setSmallIcon(android.R.drawable.ic_menu_call)
            .setContentTitle("Ongoing Call")
            .setContentText(number)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setOngoing(true)
            .setAutoCancel(false)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .addAction(android.R.drawable.ic_delete, "End Call", endPi)
            .setContentIntent(tapIntent)
            .build()

        val nm = getSystemService(NotificationManager::class.java)
        nm.notify(CALL_NOTIFICATION_ID, notification)
    }

    // ── Bring app to foreground (works over lockscreen) ────────────────────────

    /**
     * Launch (or bring to foreground) MainActivity.
     * FLAG_SHOW_WHEN_LOCKED ensures the activity appears above the lockscreen.
     * FLAG_TURN_SCREEN_ON wakes the screen if it was off.
     * FLAG_DISMISS_KEYGUARD allows dismissing a non-secure keyguard.
     */
    private fun bringAppToForeground() {
        val intent = Intent(this, MainActivity::class.java).apply {
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
            )
            putExtra("from_incoming_call", true)
        }
        startActivity(intent)
    }

    // ── Ringtone + vibration ───────────────────────────────────────────────────

    private fun startRinging(number: String) {
        stopRinging()
        try {
            val audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
            audioManager.requestAudioFocus(
                null, AudioManager.STREAM_RING,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT
            )
            val uri: Uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            ringtone = RingtoneManager.getRingtone(applicationContext, uri)
            ringtone?.play()
        } catch (_: Exception) { /* ringtone is best-effort */ }

        // Vibration pattern: wait 0 ms, vibrate 1s, pause 0.5s, repeat
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val pattern = longArrayOf(0, 1000, 500)
                vibrator?.vibrate(
                    VibrationEffect.createWaveform(pattern, 0 /* repeat from index 0 */)
                )
            } else {
                @Suppress("DEPRECATION")
                vibrator?.vibrate(longArrayOf(0, 1000, 500), 0)
            }
        } catch (_: Exception) { /* vibration is best-effort */ }
    }

    private fun stopRinging() {
        try { ringtone?.let { if (it.isPlaying) it.stop() } } catch (_: Exception) {}
        ringtone = null
        try { vibrator?.cancel() } catch (_: Exception) {}
    }

    // ── Wake lock (keeps CPU alive during active call) ────────────────────────

    private fun acquireCallWakeLock() {
        if (wakeLock?.isHeld == true) return
        try {
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK, "VoiceGuard:CallWakeLock"
            ).also { it.acquire(60 * 60 * 1000L /* 1 hour max */) }
        } catch (_: Exception) {}
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Exception) {}
        wakeLock = null
    }

    // ── Call controls ──────────────────────────────────────────────────────────

    fun acceptCurrentCall() {
        currentCall?.answer(VideoProfile.STATE_AUDIO_ONLY)
    }

    fun rejectCurrentCall() {
        currentCall?.reject(false, null)
    }

    fun endCurrentCall() {
        currentCall?.disconnect()
    }

    /**
     * Toggle the loudspeaker for a cellular call.
     *
     * Cellular calls are owned by Android Telecom while this class is the active
     * InCallService. Telecom ignores AudioManager.isSpeakerphoneOn on many
     * modern devices, so the primary route change must go through
     * InCallService.setAudioRoute().
     */
    fun toggleSpeaker(enabled: Boolean) {
        val audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
        val targetRoute = if (enabled) {
            CallAudioState.ROUTE_SPEAKER
        } else {
            preferredNonSpeakerRoute()
        }

        try {
            setAudioRoute(targetRoute)
        } catch (_: Exception) {
            // Fallback for devices/ROMs that still honor AudioManager directly.
            audioManager.mode = AudioManager.MODE_IN_CALL
            @Suppress("DEPRECATION")
            audioManager.isSpeakerphoneOn = enabled
        }

        // Some devices briefly override the route after call state changes.
        handler.postDelayed({
            try {
                setAudioRoute(targetRoute)
            } catch (_: Exception) {
                audioManager.mode = AudioManager.MODE_IN_CALL
                @Suppress("DEPRECATION")
                audioManager.isSpeakerphoneOn = enabled
            }
        }, 250)
    }

    private fun preferredNonSpeakerRoute(): Int {
        val state = callAudioState
        val supported = state?.supportedRouteMask ?: 0

        return when {
            supported and CallAudioState.ROUTE_BLUETOOTH != 0 &&
                state?.route == CallAudioState.ROUTE_BLUETOOTH ->
                CallAudioState.ROUTE_BLUETOOTH

            supported and CallAudioState.ROUTE_WIRED_HEADSET != 0 ->
                CallAudioState.ROUTE_WIRED_HEADSET

            supported and CallAudioState.ROUTE_EARPIECE != 0 ->
                CallAudioState.ROUTE_EARPIECE

            else -> CallAudioState.ROUTE_EARPIECE
        }
    }

    fun toggleMute(muted: Boolean) {
        val audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
        audioManager.isMicrophoneMute = muted
    }

    /** Send a DTMF tone on the active cellular call. */
    fun sendDtmf(digit: Char) {
        currentCall?.playDtmfTone(digit)
        handler.postDelayed({ currentCall?.stopDtmfTone() }, 120)
    }

    // ── State reporting ────────────────────────────────────────────────────────

    private fun notifyCallState(state: Int, call: Call) {
        val stateName = when (state) {
            Call.STATE_RINGING      -> "ringing"
            Call.STATE_DIALING      -> "dialing"
            Call.STATE_ACTIVE       -> "active"
            Call.STATE_HOLDING      -> "holding"
            Call.STATE_DISCONNECTED -> "disconnected"
            Call.STATE_CONNECTING   -> "connecting"
            else                    -> "unknown"
        }
        val number = call.details?.handle?.schemeSpecificPart ?: "Unknown"
        notifyFlutter("call_state_changed", mapOf("state" to stateName, "number" to number))
    }

    private fun notifyFlutter(event: String, data: Map<String, String>) {
        sendEvent(event, data)
    }
}
