package de.paulherter.swiftly.tv

import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import de.paulherter.swiftly.*
import de.paulherter.swiftly.shared.Theme

/**
 * **Who has watched a title, in the button row** (mirrors `WatcherDots` in `Sources/tvOS/TVWatchers.swift`):
 * round avatars after the buttons, as tall as a button, apart from them and without a heading. The
 * focused one names itself to the right of the row: who, how often, when last. The text stands after
 * the last avatar, so moving focus along the row never shifts the buttons. Absent for an empty list.
 *
 * Called inside the button `Row`, so it lines up with the buttons and focus reaches it with right.
 */
@Composable
fun TvWatcherDots(watchers: List<Watcher>) {
    if (watchers.isEmpty()) return
    var focused by remember(watchers) { mutableStateOf<String?>(null) }
    Row(Modifier.padding(start = 20.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(9.dp)) {
        for (w in watchers) {
            // Nothing to open: only a place focus can rest on.
            FocusArea(focusChanged = { f -> if (f) focused = w.id else if (focused == w.id) focused = null },
                      liftCorner = 100.dp, perform = {}, modifier = Modifier.semantics { contentDescription = w.spoken() }) {
                WatcherAvatar(w, TvTheme.buttonHeight)
            }
        }
        val shown = watchers.firstOrNull { it.id == focused }
        Column(Modifier.padding(start = 4.dp).widthIn(max = 240.dp)) {
            Text(shown?.name?.ifBlank { "?" } ?: "", style = TvTheme.small, color = Theme.font,
                 maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(shown?.caption ?: "", style = TvTheme.small, color = Theme.fontQuiet,
                 maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}
