package de.paulherter.swiftly

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.zIndex
import de.paulherter.swiftly.rustcore.PlayerMenuAction
import de.paulherter.swiftly.rustcore.PlayerMenuHandoffState
import de.paulherter.swiftly.rustcore.PlayerMenuLevel
import de.paulherter.swiftly.rustcore.PlayerMenuPanelTab
import de.paulherter.swiftly.rustcore.PlayerMenuTrackTab
import de.paulherter.swiftly.rustcore.PlayerMenuWords
import de.paulherter.swiftly.rustcore.PlayerMenus
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Strength
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.launch

// **The player's menus on the phone** (design "Am Knopf"): a small solid box hanging from the button that opened it.
// The core builds every level (`playerMenusFor`, the same `build_menus` as `PlayerVm::menus`): which rows exist, their
// order, their words, what a press does. This file owns no list of options; it turns a core page into a `LevelSpec`
// (`PlayerMenuSpecs`) and draws it. Mirrors `Sources/Shared/PlayerMenuSession.swift`, `MenuBox.swift`, `MenuRows.swift`.

/** `Folgen` is the episodes (or chapters) panel of the TV player: no core level, the host draws its content. */
internal enum class MenuKind { Tracks, Settings, Seasons, Handoff, Folgen }

/** Which menu is mounted and whether it is open. Closing keeps it mounted for the 140 ms of the close motion. */
internal class PlayerMenuSession {
    var kind by mutableStateOf<MenuKind?>(null); private set
    var isOpen by mutableStateOf(false); private set
    var stack by mutableStateOf<List<PlayerMenuLevel>>(emptyList()); private set
    var tab by mutableStateOf(PlayerMenuTrackTab.SUBTITLES)
    var handoffBusy by mutableStateOf<String?>(null)
    /** The chosen audio and subtitle id the menu shows as selected (the engine has no observable state for it). */
    var audioSelected by mutableIntStateOf(-1)
    var subtitleSelected by mutableIntStateOf(-1)
    /** Each opening button's frame in the window. */
    val anchors = mutableStateMapOf<MenuKind, Rect>()
    /** The Folgen button's frame and what it does: not a menu of this session, but a tap on it while a box is open must reach it
     *  (one tap swaps the box for the episode panel) instead of being taken by the closing backdrop. */
    var folgenBounds by mutableStateOf<Rect?>(null)
    var folgenTap: () -> Unit = {}

    fun root(k: MenuKind): PlayerMenuLevel? = when (k) {
        MenuKind.Tracks -> PlayerMenuLevel.Tracks(PlayerMenuTrackTab.SUBTITLES)
        MenuKind.Settings -> PlayerMenuLevel.Options
        MenuKind.Seasons -> PlayerMenuLevel.Seasons
        MenuKind.Handoff -> PlayerMenuLevel.Handoff
        MenuKind.Folgen -> null
    }

    /** Another button while a box is open moves the box to it (one tap, no close first); the same button closes. */
    fun open(k: MenuKind) {
        if (isOpen && kind == k) { close(); return }
        if (kind != k) { stack = listOfNotNull(root(k)); tab = PlayerMenuTrackTab.SUBTITLES }
        kind = k
        isOpen = true
    }
    fun close() { isOpen = false }
    fun finished() { if (!isOpen) { kind = null; stack = emptyList() } }
    fun push(level: PlayerMenuLevel) {
        if (level is PlayerMenuLevel.Tracks) tab = level.tab
        if (level is PlayerMenuLevel.TimeAdjust) tab = level.tab
        stack = stack + level
    }
    fun back() { if (stack.size > 1) stack = stack.dropLast(1) }
}

// MARK: Plain data of a level (what the box draws)

internal data class MenuCapsule(val id: String, val label: String)

internal sealed class RowSpec {
    data class Value(val id: String, val label: String, val value: String?) : RowSpec()
    data class Check(val id: String, val label: String, val detail: String?, val selected: Boolean) : RowSpec()
    data class Toggle(val id: String, val label: String, val on: Boolean) : RowSpec()
    data class Capsules(val id: String, val caption: String, val items: List<MenuCapsule>, val selected: String?, val compact: Boolean = false) : RowSpec()
    data class Device(val id: String, val name: String, val kind: String, val loading: Boolean, val enabled: Boolean) : RowSpec()
    data class Person(val name: String, val status: String) : RowSpec()
    data class Action(val id: String, val label: String, val destructive: Boolean) : RowSpec()
    data class Section(val text: String) : RowSpec()
    data class Hint(val text: String) : RowSpec()
    object Divider : RowSpec()
}

internal data class StepSpec(val value: String, val caption: String, val earlier: String, val later: String, val reset: String, val canReset: Boolean)
internal data class FooterSpec(val id: String, val label: String, val quiet: Boolean)

internal data class LevelSpec(
    val backTitle: String? = null,
    val segments: List<MenuCapsule> = emptyList(),
    val segmentSelected: String? = null,
    val search: Boolean = false,
    val rows: List<RowSpec> = emptyList(),
    val step: StepSpec? = null,
    val fixedRows: List<RowSpec> = emptyList(),
    val footer: List<FooterSpec> = emptyList(),
)

internal class Built(val spec: LevelSpec, val actions: Map<String, PlayerMenuAction>)

internal fun PlayerMenuWords.text(): String = when (this) {
    is PlayerMenuWords.Key -> translated(key)
    is PlayerMenuWords.Count -> translated(key, count.toInt())
    is PlayerMenuWords.Pair -> translated(first) + " · " + translated(second)
    is PlayerMenuWords.Literal -> text
}

/** Turns the core's pages into level data. Decides nothing: order, words and selection come from the core. */
internal class PlayerMenuSpecs(private val menus: PlayerMenus, private val tab: PlayerMenuTrackTab, private val handoffBusy: String?,
                               private val canReport: Boolean, private val canLock: Boolean) {
    fun build(level: PlayerMenuLevel, isRoot: Boolean): Built {
        val actions = LinkedHashMap<String, PlayerMenuAction>()
        var n = 0
        fun key(a: PlayerMenuAction): String { n++; return "a$n".also { actions[it] = a } }
        fun back(title: String) = if (isRoot) null else title
        fun check(c: de.paulherter.swiftly.rustcore.PlayerMenuChoice) =
            RowSpec.Check(key(c.action), c.label.text(), c.detail?.text(), c.selected)
        fun capsules(choices: List<de.paulherter.swiftly.rustcore.PlayerMenuChoice>, group: String): List<MenuCapsule> {
            choices.forEachIndexed { j, c -> actions["$group:$j"] = c.action }
            return choices.mapIndexed { j, c ->
                val w = c.label
                MenuCapsule("$j", if (w is PlayerMenuWords.Count) w.count.toString() else w.text())
            }
        }
        fun tabId(t: PlayerMenuTrackTab) = if (t == PlayerMenuTrackTab.SUBTITLES) "subtitles" else "audio"

        val spec: LevelSpec = when (level) {
            PlayerMenuLevel.Options -> {
                val rows = menus.options.rows.flatMap { r ->
                    val a = r.action
                    val line = a is PlayerMenuAction.Open && (a.level == PlayerMenuLevel.Sleep || a.level == PlayerMenuLevel.Quality)
                    val made = RowSpec.Value(key(a), r.title.text(), r.value.text())
                    if (line) listOf(made, RowSpec.Divider) else listOf(made)
                }
                val footer = menus.options.footer.mapNotNull { r ->
                    val a = r.action
                    when {
                        a is PlayerMenuAction.ReportProblem && !canReport -> null
                        a is PlayerMenuAction.LockScreen && !canLock -> null
                        // The phone's footer says "Sperren" (design); the core's longer "Bildschirm sperren" is the big screens' row text.
                        else -> FooterSpec(key(a), if (a is PlayerMenuAction.LockScreen) translated("Sperren") else r.title.text(),
                                           quiet = a is PlayerMenuAction.ReportProblem)
                    }
                }
                LevelSpec(rows = rows, footer = footer)
            }
            PlayerMenuLevel.Speed -> LevelSpec(backTitle = back(menus.speed.title.text()), rows = menus.speed.choices.map(::check))
            PlayerMenuLevel.Picture -> LevelSpec(backTitle = back(menus.picture.title.text()), rows = menus.picture.choices.map(::check))
            PlayerMenuLevel.Sleep -> {
                val p = menus.sleep
                LevelSpec(backTitle = back(p.title.text()), rows = p.choices.map(::check) + RowSpec.Capsules(
                    "minutes", p.minutesTitle.text(), capsules(p.minutes, "minutes"), p.minutes.indexOfFirst { it.selected }.takeIf { it >= 0 }?.toString()))
            }
            PlayerMenuLevel.Quality -> {
                val p = menus.quality
                LevelSpec(backTitle = back(p.title.text()),
                    rows = if (p.offered) listOf(check(p.original), RowSpec.Capsules("bitrate", p.bitrateTitle.text(), capsules(p.bitrates, "bitrate"),
                        p.bitrates.indexOfFirst { it.selected }.takeIf { it >= 0 }?.toString())) else emptyList(),
                    fixedRows = listOf(RowSpec.Toggle(key(p.badgeAction), p.badgeTitle.text(), p.badgeOn)))
            }
            PlayerMenuLevel.Together -> {
                val p = menus.together
                if (p == null) LevelSpec() else LevelSpec(backTitle = back(p.groupName),
                    rows = p.members.map { RowSpec.Person(it.name, it.status.text()) },
                    fixedRows = listOf(RowSpec.Action(key(p.leave.action), p.leave.title.text(), destructive = true)))
            }
            is PlayerMenuLevel.Tracks -> {
                val p = menus.tracks
                val subtitles = tab == PlayerMenuTrackTab.SUBTITLES
                val page = if (subtitles) p.subtitles else p.audio
                val rows = page.rows.map { RowSpec.Check(key(it.action), if (it.labelIsKey) PlayerMenuWords.Key(it.label).text() else it.label, null, it.selected) }
                val segs = p.tabs.map { MenuCapsule(tabId(it), (if (it == PlayerMenuTrackTab.SUBTITLES) p.subtitles else p.audio).title.text()) }
                val search = if (subtitles) page.search else null
                if (search != null) actions["search"] = search
                val time = if (subtitles) p.subtitleTime else p.audioTime
                val fixed = mutableListOf<RowSpec>(RowSpec.Value(key(time.action), time.title.text(), time.value.text()))
                if (subtitles) fixed += RowSpec.Value(key(p.look.action), p.look.title.text(), p.look.value.text())
                LevelSpec(segments = segs, segmentSelected = tabId(tab), search = search != null, rows = rows, fixedRows = fixed)
            }
            PlayerMenuLevel.SubtitleLook -> LevelSpec(backTitle = back(menus.look.title.text()),
                rows = menus.look.groups.mapIndexed { i, g ->
                    g.choices.forEachIndexed { j, c -> actions["g$i:$j"] = c.action }
                    RowSpec.Capsules("g$i", g.title.text(), g.choices.mapIndexed { j, c -> MenuCapsule("$j", c.label.text()) },
                        g.choices.indexOfFirst { it.selected }.takeIf { it >= 0 }?.toString(), compact = true)
                })
            is PlayerMenuLevel.TimeAdjust -> {
                val p = menus.time
                val t = p.tabs.firstOrNull { it.tab == tab } ?: p.tabs.firstOrNull()
                var step: StepSpec? = null
                if (t != null) {
                    actions["earlier"] = t.earlier.action
                    actions["later"] = t.later.action
                    t.reset?.let { actions["reset"] = it.action }
                    step = StepSpec(t.value, t.meaning.text(), t.earlier.title.text(), t.later.title.text(), t.reset?.title?.text().orEmpty(), t.reset != null)
                }
                LevelSpec(backTitle = back(p.title.text()), segments = p.tabs.map { MenuCapsule(tabId(it.tab), it.title.text()) },
                    segmentSelected = tabId(tab), step = step)
            }
            PlayerMenuLevel.Seasons, is PlayerMenuLevel.Episodes -> LevelSpec(rows = menus.episodes.seasons.map(::check))
            PlayerMenuLevel.Handoff -> {
                val p = menus.handoff
                val rows = mutableListOf<RowSpec>(RowSpec.Section(p.title.text()))
                when (p.state) {
                    PlayerMenuHandoffState.LIST -> (p.rows + listOfNotNull(p.airplay)).forEach { r ->
                        val a = r.action
                        val busy = a is PlayerMenuAction.Handoff && a.sessionId == handoffBusy
                        rows += RowSpec.Device(key(a), r.name, r.detail.orEmpty(), busy, handoffBusy == null || busy)
                    }
                    else -> p.text?.let { rows += RowSpec.Hint(it.text()) }
                }
                rows += RowSpec.Divider
                rows += RowSpec.Hint(p.note.text())
                LevelSpec(rows = rows)
            }
        }
        return Built(spec, actions)
    }
}

// MARK: Metrics (`MenuMetric`)

private val menuWidth = 300.dp
private val menuMargin = 12.dp
private val menuGap = 6.dp
private val menuPad = 12.dp
private val menuBoxPad = 6.dp
private val menuRadius = 16.dp
private val menuRowRadius = 10.dp
private val menuOpenSpring = spring<Dp>(dampingRatio = Spring.DampingRatioNoBouncy, stiffness = 440f)
private val menuCloseCurve = CubicBezierEasing(0.23f, 1f, 0.32f, 1f)
private val menuLevelCurve = CubicBezierEasing(0.77f, 0f, 0.175f, 1f)

private data class Slot(val kind: MenuKind?, val level: PlayerMenuLevel?, val depth: Int)

/**
 * The menu layer over the player: nothing mounted while closed. The box hangs under the anchor, opens with a 0.30 s
 * spring (scale .92, 6 up, fade), closes into the button in 0.14 s; another button moves the box and cross-fades the
 * content; a level slides 12 inside the box.
 */
@Composable
internal fun PlayerMenuLayer(session: PlayerMenuSession, menus: () -> PlayerMenus, canReport: Boolean, canLock: Boolean,
                             press: (PlayerMenuAction) -> Unit, modifier: Modifier = Modifier) {
    val shown = remember { Animatable(0f) }
    LaunchedEffect(session.isOpen) {
        if (session.isOpen) shown.animateTo(1f, spring(dampingRatio = Spring.DampingRatioNoBouncy, stiffness = 440f))
        else { shown.animateTo(0f, tween(140, easing = menuCloseCurve)); session.finished() }
    }
    val kind = session.kind ?: return
    val level = session.stack.lastOrNull() ?: return
    val anchor = session.anchors[kind] ?: return
    val density = LocalDensity.current
    BoxWithConstraints(modifier.fillMaxSize().zIndex(8f)) {
        val screenW = maxWidth
        val screenH = maxHeight
        // A tap beside the box closes; a tap on another menu button of the bar moves the box there instead.
        Box(Modifier.fillMaxSize().pointerInput(kind) {
            detectTapGestures { p ->
                val hit = session.anchors.entries.firstOrNull { it.key != MenuKind.Seasons && it.value.contains(p) }
                if (kind != MenuKind.Seasons && session.folgenBounds?.contains(p) == true) session.folgenTap()
                else if (hit != null && kind != MenuKind.Seasons) session.open(hit.key) else session.close()
            }
        })
        val width = minOf(menuWidth, screenW - menuMargin * 2)
        val anchorBottom = with(density) { anchor.bottom.toDp() }
        val anchorCentre = with(density) { anchor.center.x.toDp() }
        val left by animateDpAsState((anchorCentre - width / 2).coerceIn(menuMargin, maxOf(menuMargin, screenW - menuMargin - width)), menuOpenSpring, label = "menuLeft")
        val top by animateDpAsState(anchorBottom + menuGap, menuOpenSpring, label = "menuTop")
        // One rule: the free height below the button; at most 72 % of the screen, a short screen (landscape phone) may use all of it.
        val below = screenH - top - menuMargin
        val maxHeight = (if (screenH < 480.dp) below else minOf(below, screenH * 0.72f)).coerceAtLeast(120.dp)
        val rowHeight = if (maxHeight < 250.dp) 36.dp else 44.dp
        val originX = ((anchorCentre - left) / width).coerceIn(0f, 1f)
        val isRoot = session.stack.size == 1
        Box(Modifier.offset(left, top).width(width)
                .graphicsLayer {
                    val s = 0.92f + 0.08f * shown.value
                    scaleX = s; scaleY = s
                    translationY = -6.dp.toPx() * (1f - shown.value)
                    alpha = shown.value.coerceIn(0f, 1f)
                    transformOrigin = TransformOrigin(originX, 0f)
                }
                .clip(RoundedCornerShape(menuRadius)).background(Theme.raised)
                .border(BorderStroke(1.dp, Color.White.copy(alpha = 0.08f)), RoundedCornerShape(menuRadius))
                .pointerInput(Unit) { detectTapGestures { } }) {
            AnimatedContent(targetState = Slot(kind, level, session.stack.size), modifier = Modifier.padding(menuBoxPad),
                transitionSpec = {
                    val push = targetState.depth > initialState.depth
                    val pop = targetState.depth < initialState.depth
                    val slide = with(density) { 12.dp.roundToPx() }
                    when {
                        push -> (slideInHorizontally(tween(220, easing = menuLevelCurve)) { slide } + fadeIn(tween(220))) togetherWith
                            (slideOutHorizontally(tween(220, easing = menuLevelCurve)) { -slide } + fadeOut(tween(120)))
                        pop -> (slideInHorizontally(tween(220, easing = menuLevelCurve)) { -slide } + fadeIn(tween(220))) togetherWith
                            (slideOutHorizontally(tween(220, easing = menuLevelCurve)) { slide } + fadeOut(tween(120)))
                        else -> fadeIn(tween(200)) togetherWith fadeOut(tween(120))
                    }.using(SizeTransform(clip = true) { _, _ -> spring(dampingRatio = Spring.DampingRatioNoBouncy, stiffness = 440f) })
                }, label = "menuLevel") { slot ->
                val lv = slot.level ?: return@AnimatedContent
                val built = PlayerMenuSpecs(menus(), session.tab, session.handoffBusy, canReport, canLock).build(lv, slot.depth == 1)
                LevelView(built.spec, rowHeight, maxHeight - menuBoxPad * 2) { act ->
                    fun doPress(id: String) { built.actions[id]?.let { a -> if (a is PlayerMenuAction.Open) session.push(a.level) else press(a) } }
                    when (act) {
                        is Act.Back -> session.back()
                        is Act.Segment -> session.tab = if (act.id == "audio") PlayerMenuTrackTab.AUDIO else PlayerMenuTrackTab.SUBTITLES
                        is Act.Select -> doPress(act.id)
                        Act.Search -> doPress("search")
                        is Act.Capsule -> doPress("${act.group}:${act.value}")
                        is Act.Step -> doPress(if (act.sign < 0) "earlier" else "later")
                        Act.Reset -> doPress("reset")
                    }
                }
            }
        }
    }
}

private sealed class Act {
    object Back : Act()
    data class Segment(val id: String) : Act()
    data class Select(val id: String) : Act()
    object Search : Act()
    data class Capsule(val group: String, val value: String) : Act()
    data class Step(val sign: Int) : Act()
    object Reset : Act()
}

// MARK: Drawing a level

@Composable
private fun LevelView(spec: LevelSpec, rowHeight: Dp, maxHeight: Dp, act: (Act) -> Unit) {
    Column(Modifier.fillMaxWidth().heightIn(max = maxHeight)) {
        spec.backTitle?.let { t ->
            Row(Modifier.fillMaxWidth().height(rowHeight).clip(RoundedCornerShape(menuRowRadius)).pressRow { act(Act.Back) }.padding(horizontal = menuPad)
                    .semantics { contentDescription = t },
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Symbol(Glyph.AngleDown, 14.dp, Modifier.rotate(90f), color = Theme.fontQuiet, strength = Strength.Semibold)
                Text16(t, Theme.fontQuiet, semibold = true, modifier = Modifier.weight(1f))
            }
        }
        if (spec.segments.isNotEmpty()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 6.dp, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically) {
                spec.segments.forEach { s -> CapsuleChip(s.label, s.id == spec.segmentSelected, Modifier.weight(1f)) { act(Act.Segment(s.id)) } }
                if (spec.search) Box(Modifier.size(32.dp).clip(CircleShape).background(Theme.area).pressRow { act(Act.Search) }
                        .semantics { contentDescription = translated("Untertitel suchen …") }, contentAlignment = Alignment.Center) {
                    Symbol(Glyph.TextSearch, 16.dp, color = Theme.font)
                }
            }
        }
        // Long lists scroll only here; the rows around stay put.
        Column(Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState())) {
            spec.rows.forEach { RowView(it, rowHeight, act) }
            spec.step?.let { StepView(it, act) }
        }
        spec.fixedRows.forEach { RowView(it, rowHeight, act) }
        if (spec.footer.isNotEmpty()) Row(Modifier.fillMaxWidth().padding(top = 4.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            spec.footer.forEach { f ->
                Box(Modifier.weight(1f).height(rowHeight).clip(RoundedCornerShape(menuRowRadius)).background(Theme.area).pressRow { act(Act.Select(f.id)) },
                    contentAlignment = Alignment.Center) { Text16(f.label, if (f.quiet) Theme.fontVeryQuiet else Theme.font, semibold = true, size = 15) }
            }
        }
    }
}

@Composable
internal fun Text16(text: String, color: Color, modifier: Modifier = Modifier, semibold: Boolean = false, size: Int = 16, lines: Int = 1) {
    androidx.compose.material3.Text(text, style = Theme.listTitle.copy(fontSize = size.sp, fontWeight = if (semibold) FontWeight.SemiBold else FontWeight.Normal),
        color = color, maxLines = lines, overflow = TextOverflow.Ellipsis, modifier = modifier)
}

@Composable
private fun CapsuleChip(label: String, on: Boolean, modifier: Modifier = Modifier, perform: () -> Unit) {
    Box(modifier.height(32.dp).clip(CircleShape).background(if (on) Theme.font else Theme.area).pressRow(perform).padding(horizontal = 12.dp)
            .semantics { contentDescription = label }, contentAlignment = Alignment.Center) {
        Text16(label, if (on) Theme.reason else Theme.fontQuiet, semibold = true, size = 15)
    }
}

@Composable
private fun RowView(spec: RowSpec, h: Dp, act: (Act) -> Unit) {
    when (spec) {
        is RowSpec.Value -> Row(Modifier.fillMaxWidth().height(h).clip(RoundedCornerShape(menuRowRadius)).pressRow { act(Act.Select(spec.id)) }.padding(horizontal = menuPad),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text16(spec.label, Theme.font, Modifier.weight(1f))
            spec.value?.let { Text16(it, Theme.fontVeryQuiet, size = 15) }
            Symbol(Glyph.AngleDown, 12.dp, Modifier.rotate(-90f), color = Theme.fontVeryQuiet, strength = Strength.Semibold)
        }
        is RowSpec.Check -> Row(Modifier.fillMaxWidth().heightIn(min = h).clip(RoundedCornerShape(menuRowRadius)).pressRow { act(Act.Select(spec.id)) }
                .padding(horizontal = menuPad, vertical = 6.dp).semantics { contentDescription = spec.label },
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.width(18.dp)) { if (spec.selected) Symbol(Glyph.Checkmark, 14.dp, color = Theme.font, strength = Strength.Semibold) }
            Text16(spec.label, Theme.font, Modifier.weight(1f), lines = 2)
            spec.detail?.let { Text16(it, Theme.fontVeryQuiet, size = 13) }
        }
        is RowSpec.Toggle -> Row(Modifier.fillMaxWidth().height(h).padding(horizontal = menuPad), verticalAlignment = Alignment.CenterVertically) {
            Text16(spec.label, Theme.font, Modifier.weight(1f))
            Switch(spec.on, { act(Act.Select(spec.id)) }, colors = SwitchDefaults.colors(checkedTrackColor = Theme.accent))
        }
        is RowSpec.Capsules -> Column(Modifier.fillMaxWidth().padding(horizontal = if (spec.compact) 3.dp else menuPad, vertical = if (spec.compact) 3.dp else 6.dp)) {
            Text16(spec.caption, Theme.fontVeryQuiet, size = 13, modifier = Modifier.padding(bottom = 5.dp, start = if (spec.compact) menuPad - 3.dp else 0.dp))
            Row(Modifier.horizontalScroll(rememberScrollState()).padding(start = if (spec.compact) menuPad - 3.dp else 0.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                spec.items.forEach { i -> CapsuleChip(i.label, i.id == spec.selected) { act(Act.Capsule(spec.id, i.id)) } }
            }
        }
        is RowSpec.Device -> Row(Modifier.fillMaxWidth().heightIn(min = h).clip(RoundedCornerShape(menuRowRadius))
                .pressRow { if (spec.enabled) act(Act.Select(spec.id)) }.padding(horizontal = menuPad, vertical = 6.dp).graphicsLayer { alpha = if (spec.enabled) 1f else 0.4f },
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Symbol(Glyph.Tv, 17.dp, color = Theme.font)
            Column(Modifier.weight(1f)) {
                Text16(spec.name, Theme.font)
                if (spec.kind.isNotEmpty()) Text16(spec.kind, Theme.fontVeryQuiet, size = 13)
            }
            if (spec.loading) Text16("…", Theme.fontQuiet)
        }
        is RowSpec.Person -> Row(Modifier.fillMaxWidth().height(h).padding(horizontal = menuPad), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Symbol(Glyph.PersonFilled, 14.dp, color = Theme.fontQuiet)
            Text16(spec.name, Theme.font, Modifier.weight(1f))
            Text16(spec.status, Theme.fontVeryQuiet, size = 13)
        }
        is RowSpec.Action -> Row(Modifier.fillMaxWidth().height(h).clip(RoundedCornerShape(menuRowRadius)).pressRow { act(Act.Select(spec.id)) }.padding(horizontal = menuPad),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Symbol(Glyph.SignOut, 14.dp, color = if (spec.destructive) Theme.accent else Theme.font)
            Text16(spec.label, if (spec.destructive) Theme.accent else Theme.font)
        }
        is RowSpec.Section -> Text16(spec.text, Theme.fontVeryQuiet, size = 13, modifier = Modifier.padding(horizontal = menuPad, vertical = 6.dp))
        is RowSpec.Hint -> Text16(spec.text, Theme.fontVeryQuiet, size = 13, lines = 4, modifier = Modifier.padding(horizontal = menuPad, vertical = 6.dp))
        RowSpec.Divider -> Box(Modifier.fillMaxWidth().padding(horizontal = menuPad, vertical = 3.dp).height(1.dp).background(Color.White.copy(alpha = 0.08f)))
    }
}

/** "Zeit anpassen": the value in the middle, earlier and later at its sides, the meaning below, a reset. */
@Composable
private fun StepView(s: StepSpec, act: (Act) -> Unit) {
    Column(Modifier.fillMaxWidth().padding(horizontal = menuPad, vertical = 8.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            CapsuleChip(s.earlier, false, Modifier.weight(1f)) { act(Act.Step(-1)) }
            Text16(s.value, Theme.font, semibold = true, size = 18)
            CapsuleChip(s.later, false, Modifier.weight(1f)) { act(Act.Step(1)) }
        }
        Text16(s.caption, Theme.fontVeryQuiet, size = 13)
        if (s.canReset) Text16(s.reset, Theme.accent, Modifier.clip(RoundedCornerShape(menuRowRadius)).pressRow { act(Act.Reset) }.padding(8.dp), semibold = true, size = 15)
    }
}

// MARK: The bar: ONE glass capsule + the X

/** Quiet glass: black 18 % (iOS `Theme.scrimGlass`) with a white 10 % hairline (`glassEdge`); Android has no backdrop blur to put under it. */
private val scrimGlass = Color.Black.copy(alpha = 0.18f)
private val glassEdge = Color.White.copy(alpha = 0.10f)
private fun Modifier.barGlass(shape: androidx.compose.ui.graphics.Shape) =
    this.clip(shape).background(scrimGlass).border(BorderStroke(1.dp, glassEdge), shape)

@Composable
private fun BarGlyph(glyph: Glyph, label: String, width: Dp, open: Boolean, active: Boolean, modifier: Modifier = Modifier, perform: () -> Unit) {
    Box(modifier.size(width, 40.dp).clip(RoundedCornerShape(20.dp)).background(if (open) Color.White.copy(alpha = 0.16f) else Color.Transparent)
            .then(if (active) Modifier.pressRow(perform) else Modifier).semantics { contentDescription = label },
        contentAlignment = Alignment.Center) {
        Symbol(glyph, 19.dp, color = Color.White, strength = Strength.Medium)
    }
}

/** **One capsule** (Folgen, Untertitel, Einstellungen, Übergeben) and the X alone as a circle (`BarRail` on the iPhone). */
@Composable
internal fun BarCapsule(showFolgen: Boolean, folgenOpen: Boolean, showHandoff: Boolean, session: PlayerMenuSession, active: Boolean,
                        folgen: () -> Unit, close: () -> Unit, modifier: Modifier = Modifier) {
    fun Modifier.anchor(k: MenuKind) = onGloballyPositioned { session.anchors[k] = it.boundsInRoot() }
    val open = session.kind.takeIf { session.isOpen }
    SideEffect { session.folgenTap = folgen }
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        Row(Modifier.barGlass(CircleShape)) {
            if (showFolgen) BarGlyph(Glyph.Pile, translated("Folgen"), 44.dp, folgenOpen, active,
                Modifier.onGloballyPositioned { session.folgenBounds = it.boundsInRoot() }, perform = folgen)
            BarGlyph(Glyph.Subtitle, translated("Audio & Untertitel"), 44.dp, open == MenuKind.Tracks, active, Modifier.anchor(MenuKind.Tracks)) { session.open(MenuKind.Tracks) }
            BarGlyph(Glyph.SliderControl, translated("Einstellungen"), 44.dp, open == MenuKind.Settings, active, Modifier.anchor(MenuKind.Settings)) { session.open(MenuKind.Settings) }
            if (showHandoff) BarGlyph(Glyph.Tv, translated("Übergeben an …"), 44.dp, open == MenuKind.Handoff, active, Modifier.anchor(MenuKind.Handoff)) { session.open(MenuKind.Handoff) }
        }
        BarGlyph(Glyph.Cross, translated("Player schließen"), 40.dp, false, active, Modifier.barGlass(CircleShape), close)
    }
}

/** The "Staffel N ⌄" button of the Folgen panel; its frame is where the season box hangs from. */
@Composable
internal fun SeasonButton(label: String, session: PlayerMenuSession, perform: () -> Unit) {
    Row(Modifier.height(32.dp).clip(RoundedCornerShape(16.dp)).pressRow(perform).padding(horizontal = 10.dp)
            .onGloballyPositioned { session.anchors[MenuKind.Seasons] = it.boundsInRoot() },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Text16(label, Theme.font, semibold = true, size = 15)
        Symbol(Glyph.AngleDown, 14.dp, color = Theme.font, strength = Strength.Semibold)
    }
}

// MARK: Core inputs and presses (the host side)

private fun lookInfo(app: SwiftlyApplication) =
    de.paulherter.swiftly.rustcore.subtitleLookRead(app.settings.subtitleLook.takeIf { it.isNotEmpty() }?.toByteArray())

/** Every menu of the running player, built by the core from what the player shows now and what only this host knows. */
internal fun playerMenus(app: SwiftlyApplication, mediaWork: PlayItem, session: PlayerMenuSession, targets: List<PlayOutputChoice>,
                         seasons: List<Season>, shownSeason: String?): PlayerMenus {
    val e = app.settings
    val qualityShow = e.convertAllowed && mediaWork.plan?.url?.startsWith("file") != true && !mediaWork.inGroup
    fun rows(audio: Boolean, chosen: Int) = mediaWork.trackList(audio).map { (id, name) ->
        de.paulherter.swiftly.rustcore.PlayerTrackRow(id.toLong(), name, id == chosen, false, false, false)
    }
    val group = if (mediaWork.inGroup) app.gemeinsam.value.group else null
    return de.paulherter.swiftly.rustcore.playerMenusFor(
        de.paulherter.swiftly.rustcore.PlayerMenusState(
            tempo = mediaWork.tempo,
            sleep = if (mediaWork.sleepTime == 0) de.paulherter.swiftly.rustcore.PlayerMenuSleep.Off
                    else de.paulherter.swiftly.rustcore.PlayerMenuSleep.Minutes(mediaWork.sleepTime.toUInt()),
            fill = mediaWork.fillFrame,
            quality = if (qualityShow) de.paulherter.swiftly.rustcore.PlayerQuality(e.alwaysDirectPlay, e.bitratesLimit.toLong()) else null,
            series = mediaWork.plan?.seriesIdentifier != null,
            hasChapters = mediaWork.chapterCount > 0,
            tracks = de.paulherter.swiftly.rustcore.PlayerTracks(rows(true, session.audioSelected), rows(false, session.subtitleSelected),
                session.subtitleSelected == -1, mediaWork.audioDelay.toLong(), mediaWork.subtitleDelay.toLong())),
        de.paulherter.swiftly.rustcore.PlayerMenusInputs(
            decimalSeparator = java.text.DecimalFormatSymbols.getInstance().decimalSeparator.toString(),
            techBadge = e.techBadge,
            group = group?.let { g -> de.paulherter.swiftly.rustcore.PlayerMenuGroup(g.name, g.participant.map {
                de.paulherter.swiftly.rustcore.PlayerMenuGroupMember(it, false, de.paulherter.swiftly.rustcore.PlayerMenuMemberStatus.WATCHING) }) },
            look = lookInfo(app),
            seasons = seasons.map { de.paulherter.swiftly.rustcore.SeasonRow(it.id, it.name, it.number?.toLong()) },
            shownSeason = shownSeason,
            handoff = de.paulherter.swiftly.rustcore.PlayerMenuHandoffInput.Devices(targets.map {
                de.paulherter.swiftly.rustcore.PlayerMenuHandoffDevice(it.deviceID, it.name, de.paulherter.swiftly.rustcore.TakeoverDevice.TV, null) }),
            airplay = false))
}

/** A press the box did not handle itself: the player's own intents go to the Media3 player, the rest to the app. */
internal fun playerMenuPress(app: SwiftlyApplication, mediaWork: PlayItem, session: PlayerMenuSession, run: kotlinx.coroutines.CoroutineScope,
                             close: () -> Unit, targets: List<PlayOutputChoice>, season: (String) -> Unit, search: () -> Unit,
                             action: PlayerMenuAction) {
    val e = app.settings
    when (action) {
        is PlayerMenuAction.Player -> when (val i = action.intent) {
            is de.paulherter.swiftly.rustcore.PlayerIntent.SelectAudio -> { session.audioSelected = i.index.toInt(); mediaWork.audioFromHand(i.index.toInt()) }
            is de.paulherter.swiftly.rustcore.PlayerIntent.SelectSubtitle -> { session.subtitleSelected = i.index.toInt(); mediaWork.subtitleFromHand(i.index.toInt()) }
            is de.paulherter.swiftly.rustcore.PlayerIntent.AudioDelay -> mediaWork.delaySet(true, i.milliseconds.toInt())
            is de.paulherter.swiftly.rustcore.PlayerIntent.SubtitleOffsetStep -> mediaWork.delayPush(false, if (i.stepMs < 0) -1 else 1)
            de.paulherter.swiftly.rustcore.PlayerIntent.SubtitleOffsetReset -> mediaWork.delaySet(false, 0)
            is de.paulherter.swiftly.rustcore.PlayerIntent.Tempo -> mediaWork.tempoSet(i.tempo)
            is de.paulherter.swiftly.rustcore.PlayerIntent.Fill -> mediaWork.imageFillingSet(i.on)
            is de.paulherter.swiftly.rustcore.PlayerIntent.Sleep -> mediaWork.sleepTimeSet(i.minutes?.toInt() ?: 0)
            de.paulherter.swiftly.rustcore.PlayerIntent.SleepEndOfEpisode ->
                mediaWork.sleepTimeSet(kotlin.math.ceil((mediaWork.duration - mediaWork.position) / 60.0).toInt().coerceAtLeast(1))
            is de.paulherter.swiftly.rustcore.PlayerIntent.Quality -> {
                val limit = i.limit
                val before = e.alwaysDirectPlay to e.bitratesLimit
                if (limit == null) e.alwaysDirectPlay = true else { e.alwaysDirectPlay = false; e.bitratesLimit = limit.toInt() }
                if (before != (e.alwaysDirectPlay to e.bitratesLimit)) { app.qualityReport(); session.close(); run.launch { mediaWork.qualitySwitch() } }
            }
            else -> {}
        }
        is PlayerMenuAction.TechBadge -> e.techBadge = action.on
        is PlayerMenuAction.Look -> e.subtitleLook = String(de.paulherter.swiftly.rustcore.subtitleLookWrite(action.look))
        is PlayerMenuAction.SearchSubtitles -> { session.close(); search() }
        is PlayerMenuAction.SelectSeason -> { season(action.id); session.close() }
        is PlayerMenuAction.LeaveGroup -> mediaWork.finish(close)
        is PlayerMenuAction.Handoff -> targets.firstOrNull { it.deviceID == action.sessionId }?.let { t ->
            session.handoffBusy = t.deviceID
            run.launch { mediaWork.handOver(t, close); session.handoffBusy = null }
        }
        else -> {}
    }
}
