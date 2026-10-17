package de.paulherter.swiftly

import okhttp3.Interceptor
import okhttp3.OkHttpClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URI
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * The forwarder in front of VLC (issue #4) against an outpost server: same cases as
 * `StreamNextLeaderTests` in JellyfinKit, plus pause and cancel take effect immediately,
 * not only at the upper limit.
 */
class StreamNextLeaderTest {

    /** 1 MiB; every byte is derivable from its position. */
    private val file = ByteArray(1 shl 20) { (it * 31 + 7).toByte() }

    private fun nextLeader(entries: PreItem?): StreamForwarder {
        val headers: (String) -> Map<String, String> = { url ->
            if (entries != null && url.startsWith("http://127.0.0.1:${entries.port}/")) mapOf("X-Vorposten" to "offen") else emptyMap()
        }
        // Like `OwnHeadersCatch`, with the test's own header table.
        val interceptor = Interceptor { chain ->
            val a = chain.request()
            val f = headers(a.url.toString())
            if (f.isEmpty()) chain.proceed(a)
            else chain.proceed(a.newBuilder().apply { f.forEach { (n, w) -> header(n, w) } }.build())
        }
        return StreamForwarder(headers, OkHttpClient.Builder().addInterceptor(interceptor).build())
    }

    @Test fun withoutHeadersStaysAddress() {
        val w = nextLeader(null)
        val u = "https://ohne-koepfe.test/Videos/1/stream.mkv?static=true"
        assertEquals(u, w.address(u))
        assertEquals(0, w.currentPort)
    }

    @Test fun headersGoWith() {
        PreItem(file).use { entries ->
            val w = nextLeader(entries)
            assertEquals(403, raw(entries.port, "/Videos/1/stream.mkv").status)
            val redirected = URI(w.address(entries.url("/Videos/1/stream.mkv?static=true&api_key=geheim")))
            assertEquals("127.0.0.1", redirected.host)
            assertEquals(w.currentPort, redirected.port)
            assertTrue(redirected.path.endsWith("/Videos/1/stream.mkv"))
            assertEquals("static=true&api_key=geheim", redirected.rawQuery)
            val a = raw(redirected)
            assertEquals(200, a.status)
            assertEquals("${file.size}", a.fields["content-length"])
            assertTrue(a.body.contentEquals(file))
            assertEquals("static=true&api_key=geheim", entries.lastQuery)
        }
    }

    @Test fun sectionMultipleConnection() {
        PreItem(file).use { entries ->
            val w = nextLeader(entries)
            val u = URI(w.address(entries.url("/Videos/1/stream.mkv")))
            val done = CountDownLatch(6)
            val error = AtomicInteger(0)
            repeat(6) { i ->
                Thread {
                    val from = i * 100_000 + 17; val until = from + 4_999
                    val a = raw(u, "bytes=$from-$until")
                    val good = a.status == 206 && a.fields["content-range"] == "bytes $from-$until/${file.size}" &&
                        a.fields["accept-ranges"] == "bytes" && a.body.contentEquals(file.copyOfRange(from, until + 1))
                    if (!good) error.incrementAndGet()
                    done.countDown()
                }.start()
            }
            assertTrue(done.await(20, TimeUnit.SECONDS))
            assertEquals(0, error.get())
        }
    }

    @Test fun wrongMark() {
        PreItem(file).use { entries ->
            val w = nextLeader(entries)
            val u = URI(w.address(entries.url("/Videos/1/stream.mkv")))
            val mark = u.path.split("/")[1]
            assertEquals(404, raw(w.currentPort, "/${mark.reversed()}/Videos/1/stream.mkv").status)
            assertEquals(404, raw(w.currentPort, "/Videos/1/stream.mkv").status)
            assertEquals(0, entries.askFor.get())
        }
    }

    @Test fun cancelActsImmediate() {
        PreItem(file).use { entries ->
            val w = nextLeader(entries)
            val u = URI(w.address(entries.url("/endlos")))
            val v = Socket(InetAddress.getByName("127.0.0.1"), u.port)
            v.getOutputStream().write("GET ${u.rawPath} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".toByteArray())
            val buffer = ByteArray(65536)
            var hasRead = 0
            val on = v.getInputStream()
            while (hasRead < 200_000) { val n = on.read(buffer); if (n <= 0) break; hasRead += n }
            assertTrue(hasRead >= 200_000)
            v.close()
            // The outpost notices when its send fails, within a second.
            repeat(20) { if (!entries.endlessCancelled.get()) Thread.sleep(50) }
            assertTrue("Anfrage beim Server lief weiter", entries.endlessCancelled.get())
        }
    }

    @Test fun pauseHoldsServerAn() {
        PreItem(file).use { entries ->
            val w = nextLeader(entries)
            val u = URI(w.address(entries.url("/endlos")))
            Socket(InetAddress.getByName("127.0.0.1"), u.port).use { v ->
                v.getOutputStream().write("GET ${u.rawPath} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".toByteArray())
                assertTrue(v.getInputStream().read(ByteArray(65536)) > 0)
                Thread.sleep(1500)
                val a = entries.endlessSent.get()
                Thread.sleep(1000)
                val b = entries.endlessSent.get()
                // Stalled: only the socket buffers are filled, no backlog up to 64 MiB.
                assertTrue("lief weiter: ${b - a}", b - a < (1 shl 20))
                assertTrue("zu viel gepuffert: $b", b < (16 shl 20))
                assertTrue(!entries.endlessCancelled.get())
            }
        }
    }

    @Test fun listBecomesWritten() {
        PreItem(file).use { entries ->
            val w = nextLeader(entries)
            val u = URI(w.address(entries.url("/Videos/1/master.m3u8?api_key=geheim")))
            val mark = u.path.split("/")[1]
            val a = raw(u)
            assertEquals(200, a.status)
            val text = String(a.body)
            val rows = text.split("\n")
            assertTrue(rows.contains("main.m3u8?api_key=geheim"))
            assertTrue(rows.contains("/$mark/Videos/1/hls/0.ts"))
            assertTrue(rows.contains("http://127.0.0.1:${w.currentPort}/$mark/Videos/1/hls/1.ts"))
            assertTrue(rows.contains("https://fremd.test/werbung.ts"))
            assertTrue(text.contains("URI=\"/$mark/Videos/1/init.mp4\""))
            assertEquals("${a.body.size}", a.fields["content-length"])
        }
    }

    @Test fun requestHeader() {
        val k = RequestHeader.dismantle("GET /a/b?c=d HTTP/1.1\r\nRange: bytes=0-\r\nUser-Agent: VLC\r\n\r\n")
        assertNotNull(k)
        assertEquals("GET", k!!.procedure)
        assertEquals("/a/b?c=d", k.target)
        assertEquals("bytes=0-", k.headers["range"])
        assertEquals("VLC", k.headers["user-agent"])
    }

    // MARK: Helpers

    private class RawResponse(val status: Int = 0, val fields: Map<String, String> = emptyMap(), val body: ByteArray = ByteArray(0))

    private fun raw(u: URI, range: String? = null): RawResponse =
        raw(u.port, u.rawPath + (u.rawQuery?.let { "?$it" } ?: ""), range)

    /** A request as VLC makes it, over a raw socket. */
    private fun raw(port: Int, path: String, range: String? = null): RawResponse {
        Socket(InetAddress.getByName("127.0.0.1"), port).use { v ->
            var header = "GET $path HTTP/1.1\r\nHost: 127.0.0.1:$port\r\nUser-Agent: VLC/4.0.0\r\n"
            if (range != null) header += "Range: $range\r\n"
            v.getOutputStream().write((header + "\r\n").toByteArray())
            val everything = v.getInputStream().readBytes()
            val t = (0..everything.size - 4).firstOrNull {
                everything[it] == 13.toByte() && everything[it + 1] == 10.toByte() && everything[it + 2] == 13.toByte() && everything[it + 3] == 10.toByte()
            } ?: return RawResponse()
            val rows = String(everything, 0, t, Charsets.ISO_8859_1).split("\r\n")
            val status = rows.first().split(" ").getOrNull(1)?.toIntOrNull() ?: 0
            val fields = rows.drop(1).mapNotNull { z ->
                val d = z.indexOf(':'); if (d < 0) null else z.substring(0, d).lowercase() to z.substring(d + 1).trim()
            }.toMap()
            return RawResponse(status, fields, everything.copyOfRange(t + 4, everything.size))
        }
    }

    /** A server behind an outpost: without `X-PreItem: offen` it answers 403. */
    private class PreItem(private val file: ByteArray) : AutoCloseable {
        private val listener = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
        val port: Int = listener.localPort
        val askFor = AtomicInteger(0)
        @Volatile var lastQuery: String? = null
        val endlessCancelled = AtomicBoolean(false)
        val endlessSent = AtomicLong(0)

        init {
            Thread {
                while (true) {
                    val v = try { listener.accept() } catch (_: Exception) { break }
                    Thread { try { operate(v) } catch (_: Exception) {} finally { runCatching { v.close() } } }.start()
                }
            }.apply { isDaemon = true }.start()
        }

        override fun close() { listener.close() }

        fun url(path: String) = "http://127.0.0.1:$port$path"

        private fun operate(v: Socket) {
            val a = RequestHeader.read(java.io.BufferedInputStream(v.getInputStream())) ?: return
            val out: OutputStream = v.getOutputStream()
            if (a.headers["x-vorposten"] != "offen") {
                out.write("HTTP/1.1 403 Forbidden\r\nContent-Type: text/html\r\nContent-Length: 5\r\nConnection: close\r\n\r\nnein!".toByteArray())
                return
            }
            val parts = a.target.split("?", limit = 2)
            askFor.incrementAndGet()
            lastQuery = parts.getOrNull(1)
            when (parts[0]) {
                "/endlos" -> {
                    out.write("HTTP/1.1 200 OK\r\nContent-Type: video/x-matroska\r\nConnection: close\r\n\r\n".toByteArray())
                    val piece = ByteArray(16384) { 0x42 }
                    try {
                        repeat(100_000) { out.write(piece); endlessSent.addAndGet(piece.size.toLong()) }
                    } catch (_: Exception) {}
                    endlessCancelled.set(true)
                }
                "/Videos/1/master.m3u8" -> {
                    val list = listOf("#EXTM3U", "#EXT-X-MAP:URI=\"/Videos/1/init.mp4\"", "main.m3u8?api_key=geheim",
                        "/Videos/1/hls/0.ts", url("/Videos/1/hls/1.ts"), "https://fremd.test/werbung.ts").joinToString("\n")
                    val d = list.toByteArray()
                    out.write("HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: ${d.size}\r\nConnection: close\r\n\r\n".toByteArray())
                    out.write(d)
                }
                else -> {
                    var from = 0; var until = file.size - 1; var status = "200 OK"; var section = ""
                    val r = a.headers["range"]
                    if (r != null && r.startsWith("bytes=")) {
                        val z = r.substring(6).split("-")
                        from = z[0].toIntOrNull() ?: 0
                        z.getOrNull(1)?.toIntOrNull()?.let { until = minOf(it, file.size - 1) }
                        status = "206 Partial Content"
                        section = "Content-Range: bytes $from-$until/${file.size}\r\n"
                    }
                    out.write("HTTP/1.1 $status\r\nContent-Type: video/x-matroska\r\nAccept-Ranges: bytes\r\n${section}Content-Length: ${until - from + 1}\r\nConnection: close\r\n\r\n".toByteArray())
                    out.write(file, from, until - from + 1)
                }
            }
            out.flush()
        }
    }
}
