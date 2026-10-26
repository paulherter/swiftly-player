package de.paulherter.swiftly

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.shared.Motion
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import org.json.JSONArray

/** One letter of the strip: `{"buchstabe","ab"}` from the core (`AlphabetIndex.Entry`). */
data class LetterEntry(val letter: String, val first: Int)

/** Reads the core's letters; empty when the page is not sorted by name. */
fun lettersRead(a: JSONArray?): List<LetterEntry> =
    if (a == null) emptyList()
    else (0 until a.length()).map { a.getJSONObject(it).let { e -> LetterEntry(e.getString("buchstabe"), e.getInt("ab")) } }

/**
 * Mirrors `AlphabetIndex.condensed(fitting:)`: keeps the first and the last letter and spreads
 * the rest evenly when the height is not enough for all of them.
 */
fun condensed(letters: List<LetterEntry>, slots: Int): List<LetterEntry> {
    if (slots < 2 || letters.size <= slots) return letters
    val last = letters.size - 1
    return (0 until slots).map { k -> Math.round(k.toDouble() * last / (slots - 1)).toInt() }
        .distinct().map { letters[it] }
}

/**
 * Mirrors `LibraryModel.jumpTarget`: the index of the first title of a letter, loading up to it in
 * steps sized by where the letter starts in the list. Shared by the library and the collection.
 */
suspend fun alphabetJumpTarget(letter: String, letters: List<LetterEntry>, items: () -> List<GridTile>,
                               stillMore: () -> Boolean, busy: () -> Boolean,
                               loadMore: suspend (Long) -> Unit): Int? {
    val start = letters.firstOrNull { it.letter == letter }?.first ?: return null
    repeat(20) {
        val now = items()
        now.indexOfFirst { it.letter == letter }.takeIf { it >= 0 }?.let { return it }
        if (!stillMore()) return now.lastIndex.takeIf { it >= 0 }
        // A page being appended right now blocks loading more; wait for it.
        if (busy()) { kotlinx.coroutines.delay(100); return@repeat }
        loadMore(maxOf(60L, (start - now.size).toLong() + 60L))
        if (items().size == now.size) return now.lastIndex.takeIf { it >= 0 }
    }
    return items().lastIndex.takeIf { it >= 0 }
}

/** Mirrors `AlphabetRail.width`. */
val AlphabetRailWidth = 22.dp

/**
 * Mirrors `AlphabetRail` in `Sources/Shared`: the letters the list has, spread over the whole
 * height beside a "By name" grid. A tap or a slide jumps to the first title of the letter under
 * the finger, with one tick per new letter; while the grid scrolls on its own, the letter of the
 * topmost title is in the accent.
 */
@Composable
fun AlphabetRail(letters: List<LetterEntry>, current: String?, modifier: Modifier = Modifier,
                 jump: (String) -> Unit) {
    val jerk = rememberJerk()
    val onJump by rememberUpdatedState(jump)
    var touched by remember { mutableStateOf<String?>(null) }
    BoxWithConstraints(modifier.width(AlphabetRailWidth).fillMaxHeight()) {
        // The smallest row a letter gets is 14 (`AlphabetRail.minimumRow`).
        val shown = condensed(letters, maxOf(2, (maxHeight / 14.dp).toInt()))
        val lit = touched ?: current
        Column(
            Modifier.fillMaxHeight().fillMaxWidth()
                .semantics { contentDescription = translated("Alphabet") }
                .pointerInput(shown) {
                    fun at(y: Float) {
                        if (shown.isEmpty()) return
                        val row = (y / (size.height.toFloat() / shown.size)).toInt().coerceIn(0, shown.size - 1)
                        val letter = shown[row].letter
                        if (letter == touched) return
                        touched = letter
                        jerk(Jerk.Lightweight)
                        onJump(letter)
                    }
                    awaitEachGesture {
                        val down = awaitFirstDown()
                        down.consume()
                        at(down.position.y)
                        while (true) {
                            val event = awaitPointerEvent()
                            val change = event.changes.firstOrNull() ?: break
                            if (!change.pressed) break
                            change.consume()
                            at(change.position.y)
                        }
                        touched = null
                    }
                }
        ) {
            shown.forEach { entry ->
                val color by animateColorAsState(if (entry.letter == lit) Theme.accent else Theme.fontQuiet,
                                                 Motion.reveal(), label = "letter")
                Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                    Text(entry.letter, color = color, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}
