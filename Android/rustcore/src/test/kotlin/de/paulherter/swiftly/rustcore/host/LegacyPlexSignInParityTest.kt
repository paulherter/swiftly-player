package de.paulherter.swiftly.rustcore.host

import de.paulherter.swiftly.rustcore.Core
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import javax.crypto.spec.SecretKeySpec

/**
 * Plex sign-in: the steps of the Swift `Kern.plex…` (`Servers.swift`) as JSON, against a MockWebServer that stands in for
 * plex.tv and the server (the core's base-URL override; the real hosts stay the default). The expected texts are what the
 * Swift code writes, step by step (`PlexStepResponse`, absent optionals left out).
 */
class LegacyPlexSignInParityTest {
    private object Mem : StringPrefs {
        val m = HashMap<String, String>()
        override fun get(key: String) = m[key]
        override fun put(key: String, value: String) { m[key] = value }
        override fun remove(key: String) { m.remove(key) }
    }

    private fun mock(base: () -> String) = object : Dispatcher() {
        var looks = 0
        override fun dispatch(request: RecordedRequest): MockResponse {
            val path = request.path.orEmpty().substringBefore('?')
            val json = { code: Int, body: String -> MockResponse().setResponseCode(code).setHeader("Content-Type", "application/json").setBody(body) }
            return when (path) {
                "/api/v2/pins" -> json(201, """{"id":4711,"code":"ABCD1234","expiresIn":1800,"authToken":null}""")
                "/api/v2/pins/4711" ->
                    if (looks++ == 0) json(200, """{"id":4711,"code":"ABCD1234","expiresIn":1800,"authToken":null}""")
                    else json(200, """{"id":4711,"code":"ABCD1234","expiresIn":1700,"authToken":"ACCOUNTTOKEN"}""")
                "/api/v2/user" -> json(200, """{"id":7,"uuid":"u7","title":"paulplex","thumb":"https://t/p.png"}""")
                "/api/v2/home/users" -> json(200, """{"id":99,"name":"Home","users":[{"id":1,"uuid":"uuid-admin","title":"Owner","admin":true,"restricted":false,"protected":false,"guest":false}]}""")
                "/api/v2/resources" -> json(200, """[{"name":"Home","clientIdentifier":"MACHINE1","provides":"server","owned":true,"accessToken":"SERVERTOKEN","httpsRequired":false,"presence":true,"ownerId":1,"connections":[{"protocol":"http","address":"127.0.0.1","port":${base().substringAfterLast(':').trim('/')},"uri":"${base()}","local":true,"relay":false,"IPv6":false}]}]""")
                "/identity" -> json(200, """{"MediaContainer":{"size":0,"claimed":false,"machineIdentifier":"MACHINE1","version":"1.43.0.0"}}""")
                else -> json(404, "")
            }
        }
    }

    @Test fun stepsAreTheOnesOfTheSwiftCore() = runBlocking {
        val server = MockWebServer()
        val base = { server.url("/").toString().trimEnd('/') }
        server.dispatcher = mock(base)
        server.start()
        try {
            val core = Core(AndroidPlatform("Golden", null) {}, AndroidSecretStore(Mem, GcmSealer { SecretKeySpec(ByteArray(32), "AES") }),
                AndroidKeyValueStore(Mem), AndroidHttpClient())
            val flow = core.accountsModel("test-device", "de").legacyPlexSignIn("cid", "1.0", "Android", "Pixel", "Pixel", base())
            assertEquals("""{"secondsLeft":0,"step":"waiting"}""", flow.poll())
            assertEquals("""{"code":"ABCD1234","secondsLeft":1800,"step":"waiting","url":"${base()}/link"}""".canon(), flow.startTv().canon())
            val browser = JSONObject(flow.start())
            assertEquals("waiting", browser.getString("step"))
            assertTrue(browser.getString("url").startsWith("${base()}/auth#?clientID=cid&code=ABCD1234"))
            assertTrue(!browser.has("code"))
            assertEquals("waiting", JSONObject(flow.poll()).getString("step"))
            // The token is there and the account has one profile: the servers follow in the same answer.
            val servers = JSONObject(flow.poll())
            assertEquals("servers", servers.getString("step"))
            assertEquals("paulplex", servers.getString("account"))
            assertTrue(!servers.has("profile"))
            assertNull(JsonParity.diff("""[{"id":"MACHINE1","name":"Home","local":true,"online":true}]""", servers.getJSONArray("servers").toString()))
            assertEquals("""{"step":"failed"}""", flow.pickServer("NOPE"))
            val done = JSONObject(flow.pickServer("MACHINE1"))
            assertEquals("done", done.getString("step"))
            val session = JSONObject(done.getString("session"))
            assertEquals("SERVERTOKEN", session.getString("accessToken"))
            assertEquals("MACHINE1", session.getJSONObject("plex").getString("machineIdentifier"))
            flow.reset()
            assertEquals("""{"step":"failed"}""", flow.servers())
        } finally { server.shutdown() }
    }

    /** Key order of a JSON text does not matter for the comparison. */
    private fun String.canon(open: String = "{"): String =
        if (open == "[") org.json.JSONArray(this).let { a -> (0 until a.length()).joinToString(",", "[", "]") { a.getJSONObject(it).canon() } }
        else JSONObject(this).canon()
    private fun JSONObject.canon(): String = keys().asSequence().sorted().joinToString(",", "{", "}") { "\"$it\":${get(it).let { v -> if (v is String) "\"$v\"" else v.toString() }}" }
}
