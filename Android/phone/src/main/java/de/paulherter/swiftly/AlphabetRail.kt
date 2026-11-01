package de.paulherter.swiftly

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.shared.Motion
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.delay
import org.json.JSONArray

/**
 * One entry of the strip: `{"buchstabe","ab","anzeige","luecke"}` from the core (`AlphabetIndex.Entry`).
 * `letter` is the key (a letter, "2025", "r7"), `label` what the strip shows ("25").
 */
data class LetterEntry(val letter: String, val first: Int, val label: String = letter,
                       /** A dot before the entry: the next year or rating. */
                       val gap: Boolean = false)

/** Mirrors `AlphabetIndex.gapShare`: a dot takes half an entry's row. */
const val GapShare = 0.5f

/** Mirrors `AlphabetIndex.entry(at:height:in:)`: a dot belongs to the entry after it. */
fun entryAt(y: Float, height: Float, shown: List<LetterEntry>): LetterEntry? {
    if (shown.isEmpty() || height <= 0f) return null
    val row = height / (shown.size + shown.count { it.gap } * GapShare)
    var bottom = 0f
    for (entry in shown) {
        bottom += (if (entry.gap) GapShare * row else 0f) + row
        if (y < bottom) return entry
    }
    return shown.last()
}

/** Reads the core's index; empty when there is none. */
fun lettersRead(a: JSONArray?): List<LetterEntry> =
    if (a == null) emptyList()
    else (0 until a.length()).map {
        a.getJSONObject(it).let { e ->
            val key = e.getString("buchstabe")
            LetterEntry(key, e.getInt("ab"), e.optString("anzeige", key), e.optBoolean("luecke", false))
        }
    }

/**
 * Mirrors `AlphabetIndex.condensed(fitting:)`: a scale (years, ratings: the entries with dots) is thinned
 * from the top down; letters keep the first and the last and spread the rest evenly. Dots count
 * for height.
 */
fun condensed(letters: List<LetterEntry>, slots: Int): List<LetterEntry> {
    fun rows(l: List<LetterEntry>) = l.size + l.count { it.gap } * GapShare
    if (slots < 2 || rows(letters) <= slots) return letters
    if (letters.any { it.gap }) return thinned(letters, slots)
    val last = letters.size - 1
    return (0 until slots).map { k -> Math.round(k.toDouble() * last / (slots - 1)).toInt() }
        .distinct().map { letters[it] }
}

/** Mirrors `AlphabetIndex.thinned(fitting:)`: newest one after another, further down ever sparser. */
private fun thinned(letters: List<LetterEntry>, slots: Int): List<LetterEntry> {
    val fits = maxOf(2, ((slots + GapShare) / (1 + GapShare)).toInt())
    if (letters.size <= fits) return letters
    val last = letters.size - 1
    val picked = mutableListOf<Int>()
    for (k in 0 until fits) {
        val share = k.toDouble() / (fits - 1)
        var i = Math.round(share * share * last).toInt()
        picked.lastOrNull()?.let { i = maxOf(i, it + 1) }
        i = minOf(i, last - (fits - 1 - k))
        picked += i
    }
    return picked.mapIndexed { k, i -> if (k == 0) letters[i].copy(gap = false) else letters[i] }
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
 * height beside a grid: letters for "By name", years or ratings for the other orders. A tap or a slide jumps to the first title of the letter under
 * the finger, with one tick per new letter; while the grid scrolls on its own, the letter of the
 * topmost title is in the accent.
 */
@Composable
fun AlphabetRail(letters: List<LetterEntry>, current: String?, modifier: Modifier = Modifier,
                 jump: (String) -> Unit) {
    val jerk = rememberJerk()
    val onJump by rememberUpdatedState(jump)
    var touched by remember { mutableStateOf<String?>(null) }
    // The last entry jumped to, until the grid is there (`AlphabetRail.held`): the grid loads
    // and scrolls first, and the strip must not fall back to the old year meanwhile.
    var held by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(current) {
        val h = held
        if (h != null && current == h) held = null
    }
    LaunchedEffect(held) {
        if (held != null) { delay(5_000); held = null }
    }
    BoxWithConstraints(modifier.width(AlphabetRailWidth).fillMaxHeight()) {
        // The smallest row a letter gets is 14 (`AlphabetRail.minimumRow`).
        val shown = condensed(letters, maxOf(2, (maxHeight / 14.dp).toInt()))
        val lit = touched ?: held ?: current
        Column(
            Modifier.fillMaxHeight().fillMaxWidth()
                .semantics { contentDescription = translated("Alphabet") }
                .pointerInput(shown) {
                    fun at(y: Float) {
                        val letter = entryAt(y, size.height.toFloat(), shown)?.letter ?: return
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
                        held = touched
                        touched = null
                    }
                }
        ) {
            shown.forEach { entry ->
                val color by animateColorAsState(if (entry.letter == lit) Theme.accent else Theme.fontQuiet,
                                                 Motion.reveal(), label = "letter")
                // The next step of a scale, half a row high.
                if (entry.gap) {
                    Box(Modifier.weight(GapShare).fillMaxWidth(), contentAlignment = Alignment.Center) {
                        Box(Modifier.size(3.dp).clip(CircleShape).background(Theme.fontVeryQuiet))
                    }
                }
                Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                    Text(entry.label, color = color, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}
