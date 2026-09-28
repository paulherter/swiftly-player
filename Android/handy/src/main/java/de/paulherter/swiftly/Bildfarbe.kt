package de.paulherter.swiftly

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Shader
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.AnimationVector1D
import androidx.compose.animation.core.tween
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.ShaderBrush
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import coil3.SingletonImageLoader
import coil3.request.ImageRequest
import coil3.request.SuccessResult
import coil3.request.allowHardware
import coil3.toBitmap
import de.paulherter.swiftly.gemeinsam.Bewegung
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.kern.Kern
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.withContext

/**
 * **Die Farbe aus dem Bild** — Vorlage `Sources/Shared/Bildton.swift` und `Sources/iOS/Bildstimmung.swift`.
 *
 * Gerechnet wird im Kern (`Bildtonrechnung` im Paket): die Toene eines Bildes und die Farbe an jeder
 * Stelle, samt dem Auslauf in OKLab. Bis 27.09.2026 stand hier (in `TvBildgrund.kt`) eine Kotlin-Abschrift
 * der Toenerechnung, und der Grund war ein Verlauf mit drei Flecken — der Auslauf fehlte ganz. Hier bleibt,
 * was nur Android kann: das Bild entschluesseln, die Punkte als kleines Bild halten und es weich auf die
 * Flaeche ziehen.
 *
 * **Kein Netz wie `MeshGradient`, sondern ein kleines Bild, bilinear aufgezogen.** `Bildtonrechnung.punkte`
 * tastet dieselbe stetige Farbe dicht ab (auf dem Telefon alle ~17 dp); die GPU mischt dazwischen. Das
 * Rauschen gegen Baender liegt darueber wie auf Apple.
 */
object Bildton {
    /** Prozessweit, wie `Bildton.geteilt.bekannt` — eine neue Seite hat den Ton im ersten Bild. Begrenzt. */
    private val bekannt = object : LinkedHashMap<String, List<Double>>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, List<Double>>?) = size > GRENZE
    }
    private const val GRENZE = 400
    private val laufend = mutableMapOf<String, Deferred<List<Double>>>()
    private val sperre = Any()
    /** Lebt so lange wie der Prozess — eine geschlossene Seite wuergt keine Berechnung ab, die eine andere braucht. */
    private val bereich = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    /** Ohne Warten — damit eine neue Seite im ersten Bild schon den Ton zeigen kann. */
    fun gemerkt(bild: String): List<Double>? = synchronized(sperre) { bekannt[bild] }

    /** Bis zu fuenf Farbtoene in Grad, nach Gewicht — leer, wenn sich keiner ableiten laesst. */
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
                // Eigener Speicherschluessel: sonst ersetzte dieses 48-px-Bild die grosse Kulisse derselben
                // Adresse im Speicher, und die naechste Kulisse musste neu laden.
                ImageRequest.Builder(kontext).data(bild).size(48).allowHardware(false).memoryCacheKey("$bild#bildton").build()
            ) as? SuccessResult)?.image?.toBitmap()
        }.getOrNull() ?: return emptyList()
        return withContext(Dispatchers.Default) {
            val breite = bitmap.width
            val hoehe = bitmap.height
            if (breite <= 0 || hoehe <= 0) return@withContext emptyList()
            val punkte = IntArray(breite * hoehe)
            bitmap.getPixels(punkte, 0, breite, 0, 0, breite, hoehe)
            val rgba = ByteArray(punkte.size * 4)
            for (i in punkte.indices) {
                val p = punkte[i]
                rgba[i * 4] = (p shr 16).toByte(); rgba[i * 4 + 1] = (p shr 8).toByte()
                rgba[i * 4 + 2] = p.toByte(); rgba[i * 4 + 3] = (p ushr 24).toByte()
            }
            Kern.bildtoene(rgba).toList()
        }
    }
}

/**
 * **Die Punkte einer Flaeche als Bild** — `Bildtonrechnung.punkte`. `hoehe`, `farbhoehe`, `ab` und
 * `auslauf` in derselben Einheit (dp auf dem Telefon, Anteile auf dem Fernseher).
 */
class Bildfarbflaeche(val bild: ImageBitmap, val spalten: Int, val zeilen: Int) {
    companion object {
        fun aus(toene: List<Double>, spalten: Int, zeilen: Int, hoehe: Double, farbhoehe: Double,
                ab: Double, auslauf: Double): Bildfarbflaeche? {
            if (toene.isEmpty()) return null
            val punkte = runCatching {
                Kern.bildtonPunkte(toene.toDoubleArray(), spalten.toLong(), zeilen.toLong(), hoehe, farbhoehe, ab, auslauf)
            }.getOrNull() ?: return null
            if (punkte.size != spalten * zeilen) return null
            val bitmap = Bitmap.createBitmap(punkte, spalten, zeilen, Bitmap.Config.ARGB_8888)
            return Bildfarbflaeche(bitmap.asImageBitmap(), spalten, zeilen)
        }
    }

    /**
     * Auf `breite` × `hoehe` (px) ab `oben` gezogen, bilinear. Um einen halben Punkt ueber den Rand
     * hinaus, damit die Mitte jedes Punkts genau auf seiner Stelle im Raster liegt — sonst stuende die
     * Farbe um einen halben Schritt verschoben.
     */
    fun zeichnen(scope: DrawScope, breite: Float, hoehe: Float, oben: Float = 0f, deckung: Float = 1f) = with(scope) {
        val sx = breite / (spalten - 1).coerceAtLeast(1)
        val sy = hoehe / (zeilen - 1).coerceAtLeast(1)
        drawImage(bild, srcOffset = IntOffset.Zero, srcSize = IntSize(spalten, zeilen),
                  dstOffset = IntOffset((-sx / 2).toInt(), (oben - sy / 2).toInt()),
                  dstSize = IntSize((breite + sx).toInt(), (hoehe + sy).toInt()),
                  alpha = deckung, filterQuality = FilterQuality.Low)
    }
}

/**
 * Feines Rauschen gegen Streifenbildung, wie `Bildton.rauschen` — 96 × 96 gekachelt, in beide Richtungen
 * (schwarz oder weiss mit zufaelliger Deckung), bei 0,008 rund eine Helligkeitsstufe.
 */
object Rauschen {
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

    fun zeichnen(scope: DrawScope, breite: Float, hoehe: Float, oben: Float = 0f, deckung: Float = 1f) = with(scope) {
        drawRect(Rauschen.brush, topLeft = Offset(0f, oben), size = androidx.compose.ui.geometry.Size(breite, hoehe),
                 alpha = 0.008f * deckung)
    }
}

/**
 * **Die Toene eines Bildes, sobald sie da sind** — `Stimmungslader`. Gemerkte stehen im ersten Durchgang
 * (kein Aufblenden), neu gerechnete blenden weich ein (`.smooth(duration: 0.55)`, reduziert kurz).
 */
class Bildtonstand(toene: List<Double>, val deckung: Animatable<Float, AnimationVector1D>) {
    var toene by mutableStateOf(toene)
}

@Composable
fun rememberBildtoene(bild: String?): Bildtonstand {
    val kontext = LocalContext.current
    val ruhig = de.paulherter.swiftly.gemeinsam.bewegungReduziert()
    val stand = remember { Bildtonstand(bild?.let { Bildton.gemerkt(it) }.orEmpty(), Animatable(1f)) }
    LaunchedEffect(bild) {
        if (bild == null) { stand.toene = emptyList(); return@LaunchedEffect }
        Bildton.gemerkt(bild)?.let { if (it != stand.toene) { stand.toene = it; stand.deckung.snapTo(1f) }; return@LaunchedEffect }
        val neu = Bildton.toene(kontext, bild)
        stand.deckung.snapTo(0f)
        stand.toene = neu
        stand.deckung.animateTo(1f, if (ruhig) Bewegung.blendeReduziert() else tween(550, easing = Bewegung.weich))
    }
    return stand
}

/** Die Detailseite, wie `Stimmungsgrund`: Farbe ueber `farbhoehe`, ab dem Kopfbild ueber `auslauf` in den Grund. */
object Stimmung {
    /** So stand sie, als sie gefiel (Runde 3, Paul: „10/10"). */
    const val FARBHOEHE = 900.0
    /** Lang, damit beim Scrollen nirgends eine Grenze steht. */
    const val AUSLAUF = 1300.0
    /** Alle ~17 dp eine Zeile — dicht genug fuer den Auslauf, klein genug fuer jede Seite. */
    private const val SPALTEN = 8
    private const val ZEILEN = 96

    fun flaeche(toene: List<Double>, ab: Double): Bildfarbflaeche? =
        Bildfarbflaeche.aus(toene, SPALTEN, ZEILEN, ab + AUSLAUF, ab + FARBHOEHE, ab, AUSLAUF)
}

/**
 * **Liegt Bildfarbe dahinter?** Dann tragen Knoepfe und Felder durchsichtiges Weiss 8 % statt `flaeche`
 * (`Stil.flaecheDurchsichtig`, `aufBildfarbe` auf iOS). Gesetzt von Film- und Serienseite.
 */
val LocalAufBildfarbe = staticCompositionLocalOf { false }
/** Die Toene der Seite — fuer Tafeln, die deckend ueber Inhalt aufgehen (Staffelliste). */
val LocalBildtoene = staticCompositionLocalOf<List<Double>> { emptyList() }

/** `Stil.flaecheDurchsichtig` — Weiss 8 %, dieselbe Deckkraft wie in Swiftly Music. */
val flaecheDurchsichtig = Color.White.copy(alpha = 0.08f)

/** `Stil.knopfflaeche(aufBild:)` — fest auf `grund`, durchsichtig ueber Bildfarbe. Aktiv aendert sie nicht. */
fun knopfflaeche(aufBild: Boolean): Color = if (aufBild) flaecheDurchsichtig else Stil.flaeche

/** Die Farbe der Seite an einer Stelle (`Bildton.farbe(_, bei: (0,2 · 0,55))`) — fuer die Staffelliste. */
fun bildfarbeBei(toene: List<Double>, x: Double, y: Double): Color =
    Color(Kern.bildtonFarbe(toene.toDoubleArray(), x, y))

/**
 * **Der Grund unter der Detailseite** (`Stimmungsgrund`): am Inhalt der Scrollflaeche, damit die Farbe
 * immer an derselben Stelle zum Kopfbild steht. `ab` ist die Hoehe des Kopfbilds in dp.
 */
fun Modifier.stimmungsgrund(stand: Bildtonstand, ab: Dp): Modifier = composed {
    val toene = stand.toene
    val flaeche = remember(toene, ab) { Stimmung.flaeche(toene, ab.value.toDouble()) }
    drawBehind {
        val f = flaeche ?: return@drawBehind
        val hoehe = (ab.value + Stimmung.AUSLAUF.toFloat()) * density
        val d = stand.deckung.value
        f.zeichnen(this, size.width, hoehe, deckung = d)
        Rauschen.zeichnen(this, size.width, hoehe, deckung = d)
    }
}

/**
 * **Der Auslauf des Kopfbilds in der Farbe der Seite** (`Heldauslauf(bild:)`): dieselben Stufen wie der
 * graue Auslauf, nur im Netz — unten deckend und damit genau der Grund darunter. `ab`: Hoehe des Kopfbilds.
 */
fun Modifier.heldauslaufFarbe(stand: Bildtonstand, ab: Dp, hoehe: Dp): Modifier = composed {
    val toene = stand.toene
    val flaeche = remember(toene, ab) { Stimmung.flaeche(toene, ab.value.toDouble()) }
    drawWithContent {
        drawContent()
        val f = flaeche ?: return@drawWithContent
        val gesamt = (ab.value + Stimmung.AUSLAUF.toFloat()) * density
        val oben = -(ab - hoehe).toPx()
        val d = stand.deckung.value
        // Erst das Netz in seine Lage, dann mit den Stufen des Auslaufs ausmaskieren.
        drawIntoLayer {
            f.zeichnen(this, size.width, gesamt, oben = oben, deckung = d)
            Rauschen.zeichnen(this, size.width, size.height, deckung = d)
            drawRect(Brush.verticalGradient(*HELDSTUFEN.map { (lage, a) -> lage to Color.Black.copy(alpha = a) }.toTypedArray()),
                     blendMode = BlendMode.DstIn)
        }
    }
}

/** Die Stufen von `Heldauslauf` — Lage und Deckung, oben durchsichtig, unten deckend. */
val HELDSTUFEN = listOf(0f to 0f, 0.32f to 0.28f, 0.56f to 0.58f, 0.78f to 0.85f, 1f to 1f)

/** Eine eigene Ebene, damit `DstIn` nur das Netz ausmaskiert, nicht den grauen Verlauf darunter. */
private inline fun DrawScope.drawIntoLayer(crossinline zeichnen: DrawScope.() -> Unit) {
    drawContext.canvas.saveLayer(androidx.compose.ui.geometry.Rect(Offset.Zero, size), androidx.compose.ui.graphics.Paint())
    zeichnen()
    drawContext.canvas.restore()
}
