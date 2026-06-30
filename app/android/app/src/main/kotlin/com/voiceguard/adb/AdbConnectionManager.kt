package com.voiceguard.adb

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.util.Log
import io.github.muntashirakon.adb.AbsAdbConnectionManager
import org.conscrypt.Conscrypt
import java.io.File
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.Security
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Date

class AdbConnectionManager private constructor(ctx: Context)
    : AbsAdbConnectionManager() {

    companion object {
        private const val TAG      = "AdbManager"
        private const val PREFS    = "voiceguard_adb"
        private const val K_PORT   = "main_port"
        private const val K_PAIRED = "is_paired"

        @Volatile private var INSTANCE: AdbConnectionManager? = null

        fun getInstance(context: Context): AdbConnectionManager =
            INSTANCE ?: synchronized(this) {
                INSTANCE ?: AdbConnectionManager(context.applicationContext)
                    .also { INSTANCE = it }
            }
    }

    private val appContext: Context            = ctx.applicationContext
    private val prefs: SharedPreferences       =
        appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val keyFile                        = File(appContext.filesDir, "vg_adb_key.der")
    private val certFile                       = File(appContext.filesDir, "vg_adb_cert.der")

    private lateinit var _privateKey: PrivateKey
    private lateinit var _certificate: X509Certificate

    init {
        // Conscrypt is required for TLS connections used by Android 11+ wireless debugging.
        if (Security.getProvider("Conscrypt") == null) {
            runCatching { Security.insertProviderAt(Conscrypt.newProvider(), 1) }
        }
        setApi(Build.VERSION.SDK_INT)
        loadOrGenerateKeys()
    }

    // ── AbsAdbConnectionManager abstract members ──────────────────────────────

    override fun getPrivateKey(): PrivateKey       = _privateKey
    override fun getCertificate(): X509Certificate = _certificate
    override fun getDeviceName(): String            = "VoiceGuard"

    // ── Key / certificate persistence ─────────────────────────────────────────

    private fun loadOrGenerateKeys() {
        if (keyFile.exists() && certFile.exists()) {
            runCatching {
                _privateKey = KeyFactory.getInstance("RSA")
                    .generatePrivate(PKCS8EncodedKeySpec(keyFile.readBytes()))
                _certificate = CertificateFactory.getInstance("X.509")
                    .generateCertificate(certFile.inputStream()) as X509Certificate
                return
            }.onFailure { Log.w(TAG, "Key load failed, regenerating: ${it.message}") }
        }
        generateKeys()
    }

    private fun generateKeys() {
        val kpg = KeyPairGenerator.getInstance("RSA")
        kpg.initialize(2048, SecureRandom.getInstance("SHA1PRNG"))
        val kp = kpg.generateKeyPair()
        keyFile.writeBytes(kp.private.encoded)
        _privateKey = kp.private
        _certificate = buildSelfSignedCert(kp)
        certFile.writeBytes(_certificate.encoded)
        Log.d(TAG, "Generated new RSA key pair for ADB")
    }

    private fun buildSelfSignedCert(kp: java.security.KeyPair): X509Certificate {
        val now   = Date()
        val until = Date(System.currentTimeMillis() + 10L * 365 * 24 * 3_600_000)
        val dn    = org.bouncycastle.asn1.x500.X500Name("CN=VoiceGuard")
        val serial = BigInteger.valueOf(System.currentTimeMillis())
        val builder = org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder(
            dn, serial, now, until, dn, kp.public)
        val signer = org.bouncycastle.operator.jcajce.JcaContentSignerBuilder("SHA256withRSA")
            .build(kp.private)
        return org.bouncycastle.cert.jcajce.JcaX509CertificateConverter()
            .getCertificate(builder.build(signer))
    }

    // ── Public API (called from MainActivity MethodChannel handlers) ──────────

    val isPaired: Boolean get() = prefs.getBoolean(K_PAIRED, false) && keyFile.exists()
    val savedPort: Int    get() = prefs.getInt(K_PORT, -1)

    override fun pair(pairingPort: Int, code: String): Boolean {
        return try {
            super.pair(pairingPort, code)
            prefs.edit().putBoolean(K_PAIRED, true).apply()
            Log.i(TAG, "Paired on port $pairingPort")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Pairing failed: ${e.message}")
            false
        }
    }

    fun savePort(port: Int) {
        prefs.edit().putInt(K_PORT, port).apply()
    }

    @Synchronized
    fun testConnection(): Boolean {
        val port = savedPort
        if (port < 0 || !keyFile.exists()) return false
        return try {
            connect("127.0.0.1", port)
            val ok = isConnected
            disconnect()
            ok
        } catch (e: Exception) {
            Log.e(TAG, "Connection test failed: ${e.message}")
            runCatching { disconnect() }
            false
        }
    }

    @Synchronized
    fun launchAudioBridge(tcpPort: Int): Boolean {
        if (!keyFile.exists()) return false

        // Try the saved port first. Android rotates the wireless-debugging port
        // whenever the network changes (new Wi-Fi, reconnect, reboot), which
        // leaves savedPort stale and makes connect() fail with a null message.
        // On failure we re-discover the live port via mDNS and retry once — the
        // pairing keys persist across port changes, so no re-pairing is needed.
        if (tryLaunchOnce(savedPort, tcpPort)) return true

        Log.w(TAG, "Bridge launch failed on saved port $savedPort — re-discovering ADB port")
        val fresh = rediscoverPortBlocking()
        if (fresh != null && fresh > 0) {
            savePort(fresh)
            Log.i(TAG, "Re-discovered live ADB port: $fresh")
            if (tryLaunchOnce(fresh, tcpPort)) return true
        }
        Log.e(TAG, "Bridge launch failed — could not reach adbd (is Wireless Debugging on?)")
        return false
    }

    private fun tryLaunchOnce(port: Int, tcpPort: Int): Boolean {
        if (port < 0) return false
        return try {
            val apkPath = appContext.packageCodePath
            // setsid creates a new session so the audio process survives ADB disconnect.
            // </dev/null >/dev/null 2>&1 & detaches all stdio and backgrounds it.
            val cmd = "setsid sh -c 'CLASSPATH=\"$apkPath\" " +
                "/system/bin/app_process / com.voiceguard.shell.AudioCaptureMain $tcpPort " +
                "</dev/null >/dev/null 2>&1 &'"
            connect("127.0.0.1", port)
            val stream = openStream("shell:$cmd")
            // The outer setsid sh exits immediately after backgrounding app_process,
            // so the stream closes on its own within ~500 ms.
            Thread.sleep(600)
            runCatching { stream.close() }
            disconnect()
            Log.i(TAG, "Audio bridge launched → tcp:$tcpPort (adb port $port)")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Bridge launch failed on port $port: ${e.message}")
            runCatching { disconnect() }
            false
        }
    }

    // Blocks the calling (background) thread while mDNS resolves the current
    // _adb-tls-connect._tcp port. Safe here because launchAudioBridge runs on
    // ShellAudioSession's worker thread, never the UI thread.
    private fun rediscoverPortBlocking(): Int? {
        val latch = java.util.concurrent.CountDownLatch(1)
        val result = java.util.concurrent.atomic.AtomicInteger(-1)
        NsdDiscovery.findMainPort(appContext, 8_000L) { port ->
            if (port != null) result.set(port)
            latch.countDown()
        }
        return try {
            latch.await(10, java.util.concurrent.TimeUnit.SECONDS)
            result.get().takeIf { it > 0 }
        } catch (_: InterruptedException) {
            null
        }
    }

    fun reset() {
        runCatching { disconnect() }
        prefs.edit().remove(K_PAIRED).remove(K_PORT).apply()
        keyFile.delete()
        certFile.delete()
        INSTANCE = null
        // Fresh key pair will be generated on the next getInstance() call.
    }
}
