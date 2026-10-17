package de.paulherter.swiftly

import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.runtime.derivedStateOf
import androidx.compose.ui.platform.LocalDensity
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Strength
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.shared.Motion
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import de.paulherter.swiftly.core.Kern
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.text.NumberFormat

/**
 * **Counterpart to `WatchlistModel`:** a library bounded by the watchlist flag, built like
 * the library page instead of its own grammar. Kind and sort order survive a restart under the
 * same keys as on iOS.
 */
class WatchlistState(private val store: Store) {
    var items by mutableStateOf<List<GridTile>>(emptyList()); private set
    var total by mutableIntStateOf(0); private set
    var loads by mutableStateOf(true); private set
    /**
     * **The server did not answer, which is not "nothing here".**
     * The error was swallowed (`catch (_: Exception) {}`) and the empty list then said "Nothing
     * saved yet". With a full watchlist that is plainly false; iOS fixed the same lie in 25 places.
     */
    var disrupted by mutableStateOf(false); private set
    /** Default "Recent": a watchlist is an intention, not a shelf; A–Z would be shelf order. */
    var sorting by mutableStateOf(store.rememberValue("sortierung.merkliste") ?: "neueste"); private set
    /** Empty means films **and** series, no third case. */
    var genre by mutableStateOf(store.rememberValue("gattung.merkliste").orEmpty()); private set
    private var loadsPost = false
    private var loadedFor: String? = null

    val stillMorePresent: Boolean get() = items.size < total

    fun sortingSet(value: String) { sorting = value; store.remember("sortierung.merkliste", value) }
    fun genreSet(value: String) { genre = value; store.remember("gattung.merkliste", value) }
    fun forget() { items = emptyList(); total = 0; loads = true; disrupted = false; loadedFor = null }

    suspend fun load(kern: Kern) {
        loads = items.isEmpty()
        disrupted = false
        try {
            // Refreshing fetches as much as is already shown (up to 300), as in `WatchlistModel.load`.
            val of = "$sorting|$genre"
            val reach = if (loadedFor == of) minOf(300, maxOf(60, items.size)) else 60
            val (new, figure) = page(kern, 0, reach)
            items = new
            loadedFor = of
            total = figure
        } catch (e: CancellationException) {
            // A cancellation is not a failure: the successor is already loading.
            throw e
        } catch (_: Exception) {
            // What is already shown stays; only whoever has nothing to show counts as failed.
            disrupted = items.isEmpty()
        }
        loads = false
    }

    suspend fun loadMore(kern: Kern) {
        if (!stillMorePresent || loadsPost || loads) return
        loadsPost = true
        try {
            val (new, figure) = page(kern, items.size)
            val known = items.mapTo(HashSet()) { it.id }
            items = items + new.filter { known.add(it.id) }
            total = figure
        } catch (e: CancellationException) { throw e } catch (_: Exception) {
        } finally { loadsPost = false }
    }

    private suspend fun page(kern: Kern, since: Int, count: Int = 60): Pair<List<GridTile>, Int> {
        val o = JSONObject(withContext(Dispatchers.IO) { kern.watchlist(genre, sorting, since.toLong(), count.toLong()).await() })
        val a = o.getJSONArray("titel")
        return (0 until a.length()).map { gridTileRead(a.getJSONObject(it)) } to o.getInt("gesamt")
    }
}

/**
 * Mirrors iOS `WatchlistView`, narrow variant: a page with back arrow, reached via the symbol
 * in the header.
 * **The grid symbol, not the funnel:** the library shows "All" as a state at the same place; here
 * the pill selects a kind. Same word, same place, two meanings would be a trap. Removal happens
 * on the title page, not here.
 */
@Composable
fun WatchlistPage(app: SwiftlyApplication, open: (Destination) -> Unit, back: () -> Unit) {
    val state = app.watchlist
    // Fresh on every arrival; what was removed on a title page is gone then.
    LaunchedEffect(state.sorting, state.genre) { state.load(app.kern) }
    WatchStateChange(app) { state.load(app.kern) }
    val genres = remember { selectionRead(Kern.savedGenres()) }
    val grid = rememberLazyGridState()
    val section = rememberCoroutineScope()

    val density = LocalDensity.current
    val offset by remember {
        derivedStateOf { if (grid.firstVisibleItemIndex > 0) 100f else grid.firstVisibleItemScrollOffset / density.density }
    }

    // **Content runs under the header**, like `safeAreaInset(edge: .top) { header }` on iPhone.
    HeaderAndContent(header = {
        // The arrow sits at the edge as on every subpage, the value row below it in the page margin.
        RootHeader({ offset }, margin = false) {
            SubpageHeader(translated("Merkliste"), back, bottom = 0.dp, top = false)
            ValueRail({ offset }, Modifier.padding(horizontal = Theme.edgeSpacing)) {
                ValuePill(Glyph.Grid, Choices.text(genres, state.genre)) {
                    app.sheet.value = SheetRequest(translated("Merkliste"), genres, state.genre) { state.genreSet(it) }
                }
                ValuePill(Glyph.Sort, Choices.text(Choices.sortings, state.sorting)) {
                    app.sheet.value = SheetRequest(translated("Sortieren"), Choices.sortings, state.sorting) { state.sortingSet(it) }
                }
                Spacer(Modifier.weight(1f))
                if (state.total > 0) CountMark(state.total)
            }
        }
    }) { headerDp ->
        BoxWithConstraints(Modifier.fillMaxSize().background(Theme.reason)) {
            val count = Theme.columns((maxWidth - Theme.edgeSpacing * 2).value)
            LaunchedEffect(grid, count) {
                snapshotFlow { (grid.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: -1) to state.items.size }
                    .collect { (lastOne, loaded) -> if (loaded > 0 && lastOne >= loaded - count * 3) state.loadMore(app.kern) }
            }
            LazyVerticalGrid(GridCells.Fixed(count), state = grid,
                contentPadding = PaddingValues(start = Theme.edgeSpacing, end = Theme.edgeSpacing, top = headerDp + 8.dp, bottom = 24.dp),
                horizontalArrangement = Arrangement.spacedBy(Theme.tileSpacing),
                verticalArrangement = Arrangement.spacedBy(20.dp),
                modifier = Modifier.fillMaxSize().navigationBarsPadding()) {
                if (state.items.isEmpty() && state.loads) items(count * 3, key = { "platzhalter$it" }) {
                    Box(Modifier.animateItem(fadeInSpec = null, placementSpec = null, fadeOutSpec = Motion.reveal())) { TilePlaceholder() }
                }
                items(state.items, key = { it.id }) { k -> GridTileView(k) { open(Destination(k.id, k.title, k.type)) } }
                if (state.items.isNotEmpty() && state.stillMorePresent) items(count, key = { "nachschub$it" }) { TilePlaceholder() }
            }
            // **Failed and empty are two states.** Mirrors `WatchlistView`.
            if (AccountSwitchTransition.waits) {
                // On account switch neither failure nor empty state.
            } else if (state.disrupted && state.items.isEmpty() && !state.loads) {
                EmptyState(Glyph.ServerRoute, translated("Server ist abgetaucht"),
                    translated("%@ antwortet nicht. Läuft er noch, oder hängt das WLAN?", app.serverAddress()),
                    primaryButton = translated("Erneut versuchen") to { section.launch { state.load(app.kern) } })
            } else if (state.items.isEmpty() && !state.loads) {
                EmptyState(Glyph.Bookmark, translated("Noch nichts gemerkt"),
                    translated("Tippe irgendwo auf das Lesezeichen. Dein Zukunfts-Ich freut sich."))
            }
        }
    }
}
