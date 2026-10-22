package de.paulherter.swiftly.tv

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import de.paulherter.swiftly.*
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

// MARK: Video playlists on TV (mirrors `PlaylistView` on tvOS)

/** A playlist's tile in the grid: the number of the section's entries under the name. */
@Composable
fun TvPlaylistTile(s: CollectionTile, modifier: Modifier = Modifier, perform: () -> Unit) {
    TvTile(s.poster, s.name, playlistCount(s.count), modifier = modifier, perform = perform)
}

/**
 * The playlist page: name, "Abspielen" and the count above the grid, the entries in the playlist's order.
 * "Abspielen" starts the first entry; the player's "Next episode" then walks along the list.
 */
@Composable
fun TvPlaylist(app: SwiftlyApplication, target: Destination, open: (Destination) -> Unit) {
    val state = remember(target.id, target.role) { PlaylistState(target.id, target.role) }
    val run = rememberCoroutineScope()
    var prepares by remember { mutableStateOf(false) }
    LaunchedEffect(state) { state.load(app.kern) }
    WatchStateChange(app) { state.load(app.kern) }
    val focus = firstFocus(!state.loads)
    Box(Modifier.fillMaxSize().background(Theme.reason)) {
        TvGrid(state.items, {}, focus, open, loads = state.loads, withUnderRow = false, header = {
            Column(Modifier.padding(bottom = 10.dp)) {
                Text(target.name, style = TvTheme.rail, color = Theme.font, maxLines = 1,
                     modifier = Modifier.padding(top = 48.dp, bottom = TvTheme.titleSpacing))
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    TvCapsule(translated("Abspielen"), symbol = Glyph.Play) {
                        if (state.items.isEmpty() || prepares) return@TvCapsule
                        prepares = true
                        run.launch {
                            val first = try { state.start(app.kern) } catch (e: CancellationException) { throw e } catch (_: Exception) { "" }
                            if (first.isNotEmpty()) app.play.value = PlayRequest(first, null)
                            prepares = false
                        }
                    }
                    Spacer(Modifier.weight(1f))
                    if (state.items.isNotEmpty()) Text(playlistCount(state.items.size), style = TvTheme.small, color = Theme.fontVeryQuiet)
                }
                if (state.disrupted) TvDisruption(app, retry = { run.launch { state.load(app.kern) } })
                else if (!state.loads && state.items.isEmpty())
                    TvEmpty(translated("Hier ist noch nichts"), translated("Sobald in dieser Wiedergabeliste etwas liegt, taucht es hier auf."),
                        symbol = Glyph.Store, button = translated("Aktualisieren") to { run.launch { state.load(app.kern) } })
            }
        })
    }
}
