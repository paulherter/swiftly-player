package de.paulherter.swiftly.tv

import de.paulherter.swiftly.KernRules

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.layout.layout
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Strength
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import org.json.JSONArray

/**
 * One cell of the keyboard, as `SearchKeys` in the package delivers it. `kind` is `letter`, `space`,
 * `delete` or `speak`; `span` is the number of columns the key covers.
 */
internal data class SearchKey(val kind: String, val character: String, val span: Int) {
    /** The same id as `SearchKeys.Key.id`: the character for a letter, else the kind. */
    val id: String get() = if (kind == "letter") character else kind
}

/** The rows of the grid. The layout is the package's, so both TVs type on the same keyboard. */
internal fun searchKeyRows(speech: Boolean): List<List<SearchKey>> =
    JSONArray(KernRules.searchKeyRows(speech)).let { rows ->
        (0 until rows.length()).map { r ->
            rows.getJSONArray(r).let { row ->
                (0 until row.length()).map { c ->
                    row.getJSONObject(c).let { SearchKey(it.getString("kind"), it.getString("character"), it.getInt("span")) }
                }
            }
        }
    }

/**
 * Where focus stands on the search page, so it can go back there: the keyboard remembers its last key
 * and the results their last tile (`SearchTarget` and `lastKey`/`lastHit` on tvOS).
 */
internal class SearchFocus(private val st: de.paulherter.swiftly.SearchState) {
    /** Kept in the search state, which outlives the page: coming back from a title, focus is where it was. */
    var lastKey: String
        get() = st.lastKey
        set(value) { st.lastKey = value }
    var lastHit: String?
        get() = st.lastHit
        set(value) { st.lastHit = value }
    private val keys = HashMap<String, FocusRequester>()
    private val hits = HashMap<String, FocusRequester>()

    fun key(id: String): FocusRequester = keys.getOrPut(id) { FocusRequester() }
    fun hit(id: String): FocusRequester = hits.getOrPut(id) { FocusRequester() }
    /** The first row of the history card, where focus lands when the page has no hits. */
    val recent = FocusRequester()

    /** Focus to the last key; false if the keyboard is not there (yet). */
    fun toKeys(): Boolean = runCatching { key(lastKey).requestFocus(); true }.getOrDefault(false)
}

/**
 * **The on-screen keyboard of the search: a card with the field on top and the keys below.**
 * Mirrors `TVSearchKeyboard` on tvOS, point for point (dp = points / 2, all numbers from `TvSpec`).
 *
 * Not the system keyboard: that one covers the results, and the two TVs would type differently. Here
 * every letter is on the page at once, next to the hits. At rest the keys are bare characters on the
 * card; in focus a key turns white with dark text, the rule of every button on the TV.
 *
 * The field is never focusable. It shows what was typed, cut at the front when it gets long so the last
 * letter stays visible, with a caret that stands still (a blinking one would be a pulse).
 */
@Composable
internal fun TvSearchKeyboard(term: String, change: (String) -> Unit, focus: SearchFocus,
                              speaking: Boolean, speak: (() -> Unit)?, modifier: Modifier = Modifier) {
    val rows = remember(speak != null) { searchKeyRows(speech = speak != null) }
    Column(modifier
            .width(SearchLayout.keyboardWidth)
            .clip(RoundedCornerShape(TvTheme.cornerArea))
            .background(Theme.groupsArea)
            .padding(SearchLayout.keyboardInset)
            // A hardware keyboard on the TV (or a Bluetooth one) types into the field as well. Read after
            // the focused key had its turn, so Enter and the D-pad still press the key.
            .onPreviewKeyEvent { e ->
                if (e.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                if (e.key == Key.Backspace || e.key == Key.Delete) { change(KernRules.searchKeyDelete(term)); return@onPreviewKeyEvent true }
                val n = e.nativeKeyEvent
                if (n.isCtrlPressed || n.isAltPressed || n.isMetaPressed) return@onPreviewKeyEvent false
                val typed = n.unicodeChar.takeIf { it > 0 }?.let { String(Character.toChars(it)) } ?: return@onPreviewKeyEvent false
                val next = KernRules.searchKeyHardware(typed, term)
                if (next == term) return@onPreviewKeyEvent false
                change(next)
                true
            },
        verticalArrangement = Arrangement.spacedBy(TvSpec.searchFieldGap)) {
        Field(term)
        Column(verticalArrangement = Arrangement.spacedBy(TvSpec.searchKeyGap)) {
            // Letter rows: six keys spread over the card's width ("space-between"); the last row (delete and
            // microphone, 72 pt high) sits at both edges.
            rows.forEachIndexed { i, row ->
                Row(Modifier.width(SearchLayout.keysWidth), horizontalArrangement = Arrangement.SpaceBetween) {
                    row.forEach { key -> KeyButton(key, term, change, focus, speaking, speak, tall = i == rows.lastIndex) }
                }
            }
        }
    }
}

/** The measures of the search page, computed from the spec and never typed. */
internal object SearchLayout {
    /** `columns` keys, the gaps between them, the card's inset on both sides: 222 dp for 6. */
    /** The design's card: 460 pt wide with 16 pt inside on every side. */
    val keyboardWidth = 230.dp  // tv-spec: unrelated
    val keyboardInset = 8.dp
    /** What is left for the keys: 214 dp. Six 32 dp keys sit "space-between" in it. */
    val keysWidth = keyboardWidth - keyboardInset * 2
    /** The field and the bottom row are 72 pt high. */
    val fieldHeight = 36.dp  // tv-spec: unrelated
    /** Left edge of the right column ("Zuletzt gesucht") and its width: 620 / 760 pt. */
    val historyLeft = 310.dp
    val historyWidth = 380.dp  // tv-spec: unrelated

    /** 5 posters, 4 gaps: 620 dp. */
    val resultsWidth: Dp = TvTheme.posterWidth * TvSpec.searchColumns + TvTheme.gridColumn * (TvSpec.searchColumns - 1)

    fun keyWidth(span: Int): Dp = TvSpec.searchKey * span + TvSpec.searchKeyGap * (span - 1)
}

@Composable
private fun Field(term: String) {
    val label = translated("Titel, Serie, Person")
    Row(Modifier.fillMaxWidth().height(SearchLayout.fieldHeight)
            .clip(RoundedCornerShape(TvTheme.cornerSmall))
            .background(Theme.area)
            .padding(horizontal = 8.dp)
            .semantics(mergeDescendants = true) { contentDescription = if (term.isEmpty()) label else "$label, $term" },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Symbol(Glyph.Magnifier, 14.dp, color = Theme.fontQuiet, strength = Strength.Medium)  // tv-spec: unrelated
        // The typed text and the caret as one piece that is pushed to the left when it gets too wide:
        // the head is cut, never the caret.
        Box(Modifier.weight(1f).clipToBounds()) {
            Row(Modifier.layout { measurable, constraints ->
                val placeable = measurable.measure(Constraints(minWidth = 0, maxWidth = Constraints.Infinity,
                                                               minHeight = 0, maxHeight = constraints.maxHeight))
                layout(minOf(placeable.width, constraints.maxWidth), placeable.height) {
                    placeable.place(minOf(0, constraints.maxWidth - placeable.width), 0)
                }
            }, verticalAlignment = Alignment.CenterVertically) {
                if (term.isEmpty()) {
                    Caret()
                    Text(label, style = TvTheme.body.copy(fontSize = 14.sp), color = Theme.fontVeryQuiet, maxLines = 1, softWrap = false,
                         modifier = Modifier.padding(start = 2.dp))
                } else {
                    // A trailing space is not always measured; a no-break space is, so the caret moves when the
                    // space key is pressed.
                    Text(term.replace(' ', ' '), style = TvTheme.body.copy(fontSize = 14.sp), color = Theme.font, maxLines = 1, softWrap = false)
                    Caret()
                }
            }
        }
    }
}

@Composable
private fun Caret() {
    Spacer(Modifier.size(1.5.dp, 17.dp).background(Theme.accent))  // tv-spec: unrelated
}

@Composable
private fun KeyButton(key: SearchKey, term: String, change: (String) -> Unit, focus: SearchFocus,
                      speaking: Boolean, speak: (() -> Unit)?, tall: Boolean = false) {
    val muted = when (key.kind) {
        "space" -> !KernRules.searchKeySpaceFits(term)
        "delete" -> false
        else -> false
    }
    val description = when (key.kind) {
        "space" -> translated("Leerzeichen")
        "delete" -> translated("Löschen") + ", " + translated("Halten löscht alles")
        "speak" -> translated("Sprechen")
        else -> key.character
    }
    FocusArea(Modifier.size(SearchLayout.keyWidth(key.span), if (tall) SearchLayout.fieldHeight else TvSpec.searchKey)
                    .focusRequester(focus.key(key.id))
                    .semantics(mergeDescendants = true) { contentDescription = description },
        magnifier = TvTheme.focusMagnifierSmall, lift = true, liftCorner = TvTheme.cornerSmall,
        focusChanged = { if (it) focus.lastKey = key.id },
        // Hold OK on "delete" for half a second: everything goes. No fourth key "clear all".
        lengthy = if (key.kind == "delete") ({ if (term.isNotEmpty()) change("") }) else null,
        perform = {
            when (key.kind) {
                "letter" -> change(KernRules.searchKeyTyped(key.character, term))
                "space" -> change(KernRules.searchKeySpace(term))
                "delete" -> change(KernRules.searchKeyDelete(term))
                "speak" -> speak?.invoke()
            }
        }) { focused ->
        // A muted key in focus gets only the calm surface, not white, and keeps a readable character.
        val surface = if (!focused) Color.Transparent else if (muted) TvTheme.focusArea else Color.White
        val character = if (focused) (if (muted) Theme.fontQuiet else Theme.reason)
                        else (if (muted) Theme.fontVeryQuiet else Theme.fontQuiet)
        Box(Modifier.fillMaxSize().clip(RoundedCornerShape(TvTheme.cornerSmall)).background(surface),
            contentAlignment = Alignment.Center) {
            when (key.kind) {
                "letter" -> Text(key.character, style = TvTheme.button.copy(fontSize = 15.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold), color = character, maxLines = 1)
                "space" -> Symbol(Glyph.SpaceBar, 15.dp, color = character, strength = Strength.Medium)
                "delete" -> Symbol(Glyph.Backspace, 18.dp, color = character, strength = Strength.Medium)  // tv-spec: unrelated
                else -> Symbol(if (speaking) Glyph.MicFilled else Glyph.Mic, 18.dp, color = character, strength = Strength.Medium)  // tv-spec: unrelated
            }
        }
    }
}
