package de.paulherter.swiftly.tv

import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.Column
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalFocusManager
import kotlinx.coroutines.delay
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.LetterEntry
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated

/** Mirrors `TVAlphabetRail.width`, scaled to the 40 dp margin. */
val TvAlphabetRailWidth = 28.dp

/**
 * Mirrors `TVAlphabetRail` on tvOS: a column of focusable letters in the right margin beside a
 * "By name" grid. Right from the last column reaches it; up and down walk the letters and the grid
 * follows at once; OK jumps too; left goes back into the grid. **Every letter, scrolling**: a
 * library in two alphabets has more letters than fit at a size readable from the sofa, and the
 * column keeps the focused one in view. Without focus the current letter stays in view.
 */
@Composable
fun TvAlphabetRail(letters: List<LetterEntry>, current: String?, modifier: Modifier = Modifier,
                   toGrid: FocusRequester? = null, jump: (String) -> Unit) {
    val list = rememberLazyListState()
    val manager = LocalFocusManager.current
    var focused by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(current, focused) {
        if (focused != null) return@LaunchedEffect
        val at = letters.indexOfFirst { it.letter == current }
        if (at >= 0) list.animateScrollToItem(maxOf(0, at - 4))
    }
    // **Scroll the grid only once the focus has settled**: a jump per letter while walking down the rail
    // re-laid-out the tiles beside it and Left found no candidate. OK still jumps at once.
    LaunchedEffect(focused) {
        val letter = focused ?: return@LaunchedEffect
        delay(150)
        jump(letter)
    }
    // A soft edge says there are more letters above or below (tvOS mask: clear 0, black .02, black .98, clear 1).
    LazyColumn(modifier.width(TvAlphabetRailWidth).fillMaxHeight()
                   .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
                   .drawWithContent {
                       drawContent()
                       drawRect(Brush.verticalGradient(0f to Color.Transparent, 0.02f to Color.Black, 0.98f to Color.Black, 1f to Color.Transparent),
                                blendMode = BlendMode.DstIn)
                   }.onPreviewKeyEvent { e ->
                       // Left goes back into the grid: the requested landing tile first, the focus search as a fallback.
                       if (e.key == Key.DirectionLeft && e.type == KeyEventType.KeyDown) {
                           val ok = toGrid != null && try { toGrid.requestFocus(); true } catch (_: Exception) { false }
                           ok || manager.moveFocus(FocusDirection.Left)
                       } else false
                   }.focusGroup()
                   .semantics { contentDescription = translated("Alphabet") },
               state = list, contentPadding = PaddingValues(vertical = 8.dp),
               horizontalAlignment = Alignment.CenterHorizontally) {
        items(letters, key = { it.letter }) { entry ->
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                // The next step of a scale, not focusable.
                if (entry.gap) {
                    Box(Modifier.height(10.dp).fillMaxWidth(), contentAlignment = Alignment.Center) {
                        Box(Modifier.size(4.dp).clip(CircleShape).background(Theme.fontVeryQuiet))
                    }
                }
                FocusArea(Modifier.height(21.5.dp), magnifier = 1.15f,
                          focusChanged = { inside ->
                              if (inside) focused = entry.letter
                              else if (focused == entry.letter) focused = null
                          },
                          perform = { jump(entry.letter) }) { focus ->
                    Box(Modifier.size(20.dp).clip(CircleShape).background(if (focus) Theme.accent else Color.Transparent),
                        contentAlignment = Alignment.Center) {
                        Text(entry.label, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                             color = when {
                                 focus -> Theme.font
                                 entry.letter == current -> Theme.accent
                                 else -> Theme.fontVeryQuiet
                             })
                    }
                }
            }
        }
    }
}
