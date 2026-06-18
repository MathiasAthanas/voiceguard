package com.voiceguard

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Handles answer / reject / end-call actions tapped directly on the
 * incoming-call or ongoing-call notification — even when the device is locked
 * and the app isn't in the foreground.
 *
 * The receiver is registered in AndroidManifest with exported=false so only
 * our own PendingIntents can trigger it.
 */
class CallActionReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val service = VoiceGuardInCallService.instance ?: return
        when (intent.action) {
            VoiceGuardInCallService.ACTION_ANSWER -> service.acceptCurrentCall()
            VoiceGuardInCallService.ACTION_REJECT -> service.rejectCurrentCall()
            VoiceGuardInCallService.ACTION_END    -> service.endCurrentCall()
        }
    }
}
