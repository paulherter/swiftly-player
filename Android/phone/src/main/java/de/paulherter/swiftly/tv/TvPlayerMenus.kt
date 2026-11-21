package de.paulherter.swiftly.tv

import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.RowScope
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import de.paulherter.swiftly.LevelSpec
import de.paulherter.swiftly.MenuKind
import de.paulherter.swiftly.PlayerMenuSession
import de.paulherter.swiftly.PlayerMenuSpecs
import de.paulherter.swiftly.RowSpec
import de.paulherter.swiftly.StepSpec
import de.paulherter.swiftly.rustcore.PlayerMenuAction
import de.paulherter.swiftly.rustcore.PlayerMenuLevel
import de.paulherter.swiftly.rustcore.PlayerMenuTrackTab
import de.paulherter.swiftly.rustcore.PlayerMenus
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Strength
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.smoothRoundedShape
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.delay

// **The player's menus on Android TV** (design "Player-Menues", TV frames 20 to 27, and the bar's TV frame).
//
// The core builds every level (`playerMenusFor` through `PlayerMenuSpecs`, shared with the phone and with
// `PlayerVm::menus`): which rows exist, their order, their words, what a press does. This file only draws a core
// page for ten feet and the remote: 36 dp rows, white focus with dark text, one box that takes the place of the
// bar's capsule (top right; the season box hangs under the "Staffel N" pill, top left). Back goes one level back,
// then closes. "Zeit anpassen": left / right steps the value without a focused button.

private object TvMenuMetric {
    val width = 300.dp
    val wide = 320.dp
    val row = 36.dp
    val pad = 12.dp
    val boxPad = 6.dp
    /** The box is a card (`radius.card`); its rows sit concentric inside it: card corner minus the 6 dp pad = `radius.small`. */
    val radius = TvTheme.cornerArea
    val rowRadius = TvTheme.cornerSmall
    val label = 15.sp
    val detail = 12.sp
    val chip = 32.dp
}

internal val menuOpenSpring = spring<Float>(dampingRatio = Spring.DampingRatioNoBouncy, stiffness = 440f)
internal val menuCloseCurve = CubicBezierEasing(0.23f, 1f, 0.32f, 1f)

/** One press of the box, turned into what the core expects (`PlayerMenuSpecs` keys every action). */
private sealed class TvAct {
    object Back : TvAct()
    data class Segment(val id: String) : TvAct()
    data class Select(val id: String) : TvAct()
    object Search : TvAct()
    data class Capsule(val group: String, val value: String) : TvAct()
    data class Step(val sign: Int) : TvAct()
    object Reset : TvAct()
}

private data class TvSlot(val level: PlayerMenuLevel, val depth: Int, val tab: PlayerMenuTrackTab)

/** Back on the remote: one level back inside a box, then closed. Returns false when no menu is open. */
internal fun PlayerMenuSession.backOrClose(): Boolean {
    if (kind == null || !isOpen) return false
    if (stack.size > 1) back() else close()
    return true
}

/**
 * The menu layer over the player: nothing mounted while closed. Opens with a short spring (scale .96, fade), closes in
 * 0.14 s; switching a level is one cross-fade inside the same box. Focus stays inside until Back.
 */
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
internal fun TvPlayerMenuLayer(session: PlayerMenuSession, menus: () -> PlayerMenus, press: (PlayerMenuAction) -> Unit, modifier: Modifier = Modifier) {
    val shown = remember { Animatable(0f) }
    LaunchedEffect(session.isOpen) {
        if (session.isOpen) shown.animateTo(1f, menuOpenSpring)
        else { shown.animateTo(0f, tween(140, easing = menuCloseCurve)); session.finished() }
    }
    val kind = session.kind ?: return
    val level = session.stack.lastOrNull() ?: return
    val hangs = kind == MenuKind.Seasons
    val wide = level is PlayerMenuLevel.Tracks
    Box(modifier.fillMaxSize().zIndex(8f)) {
        // The season box hangs under the Folgen box's first row, its right edge in line with the Folgen box's (tvOS `TVFolgenBox`).
        Box(Modifier.align(Alignment.TopEnd)
                .padding(top = if (hangs) TvTheme.edgeTop - 6.dp + TvFolgenMetric.boxPad + TvFolgenMetric.row + 4.dp else TvTheme.edgeTop - 6.dp,
                         end = TvTheme.edgePage)
                .graphicsLayer {
                    val s = 0.96f + 0.04f * shown.value
                    scaleX = s; scaleY = s
                    alpha = shown.value.coerceIn(0f, 1f)
                    transformOrigin = TransformOrigin(1f, 0f)
                }
                .width(if (wide) TvMenuMetric.wide else TvMenuMetric.width)
                .clip(smoothRoundedShape(TvMenuMetric.radius)).background(Theme.raised)
                .border(BorderStroke(1.dp, TvTheme.edge), smoothRoundedShape(TvMenuMetric.radius))
                // Focus stays in the box until Back closes it.
                .focusProperties { exit = { FocusRequester.Cancel } }
                .focusGroup()) {
            val maxH = LocalConfiguration.current.screenHeightDp.dp * 0.78f
            Crossfade(TvSlot(level, session.stack.size, session.tab), animationSpec = tween(180), label = "tvMenuLevel") { slot ->
                val built = PlayerMenuSpecs(menus(), slot.tab, session.handoffBusy, canReport = false, canLock = false).build(slot.level, slot.depth == 1)
                TvLevelView(built.spec, Modifier.padding(TvMenuMetric.boxPad), maxH) { act ->
                    fun doPress(id: String) { built.actions[id]?.let { a -> if (a is PlayerMenuAction.Open) session.push(a.level) else press(a) } }
                    when (act) {
                        is TvAct.Back -> session.back()
                        is TvAct.Segment -> session.tab = if (act.id == "audio") PlayerMenuTrackTab.AUDIO else PlayerMenuTrackTab.SUBTITLES
                        is TvAct.Select -> doPress(act.id)
                        TvAct.Search -> doPress("search")
                        is TvAct.Capsule -> doPress("${act.group}:${act.value}")
                        is TvAct.Step -> doPress(if (act.sign < 0) "earlier" else "later")
                        TvAct.Reset -> doPress("reset")
                    }
                }
            }
        }
    }
}

/** The first thing the remote lands on: the step of "Zeit anpassen", the chosen row of a list, else the first row. */
private fun initialFocus(spec: LevelSpec): String? {
    if (spec.step != null) return "step"
    spec.rows.forEach { if (it is RowSpec.Check && it.selected) return it.id }
    (spec.rows + spec.fixedRows).forEach { r ->
        when (r) {
            is RowSpec.Value -> return r.id
            is RowSpec.Check -> return r.id
            is RowSpec.Toggle -> return r.id
            is RowSpec.Action -> return r.id
            is RowSpec.Device -> if (r.enabled) return r.id
            is RowSpec.Capsules -> return "${r.id}:${r.selected ?: r.items.firstOrNull()?.id.orEmpty()}"
            else -> {}
        }
    }
    spec.segmentSelected?.let { return "seg:$it" }
    return spec.footer.firstOrNull()?.id
}

@Composable
private fun TvLevelView(spec: LevelSpec, modifier: Modifier, maxHeight: Dp, act: (TvAct) -> Unit) {
    val first = remember(spec) { FocusRequester() }
    val initial = remember(spec) { initialFocus(spec) }
    fun Modifier.landing(id: String) = if (id == initial) this.focusRequester(first) else this
    LaunchedEffect(spec) {
        delay(50)
        repeat(8) { if (runCatching { first.requestFocus() }.isSuccess) return@LaunchedEffect; delay(TvTheme.focusDeadline) }
    }
    Column(modifier.fillMaxWidth().heightIn(max = maxHeight)) {
        spec.backTitle?.let { t ->
            TvMenuItem(Modifier.landing("back"), label = t, perform = { act(TvAct.Back) }) { lit ->
                Symbol(Glyph.AngleDown, 12.dp, Modifier.rotate(90f), color = if (lit) Theme.reason else Theme.fontQuiet, strength = Strength.Semibold)
                MenuText(t, if (lit) Theme.reason else Theme.fontQuiet, Modifier.weight(1f))
            }
        }
        if (spec.segments.isNotEmpty()) {
            Row(Modifier.fillMaxWidth().padding(vertical = 3.dp), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                spec.segments.forEach { s ->
                    MenuChip(s.label, s.id == spec.segmentSelected, Modifier.weight(1f).landing("seg:${s.id}")) { act(TvAct.Segment(s.id)) }
                }
                if (spec.search) TvMenuItem(Modifier.width(TvMenuMetric.chip), height = TvMenuMetric.chip, label = translated("Untertitel suchen …"),
                        radius = 16.dp, perform = { act(TvAct.Search) }, centre = true) { lit ->
                    Symbol(Glyph.TextSearch, 16.dp, color = if (lit) Theme.reason else Theme.font)
                }
            }
        }
        // Long lists scroll only here; the rows around stay put.
        Column(Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState())) {
            spec.rows.forEach { TvRowView(it, { id -> Modifier.landing(id) }, act) }
            spec.step?.let { TvStepView(it, Modifier.landing("step"), act) }
        }
        spec.fixedRows.forEach { TvRowView(it, { id -> Modifier.landing(id) }, act) }
        spec.footer.forEach { f ->
            TvMenuItem(Modifier.landing(f.id), label = f.label, perform = { act(TvAct.Select(f.id)) }, centre = true) { lit ->
                MenuText(f.label, if (lit) Theme.reason else if (f.quiet) Theme.fontVeryQuiet else Theme.font)
            }
        }
    }
}

@Composable
private fun MenuText(text: String, color: Color, modifier: Modifier = Modifier, size: androidx.compose.ui.unit.TextUnit = TvMenuMetric.label,
                   semibold: Boolean = true, lines: Int = 1) {
    Text(text, style = Theme.listTitle.copy(fontSize = size, fontWeight = if (semibold) FontWeight.SemiBold else FontWeight.Normal),
        color = color, maxLines = lines, overflow = TextOverflow.Ellipsis, modifier = modifier)
}

/** One focusable row: white with dark text when focused (OK performs), nothing at rest. */
@Composable
private fun TvMenuItem(modifier: Modifier = Modifier, label: String, height: Dp = TvMenuMetric.row, radius: Dp = TvMenuMetric.rowRadius,
                       enabled: Boolean = true, centre: Boolean = false, onKey: ((androidx.compose.ui.input.key.KeyEvent) -> Boolean)? = null,
                       perform: () -> Unit, content: @Composable RowScope.(Boolean) -> Unit) {
    FocusArea(modifier.fillMaxWidth().focusProperties { canFocus = enabled }.semantics { contentDescription = label }
            .then(if (onKey != null) Modifier.onPreviewKeyEvent { onKey(it) } else Modifier),
        magnifier = 1f, perform = perform) { lit ->
        Row(Modifier.fillMaxWidth().heightIn(min = height).clip(smoothRoundedShape(radius))
                .background(if (lit) Color.White else Color.Transparent).padding(horizontal = TvMenuMetric.pad),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = if (centre) Arrangement.Center else Arrangement.spacedBy(8.dp)) { content(lit) }
    }
}

@Composable
private fun MenuChip(label: String, on: Boolean, modifier: Modifier = Modifier, perform: () -> Unit) {
    FocusArea(modifier.semantics { contentDescription = label }, magnifier = 1f, perform = perform) { lit ->
        Box(Modifier.fillMaxWidth().height(TvMenuMetric.chip).clip(CircleShape)
                .background(if (lit) Color.White else if (on) Color.White.copy(alpha = 0.22f) else Theme.area).padding(horizontal = 12.dp),
            contentAlignment = Alignment.Center) {
            MenuText(label, if (lit) Theme.reason else if (on) Theme.font else Theme.fontQuiet, size = 13.sp)
        }
    }
}

@Composable
private fun TvRowView(spec: RowSpec, landing: (String) -> Modifier, act: (TvAct) -> Unit) {
    when (spec) {
        is RowSpec.Value -> TvMenuItem(landing(spec.id), label = spec.label, perform = { act(TvAct.Select(spec.id)) }) { lit ->
            MenuText(spec.label, if (lit) Theme.reason else Theme.font, Modifier.weight(1f))
            spec.value?.let { MenuText(it, if (lit) Theme.reason.copy(alpha = 0.7f) else Theme.fontVeryQuiet, size = 13.sp, semibold = false) }
            Symbol(Glyph.AngleDown, 10.dp, Modifier.rotate(-90f), color = if (lit) Theme.reason else Theme.fontVeryQuiet, strength = Strength.Semibold)
        }
        is RowSpec.Check -> TvMenuItem(landing(spec.id), label = spec.label, perform = { act(TvAct.Select(spec.id)) }) { lit ->
            Box(Modifier.width(16.dp)) { if (spec.selected) Symbol(Glyph.Checkmark, 13.dp, color = if (lit) Theme.reason else Theme.font, strength = Strength.Semibold) }
            MenuText(spec.label, if (lit) Theme.reason else Theme.font, Modifier.weight(1f))
            spec.detail?.let { MenuText(it, if (lit) Theme.reason.copy(alpha = 0.7f) else Theme.fontVeryQuiet, size = TvMenuMetric.detail, semibold = false) }
        }
        is RowSpec.Toggle -> TvMenuItem(landing(spec.id), label = spec.label, perform = { act(TvAct.Select(spec.id)) }) { lit ->
            MenuText(spec.label, if (lit) Theme.reason else Theme.font, Modifier.weight(1f))
            Box(Modifier.size(38.dp, 22.dp).clip(CircleShape).background(if (spec.on) Theme.accent else Color.White.copy(alpha = 0.25f)).padding(3.dp)) {
                Box(Modifier.size(16.dp).align(if (spec.on) Alignment.CenterEnd else Alignment.CenterStart).clip(CircleShape).background(Color.White))
            }
        }
        is RowSpec.Capsules -> Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
            MenuText(spec.caption, Theme.fontVeryQuiet, Modifier.padding(start = TvMenuMetric.pad, bottom = 4.dp), size = TvMenuMetric.detail, semibold = false)
            Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 3.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                spec.items.forEach { i -> MenuChip(i.label, i.id == spec.selected, Modifier.widthIn(min = 52.dp).then(landing("${spec.id}:${i.id}"))) { act(TvAct.Capsule(spec.id, i.id)) } }
            }
        }
        is RowSpec.Device -> TvMenuItem(landing(spec.id), label = spec.name, enabled = spec.enabled, perform = { act(TvAct.Select(spec.id)) }) { lit ->
            Symbol(Glyph.Tv, 16.dp, color = if (lit) Theme.reason else Theme.font)
            Column(Modifier.weight(1f)) {
                MenuText(spec.name, if (lit) Theme.reason else Theme.font)
                if (spec.kind.isNotEmpty()) MenuText(spec.kind, if (lit) Theme.reason.copy(alpha = 0.7f) else Theme.fontVeryQuiet, size = TvMenuMetric.detail, semibold = false)
            }
            if (spec.loading) MenuText("…", if (lit) Theme.reason else Theme.fontQuiet)
        }
        is RowSpec.Person -> Row(Modifier.fillMaxWidth().height(TvMenuMetric.row).padding(horizontal = TvMenuMetric.pad), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Symbol(Glyph.PersonFilled, 13.dp, color = Theme.fontQuiet)
            MenuText(spec.name, Theme.font, Modifier.weight(1f))
            MenuText(spec.status, Theme.fontVeryQuiet, size = TvMenuMetric.detail, semibold = false)
        }
        is RowSpec.Action -> TvMenuItem(landing(spec.id), label = spec.label, perform = { act(TvAct.Select(spec.id)) }) { lit ->
            Symbol(Glyph.SignOut, 13.dp, color = if (lit) Theme.reason else if (spec.destructive) Theme.accent else Theme.font)
            MenuText(spec.label, if (lit) Theme.reason else if (spec.destructive) Theme.accent else Theme.font)
        }
        is RowSpec.Section -> MenuText(spec.text, Theme.fontVeryQuiet, Modifier.padding(horizontal = TvMenuMetric.pad, vertical = 6.dp), size = TvMenuMetric.detail, semibold = false)
        is RowSpec.Hint -> MenuText(spec.text, Theme.fontVeryQuiet, Modifier.padding(horizontal = TvMenuMetric.pad, vertical = 6.dp), size = TvMenuMetric.detail, semibold = false, lines = 4)
        RowSpec.Divider -> Box(Modifier.fillMaxWidth().padding(horizontal = TvMenuMetric.pad, vertical = 3.dp).height(1.dp).background(TvTheme.hairline))
    }
}

/** "Zeit anpassen": left / right steps the value (no button needs focus), the meaning below, a reset row. */
@Composable
private fun TvStepView(s: StepSpec, landing: Modifier, act: (TvAct) -> Unit) {
    Column(Modifier.fillMaxWidth().padding(vertical = 6.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        TvMenuItem(landing, label = s.value, height = 56.dp, centre = true,
            onKey = { e ->
                if (e.type != KeyEventType.KeyDown) false
                else when (e.key) {
                    Key.DirectionLeft -> { act(TvAct.Step(-1)); true }
                    Key.DirectionRight -> { act(TvAct.Step(1)); true }
                    else -> false
                }
            }, perform = {}) { lit ->
            val c = if (lit) Theme.reason else Theme.font
            MenuText("‹  " + s.earlier, if (lit) Theme.reason.copy(alpha = 0.7f) else Theme.fontVeryQuiet, size = TvMenuMetric.detail, semibold = false)
            MenuText(s.value, c, Modifier.padding(horizontal = 14.dp), size = 22.sp)
            MenuText(s.later + "  ›", if (lit) Theme.reason.copy(alpha = 0.7f) else Theme.fontVeryQuiet, size = TvMenuMetric.detail, semibold = false)
        }
        MenuText(s.caption, Theme.fontVeryQuiet, Modifier.padding(horizontal = TvMenuMetric.pad), size = TvMenuMetric.detail, semibold = false, lines = 2)
        if (s.canReset) TvMenuItem(label = s.reset, centre = true, perform = { act(TvAct.Reset) }) { lit ->
            MenuText(s.reset, if (lit) Theme.reason else Theme.accent)
        }
    }
}

// MARK: The bar: ONE capsule (Folgen, Untertitel, Einstellungen); Back closes, so no X and no Übergeben on TV

private val scrimGlass = Color.Black.copy(alpha = 0.18f)
private val glassEdge = Color.White.copy(alpha = 0.10f)

/** One button of the capsule: at rest only the glyph, lit while its menu is open, white when focused. */
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
private fun TvBarHalf(glyph: Glyph, label: String, open: Boolean, focus: FocusRequester, before: FocusRequester?, after: FocusRequester?, perform: () -> Unit) {
    // Explicit left / right order over the capsule's buttons; at either end Left / Right stay put (Cancel), so the row never leaks into
    // the geometric search of Compose.
    FocusArea(Modifier.focusRequester(focus).focusProperties {
            left = before ?: FocusRequester.Cancel
            right = after ?: FocusRequester.Cancel
        }.semantics { contentDescription = label }, magnifier = TvTheme.focusMagnifierSmall, perform = perform) { lit ->
        Box(Modifier.size(56.dp, 40.dp).clip(smoothRoundedShape(20.dp))
                .background(if (lit) Color.White else if (open) Color.White.copy(alpha = 0.16f) else Color.Transparent), contentAlignment = Alignment.Center) {
            Symbol(glyph, 22.dp, color = if (lit) Theme.reason else Theme.font, strength = Strength.Medium)
        }
    }
}

@Composable
internal fun TvBarCapsule(showFolgen: Boolean, folgenOpen: Boolean, session: PlayerMenuSession, focusFolgen: FocusRequester,
                          focusTracks: FocusRequester, focusSettings: FocusRequester, folgen: () -> Unit, modifier: Modifier = Modifier) {
    val open = session.kind.takeIf { session.isOpen }
    // The focus order of the row: Folgen (when shown), Untertitel, Einstellungen.
    val order = if (showFolgen) listOf(focusFolgen, focusTracks, focusSettings) else listOf(focusTracks, focusSettings)
    fun before(r: FocusRequester) = order.getOrNull(order.indexOf(r) - 1)
    fun after(r: FocusRequester) = order.getOrNull(order.indexOf(r) + 1)
    Row(modifier.clip(CircleShape).background(scrimGlass).border(BorderStroke(1.dp, glassEdge), CircleShape).padding(2.dp).focusGroup(),
        horizontalArrangement = Arrangement.spacedBy(2.dp), verticalAlignment = Alignment.CenterVertically) {
        if (showFolgen) TvBarHalf(Glyph.Pile, translated("Folgen"), folgenOpen, focusFolgen, before(focusFolgen), after(focusFolgen), folgen)
        TvBarHalf(Glyph.Subtitle, translated("Audio & Untertitel"), open == MenuKind.Tracks, focusTracks, before(focusTracks), after(focusTracks)) { session.open(MenuKind.Tracks) }
        TvBarHalf(Glyph.SliderControl, translated("Einstellungen"), open == MenuKind.Settings, focusSettings, before(focusSettings), after(focusSettings)) { session.open(MenuKind.Settings) }
    }
}
