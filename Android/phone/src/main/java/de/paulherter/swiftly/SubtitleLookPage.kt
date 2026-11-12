package de.paulherter.swiftly

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Motion
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.delay

/**
 * **Playback -> "Aussehen der Untertitel" (phone).** The look of text subtitles on one page with a
 * picture that shows it; mirrors `SubtitleLookView` on iPhone. Layout and numbers:
 * `Notizen/Mehrserver/UNTERTITEL-ENTWURF.md`.
 *
 * Narrow: the picture stands still at the top and the rows scroll below it. Wide (a tablet): two
 * columns, picture left, rows right. Every tap is written to `Settings.subtitleLook` at once; the
 * player takes it when it builds its library (`PlayerPage`).
 */
@Composable
fun SubtitleLookPage(app: SwiftlyApplication, back: () -> Unit) {
    val e = app.settings
    val look = e.subtitleLook
    val facts = SubtitleFacts.of(look, app.isTv)
    val jerk = rememberJerk()
    // The look before "Reset", for the strip's "Undo" (4 seconds).
    var undo by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(undo) { if (undo != null) { delay(4000); undo = null } }

    // Every tap builds on the look as it is NOW (`e.subtitleLook` is read when the tap happens), never on the
    // `look` of the composition that created the callback: a second tap before the page recomposed lost the first.
    val editor = remember(app) { SubtitleLookEditor({ app.settings.subtitleLook }, { app.settings.subtitleLook = it; app.qualityReport() },
        KernRules::subtitleLookNormalise, KernRules::subtitleLookChange) }
    fun set(field: String, value: String) = editor.set(field, value)
    fun reset() {
        if (facts.standard) return
        jerk(Jerk.Lightweight)
        // The file switch is part of the look and goes back with it (spec section 3).
        undo = editor.reset(KernRules.subtitleLookStandard())
    }
    fun store(next: String) = editor.store(next)

    // The picture height the player's text is sized against: the short side of the screen.
    val metrics = LocalContext.current.resources.displayMetrics
    val previewHeight = (minOf(metrics.widthPixels, metrics.heightPixels) / metrics.density).dp
    val playerOpen = app.play.value != null

    Box(Modifier.fillMaxSize().background(Theme.reason)) {
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val wide = maxWidth >= 700.dp
            Column(Modifier.fillMaxSize()) {
                SubpageHeader(translated("Untertitel"), back, bottom = if (wide) 18.dp else 8.dp)
                if (wide) {
                    Row(Modifier.fillMaxSize(), horizontalArrangement = Arrangement.spacedBy(28.dp)) {
                        Column(Modifier.widthIn(min = 420.dp, max = 640.dp).padding(start = Theme.edgeSpacing),
                               verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            SubtitlePreview(facts, previewHeight, cornerRadius = Theme.cornerArea)
                            if (playerOpen) Footer(translated("Gilt ab dem nächsten Video."))
                            Footer(translated("Gilt für Untertitel aus Text. Die von Blu-rays sind Bilder und bleiben, wie sie sind."))
                        }
                        Rows(app, facts, playerOpen, wide = true, ::set, ::reset, Modifier.weight(1f))
                    }
                } else {
                    Box(Modifier.padding(horizontal = Theme.edgeSpacing)) {
                        SubtitlePreview(facts, previewHeight, cornerRadius = Theme.cornerArea)
                    }
                    Rows(app, facts, playerOpen, wide = false, ::set, ::reset, Modifier.weight(1f))
                }
            }
        }
        // "Reset" and "Undo" for 4 seconds: it does not ask first, because it can be reversed.
        Box(Modifier.align(Alignment.BottomCenter).navigationBarsPadding()) {
            AnimatedVisibility(undo != null,
                enter = slideInVertically(Motion.change()) { it } + fadeIn(Motion.change()),
                exit = slideOutVertically(Motion.change()) { it } + fadeOut(Motion.change())) {
                Row(Modifier.padding(horizontal = Theme.edgeSpacing).padding(bottom = 12.dp).fillMaxWidth().heightIn(min = 52.dp)
                        .clip(RoundedCornerShape(Theme.cornerCard)).background(Theme.area).padding(horizontal = 16.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Text(translated("Zurückgesetzt"), style = Theme.listTitle.copy(fontSize = 15.sp, fontWeight = FontWeight.SemiBold), color = Theme.font)
                    Box(Modifier.weight(1f))
                    Box(Modifier.heightIn(min = 44.dp).clickable(remember { MutableInteractionSource() }, null) {
                        undo?.let { before -> store(before); undo = null }
                    }, contentAlignment = Alignment.Center) {
                        Text(translated("Rückgängig"), style = Theme.listTitle.copy(fontSize = 15.sp, fontWeight = FontWeight.Normal), color = Theme.fontQuiet)
                    }
                }
            }
        }
    }
}

@Composable
private fun Rows(app: SwiftlyApplication, facts: SubtitleFacts, playerOpen: Boolean, wide: Boolean,
                 set: (String, String) -> Unit, reset: () -> Unit, modifier: Modifier) {
    Box(modifier) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).navigationBarsPadding().padding(bottom = 80.dp)) {
            if (!wide && playerOpen) Box(Modifier.padding(top = 8.dp)) { Footer(translated("Gilt ab dem nächsten Video.")) }
            SettingGroup(translated("Aussehen")) {
                SegmentRow(Glyph.SizeText, translated("Größe"), SubtitleSteps.sizes, facts.size, 48.dp, ::subtitleSizeName,
                           { set("size", it) }) { word, chosen -> GlyphLetter(subtitleGlyphSize(word).sp, chosen, null) }
                SeparatorLine()
                SegmentRow(Glyph.Palette, translated("Farbe"), SubtitleSteps.colours, facts.colour, 48.dp, ::subtitleColourName,
                           { set("colour", it) }) { word, _ -> GlyphLetter(17.sp, true, SubtitleFacts.of(KernRules.subtitleLookChange("", "colour", word), app.isTv).color) }
                SeparatorLine()
                SegmentRow(Glyph.TextOutline, translated("Rand"), SubtitleSteps.outlines, facts.outline, 60.dp, ::subtitleOutlineName,
                           { set("outline", it) }) { word, chosen -> SegmentWord(subtitleOutlineName(word), chosen) }
                SeparatorLine()
                ChoiceRow(Glyph.Shadow, translated("Schatten"), an = facts.shadow) { set("shadow", it.toString()) }
                SeparatorLine()
                ChoiceRow(Glyph.FillBackground, translated("Dunkler Hintergrund"), an = facts.background) { set("background", it.toString()) }
                SeparatorLine()
                SegmentRow(Glyph.AlignBottom, translated("Position"), SubtitleSteps.positions, facts.position, 70.dp, ::subtitlePositionName,
                           { set("position", it) }) { word, chosen -> SegmentWord(subtitlePositionName(word), chosen) }
            }
            if (!wide) Footer(translated("Gilt für Untertitel aus Text. Die von Blu-rays sind Bilder und bleiben, wie sie sind."))
            SettingGroup(translated("Aufwendige Untertitel")) {
                val adjustable = app.rk.subtitleFileStyleAdjustable()
                ChoiceRow(Glyph.Document, translated("Gestaltung aus der Datei übernehmen"),
                          under = if (adjustable) facts.fileStyleLine() else translated("Bei Plex-Servern kommt die Gestaltung immer aus der Datei."),
                          an = facts.keepFileStyle || !adjustable, locked = !adjustable) { set("keepFileStyle", it.toString()) }
            }
            Box(Modifier.padding(top = 26.dp)) {
                CardView {
                    RowsLayout(Glyph.Ruecksetzen, translated("Zurücksetzen"), null,
                               if (facts.standard) Theme.fontVeryQuiet else Theme.font,
                               if (facts.standard) Modifier else Modifier.tapOn(reset)) {}
                }
            }
        }
        // The ground runs out under the picture: no line, no glass (spec section 2).
        Box(Modifier.fillMaxWidth().height(20.dp).background(Brush.verticalGradient(listOf(Theme.reason, Theme.reason.copy(alpha = 0f)))))
    }
}

@Composable
private fun GlyphLetter(size: androidx.compose.ui.unit.TextUnit, chosen: Boolean, color: Color?) {
    Text("A", style = Theme.listTitle.copy(fontSize = size, fontWeight = FontWeight.SemiBold),
         color = color ?: if (chosen) Theme.font else Theme.fontQuiet)
}

@Composable
private fun SegmentWord(text: String, chosen: Boolean) {
    Text(text, style = Theme.listTitle.copy(fontSize = 13.sp, fontWeight = FontWeight.SemiBold),
         color = if (chosen) Theme.font else Theme.fontQuiet, maxLines = 1, overflow = TextOverflow.Clip)
}

/**
 * One row with segments: title left, segments right; when they do not fit side by side (large system
 * type) the segments go below, full width (`segmentRow` on iPhone).
 */
@Composable
private fun SegmentRow(symbol: Glyph, title: String, options: List<String>, value: String, each: Dp,
                       name: (String) -> String, choose: (String) -> Unit,
                       label: @Composable (String, Boolean) -> Unit) {
    val strip = @Composable { GlyphSegments(title, options, value, each, name, choose, label) }
    val measurer = androidx.compose.ui.text.rememberTextMeasurer()
    val density = LocalDensity.current
    val titleStyle = Theme.listTitle.copy(fontSize = Theme.rowTitleSize, fontWeight = FontWeight.Medium)
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        // The title never wraps ("Outlin / e"): when it does not fit beside the segments in one line, the
        // segments go below, full width. Large system type does the same.
        val titleDp = with(density) { measurer.measure(title, titleStyle, maxLines = 1, softWrap = false).size.width.toDp() }
        val stacked = density.fontScale > 1.3f || SegmentRowFit.stacks(titleDp, maxWidth, each * options.size + 2.dp)
        if (stacked) {
            Column {
                RowsLayout(symbol, title, null, Theme.font, Modifier) {}
                Box(Modifier.fillMaxWidth().padding(horizontal = Theme.edgeSpacing).padding(bottom = 10.dp), contentAlignment = Alignment.CenterEnd) { strip() }
            }
        } else {
            RowsLayout(symbol, title, null, Theme.font, Modifier, verticalRight = 6) { strip() }
        }
    }
}

/** Whether a title fits in one line beside the segment strip. `row` is the card's width; inside it `RowsLayout` takes edge, icon, two 14 dp gaps. */
object SegmentRowFit {
    fun stacks(title: Dp, row: Dp, strip: Dp): Boolean {
        val free = row - Theme.edgeSpacing * 2 - Theme.rowIconWidth - 14.dp * 2 - strip
        return title > free
    }
}

/**
 * **Segments whose labels are views** (the "A" in its size or colour), mirrors `GlyphSegments`: one
 * surface moved by an offset, 0.25 s without overshoot. The chosen one takes surface and full type,
 * not more weight or size. Each segment says what it is to TalkBack ("Größe, Groß"), because the "A"s
 * carry no text of their own.
 */
@Composable
private fun GlyphSegments(group: String, options: List<String>, value: String, each: Dp,
                          name: (String) -> String, choose: (String) -> Unit,
                          label: @Composable (String, Boolean) -> Unit) {
    val jerk = rememberJerk()
    val index = options.indexOf(value).coerceAtLeast(0)
    val total = each * options.size + 2.dp
    val pillWidth = (total - 4.dp - 2.dp * (options.size - 1)) / options.size
    val pillX by animateDpAsState(2.dp + (pillWidth + 2.dp) * index, Motion.select(), label = "segmentFlaeche")
    Box(Modifier.size(total, 44.dp), contentAlignment = Alignment.Center) {
        // On the card the track is one step lighter than the card (`Theme.raised`).
        Box(Modifier.size(total, 32.dp).clip(RoundedCornerShape(Theme.cornerSmall)).background(Theme.raised)) {
            Box(Modifier.offset(x = pillX, y = 2.dp).size(pillWidth, 28.dp).clip(RoundedCornerShape(6.dp)).background(Color(0.29f, 0.29f, 0.29f)))
        }
        Row(Modifier.size(total, 44.dp).padding(horizontal = 2.dp), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            options.forEach { option ->
                val chosen = option == value
                Box(Modifier.weight(1f).fillMaxSize()
                        .semantics(mergeDescendants = true) {
                            contentDescription = "$group, ${name(option)}"
                            role = Role.RadioButton
                            selected = chosen
                        }
                        .clickable(remember { MutableInteractionSource() }, null) { if (!chosen) { jerk(Jerk.Lightweight); choose(option) } },
                    contentAlignment = Alignment.Center) { label(option, chosen) }
            }
        }
    }
}

/**
 * The writes of the look page. Reads the current look at call time, so a tap always builds on the latest look
 * (tests: `SubtitleLookEditorTest`).
 */
class SubtitleLookEditor(
    private val read: () -> String,
    private val write: (String) -> Unit,
    private val normalise: (String) -> String,
    private val change: (String, String, String) -> String,
) {
    fun store(next: String) = write(normalise(next))

    fun set(field: String, value: String) {
        val now = read()
        val next = change(now, field, value)
        if (next != normalise(now)) store(next)
    }

    /** Stores [standard]; returns the look before, for "Undo". */
    fun reset(standard: String): String {
        val before = normalise(read())
        store(standard)
        return before
    }
}
