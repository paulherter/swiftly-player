package de.paulherter.swiftly.rustcore.host

import de.paulherter.swiftly.rustcore.Core
import de.paulherter.swiftly.rustcore.DatagramHost
import de.paulherter.swiftly.rustcore.DiscoverInterface
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import javax.crypto.spec.SecretKeySpec

/** Old against new for the server and sign-in group: Swift `Kern` answers (Android/golden) against the core's, same fixture server. */
class LegacyLoginParityTest {
    private val url = System.getenv("SWIFTLY_FIXTURE_URL")
    private val golden = System.getenv("SWIFTLY_GOLDEN_DIR")

    private object Mem : StringPrefs {
        val m = HashMap<String, String>()
        override fun get(key: String) = m[key]
        override fun put(key: String, value: String) { m[key] = value }
        override fun remove(key: String) { m.remove(key) }
    }

    private fun login() = Core(AndroidPlatform("Golden", null) {}, AndroidSecretStore(Mem, GcmSealer { SecretKeySpec(ByteArray(32), "AES") }),
        AndroidKeyValueStore(Mem), AndroidHttpClient()).accountsModel("golden-device", "en").legacyLogin().also {
        it.sessionSet("""{"accessToken":"fixture-token","userID":"u1","userName":"demo","serverURL":"$url"}""")
    }

    private fun old(name: String) = File(golden!!, "$name.json").readText()
    private fun check(name: String, new: String) { assertNull(name, JsonParity.diff(old(name), new)) }
    private fun ready() = assumeTrue("no SWIFTLY_FIXTURE_URL / SWIFTLY_GOLDEN_DIR", url != null && golden != null)

    @Test fun infoAndPublicUsers() = runBlocking {
        ready(); val l = login()
        check("lg-server-info", l.serverInfo())
        check("lg-public-user", l.publicUser(false))
        check("lg-public-user-new-none", l.publicUser(true))
    }

    @Test fun addingAServerAndSigningIn() = runBlocking {
        ready(); val l = login()
        check("lg-onboarding-connect", l.onboardingConnect(url!!, "[]"))
        check("lg-public-user-new", l.publicUser(true))
        check("lg-onboarding-signin", l.onboardingSignIn("demo", "demo"))
        check("lg-signin", l.signIn("demo", "demo"))
    }

    @Test fun quickConnect() = runBlocking {
        ready(); val l = login()
        assertEquals(old("lg-qc-start"), l.quickConnectStart(false))
        assertEquals(old("lg-qc-wait"), l.quickConnectWait(false))
        check("lg-qc-signin", l.quickConnectSignIn(false))
    }

    @Test fun sessionShareAndEmbyCheck() = runBlocking {
        ready(); val l = login()
        assertEquals(old("lg-session-applies").trim(), l.sessionApplies().toString())
        assertEquals(old("lg-qc-share-short"), l.quickConnectShare("12"))
        assertEquals(old("lg-qc-share"), l.quickConnectShare("123456"))
        check("lg-emby-check", l.embyCheck(url!!, "[]"))
        check("lg-emby-bad", l.embyCheck("", "[]"))
        check("lg-emby-unreachable", l.embyCheck("http://127.0.0.1:1", "[]"))
    }

    @Test fun linkUpSignsInAndSignOffForgets() = runBlocking {
        ready(); val l = login()
        check("lg-link-up", l.linkUp(url!!, "[]"))
        check("lg-link-up-signin", l.signIn("demo", "demo"))
        l.sessionSet("""{"accessToken":"fixture-token","userID":"u1","userName":"demo","serverURL":"$url"}""")
        l.signOff()
        assertEquals(old("lg-qc-share-signed-off"), l.quickConnectShare("123456"))
    }

    @Test fun withoutASessionNothingIsRefusedAndNothingIsShared() = runBlocking {
        val l = Core(AndroidPlatform("Golden", null) {}, AndroidSecretStore(Mem, GcmSealer { SecretKeySpec(ByteArray(32), "AES") }),
            AndroidKeyValueStore(Mem), AndroidHttpClient()).accountsModel("golden-device", "en").legacyLogin()
        assertEquals(true, l.sessionApplies())
        assertEquals("nichtAngemeldet", l.quickConnectShare("123456"))
        l.signOff()
        assertEquals(true, runCatching { l.signIn("demo", "demo") }.isFailure)
    }

    @Test fun anAddressNobodyReadsIsAnErrorAndEmbyNeedsItsCheck() = runBlocking {
        val l = login()
        assertEquals(true, runCatching { l.onboardingConnect("", "[]") }.isFailure)
        assertEquals(true, runCatching { l.embySignIn("demo", "demo") }.isFailure)
        assertEquals(true, runCatching { l.quickConnectStart(true) }.isFailure)
    }

    /** The search has no Swift golden (the network is the machine's): the shape is the one `Core.serverSearch` wrote. */
    @Test fun searchMergesSortsAndDropsTheTaken() {
        val reply = """{"Address":"http://192.168.1.5:8096","Id":"b","Name":"Zeta"}""".toByteArray()
        val reply2 = """{"Address":"http://192.168.1.6:8096","Id":"a","Name":"Alpha"}""".toByteArray()
        val reply3 = """{"Address":"http://192.168.1.7:8096","Id":"c","Name":"Mid"}""".toByteArray()
        val host = object : DatagramHost {
            override fun send(payload: ByteArray, target: UInt, port: UShort) = true
            override fun receive(seconds: UInt) = listOf(reply, reply2, reply3, "junk".toByteArray())
        }
        val l = login()
        val out = l.serverSearch(host, listOf(DiscoverInterface(0xC0A80102u, 0xFFFFFF00u)), "[]", """["http://192.168.1.7:8096"]""")
        assertNull(JsonParity.diff(
            """[{"id":"a","name":"Alpha","adresse":"http://192.168.1.6:8096","kurz":"192.168.1.6:8096"},{"id":"b","name":"Zeta","adresse":"http://192.168.1.5:8096","kurz":"192.168.1.5:8096"}]""", out))
        assertEquals(8000L, l.serverSearchPause())
    }
}
