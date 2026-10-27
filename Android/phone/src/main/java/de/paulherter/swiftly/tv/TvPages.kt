package de.paulherter.swiftly.tv

import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Strength
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.platform.LocalDensity
import de.paulherter.swiftly.SwiftlyApplication
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupPositionProvider
import androidx.compose.ui.window.PopupProperties
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyGridScope
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.*
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import de.paulherter.swiftly.core.Kern
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONArray

/** Set the first focus once the page exists; without focus the TV accepts no input. */
@Composable
fun firstFocus(ready: Boolean = true): FocusRequester {
    val f = remember { FocusRequester() }
    // Double deadline: the whole page must exist here, not just one button.
    LaunchedEffect(ready) { if (ready) { delay(2 * TvTheme.focusDeadline); runCatching { f.requestFocus() } } }
    return f
}

/**
 * Mirrors the grid of `LibraryView`: **seven columns**, 104 dp wide with a 25 dp gap
 * (7 x 208 + 6 x 50 + 2 x 80 = 1916 points on tvOS). Header as a full row above the grid.
 *
 * **Load more from the third-to-last row** (`gridColumns * 3`), as on tvOS, so more content
 * is there before focus reaches the bottom.
 *
 * `loads`: while nothing is there yet, placeholder tiles show instead of an empty grid
 * (counterpart of `GridPlaceholder` on tvOS).
 */
@Composable
fun TvGrid(tiles: List<GridTile>, loadMore: () -> Unit = {}, focus: FocusRequester? = null,
             open: (Destination) -> Unit, loads: Boolean = false, placeholderRails: Int = 2,
             withUnderRow: Boolean = true,
             /** Passed in where the page scrolls the grid itself (the letter strip). */
             lattice: androidx.compose.foundation.lazy.grid.LazyGridState = rememberLazyGridState(),
             header: @Composable () -> Unit, more: LazyGridScope.() -> Unit = {}) {
    // **Back means back to where one was** (tvOS: `lastAtTitle`). The grid keeps its scroll
    // position via `rememberLazyGridState` (saveable, `TvMain` restores the page), but `focus` was
    // always attached to tile 0: after returning, that tile was either not composed at all (focus
    // nowhere) or the grid scrolled up to it. Now `focus` attaches to the last focused tile on
    // reappearing, which is in view with the scroll position. Read only on appearing (`comeBack`)
    // and discarded as soon as it reloads (filter, library), when the first tile applies again.
    var recent by rememberSaveable { mutableStateOf<String?>(null) }
    var comeBack by remember { mutableStateOf(recent) }
    LaunchedEffect(loads) { if (loads) comeBack = null }
    val focusIndex = comeBack?.let { id -> tiles.indexOfFirst { it.id == id } }?.takeIf { it >= 0 } ?: 0
    val end by remember { derivedStateOf { (lattice.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0) >= lattice.layoutInfo.totalItemsCount - TvTheme.gridColumns * 3 } }
    LaunchedEffect(end, tiles.size) { if (end && tiles.isNotEmpty()) loadMore() }
    // **The look's glow behind the page** (`.lookGlow()` on tvOS): from the screen's top edge, moving
    // up with the content (read while drawing, so scrolling never recomposes).
    val glowApp = LocalContext.current.applicationContext as SwiftlyApplication
    val glowDensity = LocalDensity.current.density
    Box(Modifier.fillMaxSize()) {
    TvGlow(glowApp, scrolled = {
        if (lattice.firstVisibleItemIndex > 0) TV_GLOW_SCROLL_MAX else lattice.firstVisibleItemScrollOffset / glowDensity
    })
    LazyVerticalGrid(GridCells.Fixed(TvTheme.gridColumns), state = lattice, modifier = Modifier.fillMaxSize(),
                     contentPadding = PaddingValues(start = TvTheme.edgePage, end = TvTheme.edgePage, bottom = 40.dp),
                     horizontalArrangement = Arrangement.spacedBy(TvTheme.gridColumn),
                     verticalArrangement = Arrangement.spacedBy(TvTheme.latticeRow - 16.dp)) {
        item(span = { GridItemSpan(maxLineSpan) }) { header() }
        if (loads && tiles.isEmpty()) {
            items(TvTheme.gridColumns * placeholderRails) { TvTilePlaceholder() }
        } else {
            items(tiles.size, key = { tiles[it].id }) { i ->
                val k = tiles[i]
                // **No year under the title in Library/Watchlist** (`withUnderRow: false` on tvOS). Search keeps
                // it, where it reads "Series · 2008" instead of a year.
                val menu = de.paulherter.swiftly.LocalTileMenu.current
                TvTile(k.poster, k.title, if (withUnderRow) k.subline else null,
                         mark = k.mark, markCount = k.markCount,
                         lengthy = menu?.let { m -> { m(de.paulherter.swiftly.TileMenuRequest(k.id, k.title, k.type, k.poster, false, k.subline)) } },
                         modifier = if (i == focusIndex && focus != null) Modifier.focusRequester(focus) else Modifier,
                         focusChanged = { if (it) recent = k.id }) {
                    open(Destination(k.id, k.title, k.type))
                }
            }
        }
        more()
    }
    }
}

/** Mirrors `TilePlaceholder` on tvOS: poster size, below it two breathing lines. */
@Composable
private fun TvTilePlaceholder() {
    Column(Modifier.width(TvTheme.posterWidth)) {
        LoadField(Modifier.size(TvTheme.posterWidth, TvTheme.posterHeight), TvTheme.cornerTile)
        LoadField(Modifier.fillMaxWidth().height(11.dp).padding(top = 9.dp), 3.dp)
        LoadField(Modifier.size(42.dp, 9.dp).padding(top = 5.dp), 3.dp)
    }
}

/**
 * Mirrors `Leerzustand` on tvOS: icon, title, hint, **and a way out**: on a remote a dead end is
 * worse than on a touchscreen (tvOS comment). Without `button` it stays a plain hint, as in
 * Watchlist and Search.
 */
@Composable
fun TvEmpty(headerLine: String, text: String, symbol: Glyph? = null, button: Pair<String, () -> Unit>? = null,
           /** For the initial focus when the button is the only target on the page. */
           buttonModifier: Modifier = Modifier) {
    Column(Modifier.fillMaxWidth().padding(top = 80.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        symbol?.let {
            // **44, not 38**: tvOS uses 88, here half. It was the only number in the file next to the scale.
            // No circle around it: the phone's empty state has one, tvOS omits it, and that stays.
            Symbol(it, 44.dp, Modifier.padding(bottom = 10.dp), color = Theme.fontVeryQuiet)
        }
        Text(headerLine, style = TvTheme.rail, color = Theme.font)
        Text(text, style = TvTheme.body, color = Theme.fontQuiet, textAlign = TextAlign.Center,
             modifier = Modifier.padding(top = 8.dp).widthIn(max = 480.dp))
        button?.let { (title, perform) ->
            TvButton(title, modifier = Modifier.padding(top = 16.dp).then(buttonModifier), perform = perform)
        }
    }
}

/**
 * **One wording for "the server did not answer", not thirteen.** Mirrors `DisturbState` in
 * `Sources/tvOS/Style.swift`.
 *
 * Exactly the `TvEmpty` that Library, Home and Search already show, with the **server wording**
 * ("Server ist abgetaucht" / "<address> antwortet nicht. ..." / "Erneut versuchen"). Android TV
 * used to have its own component with its own wording here, and Library, Watchlist, Search and
 * Genre had none: a network error read as "nothing here".
 *
 * `address` is optional: on a Seerr page it was Jellyseerr that stayed silent, not the own
 * server, and the wrong address in the sentence would send the user looking in the wrong place.
 *
 * The icon is `CloudOff` instead of Apple's `externaldrive.badge.xmark`, since Android has no
 * external-drive symbol.
 */
@Composable
fun TvDisruption(app: SwiftlyApplication, address: String? = null, buttonModifier: Modifier = Modifier, retry: (() -> Unit)? = null) {
    TvEmpty(translated("Server ist abgetaucht"),
           translated("%@ antwortet nicht. Läuft er noch, oder hängt das WLAN?", address ?: app.serverAddress()),
           symbol = Glyph.ServerRoute,
           button = retry?.let { translated("Erneut versuchen") to it }, buttonModifier = buttonModifier)
}

/**
 * Mirrors `LibraryView` on tvOS. **One row of capsules**: first the choice, the iPhone's title
 * menu ("Alle", "Sammlungen", a divider and the "Bibliotheken" heading, then the libraries via
 * `SectionOffering`, only from `isMenu`), then filter and sort as one capsule each with icon and
 * value, and only the count on the right. The capsule names the value ("Alle Filme", not just
 * "Filme" as on iPhone), since the top bar already says where one is.
 *
 * **No filter chips anymore** ("Alle · Angefangen · Merkliste · Ungesehen") and no "5 · sorted by"
 * on the right: on iPhone the filter is a button that names the value and opens a choice, and tvOS
 * adopted that. Each panel opens under its capsule (`TvCapsuleWithPanel`), not at the right edge.
 *
 * **For "Sammlungen" only the count**: that list needs neither filtering nor re-sorting. The grid
 * then shows the collections with "3 Filme" and, without an image of their own, the mosaic.
 */
@Composable
fun TvLibrary(app: SwiftlyApplication, art: String, filter: List<String>, open: (Destination) -> Unit) {
    val state = remember { app.libraries.getOrPut(art) { LibraryState(art, app.store) } }
    val run = rememberCoroutineScope()
    LaunchedEffect(state.sorting, state.filter) { state.load(app.kern) }
    // A filter the panel no longer offers (the watchlist, switched off) falls back to "all".
    LaunchedEffect(filter) { if (state.filter !in filter) state.filterSet("alle") }
    de.paulherter.swiftly.WatchStateChange(app) { state.load(app.kern) }
    val collections = state.listSelected
    val focus = firstFocus(!state.loads || collections)
    val lattice = rememberLazyGridState()
    Box(Modifier.fillMaxSize()) {
        TvGrid(if (collections) emptyList() else state.items, { run.launch { state.loadMore(app.kern) } }, focus, open,
                 loads = state.loads && !collections, withUnderRow = false, lattice = lattice, header = {
            Column(Modifier.padding(top = headerBottom + 14.dp, bottom = 10.dp)) {
                // **A fixed height with and without capsules** (tvOS: `.frame(height: chipHeight)`): "Sammlungen"
                // has no filter and sort, and the row would shift on switching.
                Row(Modifier.height(TvTheme.chipHeight), verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    // **The choice as a capsule, only when there is something to choose.** Library names come from
                    // the server and are shown as they are.
                    if (state.isMenu) {
                        TvCapsuleWithPanel(state.label(state.choice), null,
                                         state.offering.map { Choice(it.value, state.label(it.value)) },
                                         state.choice, categories = state.categories) { new ->
                            if (new != state.choice) {
                                state.select(new)
                                run.launch { state.load(app.kern) }
                            }
                        }
                        // Vertical divider, 2 x 60 % of the chip height on tvOS. Without a filter ("Sammlungen") it
                        // separates nothing and is dropped.
                        if (!collections) Box(Modifier.size(1.dp, TvTheme.chipHeight * 0.6f).background(Theme.margin))
                    }
                    // **Filter and sort as one capsule each with icon, like the two `ValuePill`s on iPhone**, no chip
                    // row anymore. Each names the value and expands the choice under itself; the selected row carries
                    // the accent.
                    if (!collections) {
                        val filterSelection = filter.map { Choice(it, Choices.text(Choices.filter, it)) }
                        TvCapsuleWithPanel(Choices.text(Choices.filter, state.filter), Glyph.Filter,
                                         filterSelection, state.filter) { state.filterSet(it) }
                        TvCapsuleWithPanel(Choices.text(Choices.sortings, state.sorting), Glyph.Sort,
                                         Choices.sortings, state.sorting) { state.sortingSet(it) }
                    }
                    Spacer(Modifier.weight(1f).widthIn(min = 20.dp))
                    // Only the count on the right, as on iPhone.
                    if (state.playlistsSelected) {
                        if (state.playlistList.isNotEmpty())
                            Text(translated("%lld Wiedergabelisten", state.playlistList.size), style = TvTheme.small, color = Theme.fontVeryQuiet)
                    } else if (collections) {
                        if (state.collectionList.isNotEmpty())
                            Text(translated("%lld Sammlungen", state.collectionList.size), style = TvTheme.small, color = Theme.fontVeryQuiet)
                    } else if (state.total > 0) {
                        Text(translated("%lld Titel", state.total), style = TvTheme.small, color = Theme.fontVeryQuiet)
                    }
                }
                if (collections) {
                    // The list is already in memory: "Sammlungen" only appears in the panel if there are any.
                } else if (de.paulherter.swiftly.AccountSwitchTransition.waits) {
                    // No error or empty state while switching accounts.
                } else if (state.disrupted) TvDisruption(app, retry = { run.launch { state.load(app.kern) } })
                else if (!state.loads && state.items.isEmpty()) {
                    if (state.filter == "alle") TvEmpty(translated("Hier ist noch nichts"), translated("Sobald in dieser Bibliothek etwas liegt, taucht es hier auf."),
                        symbol = Glyph.Store, button = translated("Aktualisieren") to { run.launch { state.load(app.kern) } })
                    else TvEmpty(translated("Nichts gefunden"), translated("Unter diesem Filter liegt gerade nichts."),
                        symbol = Glyph.Filter, button = translated("Filter zurücksetzen") to { state.filterSet("alle") })
                }
            }
        }, more = {
            if (state.playlistsSelected) items(state.playlistList.size, key = { "liste" + state.playlistList[it].id }) { i ->
                val s = state.playlistList[i]
                TvPlaylistTile(s, if (i == 0) Modifier.focusRequester(focus) else Modifier) {
                    open(playlistTarget(s.id, s.name, art))
                }
            } else if (collections) items(state.collectionList.size, key = { "sammlung" + state.collectionList[it].id }) { i ->
                val s = state.collectionList[i]
                TvCollectionTile(app, s, art, if (i == 0) Modifier.focusRequester(focus) else Modifier) {
                    open(collectionTarget(s.id, s.name, art))
                }
            }
        })
        // **The letter strip in the right margin** where it means something (switched on, "By name", a
        // grid of titles). The grid's first item is the header, so tile i is item i + 1.
        if (app.settings.alphabet && state.sorting == "name" && !collections && state.letters.size > 1) {
            val current by remember(state) {
                derivedStateOf { state.items.getOrNull(maxOf(0, lattice.firstVisibleItemIndex - 1))?.letter }
            }
            TvAlphabetRail(state.letters, current,
                           Modifier.align(Alignment.TopEnd)
                               .padding(end = (TvTheme.edgePage - TvAlphabetRailWidth) / 2,
                                        top = headerBottom + 70.dp, bottom = 24.dp)) { letter ->
                run.launch { state.jumpTarget(app.kern, letter)?.let { lattice.animateScrollToItem(it + 1) } }
            }
        }
    }
}

/**
 * Mirrors a capsule with `CapsuleStyle` plus `.tafel(unter:)` and `Handlungstafel(selected:)` from
 * `LibraryView` on tvOS: **the panel hangs under its trigger**, at its left edge, 8 dp below
 * (`Handlungstafel.padding` 16 -> 8), 310 wide (620 -> 310). If it would run off the right, it aligns
 * to the trigger's right edge (`Handlungstafel.left`).
 *
 * Rows as in the action panel: an empty circle in front, a filled check mark on the selected one,
 * **in the accent**. A shape step alone does not survive three meters (tvOS comment on `selected`).
 * Background `erhoeht`, no padding around the rows, no header, the page is not dimmed.
 *
 * **Focus**: on opening to the first row, after selection or back to the capsule again. While open
 * it stays inside, the same mechanism as `TvMoreButton`.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun TvCapsuleWithPanel(text: String, symbol: Glyph?, entries: List<Choice>, selected: String,
                             categories: Map<String, String> = emptyMap(), select: (String) -> Unit) {
    var opened by remember { mutableStateOf(false) }
    val capsule = remember { FocusRequester() }
    // `exit = Cancel` also blocks programmatic `requestFocus` to the outside; `sharing` opens the
    // exit exactly for the way back to the capsule.
    val sharing = remember { booleanArrayOf(false) }
    fun close() {
        sharing[0] = true
        runCatching { capsule.requestFocus() }
        opened = false
    }
    val margin = with(LocalDensity.current) { TvTheme.edgePage.roundToPx() }
    val padding = with(LocalDensity.current) { 8.dp.roundToPx() }
    Box {
        TvCapsule(text, Modifier.focusRequester(capsule), symbol = symbol) {
            if (opened) close() else { sharing[0] = false; opened = true }
        }
        if (opened) {
            BackHandler(onBack = { close() })
            val first = remember { FocusRequester() }
            LaunchedEffect(Unit) { delay(TvTheme.focusDeadline); runCatching { first.requestFocus() } }
            val status = remember(margin, padding) {
                object : PopupPositionProvider {
                    override fun calculatePosition(anchorBounds: IntRect, windowSize: IntSize,
                                                   layoutDirection: LayoutDirection, popupContentSize: IntSize): IntOffset {
                        val width = popupContentSize.width
                        val left = if (anchorBounds.left + width <= windowSize.width - margin) anchorBounds.left
                                    else anchorBounds.right - width
                        return IntOffset(left.coerceIn(margin, maxOf(margin, windowSize.width - margin - width)),
                                         anchorBounds.bottom + padding)
                    }
                }
            }
            // **`focusable = true`: the panel is a window of its own** and only then receives keys. With
            // `false`, focus was on its first row but every direction key went to the window below: focus
            // jumped into the grid and nothing in the panel was selectable. Back closes it via
            // `onDismissRequest`.
            Popup(popupPositionProvider = status, onDismissRequest = { close() },
                  properties = PopupProperties(focusable = true)) {
                CompositionLocalProvider(LocalWithinPanel provides true) {
                    Column(Modifier.width(310.dp).clip(RoundedCornerShape(TvTheme.cornerArea)).background(Theme.raised)
                            .heightIn(max = 420.dp).verticalScroll(rememberScrollState())
                            .focusProperties { exit = { if (sharing[0]) FocusRequester.Default else FocusRequester.Cancel } }
                            .focusGroup()) {
                        entries.forEachIndexed { i, e ->
                            categories[e.value]?.let { over ->
                                // The `Handlungstafel` heading: divider, below it the heading in capitals, inset like the row
                                // text.
                                Box(Modifier.padding(horizontal = 16.dp).fillMaxWidth().height(1.dp).background(Theme.line))
                                Text(over.uppercase(), style = Theme.group, color = Theme.fontVeryQuiet,
                                     modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 4.dp))
                            }
                            val an = e.value == selected
                            TvRow(e.text, if (an) Glyph.CheckmarkCircleFilled else Glyph.Ring,
                                    symbolColor = if (an) Theme.accent else Theme.font,
                                    modifier = (if (i == 0) Modifier.focusRequester(first) else Modifier)
                                        .semantics { this.selected = an }) {
                                close()
                                select(e.value)
                            }
                        }
                    }
                }
            }
        }
    }
}

/** Mirrors `WatchlistView` on tvOS: a section of its own, because the TV has no downloads. */
@Composable
fun TvWatchlist(app: SwiftlyApplication, open: (Destination) -> Unit) {
    val state = app.watchlist
    val run = rememberCoroutineScope()
    val genres = remember { selectionRead(Kern.savedGenres()) }
    LaunchedEffect(state.genre, state.sorting) { state.load(app.kern) }
    de.paulherter.swiftly.WatchStateChange(app) { state.load(app.kern) }
    val focus = firstFocus(!state.loads)
    TvGrid(state.items, { run.launch { state.loadMore(app.kern) } }, focus, open, loads = state.loads, withUnderRow = false, header = {
        Column(Modifier.padding(top = headerBottom + 14.dp, bottom = 10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                genres.forEach { g -> TvChip(g.text, state.genre == g.value) { state.genreSet(g.value) } }
                Spacer(Modifier.weight(1f))
                if (state.total > 0) Text(translated("%lld · sortiert nach", state.total), style = TvTheme.small, color = Theme.fontQuiet)
                TvButton(Choices.text(Choices.sortings, state.sorting), Glyph.AngleDown, height = TvTheme.chipHeight + 6.dp, symbolToText = true) {
                    app.sheet.value = SheetRequest(translated("Sortieren"), Choices.sortings, state.sorting) { state.sortingSet(it) }
                }
            }
            // No way-out button here, unlike in Library: tvOS' `WatchlistView.empty` has none either. There is
            // nothing to refresh or reset, only the hint where to add titles.
            if (de.paulherter.swiftly.AccountSwitchTransition.waits) { /* No error or empty state while switching accounts. */ }
            else if (state.disrupted) TvDisruption(app, retry = { run.launch { state.load(app.kern) } })
            else if (!state.loads && state.items.isEmpty()) {
                TvEmpty(translated("Noch nichts gemerkt"),
                    translated("Auf jeder Film- und Serienseite steht „Merkliste“ in der Knopfreihe. Was du dort auswählst, sammelt sich hier."),
                    symbol = Glyph.BookmarkFilled)
            }
        }
    })
}

/**
 * Mirrors `SearchView` on tvOS: **no system search field**, but a field of its own in the header;
 * it searches while typing from two characters. With a remote every typed word is expensive, so
 * the history comes first. Hits from the own server, below them what Seerr knows.
 */
@Composable
fun TvSearch(app: SwiftlyApplication, open: (Destination) -> Unit) {
    val st = app.search
    var historyRaw by remember { mutableStateOf(de.paulherter.swiftly.SearchState.historyRead(app)) }
    val history = remember(historyRaw) { runCatching { JSONArray(Kern.searchHistoryList(historyRaw)).let { a -> (0 until a.length()).map { a.getString(it) } } }.getOrDefault(emptyList()) }
    LaunchedEffect(st.term) { st.searching(app, st.term.trim()) }
    de.paulherter.swiftly.WatchStateChange(app) { if (Kern.searchTermFits(st.term.trim())) st.searching(app, st.term.trim()) }
    val inputField = firstFocus()
    fun remember() { historyRaw = Kern.searchHistoryRemember(st.term, historyRaw); de.paulherter.swiftly.SearchState.historyWrite(app, historyRaw) }

    TvGrid(st.hit, open = open, loads = st.hunts && st.hit.isEmpty(), placeholderRails = 1, header = {
        Column(Modifier.padding(top = headerBottom + 14.dp, bottom = 10.dp)) {
            var inField by remember { mutableStateOf(false) }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                BasicTextField(st.term, { st.term = it }, singleLine = true,
                    textStyle = TvTheme.body.copy(color = Theme.font), cursorBrush = SolidColor(Theme.accent),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search), keyboardActions = KeyboardActions(onSearch = { remember() }),
                    // **Up and Down leave the field, OK brings up the keyboard** (`remoteBarField`): otherwise
                    // one could not get from Search to the tab bar, history or hits.
                    modifier = Modifier.width(460.dp).focusRequester(inputField).onFocusChanged { inField = it.isFocused }
                        .remoteBarField(),
                    decorationBox = { inner ->
                        // **No border, not even when focused**: a search field is a filled capsule, not a drawn outline,
                        // and the light surface is already its focus indicator. `area` instead of `erhoeht`.
                        Row(Modifier.height(44.dp).clip(RoundedCornerShape(TvTheme.corner))
                                .background(if (inField) TvTheme.focusArea else Theme.area)
                                .padding(horizontal = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                            Symbol(Glyph.Magnifier, 15.dp, color = Theme.fontQuiet, strength = Strength.Medium)
                            Spacer(Modifier.width(10.dp))
                            Box(Modifier.weight(1f)) {
                                if (st.term.isEmpty()) Text(translated("Titel, Serie, Person"), style = TvTheme.body, color = Theme.fontVeryQuiet)
                                inner()
                            }
                        }
                    })
                if (st.searched.isNotEmpty() && st.hit.isNotEmpty()) Text(translated("%lld Treffer", st.hit.size), style = TvTheme.small, color = Theme.fontQuiet)
            }
            when {
                st.term.isBlank() && history.isNotEmpty() -> Column(Modifier.padding(top = 20.dp).width(460.dp).clip(RoundedCornerShape(TvTheme.cornerArea)).background(Theme.area).padding(6.dp)) {
                    Text(translated("Zuletzt gesucht"), style = TvTheme.rail,
                         color = Theme.fontQuiet, modifier = Modifier.padding(12.dp))
                    history.forEach { w -> TvRow(w, Glyph.History) { st.term = w } }
                    // As the last row in the card, not as a button beside it, which would be a focus trap.
                    TvRow(translated("Verlauf löschen"), Glyph.Papierkorb) { historyRaw = ""; de.paulherter.swiftly.SearchState.historyWrite(app, "") }
                }
                !Kern.searchTermFits(st.term.trim()) -> Text(translated("Titel, Serie oder Name. Ab zwei Zeichen wird gesucht."),
                                                               style = TvTheme.body, color = Theme.fontQuiet, modifier = Modifier.padding(top = 20.dp))
                // **Failed is not empty**: otherwise Search says "Nichts gefunden" when in truth nobody
                // answered.
                st.disrupted && !de.paulherter.swiftly.AccountSwitchTransition.waits -> TvDisruption(app, retry = { st.term = st.term + " "; st.term = st.term.trim() })
                !st.hunts && st.searched.isNotEmpty() && st.hit.isEmpty() && st.seerr.isEmpty() ->
                    TvEmpty(translated("Nichts gefunden"), translated("Versuch es mit einem anderen Wort."), symbol = Glyph.Magnifier)
            }
        }
    }, more = {
        if (st.seerr.isNotEmpty()) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                Row(Modifier.padding(top = 20.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(translated("Kann angefragt werden"), style = TvTheme.rail, color = Theme.font)
                    // Like `Zaehlmarke` on tvOS: a bare number, not a badge.
                    Text("${st.seerr.size}", style = TvTheme.small, color = Theme.fontVeryQuiet)
                }
            }
            items(st.seerr, key = { "seerr-" + it.key }) { t ->
                TvTile(t.poster, t.title, SeerrMark.shortWord(t.state) ?: t.year?.toString(), opacity = 0.45f) {
                    app.seerrHit[t.key] = t
                    open(Destination(t.key, t.title, "Seerrtitel"))
                }
            }
        }
    })
}

