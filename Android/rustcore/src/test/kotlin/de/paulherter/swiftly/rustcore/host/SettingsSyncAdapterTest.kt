package de.paulherter.swiftly.rustcore.host

import de.paulherter.swiftly.rustcore.AccountRef
import de.paulherter.swiftly.rustcore.Core
import de.paulherter.swiftly.rustcore.ServerKind
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import javax.crypto.spec.SecretKeySpec

/** `Kern.settingsSyncRun` answers, through the real core and a local server holding one display-preferences document. */
class SettingsSyncAdapterTest {
    private class Mem : StringPrefs {
        val m = HashMap<String, String>()
        override fun get(key: String) = m[key]
        override fun put(key: String, value: String) { m[key] = value }
        override fun remove(key: String) { m.remove(key) }
    }

    private val posts = ArrayList<String>()
    private var doc = """{"CustomPrefs":{}}"""
    private val server = MockWebServer().apply {
        dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                if (request.method == "POST") { posts += request.body.readUtf8(); return MockResponse().setBody("") }
                return MockResponse().setBody(doc)
            }
        }
        start()
    }

    @After fun stop() = server.shutdown()

    private fun adapter(): SettingsSyncAdapter {
        val core = Core(AndroidPlatform("T", null) {}, AndroidSecretStore(Mem(), GcmSealer { SecretKeySpec(ByteArray(32), "AES") }), AndroidKeyValueStore(Mem()), AndroidHttpClient())
        val account = AccountRef(server.url("/").toString().trimEnd('/'), "u1", "t", ServerKind.JELLYFIN, "d")
        return SettingsSyncAdapter(core.settingsSyncModel(account, "de"))
    }

    private val local = """{"tonSprache":"de","vorSek":"30"}"""
    private val access = """{"adresse":"https://seerr.example","keks":"connect.sid=abc"}"""

    @Test fun emptyServerGetsLocalValuesAndTheSeerrConnectionInOneWrite() = runBlocking {
        val a = JSONObject(adapter().run(local, 0.0, 0.0, false, access, 0.0))
        assertEquals("push", a.getString("decision")); assertEquals("push", a.getString("seerr"))
        assertTrue(a.getDouble("stamp") > 0 && a.getDouble("seerrStamp") > 0)
        assertEquals(1, posts.size)
        assertTrue(posts[0], posts[0].contains("swiftly.tonSprache") && posts[0].contains("connect.sid=abc"))
    }

    @Test fun newerServerValuesAreHandedBackInTheOldShape() = runBlocking {
        doc = """{"CustomPrefs":{"swiftly.tonSprache":"fr","swiftly.changed":"5000000"}}"""
        val a = JSONObject(adapter().run(local, 1_000_000.0, 0.0, false, "", 0.0))
        assertEquals("apply", a.getString("decision"))
        assertEquals(5_000_000.0, a.getDouble("remote"), 0.5); assertEquals(5_000_000.0, a.getDouble("stamp"), 0.5)
        assertEquals("fr", a.getJSONObject("values").getString("tonSprache"))
        assertEquals("nothing", a.getString("seerr")); assertTrue(posts.isEmpty())
    }

    @Test fun unreachableServerIsAnError() = runBlocking {
        server.shutdown()
        assertEquals("error", JSONObject(adapter().run(local, 0.0, 0.0, false, "", 0.0)).getString("decision"))
    }
}
