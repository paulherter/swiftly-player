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
import de.paulherter.swiftly.shared.Motion
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.core.Kern
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.withContext

/**
 * Color from the image. Mirrors `Sources/Shared/ImageTone.swift` and `Sources/iOS/ImageMood.swift`.
 *
 * The math runs in the core (`AvComputation` in the package): the tones of an image and the
 * color at each position, including the fade-out in OKLab. What stays here is what only Android
 * can do: decode the image, hold the points as a small bitmap and stretch it smoothly over the
 * surface.
 *
 * A small bitmap stretched bilinearly, not a mesh like `MeshGradient`. `AvComputation.points`
 * samples the same continuous color densely (every ~17 dp on the phone); the GPU blends in
 * between. The anti-banding noise lies on top as on Apple.
 */
object ImageTone {
    /** Process-wide like `ImageTone.shared.known`, so a new page has the tone in its first frame. Bounded. */
    private val known = object : LinkedHashMap<String, List<Double>>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, List<Double>>?) = size > Limit
    }
    private const val Limit = 400
    private val ongoing = mutableMapOf<String, Deferred<List<Double>>>()
    private val barrier = Any()
    /** Lives as long as the process, so a closed page does not cancel a computation another page needs. */
    private val section = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    /** Non-blocking, so a new page can show the tone in its first frame. */
    fun remembered(image: String): List<Double>? = synchronized(barrier) { known[image] }

    /** Up to five hues in degrees, by weight; empty if none can be derived. */
    suspend fun tones(context: Context, image: String): List<Double> {
        remembered(image)?.let { return it }
        val hostApp = context.applicationContext
        val task = synchronized(barrier) {
            known[image]?.let { return it }
            ongoing.getOrPut(image) { section.async { calculate(hostApp, image) } }
        }
        val result = task.await()
        synchronized(barrier) { known[image] = result; ongoing.remove(image) }
        return result
    }

    private suspend fun calculate(context: Context, image: String): List<Double> {
        val bitMap = runCatching {
            (SingletonImageLoader.get(context).execute(
                // Own cache key: otherwise this 48 px image would replace the large backdrop of the same
                                // URL in the cache, and the next backdrop would have to reload.
                ImageRequest.Builder(context).data(image).size(48).allowHardware(false).memoryCacheKey("$image#bildton").build()
            ) as? SuccessResult)?.image?.toBitmap()
        }.getOrNull() ?: return emptyList()
        return withContext(Dispatchers.Default) {
            val width = bitMap.width
            val height = bitMap.height
            if (width <= 0 || height <= 0) return@withContext emptyList()
            val points = IntArray(width * height)
            bitMap.getPixels(points, 0, width, 0, 0, width, height)
            val rgba = ByteArray(points.size * 4)
            for (i in points.indices) {
                val p = points[i]
                rgba[i * 4] = (p shr 16).toByte(); rgba[i * 4 + 1] = (p shr 8).toByte()
                rgba[i * 4 + 2] = p.toByte(); rgba[i * 4 + 3] = (p ushr 24).toByte()
            }
            Kern.imageTones(rgba).toList()
        }
    }
}

/**
 * The points of a surface as a bitmap (`AvComputation.points`). `height`, `colorHeight`, `since` and
 * `runOut` use the same unit (dp on the phone, fractions on TV).
 */
class ImageColorArea(val image: ImageBitmap, val columns: Int, val rows: Int) {
    companion object {
        fun from(tones: List<Double>, columns: Int, rows: Int, height: Double, colorHeight: Double,
                since: Double, runOut: Double): ImageColorArea? {
            if (tones.isEmpty()) return null
            val points = runCatching {
                Kern.imageTonePoints(tones.toDoubleArray(), columns.toLong(), rows.toLong(), height, colorHeight, since, runOut)
            }.getOrNull() ?: return null
            if (points.size != columns * rows) return null
            val bitMap = Bitmap.createBitmap(points, columns, rows, Bitmap.Config.ARGB_8888)
            return ImageColorArea(bitMap.asImageBitmap(), columns, rows)
        }
    }

    /**
         * Stretched bilinearly to `width` x `height` (px) from `top`. Extends half a point beyond the
         * edge so the center of each point lies exactly at its grid position; otherwise the color
         * would be shifted by half a step.
         */
    fun draw(scope: DrawScope, width: Float, height: Float, top: Float = 0f, coverage: Float = 1f) = with(scope) {
        val sx = width / (columns - 1).coerceAtLeast(1)
        val sy = height / (rows - 1).coerceAtLeast(1)
        drawImage(image, srcOffset = IntOffset.Zero, srcSize = IntSize(columns, rows),
                  dstOffset = IntOffset((-sx / 2).toInt(), (top - sy / 2).toInt()),
                  dstSize = IntSize((width + sx).toInt(), (height + sy).toInt()),
                  alpha = coverage, filterQuality = FilterQuality.Low)
    }
}

/**
 * Fine noise against banding, like `ImageTone.noise`: 96 x 96 tiled in both directions (black
 * or white with random alpha), about one brightness step at 0.008.
 */
object Noise {
    val brush: Brush by lazy { generate() }

    private fun generate(): Brush {
        val border = 96
        val bitMap = Bitmap.createBitmap(border, border, Bitmap.Config.ARGB_8888)
        val pixel = IntArray(border * border)
        var condition = 0x2545F4914F6CDD1DL
        for (i in pixel.indices) {
            condition = condition xor (condition shl 13)
            condition = condition xor (condition ushr 7)
            condition = condition xor (condition shl 17)
            val bright = (condition and 1L) == 1L
            val coverage = ((condition ushr 8) and 0xFF).toInt()
            val channel = if (bright) 255 else 0
            pixel[i] = (coverage shl 24) or (channel shl 16) or (channel shl 8) or channel
        }
        bitMap.setPixels(pixel, 0, border, 0, 0, border, border)
        return ShaderBrush(BitmapShader(bitMap, Shader.TileMode.REPEAT, Shader.TileMode.REPEAT))
    }

    fun draw(scope: DrawScope, width: Float, height: Float, top: Float = 0f, coverage: Float = 1f) = with(scope) {
        drawRect(Noise.brush, topLeft = Offset(0f, top), size = androidx.compose.ui.geometry.Size(width, height),
                 alpha = 0.008f * coverage)
    }
}

/**
 * The tones of an image once available (`MoodLoader`). Remembered ones are there in the first
 * pass (no fade-in), newly computed ones fade in smoothly (`.smooth(duration: 0.55)`, short with
 * reduced motion).
 */
class AvState(tones: List<Double>, val coverage: Animatable<Float, AnimationVector1D>) {
    var tones by mutableStateOf(tones)
}

@Composable
fun rememberImageAudio(image: String?): AvState {
    val context = LocalContext.current
    val calm = de.paulherter.swiftly.shared.motionReduced()
    val state = remember { AvState(image?.let { ImageTone.remembered(it) }.orEmpty(), Animatable(1f)) }
    LaunchedEffect(image) {
        if (image == null) { state.tones = emptyList(); return@LaunchedEffect }
        ImageTone.remembered(image)?.let { if (it != state.tones) { state.tones = it; state.coverage.snapTo(1f) }; return@LaunchedEffect }
        val new = ImageTone.tones(context, image)
        state.coverage.snapTo(0f)
        state.tones = new
        state.coverage.animateTo(1f, if (calm) Motion.fadeReduced() else tween(550, easing = Motion.soft))
    }
    return state
}

/** The detail page like `MoodReason`: color over `colorHeight`, from the header image over `runOut` into the ground. */
object Mood {
    /** The look that was approved. */
    const val ColorHeight = 900.0
    /** Long, so no edge shows while scrolling. */
    const val RunOut = 1300.0
    /** One row every ~17 dp: dense enough for the fade-out, small enough for any page. */
    private const val Columns = 8
    private const val ROW_COUNT = 96

    fun area(tones: List<Double>, since: Double): ImageColorArea? =
        ImageColorArea.from(tones, Columns, ROW_COUNT, since + RunOut, since + ColorHeight, since, RunOut)
}

/**
 * Is image color behind this? Then buttons and fields use translucent white at 8 % instead of
 * `area` (`Theme.flaecheDurchsichtig`, `onImageTint` on iOS). Set by the movie and series pages.
 */
val LocalImageColor = staticCompositionLocalOf { false }
/** The page's tones, for panels that open opaquely over content (season list). */
val LocalImageAudio = staticCompositionLocalOf<List<Double>> { emptyList() }

/** `Theme.flaecheDurchsichtig`: white at 8 %. */
val surfaceTranslucent = Color.White.copy(alpha = 0.08f)

/** `Theme.buttonArea(onImage:)`: solid `reason`, translucent over image color. Active does not change it. */
fun buttonArea(onImage: Boolean): Color = if (onImage) surfaceTranslucent else Theme.area

/** The page color at one position (`ImageTone.farbe(_, at: (0.2 · 0.55))`), for the season list. */
fun imageColor(tones: List<Double>, x: Double, y: Double): Color =
    Color(Kern.imageToneColor(tones.toDoubleArray(), x, y))

/**
 * The ground under the detail page (`MoodReason`): attached to the scroll content so the
 * color always sits at the same place relative to the header image. `since` is the header image
 * height in dp.
 */
fun Modifier.moodReason(state: AvState, since: Dp): Modifier = composed {
    val tones = state.tones
    val area = remember(tones, since) { Mood.area(tones, since.value.toDouble()) }
    drawBehind {
        val f = area ?: return@drawBehind
        val height = (since.value + Mood.RunOut.toFloat()) * density
        val d = state.coverage.value
        f.draw(this, size.width, height, coverage = d)
        Noise.draw(this, size.width, height, coverage = d)
    }
}

/**
 * The header image's fade-out in the page color (`HeroRunOut(image:)`): same steps as the gray
 * fade-out, but in the mesh; opaque at the bottom, so exactly the ground below. `since`: header
 * image height.
 */
fun Modifier.heroRunOutColor(state: AvState, since: Dp, height: Dp): Modifier = composed {
    val tones = state.tones
    val area = remember(tones, since) { Mood.area(tones, since.value.toDouble()) }
    drawWithContent {
        drawContent()
        val f = area ?: return@drawWithContent
        val total = (since.value + Mood.RunOut.toFloat()) * density
        val top = -(since - height).toPx()
        val d = state.coverage.value
        // First put the mesh in place, then mask it with the fade-out steps.
        drawIntoLayer {
            f.draw(this, size.width, total, top = top, coverage = d)
            Noise.draw(this, size.width, size.height, coverage = d)
            drawRect(Brush.verticalGradient(*HeroLevels.map { (status, a) -> status to Color.Black.copy(alpha = a) }.toTypedArray()),
                     blendMode = BlendMode.DstIn)
        }
    }
}

/** The steps of `HeroRunOut`: position and alpha, transparent at the top, opaque at the bottom. */
val HeroLevels = listOf(0f to 0f, 0.32f to 0.28f, 0.56f to 0.58f, 0.78f to 0.85f, 1f to 1f)

/** Its own layer so `DstIn` masks only the mesh, not the gray gradient below. */
private inline fun DrawScope.drawIntoLayer(crossinline draw: DrawScope.() -> Unit) {
    drawContext.canvas.saveLayer(androidx.compose.ui.geometry.Rect(Offset.Zero, size), androidx.compose.ui.graphics.Paint())
    draw()
    drawContext.canvas.restore()
}
