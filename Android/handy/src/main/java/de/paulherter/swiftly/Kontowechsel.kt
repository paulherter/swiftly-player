package de.paulherter.swiftly

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.layer.GraphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import de.paulherter.swiftly.gemeinsam.Bewegung
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.kern.Kern
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import android.view.Choreographer
import kotlin.coroutines.resume
import kotlinx.coroutines.launch
import org.json.JSONObject

/**
 * **Der Kontowechsel als Bewegung** — Entwurf D (Paul, 26.09.2026), Vorlage `Kontowechselflug` in
 * `Sources/iOS/Uebergaenge.swift`.
 *
 * 1. **Tipp:** ein Standbild des Schirms liegt ueber allem und faehrt als Seite nach rechts weg (Feder 0,42,
 *    ohne Nachschwingen, 80 ms nach dem Tipp); daneben fliegt das Profilbild im Bogen nach oben rechts.
 * 2. **Gleich danach**, noch bevor sich etwas bewegt, springt der Stapel ohne Animation zurueck — unter dem
 *    Standbild, unsichtbar. Die Reihen des alten Kontos sind sofort weg.
 * 3. **Wechsel:** 0,3 s vor der Ruhe des Bildes (`Kontowechselkurve.wechsel`) — der Neuaufbau kostet den
 *    Hauptlauf Zeit, und dann bewegt sich das Bild nur noch um Bruchteile eines Punkts.
 * 4. **Tausch:** wenn das Bild ruht, steht dort das echte; der Ring ploppt bei der Landung.
 * 5. **Reihen:** 30 ms danach gestaffelt (`reihenauftritt`).
 *
 * **Die Bahn rechnet das Paket** (`Kontowechselkurve`, ueber `Kern.kontowechselKurve`) als Stuetzpunkte, 120
 * je Sekunde; hier wird sie nur je Bild abgelesen, ohne Neuaufbau — Lage und Groesse sitzen im
 * `graphicsLayer`, gelesen wird im Zeichnen. Bewegung reduzieren: nur Ueberblenden, kein Flug.
 */
object Kontowechselflug {
    /** Das neue Konto fliegt; `ersetzt`: das echte Bild im Kopf steht schon (Schritt 4). */
    data class Flug(val konto: String, val ersetzt: Boolean = false)

    class Kurve(json: String) {
        private val o = JSONObject(json)
        val tausch = o.getDouble("tausch")
        val landung = o.getDouble("landung")
        val ringEnde = o.getDouble("ringEnde")
        val wechsel = o.getDouble("wechsel")
        val zielgroesse = o.getDouble("zielgroesse").toFloat()
        val bahn: FloatArray = o.getJSONArray("bahn").let { a -> FloatArray(a.length()) { a.getDouble(it).toFloat() } }
        val ring: FloatArray = o.getJSONArray("ring").let { a -> FloatArray(a.length()) { a.getDouble(it).toFloat() } }

        /** x, y, Groesse (dp) zur Zeit `t` — zwischen den Stuetzpunkten geradlinig, wie `calculationMode = .linear`. */
        fun lage(t: Double): Triple<Float, Float, Float> {
            val n = bahn.size / 3 - 1
            if (n <= 0 || t >= tausch) return Triple(bahn[bahn.size - 3], bahn[bahn.size - 2], bahn[bahn.size - 1])
            val stelle = (t.coerceAtLeast(0.0) / tausch * n)
            val i = stelle.toInt().coerceIn(0, n - 1)
            val f = (stelle - i).toFloat()
            fun w(k: Int) = bahn[i * 3 + k] + (bahn[(i + 1) * 3 + k] - bahn[i * 3 + k]) * f
            return Triple(w(0), w(1), w(2))
        }

        /** Mass und Deckung des Rings `r` Sekunden nach der Landung. */
        fun ring(r: Double): Pair<Float, Float> {
            if (r < 0 || r > 0.8) return 1f to 0f
            val i = (r / 0.8 * 96).toInt().coerceIn(0, 96)
            return ring[i * 2] to ring[i * 2 + 1]
        }
    }

    /** Was auf der Buehne steht. Alle Rahmen in Wurzelkoordinaten (px). */
    class Buehne(val standbild: ImageBitmap?, val deckel: Rect?, val flaeche: Color, val kurve: Kurve?,
                 val name: String, val bild: String?, val start: Long, val ruhig: Boolean, val nummer: Int)

    var buehne by mutableStateOf<Buehne?>(null); private set
    var flug by mutableStateOf<Flug?>(null); private set
    /** Zwischen Tipp und Freigabe — solange haelt die Startseite ihre Reihen zurueck. */
    var wartet by mutableStateOf(false); private set
    /** Steigt beim Tipp: die Hauptansicht baut sich unter dem Standbild neu (Stapel leer). */
    var zurueck by mutableIntStateOf(0); private set
    /** Steigt, wenn die Reihen kommen duerfen — dann gestaffelt (`reihenauftritt`). */
    var freigabe by mutableIntStateOf(0); private set
    var freigabeUm = 0L; private set
    /** Wo das Profilbild oben steht, in Wurzelkoordinaten — gemeldet vom Kopf. */
    var ziel: Rect = Rect.Zero; private set
    /** Das Ziel, auf das die Bahn beim Tipp gerechnet wurde — der Kopf federt dann noch und steht spaeter anders. */
    var zielBeiTipp: Rect = Rect.Zero; private set
    /** Der Schirm als aufgezeichnete Ebene (`MainActivity`) — daraus das Standbild. */
    var schirm: GraphicsLayer? = null

    private var wechseln: (() -> Unit)? = null
    /** Das Konto ist schon gewechselt — vorher laedt die Startseite nicht (sie holte sonst das alte Konto). */
    val gewechselt: Boolean get() = wechseln == null
    private var laeufe = 0

    /** **Nur, wenn es wirklich oben rechts steht** — mitten im Schieben einer Seite steht es weiter links (gemessen: 846 statt 949 px). */
    fun zielMelden(rahmen: Rect, breite: Float) {
        // Ruhig steht der Rand 16 dp vom Schirmrand; 30 dp lassen die Feder-Ruhe zu, aber kein Schieben.
        if (rahmen.width > 0 && rahmen.right > breite - 30 * (rahmen.width / 34f)) ziel = rahmen
    }

    private fun notiz(text: String) = Protokoll.schreib("[Kontowechsel] $text")

    /**
     * Tipp auf ein Konto: `von` ist der Rahmen seines Profilbilds, `flaeche` die Farbe unter ihm in der Karte
     * (sie deckt die Stelle auf dem Standbild, das Bild fliegt ja schon).
     */
    fun starten(app: SwiftlyAnwendung, kennung: String, name: String, bild: String?, von: Rect, flaeche: Color,
                dichte: Float, ruhig: Boolean) {
        if (wartet) { notiz("zweiter Tipp ignoriert"); return }
        laeufe++
        val meiner = laeufe
        wartet = true
        wechseln = { app.kontoWechseln(kennung) }
        app.anwendungslauf.launch {
            val beginn = System.nanoTime()
            val standbild = runCatching { schirm?.toImageBitmap() }.getOrNull()
            zielBeiTipp = ziel
            val kurve = if (!ruhig && von.width > 0 && ziel.width > 0) runCatching {
                Kurve(Kern.kontowechselKurve((von.center.x / dichte).toDouble(), (von.center.y / dichte).toDouble(),
                    (von.width / dichte).toDouble(), (ziel.center.x / dichte).toDouble(), (ziel.center.y / dichte).toDouble(),
                    (ziel.width / dichte).toDouble()))
            }.getOrNull() else null
            buehne = Buehne(standbild, von.takeIf { kurve != null }?.inflate(3 * dichte), flaeche, kurve, name, bild,
                            beginn, ruhig, meiner)
            if (kurve != null) flug = Flug(kennung)
            notiz("1: Tipp, Flug ${if (kurve == null) "aus" else "an"}, Standbild in ${(System.nanoTime() - beginn) / 1_000_000} ms")
            // Ein Bild spaeter: unter dem Standbild springt der Stapel zurueck, bevor sich etwas bewegt.
            // **Nicht `withFrameNanos`.** Der Anwendungslauf ist kein
            // Compose-Lauf und hat keine `MonotonicFrameClock` — die App stürzte
            // beim Kontowechsel sofort ab. Der Choreographer liefert dasselbe
            // „ein Bild später“ ohne Compose.
            naechstesBild()
            zurueck++
            notiz("1b: Stapel leer (unter dem Standbild)")
            fun gilt() = laeufe == meiner
            suspend fun bis(t: Double) { delay(((t - (System.nanoTime() - beginn) / 1e9) * 1000).toLong().coerceAtLeast(0)) }
            bis(kurve?.wechsel ?: (if (ruhig) 0.15 else 0.45))
            if (!gilt()) return@launch
            wechselAusfuehren()
            if (kurve != null) {
                bis(kurve.tausch)
                if (!gilt()) return@launch
                val e = kurve.lage(kurve.tausch); val d = dichte
                notiz("MESSEN Tausch: Bild Mitte ${e.first * d}/${e.second * d} Groesse ${e.third * d} px, echtes Ziel ${ziel} (${ziel.width}x${ziel.height}), beim Tipp ${zielBeiTipp}")
                notiz("4: Bild ruht, Tausch gegen das echte (${(kurve.tausch * 1000).toInt()} ms nach Tipp)")
                flug = flug?.copy(ersetzt = true)
            }
            delay(30)
            if (!gilt()) return@launch
            notiz("5: Reihen duerfen kommen")
            freigeben()
            bis((kurve?.ringEnde ?: 0.3) + 0.1)
            if (gilt()) beenden()
        }
    }

    private fun wechselAusfuehren() {
        val w = wechseln ?: return
        wechseln = null
        val a = System.nanoTime()
        w()
        notiz("2: Konto gewechselt in ${(System.nanoTime() - a) / 1_000_000} ms")
    }

    private fun freigeben() {
        wartet = false
        freigabeUm = android.os.SystemClock.elapsedRealtime()
        freigabe++
    }

    private fun beenden() {
        buehne = null
        flug = null
        if (wartet) freigeben()
    }

    /**
     * **Die Profilseite geht auf, waehrend der Wechsel noch laeuft** (Paul, 26.09.: das Profil oben ist sofort
     * wieder antippbar): alles Ausstehende ist sofort erledigt — das Konto wechselt jetzt, Standbild und Bild
     * gehen, und die Startseite darf ihre Reihen bauen.
     */
    fun abschliessen() {
        if (buehne == null && !wartet) return
        notiz("Profil geoeffnet, Rest sofort")
        laeufe++
        wechselAusfuehren()
        flug = flug?.copy(ersetzt = true)
        beenden()
    }
}

/**
 * **Die Buehne** ueber allem: das Standbild faehrt weg, das Profilbild fliegt, der Ring ploppt. Liegt in der
 * `MainActivity` ueber der Hauptansicht, die sich darunter neu baut. Nimmt keine Tipps an — das Profil oben
 * ist sofort wieder antippbar.
 */
@Composable
fun Kontowechselebene() {
    val b = Kontowechselflug.buehne ?: return
    val dichte = LocalDensity.current.density
    var zeit by remember(b.nummer) { mutableFloatStateOf(0f) }
    LaunchedEffect(b.nummer) {
        while (true) withFrameNanos { n -> zeit = ((n - b.start) / 1e9).toFloat().coerceAtLeast(0f) }
    }
    val weg = remember(b.nummer) { Animatable(0f) }
    LaunchedEffect(b.nummer) {
        if (b.ruhig) { weg.animateTo(1f, tween(200, easing = LinearEasing)); return@LaunchedEffect }
        // Wie ein gewoehnliches Zurueck: Feder 0,42, keine Ueberschwinger, 80 ms nach dem Tipp —
        // (2π / 0,42)² ≈ 224.
        delay(80)
        weg.animateTo(1f, spring(dampingRatio = 1f, stiffness = 224f))
    }
    Box(Modifier.fillMaxSize()) {
        // 1. Das Standbild — auf ihm deckt die Kartenfarbe das angetippte Bild, das ja schon fliegt.
        b.standbild?.let { s ->
            Box(Modifier.fillMaxSize().graphicsLayer {
                if (b.ruhig) alpha = 1f - weg.value else translationX = weg.value * size.width
            }) {
                Image(s, contentDescription = null, contentScale = ContentScale.FillBounds, modifier = Modifier.fillMaxSize())
                b.deckel?.let { d -> Canvas(Modifier.fillMaxSize()) { drawCircle(b.flaeche, d.width / 2, d.center) } }
            }
        }
        val k = b.kurve ?: return@Box
        val flug = Kontowechselflug.flug
        // 2. Das fliegende Bild: einmal gebaut, dann nur verschoben und skaliert (im Zeichnen gelesen).
        if (flug != null && !flug.ersetzt) {
            val basis = (k.lage(0.0).third * 1.06f)
            Box(Modifier.size(basis.dp).graphicsLayer {
                val (x, y, s) = k.lage(zeit.toDouble())
                transformOrigin = TransformOrigin(0.5f, 0.5f)
                translationX = x * dichte - basis * dichte / 2
                translationY = y * dichte - basis * dichte / 2
                // Der Kopf federt beim Tipp noch: das Ziel steht bei der Landung anders als beim Tipp.
                // Der Unterschied wird bis zum Tausch eingerechnet, damit das Bild genau dort landet,
                // wo das echte steht.
                val p = (zeit / k.tausch.toFloat()).coerceIn(0f, 1f)
                val z = Kontowechselflug.ziel; val z0 = Kontowechselflug.zielBeiTipp
                val korr = z.width > 0 && z0.width > 0
                val dx = if (korr) (z.center.x - z0.center.x) * p else 0f
                val dy = if (korr) (z.center.y - z0.center.y) * p else 0f
                val f = if (korr) 1f + (z.width / z0.width - 1f) * p else 1f
                translationX += dx; translationY += dy
                scaleX = s / basis * f; scaleY = s / basis * f
            }) { Profilzeichen(b.name, b.bild, basis.dp) }
        }
        // 3. Der Ring, nur angedeutet: ab der Landung, hoechstens 55 %.
        val ziel = k.lage(k.tausch)
        Canvas(Modifier.size(52.dp).graphicsLayer {
            val (m, d) = k.ring(zeit - k.landung)
            translationX = ziel.first * dichte - 26 * dichte
            translationY = ziel.second * dichte - 26 * dichte
            scaleX = m; scaleY = m; alpha = d
        }) { drawCircle(Stil.akzent, radius = size.minDimension / 2 - 1.dp.toPx(), style = Stroke(2.dp.toPx())) }
    }
}

/**
 * **Die Reihen der Startseite kommen gestaffelt**, wenn ein Kontowechsel sie freigibt (`Reihenauftritt`):
 * je Reihe 80 ms spaeter, Feder 0,55/0,82 aus 14 dp tiefer und 96 %, Deckung linear 0,22 s. Reihen, die
 * nicht aus einem Wechsel kommen, stehen einfach da.
 */
fun Modifier.reihenauftritt(index: Int): Modifier = composed {
    val runde = Kontowechselflug.freigabe
    val frisch = runde > 0 && android.os.SystemClock.elapsedRealtime() - Kontowechselflug.freigabeUm < 1500
    val ruhig = de.paulherter.swiftly.gemeinsam.bewegungReduziert()
    val lage = remember(runde) { Animatable(if (frisch) 0f else 1f) }
    val deckung = remember(runde) { Animatable(if (frisch) 0f else 1f) }
    LaunchedEffect(runde) {
        if (lage.value >= 1f) return@LaunchedEffect
        if (ruhig) { deckung.animateTo(1f, Bewegung.blendeReduziert()); lage.snapTo(1f); return@LaunchedEffect }
        delay(80L * index)
        launch { deckung.animateTo(1f, tween(220, easing = LinearEasing)) }
        // response 0,55, Daempfung 0,82 — (2π / 0,55)² ≈ 130.
        lage.animateTo(1f, spring(dampingRatio = 0.82f, stiffness = 130f))
    }
    graphicsLayer {
        val l = lage.value
        transformOrigin = TransformOrigin(0.5f, 0f)
        val m = 0.96f + 0.04f * l
        scaleX = m; scaleY = m
        translationY = (1f - l) * 14.dp.toPx()
        alpha = deckung.value
    }
}

/** Wartet auf das nächste Bild des Hauptfadens, ohne Compose-Uhr. */
private suspend fun naechstesBild() = suspendCancellableCoroutine<Unit> { weiter ->
    Choreographer.getInstance().postFrameCallback { if (weiter.isActive) weiter.resume(Unit) }
}
