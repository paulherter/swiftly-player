package de.paulherter.swiftly

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.security.KeyChain
import android.system.Os
import android.util.Log
import java.io.File
import java.security.KeyStore

/**
 * Custom certificate authorities for the core and for VLC too.
 *
 * `netz_vertrauen.xml` makes Android trust certificates the user installed, but that only applies
 * to Kotlin (Coil, downloads). Sign-in and all Jellyfin requests go through the Swift core:
 * `URLSession` from swift-corelibs-foundation, which uses libcurl with BoringSSL underneath. On
 * Android that reads only `/apex/com.android.conscrypt/cacerts` (Android 14+, before that
 * `/system/etc/security/cacerts`); user certificates live elsewhere, which an app may not read.
 * Result: "SSL certificate problem: unable to get local issuer certificate", shown as "The
 * server's certificate is not trusted" although Chrome on the same device connects.
 *
 * So at startup the whole Android store (system and user, `AndroidCAStore`) is written as a PEM
 * bundle and Foundation is pointed at it. Foundation reads `URLSessionCertificateAuthorityInfoFile`
 * on every new connection (`EasyHandle.setCARootBundlePath`) and sets it as `CURLOPT_CAINFO`. VLC
 * gets the same folder as `--gnutls-dir-trust`; otherwise GnuTLS finds only the system store.
 *
 * Only if the user has installed their own certificates. Without them everything stays at the
 * default, which is proven. Rejected: pointing the variable at the folder
 * `/system/etc/security/cacerts`; it expects a file, and every connection failed.
 *
 * Also while the app runs. If the authority is added after startup (settings, back to the app,
 * "Connect"), the same error persisted until the app was fully quit. So
 * `KeyChain.ACTION_TRUST_STORE_CHANGED` rewrites the bundle; Foundation reads the variable on
 * every new connection (`getenv`). When the last custom certificate is gone, the variable is
 * removed: otherwise it pointed at a deleted file and curl rejected every https connection.
 */
object Certificates {
    /** Folder with the bundle, for VLC. `null` without custom certificates. */
    @Volatile var folder: String? = null
        private set

    private const val VARIABLE = "URLSessionCertificateAuthorityInfoFile"

    /** Once at startup: rewrite the bundle on every change to the certificate store. */
    fun observe(context: Context) {
        val app = context.applicationContext
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, intent: Intent) {
                // From the main thread: the store reads files.
                Thread { readySet(app) }.start()
            }
        }
        val filter = IntentFilter(KeyChain.ACTION_TRUST_STORE_CHANGED)
        // System broadcast, only sent by the system, so not exported is enough. Lives as long as the process.
        androidx.core.content.ContextCompat.registerReceiver(app, receiver, filter,
            androidx.core.content.ContextCompat.RECEIVER_NOT_EXPORTED)
    }

    /** Call before the core's first request, at app start. */
    @Synchronized
    fun readySet(context: Context) {
        val store = File(context.filesDir, "zertifikate")
        try {
            val cache = KeyStore.getInstance("AndroidCAStore").apply { load(null) }
            val names = cache.aliases().toList()
            val ownOnes = names.count { it.startsWith("user:") }
            if (ownOnes == 0) {
                // Variable first, then the file; otherwise it briefly points at nothing.
                Os.unsetenv(VARIABLE)
                folder = null
                if (store.exists()) store.deleteRecursively()
                Log.i("Swiftly", "Zertifikate: keine eigenen, der Kern nimmt den Systemspeicher")
                return
            }
            val encoder = java.util.Base64.getMimeEncoder(64, "\n".toByteArray())
            val text = StringBuilder()
            for (name in names) {
                val certificate = cache.getCertificate(name) ?: continue
                text.append("-----BEGIN CERTIFICATE-----\n")
                    .append(encoder.encodeToString(certificate.encoded))
                    .append("\n-----END CERTIFICATE-----\n")
            }
            store.mkdirs()
            val target = File(store, "alle.pem")
            val new = File(store, "alle.pem.neu")
            new.writeText(text.toString())
            if (!new.renameTo(target)) { new.copyTo(target, overwrite = true); new.delete() }
            Os.setenv(VARIABLE, target.absolutePath, true)
            folder = store.absolutePath
            Log.i("Swiftly", "Zertifikate: ${names.size - ownOnes} System, $ownOnes eigene — Bündel für Kern und VLC")
        } catch (e: Exception) {
            Log.w("Swiftly", "Zertifikate: Bündel nicht angelegt, der Kern nimmt den Systemspeicher", e)
        }
    }
}
