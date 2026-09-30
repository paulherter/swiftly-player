package de.paulherter.swiftly

import android.content.Context
import android.graphics.Bitmap
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import coil3.SingletonImageLoader
import coil3.request.ImageRequest
import coil3.request.SuccessResult
import coil3.request.allowHardware
import coil3.toBitmap
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.kern.Kern
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.withContext

/** Ein vermessenes, zugeschnittenes Logo, fertig zum Zeichnen. */
class Titellogo(val bild: ImageBitmap, val dichte: Double, val dunkel: Boolean) {
    val seitenverhaeltnis: Double get() = bild.width.toDouble() / bild.height.coerceAtLeast(1)
}

/**
 * Holt Logos, schneidet den transparenten Rand ab, misst — abseits des Hauptlaufs — und merkt das
 * Ergebnis je Adresse. Vorlage `Titellogospeicher` auf iOS; die Rechenregeln (`Titelmarkenmass`) stehen
 * im Paket und kommen ueber den Kern, hier wird nur das Bild entschluesselt und zugeschnitten.
 */
object Titellogospeicher {
    private val bekannt = object : LinkedHashMap<String, Titellogo>(32, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Titellogo>?) = size > 60
    }
    /** Adressen ohne brauchbares Logo, damit nicht jedes Erscheinen neu holt. */
    private val leer = HashSet<String>()
    private val laufend = HashMap<String, Deferred<Titellogo?>>()
    private val sperre = Any()
    private val bereich = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    fun vorhanden(url: String): Titellogo? = synchronized(sperre) { bekannt[url] }

    suspend fun laden(kontext: Context, url: String): Titellogo? {
        val anwendung = kontext.applicationContext
        val aufgabe = synchronized(sperre) {
            bekannt[url]?.let { return it }
            if (url in leer) return null
            laufend.getOrPut(url) { bereich.async { vermessen(anwendung, url) } }
        }
        val ergebnis = aufgabe.await()
        synchronized(sperre) {
            if (ergebnis != null) bekannt[url] = ergebnis else leer.add(url)
            laufend.remove(url)
        }
        return ergebnis
    }

    /** Entschluesseln (hoechstens 800 px), vormultipliziert lesen, vermessen, auf die deckende Box zuschneiden. */
    private suspend fun vermessen(kontext: Context, url: String): Titellogo? {
        val roh = runCatching {
            (SingletonImageLoader.get(kontext).execute(
                ImageRequest.Builder(kontext).data(url).size(800).allowHardware(false)
                    .memoryCacheKey("$url#titelmarke").build()
            ) as? SuccessResult)?.image?.toBitmap()
        }.getOrNull() ?: return null
        return withContext(Dispatchers.Default) {
            runCatching {
                val b = roh.width
                val h = roh.height
                if (b <= 0 || h <= 0) return@runCatching null
                val punkte = IntArray(b * h)
                roh.getPixels(punkte, 0, b, 0, 0, b, h)
                val rgba = ByteArray(punkte.size * 4)
                for (i in punkte.indices) {
                    val p = punkte[i]
                    val a = p ushr 24
                    // getPixels liefert nicht vormultiplizierte Werte; das Paket misst vormultipliziert.
                    rgba[i * 4] = (((p shr 16) and 0xFF) * a / 255).toByte()
                    rgba[i * 4 + 1] = (((p shr 8) and 0xFF) * a / 255).toByte()
                    rgba[i * 4 + 2] = ((p and 0xFF) * a / 255).toByte()
                    rgba[i * 4 + 3] = a.toByte()
                }
                val m = Kern.titelmarkeMessen(rgba, b.toLong(), h.toLong())
                if (m.size < 6) return@runCatching null
                val zu = Bitmap.createBitmap(roh, m[0].toInt(), m[1].toInt(), m[2].toInt(), m[3].toInt())
                Titellogo(zu.asImageBitmap(), m[4], Kern.titelmarkeDunkel(m[5]))
            }.getOrNull()
        }
    }
}

/**
 * Der Titel einer Detailseite: der Text — oder, wenn `logo` gesetzt ist (Einstellungen → Darstellung →
 * „Titel als Logo" an und der Server fuehrt eins), das Logo. Vorlage `Titelmarke` auf iOS.
 *
 * Das Logo kommt auf die Textkante zugeschnitten und nach gleichem optischen Gewicht bemessen
 * (`Titelmarkenmass`), hoechstens 70 Prozent breit; ueberwiegend dunkle Logos stehen als helle
 * Silhouette. Bis Zuschnitt und Messung fertig sind, steht der Text an seinem Platz; scheitert der
 * Abruf, bleibt er. Ohne `logo`: nur der Text, kein Abruf.
 *
 * @param zeile eine Titelzeile in dp (Schriftgroesse der Titelschrift)
 */
@Composable
fun Titelmarke(titel: String, logo: String?, zeile: Dp, modifier: Modifier = Modifier, text: @Composable () -> Unit) {
    if (logo == null) { text(); return }
    val kontext = LocalContext.current
    val marke by produceState(Titellogospeicher.vorhanden(logo), logo) {
        value = Titellogospeicher.vorhanden(logo) ?: Titellogospeicher.laden(kontext, logo)
    }
    val sichtbar by animateFloatAsState(if (marke != null) 1f else 0f, tween(250), label = "titelmarke")
    val dichte = LocalDensity.current
    BoxWithConstraints(modifier.fillMaxWidth().heightIn(min = zeile * 2), contentAlignment = Alignment.BottomStart) {
        val m = marke
        val maxBreite = maxWidth * 0.7f
        Box(Modifier.alpha(1f - sichtbar).semantics { contentDescription = titel; heading() }) { text() }
        if (m != null) {
            val g = Kern.titelmarkeGroesse(m.seitenverhaeltnis, m.dichte, zeile.value.toDouble(), maxBreite.value.toDouble())
            Image(m.bild, contentDescription = titel, modifier = Modifier.size(g[0].dp, g[1].dp).alpha(sichtbar),
                  colorFilter = if (m.dunkel) ColorFilter.tint(Stil.schrift) else null)
        }
    }
}
