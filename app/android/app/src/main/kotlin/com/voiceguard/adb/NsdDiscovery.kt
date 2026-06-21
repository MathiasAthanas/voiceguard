package com.voiceguard.adb

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Discovers ADB wireless debugging services via mDNS (DNS-SD).
 *
 * Android broadcasts two service types when Wireless Debugging is active:
 *   _adb-tls-pairing._tcp  — only while "Pair device with pairing code" dialog is open
 *   _adb-tls-connect._tcp  — always, while Wireless Debugging is enabled
 *
 * This is the same mechanism Android Studio uses to find devices without USB.
 * No special permissions are required beyond ACCESS_NETWORK_STATE.
 */
object NsdDiscovery {
    private const val TAG = "NsdDiscovery"

    /** Auto-discovers the one-time pairing port. Only active while the
     *  "Pair device with pairing code" dialog is open in Developer Options.
     *  [onResult] fires on the main thread with the port, or null on timeout. */
    fun findPairingPort(
        context: Context,
        timeoutMs: Long = 60_000L,
        onResult: (Int?) -> Unit,
    ) = findFirst(context, "_adb-tls-pairing._tcp", timeoutMs, onResult)

    /** Auto-discovers the persistent main ADB connection port. Always broadcasting
     *  when Wireless Debugging is enabled.
     *  [onResult] fires on the main thread with the port, or null on timeout. */
    fun findMainPort(
        context: Context,
        timeoutMs: Long = 15_000L,
        onResult: (Int?) -> Unit,
    ) = findFirst(context, "_adb-tls-connect._tcp", timeoutMs, onResult)

    private fun findFirst(
        context: Context,
        serviceType: String,
        timeoutMs: Long,
        onResult: (Int?) -> Unit,
    ) {
        val nsd  = context.getSystemService(Context.NSD_SERVICE) as NsdManager
        val main = Handler(Looper.getMainLooper())
        val done = AtomicBoolean(false)
        var listener: NsdManager.DiscoveryListener? = null

        fun finish(port: Int?) {
            if (!done.compareAndSet(false, true)) return
            try { listener?.let { nsd.stopServiceDiscovery(it) } } catch (_: Exception) {}
            main.post { onResult(port) }
        }

        listener = object : NsdManager.DiscoveryListener {
            override fun onStartDiscoveryFailed(st: String, err: Int) {
                Log.w(TAG, "Discovery start failed [$serviceType]: $err")
                finish(null)
            }
            override fun onStopDiscoveryFailed(st: String, err: Int) {}
            override fun onDiscoveryStarted(st: String)  { Log.d(TAG, "Scanning: $st") }
            override fun onDiscoveryStopped(st: String)  {}
            override fun onServiceLost(info: NsdServiceInfo) {}

            override fun onServiceFound(info: NsdServiceInfo) {
                nsd.resolveService(info, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(si: NsdServiceInfo, err: Int) {
                        Log.w(TAG, "Resolve failed: $err")
                    }
                    override fun onServiceResolved(si: NsdServiceInfo) {
                        Log.d(TAG, "Found $serviceType → port ${si.port}")
                        finish(si.port)
                    }
                })
            }
        }

        nsd.discoverServices(serviceType, NsdManager.PROTOCOL_DNS_SD, listener)
        main.postDelayed({ finish(null) }, timeoutMs)
    }
}
