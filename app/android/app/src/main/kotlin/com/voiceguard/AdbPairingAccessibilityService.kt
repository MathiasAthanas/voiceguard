package com.voiceguard

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import com.voiceguard.adb.AdbConnectionManager
import com.voiceguard.adb.NsdDiscovery
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Watches the Android Settings screen for the "Pair device with pairing code" dialog.
 * When detected, automatically reads the 6-digit code and pairing port from the screen
 * and calls pair() in the background — the user never has to switch apps.
 *
 * After successful pairing, also auto-discovers and saves the main ADB connection port.
 */
class AdbPairingAccessibilityService : AccessibilityService() {

    companion object {
        private const val TAG = "AdbA11y"

        // Stock Android settings package; Samsung also uses com.samsung.android.settings
        // for their UI shell but Developer Options / Wireless Debugging remain in the
        // AOSP package on all tested One UI versions.
        private val SETTINGS_PKGS = setOf(
            "com.android.settings",
            "com.samsung.android.settings",  // One UI fallback
        )
        private const val NOTIF_CH     = "voiceguard_adb_pairing"
        private const val NOTIF_ID     = 9900
    }

    private val handler  = Handler(Looper.getMainLooper())
    private val pairing  = AtomicBoolean(false)
    private var lastCode = ""           // avoid re-pairing on the same code

    // ── Service lifecycle ─────────────────────────────────────────────────────

    override fun onServiceConnected() {
        serviceInfo = AccessibilityServiceInfo().apply {
            eventTypes      = AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED or
                              AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED
            feedbackType    = AccessibilityServiceInfo.FEEDBACK_GENERIC
            flags           = AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS
            notificationTimeout = 400
            packageNames    = SETTINGS_PKGS.toTypedArray()
        }
        Log.d(TAG, "ADB pairing accessibility service connected")
    }

    override fun onInterrupt() {}

    // ── Accessibility events ──────────────────────────────────────────────────

    override fun onAccessibilityEvent(event: AccessibilityEvent) {
        if (pairing.get()) return
        if (event.packageName?.toString() !in SETTINGS_PKGS) return

        // Skip events unrelated to window transitions and content updates
        val t = event.eventType
        if (t != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED &&
            t != AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED) return

        handler.removeCallbacksAndMessages(TAG)
        handler.postAtTime({
            tryDetectAndPair()
        }, TAG, android.os.SystemClock.uptimeMillis() + 300)
    }

    // ── Detection ─────────────────────────────────────────────────────────────

    private fun tryDetectAndPair() {
        if (pairing.get()) return
        val root = rootInActiveWindow ?: return
        val text = gatherText(root)

        // Must look like the ADB pairing dialog
        if (!text.contains("pair", ignoreCase = true)) return
        if (!text.contains("debug", ignoreCase = true) &&
            !text.contains("wireless", ignoreCase = true) &&
            !text.contains("port", ignoreCase = true)) return

        val code = extractCode(text) ?: return
        if (code == lastCode) return

        val port = extractPort(text, code)
        if (port != null) {
            startPairing(port, code)
        } else {
            // Port not visible yet — try mDNS (short timeout; it's already broadcasting)
            NsdDiscovery.findPairingPort(applicationContext, timeoutMs = 8_000) { p ->
                if (p != null) startPairing(p, code)
            }
        }
    }

    // ── Text extraction ───────────────────────────────────────────────────────

    /** Collects all visible text from the accessibility tree iteratively. */
    private fun gatherText(root: AccessibilityNodeInfo): String {
        val sb    = StringBuilder()
        val queue = ArrayDeque<AccessibilityNodeInfo>()
        queue.addLast(root)
        while (queue.isNotEmpty()) {
            val node = queue.removeFirst()
            node.text?.let { sb.append(it).append(' ') }
            node.contentDescription?.let { sb.append(it).append(' ') }
            for (i in 0 until node.childCount) {
                node.getChild(i)?.let { queue.addLast(it) }
            }
        }
        return sb.toString()
    }

    /** Finds the 6-digit pairing code. Handles "123456", "123 456", "1 2 3 4 5 6". */
    private fun extractCode(text: String): String? {
        // Try plain 6-digit block first (most common)
        Regex("""(?<!\d)(\d{6})(?!\d)""").find(text)
            ?.let { return it.groupValues[1] }

        // Fallback: 6 single digits possibly separated by spaces/dashes
        val m = Regex("""(\d)[\s\-]?(\d)[\s\-]?(\d)[\s\-]?(\d)[\s\-]?(\d)[\s\-]?(\d)""")
            .find(text) ?: return null
        return (1..6).joinToString("") { m.groupValues[it] }
    }

    /** Finds the pairing port: a 4–5 digit number in the valid port range, not the code. */
    private fun extractPort(text: String, code: String): Int? =
        Regex("""(?<!\d)(\d{4,5})(?!\d)""").findAll(text)
            .mapNotNull { it.groupValues[1].toIntOrNull() }
            .filter { it in 1024..65535 && it.toString() != code }
            .firstOrNull()

    // ── Pairing ───────────────────────────────────────────────────────────────

    private fun startPairing(port: Int, code: String) {
        if (!pairing.compareAndSet(false, true)) return
        lastCode = code
        Log.d(TAG, "Auto-pairing: port=$port code=$code")

        Thread {
            val mgr    = AdbConnectionManager.getInstance(applicationContext)
            val paired = mgr.pair(port, code)
            Log.d(TAG, "Pair result: $paired")

            if (!paired) {
                lastCode = ""
                pairing.set(false)
                return@Thread
            }

            // Paired — now auto-discover the main connection port
            NsdDiscovery.findMainPort(applicationContext, timeoutMs = 15_000) { mainPort ->
                if (mainPort != null) {
                    mgr.savePort(mainPort)
                    Log.d(TAG, "Main port saved: $mainPort")
                }
                showNotification(mainPort != null)
                pairing.set(false)
            }
        }.apply { isDaemon = true; name = "adb-auto-pair" }.start()
    }

    // ── Notification ──────────────────────────────────────────────────────────

    private fun showNotification(fullyConnected: Boolean) {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(NOTIF_CH, "ADB Pairing",
                    NotificationManager.IMPORTANCE_DEFAULT)
            )
        }
        val tap = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val body = if (fullyConnected)
            "Cellular audio capture is ready!"
        else
            "Paired! Open VoiceGuard to complete the connection."

        @Suppress("DEPRECATION")
        val notif = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            android.app.Notification.Builder(this, NOTIF_CH)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle("VoiceGuard — ADB Setup")
                .setContentText(body)
                .setContentIntent(tap)
                .setAutoCancel(true)
                .build()
        else
            android.app.Notification.Builder(this)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle("VoiceGuard — ADB Setup")
                .setContentText(body)
                .setContentIntent(tap)
                .setAutoCancel(true)
                .build()

        nm.notify(NOTIF_ID, notif)
    }
}
