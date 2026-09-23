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
 * Der Weiterleiter vor VLC (Issue #4) gegen einen Vorposten im Test — dieselben Faelle wie
 * `StromweiterleiterTests` in JellyfinKit, dazu: **Pause und Abbruch wirken sofort**, nicht erst an
 * der Obergrenze.
 */
class StromweiterleiterTest {

    /** 1 MiB, jedes Byte aus seiner Stelle ableitbar. */
    private val datei = ByteArray(1 shl 20) { (it * 31 + 7).toByte() }

    private fun weiterleiter(posten: Vorposten?): Stromweiterleiter {
        val koepfe: (String) -> Map<String, String> = { url ->
            if (posten != null && url.startsWith("http://127.0.0.1:${posten.port}/")) mapOf("X-Vorposten" to "offen") else emptyMap()
        }
        // Wie `EigenkoepfeAbfang`, nur mit der Tafel des Tests.
        val abfang = Interceptor { kette ->
            val a = kette.request()
            val f = koepfe(a.url.toString())
            if (f.isEmpty()) kette.proceed(a)
            else kette.proceed(a.newBuilder().apply { f.forEach { (n, w) -> header(n, w) } }.build())
        }
        return Stromweiterleiter(koepfe, OkHttpClient.Builder().addInterceptor(abfang).build())
    }

    @Test fun ohneKoepfeBleibtDieAdresse() {
        val w = weiterleiter(null)
        val u = "https://ohne-koepfe.test/Videos/1/stream.mkv?static=true"
        assertEquals(u, w.adresse(u))
        assertEquals(0, w.aktuellerPort)
    }

    @Test fun koepfeGehenMit() {
        Vorposten(datei).use { posten ->
            val w = weiterleiter(posten)
            assertEquals(403, roh(posten.port, "/Videos/1/stream.mkv").status)
            val umgelenkt = URI(w.adresse(posten.url("/Videos/1/stream.mkv?static=true&api_key=geheim")))
            assertEquals("127.0.0.1", umgelenkt.host)
            assertEquals(w.aktuellerPort, umgelenkt.port)
            assertTrue(umgelenkt.path.endsWith("/Videos/1/stream.mkv"))
            assertEquals("static=true&api_key=geheim", umgelenkt.rawQuery)
            val a = roh(umgelenkt)
            assertEquals(200, a.status)
            assertEquals("${datei.size}", a.felder["content-length"])
            assertTrue(a.koerper.contentEquals(datei))
            assertEquals("static=true&api_key=geheim", posten.letzteAbfrage)
        }
    }

    @Test fun bereichAufMehrerenVerbindungen() {
        Vorposten(datei).use { posten ->
            val w = weiterleiter(posten)
            val u = URI(w.adresse(posten.url("/Videos/1/stream.mkv")))
            val fertig = CountDownLatch(6)
            val fehler = AtomicInteger(0)
            repeat(6) { i ->
                Thread {
                    val von = i * 100_000 + 17; val bis = von + 4_999
                    val a = roh(u, "bytes=$von-$bis")
                    val gut = a.status == 206 && a.felder["content-range"] == "bytes $von-$bis/${datei.size}" &&
                        a.felder["accept-ranges"] == "bytes" && a.koerper.contentEquals(datei.copyOfRange(von, bis + 1))
                    if (!gut) fehler.incrementAndGet()
                    fertig.countDown()
                }.start()
            }
            assertTrue(fertig.await(20, TimeUnit.SECONDS))
            assertEquals(0, fehler.get())
        }
    }

    @Test fun falscheMarke() {
        Vorposten(datei).use { posten ->
            val w = weiterleiter(posten)
            val u = URI(w.adresse(posten.url("/Videos/1/stream.mkv")))
            val marke = u.path.split("/")[1]
            assertEquals(404, roh(w.aktuellerPort, "/${marke.reversed()}/Videos/1/stream.mkv").status)
            assertEquals(404, roh(w.aktuellerPort, "/Videos/1/stream.mkv").status)
            assertEquals(0, posten.anfragen.get())
        }
    }

    @Test fun abbruchWirktSofort() {
        Vorposten(datei).use { posten ->
            val w = weiterleiter(posten)
            val u = URI(w.adresse(posten.url("/endlos")))
            val v = Socket(InetAddress.getByName("127.0.0.1"), u.port)
            v.getOutputStream().write("GET ${u.rawPath} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".toByteArray())
            val puffer = ByteArray(65536)
            var gelesen = 0
            val ein = v.getInputStream()
            while (gelesen < 200_000) { val n = ein.read(puffer); if (n <= 0) break; gelesen += n }
            assertTrue(gelesen >= 200_000)
            v.close()
            // Der Vorposten merkt es, wenn sein Senden scheitert — in weniger als einer Sekunde.
            repeat(20) { if (!posten.endlosAbgebrochen.get()) Thread.sleep(50) }
            assertTrue("Anfrage beim Server lief weiter", posten.endlosAbgebrochen.get())
        }
    }

    @Test fun pauseHaeltDenServerAn() {
        Vorposten(datei).use { posten ->
            val w = weiterleiter(posten)
            val u = URI(w.adresse(posten.url("/endlos")))
            Socket(InetAddress.getByName("127.0.0.1"), u.port).use { v ->
                v.getOutputStream().write("GET ${u.rawPath} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".toByteArray())
                assertTrue(v.getInputStream().read(ByteArray(65536)) > 0)
                Thread.sleep(1500)
                val a = posten.endlosGesendet.get()
                Thread.sleep(1000)
                val b = posten.endlosGesendet.get()
                // Steht still — nur die Steckdosenpuffer sind gefuellt, kein Vorrat bis 64 MiB.
                assertTrue("lief weiter: ${b - a}", b - a < (1 shl 20))
                assertTrue("zu viel gepuffert: $b", b < (16 shl 20))
                assertTrue(!posten.endlosAbgebrochen.get())
            }
        }
    }

    @Test fun listeWirdUmgeschrieben() {
        Vorposten(datei).use { posten ->
            val w = weiterleiter(posten)
            val u = URI(w.adresse(posten.url("/Videos/1/master.m3u8?api_key=geheim")))
            val marke = u.path.split("/")[1]
            val a = roh(u)
            assertEquals(200, a.status)
            val text = String(a.koerper)
            val zeilen = text.split("\n")
            assertTrue(zeilen.contains("main.m3u8?api_key=geheim"))
            assertTrue(zeilen.contains("/$marke/Videos/1/hls/0.ts"))
            assertTrue(zeilen.contains("http://127.0.0.1:${w.aktuellerPort}/$marke/Videos/1/hls/1.ts"))
            assertTrue(zeilen.contains("https://fremd.test/werbung.ts"))
            assertTrue(text.contains("URI=\"/$marke/Videos/1/init.mp4\""))
            assertEquals("${a.koerper.size}", a.felder["content-length"])
        }
    }

    @Test fun anfragekopf() {
        val k = Anfragekopf.zerlegen("GET /a/b?c=d HTTP/1.1\r\nRange: bytes=0-\r\nUser-Agent: VLC\r\n\r\n")
        assertNotNull(k)
        assertEquals("GET", k!!.verfahren)
        assertEquals("/a/b?c=d", k.ziel)
        assertEquals("bytes=0-", k.koepfe["range"])
        assertEquals("VLC", k.koepfe["user-agent"])
    }

    // MARK: Werkzeug

    private class Rohantwort(val status: Int = 0, val felder: Map<String, String> = emptyMap(), val koerper: ByteArray = ByteArray(0))

    private fun roh(u: URI, range: String? = null): Rohantwort =
        roh(u.port, u.rawPath + (u.rawQuery?.let { "?$it" } ?: ""), range)

    /** Eine Anfrage, wie VLC sie stellt, ueber eine rohe Steckdose. */
    private fun roh(port: Int, pfad: String, range: String? = null): Rohantwort {
        Socket(InetAddress.getByName("127.0.0.1"), port).use { v ->
            var kopf = "GET $pfad HTTP/1.1\r\nHost: 127.0.0.1:$port\r\nUser-Agent: VLC/4.0.0\r\n"
            if (range != null) kopf += "Range: $range\r\n"
            v.getOutputStream().write((kopf + "\r\n").toByteArray())
            val alles = v.getInputStream().readBytes()
            val t = (0..alles.size - 4).firstOrNull {
                alles[it] == 13.toByte() && alles[it + 1] == 10.toByte() && alles[it + 2] == 13.toByte() && alles[it + 3] == 10.toByte()
            } ?: return Rohantwort()
            val zeilen = String(alles, 0, t, Charsets.ISO_8859_1).split("\r\n")
            val status = zeilen.first().split(" ").getOrNull(1)?.toIntOrNull() ?: 0
            val felder = zeilen.drop(1).mapNotNull { z ->
                val d = z.indexOf(':'); if (d < 0) null else z.substring(0, d).lowercase() to z.substring(d + 1).trim()
            }.toMap()
            return Rohantwort(status, felder, alles.copyOfRange(t + 4, alles.size))
        }
    }

    /** Ein Server hinter einem Vorposten: ohne `X-Vorposten: offen` gibt es 403. */
    private class Vorposten(private val datei: ByteArray) : AutoCloseable {
        private val lauscher = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
        val port: Int = lauscher.localPort
        val anfragen = AtomicInteger(0)
        @Volatile var letzteAbfrage: String? = null
        val endlosAbgebrochen = AtomicBoolean(false)
        val endlosGesendet = AtomicLong(0)

        init {
            Thread {
                while (true) {
                    val v = try { lauscher.accept() } catch (_: Exception) { break }
                    Thread { try { bedienen(v) } catch (_: Exception) {} finally { runCatching { v.close() } } }.start()
                }
            }.apply { isDaemon = true }.start()
        }

        override fun close() { lauscher.close() }

        fun url(pfad: String) = "http://127.0.0.1:$port$pfad"

        private fun bedienen(v: Socket) {
            val a = Anfragekopf.lesen(java.io.BufferedInputStream(v.getInputStream())) ?: return
            val aus: OutputStream = v.getOutputStream()
            if (a.koepfe["x-vorposten"] != "offen") {
                aus.write("HTTP/1.1 403 Forbidden\r\nContent-Type: text/html\r\nContent-Length: 5\r\nConnection: close\r\n\r\nnein!".toByteArray())
                return
            }
            val teile = a.ziel.split("?", limit = 2)
            anfragen.incrementAndGet()
            letzteAbfrage = teile.getOrNull(1)
            when (teile[0]) {
                "/endlos" -> {
                    aus.write("HTTP/1.1 200 OK\r\nContent-Type: video/x-matroska\r\nConnection: close\r\n\r\n".toByteArray())
                    val stueck = ByteArray(16384) { 0x42 }
                    try {
                        repeat(100_000) { aus.write(stueck); endlosGesendet.addAndGet(stueck.size.toLong()) }
                    } catch (_: Exception) {}
                    endlosAbgebrochen.set(true)
                }
                "/Videos/1/master.m3u8" -> {
                    val liste = listOf("#EXTM3U", "#EXT-X-MAP:URI=\"/Videos/1/init.mp4\"", "main.m3u8?api_key=geheim",
                        "/Videos/1/hls/0.ts", url("/Videos/1/hls/1.ts"), "https://fremd.test/werbung.ts").joinToString("\n")
                    val d = liste.toByteArray()
                    aus.write("HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: ${d.size}\r\nConnection: close\r\n\r\n".toByteArray())
                    aus.write(d)
                }
                else -> {
                    var von = 0; var bis = datei.size - 1; var status = "200 OK"; var bereich = ""
                    val r = a.koepfe["range"]
                    if (r != null && r.startsWith("bytes=")) {
                        val z = r.substring(6).split("-")
                        von = z[0].toIntOrNull() ?: 0
                        z.getOrNull(1)?.toIntOrNull()?.let { bis = minOf(it, datei.size - 1) }
                        status = "206 Partial Content"
                        bereich = "Content-Range: bytes $von-$bis/${datei.size}\r\n"
                    }
                    aus.write("HTTP/1.1 $status\r\nContent-Type: video/x-matroska\r\nAccept-Ranges: bytes\r\n${bereich}Content-Length: ${bis - von + 1}\r\nConnection: close\r\n\r\n".toByteArray())
                    aus.write(datei, von, bis - von + 1)
                }
            }
            aus.flush()
        }
    }
}
