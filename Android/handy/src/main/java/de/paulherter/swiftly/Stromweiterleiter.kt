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
 * **Der Weiterleiter vor libVLC — fuer Server hinter einem Vorposten (Issue #4).** Vorlage:
 * `Stromweiterleiter` in JellyfinKit; Verhalten und Grenzen wie dort, Tests nach
 * `StromweiterleiterTests`.
 *
 * libVLC setzt keine beliebigen Header. Hinter Cloudflare Access, Authelia oder Pangolin holt die App
 * den Strom deshalb selbst: ein kleiner HTTP-Dienst auf `127.0.0.1:<Port>` nimmt VLCs Anfrage an, holt
 * dieselbe Adresse beim Server — mit den eigenen Headern ueber [EigenkoepfeAbfang] — und reicht Status,
 * die Header zum Spulen und den Koerper gestreamt durch.
 *
 * **Warum OkHttp und nicht mehr der Weiterleiter im Kern** (`Kern.stromAdresse`, 2b380379): der lief
 * auf swift-corelibs-foundation, und dort haelt `suspend()` eine Uebertragung nicht an und ein
 * abgebrochener Auftrag meldet sein Ende nicht. Bei Pause lud er bis zur Obergrenze von 64 MiB weiter,
 * nach dem Schliessen des Players lief die Anfrage beim Server weiter. Hier wird blockierend gelesen
 * und geschrieben: liest VLC nicht (Pause), blockiert das Schreiben, es wird nicht mehr gelesen, und
 * TCP bremst den Server — ohne Vorrat. Schliesst VLC die Verbindung, scheitert das naechste Schreiben
 * und der Aufruf wird sofort abgebrochen.
 *
 * - **Nur wenn Header eingetragen sind**, sonst bleibt die Adresse unveraendert.
 * - **Nur an 127.0.0.1**, und jeder Ursprung bekommt eine zufaellige Marke (128 Bit) als ersten
 *   Pfadteil; eine fremde App kennt sie nicht und bekommt 404.
 * - **Range geht 1:1 durch**, `Content-Range`/`Content-Length` unveraendert zurueck.
 * - **HLS:** absolute und wurzelbezogene Adressen in Wiedergabelisten werden umgeschrieben.
 */
class Stromweiterleiter(
    /** Die eigenen Header fuer eine Adresse — leer heisst: nicht umleiten. */
    private val koepfe: (String) -> Map<String, String>,
    /** Der Aufrufer, der die Header anhaengt (in der App mit [EigenkoepfeAbfang]). */
    klient: OkHttpClient,
    /** Nur Verfahren, Pfad, Status — nie Werte, nie Abfragen. */
    private val melden: (String) -> Unit = {},
) {
    companion object {
        /** Der eine fuer die App. Tests bauen sich eigene. */
        val gemeinsam: Stromweiterleiter by lazy {
            Stromweiterleiter(
                koepfe = ::eigenkoepfeFelder,
                klient = OkHttpClient.Builder().addInterceptor(EigenkoepfeAbfang).build(),
                melden = { Protokoll.schreib(it) },
            )
        }

        /** Wiedergabelisten sind klein; groesser ist keine. */
        const val LISTENGRENZE = 4 shl 20
        /** Stueckgroesse beim Durchreichen. */
        private const val STUECK = 64 shl 10
    }

    private val sitzung: OkHttpClient = klient.newBuilder()
        .cache(null)
        // Leerlauf zwischen zwei Lesungen, nicht Gesamtdauer: ein Film laeuft Stunden.
        .readTimeout(60, TimeUnit.SECONDS)
        .callTimeout(0, TimeUnit.MILLISECONDS)
        .build()

    private val sperre = Any()
    private var lauscher: ServerSocket? = null
    private var port = 0
    private val ursprungFuerMarke = HashMap<String, String>()
    private val markeFuerUrsprung = HashMap<String, String>()

    // MARK: Adresse

    /**
     * Die Adresse, die VLC bekommen soll. Unveraendert ohne eingetragene Header, fuer alles ausser
     * `http(s)` und wenn nicht gelauscht werden kann.
     */
    fun adresse(url: String): String {
        if (koepfe(url).isEmpty()) return url
        val u = runCatching { URI(url) }.getOrNull() ?: return url
        val schema = u.scheme?.lowercase() ?: return url
        if (schema != "http" && schema != "https") return url
        val rechner = u.rawAuthority?.substringAfterLast('@') ?: return url
        if (rechner.isEmpty()) return url
        val ursprung = "$schema://$rechner"
        synchronized(sperre) {
            val p = lauschenGesperrt() ?: return url
            val marke = markeFuerUrsprung.getOrPut(ursprung) {
                neueMarke().also { ursprungFuerMarke[it] = ursprung }
            }
            val pfad = u.rawPath.takeUnless { it.isNullOrEmpty() } ?: "/"
            val abfrage = u.rawQuery?.let { "?$it" } ?: ""
            return "http://127.0.0.1:$p/$marke$pfad$abfrage"
        }
    }

    /** Der Port, auf dem gerade gelauscht wird — 0, solange nicht. */
    val aktuellerPort: Int get() = synchronized(sperre) { if (lauscher == null) 0 else port }

    /** Aus VLCs Anfragepfad die Adresse beim Server — `null` bei falscher Marke. */
    internal fun ziel(anfragepfad: String): Pair<String, String>? {
        if (!anfragepfad.startsWith("/")) return null
        val ohne = anfragepfad.substring(1)
        val ende = ohne.indexOfFirst { it == '/' || it == '?' }.let { if (it < 0) ohne.length else it }
        val marke = ohne.substring(0, ende)
        var rest = ohne.substring(ende)
        if (!rest.startsWith("/")) rest = "/$rest"
        val ursprung = synchronized(sperre) { ursprungFuerMarke[marke] } ?: return null
        return (ursprung + rest) to marke
    }

    private fun neueMarke(): String {
        val b = ByteArray(16).also { SecureRandom().nextBytes(it) }
        return b.joinToString("") { "%02x".format(it) }
    }

    // MARK: Lauschen

    /** Nach einem Neustart zuerst derselbe Port — VLC haelt vielleicht noch die alte Adresse. **Sperre gehalten.** */
    private fun lauschenGesperrt(): Int? {
        lauscher?.let { return port }
        val s = runCatching { binden(port) }.getOrNull() ?: runCatching { binden(0) }.getOrNull()
        if (s == null) { melden("[Weiterleiter] Lauschen gescheitert"); return null }
        lauscher = s
        port = s.localPort
        melden("[Weiterleiter] lauscht auf 127.0.0.1:$port")
        Thread({ annehmen(s) }, "Stromweiterleiter").apply { isDaemon = true }.start()
        return port
    }

    private fun binden(p: Int): ServerSocket = ServerSocket().apply {
        reuseAddress = true
        bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), p), 16)
    }

    private fun annehmen(s: ServerSocket) {
        while (true) {
            val v = try { s.accept() } catch (_: IOException) {
                synchronized(sperre) { if (lauscher === s) lauscher = null }
                runCatching { s.close() }
                melden("[Weiterleiter] Lauscher beendet")
                return
            }
            Thread({
                try { bedienen(v) } catch (_: Exception) {} finally { runCatching { v.close() } }
            }, "Stromweiterleiter.Verbindung").apply { isDaemon = true }.start()
        }
    }

    // MARK: Eine Verbindung

    private fun bedienen(v: Socket) {
        v.soTimeout = 30_000
        val eingang = java.io.BufferedInputStream(v.getInputStream())
        val aus = v.getOutputStream()
        val anfrage = Anfragekopf.lesen(eingang) ?: return
        if (anfrage.verfahren != "GET" && anfrage.verfahren != "HEAD") {
            aus.write(kopf(405, mapOf("Allow" to "GET, HEAD"), 0)); return
        }
        val (url, marke) = ziel(anfrage.ziel) ?: run {
            melden("[Weiterleiter] fremde Marke abgewiesen")
            aus.write(kopf(404, emptyMap(), 0)); return
        }
        val r = Request.Builder().url(url).method(anfrage.verfahren, null)
        // Unveraendert durch, was fuers Spulen zaehlt. Kekse und Icy-MetaData bleiben draussen.
        for (name in listOf("Range", "If-Range", "User-Agent", "Accept")) {
            anfrage.koepfe[name.lowercase()]?.let { r.header(name, it) }
        }
        // Sonst packt OkHttp aus und Content-Length stimmt nicht mehr.
        r.header("Accept-Encoding", "identity")

        val aufruf: Call = sitzung.newCall(r.build())
        val pfad = runCatching { URI(url).path }.getOrDefault("")
        val antwort: Response = try { aufruf.execute() } catch (_: IOException) {
            melden("[Weiterleiter] ${anfrage.verfahren} $pfad → keine Antwort vom Server")
            aus.write(kopf(502, emptyMap(), 0)); return
        }
        antwort.use { a ->
            val bereich = anfrage.koepfe["range"]?.let { " $it" } ?: ""
            melden("[Weiterleiter] ${anfrage.verfahren} $pfad$bereich → ${a.code}")
            val felder = LinkedHashMap<String, String>()
            for (name in listOf("Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "Last-Modified", "ETag")) {
                a.header(name)?.let { felder[name] = it }
            }
            if (a.header("Content-Encoding") != null) felder.remove("Content-Length")

            if (anfrage.verfahren == "HEAD") { aus.write(kopf(a.code, felder, null)); return }

            val typ = (felder["Content-Type"] ?: "").lowercase()
            if (typ.contains("mpegurl") || pfad.lowercase().endsWith(".m3u8")) {
                val roh = a.body?.let { alles(it.byteStream(), LISTENGRENZE) } ?: run {
                    aus.write(kopf(502, emptyMap(), 0)); return
                }
                val neu = listeUmschreiben(String(roh, Charsets.UTF_8), marke).toByteArray(Charsets.UTF_8)
                felder.remove("Content-Length")
                aus.write(kopf(a.code, felder, neu.size)); aus.write(neu); aus.flush()
                return
            }

            try { aus.write(kopf(a.code, felder, null)); aus.flush() } catch (_: IOException) { aufruf.cancel(); return }
            a.body?.let { durchreichen(it.byteStream(), aus, aufruf, pfad) }
        }
    }

    /**
     * **Blockierend durchreichen.** Liest VLC nicht, blockiert `write`, und es wird beim Server nichts
     * mehr gelesen — kein Vorrat. Scheitert das Schreiben, ist VLC weg: sofort abbrechen.
     */
    private fun durchreichen(ein: InputStream, aus: OutputStream, aufruf: Call, pfad: String) {
        val puffer = ByteArray(STUECK)
        var gesendet = 0L
        while (true) {
            val n = try { ein.read(puffer) } catch (_: IOException) { -1 }
            if (n < 0) break
            try {
                aus.write(puffer, 0, n)
            } catch (_: IOException) {
                aufruf.cancel()
                melden("[Weiterleiter] $pfad abgebrochen nach $gesendet Bytes")
                return
            }
            gesendet += n
        }
        runCatching { aus.flush() }
    }

    private fun alles(ein: InputStream, grenze: Int): ByteArray? {
        val raus = java.io.ByteArrayOutputStream()
        val puffer = ByteArray(STUECK)
        while (true) {
            val n = try { ein.read(puffer) } catch (_: IOException) { return null }
            if (n < 0) return raus.toByteArray()
            raus.write(puffer, 0, n)
            if (raus.size() > grenze) return null
        }
    }

    // MARK: Wiedergabelisten

    /**
     * Absolute Adressen und wurzelbezogene Pfade in einer HLS-Liste auf den Weiterleiter umbiegen.
     * Relative bleiben — VLC loest sie gegen die Adresse der Liste auf, und die zeigt schon hierher.
     */
    internal fun listeUmschreiben(text: String, marke: String): String {
        fun umbiegen(a: String): String {
            if (a.startsWith("/") && !a.startsWith("//")) return "/$marke$a"
            val klein = a.lowercase()
            if (klein.startsWith("http://") || klein.startsWith("https://")) return adresse(a)
            return a
        }
        return text.split("\n").joinToString("\n") { roh ->
            var zeile = roh
            val cr = zeile.endsWith("\r")
            if (cr) zeile = zeile.dropLast(1)
            val getrimmt = zeile.trim()
            if (getrimmt.isEmpty()) {
                // bleibt
            } else if (getrimmt.startsWith("#")) {
                // URI="…" in EXT-X-MAP, EXT-X-MEDIA, EXT-X-KEY …
                val a = zeile.indexOf("URI=\"")
                if (a >= 0) {
                    val start = a + 5
                    val e = zeile.indexOf('"', start)
                    if (e >= 0) zeile = zeile.substring(0, start) + umbiegen(zeile.substring(start, e)) + zeile.substring(e)
                }
            } else {
                zeile = umbiegen(getrimmt)
            }
            if (cr) "$zeile\r" else zeile
        }
    }

    // MARK: Antwortkopf

    internal fun kopf(status: Int, felder: Map<String, String>, laenge: Int?): ByteArray {
        val grund = when (status) {
            200 -> "OK"; 206 -> "Partial Content"; 404 -> "Not Found"
            405 -> "Method Not Allowed"; 502 -> "Bad Gateway"; else -> "Status"
        }
        val s = StringBuilder("HTTP/1.1 $status $grund\r\n")
        for ((n, w) in felder.toSortedMap()) s.append("$n: $w\r\n")
        if (laenge != null) s.append("Content-Length: $laenge\r\n")
        s.append("Connection: close\r\n\r\n")
        return s.toString().toByteArray(Charsets.ISO_8859_1)
    }
}

/** VLCs Anfrage: Verfahren, Ziel, Header mit kleinen Namen. */
internal class Anfragekopf(val verfahren: String, val ziel: String, val koepfe: Map<String, String>) {
    companion object {
        /** Bis zur Leerzeile lesen. Mehr als 64 KiB Kopf ist keine VLC-Anfrage. */
        fun lesen(ein: InputStream): Anfragekopf? {
            val puffer = java.io.ByteArrayOutputStream()
            var letzte = 0
            while (puffer.size() < 65536) {
                val b = try { ein.read() } catch (_: IOException) { return null }
                if (b < 0) return null
                puffer.write(b)
                letzte = (letzte shl 8) or b
                if (letzte == 0x0d0a0d0a) return zerlegen(puffer.toString("ISO-8859-1"))
            }
            return null
        }

        fun zerlegen(text: String): Anfragekopf? {
            val zeilen = text.split("\r\n")
            val erste = zeilen.firstOrNull()?.split(" ")?.filter { it.isNotEmpty() } ?: return null
            if (erste.size < 2) return null
            val koepfe = HashMap<String, String>()
            for (z in zeilen.drop(1)) {
                val d = z.indexOf(':')
                if (d < 0) continue
                koepfe[z.substring(0, d).trim().lowercase()] = z.substring(d + 1).trim()
            }
            return Anfragekopf(erste[0], erste[1], koepfe)
        }
    }
}
