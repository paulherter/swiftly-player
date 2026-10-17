package de.paulherter.swiftly.tv

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.LocalBringIntoViewSpec
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import de.paulherter.swiftly.*
import de.paulherter.swiftly.shared.Strength
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.launch

// MARK: Collections on TV (mirrors `LibraryView.swift`, `TitleRails.swift` on tvOS)

/**
 * A collection's tile in the grid: `TileContent` with `subline` ("3 films") and `substitute`:
 * without its own image, the mosaic of the first posters (`Sammlungsmosaik`, posters at half
 * tile size as on tvOS).
 */
@Composable
fun TvCollectionTile(app: SwiftlyApplication, s: CollectionTile, art: String, modifier: Modifier = Modifier, perform: () -> Unit) {
    TvTile(s.poster, s.name, collectionCount(art, s.count), modifier = modifier,
             substitute = if (s.poster == null) ({
                 CollectionMosaic(app, s.id, art, 300, Modifier.fillMaxSize(), corner = TvTheme.cornerTile, symbolText = false)
             }) else null, perform = perform)
}

/**
 * Mirrors `LibraryView(collection:)` on tvOS. **The collection page is a library page**, as on
 * the phone: name, filter and sort order, grid; sorted by year ascending, none of it remembered.
 * The name sits above, so the page starts like the genre page.
 */
@Composable
fun TvCollection(app: SwiftlyApplication, target: Destination, open: (Destination) -> Unit) {
    val state = remember(target.id, target.role) { CollectionState(target.id, target.role) }
    val run = rememberCoroutineScope()
    LaunchedEffect(state, state.sorting, state.filter) { state.load(app.kern) }
    de.paulherter.swiftly.WatchStateChange(app) { state.load(app.kern) }
    val focus = firstFocus(!state.loads)
    Box(Modifier.fillMaxSize().background(Theme.reason)) {
        TvGrid(state.items, { run.launch { state.loadMore(app.kern) } }, focus, open, loads = state.loads, withUnderRow = false, header = {
            Column(Modifier.padding(bottom = 10.dp)) {
                // The name comes from the server and is not translated, like the genre page title.
                Text(target.name, style = TvTheme.rail, color = Theme.font, maxLines = 1,
                     modifier = Modifier.padding(top = 48.dp, bottom = TvTheme.titleSpacing))
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    state.filterSelection.forEach { f -> TvChip(Choices.text(Choices.filter, f), state.filter == f) { state.filter = f } }
                    Spacer(Modifier.weight(1f))
                    if (state.total > 0) Text(translated("%lld · sortiert nach", state.total), style = TvTheme.small, color = Theme.fontQuiet)
                    TvCapsule(Choices.text(Choices.sortings, state.sorting)) {
                        app.sheet.value = SheetRequest(translated("Sortieren"), Choices.sortings, state.sorting) { state.sorting = it }
                    }
                }
                if (state.disrupted) TvDisruption(app, retry = { run.launch { state.load(app.kern) } })
                else if (!state.loads && state.items.isEmpty()) {
                    if (state.filter == "alle") TvEmpty(translated("Hier ist noch nichts"), translated("Sobald in dieser Sammlung etwas liegt, taucht es hier auf."),
                        symbol = Glyph.Store, button = translated("Aktualisieren") to { run.launch { state.load(app.kern) } })
                    else TvEmpty(translated("Nichts gefunden"), translated("Unter diesem Filter liegt gerade nichts."),
                        symbol = Glyph.Filter, button = translated("Filter zurücksetzen") to { state.filter = "alle" })
                }
            }
        })
    }
}

/**
 * Mirrors `Sammlungsreihe` in `TitleRails.swift`: "Part of the collection" on the film page,
 * above "Similar films". **The way to the collection page is a capsule next to the heading:** on
 * TV a heading is not a focus target, and a path focus cannot reach is none. The capsule carries
 * the collection's name and the right arrow (`CapsuleStyle(arrow:)`).
 * At most two rows, without the open title; no collection, no row.
 * `abschnitt`: the per-row modifier from the page (fade-in, section-wise scrolling).
 * **Loading happens on the film page, not here** (`collectionRailsLoad`), as on iOS: the row
 * fetched its titles itself and pushed into the page later than everything else.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun TvCollectionRail(rails: List<CollectionRailsData>, open: (Destination) -> Unit, segment: (Int) -> Modifier = { Modifier }) {
    rails.forEachIndexed { i, rail ->
        Column(segment(i).padding(top = TvTheme.railsSpacing - TvTheme.railsPadding)) {
            Row(Modifier.padding(start = TvTheme.edgePage, bottom = TvTheme.titleSpacing - TvTheme.railsPadding),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(translated("Teil der Sammlung"), style = TvTheme.rail, color = Theme.font, maxLines = 1)
                TvCapsule(rail.name, arrow = Glyph.AngleRight) { open(collectionTarget(rail.id, rail.name, rail.art)) }
            }
            CompositionLocalProvider(LocalBringIntoViewSpec provides TvRailsBringIntoView) {
                LazyRow(contentPadding = PaddingValues(horizontal = TvTheme.edgePage, vertical = TvTheme.railsPadding),
                        horizontalArrangement = Arrangement.spacedBy(TvTheme.tileSpacing)) {
                    items(rail.title, key = { it.id }) { k -> TvTile(k.poster, k.title, k.subline) { open(Destination(k.id, k.title, k.type)) } }
                }
            }
        }
    }
}

