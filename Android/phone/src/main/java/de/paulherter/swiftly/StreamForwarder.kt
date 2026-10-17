package de.paulherter.swiftly

import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URI
import java.security.SecureRandom
import java.util.concurrent.TimeUnit

/**
 * **The relay in front of libVLC, for servers behind an outpost (issue #4).** Mirrors
 * `StreamForwarder` in JellyfinKit; behavior and limits as there, tests in
 * `StreamNextLeaderTests`.
 *
 * libVLC cannot set arbitrary headers. Behind Cloudflare Access, Authelia or Pangolin the app
 * therefore fetches the stream itself: a small HTTP service on `127.0.0.1:<port>` accepts VLC's
 * request, fetches the same address from the server with the custom headers via [OwnHeadersCatch],
 * and streams status, seek headers and body through.
 *
 * **Why OkHttp rather than the relay in the kernel** (`Kern.stromAdresse`): that one ran on
 * swift-corelibs-foundation, where `suspend()` does not pause a transfer and a cancelled task does
 * not report its end. On pause it kept loading up to the 64 MiB cap, and after closing the player
 * the request kept running at the server. Here reads and writes block: if VLC does not read
 * (pause), the write blocks, nothing more is read, and TCP throttles the server with no buffer.
 * If VLC closes the connection, the next write fails and the call is aborted at once.
 *
 * - **Only when headers are configured**, otherwise the address stays unchanged.
 * - **Only on 127.0.0.1**, and each origin gets a random token (128 bit) as first path segment;
 *   a foreign app does not know it and gets 404.
 * - **Range passes through 1:1**, `Content-Range`/`Content-Length` returned unchanged.
 * - **HLS:** absolute and root-relative addresses in playlists are rewritten.
 */
class StreamForwarder(
    /** The custom headers for an address; empty means: do not redirect. */
    private val headers: (String) -> Map<String, String>,
    /** The caller that attaches the headers (in the app [OwnHeadersCatch]). */
    clientApi: OkHttpClient,
    /** Only method, path, status: never values, never queries. */
    private val report: (String) -> Unit = {},
) {
    companion object {
        /** The one for the app. Tests build their own. */
        val gemeinsam: StreamForwarder by lazy {
            StreamForwarder(
                headers = ::ownHeadersFields,
                clientApi = OkHttpClient.Builder().addInterceptor(OwnHeadersCatch).build(),
                report = { AppLog.writeOut(it) },
            )
        }

        /** Playlists are small; anything larger is not one. */
        const val ListsLimit = 4 shl 20
        /** Chunk size when passing through. */
        private const val Piece = 64 shl 10
    }

    private val session: OkHttpClient = clientApi.newBuilder()
        .cache(null)
        // Idle time between two reads, not total duration: a movie runs for hours.
        .readTimeout(60, TimeUnit.SECONDS)
        .callTimeout(0, TimeUnit.MILLISECONDS)
        .build()

    private val barrier = Any()
    private var listener: ServerSocket? = null
    private var port = 0
    private val originMark = HashMap<String, String>()
    private val markOrigin = HashMap<String, String>()

    // MARK: Address

    /**
     * The address VLC should get. Unchanged without configured headers, for anything but `http(s)`,
     * and when listening is not possible.
     */
    fun address(url: String): String {
        if (headers(url).isEmpty()) return url
        val u = runCatching { URI(url) }.getOrNull() ?: return url
        val schema = u.scheme?.lowercase() ?: return url
        if (schema != "http" && schema != "https") return url
        val computer = u.rawAuthority?.substringAfterLast('@') ?: return url
        if (computer.isEmpty()) return url
        val provenance = "$schema://$computer"
        synchronized(barrier) {
            val p = listenLocked() ?: return url
            val mark = markOrigin.getOrPut(provenance) {
                newMark().also { originMark[it] = provenance }
            }
            val path = u.rawPath.takeUnless { it.isNullOrEmpty() } ?: "/"
            val query = u.rawQuery?.let { "?$it" } ?: ""
            return "http://127.0.0.1:$p/$mark$path$query"
        }
    }

    /** The port currently listened on; 0 while not. */
    val currentPort: Int get() = synchronized(barrier) { if (listener == null) 0 else port }

    /** The address at the server from VLC's request path; `null` for a wrong token. */
    internal fun target(requestPath: String): Pair<String, String>? {
        if (!requestPath.startsWith("/")) return null
        val without = requestPath.substring(1)
        val end = without.indexOfFirst { it == '/' || it == '?' }.let { if (it < 0) without.length else it }
        val mark = without.substring(0, end)
        var rest = without.substring(end)
        if (!rest.startsWith("/")) rest = "/$rest"
        val provenance = synchronized(barrier) { originMark[mark] } ?: return null
        return (provenance + rest) to mark
    }

    private fun newMark(): String {
        val b = ByteArray(16).also { SecureRandom().nextBytes(it) }
        return b.joinToString("") { "%02x".format(it) }
    }

    // MARK: Listening

    /** After a restart the same port first, since VLC may still hold the old address. **Lock held.** */
    private fun listenLocked(): Int? {
        listener?.let { return port }
        val s = runCatching { bind(port) }.getOrNull() ?: runCatching { bind(0) }.getOrNull()
        if (s == null) { report("[Weiterleiter] Lauschen gescheitert"); return null }
        listener = s
        port = s.localPort
        report("[Weiterleiter] lauscht auf 127.0.0.1:$port")
        Thread({ accept(s) }, "Stromweiterleiter").apply { isDaemon = true }.start()
        return port
    }

    private fun bind(p: Int): ServerSocket = ServerSocket().apply {
        reuseAddress = true
        bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), p), 16)
    }

    private fun accept(s: ServerSocket) {
        while (true) {
            val v = try { s.accept() } catch (_: IOException) {
                synchronized(barrier) { if (listener === s) listener = null }
                runCatching { s.close() }
                report("[Weiterleiter] Lauscher beendet")
                return
            }
            Thread({
                try { operate(v) } catch (_: Exception) {} finally { runCatching { v.close() } }
            }, "Stromweiterleiter.Verbindung").apply { isDaemon = true }.start()
        }
    }

    // MARK: One connection

    private fun operate(v: Socket) {
        v.soTimeout = 30_000
        val input = java.io.BufferedInputStream(v.getInputStream())
        val from = v.getOutputStream()
        val petition = RequestHeader.read(input) ?: return
        if (petition.procedure != "GET" && petition.procedure != "HEAD") {
            from.write(header(405, mapOf("Allow" to "GET, HEAD"), 0)); return
        }
        val (url, mark) = target(petition.target) ?: run {
            report("[Weiterleiter] fremde Marke abgewiesen")
            from.write(header(404, emptyMap(), 0)); return
        }
        val r = Request.Builder().url(url).method(petition.procedure, null)
        // Pass through what matters for seeking. Cookies and Icy-MetaData stay out.
        for (name in listOf("Range", "If-Range", "User-Agent", "Accept")) {
            petition.headers[name.lowercase()]?.let { r.header(name, it) }
        }
        // Otherwise OkHttp unpacks and Content-Length no longer matches.
        r.header("Accept-Encoding", "identity")

        val call: Call = session.newCall(r.build())
        val path = runCatching { URI(url).path }.getOrDefault("")
        val answer: Response = try { call.execute() } catch (_: IOException) {
            report("[Weiterleiter] ${petition.procedure} $path → keine Antwort vom Server")
            from.write(header(502, emptyMap(), 0)); return
        }
        answer.use { a ->
            val section = petition.headers["range"]?.let { " $it" } ?: ""
            report("[Weiterleiter] ${petition.procedure} $path$section → ${a.code}")
            val fields = LinkedHashMap<String, String>()
            for (name in listOf("Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "Last-Modified", "ETag")) {
                a.header(name)?.let { fields[name] = it }
            }
            if (a.header("Content-Encoding") != null) fields.remove("Content-Length")

            if (petition.procedure == "HEAD") { from.write(header(a.code, fields, null)); return }

            val type = (fields["Content-Type"] ?: "").lowercase()
            if (type.contains("mpegurl") || path.lowercase().endsWith(".m3u8")) {
                val raw = a.body?.let { everything(it.byteStream(), ListsLimit) } ?: run {
                    from.write(header(502, emptyMap(), 0)); return
                }
                val new = listWrite(String(raw, Charsets.UTF_8), mark).toByteArray(Charsets.UTF_8)
                fields.remove("Content-Length")
                from.write(header(a.code, fields, new.size)); from.write(new); from.flush()
                return
            }

            try { from.write(header(a.code, fields, null)); from.flush() } catch (_: IOException) { call.cancel(); return }
            a.body?.let { passThrough(it.byteStream(), from, call, path) }
        }
    }

    /**
     * **Pass through blocking.** If VLC does not read, `write` blocks and nothing more is read from
     * the server: no buffer. If writing fails, VLC is gone: abort at once.
     */
    private fun passThrough(on: InputStream, from: OutputStream, call: Call, path: String) {
        val buffer = ByteArray(Piece)
        var sent = 0L
        while (true) {
            val n = try { on.read(buffer) } catch (_: IOException) { -1 }
            if (n < 0) break
            try {
                from.write(buffer, 0, n)
            } catch (_: IOException) {
                call.cancel()
                report("[Weiterleiter] $path abgebrochen nach $sent Bytes")
                return
            }
            sent += n
        }
        runCatching { from.flush() }
    }

    private fun everything(on: InputStream, limit: Int): ByteArray? {
        val out = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(Piece)
        while (true) {
            val n = try { on.read(buffer) } catch (_: IOException) { return null }
            if (n < 0) return out.toByteArray()
            out.write(buffer, 0, n)
            if (out.size() > limit) return null
        }
    }

    // MARK: Playlists

    /**
     * Point absolute addresses and root-relative paths in an HLS playlist at the relay. Relative ones
     * stay: VLC resolves them against the playlist's address, which already points here.
     */
    internal fun listWrite(text: String, mark: String): String {
        fun bend(a: String): String {
            if (a.startsWith("/") && !a.startsWith("//")) return "/$mark$a"
            val small = a.lowercase()
            if (small.startsWith("http://") || small.startsWith("https://")) return address(a)
            return a
        }
        return text.split("\n").joinToString("\n") { raw ->
            var row = raw
            val cr = row.endsWith("\r")
            if (cr) row = row.dropLast(1)
            val trimmed = row.trim()
            if (trimmed.isEmpty()) {
                // stays
            } else if (trimmed.startsWith("#")) {
                // URI="..." in EXT-X-MAP, EXT-X-MEDIA, EXT-X-KEY ...
                val a = row.indexOf("URI=\"")
                if (a >= 0) {
                    val start = a + 5
                    val e = row.indexOf('"', start)
                    if (e >= 0) row = row.substring(0, start) + bend(row.substring(start, e)) + row.substring(e)
                }
            } else {
                row = bend(trimmed)
            }
            if (cr) "$row\r" else row
        }
    }

    // MARK: Response head

    internal fun header(status: Int, fields: Map<String, String>, length: Int?): ByteArray {
        val reason = when (status) {
            200 -> "OK"; 206 -> "Partial Content"; 404 -> "Not Found"
            405 -> "Method Not Allowed"; 502 -> "Bad Gateway"; else -> "Status"
        }
        val s = StringBuilder("HTTP/1.1 $status $reason\r\n")
        for ((n, w) in fields.toSortedMap()) s.append("$n: $w\r\n")
        if (length != null) s.append("Content-Length: $length\r\n")
        s.append("Connection: close\r\n\r\n")
        return s.toString().toByteArray(Charsets.ISO_8859_1)
    }
}

/** VLC's request: method, target, headers with lower-case names. */
internal class RequestHeader(val procedure: String, val target: String, val headers: Map<String, String>) {
    companion object {
        /** Read up to the blank line. More than 64 KiB of head is not a VLC request. */
        fun read(on: InputStream): RequestHeader? {
            val buffer = java.io.ByteArrayOutputStream()
            var last = 0
            while (buffer.size() < 65536) {
                val b = try { on.read() } catch (_: IOException) { return null }
                if (b < 0) return null
                buffer.write(b)
                last = (last shl 8) or b
                if (last == 0x0d0a0d0a) return dismantle(buffer.toString("ISO-8859-1"))
            }
            return null
        }

        fun dismantle(text: String): RequestHeader? {
            val rows = text.split("\r\n")
            val first = rows.firstOrNull()?.split(" ")?.filter { it.isNotEmpty() } ?: return null
            if (first.size < 2) return null
            val headers = HashMap<String, String>()
            for (z in rows.drop(1)) {
                val d = z.indexOf(':')
                if (d < 0) continue
                headers[z.substring(0, d).trim().lowercase()] = z.substring(d + 1).trim()
            }
            return RequestHeader(first[0], first[1], headers)
        }
    }
}
