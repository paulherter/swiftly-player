package de.paulherter.swiftly

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import de.paulherter.swiftly.shared.Strength
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.translated
import de.paulherter.swiftly.core.Kern
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

// MARK: Collections; mirrors `Sources/Shared/CollectionDetailPage.swift`

/** A collection in a section (`ItemCollection` in the package); `poster` is missing without its own image. */
data class CollectionTile(val id: String, val name: String, val poster: String?, val count: Int)

/** Reads an entry from `Kern.collections`. */
fun collectionTileRead(o: JSONObject) =
    CollectionTile(o.getString("id"), o.getString("name"), o.fieldText("plakat"), o.optInt("anzahl"))

/**
 * The route to the collection page, `CollectionRoute`: the collection and its section (`movies`,
 * `tvshows`), in `role`. Without a section (from search or watchlist): everything in it.
 */
fun collectionTarget(id: String, name: String, art: String?) = Destination(id, name, "BoxSet", role = art)

/**
 * "3 movies" or "3 series" under a collection tile; `countText` in `LibraryView`. The rule
 * lives in the package, not here (``ItemCollection.anzahltext(art:count:)``).
 */
fun collectionCount(art: String?, n: Int): String = Kern.collectionCountText(art.orEmpty(), n.toLong())

/**
 * The posters of each collection's first titles, fetched once, then from memory: the grid
 * recomposes a tile while scrolling, and the same request each time would be wasteful.
 */
private object MosaicCache {
    val posters = mutableMapOf<String, List<String?>>()
}

/**
 * Fallback poster for a collection without its own image (`Sammlungsmosaik`): a mosaic of the
 * posters of its first titles, in the same 2:3 format and with the same corners as any other poster.
 *
 * One layout per count. One title fills the field, two sit side by side, from three it becomes a
 * 2x2 mosaic. Gap 2 on the phone; on TV half of tvOS' 4, so also 2.
 *
 * `zeichen`: the film icon in the empty field, like `Picture` on iPhone; on TV it stays a plain
 * surface (`Picture` on tvOS).
 */
@Composable
fun CollectionMosaic(app: SwiftlyApplication, id: String, art: String?, height: Int, modifier: Modifier = Modifier,
                    corner: Dp = Theme.cornerTile, symbolText: Boolean = true) {
    val key = "$id|${art.orEmpty()}"
    var posters by remember(key) { mutableStateOf(MosaicCache.posters[key].orEmpty()) }
    LaunchedEffect(key) {
        if (MosaicCache.posters.containsKey(key)) return@LaunchedEffect
        val list = try {
            JSONArray(withContext(Dispatchers.IO) { app.kern.collectionMosaic(id, art.orEmpty(), height.toLong()).await() })
                .let { a -> (0 until a.length()).map { if (a.isNull(it)) null else a.getString(it) } }
        } catch (e: CancellationException) { throw e } catch (_: Exception) { return@LaunchedEffect }
        MosaicCache.posters[key] = list
        posters = list
    }
    val rails: List<List<String?>> = when {
        posters.isEmpty() -> listOf(listOf(null))
        posters.size > 2 -> listOf(posters.take(2), posters.drop(2).take(2))
        else -> listOf(posters)
    }
    Column(modifier.clip(RoundedCornerShape(corner)), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        rails.forEach { stack ->
            Row(Modifier.fillMaxWidth().weight(1f), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                stack.forEach { address ->
                    Box(Modifier.weight(1f).fillMaxHeight().background(Theme.area), contentAlignment = Alignment.Center) {
                        var missing by remember(address) { mutableStateOf(address == null) }
                        if (missing && symbolText) Symbol(Glyph.Film, 22.dp, color = Theme.fontVeryQuiet)
                        if (address != null) AsyncImage(model = address, contentDescription = null, contentScale = ContentScale.Crop,
                            modifier = Modifier.fillMaxSize(), onError = { missing = true })
                    }
                }
            }
        }
    }
}

/**
 * A collection's tile: `PosterTile` with `mosaicSource` and `inquiry`, same build as
 * `GridTileView`, with the count under the name instead of the year.
 */
@Composable
fun CollectionTileView(app: SwiftlyApplication, s: CollectionTile, art: String, modifier: Modifier = Modifier, perform: () -> Unit) {
    // One tile, one tap target, one announcement; as in `GridTileView`.
    val description = "${s.name}, ${collectionCount(art, s.count)}"
    Column(modifier.reveal().tapOn(perform).semantics(mergeDescendants = true) { contentDescription = description },
        verticalArrangement = Arrangement.spacedBy(7.dp)) {
        val inputField = Modifier.fillMaxWidth().aspectRatio(2f / 3f)
        if (s.poster == null) CollectionMosaic(app, s.id, art, 260, inputField)
        else Box(inputField.clip(RoundedCornerShape(Theme.cornerTile)).background(Theme.area)) {
            var missing by remember(s.poster) { mutableStateOf(false) }
            if (missing) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Symbol(Glyph.Film, 22.dp, color = Theme.fontVeryQuiet)
            }
            AsyncImage(model = s.poster, contentDescription = null, contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(), onError = { missing = true })
        }
        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(s.name, style = Theme.tile, color = Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(collectionCount(art, s.count), style = Theme.small, color = Theme.fontVeryQuiet, maxLines = 1)
        }
    }
}

/**
 * A collection's grid: `LibraryModel` with `ShelfSource(collection: true)`. Sorted by year by
 * default, ascending (the core sets the direction), so a series of films stands in order. Nothing
 * of this is remembered: a collection is a look into a series, not a place one returns to.
 */
class CollectionState(val id: String, val art: String?) {
    var items by mutableStateOf<List<GridTile>>(emptyList()); private set
    var total by mutableIntStateOf(0); private set
    var loads by mutableStateOf(true); private set
    var disrupted by mutableStateOf(false); private set
    var sorting by mutableStateOf("erscheinung")
    var filter by mutableStateOf("alle")
    /** The letter strip of a "By name" list; empty otherwise. */
    var letters by mutableStateOf<List<LetterEntry>>(emptyList()); private set
    private var loadsPost = false
    private var loadedFor: String? = null

    val stillMorePresent: Boolean get() = items.size < total
    /** For series the same sentence as on the series library. */
    val filterSelection: List<String> get() =
        if (art == "tvshows") listOf("alle", "angefangen", "merkliste") else Choices.filter.map { it.value }

    suspend fun load(kern: Kern) {
        loads = items.isEmpty()
        disrupted = false
        try {
            val (new, figure) = page(kern, 0)
            val of = "$sorting|$filter"
            items = if (loadedFor == of && figure == total && items.size > new.size) {
                val known = new.mapTo(HashSet()) { it.id }
                new + items.drop(new.size).filter { known.add(it.id) }
            } else new.distinctBy { it.id }
            loadedFor = of
            total = figure
        } catch (e: CancellationException) { throw e } catch (_: Exception) {
            disrupted = items.isEmpty()
        }
        loads = false
    }

    suspend fun loadMore(kern: Kern, count: Long = 60L) {
        if (!stillMorePresent || loadsPost || loads) return
        loadsPost = true
        try {
            val before = loadedFor
            val (new, figure) = page(kern, items.size, count)
            if (loadedFor != before) return
            val known = items.mapTo(HashSet()) { it.id }
            items = items + new.filter { known.add(it.id) }
            total = figure
        } catch (e: CancellationException) { throw e } catch (_: Exception) {
        } finally { loadsPost = false }
    }

    suspend fun jumpTarget(kern: Kern, letter: String): Int? =
        alphabetJumpTarget(letter, letters, { items }, { stillMorePresent }, { loadsPost || loads }) { loadMore(kern, it) }

    private suspend fun page(kern: Kern, since: Int, count: Long = 60L): Pair<List<GridTile>, Int> {
        val o = JSONObject(withContext(Dispatchers.IO) {
            kern.collectionPage(id, art.orEmpty(), sorting, filter, since.toLong(), count).await()
        })
        if (since == 0) letters = if (sorting == "name") lettersRead(o.optJSONArray("buchstaben")) else emptyList()
        val a = o.getJSONArray("titel")
        return (0 until a.length()).map { gridTileRead(a.getJSONObject(it)) } to o.getInt("gesamt")
    }
}

/**
 * Mirrors `CollectionView` in `CollectionDetailPage.swift`. The collection page is a library page: no
 * hero image, no build of its own; arrow, name, filter and sort, grid. Like `GenrePage` as a
 * subpage and like `LibraryPage` in the control row.
 */
@Composable
fun CollectionPage(app: SwiftlyApplication, target: Destination, open: (Destination) -> Unit, back: () -> Unit) {
    val state = remember(target.id, target.role) { CollectionState(target.id, target.role) }
    val section = rememberCoroutineScope()
    LaunchedEffect(state, state.sorting, state.filter) { state.load(app.kern) }
    WatchStateChange(app) { state.load(app.kern) }
    val grid = rememberLazyGridState()
    val density = LocalDensity.current
    val offset by remember {
        derivedStateOf { if (grid.firstVisibleItemIndex > 0) 100f else grid.firstVisibleItemScrollOffset / density.density }
    }
    HeaderAndContent(header = {
        RootHeader({ offset }, margin = false) {
            SubpageHeader(target.name, back, bottom = 0.dp, top = false)
            // `ShelfControls`: the same row as on the library page.
            ValueRail({ offset }, Modifier.padding(horizontal = Theme.edgeSpacing)) {
                ValuePill(Glyph.Filter, Choices.text(Choices.filter, state.filter)) {
                    app.sheet.value = SheetRequest(translated("Filtern"), Choices.filter.filter { it.value in state.filterSelection }, state.filter) {
                        state.filter = it
                    }
                }
                ValuePill(Glyph.Sort, Choices.text(Choices.sortings, state.sorting)) {
                    app.sheet.value = SheetRequest(translated("Sortieren"), Choices.sortings, state.sorting) {
                        state.sorting = it
                    }
                }
                Spacer(Modifier.weight(1f))
                if (state.total > 0) CountMark(state.total)
            }
        }
    }) { headerDp ->
        BoxWithConstraints(Modifier.fillMaxSize().background(Theme.reason)) {
            // The strip and its margin, as on the library page.
            val shownLetters = if (app.settings.alphabet && state.sorting == "name" && state.letters.size > 1)
                state.letters else emptyList()
            val lane = if (shownLetters.isEmpty()) Theme.edgeSpacing else maxOf(Theme.edgeSpacing, AlphabetRailWidth)
            val count = Theme.columns((maxWidth - Theme.edgeSpacing - lane).value)
            LaunchedEffect(grid, count) {
                snapshotFlow { (grid.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: -1) to state.items.size }
                    .collect { (lastOne, loaded) ->
                        if (loaded > 0 && lastOne >= loaded - count * 3) state.loadMore(app.kern)
                    }
            }
            LazyVerticalGrid(GridCells.Fixed(count), state = grid,
                contentPadding = PaddingValues(start = Theme.edgeSpacing, end = lane, top = headerDp + 8.dp, bottom = 40.dp),
                horizontalArrangement = Arrangement.spacedBy(Theme.tileSpacing),
                verticalArrangement = Arrangement.spacedBy(20.dp),
                modifier = Modifier.fillMaxSize().navigationBarsPadding()) {
                if (state.items.isEmpty() && state.loads) items(count * 3, key = { "platzhalter$it" }) { TilePlaceholder() }
                items(state.items, key = { it.id }) { k -> GridTileView(k) { open(Destination(k.id, k.title, k.type)) } }
                if (state.items.isNotEmpty() && state.stillMorePresent) items(count, key = { "nachschub$it" }) { TilePlaceholder() }
            }
            if (shownLetters.isNotEmpty()) {
                val current by remember(state) {
                    derivedStateOf { state.items.getOrNull(grid.firstVisibleItemIndex)?.letter }
                }
                AlphabetRail(shownLetters, current,
                             Modifier.align(Alignment.TopEnd).navigationBarsPadding()
                                 .padding(end = (lane - AlphabetRailWidth) / 2, top = headerDp + 8.dp, bottom = 40.dp)) { letter ->
                    section.launch { state.jumpTarget(app.kern, letter)?.let { grid.animateScrollToItem(it) } }
                }
            }
            if (state.disrupted) {
                EmptyState(Glyph.ServerRoute, translated("Server ist abgetaucht"),
                    translated("%@ antwortet nicht. Läuft er noch, oder hängt das WLAN?", app.serverAddress()),
                    primaryButton = translated("Erneut versuchen") to { section.launch { state.load(app.kern) } })
            } else if (state.items.isEmpty() && !state.loads) {
                val all = state.filter == "alle"
                EmptyState(if (all) Glyph.Store else Glyph.Filter,
                    translated(if (all) "Hier ist noch nichts" else "Nichts gefunden"),
                    if (all) translated("Sobald in dieser Sammlung etwas liegt, taucht es hier auf.")
                    else translated("Unter „%@“ liegt gerade nichts. Nimm einen anderen Filter.", Choices.text(Choices.filter, state.filter)),
                    quietButton = if (all) translated("Aktualisieren") to { section.launch { state.load(app.kern) } }
                                   else translated("Filter zurücksetzen") to { state.filter = "alle" })
            }
        }
    }
}

/** A "Part of the collection" row: the collection and the other titles in it, in order. */
data class CollectionRailsData(val id: String, val name: String, val art: String, val title: List<GridTile>)

/** Reads `Kern.collectionsForTitle`; silent: empty without a collection or on an error. */
suspend fun collectionRailsLoad(kern: Kern, titleIdentifier: String): List<CollectionRailsData> = try {
    val a = JSONArray(withContext(Dispatchers.IO) { kern.collectionsForTitle(titleIdentifier).await() })
    (0 until a.length()).map { a.getJSONObject(it).let { o ->
        CollectionRailsData(o.getString("id"), o.getString("name"), o.getString("art"),
                             o.fieldList("titel") { k -> gridTileRead(k) })
    } }
} catch (e: CancellationException) { throw e } catch (_: Exception) { emptyList() }

/**
 * Mirrors `Sammlungsreihe` in `CollectionDetailPage.swift`: the "Part of the collection" row on the
 * movie page, above "Similar titles", since the collection is the closer relation. Its header
 * opens the collection page: "Part of the collection" with an arrow, below it the name in 15
 * `schriftLeise`.
 *
 * No collection, no row, as with extras. At most two rows (the core).
 *
 * Loading happens on the movie page, not here (`collectionRailsLoad`), as on iOS: the row used
 * to fetch its own titles and squeezed into the page later than everything else.
 */
@Composable
fun CollectionRail(rails: List<CollectionRailsData>, open: (Destination) -> Unit) {
    rails.forEach { rail ->
        Column(Modifier.padding(top = Theme.railsSpacing).reveal(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Column(Modifier.padding(horizontal = Theme.edgeSpacing).tapOn { open(collectionTarget(rail.id, rail.name, rail.art)) },
                   verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                    Text(translated("Teil der Sammlung"), style = Theme.rail, color = Theme.font)
                    Symbol(Glyph.AngleRight, 13.dp, color = Theme.fontVeryQuiet, strength = Strength.Semibold)
                }
                Text(rail.name, style = Theme.body, color = Theme.fontQuiet, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            LazyRow(contentPadding = PaddingValues(horizontal = Theme.edgeSpacing),
                    horizontalArrangement = Arrangement.spacedBy(Theme.tileSpacing)) {
                items(rail.title, key = { it.id }) { k ->
                    GridTileView(k, Modifier.width(Theme.tileWidth)) { open(Destination(k.id, k.title, k.type)) }
                }
            }
        }
    }
}
