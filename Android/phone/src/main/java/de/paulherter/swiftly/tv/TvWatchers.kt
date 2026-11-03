package de.paulherter.swiftly.tv

import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.lazy.items
import de.paulherter.swiftly.*
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated

/**
 * The TV section "Gesehen von": a row of focusable avatars; name, count and date appear below the
 * focused one. Absent for an empty list.
 */
@Composable
fun TvWatchedBy(watchers: List<Watcher>, modifier: Modifier = Modifier) {
    if (watchers.isEmpty()) return
    var focused by remember(watchers) { mutableStateOf<String?>(null) }
    Column(modifier) {
        TvStrip(translated("Gesehen von")) {
            items(watchers, key = { it.id }) { w ->
                FocusArea(focusChanged = { f -> if (f) focused = w.id else if (focused == w.id) focused = null },
                          liftCorner = 100.dp, perform = {}, modifier = Modifier.semantics { contentDescription = w.spoken() }) {
                    WatcherAvatar(w, 76.dp)
                }
            }
        }
        // A fixed line so the page does not jump when focus moves.
        Box(Modifier.fillMaxWidth().height(28.dp).padding(horizontal = TvTheme.edgePage)) {
            watchers.firstOrNull { it.id == focused }?.let { w ->
                Text(w.spoken(), style = TvTheme.small, color = Theme.fontQuiet, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}
