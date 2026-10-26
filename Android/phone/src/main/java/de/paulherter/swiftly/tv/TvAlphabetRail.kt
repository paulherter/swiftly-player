package de.paulherter.swiftly.tv

import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.LetterEntry
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated

/** Mirrors `TVAlphabetRail.width`, scaled to the 40 dp margin. */
val TvAlphabetRailWidth = 32.dp

/**
 * Mirrors `TVAlphabetRail` on tvOS: a column of focusable letters in the right margin beside a
 * "By name" grid. Right from the last column reaches it; up and down walk the letters and the grid
 * follows at once; OK jumps too; left goes back into the grid. **Every letter, scrolling**: a
 * library in two alphabets has more letters than fit at a size readable from the sofa, and the
 * column keeps the focused one in view. Without focus the current letter stays in view.
 */
@Composable
fun TvAlphabetRail(letters: List<LetterEntry>, current: String?, modifier: Modifier = Modifier,
                   jump: (String) -> Unit) {
    val list = rememberLazyListState()
    var focused by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(current, focused) {
        if (focused != null) return@LaunchedEffect
        val at = letters.indexOfFirst { it.letter == current }
        if (at >= 0) list.animateScrollToItem(maxOf(0, at - 4))
    }
    LazyColumn(modifier.width(TvAlphabetRailWidth).fillMaxHeight().focusGroup()
                   .semantics { contentDescription = translated("Alphabet") },
               state = list, contentPadding = PaddingValues(vertical = 8.dp),
               horizontalAlignment = Alignment.CenterHorizontally) {
        items(letters, key = { it.letter }) { entry ->
            FocusArea(Modifier.height(28.dp), magnifier = 1.1f,
                      focusChanged = { inside ->
                          if (inside) { focused = entry.letter; jump(entry.letter) }
                          else if (focused == entry.letter) focused = null
                      },
                      perform = { jump(entry.letter) }) { focus ->
                Box(Modifier.size(24.dp).clip(CircleShape).background(if (focus) Theme.accent else Color.Transparent),
                    contentAlignment = Alignment.Center) {
                    Text(entry.letter, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                         color = when {
                             focus -> Theme.font
                             entry.letter == current -> Theme.accent
                             else -> Theme.fontQuiet
                         })
                }
            }
        }
    }
}
