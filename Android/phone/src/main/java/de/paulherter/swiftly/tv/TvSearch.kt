package de.paulherter.swiftly.tv

import de.paulherter.swiftly.KernRules

import android.app.Activity
import android.content.Intent
import android.speech.RecognizerIntent
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.Crossfade
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.gestures.BringIntoViewSpec
import androidx.compose.foundation.gestures.LocalBringIntoViewSpec
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import de.paulherter.swiftly.shared.Strength
import de.paulherter.swiftly.Destination
import de.paulherter.swiftly.SearchState
import de.paulherter.swiftly.SeerrMark
import de.paulherter.swiftly.SwiftlyApplication
import de.paulherter.swiftly.GridTile
import de.paulherter.swiftly.CountMark
import de.paulherter.swiftly.LoadField
import de.paulherter.swiftly.SeparatorLine
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Motion
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.delay
import org.json.JSONArray

/**
 * **Search: the keyboard on the left, the hits next to it, live.** Mirrors `SearchView` on tvOS; the full
 * reasoning, the focus map and the states are in `Notizen/Mehrserver/TV-SUCHE-ENTWURF.md`.
 *
 * Whoever types a word sees the hits after every letter and confirms nothing. The system keyboard is
 * not used (it covers the results, and Apple TV has nothing like it either): the keys are
 * `TvSearchKeyboard`, laid out by the package, so both TVs type the same way. The mic key hands over to
 * the system's speech input if the device has one.
 *
 * What is shown is decided by `Kern.searchScreen` (package: `SearchScreen`), so both TVs agree and it is
 * tested: history, start, loading, blank, hits, nothing, disrupted.
 */
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class, ExperimentalFoundationApi::class)
@Composable
fun TvSearch(app: SwiftlyApplication, open: (Destination) -> Unit) {
    val st = app.search
    val focus = remember(st) { SearchFocus(st) }
    val scroll = rememberScrollState()
    val density = LocalDensity.current

    var historyRaw by remember { mutableStateOf(SearchState.historyRead(app)) }
    val history = remember(historyRaw) {
        runCatching { JSONArray(KernRules.searchHistoryList(historyRaw)).let { a -> (0 until a.length()).map { a.getString(it) } } }.getOrDefault(emptyList())
    }
    fun historySet(raw: String) { historyRaw = raw; SearchState.historyWrite(app, raw) }

    // An answer has arrived since the page was cleared. After coming back from a title the hits are still
    // in the state, so this starts out true when the last search belongs to the term.
    var answered by remember { mutableStateOf(st.searched.isNotEmpty() && KernRules.searchTermFits(st.term.trim())) }
    // The first answer takes longer than 300 ms. Only then the placeholder shows: before that nothing
    // flickers between two letters.
    var waited by remember { mutableStateOf(false) }
    var attempt by remember { mutableIntStateOf(0) }
    // The next change of the term is searched at once (a press on an earlier search, speech input).
    val immediate = remember { booleanArrayOf(false) }

    // One attempt per keystroke, but only the last counts: a new term cancels this effect, and with it the
    // running request. 250 ms pause, as on tvOS. A page that comes back with the term it already has
    // searched does not search it once more.
    LaunchedEffect(st.term, attempt) {
        val clean = st.term.trim()
        if (!KernRules.searchTermFits(clean)) {
            // Below two characters nothing is searched, and the hits give way to the history.
            st.hit = emptyList(); st.seerr = emptyList(); st.disrupted = false; st.hunts = false; st.searched = ""
            answered = false; waited = false
            return@LaunchedEffect
        }
        if (clean == st.searched && !st.disrupted && !st.hunts) return@LaunchedEffect
        val now = immediate[0]
        immediate[0] = false
        if (!now) delay(250)
        st.searching(app, clean, pause = 0)
        answered = true
    }
    // Watched/watchlist state changed elsewhere: the tile should not show the old state. Hits stay until new ones arrive.
    de.paulherter.swiftly.WatchStateChange(app) {
        val clean = st.term.trim()
        if (KernRules.searchTermFits(clean)) st.searching(app, clean, pause = 0)
    }
    // The placeholder only after 300 ms, and only while nothing at all is on screen.
    val empty = st.hit.isEmpty() && st.seerr.isEmpty()
    LaunchedEffect(st.hunts, empty, answered) {
        waited = false
        if (st.hunts && empty && !answered) { delay(300); waited = true }
    }

    val disrupted = st.disrupted && !de.paulherter.swiftly.AccountSwitchTransition.waits
    val screen = KernRules.searchScreen(st.term, history.size.toLong(), !empty, answered, disrupted, waited)

    val splitSeries = st.hit.filter { it.type == "Series" }
    val splitFilms = st.hit.filter { it.type == "Movie" }
    val titles = KernRules.searchTitlesShown(splitSeries.size.toLong(), splitFilms.size.toLong(), st.seerr.size.toLong())
    val hitIds = (splitSeries + splitFilms).map { it.id }
    val landing: FocusRequester? = when (screen) {
        "hits" -> (focus.lastHit?.takeIf { it in hitIds } ?: hitIds.firstOrNull())?.let { focus.hit(it) }
            ?: st.seerr.firstOrNull()?.let { focus.hit("seerr-" + it.key) }
        "history", "nothing" -> focus.recent
        else -> null
    }

    // MARK: Speech
    val context = LocalContext.current
    val speech = remember { Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM) }
    // Without anything on the device that answers, the key is not drawn and "delete" takes all six columns.
    val canSpeak = remember { context.packageManager.resolveActivity(speech, 0) != null }
    var speaking by remember { mutableStateOf(false) }
    val speechResult = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        speaking = false
        if (result.resultCode == Activity.RESULT_OK) {
            result.data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)?.firstOrNull()?.trim()?.takeIf { it.isNotEmpty() }?.let {
                immediate[0] = true
                st.term = it
            }
        }
        runCatching { focus.key("speak").requestFocus() }
    }

    // MARK: Focus
    // Whoever goes to "Search" wants to type, not first navigate to a key; coming back from a title, focus
    // stands on its tile again.
    LaunchedEffect(Unit) {
        delay(2 * TvTheme.focusDeadline)
        val tile = focus.lastHit?.takeIf { it in hitIds }
        if (tile != null && runCatching { focus.hit(tile).requestFocus(); true }.getOrDefault(false)) return@LaunchedEffect
        focus.toKeys()
    }
    // 0 nowhere yet, 1 keyboard, 2 results: remembered is whoever leaves the keyboard with hits. Search runs
    // while typing, a submit like on the phone never happens: one types, sees the hits and goes right. That is
    // the moment something was searched for. "Ga", "Gam" on the way do not count.
    val zone = remember { intArrayOf(0) }
    var inResults by remember { mutableStateOf(false) }
    LaunchedEffect(hitIds) {
        // A new list while typing starts at the top. Standing in the hits it stays where the tile is.
        if (!inResults && scroll.value > 0) scroll.animateScrollTo(0, Motion.change())
    }
    // Back in the hits goes back to the keyboard, not to "Start": every letter has cost work with the
    // remote, and Back must not throw them away. In the keyboard itself the rule of all pages holds
    // (`TvMain`), because this handler only runs while focus stands in the results.
    BackHandler(enabled = inResults) {
        focus.toKeys()
    }
    LaunchedEffect(inResults) { if (!inResults && scroll.value > 0) scroll.animateScrollTo(0, Motion.change()) }

    val reserve = with(density) { (headerBottom + 14.dp + TvTheme.titleSpacing + 23.dp).toPx() }
    val spec = remember(reserve) { SearchBringIntoView(reserve, with(density) { 40.dp.toPx() }) }

    Box(Modifier.fillMaxSize()) {
        TvGlow(app, scrolled = { scroll.value / density.density })
        Row(Modifier.fillMaxSize().padding(start = TvTheme.edgePage), horizontalArrangement = Arrangement.spacedBy(SearchLayout.historyLeft - TvTheme.edgePage - SearchLayout.keyboardWidth)) {
            // Design: keyboard card 80..540 pt, hits and history from 620 pt.
            TvSearchKeyboard(st.term, { st.term = it }, focus, speaking,
                speak = if (canSpeak) ({
                    speaking = true
                    runCatching { speechResult.launch(speech) }.onFailure { speaking = false }
                }) else null,
                modifier = Modifier.padding(top = headerBottom + 14.dp)
                    // Down from the bar and Left from the hits land on the last key, not on whichever
                    // key lies beside the tile.
                    .focusProperties { enter = { focus.key(focus.lastKey) } }
                    .onFocusChanged { if (it.hasFocus) zone[0] = 1 }
                    .focusGroup())
            CompositionLocalProvider(LocalBringIntoViewSpec provides spec) {
                Column(Modifier.width(SearchLayout.resultsWidth).fillMaxHeight()
                        .focusProperties {
                            enter = { landing ?: FocusRequester.Default }
                            exit = { dir -> if (dir == androidx.compose.ui.focus.FocusDirection.Left) focus.key(focus.lastKey) else FocusRequester.Default }
                        }
                        .onFocusChanged {
                            inResults = it.hasFocus
                            if (it.hasFocus) {
                                if (zone[0] == 1 && KernRules.searchTermFits(st.term.trim()) && st.hit.isNotEmpty()) {
                                    historySet(KernRules.searchHistoryRemember(st.term, historyRaw))
                                }
                                zone[0] = 2
                            }
                        }
                        .focusGroup()
                        .verticalScroll(scroll)
                        .padding(top = headerBottom + 14.dp, bottom = 40.dp)) {
                    Crossfade(screen, animationSpec = Motion.reveal(), label = "suche") { which ->
                        when (which) {
                            "blank" -> Box(Modifier.height(1.dp))
                            "loading" -> Loading()
                            "history" -> Recent(history, focus, onPick = { w ->
                                historySet(KernRules.searchHistoryRemember(w, historyRaw))
                                immediate[0] = true
                                st.term = w
                                focus.toKeys()
                            }, onClear = { historySet(""); focus.toKeys() })
                            "start" -> Note()
                            "hits" -> Hits(st, splitSeries, splitFilms, titles, focus, open)
                            "nothing" -> Column(verticalArrangement = Arrangement.spacedBy(TvSpec.searchGroupGap)) {
                                // The way out is the keyboard next to it and the history below. The earlier
                                // "try again" button is gone: the same word searched again finds nothing else.
                                TvEmpty(translated("Nichts gefunden zu „%@“", shortened(st.term)),
                                        translated("Auf deinem Server steht dazu nichts. Manchmal ist es nur ein Buchstabe."),
                                        symbol = Glyph.Magnifier, top = 35.dp)
                                if (history.isNotEmpty()) Recent(history, focus, onPick = { w ->
                                    historySet(KernRules.searchHistoryRemember(w, historyRaw))
                                    immediate[0] = true
                                    st.term = w
                                    focus.toKeys()
                                }, onClear = { historySet(""); focus.toKeys() })
                            }
                            // Failed is not "nothing found": the server did not answer.
                            else -> TvDisruption(app, top = 35.dp, retry = { attempt++ })
                        }
                    }
                }
            }
        }
    }
}

/** Long words in the middle, so the head of "Nothing found" stays on two lines. */
private fun shortened(word: String): String {
    val clean = word.trim()
    return if (clean.length > 32) clean.take(14) + "…" + clean.takeLast(14) else clean
}

/** A centred symbol with one quiet sentence, in the column of the hits. */
@Composable
private fun Note() {
    Column(Modifier.width(SearchLayout.resultsWidth).padding(top = 120.dp), horizontalAlignment = Alignment.CenterHorizontally,
           verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Symbol(Glyph.Magnifier, 44.dp, color = Theme.fontVeryQuiet)
        Text(translated("Titel, Serie oder Name. Ab zwei Zeichen wird gesucht."), style = TvTheme.body, color = Theme.fontVeryQuiet,
             textAlign = TextAlign.Center)
    }
}

/** No spinner: the grid keeps its shape. */
@Composable
private fun Loading() {
    Column(verticalArrangement = Arrangement.spacedBy(TvTheme.titleSpacing)) {
        LoadField(Modifier.size(150.dp, 15.dp), TvTheme.cornerBar)
        Row(horizontalArrangement = Arrangement.spacedBy(TvTheme.gridColumn)) {
            repeat(TvSpec.searchColumns) { TvTilePlaceholder() }
        }
    }
}

/**
 * What was searched for last: a card, one row per term, like on the phone. A press puts the word into
 * the field and searches at once. "Clear history" is the last row, not a button beside the card, which
 * would be a focus trap.
 */
@Composable
private fun Recent(history: List<String>, focus: SearchFocus, onPick: (String) -> Unit, onClear: () -> Unit) {
    // Design: heading 44/700 on the bare background, 24 pt above the group; rows are settings rows (84 pt,
    // 40 pt symbol in a 52 pt column, white focus surface over the group), the card is `groupsArea`.
    Column(Modifier.width(SearchLayout.historyWidth)) {
        Text(translated("Zuletzt gesucht"), style = TvTheme.rail, color = Theme.font, modifier = Modifier.padding(bottom = 12.dp))
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(TvTheme.cornerArea)).background(Theme.groupsArea).padding(horizontal = 13.dp)) {
            history.forEachIndexed { i, w ->
                HistoryRow(w, Glyph.History, if (i == 0) Modifier.focusRequester(focus.recent) else Modifier) { onPick(w) }
                SeparatorLine()
            }
            HistoryRow(translated("Verlauf löschen"), Glyph.Papierkorb, if (history.isEmpty()) Modifier.focusRequester(focus.recent) else Modifier) { onClear() }
        }
    }
}

/** A history row: symbol in its column, then the text; the settings look (`TvSettingsRow`), symbol quiet at rest. */
@Composable
private fun HistoryRow(text: String, symbol: Glyph, modifier: Modifier, perform: () -> Unit) {
    TvSettingsRow(modifier, perform = perform) { focus ->
        Box(Modifier.width(TvSpec.rowSymbolColumn), contentAlignment = Alignment.Center) {
            Symbol(symbol, 20.dp, color = if (focus) Theme.reason else Theme.fontVeryQuiet, strength = Strength.Medium)
        }
        Text(text, style = TvTheme.button.copy(fontSize = 15.sp, fontWeight = FontWeight.Medium),
             color = if (focus) Theme.reason else Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis,
             modifier = Modifier.padding(start = 14.dp))
    }
}

/** The blocks: series, films, what Seerr knows. Titles only when more than one block stands there. */
@Composable
private fun Hits(st: SearchState, series: List<GridTile>, films: List<GridTile>, titles: Boolean,
                 focus: SearchFocus, open: (Destination) -> Unit) {
    val app = LocalContext.current.applicationContext as SwiftlyApplication
    Column(verticalArrangement = Arrangement.spacedBy(TvTheme.railsSpacing)) {
        Block(translated("Serien"), series.size, titles) { Tiles(series) { HitTile(it, focus, open) } }
        Block(translated("Filme"), films.size, titles) { Tiles(films) { HitTile(it, focus, open) } }
        Block(translated("Kann angefragt werden"), st.seerr.size, titles) {
            Tiles(st.seerr) { t ->
                TvTile(t.poster, t.title, SeerrMark.shortWord(t.state) ?: t.year?.toString(), opacity = 0.45f,
                       modifier = Modifier.focusRequester(focus.hit("seerr-" + t.key)),
                       focusChanged = { if (it) focus.lastHit = "seerr-" + t.key }) {
                    app.seerrHit[t.key] = t
                    open(Destination(t.key, t.title, "Seerrtitel"))
                }
            }
        }
    }
}

@Composable
private fun Block(title: String, count: Int, titled: Boolean, tiles: @Composable () -> Unit) {
    if (count == 0) return
    Column(verticalArrangement = Arrangement.spacedBy(TvTheme.titleSpacing)) {
        if (titled) Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(title, style = TvTheme.rail, color = Theme.font)
            CountMark(count)
        }
        tiles()
    }
}

/** `searchColumns` posters per row. */
@Composable
private fun <T> Tiles(items: List<T>, tile: @Composable (T) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(TvTheme.latticeRow - 16.dp)) {
        items.chunked(TvSpec.searchColumns).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(TvTheme.gridColumn)) { row.forEach { tile(it) } }
        }
    }
}

@Composable
private fun HitTile(k: GridTile, focus: SearchFocus, open: (Destination) -> Unit) {
    val menu = de.paulherter.swiftly.LocalTileMenu.current
    TvTile(k.poster, k.title, k.subline, mark = k.mark, markCount = k.markCount,
           lengthy = menu?.let { m -> { m(de.paulherter.swiftly.TileMenuRequest(k.id, k.title, k.type, k.poster, false, k.subline)) } },
           modifier = Modifier.focusRequester(focus.hit(k.id)),
           focusChanged = { if (it) focus.lastHit = k.id }) {
        open(Destination(k.id, k.title, k.type))
    }
}

/**
 * Scrolls the hits only as far as needed, but keeps the block title above a first-row tile (and the top
 * bar's strip) in view: `reserve` is the room that must stay free above the focused tile. Without it a
 * tile in the first row could scroll to the very top and leave its title under the bar (tvOS: the safe-area
 * inset of the results).
 */
@OptIn(ExperimentalFoundationApi::class)
private class SearchBringIntoView(private val reserve: Float, private val below: Float) : BringIntoViewSpec {
    override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float): Float {
        if (containerSize <= 0f) return 0f
        if (offset < reserve) return offset - reserve
        val bottom = containerSize - below
        if (offset + size > bottom) return minOf(offset + size - bottom, offset - reserve)
        return 0f
    }
}
