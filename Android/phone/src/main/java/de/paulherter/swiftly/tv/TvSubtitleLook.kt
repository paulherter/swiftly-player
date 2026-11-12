package de.paulherter.swiftly.tv

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.KernRules
import de.paulherter.swiftly.SubtitleFacts
import de.paulherter.swiftly.SubtitlePreview
import de.paulherter.swiftly.SubtitleSteps
import de.paulherter.swiftly.SwiftlyApplication
import de.paulherter.swiftly.entryValue
import de.paulherter.swiftly.fileStyleLine
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Strength
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import de.paulherter.swiftly.subtitleColourName
import de.paulherter.swiftly.subtitleOutlineName
import de.paulherter.swiftly.subtitlePositionName
import de.paulherter.swiftly.subtitleSizeName
import kotlinx.coroutines.delay

/**
 * **Settings > Languages > "Aussehen der Untertitel" (Android TV).** An own full page, mirrors
 * `TVSubtitleLookView`: the picture on the left and standing, the rows on the right and scrolling.
 *
 * There is no pointer and four targets in a row are too small at three meters, so Size, Colour,
 * Outline and Position are rows that unfold their steps below them. **Focus on a step shows it in the
 * picture**, OK takes it and folds the row, Back folds it (the picture jumps back to the saved value)
 * and Back again closes the page. Only one row is open at a time.
 */
@Composable
fun TvSubtitleLook(app: SwiftlyApplication, back: () -> Unit) {
    val e = app.settings
    val look = e.subtitleLook
    val facts = SubtitleFacts.of(look, true)
    /** The row that is open ("size", "colour", "outline", "position"), at most one. */
    var opened by remember { mutableStateOf<String?>(null) }
    /** The look under the focused step; the picture shows it instead of the saved one. */
    var trial by remember { mutableStateOf<String?>(null) }
    var trialOwner by remember { mutableStateOf<String?>(null) }
    var undo by remember { mutableStateOf<String?>(null) }
    val headers = remember { listOf("size", "colour", "outline", "position").associateWith { FocusRequester() } }
    val resetRow = remember { FocusRequester() }
    val undoRow = remember { FocusRequester() }
    val sizeRow = headers.getValue("size")
    val firstRow = firstFocus()
    var undoFocused by remember { mutableStateOf(false) }
    var focusReset by remember { mutableStateOf(false) }

    // Every choice builds on the look as it is NOW, not on the `look` of the composition that made the callback
    // (a second choice before the page recomposed lost the first; see `SubtitleLookEditor`).
    val editor = remember(app) { de.paulherter.swiftly.SubtitleLookEditor({ app.settings.subtitleLook }, { app.settings.subtitleLook = it; app.qualityReport() },
        KernRules::subtitleLookNormalise, KernRules::subtitleLookChange) }
    fun store(next: String) = editor.store(next)
    fun set(field: String, value: String) = editor.set(field, value)
    fun reset() {
        if (facts.standard) return
        // The file switch is part of the look and goes back with it (spec).
        undo = editor.reset(KernRules.subtitleLookStandard())
    }
    fun takeBack() {
        val before = undo ?: return
        store(before)
        undo = null
        focusReset = true
    }

    BackHandler {
        val group = opened
        if (group != null) {
            trial = null; trialOwner = null
            runCatching { headers.getValue(group).requestFocus() }
            opened = null
        } else back()
    }
    // The locked reset row cannot keep focus; the way back takes it.
    LaunchedEffect(undo != null) {
        if (undo != null) { delay(1); runCatching { undoRow.requestFocus() } }
    }
    LaunchedEffect(undo) {
        if (undo == null) return@LaunchedEffect
        delay(TvSpec.subtitleUndoMs.toLong())
        if (undoFocused) runCatching { sizeRow.requestFocus() }
        undo = null
    }
    LaunchedEffect(focusReset) {
        if (focusReset) { delay(1); runCatching { resetRow.requestFocus() }; focusReset = false }
    }

    // The swatches do not depend on the look: computed once, not through the core on every recomposition
    // (each focus move or trial step recomposes this page).
    val colourSwatches = remember {
        SubtitleSteps.colours.associateWith { word -> SubtitleFacts.of(KernRules.subtitleLookChange("", "colour", word), true).color }
    }
    val colourSteps = SubtitleSteps.colours.map { word -> Step(word, subtitleColourName(word), colourSwatches[word], word == facts.colour) }
    val shown = trial ?: look
    // Same focus as the Profile page the user came from: a solid white row (the 12 % grey of the plain rows was hard to see at
    // three meters on the dark page).
    androidx.compose.runtime.CompositionLocalProvider(LocalSettingsLook provides true) {
    Box(Modifier.fillMaxSize().background(Theme.reason)) {
        Row(Modifier.fillMaxSize().padding(horizontal = TvTheme.edgePage, vertical = TvTheme.edgeTop),
            horizontalArrangement = Arrangement.spacedBy(TvSpec.subtitleColumnGap), verticalAlignment = Alignment.Top) {
            // MARK: Left
            Column(Modifier.width(TvSpec.subtitleLeftWidth), verticalArrangement = Arrangement.spacedBy(TvSpec.subtitleLeftSpacing)) {
                Text(translated("Untertitel"), style = TvTheme.body.copy(fontSize = TvSpec.subtitleTitleFont.value.sp, fontWeight = FontWeight.Bold),
                     color = Theme.font)
                SubtitlePreview(SubtitleFacts.of(shown, true), TvSpec.subtitlePreviewHeight, cornerRadius = TvSpec.cornerArea,
                                bottomGap = TvSpec.subtitleBottomGap)
                Column(verticalArrangement = Arrangement.spacedBy(TvSpec.subtitleNotesSpacing)) {
                    if (app.play.value != null) Note(translated("Gilt ab dem nächsten Video."), Theme.fontVeryQuiet)
                    Note(translated("Gilt für Untertitel aus Text. Die von Blu-rays sind Bilder und bleiben, wie sie sind."), Theme.fontVeryQuiet)
                }
            }
            // MARK: Right
            Column(Modifier.width(TvSpec.subtitleRightWidth).fillMaxHeight().verticalScroll(rememberScrollState())
                       .padding(bottom = TvSpec.subtitleBottomPad).focusGroup()) {
                GroupTitle(translated("Aussehen"))
                UnfoldingRow("size", translated("Größe"), subtitleSizeName(facts.size), opened, { opened = it }, headers.getValue("size"),
                             SubtitleSteps.sizes.map { Step(it, subtitleSizeName(it), null, it == facts.size) },
                             Modifier.focusRequester(firstRow), look, "size", set = ::set,
                             trialSet = { owner, value -> trialOwner = owner; trial = value },
                             trialLost = { owner -> if (trialOwner == owner) { trialOwner = null; trial = null } })
                Hairline()
                UnfoldingRow("colour", translated("Farbe"), subtitleColourName(facts.colour), opened, { opened = it }, headers.getValue("colour"),
                             colourSteps, Modifier, look, "colour", set = ::set,
                             trialSet = { owner, value -> trialOwner = owner; trial = value },
                             trialLost = { owner -> if (trialOwner == owner) { trialOwner = null; trial = null } })
                Hairline()
                UnfoldingRow("outline", translated("Rand"), subtitleOutlineName(facts.outline), opened, { opened = it }, headers.getValue("outline"),
                             SubtitleSteps.outlines.map { Step(it, subtitleOutlineName(it), null, it == facts.outline) },
                             Modifier, look, "outline", set = ::set,
                             trialSet = { owner, value -> trialOwner = owner; trial = value },
                             trialLost = { owner -> if (trialOwner == owner) { trialOwner = null; trial = null } })
                Hairline()
                TvToggleRow(translated("Schatten"), facts.shadow) { set("shadow", (!facts.shadow).toString()) }
                Hairline()
                TvToggleRow(translated("Dunkler Hintergrund"), facts.background) { set("background", (!facts.background).toString()) }
                Hairline()
                UnfoldingRow("position", translated("Position"), subtitlePositionName(facts.position), opened, { opened = it }, headers.getValue("position"),
                             SubtitleSteps.positions.map { Step(it, subtitlePositionName(it), null, it == facts.position) },
                             Modifier, look, "position", set = ::set,
                             trialSet = { owner, value -> trialOwner = owner; trial = value },
                             trialLost = { owner -> if (trialOwner == owner) { trialOwner = null; trial = null } })

                Box(Modifier.padding(top = TvSpec.subtitleGroupTop)) { GroupTitle(translated("Aufwendige Untertitel")) }
                val adjustable = app.rk.subtitleFileStyleAdjustable()
                TvToggleRow(translated("Gestaltung aus der Datei übernehmen"), facts.keepFileStyle || !adjustable, enabled = adjustable) {
                    set("keepFileStyle", (!facts.keepFileStyle).toString())
                }
                Text(if (adjustable) facts.fileStyleLine() else translated("Bei Plex-Servern kommt die Gestaltung immer aus der Datei."),
                     style = TvTheme.body.copy(fontSize = TvSpec.subtitleNoteFont.value.sp), color = Theme.fontQuiet,
                     modifier = Modifier.padding(horizontal = TvSpec.rowInset).padding(top = TvSpec.subtitleLineTop))

                Box(Modifier.padding(top = TvSpec.subtitleResetTop)) { Hairline() }
                TvAction(translated("Zurücksetzen"), enabled = !facts.standard, modifier = Modifier.focusRequester(resetRow)) { reset() }
                if (undo != null) {
                    TvAction(translated("Zurückgesetzt · Rückgängig"),
                             modifier = Modifier.focusRequester(undoRow).onFocusChanged { undoFocused = it.isFocused }) { takeBack() }
                }
            }
        }
    }
    }
}

private class Step(val word: String, val name: String, val swatch: androidx.compose.ui.graphics.Color?, val current: Boolean)

@Composable
private fun Note(text: String, color: androidx.compose.ui.graphics.Color) {
    Text(text, style = TvTheme.body.copy(fontSize = TvSpec.subtitleNoteFont.value.sp), color = color)
}

@Composable
private fun GroupTitle(text: String) {
    Text(text, style = TvTheme.body.copy(fontWeight = FontWeight.SemiBold),
         color = Theme.fontVeryQuiet, modifier = Modifier.padding(start = TvSpec.rowInset, bottom = TvSpec.groupsTitleBottom))
}

@Composable
private fun Hairline() {
    Box(Modifier.fillMaxWidth().padding(horizontal = TvSpec.rowInset).height(TvSpec.hairline).background(Theme.line))
}

/**
 * A row that unfolds its steps below it (same motion as `TvValueRow`). **Focus on a step reports the look
 * it would give** (`trialSet`), so the picture shows it; OK takes the step, folds the row and hands focus
 * back to it.
 */
@Composable
private fun UnfoldingRow(key: String, title: String, value: String, opened: String?, setOpened: (String?) -> Unit,
                         header: FocusRequester, steps: List<Step>, modifier: Modifier,
                         look: String, field: String, set: (String, String) -> Unit,
                         trialSet: (String, String) -> Unit, trialLost: (String) -> Unit) {
    val open = opened == key
    Column(Modifier.fillMaxWidth()) {
        TvAction(title, value = value, expanded = open, modifier = modifier.focusRequester(header)) { setOpened(if (open) null else key) }
        AnimatedVisibility(open,
            enter = expandVertically(tvTween(TvSpec.valueExpandMs, TvSpec.easeInOutCurve)) + fadeIn(tvTween(TvSpec.valueExpandMs, TvSpec.easeInOutCurve)),
            exit = shrinkVertically(tvTween(TvSpec.valueExpandMs, TvSpec.easeInOutCurve)) + fadeOut(tvTween(TvSpec.valueExpandMs, TvSpec.easeInOutCurve))) {
            Column(Modifier.fillMaxWidth().padding(start = TvSpec.rowInset).focusGroup()) {
                steps.forEach { step ->
                    val owner = "$key/${step.word}"
                    FocusArea(Modifier.fillMaxWidth().semantics { this.selected = step.current }, magnifier = 1f,
                        focusChanged = { focus ->
                            if (focus) trialSet(owner, KernRules.subtitleLookChange(look, field, step.word)) else trialLost(owner)
                        },
                        perform = {
                            set(field, step.word); trialLost(owner); setOpened(null); runCatching { header.requestFocus() }
                        }) { focus ->
                        Row(Modifier.fillMaxWidth().height(TvTheme.rowsHeight).clip(RoundedCornerShape(TvTheme.corner))
                                .background(if (focus) androidx.compose.ui.graphics.Color.White else androidx.compose.ui.graphics.Color.Transparent).padding(horizontal = TvSpec.rowInset),
                            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(TvSpec.rowSpacing)) {
                            // The check mark is in the type colour, not the accent (spec).
                            Box(Modifier.width(TvSpec.choiceCheckWidth), contentAlignment = Alignment.Center) {
                                if (step.current) Symbol(Glyph.Checkmark, TvSpec.valueIcon, color = if (focus) Theme.reason else Theme.font, strength = Strength.Semibold)
                            }
                            step.swatch?.let { Box(Modifier.size(TvSpec.subtitleSwatch).clip(CircleShape).background(it)) }
                            Text(step.name, style = TvTheme.body.copy(fontWeight = if (focus) FontWeight.SemiBold else FontWeight.Medium),
                                 color = if (focus) Theme.reason else Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                        }
                    }
                }
            }
        }
    }
}
