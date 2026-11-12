package de.paulherter.swiftly.rustcore.host

import de.paulherter.swiftly.rustcore.Core
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import javax.crypto.spec.SecretKeySpec

/** Seerr: the Swift `Kern.seerr…` answers (`seerr-*`) against the core's, on the fixture's small Jellyseerr. */
class LegacySeerrParityTest {
    private val url = System.getenv("SWIFTLY_FIXTURE_URL")
    private val golden = System.getenv("SWIFTLY_GOLDEN_DIR")

    private object Mem : StringPrefs {
        val m = HashMap<String, String>()
        override fun get(key: String) = m[key]
        override fun put(key: String, value: String) { m[key] = value }
        override fun remove(key: String) { m.remove(key) }
    }

    private fun check(name: String, new: String) {
        val old = File(golden!!, "$name.json").readText()
        if (old.trimStart().startsWith("{") || old.trimStart().startsWith("[")) assertNull(name, JsonParity.diff(old, new))
        else assertEquals(name, old, new)
    }

    @Test fun answersAreTheOnesOfTheSwiftCore() = runBlocking {
        assumeTrue("no SWIFTLY_FIXTURE_URL / SWIFTLY_GOLDEN_DIR", url != null && golden != null)
        val core = Core(AndroidPlatform("Golden", null) {}, AndroidSecretStore(Mem, GcmSealer { SecretKeySpec(ByteArray(32), "AES") }),
            AndroidKeyValueStore(Mem), AndroidHttpClient())
        val access = """{"adresse":"$url","keks":"connect.sid=abc","koepfe":[{"name":"X-Gate","wert":"k"}]}"""
        val s = core.legacySeerr(access)!!
        check("seerr-applies", s.applies().toString())
        check("seerr-search", s.search("Matrix"))
        check("seerr-search-short", s.search(" a "))
        check("seerr-filmography", s.filmography(7))
        check("seerr-detail-movie", s.detail("movie", 603))
        check("seerr-detail-tv", s.detail("tv", 1399))
        check("seerr-detail-unknown", s.detail("movie", 4040))
        check("seerr-request-movie", s.request("movie", 603, ""))
        check("seerr-request-tv", s.request("tv", 1399, "1,2"))
        check("seerr-request-tv-none", s.request("tv", 1399, ""))
        assertNull(core.legacySeerr("garbage"))
    }
}
