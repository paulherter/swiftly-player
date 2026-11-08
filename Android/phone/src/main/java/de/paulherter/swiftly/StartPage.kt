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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.wrapContentHeight
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
import androidx.compose.runtime.mutableIntStateOf
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
import androidx.compose.ui.text.font.FontWeight
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
                 val library: String? = null,
                 /** New movies and new series: the area (`movies`, `tvshows`) and the order the header
                     opens it in (`StartRail.libraryJump`). */
                 val jumpArt: String? = null, val jumpSorting: String? = null)

/** Reads the answer of `Kern.home`; the rows are already finished there. */
internal fun railsRead(json: String): List<Rail> {
    val rails = JSONObject(json).getJSONArray("reihen")
    return (0 until rails.length()).map { i ->
        val r = rails.getJSONObject(i)
        val key = if (r.isNull("titelSchluessel")) null else r.getString("titelSchluessel")
        val title = key?.let { translated(it) } ?: r.optString("name")
        val tiles = r.getJSONArray("kacheln")
        val library = r.optString("bibliothek").takeIf { r.has("bibliothek") && !r.isNull("bibliothek") && it.isNotEmpty() }
        val jumpArt = r.optString("sprungArt").takeIf { r.has("sprungArt") && !r.isNull("sprungArt") && it.isNotEmpty() }
        val jumpSorting = r.optString("sprungSortierung").takeIf { r.has("sprungSortierung") && !r.isNull("sprungSortierung") && it.isNotEmpty() }
        Rail(title, key, r.getBoolean("quer"), library = library, jumpArt = jumpArt, jumpSorting = jumpSorting,
             tiles = (0 until tiles.length()).map { k ->
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

/** What the home rows depend on in the settings; the same key on the phone and the TV. */
internal fun startKey(e: Settings): String =
    listOf(e.newAccessDisconnected, e.startRails, e.startOut, e.startGenres, e.genreChips, e.startLibraries.map { it.id }).joinToString("|")

/**
 * **Coming back to the home page** (section change, a page closing): fetch only when what is on hand is
 * older than the grace period or was built with other settings, as `needsRefresh` does on Apple.
 * Compose tears the page down on every section change, and the effect below used to fetch each time.
 */
internal fun startFresh(app: SwiftlyApplication, key: String): Boolean =
    app.startRails != null && app.startKey == key && !Kern.refreshDue(app.startLoaded)

/**
 * **From Continue Watching straight into playback** (`starte` in `HomeView`): fetch the position
 * fresh, the one from the list is often stale; a title with several versions asks which one (issue 33).
 * Without a plan the tap goes to the detail page. True = handled.
 */
internal suspend fun continueWatchingAsking(app: SwiftlyApplication, id: String): Boolean {
    val loaded = runCatching { titleRead(withContext(Dispatchers.IO) { app.kern.title(id).await() }) }.getOrNull()
    if (loaded == null) { app.message.value = translated("Die Fassungen konnten nicht geladen werden. Probier es gleich nochmal."); return true }
    if (!loaded.planPresent) return false
    // The full title is in hand, so its versions are known: several of them ask, one plays (issue 33).
    playOrChoose(app, loaded, id, loaded.resumeFrom)
    return true
}

/** Mirrors `HomeView` in `Sources/Shared/HomeView.swift` (header, rows, tiles). */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun StartPage(app: SwiftlyApplication, open: (Destination) -> Unit,
              libraryJump: (String, String) -> Unit = { _, _ -> }) {
    var rails by remember { mutableStateOf(app.startRails) }
    val run = rememberCoroutineScope()
    var starts by remember { mutableStateOf(false) }
    fun continueWatching(k: Tile) {
        if (starts) return
        starts = true
        run.launch {
            if (!continueWatchingAsking(app, k.id)) open(Destination(k.id, k.name, k.type))
            starts = false
        }
    }
    var error by remember { mutableStateOf<String?>(null) }
    val e = app.settings
    // How many loads are on their way. The lifecycle effect below fires on the very first composition as
    // well, next to the effect for the settings; without this a cold start fetched every row twice
    // (`HomeModel.runningRuns` on Apple).
    var running by remember { mutableIntStateOf(0) }
    suspend fun load() {
        // During an account switch, that reloads, not the return to the page that coincides with it.
        if (AccountSwitchTransition.waits && !AccountSwitchTransition.switched) return
        running++
        val key = startKey(e)
        try {
            val json = withContext(Dispatchers.IO) {
                app.kern.home(e.newAccessDisconnected, e.startRails.toTypedArray(), e.startOut.toTypedArray(),
                                    app.store.rememberValue("bibliothek-movies").orEmpty(), app.store.rememberValue("bibliothek-tvshows").orEmpty(),
                                    e.startGenres.toTypedArray(), e.genreChips, e.startLibrariesJson()).await()
            }
            rails = railsRead(json).also { app.startRails = it }
            app.startLoaded = System.currentTimeMillis()
            app.startKey = key
            error = null
        } catch (e: Throwable) {
            error = errorString(app, e)
        } finally {
            running--
        }
    }
    // Reload as soon as order, hidden rows or genres change; on entering the page only when it is due.
    LaunchedEffect(startKey(e)) { if (!startFresh(app, startKey(e))) load() }
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
            if (running == 0 && Kern.refreshDue(app.startLoaded)) load()
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
    // The look's glow sits behind everything (off in the original, `Looks.palette`).
    Box(Modifier.fillMaxSize()) {
    if (!app.isTv) de.paulherter.swiftly.support.LookHomeGlow(app, Modifier.align(Alignment.TopCenter)) { kotlin.math.min(offset, 300f) }
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
                    EmptyState(Glyph.WlanDisruption, translated("Server ist abgetaucht"),
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
                RailView(rail, open, libraryJump, if (rail.landscape) { k -> continueWatching(k) } else null, afterwards,
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
}

/** Mirrors the header in `HomeView`: wordmark 36 left, `HeaderTargets` right, in the `BlurHeader`. */
@Composable
private fun StartHeader(app: SwiftlyApplication, open: (Destination) -> Unit, offset: () -> Float) {
    RootHeader(offset) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            val mark = if (app.isTv) null else app.looks.palette.value.logoGradient
            if (mark != null && mark.size == 1) Wordmark(height = 36.dp, accent = mark.first())
            else Wordmark(height = 36.dp, gradient = Theme.markGradient)
            Spacer(Modifier.weight(1f))
            HeaderTargets(app, open)
        }
    }
}

@Composable
private fun RailView(rail: Rail, open: (Destination) -> Unit, libraryJump: (String, String) -> Unit,
                     direct: ((Tile) -> Unit)?, afterwards: () -> Unit, modifier: Modifier = Modifier) {
    // 12 between title and row; the title is `Theme.section` (22 bold, -0.308), as `RailTitle`.
    Column(modifier, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        // A chosen library or collection: the header opens it (mirrors `Rail` with `target` in HomeView).
        val header = Modifier.padding(horizontal = Theme.edgeSpacing)
        // Long rails (new movies / series, libraries) carry a quiet "Alle ›" at the right that opens the same
        // destination as the title (iPhone `RailTitle(all:)`).
        val destination: (() -> Unit)? = when {
            rail.library != null -> { { open(collectionTarget(rail.library, rail.title, null)) } }
            // New movies and new series: their library, in the row's order.
            rail.jumpArt != null && rail.jumpSorting != null -> { { libraryJump(rail.jumpArt, rail.jumpSorting) } }
            else -> null
        }
        Row(header.heightIn(min = 28.dp).fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(rail.title, style = Theme.section, color = Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis,
                 modifier = Modifier.weight(1f).then(if (destination != null) Modifier.tapOn { destination() } else Modifier))
            if (destination != null) {
                Spacer(Modifier.width(12.dp))
                Text(translated("Alle ›"), style = Theme.buttonText.copy(fontWeight = FontWeight.Medium), color = Theme.fontVeryQuiet, maxLines = 1,
                     modifier = Modifier.heightIn(min = 44.dp).wrapContentHeight(Alignment.CenterVertically).tapOn { destination() })
            }
        }
        LazyRow(contentPadding = PaddingValues(horizontal = Theme.edgeSpacing),
                horizontalArrangement = Arrangement.spacedBy(Theme.tileSpacing)) {
            items(rail.tiles, key = { it.id }) { k -> TileView(k, rail.landscape, continueWatching = rail.landscape, afterwards) { direct?.invoke(k) ?: open(Destination(k.id, k.name, k.type)) } }
        }
    }
}

/** Mirrors `Tile` in `HomeView.swift`: 116×174 portrait, 280×158 landscape (`heroRow`), corner 10, bar 4 at the bottom. */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun TileView(k: Tile, landscape: Boolean, continueWatching: Boolean, afterwards: () -> Unit, perform: () -> Unit) {
    val width: Dp = if (landscape) Theme.heroRowWidth else Theme.tileWidth
    val height: Dp = if (landscape) Theme.heroRowHeight else Theme.tileHeight
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
        verticalArrangement = Arrangement.spacedBy(8.dp)) {
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
        // One text block for every tile: title 13 medium on a fixed 16 line, 2 gap, subline on a fixed 15 line;
        // block 34 high so every card in a row ends at the same height and nothing is cut off.
        Column(Modifier.height(34.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(k.name, style = Theme.tile.copy(lineHeight = 16.sp), color = Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis)
            subline?.let { Text(it, style = Theme.small.copy(fontFeatureSettings = "tnum", lineHeight = 15.sp), color = Theme.fontVeryQuiet, maxLines = 1, overflow = TextOverflow.Ellipsis) }
        }
    }
}

@Composable
private fun Fallback(k: Tile) {
    Box(Modifier.fillMaxSize().background(Theme.area), contentAlignment = Alignment.Center) {
        Symbol(if (k.type == "Episode" || k.type == "Series") Glyph.Tv else Glyph.Film, 22.dp, color = Theme.font)
    }
}

/** Mirrors `RailsPlaceholder`: title bar 148 × 18, below it four tiles in the shape that will come. */
@Composable
private fun RailsPlaceholder(landscape: Boolean, modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(11.dp)) {
        LoadField(Modifier.padding(horizontal = Theme.edgeSpacing).size(148.dp, 18.dp), 4.dp)
        Row(Modifier.padding(horizontal = Theme.edgeSpacing).wrapContentWidth(Alignment.Start, unbounded = true),
            horizontalArrangement = Arrangement.spacedBy(Theme.tileSpacing)) {
            repeat(4) { LoadField(if (landscape) Modifier.size(Theme.heroRowWidth, Theme.heroRowHeight) else Modifier.size(Theme.tileWidth, Theme.tileHeight)) }
        }
    }
}
