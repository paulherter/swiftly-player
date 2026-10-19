package de.paulherter.swiftly

import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Strength
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
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
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.SubcomposeAsyncImage
import de.paulherter.swiftly.shared.Theme
import androidx.compose.foundation.layout.wrapContentWidth
import de.paulherter.swiftly.shared.Motion
import de.paulherter.swiftly.shared.Wordmark
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.withContext
import androidx.compose.foundation.combinedClickable
import de.paulherter.swiftly.core.Kern
import androidx.lifecycle.repeatOnLifecycle
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.launch
import org.json.JSONObject

data class Tile(val id: String, val name: String, val type: String, val subline: String?,
                  val poster: String?, val landscape: String?, val progress: Double?,
                  val mark: String? = null, val markCount: Int = 0,
                  val detailsRow: String? = null, val remainingTime: String? = null,
                  val watched: Boolean = false, val episodeName: String? = null,
                  /** Only for the Watch Next shelf on TV (`TvContinueWatchingShelf.kt`). */
                  val runtimeSeconds: Double? = null, val positionSeconds: Double? = null,
                  /** TV header only (`HeaderInfo` in `tv/TvStart.kt`): rating, certification and description of
                      the focused title, as `HeaderInfo` reads them from the full `Item` on tvOS. The phone does not read them. */
                  val rating: Double? = null, val sharing: String? = null, val description: String? = null,
                  /** TV only: the backdrop, same address as `Title.backdrop`/`Series.backdrop` (`Kern.backdrop`), so
                      home and detail page show the same image and tone. */
                  val backdrop: String? = null,
                  /** "S2 · E5 · 12 min left": the line under a Continue Watching tile (`continueWatchingRow`). */
                  val continueWatchingRow: String? = null)
/**
 * `key` is the raw, untranslated row name from the package (`StartRail.railsTitle` in
 * `StartRails.swift`, e.g. "Weiterschauen" or "Zuletzt hinzugefügt"), `null` for genre rows.
 * `title` is already translated and only for display. The Watch Next shelf needs the raw key: it
 * stays the same in every language setting, the translated title does not.
 */
data class Rail(val title: String, val key: String?, val landscape: Boolean, val tiles: List<Tile>,
                 /** Only for a chosen library or collection: its id; the header opens it. */
                 val library: String? = null)

/** Reads the answer of `Kern.home`; the rows are already finished there. */
internal fun railsRead(json: String): List<Rail> {
    val rails = JSONObject(json).getJSONArray("reihen")
    return (0 until rails.length()).map { i ->
        val r = rails.getJSONObject(i)
        val key = if (r.isNull("titelSchluessel")) null else r.getString("titelSchluessel")
        val title = key?.let { translated(it) } ?: r.optString("name")
        val tiles = r.getJSONArray("kacheln")
        val library = r.optString("bibliothek").takeIf { r.has("bibliothek") && !r.isNull("bibliothek") && it.isNotEmpty() }
        Rail(title, key, r.getBoolean("quer"), library = library, tiles = (0 until tiles.length()).map { k ->
            val o = tiles.getJSONObject(k)
            Tile(o.getString("id"), o.getString("name"), o.getString("typ"),
                   o.optString("unterzeile").takeIf { !o.isNull("unterzeile") },
                   o.optString("plakat").takeIf { !o.isNull("plakat") },
                   o.optString("quer").takeIf { !o.isNull("quer") },
                   if (o.isNull("fortschritt")) null else o.getDouble("fortschritt"),
                   o.optString("marke").takeIf { !o.isNull("marke") }, o.optInt("markenzahl"),
                   o.optString("angabenzeile").takeIf { !o.isNull("angabenzeile") },
                   o.optString("restzeit").takeIf { !o.isNull("restzeit") },
                   o.optBoolean("gesehen"),
                   o.optString("folgenname").takeIf { !o.isNull("folgenname") },
                   if (o.isNull("laufzeitSekunden")) null else o.getDouble("laufzeitSekunden"),
                   if (o.isNull("positionSekunden")) null else o.getDouble("positionSekunden"),
                   if (o.isNull("bewertung")) null else o.getDouble("bewertung"),
                   o.optString("freigabe").takeIf { !o.isNull("freigabe") },
                   o.optString("beschreibung").takeIf { !o.isNull("beschreibung") },
                   o.optString("kulisse").takeIf { o.has("kulisse") && !o.isNull("kulisse") },
                   o.optString("weiterschauenzeile").takeIf { o.has("weiterschauenzeile") && !o.isNull("weiterschauenzeile") })
        })
    }
}

/**
 * **From Continue Watching straight into playback** (`starte` in `HomeView`): fetch the position
 * fresh, the one from the list is often stale. Without a plan the tap goes to the detail page.
 */
internal suspend fun continueWatchingRequest(app: SwiftlyApplication, id: String): PlayRequest? = runCatching {
    titleRead(withContext(Dispatchers.IO) { app.kern.title(id).await() }).takeIf { it.planPresent }?.let { PlayRequest(id, it.resumeFrom) }
}.getOrNull()

/** Mirrors `HomeView` in `Sources/Shared/HomeView.swift` (header, rows, tiles). */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun StartPage(app: SwiftlyApplication, open: (Destination) -> Unit) {
    var rails by remember { mutableStateOf(app.startRails) }
    val run = rememberCoroutineScope()
    var starts by remember { mutableStateOf(false) }
    fun continueWatching(k: Tile) {
        if (starts) return
        starts = true
        run.launch {
            val wish = continueWatchingRequest(app, k.id)
            if (wish != null) app.play.value = wish else open(Destination(k.id, k.name, k.type))
            starts = false
        }
    }
    var error by remember { mutableStateOf<String?>(null) }
    val e = app.settings
    suspend fun load() {
        // During an account switch, that reloads, not the return to the page that coincides with it.
        if (AccountSwitchTransition.waits && !AccountSwitchTransition.switched) return
        try {
            val json = withContext(Dispatchers.IO) {
                app.kern.home(e.newAccessDisconnected, e.startRails.toTypedArray(), e.startOut.toTypedArray(),
                                    app.store.rememberValue("bibliothek-movies").orEmpty(), app.store.rememberValue("bibliothek-tvshows").orEmpty(),
                                    e.startGenres.toTypedArray(), e.genreChips, e.startLibrariesJson()).await()
            }
            rails = railsRead(json).also { app.startRails = it }
            app.startLoaded = System.currentTimeMillis()
            error = null
        } catch (e: Throwable) {
            error = errorString(app, e)
        }
    }
    // Reload as soon as order, hidden rows or genres change.
    LaunchedEffect(e.newAccessDisconnected, e.startRails, e.startOut, e.startGenres, e.genreChips, e.startLibraries.map { it.id }) { load() }
    // **Refetch after watching, with no grace period**: Continue Watching is certainly stale then.
    val playsNow = app.play.value != null
    var hasPlay by remember { mutableStateOf(false) }
    LaunchedEffect(playsNow) { if (playsNow) hasPlay = true else if (hasPlay) { hasPlay = false; load() } }
    // And once more when the end report is through: only then does the server know the position.
    // Also after a change to the watch state (tile menu); `pagesRefresh` on iOS.
    val ended = app.playbackEnded.intValue + app.watchStateChanged.intValue
    val endedInitial = remember { ended }
    LaunchedEffect(ended) { if (ended != endedInitial) load() }
    // Back in the app: reload if the state is older than the grace period from the package.
    @Suppress("DEPRECATION")
    val lifecycle = androidx.compose.ui.platform.LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(lifecycle) {
        lifecycle.repeatOnLifecycle(androidx.lifecycle.Lifecycle.State.STARTED) {
            if (Kern.refreshDue(app.startLoaded)) load()
        }
    }
    var pulls by remember { mutableStateOf(false) }
    val dragState = androidx.compose.material3.pulltorefresh.rememberPullToRefreshState()
    // Long press on any tile: the tile menu with preview (`TileMenu`); on Continue Watching with
    // "Go to overview" and "Remove from Continue Watching". The page catches up afterwards.
    val afterwards: () -> Unit = { run.launch { load() } }
    val list = androidx.compose.foundation.lazy.rememberLazyListState()
    val density = androidx.compose.ui.platform.LocalDensity.current
    // How far it has scrolled; the header gradient builds up from it, like `distance.value` on iPhone.
    val offset by remember {
        androidx.compose.runtime.derivedStateOf {
            if (list.firstVisibleItemIndex > 0) 400f
            else list.firstVisibleItemScrollOffset / density.density
        }
    }

    // **No glow.** A colored glow used to sit behind the header; on iPhone it is gone, the home page
    // carries the same dark header gradient as every other page, and that only builds up when
    // something scrolls beneath it.
    HeaderAndContent(header = { StartHeader(app, open) { offset } }) { headerDp ->
    Box(Modifier.fillMaxSize()) {
        // **Pull to reload** (`.refreshable`). The circle appears under the header, not behind it.
        androidx.compose.material3.pulltorefresh.PullToRefreshBox(pulls, onRefresh = { run.launch { pulls = true; load(); pulls = false } },
            state = dragState, modifier = Modifier.fillMaxSize(),
            indicator = {
                androidx.compose.material3.pulltorefresh.PullToRefreshDefaults.Indicator(dragState, pulls,
                    Modifier.align(Alignment.TopCenter).padding(top = headerDp), containerColor = Theme.raised, color = Theme.accent)
            }) {
        LazyColumn(state = list, verticalArrangement = Arrangement.spacedBy(Theme.railsSpacing),
                   // `contentMargins(.top, 58)` plus 8: 66 below the status area, the header ends at 42.
                   contentPadding = PaddingValues(top = headerDp + 24.dp, bottom = 12.dp),
                   modifier = Modifier.fillMaxSize().areaContent()) {
            // **A server error is not "nothing here", and not a footnote.**
            //
            // The error text used to be a quiet line in `warning` above an otherwise empty page, so the home
            // page looked like an empty server. The model is `HomeView.notPresent`: the whole area, the server
            // formula, and **two** ways out: retry and switch server. `warning` means "something is waiting
            // for someone"; here something went wrong, which is `error`.
            //
            // If rows are already there, it stays the quiet line: the content is there and only the refresh
            // failed.
            if (error != null && rails.isNullOrEmpty() && !AccountSwitchTransition.waits) item(key = "gestoert") {
                Box(Modifier.fillMaxWidth().height(420.dp)) {
                    EmptyState(Glyph.ServerRoute, translated("Server ist abgetaucht"),
                        translated("%@ antwortet nicht. Läuft er noch, oder hängt das WLAN?", app.serverAddress()),
                        primaryButton = translated("Erneut versuchen") to { run.launch { load() } },
                        quietButton = translated("Server wechseln") to { app.signOff() })
                }
            } else error?.let { item { Text(it, color = Theme.error, style = Theme.small, modifier = Modifier.padding(horizontal = Theme.edgeSpacing)) } }
            // Placeholder in the shape of the rows, then a crossfade, no ring (`einblenden`).
            // **Not built at all during an account switch**: on tap the old account's rows are gone at once,
            // and what arrives mid-flight is only set after landing, then staggered (`railEntrance`).
            val switches = AccountSwitchTransition.waits
            if (rails == null && !switches) items(3, key = { "platzhalter$it" }) { i ->
                RailsPlaceholder(landscape = i == 0, Modifier.animateItem(fadeInSpec = null, placementSpec = null, fadeOutSpec = Motion.reveal()))
            }
            // Genres either as chips or as rows, never both; the facade then omits the rows.
            if (e.genreChips && e.startGenres.isNotEmpty() && !switches) item(key = "gattungschips") {
                Box(Modifier.railEntrance(0)) { GenreChips(e.startGenres) { g -> open(Destination(g, g, "Genre")) } }
            }
            val visible = if (switches) emptyList() else rails ?: emptyList()
            itemsIndexed(visible, key = { _, r -> (r.library?.let { "bib$it" } ?: r.title) }) { i, rail ->
                RailView(rail, open, if (rail.landscape) { k -> continueWatching(k) } else null, afterwards,
                             Modifier.animateItem(fadeInSpec = Motion.reveal(), placementSpec = null, fadeOutSpec = null).railEntrance(i + 1))
            }
            // "Support Swiftly" at the very end, only when the package says so (`SupportPrompt`).
            if (visible.isNotEmpty()) item(key = "unterstuetzen") {
                Box(Modifier.padding(top = 4.dp)) { de.paulherter.swiftly.support.SupportHomeCard(app) }
            }
        }
        }
    }
    }
}

/** Mirrors the header in `HomeView`: wordmark 30 left, `HeaderTargets` right, in the `BlurHeader`. */
@Composable
private fun StartHeader(app: SwiftlyApplication, open: (Destination) -> Unit, offset: () -> Float) {
    RootHeader(offset) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Wordmark(height = 30.dp)
            Spacer(Modifier.weight(1f))
            HeaderTargets(app, open) { de.paulherter.swiftly.support.SupportHeaderHeart(app) }
        }
    }
}

@Composable
private fun RailView(rail: Rail, open: (Destination) -> Unit, direct: ((Tile) -> Unit)?, afterwards: () -> Unit, modifier: Modifier = Modifier) {
    // 12 between title and row; the title carries its level's tracking (-0.24).
    Column(modifier, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        // A chosen library or collection: the header opens it (mirrors `Rail` with `target` in HomeView).
        val header = Modifier.padding(horizontal = Theme.edgeSpacing)
        Text(rail.title, style = Theme.rail, color = Theme.font,
             modifier = if (rail.library != null) header.tapOn { open(collectionTarget(rail.library, rail.title, null)) } else header)
        LazyRow(contentPadding = PaddingValues(horizontal = Theme.edgeSpacing),
                horizontalArrangement = Arrangement.spacedBy(Theme.tileSpacing)) {
            items(rail.tiles, key = { it.id }) { k -> TileView(k, rail.landscape, continueWatching = rail.landscape, afterwards) { direct?.invoke(k) ?: open(Destination(k.id, k.name, k.type)) } }
        }
    }
}

/** Mirrors `Tile` in `HomeView.swift`: 112×168 portrait, 236×133 landscape, corner 10, bar 4 at the bottom. */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun TileView(k: Tile, landscape: Boolean, continueWatching: Boolean, afterwards: () -> Unit, perform: () -> Unit) {
    val width: Dp = if (landscape) 236.dp else Theme.tileWidth
    val height: Dp = if (landscape) 133.dp else Theme.tileHeight
    // The quiet line under the name: on Continue Watching with time left, "S2 · E5 · 12 min left".
    // The picture stays free; the label sits where the abbreviation was anyway.
    val subline = (if (continueWatching) k.continueWatchingRow else null) ?: k.subline
    val touch = Modifier.tilePress({
        TileMenuRequest(k.id, k.name, k.type, if (landscape) k.landscape ?: k.poster else k.poster, landscape, k.detailsRow,
                          continueWatching = continueWatching, afterwards = afterwards)
    }, perform)
    // **A tile is ONE element for TalkBack**, not picture plus two text lines separately, otherwise
    // three swipes would be needed to reach the next one.
    val share = k.progress?.takeIf { it > 0.0 && it < 1.0 }
    val description = listOfNotNull(
        k.name, subline,
        share?.let { translated("%lld Prozent gesehen", (it * 100).toInt()) } ?: if (k.watched) translated("Gesehen") else null
    ).joinToString(", ")
    Column(Modifier.width(width).reveal().then(touch)
            .semantics(mergeDescendants = true) { contentDescription = description },
        verticalArrangement = Arrangement.spacedBy(7.dp)) {
        Box(Modifier.size(width, height).clip(RoundedCornerShape(Theme.cornerTile)).background(Theme.area)) {
            val address = if (landscape) k.landscape ?: k.poster else k.poster
            // **No `SubcomposeAsyncImage` in rows**: it subcomposes per tile and cost whole images during
            // fast scrolling (measured: 99th percentile 81 ms).
            var missing by remember(address) { mutableStateOf(address == null) }
            if (missing) Fallback(k)
            // The image is decorative: the tile already speaks its description as a whole.
            coil3.compose.AsyncImage(model = address, contentDescription = null, contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(), onError = { missing = true })
            k.progress?.takeIf { it > 0 && LocalProgressShow.current }?.let { ProgressBar(it, Modifier.align(Alignment.BottomStart)) }
        }
        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(k.name, style = Theme.tile, color = Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis)
            subline?.let { Text(it, style = Theme.small.copy(fontFeatureSettings = "tnum"), color = Theme.fontVeryQuiet, maxLines = 1) }
        }
    }
}

@Composable
private fun Fallback(k: Tile) {
    Box(Modifier.fillMaxSize().background(Theme.area), contentAlignment = Alignment.Center) {
        Symbol(if (k.type == "Episode" || k.type == "Series") Glyph.Tv else Glyph.Film, 22.dp, color = Theme.fontVeryQuiet)
    }
}

/** Mirrors `RailsPlaceholder`: title bar 148 × 18, below it four tiles in the shape that will come. */
@Composable
private fun RailsPlaceholder(landscape: Boolean, modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(11.dp)) {
        LoadField(Modifier.padding(horizontal = Theme.edgeSpacing).size(148.dp, 18.dp), 4.dp)
        Row(Modifier.padding(horizontal = Theme.edgeSpacing).wrapContentWidth(Alignment.Start, unbounded = true),
            horizontalArrangement = Arrangement.spacedBy(Theme.tileSpacing)) {
            repeat(4) { LoadField(if (landscape) Modifier.size(236.dp, 133.dp) else Modifier.size(Theme.tileWidth, Theme.tileHeight)) }
        }
    }
}
