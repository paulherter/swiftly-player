package de.paulherter.swiftly.tv

import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Strength
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.tween
import androidx.compose.ui.layout.positionInParent
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.gestures.BringIntoViewSpec
import androidx.compose.foundation.gestures.LocalBringIntoViewSpec
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import kotlinx.coroutines.CoroutineScope
import kotlin.math.roundToInt
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.repeatOnLifecycle
import coil3.compose.AsyncImage
import de.paulherter.swiftly.*
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import de.paulherter.swiftly.core.Kern
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * Mirrors iOS `Backdrop` / `BackdropsFade`: the landscape backdrop at the top right, fading out
 * towards the text and downwards into the background. Home, title, series and person pages share it.
 *
 * One alpha mask, no overlay painted in `Theme.reason`. Two gradients from `Theme.reason` to
 * transparent drawn over the image assume a flat page background; once `TvImageReason` tints the
 * background after the backdrop, the image ended in a hard edge at the left and bottom where the
 * overlay hit the tinted background in the wrong colour.
 *
 * tvOS uses `BackdropsFade` (`Sources/tvOS/TVComponents.swift`) as a mask: the image itself turns
 * transparent at the left and bottom, and whatever lies behind shows through, in any colour.
 * Rebuilt with `graphicsLayer(compositingStrategy = Offscreen)` (`BlendMode.DstIn` needs its own
 * layer, otherwise it affects everything below instead of just this image) and two `drawRect`
 * calls with `DstIn` instead of SwiftUI's two `.mask` calls. Same anchors as on iOS.
 */
@Composable
fun Backdrop(image: String?, modifier: Modifier = Modifier, duration: Int = 300) {
    Crossfade(image, animationSpec = tween(duration), label = "kulisse", modifier = modifier.size(590.dp, 350.dp)) { url ->
        Box(Modifier.fillMaxSize()
                .graphicsLayer(compositingStrategy = CompositingStrategy.Offscreen)
                .drawWithContent {
                    drawContent()
                    // Horizontal: transparent at the left, fully visible at the right (first mask of
                    // `BackdropsFade`, `.leading` to `.trailing`).
                    drawRect(Brush.horizontalGradient(
                        0.00f to Color.White.copy(alpha = 0.00f),
                        0.15f to Color.White.copy(alpha = 0.05f),
                        0.29f to Color.White.copy(alpha = 0.22f),
                        0.45f to Color.White.copy(alpha = 0.50f),
                        0.57f to Color.White.copy(alpha = 0.75f),
                        0.70f to Color.White.copy(alpha = 0.90f),
                        0.85f to Color.White.copy(alpha = 0.98f),
                        1.00f to Color.White.copy(alpha = 1.00f),
                    ), blendMode = BlendMode.DstIn)
                    // Vertical: fully visible at the top, transparent at the bottom (second mask of
                    // `BackdropsFade`, `.top` to `.bottom`).
                    drawRect(Brush.verticalGradient(
                        0.00f to Color.White.copy(alpha = 1.00f),
                        0.50f to Color.White.copy(alpha = 1.00f),
                        0.60f to Color.White.copy(alpha = 0.88f),
                        0.70f to Color.White.copy(alpha = 0.62f),
                        0.80f to Color.White.copy(alpha = 0.34f),
                        0.89f to Color.White.copy(alpha = 0.14f),
                        0.95f to Color.White.copy(alpha = 0.04f),
                        1.00f to Color.White.copy(alpha = 0.00f),
                    ), blendMode = BlendMode.DstIn)
                }) {
            AsyncImage(model = url, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        }
    }
}

/**
 * No tvOS counterpart: SwiftUI has no built-in "bring the focused view into view" for custom
 * lists. Compose reports a request to every enclosing scroll container on each focus change,
 * vertical and horizontal. On a TV (`leanback` feature) the system default is a pivot behaviour
 * that keeps the focused item at 30 % height even when it is already fully visible.
 * `PivotBringIntoViewSpec` itself is `internal` since Foundation 1.7, hence
 * `TvRailsBringIntoView` below as a slim rebuild of the same calculation.
 *
 * When focus moves horizontally inside a `LazyRow` (the focus zoom grows the tile), the growing
 * tile reports again at every intermediate step to the vertical ancestor, the home `LazyColumn`,
 * which snaps it back to 30 %. That is the up-and-down jitter on every left/right press within a row.
 *
 * The vertical row change already has its own deliberate motion via
 * `listsState.animateScrollToItem(...)`, so the built-in bring-into-view is switched off
 * entirely (always 0) around the `LazyColumn`. Inside each `LazyRow`, `TvRailsBringIntoView`
 * applies again so the next tile scrolls along horizontally.
 */
@OptIn(ExperimentalFoundationApi::class)
object TvNoVerticalRightsBringIntoView : BringIntoViewSpec {
    override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float) = 0f
}

/**
 * Rebuild of the pivot behaviour every `LazyRow` had by default before `LocalBringIntoViewSpec`
 * was overridden: the focused tile moves to 30 % of the strip width, not all the way to the edge,
 * so the next tile stays visible on the right. If the tile no longer fits there (wider than the
 * strip), its end aligns with the strip edge instead of the pivot, as in the system behaviour.
 */
@OptIn(ExperimentalFoundationApi::class)
object TvRailsBringIntoView : BringIntoViewSpec {
    private const val pivot = 0.3f
    override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float): Float {
        if (containerSize <= 0f) return 0f
        val idealPreEdge = pivot * containerSize
        val spaceAfter = containerSize - idealPreEdge
        val targetPreEdge = if (size <= containerSize && spaceAfter < size) containerSize - size else idealPreEdge
        return offset - targetPreEdge
    }
}

/**
 * Like `TvRailsBringIntoView`, but a fully visible tile stays put. Episode row of the series
 * page: moving down from the header lands focus on the tile closest below the button, the first
 * visible one. The pivot then pushed it to 30 % width, the row moved one episode to the right, and
 * the next down press found the previous episode under the button (4, 3, 2, 1). Now the row only
 * moves if the tile is not fully in view; then it goes to the pivot as before.
 */
@OptIn(ExperimentalFoundationApi::class)
object TvStaticRail : BringIntoViewSpec {
    override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float): Float {
        if (containerSize <= 0f) return 0f
        if (offset >= -0.5f && offset + size <= containerSize + 0.5f) return 0f
        return TvRailsBringIntoView.calculateScrollDistance(offset, size, containerSize)
    }
}

/** How a section comes into view on focus entry; see `TvSections.enter`. */
enum class TvSectionKind {
    /** Header with button row: page fully at the top, full header visible. */
    Header,
    /** Section flush at the top (with `TvSections.rand`), not beyond `maxValue` at the page end. */
    Flush,
    /**
     * First section of a page without a focusable header (person, Seerr without request button):
     * scroll as little as possible so its bottom edge is visible; the header stays visible.
     */
    NearHeader,
}

/**
 * Mirrors the tvOS focus engine with `focusSection` on `DetailView` / `SeriesView` /
 * `PersonView` / `SeerrDetailView`: when focus enters a section, the whole section is clear
 * (row title, tiles, caption incl. focus-zoom margin); back in the button row the page is fully
 * at the top again.
 *
 * Compose's default "only as far as needed" calculation (`TvAbschnittsweisesBringIntoView`)
 * works with the focused element, not the section: scrolling down cut off the names below the
 * cast images, scrolling up only brought the play button into view and never the title and
 * description above it. So vertical bring-into-view is fully off on these pages
 * (`TvNoVerticalRightsBringIntoView`); each section reports its position and scrolls itself on
 * entry (`hasFocus` changes). Left/right inside moves nothing.
 */
class TvSections internal constructor(val scroll: ScrollState, private val run: CoroutineScope, private val edgePx: Float) {
    internal var content: LayoutCoordinates? = null
    internal var window = 0
    private val situations = HashMap<String, LayoutCoordinates>()
    private var active: String? = null

    internal fun status(key: String, c: LayoutCoordinates) { situations[key] = c }
    internal fun leave(key: String) { if (active == key) active = null }

    internal fun enter(key: String, art: TvSectionKind) {
        if (active == key) return
        active = key
        val target = if (art == TvSectionKind.Header) 0f else {
            val c = situations[key] ?: return
            val i = content ?: return
            if (!c.isAttached || !i.isAttached || window <= 0) return
            // Both coordinates are in the scrolled content, so the distance does not depend on the scroll position.
            val top = i.localPositionOf(c, Offset.Zero).y
            val bottom = top + c.size.height
            if (art == TvSectionKind.Flush) top - edgePx else bottom - window
        }
        val should = target.roundToInt().coerceIn(0, scroll.maxValue)
        if (should != scroll.value) run.launch { scroll.animateScrollTo(should, tween(TvTheme.sectionDuration, easing = TvTheme.focusCurve)) }
    }
}

/**
 * The scrolling column for `TvDetail`, `TvSeries`, `TvPerson`, `TvSeerrDetailPage`. Vertical
 * bring-into-view is off; `TvStrip` and the episode strip set `TvRailsBringIntoView` again inside.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun TvSectionPage(content: @Composable ColumnScope.(TvSections) -> Unit) {
    val scroll = rememberScrollState()
    val run = rememberCoroutineScope()
    val margin = with(LocalDensity.current) { 12.dp.toPx() }
    val sections = remember(scroll) { TvSections(scroll, run, margin) }
    CompositionLocalProvider(LocalBringIntoViewSpec provides TvNoVerticalRightsBringIntoView) {
        Column(Modifier.fillMaxSize().onSizeChanged { sections.window = it.height }
                   .verticalScroll(scroll).onGloballyPositioned { sections.content = it }) {
            content(sections)
        }
    }
}

/** Reports position and focus entry of a section to `TvSections`. */
fun Modifier.tvSection(sections: TvSections, key: String, art: TvSectionKind = TvSectionKind.Flush): Modifier =
    this.onGloballyPositioned { sections.status(key, it) }
        .onFocusChanged { if (it.hasFocus) sections.enter(key, art) else sections.leave(key) }

/**
 * Mirrors `HeaderInfo` in `Sources/tvOS/TVComponents.swift`: one source for home, movie page
 * and series page, otherwise they drift apart (`loadMore()` and `Titelangaben` did that before).
 * Title, optional second line (episode title), then a line "code · year · runtime" with rating
 * and certification, then the description. Always three lines, two with a second line, so the
 * button row (detail) or the rows (home) sit at the same place on every page.
 *
 * `closing` corresponds to tvOS' `@ViewBuilder var closing`: `TvRemainingTimeMark` on home, a
 * direct-play `TvProofRow` on movie and series pages; one function, no second layout.
 * `TvDetailHeader` (`TvTitle.kt`) calls the same function.
 */
@Composable
fun HeaderInfo(title: String, secondLine: String?, detailsRow: String?, rating: Double?,
                 sharing: String?, description: String?, modifier: Modifier = Modifier,
                 logo: String? = null, closing: @Composable () -> Unit = {}) {
    Column(modifier.width(500.dp)) {
        // With 'title as logo' (Settings, Appearance) the logo goes here. The row keeps its 34 dp;
        // a taller logo grows upwards into the free space and pushes nothing below.
        Box(Modifier.height(34.dp).wrapContentHeight(Alignment.Bottom, unbounded = true)) {
            TitleMark(title, logo, row = 28.dp) {
                Text(title, style = TvTheme.infoTitle, color = Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis,
                     modifier = Modifier.height(34.dp))
            }
        }
        secondLine?.let {
            Text(it, style = TvTheme.infoSecondRow, color = Theme.fontQuiet, maxLines = 1,
                 overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 5.dp).height(22.dp))
        }
        // Fixed 17 dp, content may overflow. tvOS: `.frame(height: 34)`; the direct-play badge is
        // centred and overhangs the row without shifting anything. With `heightIn(min = 17)` the row grew
        // with the badge (~26 dp) or certification badge on the detail page, putting description and
        // button row lower than on home. `wrapContentHeight(unbounded = true)` measures the row without
        // a height limit but reports only 17 dp and centres it; Box and Row do not clip, so nothing is cut off.
        Box(Modifier.padding(top = 7.dp).height(17.dp)) {
        Row(Modifier.wrapContentHeight(Alignment.CenterVertically, unbounded = true), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            detailsRow?.takeIf { it.isNotEmpty() }?.let {
                // Full value instead of opacity: a hero image lies underneath, and opacity reads differently
                // over an image than over the plain background. White at 62 percent equals `schriftSehrLeise` (#989898).
                Text(it, style = TvTheme.small, color = Theme.fontVeryQuiet, maxLines = 1)
            }
            // Rating and certification appear on every page, home and detail; only the direct-play
            // evidence is detail-only and comes via `closing`.
            TvProofRow(directPlayFlag = false, hint = null, rating = rating, sharing = sharing)
            closing()
        }
        }
        Text(description.orEmpty(), style = TvTheme.body, color = Theme.fontVeryQuiet,
             maxLines = if (secondLine != null) 2 else 3, overflow = TextOverflow.Ellipsis,
             modifier = Modifier.padding(top = 11.dp).height(TvTheme.descriptionHeight(if (secondLine != null) 2 else 3)))
    }
}

/**
 * Mirrors `RemainingTimeMark` in `Sources/tvOS/TVComponents.swift`: "12 minutes left" with a clock,
 * "watched" with a checkmark, otherwise nothing.
 */
@Composable
fun TvRemainingTimeMark(remainingTime: String?, watched: Boolean) {
    val (symbol, text) = when {
        remainingTime != null -> Glyph.Clock to remainingTime
        watched -> Glyph.Checkmark to translated("Gesehen")
        else -> return
    }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Symbol(symbol, 13.dp, color = Theme.accent, strength = Strength.Medium)
        Text(text, style = TvTheme.body, color = Theme.accent, maxLines = 1)
    }
}

/**
 * Reads whether no single request got through (`HomeResponse.disrupted` from
 * `Kern.home`). Separate from `railsRead` (`StartPage.kt`, phone file): the phone home
 * shows a plain error text inline, the TV a full empty state like tvOS. That is a display
 * difference, not a facade one, so a second small read is enough instead of changing another
 * file.
 */
private fun disturbedRead(json: String): Boolean = JSONObject(json).optBoolean("gestoert", false)

/**
 * Mirrors tvOS `HomeView`: a fixed header zone with the rows below. The header zone shows what
 * currently has focus; the image changes after 250 ms and fades for 300 ms, the text changes
 * immediately. Rows and their order come from the package as on the phone.
 *
 * Four states, as on tvOS: loading (two placeholder rows, one landscape), disturbed (server not
 * answering, with "try again"), empty (no content at all) and the rows themselves.
 */
@OptIn(ExperimentalComposeUiApi::class, ExperimentalFoundationApi::class)
@Composable
fun TvStartPage(app: SwiftlyApplication, open: (Destination) -> Unit) {
    val e = app.settings
    var rails by remember { mutableStateOf(app.startRails) }
    var disrupted by remember { mutableStateOf(false) }
    val run = rememberCoroutineScope()

    suspend fun load() {
        // An account switch in progress does the loading; returning to the page does not (it would fetch the old account).
        if (de.paulherter.swiftly.AccountSwitchTransition.waits && !de.paulherter.swiftly.AccountSwitchTransition.switched) return
        runCatching {
            withContext(Dispatchers.IO) {
                app.kern.home(e.newAccessDisconnected, e.startRails.toTypedArray(), e.startOut.toTypedArray(),
                                    app.store.rememberValue("bibliothek-movies").orEmpty(), app.store.rememberValue("bibliothek-tvshows").orEmpty(),
                                    e.startGenres.toTypedArray(), e.genreChips, e.startLibrariesJson()).await()
            }
        }.onSuccess { json ->
            val list = railsRead(json).also { app.startRails = it }
            rails = list
            disrupted = disturbedRead(json)
            if (!disrupted) app.startLoaded = System.currentTimeMillis()
            // Mirrors `shelfWrite()` in `HomeView.swift`: on every home load, write the same categories
            // for the Watch Next shelf. Off the main thread: the system provider needs several accesses
            // (read, write, possibly delete).
            if (!disrupted) withContext(Dispatchers.IO) {
                runCatching { TvContinueWatchingShelf.updateNow(app, list) }
            }
        }.onFailure { disrupted = true }
    }
    LaunchedEffect(e.newAccessDisconnected, e.startRails, e.startOut, e.startGenres, e.genreChips, e.startLibraries.map { it.id }) { load() }
    // The player refreshes without delay; the foreground refreshes with a 30 s grace period.
    // Same flow as `StartPage.kt` on the phone. The player is its own activity on the TV too
    // (picture-in-picture, foreground service), not an overlay as on tvOS, so "comes back" here is
    // `Lifecycle.State.STARTED`.
    val playsNow = app.play.value != null
    var hasPlay by remember { mutableStateOf(false) }
    LaunchedEffect(playsNow) { if (playsNow) hasPlay = true else if (hasPlay) { hasPlay = false; load() } }
    // Once more when the end report is through; only then does the server know the position.
    val ended = app.playbackEnded.intValue + app.watchStateChanged.intValue
    val endedInitial = remember { ended }
    LaunchedEffect(ended) { if (ended != endedInitial) load() }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            if (Kern.refreshDue(app.startLoaded)) load()
        }
    }

    // Mirrors `lastAtTitle` in `HomeView.swift`: where focus really was, as "row|id".
    // `rememberSaveable`, not `remember`: `TvMain` removes the home page from composition when a
    // subpage opens or the section changes, and restores it via the `SaveableStateHolder`. With
    // `remember` it started from zero afterwards: focus on the first tile, `focusRail` 0 and thus
    // `animateScrollToItem(0)`, so the page jumped to the top.
    var lastAtTitle by rememberSaveable { mutableStateOf<String?>(null) }
    fun tileTo(mark: String?, l: List<Rail>?): Tile? {
        val parts = mark?.split('|', limit = 2) ?: return null
        return l?.getOrNull(parts[0].toIntOrNull() ?: -1)?.tiles?.firstOrNull { it.id == parts.getOrNull(1) }
    }
    var current by remember { mutableStateOf(tileTo(lastAtTitle, rails)) }
    val list = rails
    LaunchedEffect(list) { if (current == null) current = list?.firstOrNull()?.tiles?.firstOrNull() }
    // With the restored title, show the matching image immediately; otherwise the backdrop fades in
    // from empty after coming back.
    //
    // `backdrop`, not `landscape`. `landscape` is the tile image (600 wide); the detail page used a different
    // URL, so a different image in memory, its own tone, and a pixelated backdrop on home. `backdrop`
    // is the same URL as `Title.backdrop` / `Series.backdrop` (`Kern.backdrop`, tvOS `backdropsURL`). The
    // fallbacks only apply to an old core.
    fun backdropFrom(k: Tile?) = k?.let { it.backdrop ?: it.landscape ?: it.poster }
    var image by remember { mutableStateOf(backdropFrom(current)) }
    LaunchedEffect(current) { delay(250); image = backdropFrom(current) }

    // Pass along what is already known when opening, see `TvPreOff`. An episode leads to the series
    // page, whose details, rating and description are the series', not the episode's: only name and
    // backdrop there. For a series the target page shows only the year.
    fun openWithPreOff(k: Tile) {
        val episode = k.type == "Episode"
        val details = when (k.type) {
            "Episode" -> null
            "Series" -> k.detailsRow?.substringBefore(" · ")?.takeIf { it.length == 4 && it.all(Char::isDigit) }
            else -> k.detailsRow
        }
        TvHandoff.remember(k.id, TvPreOff(k.name, details, k.rating.takeUnless { episode }, k.sharing.takeUnless { episode },
                                         k.description.takeUnless { episode }, backdropFrom(k)))
        open(Destination(k.id, k.name, k.type))
    }

    // One section fits the window: when focus moves to another row, the tvOS focus engine clears
    // row title and tiles together instead of leaving the previous row half cut off. `listsState`
    // is the Kotlin counterpart: the row of the focused item moves to the top edge of the window.
    //
    // `Column` + `verticalScroll`, not `LazyColumn`. With the lazy list, scrolling up was sometimes
    // instant instead of smooth: when the row above was no longer composed, focus search pulled it in
    // via beyond-bounds layout, and the row change did not find it in `visibleItemsInfo`; the
    // `animateScrollToItem` fallback then jumped with its own short motion. Down never hit this
    // because the next row was already partly in the layout. Home has few rows (fixed ones plus
    // genres), so all are composed now; the horizontal `LazyRow`s stay lazy. `rememberScrollState`
    // is saveable, so returning from a subpage lands at the same position.
    val listsState = rememberScrollState()
    var focusRail by rememberSaveable { mutableStateOf(0) }
    // Position of each row in the content (top, height; px), independent of the scroll position, via `positionInParent`.
    val railsStatus = remember { mutableStateMapOf<Int, Pair<Int, Int>>() }
    var window by remember { mutableIntStateOf(0) }

    // Entering the rows: only onto a tile that is currently in view.
    //
    // `focusRestorer` restores the last focused tile wherever it is. If it lay above the window
    // (lazy lists keep the focused tile "pinned" and composed, just outside the viewport), focus sat
    // invisibly under the hero zone: Right led from there to the profile image, Down went one row
    // too far. And with vertical bring-into-view off, nothing scrolled after it.
    //
    // So `entryTarget` decides from the layout: the remembered tile if fully in view (tvOS:
    // `defaultFocus(lastAtTitle)`), otherwise the frontmost visible tile of the topmost visible
    // row (tvOS: `frontmostMark`). Genre chips do not count; the tvOS default always points at a
    // tile. Each tile has its own `FocusRequester` so `enter` can redirect exactly there; only tiles
    // present in the layout are reliably attached.
    val askFor = remember { HashMap<String, FocusRequester>() }
    val railStates = remember { HashMap<Int, LazyListState>() }
    fun petition(mark: String) = askFor.getOrPut(mark) { FocusRequester() }
    fun entryTarget(): FocusRequester? {
        val l = list ?: return null
        val top = listsState.value
        if (window <= 0) return null
        val visibleRails = l.indices.filter { i ->
            val (y, h) = railsStatus[i] ?: return@filter false
            // At least the lower half in view: during a row change the upper row sits a few pixels beyond
            // the edge and should still count.
            y - top + h / 2 >= 0 && y - top < window
        }
        fun wholeVisible(i: Int): List<String> {
            val row = railStates[i]?.layoutInfo ?: return emptyList()
            return row.visibleItemsInfo
                .filter { it.offset >= row.viewportStartOffset && it.offset + it.size <= row.viewportEndOffset }
                .mapNotNull { it.key as? String }
        }
        lastAtTitle?.let { m ->
            val i = m.substringBefore('|').toIntOrNull() ?: -1
            if (i in visibleRails && m.substringAfter('|') in wholeVisible(i)) return petition(m)
        }
        val topmost = visibleRails.minOrNull() ?: return null
        val id = wholeVisible(topmost).firstOrNull() ?: return null
        return petition("$topmost|$id")
    }
    // On appearing (first build, back from a subpage, section switch to "Start") the same path:
    // wait until the layout is set (list and row state are restored by then), then go straight to
    // the entry target. No fixed delay, no detour via the first tile.
    LaunchedEffect(list != null) {
        if (list == null) return@LaunchedEffect
        val target = snapshotFlow { entryTarget() }.first { it != null }
        runCatching { target?.requestFocus() }
    }
    val chipOffset = if (e.genreChips && e.startGenres.isNotEmpty()) 1 else 0
    // Reasoning for both values at the row change right below.
    val railsSwitchDuration = 500
    val railsSwitchCurve = remember { CubicBezierEasing(0.25f, 0.1f, 0.25f, 1f) }
    // Like `inFade` on the detail pages: when the home page comes back (back from a subpage),
    // the rows fade in again while backdrop and header info stay. Counterpart to fading out the
    // header bar in `TvMain`.
    val railsFadeIn = rememberTvFadeIn(Unit)
    // Row change: the same motion every time, fixed duration, fixed curve.
    //
    // A spring (damping 1, stiffness 260) took over the velocity of the previous motion when
    // interrupted, so faster presses gave faster, shorter motions. The goal is always the same
    // softness regardless of press speed.
    //
    // So each row change is a time curve that restarts from the current position on a new target,
    // with the same duration, no velocity carry-over and no jump. The new `LaunchedEffect` cancels
    // the old one (`scroll {}` is a mutex; the running motion ends where it stands), and `distance` is
    // computed from the layout of that moment, i.e. from the actual position.
    //
    // 500 ms: a row is a bit over one tile height of travel (~200 dp); shorter looks hectic from
    // three metres away, longer lets the list visibly lag behind focus. Curve
    // `CubicBezier(0.25, 0.1, 0.25, 1)` (CSS "ease"): accelerates quickly so the list follows the
    // press at once, then a long soft run-out, which is what makes it feel smooth. Unlike
    // `easeInOut` it does not start sluggishly, so a restart mid-motion does not look like a stall.
    //
    // Left/right in a row does not change `focusRail`, so this effect does not run and the vertical
    // jitter stays away (see `TvNoVerticalRightsBringIntoView` below).
    LaunchedEffect(focusRail, list) {
        if (list == null) return@LaunchedEffect
        // On the first row, scroll all the way up so the genre chips are in view again, not just to the
        // row title, which would leave the chip row just above it.
        // The row flush at the top; all rows are composed and their position is known after the first
        // layout, so no fallback with its own motion (see `listsState`).
        val target = if (focusRail == 0) 0 else snapshotFlow { railsStatus[focusRail]?.first }.first { it != null } ?: 0
        val should = target.coerceIn(0, listsState.maxValue)
        if (should == listsState.value) return@LaunchedEffect
        // `animateScrollTo` starts from the current position; the new effect cancels the old one.
        listsState.animateScrollTo(should, tween(railsSwitchDuration, easing = railsSwitchCurve))
    }

    // As on Apple: "nothing loaded" differs from "nothing there". Genre chips are an entry point,
    // not content, and so do not count.
    val inSwitch = de.paulherter.swiftly.AccountSwitchTransition.waits
    val allEmpty = list != null && list.isEmpty() && !disrupted && !inSwitch

    // Mirrors `HomeView` `.imageReason(url: backdropsURL)` and `landscapeImage`, drawn in `TvMain`
    // (`TvBackdropsLayer`) so they simply stay when a page opens. Header shadow likewise there.
    // Error and empty state have no backdrop.
    TvBackdropReport(if ((disrupted && !inSwitch) || allEmpty) null else image)
    Box(Modifier.fillMaxSize()) {
        when {
            disrupted && !inSwitch -> TvDisruption(app, retry = { run.launch { load() } })
            allEmpty -> TvEmpty(translated("Hier ist noch nichts"), translated("Sobald auf dem Server etwas liegt, taucht es hier auf."))
            else -> {
                Column(Modifier.fillMaxSize()) {
                    Box(Modifier.fillMaxWidth().height(TvTheme.heroHeight)) {
                        // Mirrors `inquiry` in `HomeView.swift`: the same component as the detail page
                        // (`HeaderInfo`), with the episode name as second line and the remaining-time badge at the end,
                        // instead of a second layout of its own.
                        //
                        // 98 dp, not `headerBottom + 34.dp`: 196 pt from the design sheet, halved; the same number
                        // `TvDetailHeader` (`TvTitle.kt`) uses to indent its column. The header bar is its own layer
                        // above this zone (see `TvMain.kt`) and does not shift the content; `headerBottom` was left over
                        // from a version that did and put the home title 12 dp lower than the detail page's.
                        //
                        // Short crossfade (200 ms), not a hard jump: the text still changes immediately with focus
                        // (no debounce as for the image), just softly.
                        Crossfade(current, animationSpec = tween(200), label = "kopfauskunft") { k ->
                            if (k != null) {
                                HeaderInfo(k.name, k.episodeName, k.detailsRow, k.rating, k.sharing, k.description,
                                             Modifier.padding(start = TvTheme.edgePage, top = 98.dp)) {
                                    TvRemainingTimeMark(k.remainingTime, k.watched)
                                }
                            }
                        }
                    }
                    // `enter`: every entry from outside (down from the header bar, programmatic) lands on
                    // `entryTarget`, see there. No target in the layout: Compose searches itself (`Default`).
                    //
                    // Vertical is off, see `TvNoVerticalRightsBringIntoView`: the row change above
                    // (`animateScrollToItem`) already moves the list deliberately, and an extra bring-into-view made
                    // everything twitch up and down on horizontal moves within a row. Each `LazyRow` below has the
                    // system default (`TvRailsBringIntoView`, the rebuild of it) back, so the next tile keeps
                    // scrolling along there.
                    CompositionLocalProvider(LocalBringIntoViewSpec provides TvNoVerticalRightsBringIntoView) {
                        Column(Modifier.weight(1f).onSizeChanged { window = it.height }
                                   .tvInFade { railsFadeIn.value }
                                   .focusProperties { enter = { entryTarget() ?: FocusRequester.Default } }
                                   .focusGroup().verticalScroll(listsState).padding(bottom = 40.dp),
                               verticalArrangement = Arrangement.spacedBy(TvTheme.railsSpacing - TvTheme.railsPadding * 2)) {
                            if (e.genreChips && e.startGenres.isNotEmpty()) key("genres") {
                                CompositionLocalProvider(LocalBringIntoViewSpec provides TvRailsBringIntoView) {
                                    LazyRow(contentPadding = PaddingValues(horizontal = TvTheme.edgePage, vertical = TvTheme.railsPadding),
                                            horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                        // With a key like every other row; `distinct` because a duplicate key throws.
                                        items(e.startGenres.distinct(), key = { it }) { g -> TvChip(g, false) { open(Destination(g, g, "Genre")) } }
                                    }
                                }
                            }
                            // Two placeholder rows, not one: the first landscape like "Continue watching", the second
                            // portrait like the rest. Nothing changes shape when the rows arrive.
                            // No rows during an account switch; staggered in after landing.
                            val switches = de.paulherter.swiftly.AccountSwitchTransition.waits
                            if (list == null && !switches) {
                                key("platzhalter-quer") { TvRailsPlaceholder(landscape = true) }
                                key("platzhalter-plakat") { TvRailsPlaceholder(landscape = false) }
                            }
                            (if (switches) emptyList() else list.orEmpty()).forEachIndexed { i, r -> key("$i-${r.title}") {
                                Column(Modifier.railEntrance(i).onGloballyPositioned { c ->
                                    val status = c.positionInParent().y.roundToInt() to c.size.height
                                    if (railsStatus[i] != status) railsStatus[i] = status
                                }) {
                                    TvRailsTitle(r.title)
                                    // Own saveable row state (the one `LazyRow` creates itself otherwise); `entryTarget` reads
                                    // from it which tiles are in view.
                                    val row = rememberLazyListState()
                                    DisposableEffect(row, i) {
                                        railStates[i] = row
                                        onDispose { if (railStates[i] === row) railStates.remove(i) }
                                    }
                                    CompositionLocalProvider(LocalBringIntoViewSpec provides TvRailsBringIntoView) {
                                        LazyRow(state = row, contentPadding = PaddingValues(horizontal = TvTheme.edgePage, vertical = TvTheme.railsPadding),
                                                horizontalArrangement = Arrangement.spacedBy(TvTheme.tileSpacing)) {
                                            itemsIndexed(r.tiles, key = { _, k -> k.id }) { _, k ->
                                                // "Continue watching" shows the time left: "S2 · E5 · 12 min left".
                                                TvTile(if (r.landscape) k.landscape ?: k.poster else k.poster, k.name,
                                                         (if (r.landscape) k.continueWatchingRow else null) ?: k.subline, r.landscape,
                                                         if (r.landscape) k.progress else null,
                                                         mark = k.mark, markCount = k.markCount,
                                                         modifier = Modifier.focusRequester(petition("$i|${k.id}")),
                                                         focusChanged = { if (it) { current = k; focusRail = i; lastAtTitle = "$i|${k.id}" } },
                                                         // Menu key or long OK: the same tile menu as on the phone.
                                                         lengthy = {
                                                             de.paulherter.swiftly.tileMenuPanel(app, de.paulherter.swiftly.TileMenuRequest(
                                                                 k.id, k.name, k.type, null, r.landscape, k.detailsRow, continueWatching = r.landscape)) { z ->
                                                                 if (z.id == k.id) openWithPreOff(k) else open(z)
                                                             }
                                                         }) {
                                                    // "Continue watching" plays directly, as on tvOS.
                                                    if (r.landscape) run.launch { continueWatchingRequest(app, k.id)?.let { app.play.value = it } ?: openWithPreOff(k) }
                                                    else openWithPreOff(k)
                                                }
                                            }
                                        }
                                    }
                                }
                            } }
                        }
                    }
                }
            }
        }
    }
}

/**
 * Mirrors the placeholder row in `HomeView` (`RailsPlaceholder` on the phone, same shape):
 * an empty title bar with tiles in the shape that will come. No spinner, so there is not just a
 * dot at three metres distance.
 */
@Composable
private fun TvRailsPlaceholder(landscape: Boolean) {
    Column {
        TvRailsTitle(" ")
        Row(Modifier.padding(horizontal = TvTheme.edgePage, vertical = TvTheme.railsPadding),
            horizontalArrangement = Arrangement.spacedBy(TvTheme.tileSpacing)) {
            val width = if (landscape) TvTheme.landscapeWidth else TvTheme.posterWidth
            val height = if (landscape) TvTheme.landscapeHeight else TvTheme.posterHeight
            repeat(if (landscape) 4 else 7) { LoadField(Modifier.size(width, height), TvTheme.cornerTile) }
        }
    }
}

// `TvStartFehler` is replaced by `TvDisruption` (`TvPages.kt`): the server formula is worded
// identically on all platforms and names the address, so one can see at a glance whether the
// server is down or the wrong network is in use.

/**
 * Mirrors `HeaderShadow` in `Sources/tvOS/TVComponents.swift`: a quiet shadow under the header
 * bar, not a long header gradient, so the bar stays legible without making home look different
 * from a detail page. Simplified to a sampled vertical gradient plus a soft spot at the top
 * right, behind the profile mark of the header bar, where the backdrop is brightest and the
 * even gradient alone is not enough.
 */
@Composable
internal fun HeaderShadow() {
    val height = headerBottom + 45.dp
    Box(Modifier.fillMaxWidth().height(height)
            .background(Brush.verticalGradient(
                0f to Theme.reason.copy(alpha = 0.46f), 0.35f to Theme.reason.copy(alpha = 0.30f),
                0.65f to Theme.reason.copy(alpha = 0.12f), 1f to Color.Transparent)))
    // The spot sits at the top right, behind the profile mark of the header bar, where the backdrop
    // is brightest and the even gradient alone is not enough. A `Canvas`, because the centre is
    // needed in screen pixels, not fractions.
    androidx.compose.foundation.Canvas(Modifier.fillMaxWidth().height(height + 40.dp)) {
        val center = androidx.compose.ui.geometry.Offset(size.width * 0.945f, size.height * 0.06f)
        val radius = 260.dp.toPx()
        drawCircle(
            brush = Brush.radialGradient(
                listOf(Theme.reason.copy(alpha = 0.52f), Theme.reason.copy(alpha = 0.20f), Color.Transparent),
                center = center, radius = radius),
            radius = radius, center = center)
    }
}
