package de.paulherter.swiftly

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.type
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import coil3.compose.AsyncImage
import de.paulherter.swiftly.rustcore.HomeLibraryChoice
import de.paulherter.swiftly.rustcore.SeerrArrival
import de.paulherter.swiftly.rustcore.SeerrHomeInfo
import de.paulherter.swiftly.rustcore.SeerrHomeState
import de.paulherter.swiftly.rustcore.HomeForm
import de.paulherter.swiftly.rustcore.homeRowOrder
import de.paulherter.swiftly.rustcore.homeRowOrderCarried
import de.paulherter.swiftly.rustcore.homeRowOrderMoved
import de.paulherter.swiftly.rustcore.seerrHomeMemoryKey
import de.paulherter.swiftly.rustcore.seerrHomePending
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Strength
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.smoothRoundedShape
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import kotlin.math.abs
import kotlin.math.roundToInt

// ---------------------------------------------------------------------------------------------------------------------
// The Home order (`startReihenfolge`, per server). The core heals it and lists the two Seerr sections only while Seerr is
// connected (`homeRowOrder`); the page lays its rows out by that list, so a Seerr section stands where the user put it.
// ---------------------------------------------------------------------------------------------------------------------

object StartOrderStore { val version = mutableIntStateOf(0) }

private fun orderKey(app: SwiftlyApplication) = "startReihenfolge|" + app.settings.serverKey()

private fun startOrderStored(app: SwiftlyApplication): List<String> {
    StartOrderStore.version.intValue
    val raw = app.store.rememberValue(orderKey(app)) ?: return emptyList()
    val j = runCatching { JSONArray(raw) }.getOrNull() ?: return emptyList()
    return (0 until j.length()).mapNotNull { j.optString(it).takeIf { s -> s.isNotEmpty() } }
}

/** The effective combined order: fixed rows, chosen libraries and, with Seerr connected, `seerr:arrival` / `seerr:requests`. */
fun startOrderEffective(app: SwiftlyApplication): List<String> {
    val e = app.settings
    // The one-time carry-over of the old fixed-row order (the core decides; a non-empty answer is stored once).
    val carried = homeRowOrderCarried(startOrderStored(app), e.startRails)
    if (carried.isNotEmpty()) app.store.remember(orderKey(app), JSONArray(carried).toString())
    return homeRowOrder(startOrderStored(app), e.newAccessDisconnected,
        e.startLibraries.map { HomeLibraryChoice(it.id, it.name, it.collection) }, app.seerrConnected.value,
        // The core decides which Seerr sections a device form shows: handhelds both, a TV none.
        if (app.isTv) HomeForm.TV else HomeForm.HANDHELD)
}

/** Moves one row (`step` places up or down) and stores the whole order. */
fun startOrderShift(app: SwiftlyApplication, id: String, step: Int) {
    val now = startOrderEffective(app)
    val from = now.indexOf(id)
    if (from < 0) return
    val to = (from + step).coerceIn(0, now.lastIndex)
    if (to == from) return
    app.store.remember(orderKey(app), JSONArray(homeRowOrderMoved(now, from.toUInt(), to.toUInt())).toString())
    StartOrderStore.version.intValue++
}

const val SEERR_ARRIVAL_ROW = "seerr:arrival"
const val SEERR_REQUESTS_ROW = "seerr:requests"

/** One row of the Home page in the user's order. */
sealed interface HomeRowItem {
    data class RailRow(val index: Int, val rail: Rail) : HomeRowItem
    data class SeerrRow(val part: SeerrHomePart) : HomeRowItem
}

/**
 * The rows the page draws, in the core's order. Rails the server answered without a row id (genre rows) come last, as
 * before. A Seerr section is a row only when its switch is on and it has something to show (or holds its room).
 */
fun homeLayout(app: SwiftlyApplication, rails: List<Rail>, seerr: SeerrHomeFlow): List<HomeRowItem> {
    val byId = rails.filter { it.id.isNotEmpty() }.associateBy { it.id }
    val out = ArrayList<HomeRowItem>()
    val used = HashSet<String>()
    val block = seerr.block()
    for (id in startOrderEffective(app)) {
        when (id) {
            SEERR_ARRIVAL_ROW -> if (seerrArrivalOn(app) && block?.let { arrivalHas(it) } == true) out.add(HomeRowItem.SeerrRow(SeerrHomePart.Arrival))
            SEERR_REQUESTS_ROW -> if (seerrRequestsOn(app) && block?.let { it.rail.isNotEmpty() } == true) out.add(HomeRowItem.SeerrRow(SeerrHomePart.Requests))
            else -> byId[id]?.let { if (used.add(id)) out.add(HomeRowItem.RailRow(0, it)) }
        }
    }
    rails.filter { it.id.isEmpty() || it.id !in used }.forEach { out.add(HomeRowItem.RailRow(0, it)) }
    var n = 0
    return out.map { if (it is HomeRowItem.RailRow) it.copy(index = n++) else it }
}

private fun arrivalHas(h: SeerrHomeInfo) = h.arrivals.isNotEmpty()

// ---------------------------------------------------------------------------------------------------------------------
// The Seerr state of the Home page: the core's answer, the shape reserved before it, the stored X and open/closed state.
// ---------------------------------------------------------------------------------------------------------------------

class SeerrHomeFlow(private val app: SwiftlyApplication) {
    var info by mutableStateOf<SeerrHomeInfo?>(null)
        private set
    private var settled by mutableStateOf(false)

    private fun memoryKey() = "seerrHome-" + seerrHomeMemoryKey(app.settings.serverKey().ifEmpty { null })
    private fun remembered() = app.store.rememberValue(memoryKey()).orEmpty()

    /** What the page draws now: the answer, or before it the blank reserve of the last start's shape (same size as the real cards). */
    fun block(): SeerrHomeInfo? {
        info?.let { return it }
        if (settled || !app.seerrConnected.value) return null
        return seerrHomePending(remembered())
    }

    /** The first start of a profile waits for Seerr up to the core's budget, so the rows below do not shift (`holdsPage`). */
    fun holdsPage() = block()?.holdsPage ?: false

    /**
     * Reads the block (the page's effects call this on every change of connection, switches or order). The read runs in the
     * flow's own scope, never inside the caller's effect: an effect whose key changes is cancelled, and a cancelled read
     * used to leave the block `Awaiting` for good (no Seerr call, page held, `StartLeer` 18.11.).
     */
    fun load() = runner.request()

    private val runner = CoalescedLoad(CoroutineScope(SupervisorJob() + Dispatchers.Main)) { read() }

    private suspend fun read() {
        if (!app.seerrConnected.value) return
        val lists = app.seerr.lists()
        if (!settled) {
            withContext(Dispatchers.IO) { lists.beginHome(remembered()) }
            // What the last start showed is there at once (the core's stash, no call); the live read below replaces it.
            val stale = withContext(Dispatchers.IO) {
                try { lists.restoreHome(dismissedRead(app), seerrArrivalOn(app), seerrRequestsOn(app)) }
                catch (e: CancellationException) { throw e } catch (_: Exception) { null }
            }
            if (stale != null && !settled && info == null) info = stale
        }
        val loaded = coroutineScope {
            if (!settled) launch {
                val gate = withContext(Dispatchers.IO) { runCatching { lists.gateHome() }.getOrNull() }
                if (gate != null && !settled && info == null && gate.state == SeerrHomeState.PENDING) info = gate
            }
            withContext(Dispatchers.IO) {
                try {
                    lists.setArrivalsExpanded(app.store.rememberValue(expandedKey) == "1")
                    lists.loadHome(dismissedRead(app), seerrArrivalOn(app), seerrRequestsOn(app))
                } catch (e: CancellationException) { throw e } catch (_: Exception) { null }
            }
        }
        if (loaded == null || loaded.state == SeerrHomeState.HIDDEN) { info = null; settled = true }
        else {
            if (loaded.state != SeerrHomeState.PENDING) { app.store.remember(memoryKey(), loaded.memory); settled = true }
            info = loaded
            store(loaded)
        }
        // Start stands: the first Seerr read of this start (account, own requests, admin queue, discover rails) fills the
        // core's stash in the background; the core runs it once at a time and the pages wait for it.
        val hub = app.seerr.hub()
        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch { runCatching { hub.warmUp() } }
    }

    /** The X or a swipe on a card: hidden for good; the core closes the stack of fewer than two. */
    fun dismiss(requestId: Long) {
        val lists = app.seerr.lists()
        val ids = lists.dismissArrival(requestId)
        app.store.remember(dismissedKey, ids.joinToString(","))
        val next = lists.home()
        info = next
        store(next)
    }

    fun setExpanded(on: Boolean) {
        val next = app.seerr.lists().setArrivalsExpanded(on)
        info = next
        store(next)
    }

    private fun store(h: SeerrHomeInfo) = app.store.remember(expandedKey, if (h.arrivalsExpanded) "1" else "0")
}

private const val expandedKey = "seerrArrivalsExpanded"

/** Which section of the core's Home block a row draws. */
enum class SeerrHomePart { Arrival, Requests }

// ---------------------------------------------------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------------------------------------------------

/** One Seerr section of the phone Home. Before the answer the blank reserve holds the room (skeleton cards, nothing to touch). */
@Composable
fun SeerrHomePartView(app: SwiftlyApplication, flow: SeerrHomeFlow, part: SeerrHomePart, open: (Destination) -> Unit) {
    val h = flow.block() ?: return
    val pending = h.state == SeerrHomeState.PENDING
    val run = rememberCoroutineScope()
    when (part) {
        SeerrHomePart.Arrival -> if (h.arrivals.isNotEmpty()) Box(Modifier.padding(horizontal = Theme.edgeSpacing)) {
            ArrivalStack(h.arrivals, h.arrivalsExpanded, pending, app.isTv,
                play = { a -> arrivalPlay(app, a, open) },
                openTitle = { a -> open(Destination(a.libraryId, a.title, if (a.art == "tv") "Series" else "Movie")) },
                close = { a -> flow.dismiss(a.requestId) }, setExpanded = { flow.setExpanded(it) })
        }
        SeerrHomePart.Requests -> if (h.rail.isNotEmpty()) Column(Modifier.alpha(if (pending) 0f else 1f).then(if (pending) Modifier.eatTouches() else Modifier),
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(h.railTitle, style = Theme.section, color = Theme.font, modifier = Modifier.padding(horizontal = Theme.edgeSpacing))
            LazyRow(contentPadding = PaddingValues(horizontal = Theme.edgeSpacing), horizontalArrangement = Arrangement.spacedBy(Theme.tileSpacing)) {
                items(h.rail, key = { it.key }) { t -> SeerrCardTile(t, Modifier.width(Theme.tileWidth)) { run.launch { openSeerrCard(app, t, open) } } }
            }
        }
    }
}

private fun Modifier.eatTouches(): Modifier = pointerInput(Unit) {
    awaitEachGesture {
        while (true) { awaitPointerEvent().changes.forEach { it.consume() } }
    }
}

private val cardHeight = 90.dp
private val cardGap = 8.dp
private val peek = 12.dp
private val closedRoom = 8.dp
private val footerRoom = 44.dp
private const val shownBehind = 2

/**
 * **Several "ist da" notices as a stack** (like the notification stacks of the phone). State and order live in the core
 * (`ArrivalDeck`, `arrivalsExpanded`); this draws every card by its place in the core's order.
 *
 * Closed: the front card, up to two cards peek out below it and a small count sits in the front card; a tap opens the stack.
 * Open: every card in a list, "Weniger anzeigen" below closes it. All cards are the same views in both states, so opening
 * and closing is one spring. Phone: a card swipes away to either side (or the X) and the cards below close the gap;
 * TV: select expands, the X is focusable. Pending: the same shape as skeleton bars, nothing to touch, so nothing moves
 * when the real cards fade in.
 */
@Composable
fun ArrivalStack(arrivals: List<SeerrArrival>, expanded: Boolean, pending: Boolean, tv: Boolean,
                 play: (SeerrArrival) -> Unit, openTitle: (SeerrArrival) -> Unit, close: (SeerrArrival) -> Unit,
                 setExpanded: (Boolean) -> Unit) {
    val count = arrivals.size
    val stacked = count > 1
    val open = expanded && stacked
    val spec = spring<androidx.compose.ui.unit.Dp>(dampingRatio = 0.84f, stiffness = 224f)
    val snap = tween<androidx.compose.ui.unit.Dp>(0)
    val total = if (open) cardHeight * count + cardGap * (count - 1) + footerRoom else cardHeight + (if (stacked) closedRoom else 0.dp)
    val room by animateDpAsState(total, if (pending) snap else spec, label = "arrival-room")
    Box(Modifier.fillMaxWidth().height(room)) {
        arrivals.forEachIndexed { index, a ->
            androidx.compose.runtime.key(a.requestId) {
                val behind = if (open) 0 else minOf(index, shownBehind)
                val y by animateDpAsState(if (open) (cardHeight + cardGap) * index else peek * behind, if (pending) snap else spec, label = "arrival-y")
                val scale by animateFloatAsState(if (open) 1f else 1f - 0.05f * behind, spring(0.84f, 224f), label = "arrival-scale")
                val fade by animateFloatAsState(if (!open && index > shownBehind) 0f else 1f, tween(150), label = "arrival-fade")
                val live = !pending && (open || index == 0)
                Box(Modifier.zIndex((count - index).toFloat()).fillMaxWidth().height(cardHeight)
                    .graphicsLayer { translationY = y.toPx(); scaleX = scale; scaleY = scale; transformOrigin = TransformOrigin(0.5f, 1f); alpha = fade }) {
                    ArrivalCard(a, pending, tv, live, depth = behind, lifted = stacked && !open && index < shownBehind,
                        badge = if (stacked && !open && index == 0) count else null,
                        tap = { if (stacked && !open) setExpanded(true) else openTitle(a) },
                        play = { play(a) }, close = { close(a) })
                }
            }
        }
        if (open) FooterButton(Modifier.align(Alignment.BottomCenter)) { setExpanded(false) }
    }
}

@Composable
private fun FooterButton(modifier: Modifier, perform: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    Box(modifier.height(footerRoom).onFocusChanged { focused = it.isFocused }.clickable(onClick = perform), contentAlignment = Alignment.Center) {
        Text(translated("Weniger anzeigen"), style = Theme.small, color = Theme.fontQuiet,
             modifier = Modifier.clip(CircleShape).background(Theme.area).border(if (focused) 2.dp else 0.dp, Theme.font, CircleShape)
                 .padding(horizontal = 14.dp, vertical = 7.dp))
    }
}

@Composable
private fun ArrivalCard(a: SeerrArrival, pending: Boolean, tv: Boolean, live: Boolean, depth: Int, lifted: Boolean, badge: Int?,
                        tap: () -> Unit, play: () -> Unit, close: () -> Unit) {
    val shape = smoothRoundedShape(Theme.corner)
    val scope = rememberCoroutineScope()
    val travel = remember { Animatable(0f) }
    var width by remember { mutableIntStateOf(1) }
    var focused by remember { mutableStateOf(false) }
    // TV: the card is a focus target that holds Abspielen and the X; Compose's D-pad search never steps from it into its own children, so the
    // order card -> Abspielen -> X (and back) is set by hand.
    val cardReq = remember { androidx.compose.ui.focus.FocusRequester() }
    val playReq = remember { androidx.compose.ui.focus.FocusRequester() }
    val closeReq = remember { androidx.compose.ui.focus.FocusRequester() }
    val content by animateFloatAsState(if (pending) 0f else 1f, tween(250), label = "arrival-content")
    val swipe = if (!tv && live) Modifier.draggable(rememberDraggableState { d -> scope.launch { travel.snapTo(travel.value + d) } }, Orientation.Horizontal,
        onDragStopped = { v ->
            val away = abs(travel.value) > width * 0.4f || abs(v) > 1800f
            if (away) {
                travel.animateTo(if (travel.value + v * 0.05f >= 0f) width * 1.2f else -width * 1.2f, spring(stiffness = 300f))
                close()
            } else travel.animateTo(0f, spring(dampingRatio = 0.8f, stiffness = 320f))
        }) else Modifier
    Box(Modifier.fillMaxSize().onSizeChanged { width = it.width.coerceAtLeast(1) }
        .offset { IntOffset(travel.value.roundToInt(), 0) }
        .then(swipe)
        .clip(shape).background(Theme.area)
        .background(Color.Black.copy(alpha = 0.10f * depth))
        .border(1.dp, Color.White.copy(alpha = if (depth > 0) 0.12f else 0f), shape)
        .border(if (focused && tv && live) 2.dp else 0.dp, Theme.font, shape)
        .then(if (tv && live) Modifier.onPreviewKeyEvent { e ->
            if (focused && e.type == androidx.compose.ui.input.key.KeyEventType.KeyDown && e.key == androidx.compose.ui.input.key.Key.DirectionRight) { playReq.requestFocus(); true } else false
        } else Modifier)
        .focusRequester(cardReq)
        .onFocusChanged { focused = it.isFocused }
        .then(if (live) Modifier.clickable(onClick = tap) else Modifier)
        .then(if (!live && !pending) Modifier.clearAndSetSemantics { } else Modifier)) {
        // Skeleton bars of the exact final shape; they stay until the card is opaque.
        Row(Modifier.fillMaxSize().alpha(1f - content).padding(start = 12.dp, top = 12.dp, bottom = 12.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(Modifier.size(40.dp, 60.dp).clip(smoothRoundedShape(6.dp)).background(Color.White.copy(alpha = 0.07f)))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Box(Modifier.width(150.dp).height(14.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.07f)))
                Box(Modifier.width(84.dp).height(11.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.07f)))
            }
            Box(Modifier.width(92.dp).height(30.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.07f)))
            Box(Modifier.width(28.dp))
        }
        Row(Modifier.fillMaxSize().alpha(content).padding(start = 12.dp, top = 12.dp, bottom = 12.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            AsyncImage(model = tmdbImage(a.poster, 185), contentDescription = a.title, contentScale = ContentScale.Crop,
                       modifier = Modifier.size(40.dp, 60.dp).clip(smoothRoundedShape(6.dp)).background(Theme.raised))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(a.line, style = Theme.listTitle, color = Theme.font, maxLines = 2, modifier = Modifier.weight(1f, fill = false))
                    badge?.let { Text("$it", style = Theme.small, color = Theme.fontQuiet,
                        modifier = Modifier.clip(CircleShape).background(Color.White.copy(alpha = 0.10f)).padding(horizontal = 7.dp, vertical = 2.dp)) }
                }
                if (live) CardAction(translated("Abspielen"), play, if (tv) Modifier.focusProperties { left = cardReq; right = closeReq }.focusRequester(playReq) else Modifier)
            }
            if (live) {
                if (tv) {
                    // TV: the app's focus look (magnify + brighten, no ring), like the other small TV controls.
                    de.paulherter.swiftly.tv.FocusArea(Modifier.size(44.dp).focusProperties { left = playReq }.focusRequester(closeReq), magnifier = de.paulherter.swiftly.tv.TvTheme.focusMagnifierSmall, perform = close) { focus ->
                        Box(Modifier.matchParentSize(), contentAlignment = Alignment.Center) {
                            Symbol(Glyph.Cross, 14.dp, color = if (focus) Theme.font else Theme.fontQuiet, strength = Strength.Semibold, description = translated("Ausblenden"))
                        }
                    }
                } else Box(Modifier.size(44.dp).clip(CircleShape).clickable(onClick = close), contentAlignment = Alignment.Center) {
                    Symbol(Glyph.Cross, 14.dp, color = Theme.fontQuiet, strength = Strength.Semibold, description = translated("Ausblenden"))
                }
            }
        }
    }
}

@Composable
private fun CardAction(text: String, perform: () -> Unit, modifier: Modifier = Modifier) {
    var focused by remember { mutableStateOf(false) }
    Text(text, style = Theme.body, color = Theme.accent,
         modifier = modifier.clip(CircleShape).onFocusChanged { focused = it.isFocused }
             .border(if (focused) 2.dp else 0.dp, Theme.font, CircleShape).clickable(onClick = perform).padding(horizontal = 8.dp, vertical = 3.dp))
}

/** One Seerr section of the TV Home: same cards and rows, drawn with the TV's focusable parts. */
@Composable
fun TvSeerrPartView(app: SwiftlyApplication, flow: SeerrHomeFlow, part: SeerrHomePart, open: (Destination) -> Unit) {
    val h = flow.block() ?: return
    val pending = h.state == SeerrHomeState.PENDING
    val run = rememberCoroutineScope()
    when (part) {
        SeerrHomePart.Arrival -> if (h.arrivals.isNotEmpty()) Box(Modifier.padding(horizontal = de.paulherter.swiftly.tv.TvTheme.edgePage, vertical = de.paulherter.swiftly.tv.TvTheme.railsPadding)) {
            ArrivalStack(h.arrivals, h.arrivalsExpanded, pending, true,
                play = { a -> arrivalPlay(app, a, open) },
                openTitle = { a -> open(Destination(a.libraryId, a.title, if (a.art == "tv") "Series" else "Movie")) },
                close = { a -> flow.dismiss(a.requestId) }, setExpanded = { flow.setExpanded(it) })
        }
        SeerrHomePart.Requests -> if (h.rail.isNotEmpty()) Column(Modifier.alpha(if (pending) 0f else 1f).then(if (pending) Modifier.eatTouches() else Modifier)) {
            de.paulherter.swiftly.tv.TvRailsTitle(h.railTitle)
            LazyRow(contentPadding = PaddingValues(horizontal = de.paulherter.swiftly.tv.TvTheme.edgePage, vertical = de.paulherter.swiftly.tv.TvTheme.railsPadding),
                    horizontalArrangement = Arrangement.spacedBy(de.paulherter.swiftly.tv.TvTheme.tileSpacing)) {
                items(h.rail, key = { it.key }) { t ->
                    de.paulherter.swiftly.tv.TvTile(tmdbImage(t.poster, 342), t.title, t.badge?.line) { run.launch { openSeerrCard(app, t, open) } }
                }
            }
        }
    }
}
