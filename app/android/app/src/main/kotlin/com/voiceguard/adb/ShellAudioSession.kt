package com.voiceguard.adb

import android.content.Context
import android.util.Log
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.File
import java.io.FileOutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.nio.ByteBuffer
import java.nio.ByteOrder

class ShellAudioSession(
    private val context: Context,
    private val adbManager: AdbConnectionManager
) {

    companion object {
        private const val TAG          = "ShellAudioSession"
        private const val SAMPLE_RATE  = 16_000
        private const val BYTES_PER    = 2          // PCM16
        // 8 s window (was 5): VAD drops silence, so a longer window yields more
        // net speech per verification — short clips give unstable, gender-level
        // embeddings that let same-gender impostors pass.
        private const val SEGMENT_SECS = 8
        private val SEGMENT_BYTES      = SAMPLE_RATE * BYTES_PER * SEGMENT_SECS  // 256 000
        // VOICE_DOWNLINK emits silence while the HAL warms up after
        // startRecording — longer right after a previous session released it.
        // Tolerate this much leading silence before declaring the mic blocked.
        private const val BLOCKED_WARMUP_MS = 3_000L
    }

    @Volatile private var running = false
    private var serverSocket: ServerSocket? = null
    private var sessionThread: Thread? = null

    // Callbacks invoked from the session thread — callers must post to main thread.
    var onSegmentReady: ((String) -> Unit)? = null
    var onBlocked: (() -> Unit)? = null

    // ── Public API ────────────────────────────────────────────────────────────

    fun start(): Boolean {
        if (running) return true
        if (!adbManager.isPaired || adbManager.savedPort < 0) {
            Log.w(TAG, "ADB not configured — cannot start shell audio")
            return false
        }

        val server = ServerSocket()
        server.bind(InetSocketAddress("127.0.0.1", 0))
        // Allow up to 10 s for AudioCaptureMain to connect after the ADB command.
        server.soTimeout = 10_000
        serverSocket = server
        val tcpPort = server.localPort
        Log.d(TAG, "TCP server bound on 127.0.0.1:$tcpPort")

        running = true
        sessionThread = Thread({
            // Blocking network operation — runs on this background thread.
            if (!adbManager.launchAudioBridge(tcpPort)) {
                Log.e(TAG, "Failed to launch audio bridge")
                running = false
                safeClose(server)
                onBlocked?.invoke()
                return@Thread
            }
            runSession(server)
        }, "vg-shell-audio").also {
            it.isDaemon = true
            it.start()
        }
        return true
    }

    fun stop() {
        running = false
        safeClose(serverSocket)
        serverSocket = null
        sessionThread?.interrupt()
        sessionThread = null
        onSegmentReady = null
        onBlocked = null
    }

    // ── Session loop ──────────────────────────────────────────────────────────

    private fun runSession(server: ServerSocket) {
        try {
            Log.d(TAG, "Waiting for AudioCaptureMain to connect…")
            val client = server.accept()
            Log.i(TAG, "AudioCaptureMain connected")

            val din      = DataInputStream(BufferedInputStream(client.getInputStream()))
            val segBuf   = ByteArrayOutputStream(SEGMENT_BYTES)
            var accumulated = 0
            // Until the first non-silent chunk arrives we are in the warm-up
            // window: leading all-zero chunks are dropped, not accumulated, and
            // are NOT treated as a blocked mic unless the whole window elapses
            // with no audio. This stops a cold first chunk from aborting the
            // session and forcing a churn of respawns that each start cold too.
            var sawAudio = false
            val warmupDeadlineMs = System.currentTimeMillis() + BLOCKED_WARMUP_MS

            while (running && !client.isClosed) {
                val chunkLen = try {
                    din.readInt()
                } catch (_: EOFException) {
                    break
                }
                if (chunkLen <= 0 || chunkLen > 65_536) break

                val chunk = ByteArray(chunkLen)
                din.readFully(chunk)

                if (!sawAudio) {
                    if (chunk.all { it == 0.toByte() }) {
                        // Still warming up — drop the silent chunk. Only give up
                        // if the entire warm-up window passed with no real audio.
                        if (System.currentTimeMillis() >= warmupDeadlineMs) {
                            Log.w(TAG, "No audio within warm-up window — VOICE_DOWNLINK blocked on this device")
                            onBlocked?.invoke()
                            break
                        }
                        continue
                    }
                    // First real audio — begin the segment here.
                    sawAudio = true
                }

                segBuf.write(chunk)
                accumulated += chunkLen

                if (accumulated >= SEGMENT_BYTES) {
                    flushSegment(segBuf.toByteArray())
                    segBuf.reset()
                    accumulated = 0
                }
            }
        } catch (e: Exception) {
            if (running) Log.e(TAG, "Session error: ${e.message}")
        } finally {
            safeClose(server)
            Log.d(TAG, "Session ended")
        }
    }

    // ── WAV output ────────────────────────────────────────────────────────────

    private fun flushSegment(pcm: ByteArray) {
        val file = File(context.cacheDir, "vg_shell_${System.currentTimeMillis()}.wav")
        try {
            FileOutputStream(file).use { fos ->
                fos.write(buildWavHeader(pcm.size))
                fos.write(pcm)
            }
            onSegmentReady?.invoke(file.absolutePath)
        } catch (e: Exception) {
            Log.e(TAG, "WAV write failed: ${e.message}")
            file.delete()
        }
    }

    private fun buildWavHeader(dataLen: Int): ByteArray {
        val buf = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        buf.put("RIFF".toByteArray(Charsets.US_ASCII))
        buf.putInt(dataLen + 36)
        buf.put("WAVE".toByteArray(Charsets.US_ASCII))
        buf.put("fmt ".toByteArray(Charsets.US_ASCII))
        buf.putInt(16)
        buf.putShort(1.toShort())              // PCM
        buf.putShort(1.toShort())              // mono
        buf.putInt(SAMPLE_RATE)
        buf.putInt(SAMPLE_RATE * BYTES_PER)    // byte rate
        buf.putShort(BYTES_PER.toShort())      // block align
        buf.putShort(16.toShort())             // bits per sample
        buf.put("data".toByteArray(Charsets.US_ASCII))
        buf.putInt(dataLen)
        return buf.array()
    }

    private fun safeClose(closeable: AutoCloseable?) {
        try { closeable?.close() } catch (_: Exception) {}
    }
}
