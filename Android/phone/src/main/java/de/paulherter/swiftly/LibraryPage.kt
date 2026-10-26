package de.paulherter.swiftly

import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Strength
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.SubcomposeAsyncImage
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.Motion
import de.paulherter.swiftly.shared.translated
import de.paulherter.swiftly.core.Kern
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.text.NumberFormat

data class GridTile(val id: String, val title: String, val type: String, val subline: String?, val poster: String?,
                        val progress: Double?, val mark: String?, val markCount: Int,
                        /** The tile's letter in the strip of a "By name" grid (`AlphabetIndex`). */
                        val letter: String? = null)

/** Like `AppModel.pagesSize`. */
private const val PAGE = 60L

private fun JSONObject.textOrNull(inputField: String): String? = if (isNull(inputField)) null else getString(inputField)

/** Reads a tile from `Kern.libraryPage` and `Kern.titleField`, same shape. */
fun gridTileRead(k: JSONObject) = GridTile(
    k.getString("id"), k.getString("titel"), k.optString("typ"), k.textOrNull("unterzeile"), k.textOrNull("plakat"),
    if (k.isNull("fortschritt")) null else k.getDouble("fortschritt"), k.textOrNull("marke"), k.optInt("markenzahl"),
    k.textOrNull("buchstabe"))

/** The words for sorting and filtering come from the package, the same as on Apple and Linux. */
object Choices {
    private val json by lazy { JSONObject(Kern.labels()) }
    val sortings: List<Choice> by lazy { read("sortierung") }
    val filter: List<Choice> by lazy { read("filter") }
    private fun read(inputField: String): List<Choice> = json.getJSONArray(inputField).let { a ->
        (0 until a.length()).map { a.getJSONObject(it).let { o -> Choice(o.getString("wert"), o.getString("text")) } }
    }
    fun text(list: List<Choice>, value: String) = list.firstOrNull { it.value == value }?.text ?: value
}

/** An entry in the title menu: `SectionSelection` with its label; `name` only for libraries. */
data class OfferingEntry(val value: String, val name: String?, val category: Boolean)

/**
 * Counterpart of `LibraryModel` plus the scope choice from `LibraryView`: "Alle",
 * "Sammlungen", then the libraries. The rules (`SectionOffering`, `TitleFilter`) live in the
 * package and arrive through the core; this only holds what the page shows. Lives in the app,
 * not the page, since a scope change would otherwise empty the grid.
 *
 * Sort and filter survive a restart, per location (`sorting.movies`), as on iOS. The choice
 * is stored under `bibliothek-<art>`, the same name the library choice used before, so a chosen
 * library stays chosen (`SectionSelection.rememberValue`).
 */
class LibraryState(val art: String, private val store: Store) {
    var items by mutableStateOf<List<GridTile>>(emptyList()); private set
    var total by mutableIntStateOf(0); private set
    var loads by mutableStateOf(true); private set
    /** The server did not answer, as opposed to "nothing here". */
    var disrupted by mutableStateOf(false); private set
    /** What the title offers to choose from; a menu only from `isMenu`. */
    var offering by mutableStateOf<List<OfferingEntry>>(emptyList()); private set
    var isMenu by mutableStateOf(false); private set
    /** `all`, `collections` or a library id. */
    var choice by mutableStateOf("alle"); private set
    /** The collections of this scope; in memory as soon as the offer knows them. */
    var collectionList by mutableStateOf<List<CollectionTile>>(emptyList()); private set
    /** The video playlists with entries in this scope (`PlaylistDirectory`); in memory like the collections. */
    var playlistList by mutableStateOf<List<CollectionTile>>(emptyList()); private set
    var sorting by mutableStateOf(store.rememberValue("sortierung.$art") ?: "name"); private set
    /** The letter strip of a "By name" list (`LibraryModel.alphabet`); empty otherwise. */
    var letters by mutableStateOf<List<LetterEntry>>(emptyList()); private set
    var filter by mutableStateOf(store.rememberValue("filter.$art") ?: "alle"); private set
    private var loadsPost = false
    /** What `items` were loaded for: equal means refresh, different means replace. */
    private var loadedFor: String? = null
    /** `LibraryView.offeringId`: when it changes, the choice is re-checked. */
    private var identifier: String? = null
    /** Sifted from several libraries: then the core says whether the server has more. */
    private var filterMore: Boolean? = null

    val stillMorePresent: Boolean get() = !listSelected && (filterMore ?: (items.size < total))
    val collectionsSelected: Boolean get() = choice == "sammlungen"
    val playlistsSelected: Boolean get() = choice == "wiedergabelisten"
    /** "Sammlungen" and "Wiedergabelisten" come from memory, not from a query (`listChoice` on iOS). */
    val listSelected: Boolean get() = collectionsSelected || playlistsSelected
    /** What the count badge shows. */
    val shown: Int get() = when {
        collectionsSelected -> collectionList.size
        playlistsSelected -> playlistList.size
        else -> total
    }

    fun sortingSet(value: String) { sorting = value; store.remember("sortierung.$art", value) }
    fun filterSet(value: String) { filter = value; store.remember("filter.$art", value) }
    fun select(value: String) { choice = value; store.remember("bibliothek-$art", value) }

    /** `LibraryView.label`: "Alle" reads "Alle Filme" in the menu, libraries as the server names them. */
    fun label(value: String): String = when (value) {
        "alle" -> translated(if (art == "tvshows") "Alle Serien" else "Alle Filme")
        "sammlungen" -> translated("Sammlungen")
        "wiedergabelisten" -> translated("Wiedergabelisten")
        else -> offering.firstOrNull { it.value == value }?.name.orEmpty()
    }

    /** The "Bibliotheken" heading before the first library (`SectionOffering.firstLibrary`). */
    val categories: Map<String, String> get() =
        offering.firstOrNull { it.category }?.let { mapOf(it.value to translated("Bibliotheken")) }.orEmpty()

    /** Reads the offer and checks the remembered choice against it. `false`: the server was silent. */
    private suspend fun offeringRead(kern: Kern): Boolean = try {
        val o = JSONObject(withContext(Dispatchers.IO) {
            kern.sectionOffering(art, store.rememberValue("bibliothek-$art") ?: "alle").await()
        })
        val a = o.getJSONArray("eintraege")
        offering = (0 until a.length()).map { a.getJSONObject(it).let { e ->
            OfferingEntry(e.getString("wert"), e.textOrNull("name"), e.optBoolean("rubrik")) } }
        isMenu = o.optBoolean("istMenue")
        // The remembered choice belongs to an account: a library that no longer exists quietly falls
                // back to "Alle" instead of querying a foreign id.
        choice = o.getString("wahl")
        identifier = o.getString("kennung")
        true
    } catch (e: CancellationException) { throw e } catch (_: Exception) { false }

    suspend fun load(kern: Kern) {
        disrupted = false
        if (!offeringRead(kern)) {
            // No server and no content look the same here; told apart by whether the offer arrived at all.
            disrupted = items.isEmpty() && !listSelected
            loads = false
            return
        }
        pageLoad(kern)
        lookUp(kern)
    }

    /**
         * Collections and mixed libraries arrive on the side (`offeringLoad`): the page does not wait
         * for them. If that changes what "Alle" reads or what may be chosen, it reloads, like
         * `onChange(of: offeringId)` on iOS.
         */
    private suspend fun lookUp(kern: Kern) {
        try { withContext(Dispatchers.IO) { kern.offeringLoad().await() } }
        catch (e: CancellationException) { throw e } catch (_: Exception) { return }
        try {
            val a = JSONArray(withContext(Dispatchers.IO) { kern.collections(art).await() })
            collectionList = (0 until a.length()).map { collectionTileRead(a.getJSONObject(it)) }
        } catch (e: CancellationException) { throw e } catch (_: Exception) {}
        try {
            val a = JSONArray(withContext(Dispatchers.IO) { kern.playlists(art).await() })
            playlistList = (0 until a.length()).map { collectionTileRead(a.getJSONObject(it)) }
        } catch (e: CancellationException) { throw e } catch (_: Exception) {}
        val before = identifier
        val oldSelection = choice
        if (!offeringRead(kern)) return
        if (identifier != before || choice != oldSelection) pageLoad(kern)
    }

    private suspend fun pageLoad(kern: Kern) {
        // The list is already in memory: "Sammlungen" appears in the menu only if there are any.
        if (listSelected) { loads = false; return }
        loads = items.isEmpty()
        try {
            // Refreshing fetches as much as is already there (up to 300, `LibraryModel.load`): someone
                        // who finished something at title 90 would otherwise find an old progress bar there, since
                        // only the first 60 were refreshed.
            val forRetrieval = "$choice|$identifier|$sorting|$filter"
            val reach = if (loadedFor == forRetrieval) minOf(300L, maxOf(PAGE, items.size.toLong())) else PAGE
            val (new, figure) = page(kern, 0, reach)
            // Do not cut back to the first page when returning (`ListRules.auffrischen`). `load` runs
                        // every time the page reappears; if the first page replaced everything, the opened title
                        // beyond number 60 vanished, focus fell to tile 0, and a concurrent load-more appended at
                        // the old position (gap).
            val of = "$choice|$identifier|$sorting|$filter"
            items = if (loadedFor == of && figure == total && items.size > new.size) {
                val known = new.mapTo(HashSet()) { it.id }
                new + items.drop(new.size).filter { known.add(it.id) }
            } else new.distinctBy { it.id }
            loadedFor = of
            total = figure
        } catch (e: CancellationException) {
            // A cancellation is not a failure: its successor is already loading.
            throw e
        } catch (_: Exception) {
            // What is already there stays.
            disrupted = items.isEmpty()
        }
        loads = false
    }

    /** `count`: a jump in the letter strip asks for more than a page. */
    suspend fun loadMore(kern: Kern, count: Long = PAGE) {
        if (!stillMorePresent || loadsPost || loads) return
        loadsPost = true
        try {
            val before = loadedFor
            val (new, figure) = page(kern, items.size, count)
            // Meanwhile re-sorted, filtered or switched: the page belongs to another list.
            if (loadedFor != before) return
            // The server can add items between two pages; avoid duplicates.
            val known = items.mapTo(HashSet()) { it.id }
            items = items + new.filter { known.add(it.id) }
            total = figure
        } catch (e: CancellationException) { throw e } catch (_: Exception) {
        } finally { loadsPost = false }
    }

    /**
     * Mirrors `LibraryModel.jumpTarget`: the index of the first title of a letter, loading up to it
     * in steps sized by where the letter starts in the list.
     */
    suspend fun jumpTarget(kern: Kern, letter: String): Int? =
        alphabetJumpTarget(letter, letters, { items }, { stillMorePresent }, { loadsPost || loads }) { loadMore(kern, it) }

    private suspend fun page(kern: Kern, since: Int, count: Long = PAGE): Pair<List<GridTile>, Int> {
        val o = JSONObject(withContext(Dispatchers.IO) {
            kern.sectionPage(art, choice, sorting, filter, since.toLong(), count).await()
        })
        filterMore = if (o.optBoolean("gesiebt")) o.optBoolean("nochMehr") else null
        // The strip comes with the first page of a "By name" list.
        if (since == 0) letters = if (sorting == "name") lettersRead(o.optJSONArray("buchstaben")) else emptyList()
        val a = o.getJSONArray("titel")
        return (0 until a.length()).map { i ->
            gridTileRead(a.getJSONObject(i))
        } to o.getInt("gesamt")
    }
}

/** Mirrors `LibraryView` in `Sources/Shared/MainView.swift` (narrow variant). */
@Composable
fun LibraryPage(app: SwiftlyApplication, art: String, title: String, filterSelection: List<String>, open: (Destination) -> Unit) {
    val state = remember(art) { app.libraries.getOrPut(art) { LibraryState(art, app.store) } }
    val section = rememberCoroutineScope()
    LaunchedEffect(state.sorting, state.filter) { state.load(app.kern) }
    WatchStateChange(app) { state.load(app.kern) }
    val grid = rememberLazyGridState()
    val density = LocalDensity.current
    // The hairline under the header hangs on this.
    val offset by remember {
        derivedStateOf { if (grid.firstVisibleItemIndex > 0) 100f else grid.firstVisibleItemScrollOffset / density.density }
    }

    HeaderAndContent(header = { LibraryHeader(app, state, title, filterSelection, open) { offset } }) { headerDp ->
    BoxWithConstraints(Modifier.fillMaxSize().background(Theme.reason)) {
        // The strip where it means something (switched on, "By name", a grid of titles), and the right
        // margin making room for it so the gaps to the edge and to the posters match (`trailingLane`).
        val shownLetters = if (app.settings.alphabet && state.sorting == "name" && !state.listSelected
                               && state.letters.size > 1) state.letters else emptyList()
        val lane = if (shownLetters.isEmpty()) Theme.edgeSpacing else maxOf(Theme.edgeSpacing, AlphabetRailWidth)
        // `Theme.columns(usableNow:)`: three on every phone.
        val count = Theme.columns((maxWidth - Theme.edgeSpacing - lane).value)
        // Load more once the third-to-last row appears (`ListRules.postLoadSection`).
        LaunchedEffect(grid, count) {
            snapshotFlow { (grid.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: -1) to state.items.size }
                .collect { (lastOne, loaded) ->
                    if (loaded > 0 && lastOne >= loaded - count * 3) state.loadMore(app.kern)
                }
        }
        val collections = state.listSelected

        LazyVerticalGrid(
            columns = GridCells.Fixed(count), state = grid,
            contentPadding = PaddingValues(start = Theme.edgeSpacing, end = lane, top = headerDp + 8.dp, bottom = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(Theme.tileSpacing),
            verticalArrangement = Arrangement.spacedBy(20.dp),
            modifier = Modifier.fillMaxSize().areaContent()
        ) {
            if (state.playlistsSelected) {
                // Playlists in the same grid with the same tile; under the name the number of entries in this scope.
                items(state.playlistList, key = { "liste" + it.id }) { s ->
                    PlaylistTileView(s) { open(playlistTarget(s.id, s.name, art)) }
                }
            } else if (collections) {
                // Collections in the same grid with the same tile. Under the name, instead of the year, shows
                                // how many movies or series it holds.
                items(state.collectionList, key = { "sammlung" + it.id }) { s ->
                    CollectionTileView(app, s, art) { open(collectionTarget(s.id, s.name, art)) }
                }
            } else {
                // Placeholder instead of a spinner: the grid already has its shape.
                if (state.items.isEmpty() && state.loads) items(count * 3, key = { "platzhalter$it" }) {
                    Box(Modifier.animateItem(fadeInSpec = null, placementSpec = null, fadeOutSpec = Motion.reveal())) { TilePlaceholder() }
                }
                items(state.items, key = { it.id }) { GridTileView(it) { open(Destination(it.id, it.title, it.type)) } }
                // No spinner when loading more, a row of placeholders instead.
                if (state.items.isNotEmpty() && state.stillMorePresent) items(count, key = { "nachschub$it" }) { TilePlaceholder() }
            }
        }

        if (shownLetters.isNotEmpty()) {
            // The letter of the topmost visible title lights up while the grid scrolls on its own.
            val current by remember(state) {
                derivedStateOf { state.items.getOrNull(grid.firstVisibleItemIndex)?.letter }
            }
            AlphabetRail(shownLetters, current,
                         Modifier.align(Alignment.TopEnd).padding(end = (lane - AlphabetRailWidth) / 2,
                                                                  top = headerDp + 8.dp, bottom = 12.dp)) { letter ->
                section.launch {
                    // A short glide to the first title of the letter (`ScrollJump`).
                    state.jumpTarget(app.kern, letter)?.let { grid.animateScrollToItem(it) }
                }
            }
        }

        if (collections) {
            // The list is already in memory: "Sammlungen" appears in the menu only if there are any.
        } else if (AccountSwitchTransition.waits) {
            // Neither error nor empty state while switching accounts (`LibraryView`, `change`).
        } else if (state.disrupted) {
            // The server wording verbatim as on every other platform: same text, same structure, same
                        // address. A second variant ("Kein Kontakt zum Server" / "...bist du im selben Netz?") was
                        // two answers to the same question.
                        //
                        // The icon is `CloudOff`, not Apple's `externaldrive.badge.xmark`: Android has no symbol
                        // for an external drive, and a hand-drawn one would be a custom vector for a side issue.
                        // Same meaning, the platform's icon.
            EmptyState(Glyph.ServerRoute, translated("Server ist abgetaucht"),
                translated("%@ antwortet nicht. Läuft er noch, oder hängt das WLAN?", app.serverAddress()),
                primaryButton = translated("Erneut versuchen") to { section.launch { state.load(app.kern) } })
        } else if (state.items.isEmpty() && !state.loads) {
            val all = state.filter == "alle"
            EmptyState(if (all) Glyph.Store else Glyph.Filter,
                translated(if (all) "Hier ist noch nichts" else "Nichts gefunden"),
                if (all) translated("Sobald in dieser Bibliothek etwas liegt, taucht es hier auf.")
                else translated("Unter „%@“ liegt gerade nichts. Nimm einen anderen Filter.", Choices.text(Choices.filter, state.filter)),
                quietButton = if (all) translated("Aktualisieren") to { section.launch { state.load(app.kern) } }
                               else translated("Filter zurücksetzen") to { state.filterSet("alle") })
        }

    }
    }
}

/** Library header: title or title menu, header icons, pills, count. */
@Composable
private fun LibraryHeader(app: SwiftlyApplication, state: LibraryState, title: String,
                           filterSelection: List<String>, open: (Destination) -> Unit, offset: () -> Float) {
    val section = rememberCoroutineScope()
    RootHeader(offset) {
        // Centered, not at the top: without a server name below, the title is one line, and the icons on
                // the right should sit on its baseline.
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.weight(1f)) {
                val large = Theme.titleLarge
                // A menu only when there is more than one thing to choose (`SectionOffering.isMenu`): with one
                                // movie and one series library and no collections it looks exactly as before. No server
                                // name under the title.
                if (state.isMenu) {
                    Row(Modifier.tapOn {
                            // The same sheet as for sorting, with the page title as header; the "Bibliotheken" heading
                                                        // separates the libraries from "Alle" and "Sammlungen".
                            app.sheet.value = SheetRequest(title, state.offering.map { Choice(it.value, state.label(it.value)) },
                                                          state.choice, categories = state.categories) { new ->
                                if (new != state.choice) {
                                    state.select(new)
                                    section.launch { state.load(app.kern) }
                                }
                            }
                        },
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        // "Alle" reads just "Filme". The title says where you are; "Alle Filme" appears only in the
                                                // menu.
                        Text(if (state.choice == "alle") title else state.label(state.choice), style = large, color = Theme.font,
                             maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                        Symbol(Glyph.AngleDown, 15.dp, color = Theme.fontQuiet, strength = Strength.Semibold)
                    }
                } else {
                    Text(title, style = large, color = Theme.font)
                }
            }
            HeaderTargets(app, open)
        }
        ValueRail(offset) {
            if (state.listSelected) {
                // For "Sammlungen" only the count (`ShelfControls.onlyCount`): the list needs neither filtering
                                // nor sorting. The row keeps the height of a pill, otherwise it jumps up on switching.
                Box(Modifier.heightIn(min = Theme.pillsHeight))
                Spacer(Modifier.weight(1f))
                CountMark(state.shown)
            } else {
                ValuePill(Glyph.Filter, Choices.text(Choices.filter, state.filter)) {
                    app.sheet.value = SheetRequest(translated("Filtern"), Choices.filter.filter { it.value in filterSelection }, state.filter) {
                        state.filterSet(it)
                    }
                }
                ValuePill(Glyph.Sort, Choices.text(Choices.sortings, state.sorting)) {
                    app.sheet.value = SheetRequest(translated("Sortieren"), Choices.sortings, state.sorting) {
                        state.sortingSet(it)
                    }
                }
                Spacer(Modifier.weight(1f))
                // Only once known: a zero that is not yet real would be wrong.
                if (state.total > 0) CountMark(state.total)
            }
        }
    }
}

/** Mirrors `PosterTile` in `BrowseViews.swift`: fills the column, 2:3, title on two lines. */
@Composable
fun GridTileView(k: GridTile, modifier: Modifier = Modifier, perform: () -> Unit) {
    // A tile is ONE element for TalkBack: image, title and badge separately would be three tap
        // targets for the same thing.
    val share = k.progress?.takeIf { it > 0.0 && it < 1.0 }
    val marksWording = when (k.mark) {
        "offen" -> translated("%lld offen", k.markCount)
        "staffeln" -> if (k.markCount == 1) translated("1 Staffel") else translated("%lld Staffeln", k.markCount)
        "gesehen" -> translated("Gesehen")
        else -> null
    }
    val description = listOfNotNull(
        k.title, k.subline,
        share?.let { translated("%lld Prozent gesehen", (it * 100).toInt()) } ?: marksWording
    ).joinToString(", ")
    // Long press: the tile menu with preview (`TileMenu`), the same image in the same shape.
    Column(modifier.reveal().tilePress({ TileMenuRequest(k.id, k.title, k.type, k.poster, false, k.subline) }, perform)
            .semantics(mergeDescendants = true) { contentDescription = description },
        verticalArrangement = Arrangement.spacedBy(7.dp)) {
        Box(Modifier.fillMaxWidth().aspectRatio(2f / 3f).clip(RoundedCornerShape(Theme.cornerTile)).background(Theme.area)) {
            // No `SubcomposeAsyncImage` in the grid; see `TileView` on the home page.
            var missing by remember(k.poster) { mutableStateOf(k.poster == null) }
            if (missing) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Symbol(Glyph.Film, 22.dp, color = Theme.fontVeryQuiet)
            }
            // Decorative: the tile already speaks its description as a whole.
            coil3.compose.AsyncImage(model = k.poster, contentDescription = null, contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(), onError = { missing = true })
            k.progress?.takeIf { it > 0 && LocalProgressShow.current }?.let { ProgressBar(it, Modifier.align(Alignment.BottomStart)) }
            k.mark?.let { TileBadge(it, k.markCount, Modifier.align(Alignment.TopEnd)) }
        }
        // One construction everywhere: title 13 Medium on one line, then 1 spacing, detail 12
                // `schriftSehrLeise`. Only this one had two lines, and a tile that grows with its title turns
                // a grid row into two rows of different height.
        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(k.title, style = Theme.tile, color = Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis)
            k.subline?.let { Text(it, style = Theme.small, color = Theme.fontVeryQuiet, maxLines = 1) }
        }
    }
}
