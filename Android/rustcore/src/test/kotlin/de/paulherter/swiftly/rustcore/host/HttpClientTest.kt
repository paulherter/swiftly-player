package de.paulherter.swiftly.rustcore.host

import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import de.paulherter.swiftly.rustcore.HttpFailure
import de.paulherter.swiftly.rustcore.NetHeader
import de.paulherter.swiftly.rustcore.NetMethod
import de.paulherter.swiftly.rustcore.NetRequest
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.net.URL

class HttpClientTest {
    private val seen = java.util.concurrent.CopyOnWriteArrayList<Pair<String, Map<String, String>>>()
    private val server = MockWebServer().apply {
        dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                seen += (request.method + " " + request.path) to request.headers.toMultimap().mapValues { it.value.first() }
                return when (request.path?.substringBefore('?')) {
                    "/hop" -> MockResponse().setResponseCode(302).addHeader("Location", "/final")
                    "/post303" -> MockResponse().setResponseCode(303).addHeader("Location", "/final")
                    "/slow" -> MockResponse().setBodyDelay(1500, java.util.concurrent.TimeUnit.MILLISECONDS).setBody("late")
                    "/404" -> MockResponse().setResponseCode(404).setBody("nope")
                    else -> MockResponse().addHeader("X-Test", "1").setBody("ok")
                }
            }
        }
        start()
    }
    private val base = server.url("/").toString().trimEnd('/')
    private val client = AndroidHttpClient()

    @After fun stop() { runCatching { server.shutdown() } }

    private fun req(
        path: String,
        method: NetMethod = NetMethod.GET,
        body: ByteArray? = null,
        timeout: ULong? = null,
    ) = NetRequest(method, base + path, listOf(NetHeader("X-Emby-Token", "geheim"), NetHeader("Accept", "application/json")), body, timeout)

    @Test fun getFollowsRedirectsAndReportsFinalAddress() = runBlocking {
        val r = client.send(req("/hop"))
        assertEquals(200.toUShort(), r.status)
        assertEquals("ok", String(r.body))
        assertEquals("$base/final", r.url)
        assertTrue(r.headers.any { it.name == "X-Test" && it.value == "1" })
        assertEquals("geheim", seen.last().second["x-emby-token"]) // same origin keeps the token
    }

    @Test fun postAfter303BecomesGetWithoutBody() = runBlocking {
        client.send(req("/post303", NetMethod.POST, "{}".toByteArray()))
        assertEquals("GET /final", seen.last().first)
    }

    @Test fun keepMethodReturnsTheRedirectInsteadOfTurningPostIntoGet() = runBlocking {
        val before = seen.size
        val r = client.send(req("/post303", NetMethod.POST, "{}".toByteArray()).copy(keepMethod = true))
        assertEquals(303.toUShort(), r.status)
        assertEquals(before + 1, seen.size) // no second request
    }

    @Test fun errorStatusIsAnAnswerNotAFailure() = runBlocking {
        val r = client.send(req("/404"))
        assertEquals(404.toUShort(), r.status)
        assertEquals("nope", String(r.body))
    }

    @Test fun requestTimeoutIsReportedAsNsUrlTimeout() = runBlocking {
        try { client.send(req("/slow", timeout = 200UL)); fail() } catch (e: HttpFailure.Network) { assertEquals(-1001, e.code) }
    }

    @Test fun refusedConnectionIsMinus1004() = runBlocking {
        server.shutdown()
        try { client.send(req("/")); fail() } catch (e: HttpFailure.Network) { assertEquals(-1004, e.code) }
    }

    @Test fun originRule() {
        assertTrue(AndroidHttpClient.sameOrigin(URL("https://a.de/x"), URL("https://a.de:443/y")))
        assertTrue(!AndroidHttpClient.sameOrigin(URL("https://a.de/x"), URL("http://a.de/x")))
        assertTrue(!AndroidHttpClient.sameOrigin(URL("https://a.de/x"), URL("https://b.de/x")))
    }

    @Test fun certificateErrorsCarryAReasonCode() {
        val e = javax.net.ssl.SSLHandshakeException("x").apply {
            initCause(java.security.cert.CertPathValidatorException("Trust anchor for certification path not found."))
        }
        assertEquals(-1202, (AndroidHttpClient.failure(e) as HttpFailure.Certificate).code)
        assertNull(AndroidHttpClient.failure(java.io.IOException("x")) as? HttpFailure.Certificate)
    }
}
