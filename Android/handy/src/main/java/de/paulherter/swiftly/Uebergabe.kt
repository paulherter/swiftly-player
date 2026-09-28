package de.paulherter.swiftly

import android.content.Context
import android.graphics.Bitmap
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import android.view.Surface
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.requiredWidth
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.SingletonImageLoader
import coil3.compose.AsyncImage
import coil3.request.ImageRequest
import coil3.request.SuccessResult
import coil3.request.allowHardware
import coil3.toBitmap
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.uebersetzt
import de.paulherter.swiftly.kern.Kern
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import kotlin.coroutines.resume

// MARK: - „Hier weiterschauen" als Karte (Entwurf B) — Handy und Fernseher
//
// Vorlage: `Sources/Shared/Uebergabebuehne.swift` (`Uebergabebuehne`, `Uebergabeabgang`).
// **Alle Zeiten, Federn und Masse kommen aus dem Paket** (`Uebergabekarte`) ueber den Kern
// (`Kern.uebergabeLagen`, `Kern.uebergabeBahn`, `Android/kern/swift/Sources/SwiftlyKern/Uebergabe.swift`)
// — als Stuetzpunkte, 120 je Sekunde, dazwischen geradlinig wie `calculationMode = .linear`. Hier nur
// die Zeichnung: **nur Lage, Groesse und Deckkraft**, im Zeichnen gelesen (`graphicsLayer`), keine Effekte.
// Bewegung reduzieren (Animator-Dauer 0): nur Blenden.
//
// **Ueber allem, auch ueber dem Player**: der Player ist eine eigene Aktivitaet. Die Buehne ist deshalb
// ein Zustand der App (`Uebergabe`), und jede Aktivitaet zeichnet sie zuoberst (`Uebergabeebene`) — nach
// derselben Uhr ab dem Tipp. Geht der Player unter der Karte auf, zeichnet er sie im selben Bild weiter.

/** Stuetzpunkte aus `Kern.uebergabeBahn` — je Punkt x, y, Breite, Ecke, Oberkante der Zeilen (dp). */
class Uebergabebahn(json: String) {
    private val o = JSONObject(json)
    private val t0 = o.optDouble("t0", 0.0)
    private val dt = o.optDouble("dt", 0.0)
    private val l: FloatArray = o.optJSONArray("l")?.let { a -> FloatArray(a.length()) { a.getDouble(it).toFloat() } } ?: FloatArray(0)
    private val d: FloatArray = o.optJSONArray("d")?.let { a -> FloatArray(a.length()) { a.getDouble(it).toFloat() } } ?: FloatArray(0)
    private val dn = o.optInt("dn", 0)
    val raus: Double? = if (o.has("raus") && !o.isNull("raus")) o.getDouble("raus") else null
    /** `neu`: die Lage bei `ab`; `abgang`: die Karte in Ruhe (x, y, Breite). */
    val lage: FloatArray? = o.optJSONArray("lage")?.let { a -> FloatArray(a.length()) { a.getDouble(it).toFloat() } }

    private fun stelle(t: Double, anzahl: Int): Pair<Int, Float> {
        if (anzahl <= 1 || dt <= 0) return 0 to 0f
        val s = ((t - t0) / dt).coerceIn(0.0, (anzahl - 1).toDouble())
        val i = s.toInt().coerceAtMost(anzahl - 2)
        return i to (s - i).toFloat()
    }

    /** x, y, Breite, Ecke, Zeilen-Oberkante zur Zeit `t`, geradlinig zwischen den Punkten. */
    fun lage(t: Double): FloatArray {
        val n = l.size / 5
        if (n == 0) return FloatArray(5)
        val (i, f) = stelle(t, n)
        return FloatArray(5) { k -> val a = l[i * 5 + k]; if (n == 1) a else a + (l[(i + 1) * 5 + k] - a) * f }
    }

    fun deckung(t: Double, k: Int = 0): Float {
        if (dn == 0) return 1f
        val n = d.size / dn
        if (n == 0) return 1f
        val (i, f) = stelle(t, n)
        val a = d[i * dn + k]
        return if (n == 1) a else a + (d[(i + 1) * dn + k] - a) * f
    }
}

/** Die Zeiten aus dem Paket (`Uebergabebahn.Zeiten` im Kern). */
class Uebergabezeiten(o: JSONObject) {
    val seiteBis = o.getDouble("seiteBis")
    val kartenStart = o.getDouble("kartenStart")
    val schweben = o.getDouble("schweben")
    val ladelinieAb = o.getDouble("ladelinieAb")
    val ladelinieEinblenden = o.getDouble("ladelinieEinblenden")
    val ladelinieTakt = o.getDouble("ladelinieTakt")
    val zeilenAus = o.getDouble("zeilenAus")
    val schwarzDauer = o.getDouble("schwarzDauer")
    val kartenAusVon = o.getDouble("kartenAusVon")
    val ende = o.getDouble("ende")
    val hoechstensWarten = o.getDouble("hoechstensWarten")
    val blende = o.getDouble("blende")
    val blendeAus = o.getDouble("blendeAus")
    val abgangStart = o.getDouble("abgangStart")
    val wartenBis = o.getDouble("wartenBis")
}

/** Vollbild, Ruhelage und Masse fuer einen Schirm (`Kern.uebergabeLagen`), alles in dp. */
class Uebergabelagen(json: String) {
    private val o = JSONObject(json)
    private fun drei(n: String) = o.getJSONArray(n).let { a -> DoubleArray(3) { a.getDouble(it) } }
    val voll = drei("voll")
    val ruhe = drei("ruhe")
    private val m = o.getJSONObject("masse")
    val ecke = m.getDouble("ecke")
    val titel = m.getDouble("titel")
    val klein = m.getDouble("klein")
    val abstand = m.getDouble("abstand")
    val zeiten = Uebergabezeiten(o.getJSONObject("zeiten"))
}

private fun liste(vararg d: Double) = d.joinToString(",", "[", "]")

/** Titel und Folge unter der Karte — `Uebergabestil.zeilen`: „The Mentalist" und „Staffel 6 · Folge 7". */
internal fun uebergabezeilen(name: String, serie: String?, staffel: Int?, folge: Int?): Pair<String, String?> =
    if (!serie.isNullOrEmpty()) serie to (if (staffel != null && folge != null) uebersetzt("Staffel %lld · Folge %lld", staffel, folge) else name)
    else name to null

object Uebergabe {
    private fun notiz(text: String) = Protokoll.schreib("[Uebergabe] $text")

    /** Wie dieses Geraet im Hinweis an den Abgeber heisst — `Uebergabekarte.groessenrang` kennt beide. */
    fun eigenerName(app: SwiftlyAnwendung) = if (app.istFernseher) "Android TV" else "Android"

    /** Die Zeiten, einmal gelesen — sie haengen nicht am Schirm. */
    val zeiten: Uebergabezeiten by lazy { Uebergabelagen(Kern.uebergabeLagen(1920.0, 1080.0, false)).zeiten }

    // MARK: Empfaenger

    class Empfang(
        val nummer: Int, val beginn: Long, val itemID: String, val bild: String?,
        val titel: String, val unter: String?,
        /** Wo das Abzeichen stand (dp) — `Abzeichenursprung.punkt`. */
        val ursprung: Offset?, val ruhig: Boolean, val fernseher: Boolean,
    ) {
        var groesse: Pair<Double, Double>? = null
        var lagen by mutableStateOf<Uebergabelagen?>(null)
        var von = DoubleArray(3)
        var flugAb = zeiten.kartenStart
        var warten by mutableStateOf<Uebergabebahn?>(null)
        var deckung by mutableStateOf<Uebergabebahn?>(null)
        var zoom by mutableStateOf<Uebergabebahn?>(null)
        var zoomAb by mutableStateOf<Double?>(null)
        var bereit: Double? = null
        var ladelinieSeit by mutableStateOf<Double?>(null)
        var abbruchSeit by mutableStateOf<Double?>(null)
        fun jetzt() = (System.nanoTime() - beginn) / 1e9
    }

    var empfang by mutableStateOf<Empfang?>(null); private set
    private var laeufe = 0

    /** So breit ist die Karte am Abzeichen, wenn sie aufgeht (`Uebergabestil.abzeichenbreite`, TV halbiert). */
    private fun abzeichenbreite(fernseher: Boolean) = if (fernseher) 30.0 else 44.0

    /**
     * **Beim Tipp** — noch bevor das Netz gefragt ist (`Uebergabebuehne.starten`). `ursprung` in Pixeln
     * der Wurzel; `dichte` rechnet in dp um.
     */
    fun empfangen(app: SwiftlyAnwendung, a: Angebot, ursprung: Offset?, dichte: Float, ruhig: Boolean) {
        laeufe++
        val (titel, unter) = uebergabezeilen(a.name, a.serie, a.staffelNr, a.folgeNr)
        val e = Empfang(laeufe, System.nanoTime(), a.itemID, a.bild, titel, unter,
                        ursprung?.takeIf { it != Offset.Zero }?.let { Offset(it.x / dichte, it.y / dichte) },
                        ruhig, app.istFernseher)
        empfang = e
        notiz("Karte +0 ms ${if (ruhig) "blendet auf (reduziert)" else "wächst aus dem Abzeichen"}")
        // Die Ladelinie nur, wenn das Bild bei 0,75 s noch fehlt (`Uebergabekarte.ladelinie`).
        app.anwendungslauf.launch {
            delay((zeiten.ladelinieAb * 1000).toLong())
            if (empfang !== e || e.zoomAb != null) return@launch
            val b = e.bereit
            if (b == null || b > zeiten.ladelinieAb) { e.ladelinieSeit = e.jetzt(); karte(e, "Ladelinie") }
        }
    }

    private fun karte(e: Empfang, was: String) = notiz("Karte +${(e.jetzt() * 1000).toInt()} ms $was")

    /**
     * **Die Buehne kennt ihren Schirm** — beim ersten Mal die Lagen und die Bahn; dreht er sich, waehrend
     * die Karte wartet, fliegt sie von dort, wo sie gerade ist, in die neue Ruhelage (`neuAusrichten`).
     */
    internal fun schirm(e: Empfang, breite: Double, hoehe: Double) {
        val alt = e.groesse
        if (alt != null && kotlin.math.abs(alt.first - breite) < 0.5 && kotlin.math.abs(alt.second - hoehe) < 0.5) return
        e.groesse = breite to hoehe
        val neu = Uebergabelagen(Kern.uebergabeLagen(breite, hoehe, e.fernseher))
        val vorher = e.lagen
        e.lagen = neu
        if (vorher == null) {
            val u = e.ursprung
            e.von = if (u != null && !e.ruhig) doubleArrayOf(u.x.toDouble(), u.y.toDouble(), abzeichenbreite(e.fernseher)) else neu.ruhe
            e.deckung = Uebergabebahn(Kern.uebergabeBahn("""{"art":"deckung","fernseher":${e.fernseher}}"""))
            // Auch in Ruhe: die Bahn ab der Ruhelage, gelesen nur bei 0 — dort steht sie still.
            e.warten = bahn(e, "warten", 0.0)
            return
        }
        karte(e, "Drehung auf ${breite.toInt()}×${hoehe.toInt()}")
        if (e.zoomAb != null) return
        if (e.ruhig) { e.von = neu.ruhe; e.warten = bahn(e, "warten", 0.0); return }
        val t = e.jetzt()
        val jetzt = Uebergabebahn(Kern.uebergabeBahn("""{"art":"neu","fernseher":${e.fernseher},"von":${liste(*e.von)},""" +
            """"ruhe":${liste(*vorher.ruhe)},"flugAb":${e.flugAb},"ab":$t}"""))
        jetzt.lage?.let { e.von = doubleArrayOf(it[0].toDouble(), it[1].toDouble(), it[2].toDouble()) }
        e.flugAb = t
        e.warten = bahn(e, "warten", t)
    }

    private fun bahn(e: Empfang, art: String, ab: Double): Uebergabebahn {
        val l = e.lagen!!
        return Uebergabebahn(Kern.uebergabeBahn("""{"art":"$art","fernseher":${e.fernseher},"von":${liste(*e.von)},""" +
            """"ruhe":${liste(*l.ruhe)},"voll":${liste(*l.voll)},"flugAb":${e.flugAb},"ab":$ab,"bis":${zeiten.wartenBis}}"""))
    }

    /** Vor dem Start des Players: der Grund ueber der Seite steht, sonst saehe man den Wechsel der Aktivitaet. */
    suspend fun vorDemPlayer() {
        val e = empfang ?: return
        val rest = zeiten.seiteBis - e.jetzt()
        if (rest > 0) delay((rest * 1000).toLong())
    }

    /** **Der Player steht** (unsichtbar unter der Karte). Ab hier wartet sie hoechstens `hoechstensWarten`. */
    fun spielerKommt(app: SwiftlyAnwendung, itemID: String) {
        val e = empfang ?: return
        karte(e, "Player geöffnet")
        app.anwendungslauf.launch {
            delay((zeiten.hoechstensWarten * 1000).toLong())
            if (empfang !== e || e.zoomAb != null || e.abbruchSeit != null) return@launch
            karte(e, "kein erstes Bild — Karte gibt trotzdem frei")
            zoomen(app, e, e.jetzt())
        }
    }

    /** Die naechste Wiedergabe kommt aus dieser Uebergabe — sie startet stumm und blendet den Ton auf. */
    fun empfaengt(itemID: String): Boolean = empfang?.let { it.itemID == itemID && it.zoomAb == null && it.abbruchSeit == null } == true

    /** **Das erste Bild steht** — jetzt zoomt die Karte (fruehestens bei `schweben`). */
    fun bildDa(app: SwiftlyAnwendung, itemID: String) {
        val e = empfang ?: return
        if (e.zoomAb != null || e.abbruchSeit != null || e.itemID != itemID) return
        karte(e, "erstes Bild")
        zoomen(app, e, e.jetzt())
    }

    private fun zoomen(app: SwiftlyAnwendung, e: Empfang, t: Double) {
        e.bereit = t
        val z = if (e.ruhig) t else maxOf(zeiten.schweben, t)
        if (!e.ruhig && e.lagen != null) e.zoom = bahn(e, "zoom", z)
        e.zoomAb = z
        karte(e, "Zoom ab +${(z * 1000).toInt()} ms")
        val bis = z + if (e.ruhig) zeiten.blendeAus + 0.05 else zeiten.ende
        app.anwendungslauf.launch {
            delay(((bis - e.jetzt()) * 1000).toLong().coerceAtLeast(0))
            if (empfang !== e) return@launch
            karte(e, "fertig")
            empfang = null
        }
    }

    /** **Die Uebergabe ist gescheitert** oder der Player ging vorher zu: die Buehne blendet aus. */
    fun abbrechen(app: SwiftlyAnwendung, grund: String) {
        val e = empfang ?: return
        if (e.abbruchSeit != null) return
        karte(e, "abgebrochen: $grund")
        e.abbruchSeit = e.jetzt()
        app.anwendungslauf.launch {
            delay(((zeiten.blende + 0.05) * 1000).toLong())
            if (empfang === e) empfang = null
        }
    }

    /** Der Player ging zu, bevor die Karte ihn freigab. */
    fun spielerWeg(app: SwiftlyAnwendung, itemID: String) {
        val e = empfang ?: return
        if (e.itemID == itemID && e.zoomAb == null) abbrechen(app, "Player geschlossen")
    }

    // MARK: Abgeber

    class Abgang(val nummer: Int, val beginn: Long, val bild: ImageBitmap, val voll: DoubleArray, val seiten: Double,
                 val titel: String, val unter: String?, val ruhig: Boolean, val bahn: Uebergabebahn?,
                 val lagen: Uebergabelagen, val raus: Double) {
        fun jetzt() = (System.nanoTime() - beginn) / 1e9
    }

    var abgang by mutableStateOf<Abgang?>(null); private set

    /**
     * **Das Bild des Abgebers geht als Karte** (`Uebergabeabgang.starten`): der Player haelt an, das stehende
     * Bild kommt heraus (ist es schwarz, das Folgenbild), und die Buehne legt sich damit genau an die Stelle
     * des Videos, deckend ueber den ganzen Schirm. Die Karte schrumpft, schwebt kurz und fliegt hinaus — zum
     * groesseren Geraet nach oben, zum kleineren nach unten. Dann `fertig`: der Player schliesst.
     * `false`, wenn es weder Standbild noch Folgenbild gibt — dann schliesst der Player wie sonst.
     */
    suspend fun abgeben(app: SwiftlyAnwendung, kontext: Context, flaeche: View?, ziel: String, plan: Spielplan?,
                        ruhig: Boolean, fertig: () -> Unit): Boolean {
        val stopp = System.nanoTime()
        fun zeit(was: String) = notiz("Abgang +${(System.nanoTime() - stopp) / 1_000_000} ms $was")
        zeit("an $ziel${if (ruhig) " (reduziert)" else ""}")
        if (flaeche == null) { zeit("keine Fläche — Player schließt wie sonst"); return false }
        val wurzel = flaeche.rootView
        val dichte = kontext.resources.displayMetrics.density
        val schirmB = wurzel.width / dichte.toDouble()
        val schirmH = wurzel.height / dichte.toDouble()
        // Die Schwerkraft gleich anfordern — die erste Messung kommt nach wenigen Hundertstelsekunden.
        val schwere = if (!app.istFernseher && !ruhig) Schwerkraft(kontext) else null
        try {
            var bild: Bitmap? = null
            var rahmen: Rect? = null
            standbild(flaeche)?.let { (b, r) ->
                val hell = helligkeit(b)
                if (hell < 0.04) zeit("Standbild schwarz (Helligkeit ${"%.3f".format(hell)}) — Folgenbild")
                else { bild = b; rahmen = r; zeit("Standbild da") }
            } ?: zeit("kein Standbild — Folgenbild")
            var seiten = bild?.let { it.width.toDouble() / it.height.coerceAtLeast(1) } ?: (16.0 / 9)
            if (bild == null) {
                val url = plan?.kartenbild
                bild = url?.let { u -> withContext(Dispatchers.IO) { runCatching {
                    (SingletonImageLoader.get(kontext).execute(ImageRequest.Builder(kontext).data(u).size(1280).allowHardware(false).build())
                        as? SuccessResult)?.image?.toBitmap()
                }.getOrNull() } }
                rahmen = flaecheRahmen(flaeche)
                seiten = 16.0 / 9
                if (bild != null) zeit("Folgenbild da")
            }
            val b = bild
            val r = rahmen
            if (b == null || r == null) { zeit("weder Standbild noch Folgenbild — Player schließt wie sonst"); return false }
            // Wo das Video in der Flaeche stand: eingepasst nach dem Bild selbst (dp).
            val rb = r.width / dichte.toDouble(); val rh = r.height / dichte.toDouble()
            val vb = minOf(rb, rh * seiten)
            val voll = doubleArrayOf(r.center.x / dichte.toDouble(), r.center.y / dichte.toDouble(), vb)
            val lagen = Uebergabelagen(Kern.uebergabeLagen(schirmB, schirmH, app.istFernseher))
            val (titel, unter) = plan?.let { p ->
                if (p.episode) uebergabezeilen(p.titel, p.kopfzeile, p.staffelNr, p.folgeNr) else p.titel to null
            } ?: ("" to null)
            val bahn: Uebergabebahn?
            val raus: Double
            if (ruhig) {
                bahn = null
                raus = zeiten.blendeAus
            } else {
                val oben = Kern.uebergabeNachOben(eigenerName(app), ziel)
                val g = schwere?.messung()
                val lage = when (runCatching { flaeche.display?.rotation }.getOrNull()) {
                    Surface.ROTATION_180 -> "kopfueber"
                    Surface.ROTATION_90 -> "querHomeRechts"
                    Surface.ROTATION_270 -> "querHomeLinks"
                    else -> "hoch"
                }
                // Android misst die Gegenkraft (hochkant y = +9,81); `CMDeviceMotion.gravity` die Schwere
                // selbst in g (hochkant y = −1). Also umgedreht und geteilt.
                val schwerkraft = g?.let { ",\"schwerkraft\":${liste(-it[0] / 9.81, -it[1] / 9.81)},\"oberflaeche\":\"$lage\"" } ?: ""
                if (g != null) zeit("Schwerkraft ${"%.2f, %.2f, %.2f".format(-g[0] / 9.81, -g[1] / 9.81, -g[2] / 9.81)} · Oberfläche $lage")
                bahn = Uebergabebahn(Kern.uebergabeBahn("""{"art":"abgang","fernseher":${app.istFernseher},"voll":${liste(*voll)},""" +
                    """"schirm":${liste(schirmB, schirmH)},"nachOben":$oben$schwerkraft}"""))
                raus = bahn.raus ?: 2.0
                zeit("fliegt nach ${if (oben) "oben" else "unten"}, draußen nach ${(raus * 1000).toInt()} ms")
            }
            laeufe++
            val a = Abgang(laeufe, System.nanoTime(), b.asImageBitmap(), voll, seiten, titel, unter, ruhig, bahn, lagen, raus)
            abgang = a
            zeit("Bühne deckt den Player ab ihrem ersten Bild")
            app.anwendungslauf.launch {
                delay(((raus - a.jetzt()) * 1000).toLong().coerceAtLeast(0))
                zeit("Karte draußen — Player schließt unter der Bühne")
                fertig()
                // Die Aktivitaet blendet beim Schliessen aus (`player_aus`); danach ist die Buehne weg.
                delay(((0.5 + zeiten.blende + 0.05) * 1000).toLong())
                if (abgang === a) abgang = null
            }
            return true
        } finally {
            schwere?.aus()
        }
    }

    /** Die Schwerkraft beim Abgang — wie das Telefon gerade wirklich gehalten wird (`CMMotionManager`). */
    private class Schwerkraft(kontext: Context) : SensorEventListener {
        private val sensoren = kontext.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
        @Volatile private var letzte: FloatArray? = null
        init {
            sensoren?.getDefaultSensor(Sensor.TYPE_GRAVITY)?.let { sensoren.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME) }
        }
        override fun onSensorChanged(e: SensorEvent) { letzte = e.values.copyOf() }
        override fun onAccuracyChanged(s: Sensor?, a: Int) {}
        /** Hoechstens 120 ms warten, wie auf Apple (6 × 20 ms). */
        suspend fun messung(): DoubleArray? {
            var n = 0
            while (letzte == null && n < 6) { delay(20); n++ }
            return letzte?.let { doubleArrayOf(it[0].toDouble(), it[1].toDouble(), it[2].toDouble()) }
        }
        fun aus() { runCatching { sensoren?.unregisterListener(this) } }
    }

    /** Die Videoflaeche von libVLC (`surface_video`) in der `VLCVideoLayout`. */
    private fun videoflaeche(v: View): SurfaceView? {
        val alle = mutableListOf<SurfaceView>()
        fun suchen(x: View) {
            if (x is SurfaceView && x.visibility == View.VISIBLE && x.width > 0) alle += x
            if (x is ViewGroup) for (i in 0 until x.childCount) suchen(x.getChildAt(i))
        }
        suchen(v)
        return alle.firstOrNull { s -> runCatching { s.resources.getResourceEntryName(s.id) }.getOrNull() == "surface_video" } ?: alle.firstOrNull()
    }

    private fun flaecheRahmen(v: View): Rect {
        val ort = IntArray(2)
        v.getLocationInWindow(ort)
        return Rect(ort[0].toFloat(), ort[1].toFloat(), (ort[0] + v.width).toFloat(), (ort[1] + v.height).toFloat())
    }

    /** **Das stehende Bild** (`VLCPlayerView.standbild`): `PixelCopy` aus der Videoflaeche, bis 0,6 s. */
    private suspend fun standbild(flaeche: View): Pair<Bitmap, Rect>? {
        val s = videoflaeche(flaeche) ?: return null
        if (s.width <= 0 || s.height <= 0 || s.holder.surface?.isValid != true) return null
        val b = Bitmap.createBitmap(s.width, s.height, Bitmap.Config.ARGB_8888)
        val ok = withTimeoutOrNull(600) {
            suspendCancellableCoroutine { k ->
                runCatching {
                    PixelCopy.request(s, b, { r -> if (k.isActive) k.resume(r == PixelCopy.SUCCESS) }, Handler(Looper.getMainLooper()))
                }.onFailure { if (k.isActive) k.resume(false) }
            }
        } ?: false
        return if (ok) b to flaecheRahmen(s) else null
    }

    /** Mittlere Helligkeit 0…1, auf 16 × 16 Punkte verkleinert (`Uebergabeabgang.helligkeit`). */
    private fun helligkeit(b: Bitmap): Double {
        val k = Bitmap.createScaledBitmap(b, 16, 16, true)
        var summe = 0.0
        for (y in 0 until 16) for (x in 0 until 16) {
            val p = k.getPixel(x, y)
            summe += 0.2126 * ((p shr 16) and 0xFF) + 0.7152 * ((p shr 8) and 0xFF) + 0.0722 * (p and 0xFF)
        }
        return summe / 256 / 255
    }
}

private fun linear(t: Double, a: Double, b: Double): Float = ((t - a) / (b - a)).coerceIn(0.0, 1.0).toFloat()

/**
 * **Die Buehne, zuoberst in jeder Aktivitaet** — Hauptansicht, Fernseher und Player. Nimmt keine Tipps an.
 * `imPlayer`: nur dort geht auch das Bild des Abgebers ab.
 */
@Composable
fun Uebergabeebene(imPlayer: Boolean) {
    Uebergabe.empfang?.let { Empfangsbuehne(it) }
    if (imPlayer) Uebergabe.abgang?.let { Abgangsbuehne(it) }
}

@Composable
private fun uhr(beginn: Long): androidx.compose.runtime.State<Double> {
    val zeit = remember(beginn) { mutableDoubleStateOf((System.nanoTime() - beginn) / 1e9) }
    LaunchedEffect(beginn) { while (true) withFrameNanos { n -> zeit.doubleValue = ((n - beginn) / 1e9).coerceAtLeast(0.0) } }
    return zeit
}

/** Die Karte, in voller Groesse gebaut und im Zeichnen verschoben und verkleinert (`transform.scale`). */
private fun Modifier.kartenlage(dichte: Float, basis: Float, lage: () -> FloatArray?): Modifier = graphicsLayer {
    val l = lage() ?: return@graphicsLayer
    val m = l[2] / basis
    transformOrigin = TransformOrigin(0.5f, 0.5f)
    translationX = l[0] * dichte - basis * dichte / 2
    translationY = l[1] * dichte - basis * dichte / 2 * 9 / 16
    scaleX = m; scaleY = m
    // Die sichtbare Ecke `Uebergabekarte.ecke`, vor dem Verkleinern gerechnet (`cornerRadius * basis / breite`).
    shape = RoundedCornerShape((l[3] / m.coerceAtLeast(0.001f)).dp)
    clip = true
}

@Composable
private fun Zeilen(titel: String, unter: String?, breite: Double, l: Uebergabelagen, linie: (@Composable () -> Unit)?,
                   modifier: Modifier) {
    val dichte = LocalDensity.current
    val titelSp = with(dichte) { l.titel.dp.toSp() }
    val kleinSp = with(dichte) { l.klein.dp.toSp() }
    Box(modifier.requiredWidth(breite.dp)) {
        Column(Modifier.fillMaxWidth().padding(top = (2 + l.abstand * 0.35).dp),
               verticalArrangement = Arrangement.spacedBy((l.abstand * 0.25).dp)) {
            Text(titel, style = TextStyle(fontSize = titelSp, fontWeight = FontWeight.SemiBold), color = Stil.schrift,
                 maxLines = 1, overflow = TextOverflow.Ellipsis)
            unter?.let { Text(it, style = TextStyle(fontSize = kleinSp), color = Stil.schriftLeise, maxLines = 1, overflow = TextOverflow.Ellipsis) }
        }
        linie?.invoke()
    }
}

@Composable
private fun Empfangsbuehne(e: Uebergabe.Empfang) {
    val z = Uebergabe.zeiten
    val zeit by uhr(e.beginn)
    val dichte = LocalDensity.current.density
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val b = maxWidth.value.toDouble(); val h = maxHeight.value.toDouble()
        LaunchedEffect(b, h) { Uebergabe.schirm(e, b, h) }
        val l = e.lagen ?: return@BoxWithConstraints
        // Die ganze Buehne: nach dem Zoom weich hinaus, bei einem Abbruch geblendet.
        Box(Modifier.fillMaxSize().graphicsLayer {
            val t = zeit
            var a = 1f
            e.zoomAb?.let { za ->
                a = if (e.ruhig) 1f - linear(t, za, za + z.blendeAus) else (e.zoom?.deckung(t - za) ?: 1f)
            }
            e.abbruchSeit?.let { s -> a *= 1f - linear(t, s, s + z.blende) }
            alpha = a
        }) {
            // Der Grund ueber der Seite — die Seite tritt zurueck.
            Box(Modifier.fillMaxSize().graphicsLayer {
                alpha = if (e.ruhig) linear(zeit, 0.0, z.blende) else (e.deckung?.deckung(zeit, 1) ?: 0f)
            }.background(Stil.grund))
            // Schwarz wie der Grund des Players, ab dem Zoom.
            if (!e.ruhig) Box(Modifier.fillMaxSize().graphicsLayer {
                alpha = e.zoomAb?.let { za -> linear(zeit, za, za + z.schwarzDauer) } ?: 0f
            }.background(Color.Black))
            val basis = l.voll[2].toFloat()
            fun lage(t: Double): FloatArray? {
                if (e.ruhig) return e.warten?.lage(0.0)
                val za = e.zoomAb
                return if (za != null && t >= za) e.zoom?.lage(t - za) ?: e.warten?.lage(t) else e.warten?.lage(t)
            }
            Box(Modifier.requiredSize(basis.dp, (basis * 9 / 16).dp).align(Alignment.TopStart)
                    .kartenlage(dichte, basis) { lage(zeit) }
                    .graphicsLayer {
                        alpha = if (e.ruhig) linear(zeit, z.kartenStart, z.kartenStart + z.blende)
                                else (e.deckung?.deckung(zeit, 0) ?: 0f)
                    }
                    .background(Stil.flaeche)) {
                if (e.bild != null) AsyncImage(e.bild, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
            }
            // Titel und Folge darunter; oben die Ladelinie, wenn das Bild auf sich warten laesst.
            Zeilen(e.titel, e.unter, l.ruhe[2], l, linie = {
                val seit = e.ladelinieSeit
                if (seit != null) Box(Modifier.fillMaxWidth().height(2.dp).graphicsLayer {
                    alpha = linear(zeit, seit, seit + z.ladelinieEinblenden)
                }.clip(RoundedCornerShape(1.dp)).background(Stil.rand)) {
                    val breite = l.ruhe[2].toFloat()
                    Box(Modifier.requiredWidth((breite * 0.3f).dp).height(2.dp).align(Alignment.TopStart).graphicsLayer {
                        val w = breite * 0.3f
                        val u = (((zeit - seit) / z.ladelinieTakt) % 1.0).toFloat()
                        translationX = ((-w / 2) + (breite + w) * u - w / 2) * dichte
                    }.clip(RoundedCornerShape(1.dp)).background(Stil.akzent))
                }
            }, modifier = Modifier.align(Alignment.TopStart).graphicsLayer {
                val t = zeit
                val k = lage(t) ?: return@graphicsLayer
                translationX = (k[0] - l.ruhe[2].toFloat() / 2) * dichte
                translationY = k[4] * dichte
                alpha = if (e.ruhig) linear(t, z.kartenStart, z.kartenStart + z.blende)
                        else (e.deckung?.deckung(t, 2) ?: 0f) * (e.zoomAb?.let { za -> 1f - linear(t, za, za + z.zeilenAus) } ?: 1f)
            })
        }
    }
}

@Composable
private fun Abgangsbuehne(a: Uebergabe.Abgang) {
    val z = Uebergabe.zeiten
    val zeit by uhr(a.beginn)
    val dichte = LocalDensity.current.density
    val l = a.lagen
    Box(Modifier.fillMaxSize()) {
        // Deckend ueber dem Player, bis er geschlossen ist.
        Box(Modifier.fillMaxSize().background(Stil.grund))
        // Spiegel des Empfaengers: Schwarz geht, wenn die Karte schrumpft.
        Box(Modifier.fillMaxSize().graphicsLayer {
            alpha = if (a.ruhig) 1f - linear(zeit, 0.0, z.blendeAus) else 1f - linear(zeit, z.abgangStart, z.abgangStart + z.schwarzDauer)
        }.background(Color.Black))
        val vb = a.voll[2].toFloat()
        Box(Modifier.requiredSize(vb.dp, (vb / a.seiten).dp).align(Alignment.TopStart).graphicsLayer {
            val lage = if (a.ruhig) floatArrayOf(a.voll[0].toFloat(), a.voll[1].toFloat(), vb, 0f, 0f) else a.bahn?.lage(zeit)
            if (lage != null) {
                val m = lage[2] / vb
                transformOrigin = TransformOrigin(0.5f, 0.5f)
                translationX = lage[0] * dichte - vb * dichte / 2
                translationY = lage[1] * dichte - (vb / a.seiten.toFloat()) * dichte / 2
                scaleX = m; scaleY = m
                shape = RoundedCornerShape((lage[3] / m.coerceAtLeast(0.001f)).dp)
                clip = true
            }
            if (a.ruhig) alpha = 1f - linear(zeit, 0.0, z.blendeAus)
        }) {
            Image(a.bild, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        }
        if (!a.ruhig) a.bahn?.lage?.let { karte ->
            Zeilen(a.titel, a.unter, karte[2].toDouble(), l, linie = null, modifier = Modifier.align(Alignment.TopStart).graphicsLayer {
                val k = a.bahn.lage(zeit)
                translationX = (k[0] - karte[2] / 2) * dichte
                translationY = k[4] * dichte
                alpha = a.bahn.deckung(zeit, 0)
            })
        }
    }
}
