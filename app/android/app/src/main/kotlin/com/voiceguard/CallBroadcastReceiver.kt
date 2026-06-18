package com.voiceguard

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.telephony.TelephonyManager

/**
 * Catches PHONE_STATE broadcasts as a secondary signal source.
 * The primary source is VoiceGuardInCallService (TelecomManager / InCallService API).
 * This receiver handles edge cases where the InCallService hasn't started yet,
 * e.g. very brief calls or devices where the InCallService binding is delayed.
 *
 * All it does is ensure MainActivity is running so the Flutter EventChannel is alive.
 * The actual call-state events are sent by VoiceGuardInCallService.sendEvent().
 */
class CallBroadcastReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {

            TelephonyManager.ACTION_PHONE_STATE_CHANGED -> {
                val state = intent.getStringExtra(TelephonyManager.EXTRA_STATE)
                // Only act on ringing — make sure the app is alive so the
                // InCallService EventChannel has somewhere to deliver events.
                if (state == TelephonyManager.EXTRA_STATE_RINGING) {
                    ensureAppIsRunning(context)
                }
            }

            Intent.ACTION_NEW_OUTGOING_CALL -> {
                ensureAppIsRunning(context)
            }
        }
    }

    /**
     * Bring the app to the foreground (or start it) so that the Flutter engine
     * is alive and the EventChannel can receive call-state events from
     * VoiceGuardInCallService.
     */
    private fun ensureAppIsRunning(context: Context) {
        val intent = Intent(context, MainActivity::class.java).apply {
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
            )
            putExtra("from_incoming_call", true)
        }
        context.startActivity(intent)
    }
}
