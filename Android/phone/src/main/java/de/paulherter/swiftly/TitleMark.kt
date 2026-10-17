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
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.core.Kern
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.withContext

/** A measured, cropped logo, ready to draw. */
class TitleLogo(val image: ImageBitmap, val density: Double, val dark: Boolean) {
    val pagesRatio: Double get() = image.width.toDouble() / image.height.coerceAtLeast(1)
}

/**
 * Fetches logos, crops the transparent margin, measures (off the main thread) and remembers the
 * result per URL. Mirrors `TitleLogoCache` on iOS; the calculation rules (`TitleMarksMetric`)
 * live in the package and come via the core, here the image is only decoded and cropped.
 */
object TitleLogoCache {
    private val known = object : LinkedHashMap<String, TitleLogo>(32, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, TitleLogo>?) = size > 60
    }
    /** URLs without a usable logo, so not every appearance fetches again. */
    private val empty = HashSet<String>()
    private val ongoing = HashMap<String, Deferred<TitleLogo?>>()
    private val barrier = Any()
    private val section = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    fun available(url: String): TitleLogo? = synchronized(barrier) { known[url] }

    suspend fun load(context: Context, url: String): TitleLogo? {
        val hostApp = context.applicationContext
        val task = synchronized(barrier) {
            known[url]?.let { return it }
            if (url in empty) return null
            ongoing.getOrPut(url) { section.async { gauge(hostApp, url) } }
        }
        val result = task.await()
        synchronized(barrier) {
            if (result != null) known[url] = result else empty.add(url)
            ongoing.remove(url)
        }
        return result
    }

    /** Decode (at most 800 px), read premultiplied, measure, crop to the opaque box. */
    private suspend fun gauge(context: Context, url: String): TitleLogo? {
        val raw = runCatching {
            (SingletonImageLoader.get(context).execute(
                ImageRequest.Builder(context).data(url).size(800).allowHardware(false)
                    .memoryCacheKey("$url#titelmarke").build()
            ) as? SuccessResult)?.image?.toBitmap()
        }.getOrNull() ?: return null
        return withContext(Dispatchers.Default) {
            runCatching {
                val b = raw.width
                val h = raw.height
                if (b <= 0 || h <= 0) return@runCatching null
                val points = IntArray(b * h)
                raw.getPixels(points, 0, b, 0, 0, b, h)
                val rgba = ByteArray(points.size * 4)
                for (i in points.indices) {
                    val p = points[i]
                    val a = p ushr 24
                    // getPixels returns non-premultiplied values; the package measures premultiplied.
                    rgba[i * 4] = (((p shr 16) and 0xFF) * a / 255).toByte()
                    rgba[i * 4 + 1] = (((p shr 8) and 0xFF) * a / 255).toByte()
                    rgba[i * 4 + 2] = ((p and 0xFF) * a / 255).toByte()
                    rgba[i * 4 + 3] = a.toByte()
                }
                val m = Kern.titleMarkMeasure(rgba, b.toLong(), h.toLong())
                if (m.size < 6) return@runCatching null
                val toward = Bitmap.createBitmap(raw, m[0].toInt(), m[1].toInt(), m[2].toInt(), m[3].toInt())
                TitleLogo(toward.asImageBitmap(), m[4], Kern.titleMarkDark(m[5]))
            }.getOrNull()
        }
    }
}

/**
 * A detail page's title: the text, or, when `logo` is set (Settings, Appearance, "Title as
 * logo" on and the server has one), the logo. Mirrors `TitleMark` on iOS.
 *
 * The logo is cropped to the text edge and sized for equal optical weight (`TitleMarksMetric`),
 * at most 70 percent wide; mostly dark logos show as a light silhouette. Until cropping and
 * measuring are done, the text stays in place; if the fetch fails, it stays. Without `logo`: just
 * the text, no fetch.
 *
 * @param zeile one title line in dp (font size of the title type)
 */
@Composable
fun TitleMark(title: String, logo: String?, row: Dp, modifier: Modifier = Modifier, text: @Composable () -> Unit) {
    if (logo == null) { text(); return }
    val context = LocalContext.current
    val mark by produceState(TitleLogoCache.available(logo), logo) {
        value = TitleLogoCache.available(logo) ?: TitleLogoCache.load(context, logo)
    }
    val visible by animateFloatAsState(if (mark != null) 1f else 0f, tween(250), label = "titelmarke")
    val density = LocalDensity.current
    BoxWithConstraints(modifier.fillMaxWidth().heightIn(min = row * 2), contentAlignment = Alignment.BottomStart) {
        val m = mark
        val maxWidth = maxWidth * 0.7f
        Box(Modifier.alpha(1f - visible).semantics { contentDescription = title; heading() }) { text() }
        if (m != null) {
            val g = Kern.titleMarkSize(m.pagesRatio, m.density, row.value.toDouble(), maxWidth.value.toDouble())
            Image(m.image, contentDescription = title, modifier = Modifier.size(g[0].dp, g[1].dp).alpha(visible),
                  colorFilter = if (m.dark) ColorFilter.tint(Theme.font) else null)
        }
    }
}
