package de.paulherter.swiftly.rustcore.host

import de.paulherter.swiftly.rustcore.Core
import de.paulherter.swiftly.rustcore.HomeIntent
import de.paulherter.swiftly.rustcore.ServerKind
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import javax.crypto.spec.SecretKeySpec

/**
 * The Rust core on the JVM (JNA, host cdylib from `Werkzeuge/rust-kern-android.sh host`) with the Kotlin host traits:
 * sign in, persist in the old secret format, load Home. Needs the fixture server:
 * `cargo run -p xtask -- fixture-server --port 8099` and `SWIFTLY_FIXTURE_URL=http://127.0.0.1:8099`; skipped without it.
 */
class CoreFixtureTest {
    private val url = System.getenv("SWIFTLY_FIXTURE_URL")
    private val prefs = object : StringPrefs {
        val map = HashMap<String, String>()
        override fun get(key: String) = map[key]
        override fun put(key: String, value: String) { map[key] = value }
        override fun remove(key: String) { map.remove(key) }
    }
    private val sealer = GcmSealer { SecretKeySpec(ByteArray(32) { 9 }, "AES") }
    private val logs = ArrayList<String>()

    private fun core() = Core(
        AndroidPlatform("Test-Pixel", null) { logs += it },
        AndroidSecretStore(prefs, sealer),
        AndroidKeyValueStore(MapKv),
        AndroidHttpClient(),
    )

    private object MapKv : StringPrefs {
        val map = HashMap<String, String>()
        override fun get(key: String) = map[key]
        override fun put(key: String, value: String) { map[key] = value }
        override fun remove(key: String) { map.remove(key) }
    }

    @Test fun signInPersistsAndHomeLoads() = runBlocking {
        assumeTrue("no SWIFTLY_FIXTURE_URL", url != null)
        val core = core()
        assertTrue(logs.any { it.contains("core: created") })
        val accounts = core.accountsModel("test-device", "de")
        val signed = accounts.signIn(url!!, ServerKind.JELLYFIN, "demo", "demo")
        assertEquals("fixture-token", signed.account.token)
        // The account bundle is in the old place and format: `konten.tresor`, sealed.
        assertNotNull(prefs.get("konten.tresor"))
        assertEquals(1, core().accountsModel("test-device", "de").accounts().size)

        val home = core.homeVm(signed.account, "de")
        home.send(HomeIntent.Load)
        var seen = 0uL
        withTimeout(20_000) {
            while (home.rails().rails.isEmpty()) seen = home.changed(seen).let { home.version() }
        }
        assertTrue(home.rails().rails.isNotEmpty())
    }
}
