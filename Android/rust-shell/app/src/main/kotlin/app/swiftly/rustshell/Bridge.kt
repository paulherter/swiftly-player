package app.swiftly.rustshell

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import java.net.UnknownHostException
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.net.ssl.SSLException
import org.json.JSONObject

/**
 * What the Rust core calls on the platform (JNI, from `platform.rs`): the HTTP stack (system trust store, user CAs
 * and proxies apply because this is `HttpURLConnection`) and the secret store (AES-GCM key in the Android Keystore,
 * values in a private file).
 */
class Bridge(context: Context) {
    private val secretsFile = File(context.filesDir, "secrets.keystore.json")
    private val lock = Any()

    // ---- HTTP -------------------------------------------------------------------------------------------------
    /**
     * One complete exchange. Answer bytes: `S<status>\n`, header lines `name: value\n`, an empty line, the body.
     * A failure: `E<kind>\n<text>` with kind `net:<NSURLError code>`, `cert` or `cancelled`.
     */
    fun http(method: String, url: String, headers: Array<String>, body: ByteArray?, timeoutMs: Int): ByteArray {
        try {
            var target = url
            var verb = method
            var payload = body
            for (hop in 0..10) {
                val c = URL(target).openConnection() as HttpURLConnection
                try {
                    c.requestMethod = verb
                    c.instanceFollowRedirects = false
                    c.connectTimeout = if (timeoutMs > 0) timeoutMs else 15_000
                    c.readTimeout = if (timeoutMs > 0) timeoutMs else 60_000
                    c.useCaches = false
                    var i = 0
                    while (i + 1 < headers.size) { c.setRequestProperty(headers[i], headers[i + 1]); i += 2 }
                    if (payload != null && verb != "GET") {
                        c.doOutput = true
                        c.outputStream.use { it.write(payload) }
                    }
                    val status = c.responseCode
                    val location = c.getHeaderField("Location")
                    if (status in intArrayOf(301, 302, 303, 307, 308) && location != null && hop < 10) {
                        target = URL(URL(target), location).toString()
                        if (status == 303 || ((status == 301 || status == 302) && verb == "POST")) { verb = "GET"; payload = null }
                        continue
                    }
                    val out = ByteArrayOutputStream()
                    out.write("S$status\n".toByteArray())
                    for ((name, values) in c.headerFields) {
                        if (name == null) continue
                        for (v in values) out.write("$name: ${v.replace('\n', ' ')}\n".toByteArray())
                    }
                    out.write("x-final-url: $target\n\n".toByteArray())
                    val stream = if (status >= 400) c.errorStream else c.inputStream
                    stream?.use { it.copyTo(out) }
                    return out.toByteArray()
                } finally {
                    c.disconnect()
                }
            }
            return "Enet:-1005\ntoo many redirects".toByteArray()
        } catch (e: SocketTimeoutException) {
            return "Enet:-1001\n${e.message}".toByteArray()
        } catch (e: UnknownHostException) {
            return "Enet:-1003\n${e.message}".toByteArray()
        } catch (e: SSLException) {
            return "Ecert\n${e.message}".toByteArray()
        } catch (e: java.net.ConnectException) {
            return "Enet:-1004\n${e.message}".toByteArray()
        } catch (e: java.io.IOException) {
            return "Enet:-1005\n${e.message}".toByteArray()
        } catch (e: Exception) {
            return "Enet:-1\n${e.message}".toByteArray()
        }
    }

    // ---- Secrets ----------------------------------------------------------------------------------------------
    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return gen.generateKey()
    }

    private fun seal(text: String): String {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, key())
        return Base64.encodeToString(c.iv, Base64.NO_WRAP) + ":" + Base64.encodeToString(c.doFinal(text.toByteArray()), Base64.NO_WRAP)
    }

    private fun open(sealed: String): String? = try {
        val (iv, data) = sealed.split(":")
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(iv, Base64.NO_WRAP)))
        String(c.doFinal(Base64.decode(data, Base64.NO_WRAP)))
    } catch (e: Exception) { null }

    private fun read(): JSONObject = try { JSONObject(secretsFile.readText()) } catch (e: Exception) { JSONObject() }

    fun secretGet(name: String): String? = synchronized(lock) { read().optString(name, "").takeIf { it.isNotEmpty() }?.let { open(it) } }

    fun secretSet(name: String, value: String) = synchronized(lock) {
        val j = read(); j.put(name, seal(value))
        val tmp = File(secretsFile.path + ".tmp"); tmp.writeText(j.toString()); tmp.renameTo(secretsFile); Unit
    }

    fun secretRemove(name: String) = synchronized(lock) {
        val j = read(); j.remove(name)
        val tmp = File(secretsFile.path + ".tmp"); tmp.writeText(j.toString()); tmp.renameTo(secretsFile); Unit
    }

    private companion object { const val ALIAS = "swiftly.secrets.v1" }
}
