package de.paulherter.swiftly.rustcore.host

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

private class MapPrefs : StringPrefs {
    val map = HashMap<String, String>()
    override fun get(key: String) = map[key]
    override fun put(key: String, value: String) { map[key] = value }
    override fun remove(key: String) { map.remove(key) }
}

/** Data written by the old app (the `Vault` of SwiftlyApplication.kt) must open in the new one and the other way round. */
class StoresTest {
    private val key = SecretKeySpec(ByteArray(32) { it.toByte() }, "AES")
    private val sealer = GcmSealer { key }

    /** The old `Vault.encrypt`, copied literally, with a fixed IV. */
    private fun oldEncrypt(clear: String, iv: ByteArray): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(128, iv))
        val data = cipher.doFinal(clear.toByteArray(Charsets.UTF_8))
        return java.util.Base64.getEncoder().encodeToString(iv + data)
    }

    @Test fun oldAccountBundleOpensInTheNewSecretStore() {
        val prefs = MapPrefs()
        val bundle = """{"konten":[{"name":"anna","key":"k1"}]}"""
        prefs.put("konten.tresor", oldEncrypt(bundle, ByteArray(12) { 7 }))
        assertEquals(bundle, AndroidSecretStore(prefs, sealer).get("konten"))
    }

    @Test fun newSecretsOpenInTheOldVaultFormat() {
        val prefs = MapPrefs()
        AndroidSecretStore(prefs, sealer).set("konten.emby", "geheim")
        val all = java.util.Base64.getDecoder().decode(prefs.get("konten.emby.tresor"))
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, all, 0, 12))
        assertEquals("geheim", String(cipher.doFinal(all, 12, all.size - 12), Charsets.UTF_8))
    }

    @Test fun deterministicSealMatchesTheOldFormatByteForByte() {
        val iv = ByteArray(12) { 3 }
        assertEquals(oldEncrypt("x", iv), sealer.seal("x", iv))
    }

    @Test fun plaintextSessionFromVeryOldBuildsIsMigrated() {
        val prefs = MapPrefs().also { it.put("sitzung", "token-alt") }
        val store = AndroidSecretStore(prefs, sealer)
        assertEquals("token-alt", store.get("sitzung"))
        assertNull(prefs.get("sitzung"))
        assertEquals("token-alt", AndroidSecretStore(prefs, sealer).get("sitzung"))
    }

    @Test fun undecryptableValueCountsAsAbsentAndRemoveWorks() {
        val prefs = MapPrefs().also { it.put("konten.tresor", "kaputt") }
        val store = AndroidSecretStore(prefs, sealer)
        assertNull(store.get("konten"))
        store.set("konten", "neu"); assertEquals("neu", store.get("konten"))
        store.remove("konten"); assertNull(store.get("konten")); assertNull(prefs.get("konten.tresor"))
    }

    @Test fun keyValueStoreRoundTripsBytes() {
        val kv = AndroidKeyValueStore(MapPrefs())
        assertNull(kv.get("home.1"))
        kv.set("home.1", byteArrayOf(0, 1, 2, -1))
        assertArrayEquals(byteArrayOf(0, 1, 2, -1), kv.get("home.1"))
        kv.remove("home.1"); assertNull(kv.get("home.1"))
    }
}
