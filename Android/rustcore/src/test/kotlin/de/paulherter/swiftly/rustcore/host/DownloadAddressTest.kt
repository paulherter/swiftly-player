package de.paulherter.swiftly.rustcore.host

import de.paulherter.swiftly.rustcore.AccountRef
import de.paulherter.swiftly.rustcore.Core
import de.paulherter.swiftly.rustcore.ServerKind
import org.junit.Assert.assertTrue
import org.junit.Test
import javax.crypto.spec.SecretKeySpec

/** The core answers the file address the old `Kern.downloadAddress` gave: plain stream for the original, converting otherwise. */
class DownloadAddressTest {
    private class Mem : StringPrefs {
        val m = HashMap<String, String>()
        override fun get(key: String) = m[key]
        override fun put(key: String, value: String) { m[key] = value }
        override fun remove(key: String) { m.remove(key) }
    }

    private val core = Core(
        AndroidPlatform("Test", null) {},
        AndroidSecretStore(Mem(), GcmSealer { SecretKeySpec(ByteArray(32), "AES") }),
        AndroidKeyValueStore(Mem()),
        AndroidHttpClient(),
    )
    private val account = AccountRef("https://s.example", "u1", "TOKEN", ServerKind.JELLYFIN, "dev")

    @Test fun originalIsThePlainStreamAddress() {
        val url = core.downloadAddress(account, "de", "i1", "s1", "original", null)
        assertTrue(url, url.startsWith("https://s.example/Videos/i1/stream"))
        assertTrue(url, url.contains("ApiKey=TOKEN") && url.contains("mediaSourceId=s1") && url.contains("static=true"))
    }

    @Test fun lowerQualityConvertsToMkv() {
        val url = core.downloadAddress(account, "de", "i1", null, "hd720", null)
        assertTrue(url, url.contains("static=false") && url.contains("container=mkv") && url.contains("720"))
    }
}
