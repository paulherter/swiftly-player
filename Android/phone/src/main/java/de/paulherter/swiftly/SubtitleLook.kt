package de.paulherter.swiftly

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Paint
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import de.paulherter.swiftly.core.Kern
import de.paulherter.swiftly.shared.Motion
import de.paulherter.swiftly.shared.translated
import org.json.JSONObject
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.roundToInt
import kotlin.math.sin

// **The subtitle look on Android, phone and TV.** Every rule (steps, defaults, option lists) is in the
// package (`SubtitleLook`) and reaches this side through `Kern.subtitleLook…`; this file holds the
// words and the self-drawn preview, which both pages share, exactly as `SubtitlePreview.swift` does
// for the three Apple versions. The numbers of the drawing follow the spec
// (`Notizen/Mehrserver/UNTERTITEL-ENTWURF.md`, section 5) and have not been compared with VLC yet.

/** The base scale of "Normal": 0.82 on the phone, 0.88 on TV (`SubtitleStyle.baseScale`). */
object SubtitleBase {
    fun of(isTv: Boolean): Double = if (isTv) 0.88 else 0.82
}

/** The stored words of every field, in the order the page lists them (`allCases` in the package). */
object SubtitleSteps {
    val sizes = listOf("small", "normal", "large", "huge")
    val colours = listOf("white", "yellow", "grey")
    val outlines = listOf("off", "thin", "normal")
    val positions = listOf("bottom", "raised")
}

/** What the preview and the pages need from a look, derived in the package (`Kern.subtitleLookFacts`). */
class SubtitleFacts private constructor(private val o: JSONObject) {
    val size: String get() = o.optString("size", "normal")
    val colour: String get() = o.optString("colour", "white")
    val outline: String get() = o.optString("outline", "normal")
    val position: String get() = o.optString("position", "bottom")
    val shadow: Boolean get() = o.optBoolean("shadow")
    val background: Boolean get() = o.optBoolean("background")
    val keepFileStyle: Boolean get() = o.optBoolean("keepFileStyle", true)
    val raised: Boolean get() = o.optBoolean("raised")
    val standard: Boolean get() = o.optBoolean("standard", true)
    /** `--sub-text-scale` for this look and platform. */
    val percent: Int get() = o.optInt("percent", 82)
    val rgb: Int get() = o.optInt("rgb", 0xFFFFFF)
    /** Outline thickness in percent of the text height. */
    val thickness: Int get() = o.optInt("thickness", 3)

    val color: Color get() = Color(0xFF000000.toInt() or rgb)

    companion object {
        fun of(look: String, isTv: Boolean): SubtitleFacts =
            SubtitleFacts(runCatching { JSONObject(Kern.subtitleLookFacts(look, SubtitleBase.of(isTv))) }.getOrDefault(JSONObject()))
    }
}

// MARK: - Words (the German wording is the key, identical to the Apple catalog)

fun subtitleSizeName(word: String): String = translated(when (word) {
    "small" -> "Klein"; "large" -> "Groß"; "huge" -> "Sehr groß"; else -> "Normal" })

fun subtitleColourName(word: String): String = translated(when (word) {
    "yellow" -> "Gelb"; "grey" -> "Grau"; else -> "Weiß" })

fun subtitleOutlineName(word: String): String = translated(when (word) {
    "off" -> "Aus"; "thin" -> "Dünn"; else -> "Normal" })

fun subtitlePositionName(word: String): String = translated(if (word == "raised") "Höher" else "Unten")

/** The "A" of a size segment, growing with the step (spec section 3, row 1), in sp. */
fun subtitleGlyphSize(word: String): Int = when (word) { "small" -> 12; "large" -> 17; "huge" -> 20; else -> 15 }

/** The value of the entry row ("Aussehen der Untertitel"). */
fun SubtitleFacts.entryValue(): String = translated(if (standard) "Standard" else "Eigenes")

/** The whole setting as one sentence, for TalkBack on the preview (spec section 8). */
fun SubtitleFacts.sentence(): String = listOf(
    subtitleSizeName(size),
    subtitleColourName(colour),
    when (outline) { "off" -> translated("ohne Rand"); "thin" -> translated("Rand dünn"); else -> translated("Rand normal") },
    translated(if (shadow) "mit Schatten" else "ohne Schatten"),
    translated(if (background) "mit Hintergrund" else "ohne Hintergrund"),
    translated(if (position == "bottom") "unten" else "höher"),
).joinToString(", ")

/** The line under the file switch: it says what applies **now** (spec section 3). */
fun SubtitleFacts.fileStyleLine(): String = translated(
    if (keepFileStyle) "Bei ASS und SSA bestimmt die Datei Schrift, Farbe und Position. Schilder und Karaoke bleiben im Bild."
    else "Auch ASS und SSA sehen dann aus wie oben. Schilder rutschen als Zeile nach unten.")

/** One field changed, in the package's text form. */
fun subtitleLookChanged(look: String, field: String, value: String): String = Kern.subtitleLookChange(look, field, value)

// MARK: - Preview

/**
 * **The picture with the subtitle, drawn by the app, not by VLC** (mirrors `SubtitlePreview`). The text
 * is drawn like VLC calculates it: outline = step percent of the text height in black at 230/255,
 * shadow = black 160/255, 4 percent of the text height straight down, hard, background = black
 * 160/255 as a box per line with a quarter of the height around it, no rounded corners. "Higher"
 * lifts the text by 7 percent of the picture height.
 *
 * `previewHeight` is the picture height the player's text is sized against (phone: the short side of the
 * screen; TV: the screen height), not the height of this drawing, so "Normal" is as big here as in the
 * player. The drawing is 16:9 at least, taller when the text does not fit.
 */
@Composable
fun SubtitlePreview(facts: SubtitleFacts, previewHeight: Dp, modifier: Modifier = Modifier,
                    cornerRadius: Dp = 16.dp, bottomGap: Dp = 16.dp) {
    val target = previewHeight * 0.0625f * (facts.percent / 100f)
    val points by animateFloatAsState(target.value, Motion.change(), label = "untertitelGroesse")
    val colour by animateColorAsState(facts.color, Motion.change(), label = "untertitelFarbe")
    val lift = previewHeight * (if (facts.raised) 0.07f else 0f)
    val liftNow by animateFloatAsState(lift.value, Motion.change(), label = "untertitelHoeher")
    val density = LocalDensity.current
    val sentence = facts.sentence()
    val label = translated("Vorschau")
    Layout(
        content = {
            PreviewPicture()
            PreviewText(facts, colour, points, bottomGap)
        },
        modifier = modifier.fillMaxWidth().clip(RoundedCornerShape(cornerRadius))
            // One element: the text itself is part of the picture and is not read.
            .clearAndSetSemantics { contentDescription = label; stateDescription = sentence },
    ) { measurables, constraints ->
        val width = constraints.maxWidth
        val liftPx = with(density) { liftNow.dp.roundToPx() }
        val text = measurables[1].measure(Constraints(maxWidth = width))
        val height = max((width * 9f / 16f).roundToInt(), ((text.height + liftPx) / 0.85f).roundToInt())
        val picture = measurables[0].measure(Constraints.fixed(width, height))
        layout(width, height) {
            picture.place(0, 0)
            text.place(0, height - text.height - liftPx)
        }
    }
}

/** The picture from the resources. A gradient with a light strip stands under it, never an empty surface. */
@Composable
private fun PreviewPicture() {
    Box(Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color(0.063f, 0.063f, 0.063f), Color(0.227f, 0.227f, 0.227f)))))
        Column(Modifier.fillMaxSize()) {
            Spacer(Modifier.weight(1f))
            Box(Modifier.fillMaxWidth().height(40.dp).background(Color(0.75f, 0.75f, 0.75f).copy(alpha = 0.5f)))
            Box(Modifier.fillMaxWidth().height(30.dp).background(Color(0.05f, 0.05f, 0.05f)))
        }
        Image(painterResource(R.drawable.subtitle_preview), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
    }
}

/** The two sample lines, each on its own box. */
@Composable
private fun PreviewText(facts: SubtitleFacts, colour: Color, points: Float, bottomGap: Dp) {
    val measurer = rememberTextMeasurer()
    val density = LocalDensity.current
    val lines = listOf(translated("Hörst du das auch?"), translated("Da hinten am See."))
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val maxWidth = constraints.maxWidth
        val sizePx = with(density) { points.dp.toPx() }
        val style = remember(sizePx, density) {
            TextStyle(fontSize = with(density) { points.dp.toSp() }, color = Color.White, textAlign = TextAlign.Center)
        }
        val padH = if (facts.background) sizePx / 4 else 0f
        val padV = if (facts.background) sizePx / 8 else 0f
        val layouts = lines.map { measurer.measure(it, style, constraints = Constraints(maxWidth = max(1, (maxWidth - 2 * padH).toInt()))) }
        // The ink width of a line (the widest of its rows), whatever width the layout itself reports.
        fun TextLayoutResult.inkWidth() = (0 until lineCount).maxOf { getLineRight(it) } - (0 until lineCount).minOf { getLineLeft(it) }
        fun TextLayoutResult.inkLeft() = (0 until lineCount).minOf { getLineLeft(it) }
        val textHeight = layouts.sumOf { (it.size.height + 2 * padV).toDouble() }.toFloat()
        val gapPx = with(density) { bottomGap.toPx() }
        val boxHeight = with(density) { (textHeight + gapPx).toDp() }
        Box(Modifier.fillMaxWidth().height(boxHeight).drawBehind {
            var y = 0f
            layouts.forEach { layout ->
                val boxW = layout.inkWidth() + 2 * padH
                val boxH = layout.size.height + 2 * padV
                val x = (size.width - boxW) / 2
                if (facts.background) {
                    drawRect(Color.Black.copy(alpha = 160f / 255), Offset(x, y), androidx.compose.ui.geometry.Size(boxW, boxH))
                }
                drawLine(layout, Offset(x + padH - layout.inkLeft(), y + padV), facts, colour, sizePx)
                y += boxH
            }
        })
    }
}

/** One line: shadow, outline and the glyphs themselves. */
private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawLine(
    layout: TextLayoutResult, at: Offset, facts: SubtitleFacts, colour: Color, points: Float,
) {
    val radius = points * facts.thickness / 100f
    val outlined = facts.outline != "off"
    fun ring(origin: Offset, alpha: Float) {
        drawIntoCanvas { canvas ->
            val bounds = Rect(origin.x - radius - 2, origin.y - radius - 2,
                origin.x + layout.size.width + radius + 2, origin.y + layout.size.height + radius + 2)
            canvas.saveLayer(bounds, Paint().apply { this.alpha = alpha })
            for (step in 0 until 12) {
                val angle = step / 12.0 * 2 * PI
                drawText(layout, Color.Black, Offset(origin.x + radius * cos(angle).toFloat(), origin.y + radius * sin(angle).toFloat()))
            }
            canvas.restore()
        }
    }
    if (facts.shadow) {
        val origin = Offset(at.x, at.y + points * 0.04f)
        drawIntoCanvas { canvas ->
            val bounds = Rect(origin.x - radius - 2, origin.y - radius - 2,
                origin.x + layout.size.width + radius + 2, origin.y + layout.size.height + radius + 2)
            canvas.saveLayer(bounds, Paint().apply { alpha = 160f / 255 })
            if (outlined) ring(origin, 1f) else drawText(layout, Color.Black, origin)
            canvas.restore()
        }
    }
    if (outlined) ring(at, 230f / 255)
    drawText(layout, colour, at)
}
