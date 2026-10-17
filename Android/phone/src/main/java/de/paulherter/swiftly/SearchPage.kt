package de.paulherter.swiftly

import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Strength
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.EaseOut
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyGridScope
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.shape.CircleShape
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
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.shared.Motion
import de.paulherter.swiftly.shared.Theme
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.expandHorizontally
import androidx.compose.animation.shrinkHorizontally
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.onSizeChanged
import de.paulherter.swiftly.shared.translated
import de.paulherter.swiftly.core.Kern
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.future.await
import kotlinx.coroutines.withContext
import org.json.JSONArray

/**
 * **Search state lives in the app**, not in the page: leaving the section and coming back
 * finds term, results and search state as left (iOS, `active`).
 */
class SearchState {
    var term by mutableStateOf("")
    var hit by mutableStateOf<List<GridTile>>(emptyList())
    /** What Seerr knows and the own server does not, only once the own server has answered. */
    var seerr by mutableStateOf<List<SeerrTile>>(emptyList())
    var hunts by mutableStateOf(false)
    /**
     * **The server did not answer.** The error was swallowed and the empty result list then said
     * "No results for …", so search lied on every network error. Mirrors `SearchView`, which sets
     * the `Leerzustand` with the server formula for this.
     */
    var disrupted by mutableStateOf(false)
    /** In search state; goes back only with the cross next to the field, not with the keyboard. */
    var searchMode by mutableStateOf(false)
    /** A second tap on the tab opens the keyboard (`tabStillTimes`). */
    var anotherTime by mutableIntStateOf(0)
    internal var searched = ""

    /** Term, results and failure belong to the account that was switched (`SearchView`, `onChange(of: accountSwitch)`). */
    fun forget() {
        term = ""; hit = emptyList(); seerr = emptyList()
        hunts = false; disrupted = false; searchMode = false; searched = ""
    }

    companion object {
        /** **History belongs to the account, not the device.** The active account takes over the old shared entry on first use. */
        fun historyKey(app: SwiftlyApplication): String =
            Kern.searchHistoryKeyAccount(app.store.accounts?.let { Kern.bundleActiveId(it) }.orEmpty())

        fun historyRead(app: SwiftlyApplication): String {
            val key = historyKey(app)
            if (key != Kern.searchHistoryKey() && app.store.rememberValue(key) == null) {
                app.store.remember(key, app.store.rememberValue(Kern.searchHistoryKey()).orEmpty())
            }
            return app.store.rememberValue(key).orEmpty()
        }

        fun historyWrite(app: SwiftlyApplication, raw: String) = app.store.remember(historyKey(app), raw)
    }

    /** Search like `SearchView.searching`; phone and TV both call this. */
    suspend fun searching(app: SwiftlyApplication, clean: String) {
            if (!Kern.searchTermFits(clean)) { hit = emptyList(); seerr = emptyList(); disrupted = false; hunts = false; searched = clean; return }
            hunts = true
            disrupted = false
            delay(300)
            try {
                val json = withContext(Dispatchers.IO) { app.kern.search(clean).await() }
                hit = JSONArray(json).let { a -> (0 until a.length()).map { gridTileRead(a.getJSONObject(it)) } }
                searched = clean
                // **Side by side, not one after the other** for the user: the own results are already there.
                // **Seerr is a bonus:** if it fails, the own results stay; before, a Seerr error threw them
                // away too and showed the whole failure state.
                seerr = if (!app.seerrConnected.value) emptyList() else try {
                    seerrTilesRead(withContext(Dispatchers.IO) { app.kern.seerrSearch(clean).await() })
                } catch (e: CancellationException) { throw e } catch (_: Exception) { emptyList() }
            } catch (e: CancellationException) { throw e } catch (_: Exception) {
                disrupted = true
                hit = emptyList()
                seerr = emptyList()
            }
            hunts = false
    }
}

/**
 * Mirrors `SearchView`, narrow variant.
 * - **The tab does not open the keyboard.** Otherwise the page's own content (history, hint)
 *   would never be seen; only a second tap on the tab brings it up.
 * - **Search state is not the keyboard:** whoever closes it after typing wants to read the
 *   results; if the page then jumped back, everything would slip away under the thumb.
 * - A term is remembered on submit, not on every keystroke.
 * - Minimum length, history and result line live in the package.
 */
@Composable
fun SuchPage(app: SwiftlyApplication, open: (Destination) -> Unit) {
    val st = app.search
    val focus = remember { FocusRequester() }
    val focusManager = LocalFocusManager.current
    var historyRaw by remember { mutableStateOf(SearchState.historyRead(app)) }
    val history = remember(historyRaw) {
        JSONArray(Kern.searchHistoryList(historyRaw)).let { a -> (0 until a.length()).map { a.getString(it) } }
    }
    fun remember() {
        historyRaw = Kern.searchHistoryRemember(st.term, historyRaw)
        SearchState.historyWrite(app, historyRaw)
    }

    // The second tap on the tab; only new taps count, not the state on return.
    var watched by rememberSaveable { mutableIntStateOf(st.anotherTime) }
    LaunchedEffect(st.anotherTime) { if (st.anotherTime != watched) { watched = st.anotherTime; focus.requestFocus() } }

    // Delayed, so not every keystroke fires a request.
    // `redo` is the button in the failure hint: same term, new attempt; comparing with
    // `gesucht` alone would drop it.
    var redo by remember { mutableIntStateOf(0) }
    LaunchedEffect(st.term, redo) {
        val clean = st.term.trim()
        if (clean == st.searched && !st.disrupted) return@LaunchedEffect
        st.searching(app, clean)
    }

    // Ticks and bars of the results: search again after a watch-state change; the results stay until the new ones arrive.
    WatchStateChange(app) {
        val clean = st.term.trim()
        if (Kern.searchTermFits(clean)) st.searching(app, clean)
    }

    val grid = rememberLazyGridState()
    // Scrolling closes the keyboard, the counterpart to tapping empty space on iOS.
    LaunchedEffect(grid) { snapshotFlow { grid.isScrollInProgress }.collect { if (it) focusManager.clearFocus() } }

    // **The motion sits on the whole column, not the field**, or a dark edge jumped.
    // Only opacity and offset, no height animation: that rebuilt the grid below on every frame.
    // The header stays in the layout until fully faded out; the rest jumps up by its height meanwhile
    // and is longer by exactly that height.
    val headerDistance = remember { Animatable(if (st.searchMode) 1f else 0f) }
    LaunchedEffect(st.searchMode) { headerDistance.animateTo(if (st.searchMode) 1f else 0f, Motion.sheet()) }
    val headerPresent by remember { derivedStateOf { headerDistance.value < 1f } }
    var headerHeight by remember { mutableIntStateOf(0) }
    Column(Modifier.fillMaxSize().background(Theme.reason).statusBarsPadding()) {
        if (headerPresent) {
            // `BlurHeader` without offset: search does not scroll under it. Title and symbol centred.
            Row(Modifier.fillMaxWidth().onSizeChanged { headerHeight = it.height }.graphicsLayer { alpha = 1f - headerDistance.value }
                    .padding(horizontal = Theme.edgeSpacing).padding(bottom = 12.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Text(translated("Suchen"), style = Theme.titleLarge, color = Theme.font,
                     modifier = Modifier.weight(1f))
                HeaderTargets(app, open)
            }
        }
        Column(Modifier.fillMaxWidth().weight(1f)
            .layout { measurable, limits ->
                val more = if (headerPresent) headerHeight else 0
                val slot = measurable.measure(limits.copy(minHeight = limits.maxHeight + more, maxHeight = limits.maxHeight + more))
                layout(slot.width, limits.maxHeight) { slot.place(0, 0) }
            }
            .graphicsLayer { translationY = if (headerPresent) -headerHeight * headerDistance.value else 0f }) {

        Row(Modifier.fillMaxWidth().padding(horizontal = Theme.edgeSpacing)
                .padding(top = if (st.searchMode) 8.dp else 4.dp, bottom = 16.dp),
            verticalAlignment = Alignment.CenterVertically) {
            SearchField(st.term, { st.term = it }, focus, Modifier.weight(1f),
                     atTap = { inside -> if (inside) st.searchMode = true }, submit = ::remember)
            // **The way out sits next to the field, not in it:** the cross in the field only clears.
            // The row opens room for it with a spring instead of making the field jump; it fades in
            // afterwards and leaves first, or it collided with the profile image.
            AnimatedVisibility(st.searchMode,
                enter = expandHorizontally(Motion.sheet(), expandFrom = Alignment.Start) +
                        fadeIn(tween(150, delayMillis = 100, easing = Motion.soft)),
                exit = shrinkHorizontally(Motion.sheet(), shrinkTowards = Alignment.Start) +
                       fadeOut(tween(90, easing = Motion.soft))) {
                Box(Modifier.padding(start = 12.dp).size(44.dp).tapOn { st.term = ""; focusManager.clearFocus(); st.searchMode = false },
                    contentAlignment = Alignment.Center) {
                    Box(Modifier.size(36.dp).clip(CircleShape).background(Theme.area), contentAlignment = Alignment.Center) {
                        Symbol(Glyph.Cross, 15.dp, color = Theme.fontQuiet, strength = Strength.Semibold, description = translated("Suche schließen"))
                    }
                }
            }
        }

        BoxWithConstraints(Modifier.fillMaxSize()) {
            val count = Theme.columns((maxWidth - Theme.edgeSpacing * 2).value)
            val clean = st.term.trim()
            LazyVerticalGrid(GridCells.Fixed(count), state = grid,
                contentPadding = PaddingValues(start = Theme.edgeSpacing, end = Theme.edgeSpacing, bottom = 12.dp),
                horizontalArrangement = Arrangement.spacedBy(Theme.tileSpacing),
                modifier = Modifier.fillMaxSize().areaContent()) {
                when {
                    clean.isEmpty() && history.isEmpty() -> whole("hinweis") { EmptyHint() }
                    clean.isEmpty() -> whole("verlauf") {
                        History(history, erase = { historyRaw = ""; SearchState.historyWrite(app, "") }) { word ->
                            // Fills the field and searches; the keyboard stays closed.
                            st.term = word
                            focusManager.clearFocus()
                        }
                    }
                    // **No ring:** if results are already there, they stay until new ones arrive.
                    st.hunts && st.hit.isEmpty() && st.seerr.isEmpty() -> {
                        whole("abstand") { Spacer(Modifier.height(12.dp)) }
                        items(count * 2, key = { "platzhalter$it" }) { Box(Modifier.padding(bottom = 20.dp)) { TilePlaceholder() } }
                    }
                    // **Failed is not empty.** Before, a network error also showed "No results for …", a
                    // statement about the catalog nobody had checked.
                    st.disrupted && st.hit.isEmpty() && st.seerr.isEmpty() && !AccountSwitchTransition.waits -> whole("gestoert") {
                        // The full server formula, as on every other page; 24 above.
                        Box(Modifier.fillMaxWidth().padding(top = 24.dp).height(360.dp)) {
                            EmptyState(Glyph.ServerRoute, translated("Server ist abgetaucht"),
                                translated("%@ antwortet nicht. Läuft er noch, oder hängt das WLAN?", app.serverAddress()),
                                primaryButton = translated("Erneut versuchen") to { redo++ })
                        }
                    }
                    // Both empty, not only the library: an empty state, history below.
                    st.hit.isEmpty() && st.seerr.isEmpty() -> {
                        whole("keine") {
                            Box(Modifier.fillMaxWidth().padding(top = 24.dp).height(300.dp)) {
                                EmptyState(Glyph.Magnifier, translated("Nichts gefunden zu „%@“", clean),
                                    translated("Auf deinem Server steht dazu nichts. Manchmal ist es nur ein Buchstabe."))
                            }
                        }
                        if (history.isNotEmpty()) whole("verlauf-leer") {
                            History(history, erase = { historyRaw = ""; SearchState.historyWrite(app, "") }) { word ->
                                st.term = word
                                focusManager.clearFocus()
                            }
                        }
                    }
                    // **Grouped by kind, as in Plex.** Episodes are not even requested from the server.
                    else -> {
                    // Without Seerr no heading; it would announce a block that never follows.
                    if (st.seerr.isNotEmpty() && st.hit.isNotEmpty()) whole("block-server") { BlockTitle(translated("Auf deinem Server"), st.hit.size) }
                    listOf(
                        "Serien" to { k: GridTile -> k.type == "Series" },
                        "Filme" to { k: GridTile -> k.type == "Movie" },
                        "Folgen" to { k: GridTile -> k.type == "Episode" },
                        "Weiteres" to { k: GridTile -> k.type !in setOf("Series", "Movie", "Episode") },
                    ).filter { (_, fits) -> st.hit.any(fits) }.forEachIndexed { spot, (title, fits) ->
                        val group = st.hit.filter(fits)
                        val firstGroup = spot == 0 && !(st.seerr.isNotEmpty() && st.hit.isNotEmpty())
                        if (group.isNotEmpty()) {
                            whole("titel-$title") {
                                // List row, not `Theme.group`: tiles follow below, and an all-caps row would be a third style.
                                // 14 above: for all but the first group 10 are already below the grid above
                                // (20 row spacing instead of 10 grid end).
                                Text(translated(title), style = Theme.listTitle,
                                     color = Theme.fontQuiet, modifier = Modifier.padding(top = if (firstGroup) 14.dp else 4.dp, bottom = 6.dp))
                            }
                            // Every result leads to its page; nothing plays directly from search.
                            items(group, key = { it.id }) { k ->
                                // 20 as in Library, Watchlist and Genre; narrow search was the only one at 16.
                                GridTileView(k, Modifier.padding(bottom = 20.dp)) { open(Destination(k.id, k.title, k.type)) }
                            }
                        }
                    }
                    if (st.seerr.isNotEmpty()) {
                        whole("block-seerr") { BlockTitle(translated("Über Seerr anfragen"), st.seerr.size, Modifier.padding(top = 8.dp)) }
                        items(st.seerr, key = { "seerr-" + it.key }) { t ->
                            SeerrTileView(t, Modifier.padding(bottom = 20.dp)) {
                                app.seerrHit[t.key] = t
                                open(Destination(t.key, t.title, "Seerrtitel"))
                            }
                        }
                    }
                    }
                }
            }
        }
        }
    }
}

private fun LazyGridScope.whole(key: String, content: @Composable () -> Unit) =
    item(key = key, span = { GridItemSpan(maxLineSpan) }) { content() }

/** Mirrors `SearchField` in `Style.swift`: 44 high, magnifier, placeholder, cross only with text. */
@Composable
private fun SearchField(text: String, change: (String) -> Unit, focus: FocusRequester, modifier: Modifier,
                     atTap: (Boolean) -> Unit, submit: () -> Unit) {
    val keyboard = androidx.compose.ui.platform.LocalSoftwareKeyboardController.current
    // 48 as every other field; it was the only one at 44.
    Row(modifier.heightIn(min = Theme.buttonHeight).clip(RoundedCornerShape(Theme.cornerField)).background(Theme.area)
            .clickable(remember { MutableInteractionSource() }, null) { focus.requestFocus() }
            .padding(start = 14.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Symbol(Glyph.Magnifier, 17.dp, color = Theme.fontVeryQuiet)
        Box(Modifier.weight(1f)) {
            if (text.isEmpty()) Text(translated("Filme, Serien, Folgen"), style = Theme.body, color = Theme.fontVeryQuiet)
            BasicTextField(value = text, onValueChange = change, singleLine = true,
                textStyle = Theme.body.copy(color = Theme.font), cursorBrush = SolidColor(Theme.accent),
                keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, imeAction = ImeAction.Search),
                // As iOS: Search submits **and** closes the keyboard, since the results are already there.
                keyboardActions = KeyboardActions(onSearch = { submit(); keyboard?.hide() }),
                modifier = Modifier.fillMaxWidth().focusRequester(focus).onFocusChanged { atTap(it.isFocused) })
        }
        if (text.isNotEmpty()) {
            // `xmark.circle.fill` with palette: circle `schriftSehrLeise`, cross punched out in `area`.
            Box(Modifier.size(44.dp).tapOn { change("") }, contentAlignment = Alignment.Center) {
                Symbol(Glyph.CrossCircleFilled, 17.dp, color = Theme.fontVeryQuiet, description = translated("Eingabe löschen"))
            }
        } else Spacer(Modifier.width(14.dp))
    }
}

@Composable
private fun EmptyHint() {
    Column(Modifier.fillMaxWidth().padding(top = 70.dp), horizontalAlignment = Alignment.CenterHorizontally,
           verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Symbol(Glyph.Magnifier, 44.dp, color = Theme.fontVeryQuiet)
        Text(translated("Filme, Serien und Folgen durchsuchen"), style = Theme.body, color = Theme.fontQuiet)
    }
}

/** "Recent searches": a tap searches again; "Delete" clears the whole history. */
@Composable
private fun History(words: List<String>, erase: () -> Unit, select: (String) -> Unit) {
    Column {
        Row(Modifier.fillMaxWidth().padding(top = 18.dp), verticalAlignment = Alignment.Bottom) {
            // Heading: 20 semibold in normal case, `schriftLeise`. A search heading has no other role
            // than a settings heading.
            Text(translated("Zuletzt gesucht"),
                 style = Theme.rail,
                 color = Theme.fontQuiet, modifier = Modifier.weight(1f))
            Text(translated("Löschen"), style = Theme.tile, color = Theme.fontVeryQuiet,
                 modifier = Modifier.tapOn(erase))
        }
        words.forEachIndexed { i, word ->
            if (i > 0) Box(Modifier.padding(start = 34.dp).fillMaxWidth().height(1.dp).background(Theme.line))
            Row(Modifier.fillMaxWidth().heightIn(min = 44.dp).pressRow { select(word) },
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(Modifier.width(20.dp), contentAlignment = Alignment.Center) { Symbol(Glyph.History, 15.dp, color = Theme.fontVeryQuiet) }
                Text(word, style = Theme.listTitle, color = Theme.font,
                     maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}
