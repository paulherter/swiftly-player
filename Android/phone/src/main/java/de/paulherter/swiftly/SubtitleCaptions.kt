package de.paulherter.swiftly

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.text.Layout
import android.text.Spannable
import android.text.SpannableStringBuilder
import android.text.StaticLayout
import android.text.TextPaint
import android.text.style.BackgroundColorSpan
import android.text.style.CharacterStyle
import android.text.style.ForegroundColorSpan
import android.text.style.StrikethroughSpan
import android.text.style.StyleSpan
import android.text.style.UnderlineSpan
import android.util.AttributeSet
import android.view.View
import android.widget.FrameLayout
import androidx.annotation.OptIn
import androidx.media3.common.text.Cue
import androidx.media3.common.util.UnstableApi
import androidx.media3.ui.SubtitleView
import org.json.JSONObject
import kotlinx.coroutines.launch
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * **The text subtitles, drawn like the Apple overlay draws them** (`SubtitleOverlay.swift`), on phone and TV.
 *
 * Media3's own `SubtitleView` paints the outline and shadow at a fixed 2 dp and in the system's regular
 * typeface, so on a big picture the outline was thin next to the Apple one and the letters lighter
 *. This view draws the same recipe as the shared overlay:
 * Inter SemiBold; size = picture height x 6.25 % x the look's scale; the outline is the look's percent of
 * the font size (the Apple stroke width is `2 x percent`, centred on the edge, drawn over the fill, black
 * at 90 %); Hebrew, Indic and South-East-Asian runs get 75 %, Arabic-like runs 60 % of it, stroke behind the
 * letters (`SubtitleScript`). Bitmap cues (PGS, VobSub) stay with Media3's own view.
 */
@OptIn(UnstableApi::class)
class CaptionLayer @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) : FrameLayout(context, attrs) {
    private val bitmaps = SubtitleView(context).apply {
        setApplyEmbeddedStyles(true)
        setApplyEmbeddedFontSizes(false)
    }
    val text = TextCaptionView(context)

    init {
        addView(bitmaps, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        addView(text, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
    }

    /** Media3's cue output: pictures go to Media3's view, text to ours. */
    fun setCues(cues: List<Cue>) {
        bitmaps.setCues(cues.filter { it.bitmap != null })
        text.setCues(cues.filter { it.bitmap == null }.mapNotNull { it.text })
    }

    /** The look as `Kern.subtitleLookFacts` hands it out. */
    fun apply(facts: JSONObject?) {
        raised = facts?.optBoolean("raised") ?: false
        text.apply(facts)
        bitmapMarginApply()
    }

    private var raised = false

    /** Picture cues (PGS) that carry no position of their own sit at the same margin as the text. */
    private fun bitmapMarginApply() {
        if (height > 0) bitmaps.setBottomPaddingFraction(SubtitleMargin.px(height, resources.displayMetrics.density, raised) / height)
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        bitmapMarginApply()
    }
}

/**
 * Contract line 8a, the same on every platform (Apple: `SubtitleOverlay.margin(raised:pictureHeight:)`): the text's lowest
 * edge is 16 dp above the bottom edge of the picture; raised, 7 % of the picture height more.
 */
object SubtitleMargin {
    const val BASE_DP = 16f
    const val RAISED_FRACTION = 0.07f
    fun px(pictureHeight: Int, density: Float, raised: Boolean): Float =
        BASE_DP * density + if (raised) RAISED_FRACTION * pictureHeight else 0f
}

/** One sort of script, as `SubtitleScript.Density`. */
internal enum class ScriptDensity(val outlineScale: Float) { PLAIN(1f), DENSE(0.75f), CONNECTED(0.6f) }

internal object CaptionScript {
    fun densityOf(cp: Int): ScriptDensity? = when (cp) {
        in 0x0600..0x06FF, in 0x0700..0x074F, in 0x0750..0x077F, in 0x0780..0x07BF, in 0x07C0..0x07FF,
        in 0x08A0..0x08FF, in 0xFB50..0xFDFF, in 0xFE70..0xFEFF -> ScriptDensity.CONNECTED
        in 0x0590..0x05FF, in 0xFB1D..0xFB4F, in 0x0900..0x0DFF, in 0x0E00..0x0EFF, in 0x0F00..0x0FFF,
        in 0x1000..0x109F, in 0x1780..0x17FF, in 0x19E0..0x19FF -> ScriptDensity.DENSE
        else -> when (Character.getType(cp).toByte()) {
            Character.UPPERCASE_LETTER, Character.LOWERCASE_LETTER, Character.TITLECASE_LETTER,
            Character.MODIFIER_LETTER, Character.OTHER_LETTER -> ScriptDensity.PLAIN
            else -> null
        }
    }

    /** The line cut into runs of one density (UTF-16 ranges); neutral characters join the run before them. */
    fun runs(line: CharSequence): List<Triple<Int, Int, ScriptDensity>> {
        val out = ArrayList<Triple<Int, Int, ScriptDensity>>()
        var start = 0
        var current: ScriptDensity? = null
        var i = 0
        while (i < line.length) {
            val cp = Character.codePointAt(line, i)
            val found = densityOf(cp)
            if (found != null) {
                val now = current
                if (now != null && now != found) { out.add(Triple(start, i, now)); start = i }
                current = found
            }
            i += Character.charCount(cp)
        }
        if (line.isNotEmpty()) out.add(Triple(start, line.length, current ?: ScriptDensity.PLAIN))
        return out
    }
}

/** Draws a stroke (outline) of the characters it covers: used for the outline passes. */
private class StrokeSpan(private val width: Float, private val color: Int) : CharacterStyle() {
    override fun updateDrawState(ds: TextPaint) {
        ds.style = Paint.Style.STROKE
        ds.strokeWidth = width
        ds.strokeJoin = Paint.Join.ROUND
        ds.color = color
        ds.clearShadowLayer()
        ds.bgColor = Color.TRANSPARENT
    }
}

/** Draws nothing for the characters it covers (they belong to another pass). */
private class InvisibleSpan : CharacterStyle() {
    override fun updateDrawState(ds: TextPaint) { ds.color = Color.TRANSPARENT; ds.bgColor = Color.TRANSPARENT; ds.clearShadowLayer() }
}

class TextCaptionView @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) : View(context, attrs) {
    /** Last cue text on screen, for tests and logs. */
    var shownText: String = ""
        private set

    private var cues: List<CharSequence> = emptyList()
    private var fraction = 0.0625f * 0.82f
    private var fill = Color.WHITE
    private var thickness = 3
    private var shadow = false
    private var background = false
    private var keepFileStyle = true
    private var raised = false

    private val typeface: Typeface by lazy { inter(context) }

    fun setCues(c: List<CharSequence>) {
        cues = c.filter { it.isNotBlank() }
        shownText = cues.joinToString("\n") { it.toString() }
        invalidate()
    }

    fun apply(f: JSONObject?) {
        if (f != null) {
            fraction = f.optDouble("fraction", 0.0625 * 0.82).toFloat()
            fill = 0xFF000000.toInt() or f.optInt("rgb", 0xFFFFFF)
            thickness = if (f.optString("edge") == "outline") f.optInt("thickness", 3) else 0
            shadow = f.optString("edge") == "shadow"
            background = f.optBoolean("background")
            keepFileStyle = f.optBoolean("keepFileStyle", true)
            raised = f.optBoolean("raised")
        }
        invalidate()
    }

    /** Draws the captions on top of whatever `canvas` holds, the picture being `w` x `h`. */
    private fun paint(canvas: Canvas, w: Int, h: Int) {
        if (cues.isEmpty() || w < 2 || h < 2) return
        val size = h * fraction
        var bottom = h - SubtitleMargin.px(h, resources.displayMetrics.density, raised)
        for (cue in cues.asReversed()) {
            val layouts = layoutsFor(cue, size, (w * 0.9f).roundToInt())
            val height = layouts.fill.height.toFloat()
            val top = bottom - height
            canvas.save()
            val x = (w - layouts.fill.width) / 2f
            canvas.translate(x, top)
            if (background) drawBackground(canvas, layouts.fill, size)
            layouts.behind?.draw(canvas)
            layouts.fill.draw(canvas)
            layouts.over?.draw(canvas)
            canvas.restore()
            bottom = top - size * 0.25f
        }
    }

    override fun onDraw(canvas: Canvas) = paint(canvas, width, height)

    /** The captions on a flat ground, `w` x `h`: what the player draws, for tests. */
    fun renderOn(ground: Int, w: Int, h: Int): Bitmap {
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        c.drawColor(ground)
        paint(c, w, h)
        return bmp
    }

    private class Layouts(val behind: StaticLayout?, val fill: StaticLayout, val over: StaticLayout?)

    private fun paintOf(size: Float, style: Paint.Style = Paint.Style.FILL) = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        this.typeface = this@TextCaptionView.typeface
        textSize = size
        color = fill
        this.style = style
    }

    private fun layoutsFor(cue: CharSequence, size: Float, maxWidth: Int): Layouts {
        val plain = cue.toString()
        val runs = CaptionScript.runs(plain)
        // The Apple stroke is `2 x percent` of the font size; Skia strokes come out about 10 % lighter than CoreText's at the
        // same width, measured against the Apple render (`STROKE_MATCH`).
        val strokeWidth = size * thickness * 2f / 100f * STROKE_MATCH
        val outlineColor = Color.argb(230, 0, 0, 0)
        fun make(spannable: CharSequence, p: TextPaint, width: Int): StaticLayout =
            StaticLayout.Builder.obtain(spannable, 0, spannable.length, p, width)
                .setAlignment(Layout.Alignment.ALIGN_CENTER).setIncludePad(false).build()

        // The file's colours and slants only with "keep the file's style"; its sizes never apply.
        val styled = SpannableStringBuilder(plain)
        if (keepFileStyle && cue is android.text.Spanned) {
            for (span in cue.getSpans(0, cue.length, Any::class.java)) {
                val keep = span is ForegroundColorSpan || span is BackgroundColorSpan || span is StyleSpan ||
                    span is UnderlineSpan || span is StrikethroughSpan
                if (keep) styled.setSpan(span, cue.getSpanStart(span), cue.getSpanEnd(span), cue.getSpanFlags(span))
            }
        }
        val paint = paintOf(size).also { if (shadow) it.setShadowLayer(0.01f, 0f, size * 0.04f, Color.argb(160, 0, 0, 0)) }
        val probe = make(styled, paint, maxWidth)
        var widest = 0f
        for (i in 0 until probe.lineCount) widest = max(widest, probe.getLineWidth(i))
        val width = min(maxWidth, widest.roundToInt() + (size * 0.0f).roundToInt() + 2)
        val fillLayout = if (width == probe.width) probe else make(styled, paint, width)
        if (thickness == 0) return Layouts(null, fillLayout, null)

        fun pass(forComplex: Boolean): StaticLayout? {
            val s = SpannableStringBuilder(plain)
            if (keepFileStyle && cue is android.text.Spanned) {
                for (span in cue.getSpans(0, cue.length, StyleSpan::class.java)) {
                    s.setSpan(span, cue.getSpanStart(span), cue.getSpanEnd(span), cue.getSpanFlags(span))
                }
            }
            var any = false
            for ((from, to, density) in runs) {
                val complex = density != ScriptDensity.PLAIN
                if (complex == forComplex) {
                    // Behind the letters only the outside is seen: `outlineScale` of the outline, as on Apple.
                    s.setSpan(StrokeSpan(strokeWidth * (if (complex) density.outlineScale else 1f), outlineColor), from, to, Spannable.SPAN_INCLUSIVE_INCLUSIVE)
                    any = true
                } else {
                    s.setSpan(InvisibleSpan(), from, to, Spannable.SPAN_INCLUSIVE_INCLUSIVE)
                }
            }
            return if (any) make(s, paintOf(size), width) else null
        }
        return Layouts(behind = pass(true), fill = fillLayout, over = pass(false))
    }

    /** One box behind the whole text, a quarter of the font size wider on each side (the Apple layer: text + `size` wide). */
    private fun drawBackground(canvas: Canvas, layout: StaticLayout, size: Float) {
        val p = Paint().apply { color = Color.argb(160, 0, 0, 0) }
        canvas.drawRect(-size / 4, 0f, layout.width + size / 4, layout.height.toFloat(), p)
    }

    companion object {
        /** Skia-to-CoreText stroke match, fitted on the standard, "Paul" and shadow looks (subtitle-reference.json). */
        const val STROKE_MATCH = 1.1f
        @Volatile private var cached: Typeface? = null

        /** Inter 18pt SemiBold, the very file the Apple overlay draws with (shipped as `assets/fonts/Inter-SemiBold.ttf`). */
        fun inter(context: Context): Typeface {
            cached?.let { return it }
            val built = runCatching { Typeface.createFromAsset(context.assets, "fonts/Inter-SemiBold.ttf") }.getOrNull()
                ?: Typeface.create(Typeface.DEFAULT, 600, false)
            cached = built
            return built
        }
    }
}

/** The player follows the stored look: a change (settings page, sync from another device) applies at once. */
fun PlayerEngine.followLook(settings: Settings, scope: kotlinx.coroutines.CoroutineScope): kotlinx.coroutines.Job =
    scope.launch { androidx.compose.runtime.snapshotFlow { settings.subtitleLook }.collect { lookSet(it) } }
