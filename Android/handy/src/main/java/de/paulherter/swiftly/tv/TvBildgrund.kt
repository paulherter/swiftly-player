package de.paulherter.swiftly.tv

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Shader
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ShaderBrush
import androidx.compose.ui.platform.LocalContext
import coil3.SingletonImageLoader
import coil3.request.ImageRequest
import coil3.request.SuccessResult
import coil3.request.allowHardware
import coil3.toBitmap
import de.paulherter.swiftly.gemeinsam.Stil
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.withContext
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Vorlage: `Sources/tvOS/Bildton.swift` (`Bildton`, `Bildgrund`) — der Seitengrund faerbt sich nach
 * dem Farbton der Kulisse, nicht nach ihrer Farbe: Saettigung und Helligkeit setzt die App selbst,
 * nur der Ton kommt aus dem Bild. Fuer die Begruendung (Rundmittel, Gewicht mit Saettigung im
 * Quadrat, mehrere Gipfel statt eines Mittelwerts) siehe die Vorlage — die Rechnung hier ist eine
 * wortgetreue Uebertragung von `Bildton.toeneAus(_:)`.
 *
 * **Zwei bewusste Abweichungen von der Vorlage:**
 * - **Kein `MeshGradient`.** Compose kennt kein Flaechennetz. Nachgebaut mit einem linearen
 *   Verlauf mit vielen Stuetzstellen entlang der Diagonale (Kulisse oben rechts → Grund unten
 *   links, das traegt die Haupt-Helligkeits- und Tonbewegung aus `farbe(bei:)`) plus drei weichen
 *   Flecken in den uebrigen Ecken und der Mitte, damit die Flaeche nicht nur auf einer Geraden
 *   Farbe zeigt.
 * - **Immer eine 400-ms-Ueberblendung, kein stilles Uebernehmen bei bekanntem Ton.** Die Vorlage
 *   unterscheidet "schon gemerkt" (kein Uebergang) von "neu berechnet" (Uebergang); hier blendet
 *   jeder Wechsel gleich, was fuer Fokuswechsel auf derselben Seite unauffaellig ist, weil
 *   benachbarte Kacheln meist aehnliche Toene liefern.
 */
object Bildton {
    /** Prozessweit, wie `Bildton.geteilt.bekannt` — eine neue Seite hat den Ton im ersten Bild. */
    private val bekannt = mutableMapOf<String, List<Double>>()
    private val laufend = mutableMapOf<String, Deferred<List<Double>>>()
    private val sperre = Any()

    /** Lebt so lange wie der Prozess, nicht wie eine Seite — sonst wuerde eine geschlossene Seite
     *  eine noch laufende Berechnung abwuergen, die eine andere Seite gleich braucht. */
    private val bereich = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    /** Ohne Warten — damit eine neue Seite im ersten Bild schon den Ton zeigen kann. */
    fun gemerkt(bild: String): List<Double>? = synchronized(sperre) { bekannt[bild] }

    /** Bis zu fuenf Farbtoene in Grad, nach Gewicht — leer, wenn sich keiner ableiten laesst.
     *  `kontext` sollte der Anwendungskontext sein, damit der Merkspeicher keine Activity haelt. */
    suspend fun toene(kontext: Context, bild: String): List<Double> {
        gemerkt(bild)?.let { return it }
        val anwendung = kontext.applicationContext
        val aufgabe = synchronized(sperre) {
            bekannt[bild]?.let { return it }
            laufend.getOrPut(bild) { bereich.async { berechnen(anwendung, bild) } }
        }
        val ergebnis = aufgabe.await()
        synchronized(sperre) { bekannt[bild] = ergebnis; laufend.remove(bild) }
        return ergebnis
    }

    private suspend fun berechnen(kontext: Context, bild: String): List<Double> {
        val bitmap = runCatching {
            (SingletonImageLoader.get(kontext).execute(
                ImageRequest.Builder(kontext).data(bild).size(48).allowHardware(false).build()
            ) as? SuccessResult)?.image?.toBitmap()
        }.getOrNull() ?: return emptyList()
        // Die Histogramm-Rechnung ist der teure Teil (bis zu 48 x 48 Punkte) — nicht auf dem
        // Hauptthread, auch wenn `execute` selbst schon abseits davon laeuft.
        return withContext(Dispatchers.Default) { toeneAus(bitmap) }
    }

    /** Wortgetreue Uebertragung von `Bildton.toeneAus(_:)` — 36 Faecher zu je zehn Grad, gewichtet
     *  mit dem Quadrat der Saettigung mal der Helligkeit, dann bis zu fuenf Gipfel mit
     *  Mindestabstand. Siehe die Vorlage fuer die Begruendung jeder Zahl hier. */
    fun toeneAus(bitmap: Bitmap): List<Double> {
        val breite = bitmap.width
        val hoehe = bitmap.height
        if (breite <= 0 || hoehe <= 0) return emptyList()

        val punkte = IntArray(breite * hoehe)
        bitmap.getPixels(punkte, 0, breite, 0, 0, breite, hoehe)

        val faecher = 36
        val korb = DoubleArray(faecher)
        var gesamt = 0.0

        for (p in punkte) {
            val r = ((p shr 16) and 0xFF) / 255.0
            val g = ((p shr 8) and 0xFF) / 255.0
            val b = (p and 0xFF) / 255.0

            val hoch = maxOf(r, g, b)
            val tief = minOf(r, g, b)
            val spanne = hoch - tief
            if (spanne <= 0.04 || hoch <= 0.08) continue

            val saettigung = spanne / hoch
            var ton = when (hoch) {
                r -> (g - b) / spanne
                g -> 2 + (b - r) / spanne
                else -> 4 + (r - g) / spanne
            }
            ton *= 60
            if (ton < 0) ton += 360

            val gewicht = saettigung * saettigung * hoch
            val fach = minOf(faecher - 1, (ton / 10).toInt())
            korb[fach] += gewicht
            gesamt += gewicht
        }

        if (gesamt <= 0.5) return emptyList()

        val gewaehlt = mutableListOf<Double>()
        val uebrig = korb.copyOf()
        for (schritt in 0 until 5) {
            var fach = -1
            var wert = -1.0
            for (i in uebrig.indices) if (uebrig[i] > wert) { wert = uebrig[i]; fach = i }
            if (fach < 0 || wert <= gesamt * 0.035) break

            var x = 0.0
            var y = 0.0
            for (versatz in -1..1) {
                val f = ((fach + versatz) % faecher + faecher) % faecher
                val bogen = (f * 10 + 5) * Math.PI / 180
                x += cos(bogen) * korb[f]
                y += sin(bogen) * korb[f]
            }
            var grad = atan2(y, x) * 180 / Math.PI
            if (grad < 0) grad += 360
            gewaehlt.add(grad)

            for (versatz in -1..1) uebrig[((fach + versatz) % faecher + faecher) % faecher] = 0.0
        }
        return gewaehlt
    }
}

/**
 * Feines Rauschen gegen Streifenbildung, wie `Bildton.rauschen` — 96 x 96 gekachelt, Deckkraft
 * 0,008. Einmal erzeugt (billig, anders als die Tonrechnung: fester Zufallslauf, kein Netzabruf)
 * und als kachelnder `ShaderBrush` gemerkt.
 */
private object Rauschen {
    val brush: Brush by lazy { erzeugen() }

    private fun erzeugen(): Brush {
        val kante = 96
        val bitmap = Bitmap.createBitmap(kante, kante, Bitmap.Config.ARGB_8888)
        val pixel = IntArray(kante * kante)
        var zustand = 0x2545F4914F6CDD1DL
        for (i in pixel.indices) {
            zustand = zustand xor (zustand shl 13)
            zustand = zustand xor (zustand ushr 7)
            zustand = zustand xor (zustand shl 17)
            val hell = (zustand and 1L) == 1L
            val deckung = ((zustand ushr 8) and 0xFF).toInt()
            val kanal = if (hell) 255 else 0
            pixel[i] = (deckung shl 24) or (kanal shl 16) or (kanal shl 8) or kanal
        }
        bitmap.setPixels(pixel, 0, kante, 0, 0, kante, kante)
        return ShaderBrush(BitmapShader(bitmap, Shader.TileMode.REPEAT, Shader.TileMode.REPEAT))
    }
}

/** Der Farbton an der Stelle `lauf` (0…1) — wortgetreu `Bildgrund.tonBei(_:)`. */
private fun tonBei(toene: List<Double>, lauf: Double): Double {
    val leit = toene[0]
    fun gedaempft(ton: Double): Double {
        var weg = ton - leit
        if (weg > 180) weg -= 360
        if (weg < -180) weg += 360
        return leit + weg * 0.34
    }
    if (toene.size <= 1) return leit

    val stelle = lauf * (toene.size - 1)
    val a = minOf(stelle.toInt(), toene.size - 2)
    val t = stelle - a

    val von = gedaempft(toene[a])
    val bis = gedaempft(toene[a + 1])
    var weg = bis - von
    if (weg > 180) weg -= 360
    if (weg < -180) weg += 360
    var ton = von + weg * (t * t * (3 - 2 * t))
    if (ton < 0) ton += 360
    if (ton >= 360) ton -= 360
    return ton
}

/** Die Farbe an einem Netzpunkt (0…1 in beiden Achsen) — wortgetreu `Bildgrund.farbe(bei:)`. */
private fun farbeBei(toene: List<Double>, x: Double, y: Double): Color {
    if (toene.isEmpty()) return Stil.grund

    val dx = 1 - x
    val dy = y
    val naehe = 1 - minOf(1.0, sqrt(dx * dx + dy * dy) / 1.414)

    val lauf = (x + y) / 2
    val ton = tonBei(toene, lauf)

    return Color.hsv(
        hue = ton.toFloat(),
        saturation = (0.38 + 0.20 * naehe).toFloat(),
        value = (0.075 + 0.140 * naehe.pow(1.6)).toFloat()
    )
}

/**
 * Der Grund selbst — Naeherung an `Bildgrund.netz`, siehe Klassenkommentar zu `Bildton` fuer die
 * Abweichung. Zeichnet ausserhalb von `toene.isEmpty()` den reinen `Stil.grund`.
 */
@Composable
private fun Netz(toene: List<Double>, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        if (toene.isEmpty()) {
            drawRect(color = Stil.grund)
            return@Canvas
        }

        val b = size.width
        val h = size.height

        // Grundverlauf entlang der Diagonale von der Kulisse (oben rechts, x=1,y=0) zum Grund
        // (unten links, x=0,y=1) — zehn Stuetzstellen, damit der Ton unterwegs wandert wie in
        // `tonBei`, statt an zwei Enden zu haengen.
        val stuetzen = 10
        val stops = Array(stuetzen + 1) { i ->
            val t = i.toFloat() / stuetzen
            t to farbeBei(toene, 1.0 - t, t.toDouble())
        }
        drawRect(brush = Brush.linearGradient(*stops, start = Offset(b, 0f), end = Offset(0f, h)))

        // Drei weiche Flecken abseits der Diagonale (die uebrigen Ecken und die Mitte) — das
        // Netz deckte die ganze Flaeche ab, nicht nur eine Gerade.
        listOf(0.0 to 0.0, 1.0 to 1.0, 0.5 to 0.5).forEach { (x, y) ->
            val mitte = Offset((x * b).toFloat(), (y * h).toFloat())
            val radius = maxOf(b, h) * 0.62f
            drawCircle(
                brush = Brush.radialGradient(
                    listOf(farbeBei(toene, x, y).copy(alpha = 0.5f), Color.Transparent),
                    center = mitte, radius = radius
                ),
                radius = radius, center = mitte
            )
        }
    }
}

/**
 * Vorlage: `Bildgrund` in `Sources/tvOS/Bildton.swift` — faerbt den Grund einer ganzen Seite nach
 * ihrer Kulisse. Ganz hinten in der Seite einsetzen (siehe `TvHaupt.kt`: `Stil.grund` liegt schon
 * hinter der ganzen App, `TvBildgrund` gehoert darueber, unter allem Inhalt der Seite).
 *
 * `bild` ist dieselbe Adresse, die `Kulisse(bild, …)` zeichnet — HomeView auf tvOS faerbt sich
 * ebenfalls nach `kulissenURL`, demselben Bild, das die Kopfzone zeigt.
 */
@Composable
fun TvBildgrund(bild: String?, modifier: Modifier = Modifier) {
    val kontext = LocalContext.current

    // Anfangswert aus dem Gedaechtnis, nicht aus dem Nichts — damit diese Seite im ersten Bild
    // schon den Ton zeigt, wenn ein anderer Aufruf (etwa die Startseite) ihn bereits kennt.
    var toene by remember { mutableStateOf(bild?.let { Bildton.gemerkt(it) } ?: emptyList()) }

    LaunchedEffect(bild) {
        if (bild == null) { toene = emptyList(); return@LaunchedEffect }
        toene = Bildton.toene(kontext, bild)
    }

    Crossfade(
        targetState = toene,
        animationSpec = tween(400, easing = CubicBezierEasing(0.42f, 0f, 0.58f, 1f)),
        label = "bildgrund",
        modifier = modifier.fillMaxSize()
    ) { stand ->
        Box(Modifier.fillMaxSize()) {
            Netz(stand, Modifier.fillMaxSize())
            // Der letzte Rest gegen Baender — siehe `Rauschen`/`Bildton.rauschen`.
            if (stand.isNotEmpty()) {
                Canvas(Modifier.fillMaxSize()) { drawRect(brush = Rauschen.brush, alpha = 0.008f) }
            }
        }
    }
}
