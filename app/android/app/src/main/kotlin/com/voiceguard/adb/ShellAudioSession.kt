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
        private const val SEGMENT_SECS = 5
        private val SEGMENT_BYTES      = SAMPLE_RATE * BYTES_PER * SEGMENT_SECS  // 160 000
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
            var firstChunk  = true

            while (running && !client.isClosed) {
                val chunkLen = try {
                    din.readInt()
                } catch (_: EOFException) {
                    break
                }
                if (chunkLen <= 0 || chunkLen > 65_536) break

                val chunk = ByteArray(chunkLen)
                din.readFully(chunk)

                // Detect hardware mute — same criterion as VadProcessor.
                if (firstChunk && chunk.all { it == 0.toByte() }) {
                    Log.w(TAG, "All PCM samples zero — VOICE_DOWNLINK blocked on this device")
                    onBlocked?.invoke()
                    break
                }
                firstChunk = false

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
