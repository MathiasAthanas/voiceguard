package com.voiceguard.shell

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import java.io.DataOutputStream
import java.net.Socket

// Launched via app_process as Android shell user (UID 2000).
// Shell UID bypasses the CAPTURE_AUDIO_OUTPUT permission check, granting
// access to VOICE_DOWNLINK (remote caller's audio on the receive path).
//
// Launch command (run from ADB shell by AdbConnectionManager):
//   CLASSPATH=<apk_path> /system/bin/app_process / \
//     com.voiceguard.shell.AudioCaptureMain <tcpPort>
//
// The class is loaded from the installed APK via app_process.
// It connects back to the TCP server started by ShellAudioSession and
// streams length-prefixed PCM16 chunks until the socket is closed.
object AudioCaptureMain {

    private const val SAMPLE_RATE  = 16_000
    private const val CHANNEL_MASK = AudioFormat.CHANNEL_IN_MONO
    private const val ENCODING     = AudioFormat.ENCODING_PCM_16BIT

    @JvmStatic
    fun main(args: Array<String>) {
        if (args.isEmpty()) {
            System.err.println("usage: AudioCaptureMain <tcpPort>")
            return
        }
        val port = args[0].toIntOrNull() ?: run {
            System.err.println("invalid port: ${args[0]}")
            return
        }

        val minBuf  = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_MASK, ENCODING)
        val bufSize = if (minBuf > 0) maxOf(minBuf, 3_200) else 3_200

        val record = tryCreateAudioRecord(bufSize) ?: run {
            System.err.println("no audio source available — all sources failed")
            return
        }

        try {
            Socket("127.0.0.1", port).use { socket ->
                val out = DataOutputStream(socket.getOutputStream())
                val buf = ByteArray(bufSize)

                record.startRecording()
                System.err.println("AudioCapture: streaming to 127.0.0.1:$port")

                // Warm-up drain: VOICE_DOWNLINK returns silence for a short
                // period after startRecording, and can come back briefly muted
                // when re-acquired right after a previous session released it.
                // Read and discard leading all-zero chunks (up to ~1.5 s) so the
                // first chunk the receiver sees is real audio — and so the HAL
                // has a moment to recover instead of streaming pure silence.
                val warmupDeadline = System.currentTimeMillis() + 1_500
                while (!socket.isClosed && System.currentTimeMillis() < warmupDeadline) {
                    val n = record.read(buf, 0, bufSize)
                    if (n <= 0) continue
                    if (!isAllZero(buf, n)) {
                        out.writeInt(n)
                        out.write(buf, 0, n)
                        out.flush()
                        break
                    }
                }

                while (!socket.isClosed) {
                    val n = record.read(buf, 0, bufSize)
                    if (n <= 0) break
                    out.writeInt(n)
                    out.write(buf, 0, n)
                    out.flush()
                }
            }
        } catch (e: Exception) {
            System.err.println("AudioCapture: ${e.message}")
        } finally {
            try { record.stop() } catch (_: Exception) {}
            record.release()
        }
    }

    private fun isAllZero(b: ByteArray, n: Int): Boolean {
        for (i in 0 until n) if (b[i] != 0.toByte()) return false
        return true
    }

    private fun tryCreateAudioRecord(bufSize: Int): AudioRecord? {
        // Priority order:
        //   VOICE_DOWNLINK (3) — remote caller's audio only (downlink path); ideal
        //   VOICE_CALL     (4) — both directions; acceptable fallback
        //   MIC            (1) — plain microphone; last resort
        // All three require CAPTURE_AUDIO_OUTPUT on a normal app, but shell UID 2000
        // is exempt from that audio policy check.
        for (source in intArrayOf(
            MediaRecorder.AudioSource.VOICE_DOWNLINK,
            MediaRecorder.AudioSource.VOICE_CALL,
            MediaRecorder.AudioSource.MIC
        )) {
            try {
                val r = AudioRecord(source, SAMPLE_RATE, CHANNEL_MASK, ENCODING, bufSize)
                if (r.state == AudioRecord.STATE_INITIALIZED) {
                    System.err.println("AudioCapture: using source $source")
                    return r
                }
                r.release()
            } catch (_: Exception) {
                // Source unavailable on this device/Android version; try next.
            }
        }
        return null
    }
}
