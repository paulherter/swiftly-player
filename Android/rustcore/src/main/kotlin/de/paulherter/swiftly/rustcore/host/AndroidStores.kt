package de.paulherter.swiftly.rustcore.host

import android.content.Context
import android.content.SharedPreferences
import de.paulherter.swiftly.rustcore.KeyValueStore
import de.paulherter.swiftly.rustcore.LanguageNames
import de.paulherter.swiftly.rustcore.Platform
import de.paulherter.swiftly.rustcore.SecretStore
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Plain string storage under the host stores: `SharedPreferences` on a device, a map in tests. */
interface StringPrefs {
    fun get(key: String): String?
    fun put(key: String, value: String)
    fun remove(key: String)
    /** Every key held (the settings store lists only the ones it knows). */
    fun keys(): Set<String> = emptySet()
}

class SharedStringPrefs(private val prefs: SharedPreferences) : StringPrefs {
    override fun get(key: String): String? = prefs.getString(key, null)
    override fun put(key: String, value: String) = prefs.edit().putString(key, value).apply()
    override fun remove(key: String) = prefs.edit().remove(key).apply()
    override fun keys(): Set<String> = prefs.all.keys.toSet()
}

/**
 * AES-GCM with the format of the old `Vault`: Base64 (no wrap) of the 12-byte IV followed by the ciphertext.
 * Old and new builds read each other's values, so this must not change. If a value cannot be decrypted (key gone
 * after a restore) it counts as absent.
 */
class GcmSealer(private val key: () -> SecretKey) {
    fun seal(clear: String, iv: ByteArray? = null): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        if (iv == null) cipher.init(Cipher.ENCRYPT_MODE, key()) else cipher.init(Cipher.ENCRYPT_MODE, key(), GCMParameterSpec(128, iv))
        return java.util.Base64.getEncoder().encodeToString(cipher.iv + cipher.doFinal(clear.toByteArray(Charsets.UTF_8)))
    }

    fun open(sealed: String): String? = runCatching {
        val all = java.util.Base64.getDecoder().decode(sealed)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, all, 0, 12))
        String(cipher.doFinal(all, 12, all.size - 12), Charsets.UTF_8)
    }.getOrNull()

    companion object {
        /** The Keystore key of the old app (alias unchanged, so existing installs keep their sign-in). */
        const val KEYSTORE_ALIAS = "de.paulherter.swiftly.sitzung"

        fun keystore(): GcmSealer = GcmSealer {
            val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            (store.getKey(KEYSTORE_ALIAS, null) as? SecretKey) ?: run {
                val gen = KeyGenerator.getInstance(android.security.keystore.KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
                gen.init(
                    android.security.keystore.KeyGenParameterSpec.Builder(
                        KEYSTORE_ALIAS,
                        android.security.keystore.KeyProperties.PURPOSE_ENCRYPT or android.security.keystore.KeyProperties.PURPOSE_DECRYPT,
                    )
                        .setBlockModes(android.security.keystore.KeyProperties.BLOCK_MODE_GCM)
                        .setEncryptionPaddings(android.security.keystore.KeyProperties.ENCRYPTION_PADDING_NONE)
                        .build(),
                )
                gen.generateKey()
            }
        }
    }
}

/**
 * The core's secrets: the account bundles (`konten`, `konten.emby`, ...), the session (`sitzung`) and the other
 * names it keeps. Same place and format as the old `Store.vaultRead/vaultWrite`: preference key `<name>.tresor` in
 * the `swiftly` file, sealed with [GcmSealer]. A plaintext `sitzung` from very old builds is migrated on the first
 * read. Decrypted once per process (the Keystore is a service call).
 */
class AndroidSecretStore(private val prefs: StringPrefs, private val sealer: GcmSealer) : SecretStore {
    private val clear = HashMap<String, String?>()

    override fun get(name: String): String? = synchronized(clear) {
        if (name == "sitzung") prefs.get("sitzung")?.let { plain -> set(name, plain); prefs.remove("sitzung"); return plain }
        if (clear.containsKey(name)) return clear[name]
        val value = prefs.get("$name.tresor")?.let { sealer.open(it) }
        clear[name] = value
        value
    }

    override fun set(name: String, value: String) = synchronized(clear) {
        clear[name] = value
        prefs.put("$name.tresor", sealer.seal(value))
    }

    override fun remove(name: String) = synchronized(clear) {
        clear[name] = null
        prefs.remove("$name.tresor")
    }

    companion object {
        fun of(context: Context) = AndroidSecretStore(
            SharedStringPrefs(context.getSharedPreferences("swiftly", Context.MODE_PRIVATE)),
            GcmSealer.keystore(),
        )
    }
}

/**
 * The core's small values as bytes (home snapshot, named blobs of `swiftly-library`). New data: its own
 * preference file `swiftly-core`, Base64 values, so it never collides with the old keys.
 */
class AndroidKeyValueStore(private val prefs: StringPrefs) : KeyValueStore {
    override fun get(key: String): ByteArray? = prefs.get(key)?.let { runCatching { java.util.Base64.getDecoder().decode(it) }.getOrNull() }
    override fun set(key: String, value: ByteArray) = prefs.put(key, java.util.Base64.getEncoder().encodeToString(value))
    override fun remove(key: String) = prefs.remove(key)

    companion object {
        fun of(context: Context) = AndroidKeyValueStore(SharedStringPrefs(context.getSharedPreferences("swiftly-core", Context.MODE_PRIVATE)))
    }
}

/** Where the core keeps disposable files and how it names this device; the log goes to logcat and the share buffer. */
class AndroidPlatform(
    private val deviceName: String,
    private val cacheDir: String?,
    private val logLine: (String) -> Unit,
) : Platform {
    override fun deviceName(): String = deviceName
    override fun log(line: String) = logLine(line)
    override fun cacheDir(): String? = cacheDir

    companion object {
        fun of(context: Context, logLine: (String) -> Unit) =
            AndroidPlatform(android.os.Build.MODEL ?: "Android", context.cacheDir.absolutePath, logLine)
    }
}

/**
 * The system's language names for track lists (`LanguageNames`): "German" for an English interface, "Deutsch" for a
 * German one, as `Locale.localizedString(forLanguageCode:)` gives on Apple. `java.util.Locale` hands the code back
 * when it does not know it; that counts as no answer, so the core's built-in table (ISO 639 names in de/en/ru) answers.
 */
class AndroidLanguageNames : LanguageNames {
    private fun name(code: String, inLanguage: java.util.Locale): String? {
        val tag = code.replace('_', '-')
        val locale = java.util.Locale.forLanguageTag(tag)
        if (locale.language.isEmpty()) return null
        val text = locale.getDisplayLanguage(inLanguage)
        val bare = tag.substringBefore('-')
        return text.takeIf { it.isNotBlank() && !it.equals(bare, ignoreCase = true) }
    }

    override fun languageName(code: String, language: String): String? =
        name(code, java.util.Locale.forLanguageTag(language))

    override fun knowsLanguage(code: String): Boolean = name(code, java.util.Locale.ENGLISH) != null
}
