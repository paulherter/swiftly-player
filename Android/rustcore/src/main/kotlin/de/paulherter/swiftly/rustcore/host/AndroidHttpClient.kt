package de.paulherter.swiftly.rustcore.host

import de.paulherter.swiftly.rustcore.HttpClient
import de.paulherter.swiftly.rustcore.HttpFailure
import de.paulherter.swiftly.rustcore.NetHeader
import de.paulherter.swiftly.rustcore.NetMethod
import de.paulherter.swiftly.rustcore.NetRequest
import de.paulherter.swiftly.rustcore.NetResponse
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.IOException
import java.net.ConnectException
import java.net.HttpURLConnection
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.URL
import java.net.UnknownHostException
import java.security.cert.CertPathValidatorException
import java.security.cert.CertificateExpiredException
import java.security.cert.CertificateNotYetValidException
import javax.net.ssl.SSLException

/**
 * The core's HTTP on Android: `HttpURLConnection`, so the system trust store, user-installed CAs
 * (the app's network security config), proxies and the system's HTTP/2-less keep-alive pool apply and the APK
 * carries no TLS stack of its own. Counterpart of `URLSessionHttpClient` on Apple and behaves like it:
 * 15 s without data, a request's own timeout replaces that, redirects are followed (at most 10) and a target on
 * another origin gets only `Accept`, `User-Agent` and (with a body) `Content-Type`, so the token and the user's
 * gateway headers never leave the server they were meant for; no response cache; any status is an answer.
 *
 * Failures use the `NSURLError` codes the core's rules know (-1001 timeout, -1003 no host, -1004 no connection,
 * -1005 lost, -1200 range for TLS).
 *
 * @param prepare runs on every request before it goes out (the user's own gateway headers for their server).
 */
class AndroidHttpClient(
    private val prepare: ((url: String, headers: MutableList<NetHeader>) -> Unit)? = null,
    private val openConnection: (URL) -> HttpURLConnection = { it.openConnection() as HttpURLConnection },
) : HttpClient {

    override suspend fun send(request: NetRequest): NetResponse = withContext(Dispatchers.IO) {
        suspendCancellableCoroutine { cont ->
            val live = arrayOfNulls<HttpURLConnection>(1)
            val cancelled = java.util.concurrent.atomic.AtomicBoolean(false)
            cont.invokeOnCancellation { cancelled.set(true); live[0]?.disconnect() }
            try {
                cont.resumeWith(Result.success(exchange(request, live) { cancelled.get() }))
            } catch (e: HttpFailure) {
                cont.resumeWith(Result.failure(e))
            } catch (e: CancellationException) {
                cont.resumeWith(Result.failure(HttpFailure.Cancelled()))
            }
        }
    }

    internal fun exchange(request: NetRequest, live: Array<HttpURLConnection?>, cancelled: () -> Boolean): NetResponse {
        var target = request.url
        var method = request.method
        var body = request.body
        var headers = request.headers.toMutableList()
        prepare?.invoke(target, headers)
        try {
            for (hop in 0..MAX_REDIRECTS) {
                val c = openConnection(URL(target))
                live[0] = c
                try {
                    val timeout = request.timeoutMs?.toLong()?.toInt() ?: DEFAULT_TIMEOUT_MS
                    c.requestMethod = verb(method)
                    c.instanceFollowRedirects = false
                    c.connectTimeout = timeout
                    c.readTimeout = timeout
                    c.useCaches = false
                    for (h in headers) c.addRequestProperty(h.name, h.value)
                    if (body != null && method != NetMethod.GET) {
                        c.doOutput = true
                        c.outputStream.use { it.write(body!!) }
                    }
                    val status = c.responseCode
                    val location = c.getHeaderField("Location")
                    if (status in REDIRECTS && location != null && hop < MAX_REDIRECTS) {
                        val next = URL(URL(target), location)
                        val hadBody = body != null
                        val turnsIntoGet = status == 303 || ((status == 301 || status == 302) && method == NetMethod.POST)
                        // The Seerr sign-in never turns its POST into a GET: the 3xx is the result.
                        if (request.keepMethod && turnsIntoGet) return respond(c, status, target)
                        if (status == 303 || ((status == 301 || status == 302) && method == NetMethod.POST)) {
                            method = NetMethod.GET
                            body = null
                        }
                        headers = if (!sameOrigin(URL(target), next)) {
                            val kept = listOf("accept", "user-agent") + if (hadBody && body != null) listOf("content-type") else emptyList()
                            headers.filter { it.name.lowercase() in kept }.toMutableList()
                        } else if (body == null) {
                            headers.filter { !it.name.equals("Content-Type", ignoreCase = true) }.toMutableList()
                        } else headers
                        target = next.toString()
                        continue
                    }
                    return respond(c, status, target)
                } finally {
                    c.disconnect()
                    live[0] = null
                }
            }
            throw HttpFailure.Network(-1005)
        } catch (e: HttpFailure) {
            throw e
        } catch (e: Exception) {
            android.util.Log.w("Swiftly", "[Http] $method $target failed: $e")
            throw failure(e, cancelled())
        }
    }

    private fun respond(c: HttpURLConnection, status: Int, target: String): NetResponse {
        val out = c.headerFields.flatMap { (name, values) ->
            if (name == null) emptyList() else values.map { NetHeader(name, it) }
        }
        val stream = if (status >= 400) c.errorStream else c.inputStream
        val data = stream?.use { it.readBytes() } ?: ByteArray(0)
        return NetResponse(status.toUShort(), out, data, target)
    }

    companion object {
        const val DEFAULT_TIMEOUT_MS = 15_000
        const val MAX_REDIRECTS = 10
        private val REDIRECTS = setOf(301, 302, 303, 307, 308)

        private fun verb(m: NetMethod) = when (m) {
            NetMethod.GET -> "GET"
            NetMethod.POST -> "POST"
            NetMethod.PUT -> "PUT"
            NetMethod.DELETE -> "DELETE"
        }

        fun sameOrigin(a: URL, b: URL): Boolean {
            fun port(u: URL) = if (u.port != -1) u.port else u.defaultPort
            return a.protocol.equals(b.protocol, true) && a.host.equals(b.host, true) && port(a) == port(b)
        }

        /** Maps what `HttpURLConnection` throws to the codes the core sorts (see `certificate_reason`). */
        fun failure(e: Exception, cancelled: Boolean = false): HttpFailure {
            if (cancelled || e is CancellationException) return HttpFailure.Cancelled()
            val chain = generateSequence<Throwable>(e) { it.cause }.take(8).toList()
            val text = chain.joinToString(" / ") { it.message ?: it.javaClass.simpleName }
            if (e is SSLException || chain.any { it is CertPathValidatorException || it is CertificateExpiredException }) {
                val code = when {
                    chain.any { it is CertificateExpiredException } -> -1201
                    chain.any { it is CertificateNotYetValidException } -> -1204
                    text.contains("Trust anchor", true) || text.contains("unable to get local issuer", true) -> -1202
                    else -> -1200
                }
                // Hostname mismatch carries no code of its own: the text decides ("hostname", "subject name").
                return HttpFailure.Certificate(code, text)
            }
            return when (e) {
                is SocketTimeoutException -> HttpFailure.Network(-1001)
                is UnknownHostException -> HttpFailure.Network(-1003)
                is ConnectException, is NoRouteToHostException -> HttpFailure.Network(-1004)
                is IOException -> HttpFailure.Network(-1005)
                else -> HttpFailure.Other(text)
            }
        }
    }
}
