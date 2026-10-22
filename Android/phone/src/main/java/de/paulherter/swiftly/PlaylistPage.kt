package de.paulherter.swiftly

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
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
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import de.paulherter.swiftly.core.Kern
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

// MARK: Video playlists; mirrors `Sources/Shared/PlaylistPage.swift`

/** The route to the playlist page, `PlaylistRoute`: the playlist and its section (`movies`, `tvshows`) in `role`. */
fun playlistTarget(id: String, name: String, art: String?) = Destination(id, name, "Playlist", role = art)

/** "N Titel" under a playlist tile: how many entries this section shows. */
fun playlistCount(n: Int): String = translated("%lld Titel", n)

/** A playlist's tile in the grid: same build as the collection tile, count of the entries under the name. */
@Composable
fun PlaylistTileView(s: CollectionTile, modifier: Modifier = Modifier, perform: () -> Unit) {
    val description = "${s.name}, ${playlistCount(s.count)}"
    Column(modifier.reveal().tapOn(perform).semantics(mergeDescendants = true) { contentDescription = description },
        verticalArrangement = Arrangement.spacedBy(7.dp)) {
        Box(Modifier.fillMaxWidth().aspectRatio(2f / 3f).clip(RoundedCornerShape(Theme.cornerTile)).background(Theme.area),
            contentAlignment = Alignment.Center) {
            var missing by remember(s.poster) { mutableStateOf(s.poster == null) }
            if (missing) Symbol(Glyph.Film, 22.dp, color = Theme.fontVeryQuiet)
            if (s.poster != null) AsyncImage(model = s.poster, contentDescription = null, contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(), onError = { missing = true })
        }
        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(s.name, style = Theme.tile, color = Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(playlistCount(s.count), style = Theme.small, color = Theme.fontVeryQuiet, maxLines = 1)
        }
    }
}

/**
 * A playlist's entries **in the playlist's order** (the server keeps it; sorting would undo what someone
 * arranged). Nothing paged: one query, as on iOS (`PlaylistView.load`).
 */
class PlaylistState(val id: String, val art: String?) {
    var items by mutableStateOf<List<GridTile>>(emptyList()); private set
    var loads by mutableStateOf(true); private set
    var disrupted by mutableStateOf(false); private set

    suspend fun load(kern: Kern) {
        try {
            val o = JSONObject(withContext(Dispatchers.IO) { kern.playlistPage(id, art.orEmpty()).await() })
            val a = o.getJSONArray("titel")
            items = (0 until a.length()).map { gridTileRead(a.getJSONObject(it)) }
            disrupted = false
        } catch (e: CancellationException) { throw e } catch (_: Exception) {
            disrupted = items.isEmpty()
        }
        loads = false
    }

    /** The first entry's ID after the core has made the list the run; empty if there is none. */
    suspend fun start(kern: Kern): String = withContext(Dispatchers.IO) { kern.playlistStart(id, art.orEmpty()).await() }
}

/**
 * Mirrors `PlaylistView`: a collection page without sorting. Next to the count sits "Abspielen": it starts
 * the first entry, and the player's "Next episode" then walks along the list.
 */
@Composable
fun PlaylistPage(app: SwiftlyApplication, target: Destination, open: (Destination) -> Unit, back: () -> Unit) {
    val state = remember(target.id, target.role) { PlaylistState(target.id, target.role) }
    val section = rememberCoroutineScope()
    var message by remember { mutableStateOf<String?>(null) }
    var prepares by remember { mutableStateOf(false) }
    LaunchedEffect(state) { state.load(app.kern) }
    WatchStateChange(app) { state.load(app.kern) }
    val grid = rememberLazyGridState()
    val density = LocalDensity.current
    val offset by remember {
        derivedStateOf { if (grid.firstVisibleItemIndex > 0) 100f else grid.firstVisibleItemScrollOffset / density.density }
    }
    Box(Modifier.fillMaxSize()) {
        HeaderAndContent(header = {
            RootHeader({ offset }, margin = false) {
                SubpageHeader(target.name, back, bottom = 0.dp, top = false)
                ValueRail({ offset }, Modifier.padding(horizontal = Theme.edgeSpacing)) {
                    ValuePill(Glyph.Play, translated("Abspielen")) {
                        if (state.items.isEmpty() || prepares) return@ValuePill
                        prepares = true
                        section.launch {
                            val first = try { state.start(app.kern) } catch (e: CancellationException) { throw e } catch (_: Exception) { "" }
                            if (first.isNotEmpty()) app.play.value = PlayRequest(first, null)
                            else message = translated("Die Folge konnte nicht geladen werden.")
                            prepares = false
                        }
                    }
                    Spacer(Modifier.weight(1f))
                    if (state.items.isNotEmpty()) CountMark(state.items.size)
                }
            }
        }) { headerDp ->
            BoxWithConstraints(Modifier.fillMaxSize().background(Theme.reason)) {
                val count = Theme.columns((maxWidth - Theme.edgeSpacing * 2).value)
                LazyVerticalGrid(GridCells.Fixed(count), state = grid,
                    contentPadding = PaddingValues(start = Theme.edgeSpacing, end = Theme.edgeSpacing, top = headerDp + 8.dp, bottom = 40.dp),
                    horizontalArrangement = Arrangement.spacedBy(Theme.tileSpacing),
                    verticalArrangement = Arrangement.spacedBy(20.dp),
                    modifier = Modifier.fillMaxSize().navigationBarsPadding()) {
                    if (state.items.isEmpty() && state.loads) items(count * 3, key = { "platzhalter$it" }) { TilePlaceholder() }
                    items(state.items, key = { it.id }) { k -> GridTileView(k) { open(Destination(k.id, k.title, k.type)) } }
                }
                if (state.disrupted) {
                    EmptyState(Glyph.ServerRoute, translated("Server ist abgetaucht"),
                        translated("%@ antwortet nicht. Läuft er noch, oder hängt das WLAN?", app.serverAddress()),
                        primaryButton = translated("Erneut versuchen") to { section.launch { state.load(app.kern) } })
                } else if (state.items.isEmpty() && !state.loads) {
                    EmptyState(Glyph.Store, translated("Hier ist noch nichts"),
                        translated("Sobald in dieser Wiedergabeliste etwas liegt, taucht es hier auf."),
                        quietButton = translated("Aktualisieren") to { section.launch { state.load(app.kern) } })
                }
            }
        }
        HintStrip(message, Modifier.align(Alignment.BottomCenter)) { message = null }
    }
}
