package de.paulherter.swiftly.tv

import de.paulherter.swiftly.AppLog
import de.paulherter.swiftly.shared.VisibilityProtection
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Strength
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.layout
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import de.paulherter.swiftly.TileBadge
import androidx.compose.ui.platform.LocalContext
import de.paulherter.swiftly.shared.Motion
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.motionReduced
import de.paulherter.swiftly.shared.translated

/**
 * Mirrors the tvOS style (`Sources/tvOS/Style.swift`). **Points are halved to dp**: tvOS lays out
 * on 1920 points, a 1080p TV is 960 dp on Android. Colors come unchanged from `Theme`.
 *
 * The TV type scale is exactly double the phone scale step by step (56 / 44 / 40 / 34 / 30 / 30 /
 * 26 / 24 / 22 / 20), so halving it yields the phone scale: 28 / 22 / 20 / 17 / 15 / 15 / 13 / 12 /
 * 11 / 10. The same holds for letter spacing, since it is em times point size.
 *
 * **`TvTheme` therefore has no type scale of its own** and points at `Theme`: changing a phone step
 * changes the TV too.
 *
 * The one rule behind it all: **focus is white, selection is accent.**
 */
object TvTheme {
    /**
     * **How long a focus request waits until the node exists.** `requestFocus()` in the same frame as
     * the attach often finds no node yet; one frame plus some slack is enough. One value so all
     * call sites wait the same.
     */
    const val focusDeadline = 30L
    val edgePage = TvSpec.edgePage
    val edgeTop = TvSpec.edgeTop
    val stripHeight = TvSpec.stripHeight
    val tileSpacing = 20.dp
    val posterWidth = 104.dp
    val posterHeight = 156.dp
    val landscapeWidth = 224.dp
    val landscapeHeight = 126.dp
    val heroHeight = 255.dp
    /** 28 gap + 10 air + 12 head room; the air absorbs the magnification. */
    val railsSpacing = 36.dp
    val railsPadding = 10.dp
    /** 28 pt: between row title and tiles (was 36 in 1.0). */
    val titleSpacing = 14.dp
    val buttonHeight = 38.dp
    val chipHeight = 28.dp
    val rowsHeight = TvSpec.rowsHeight
    /**
     * **The corner scale: the same rounding as on the phone, not the same number.**
     *
     * What matters is the ratio of radius to the size of the thing it rounds; that decides how round a
     * corner *looks*. Things on TV do not all grow equally (poster 112 to 208 is 1.86, button 48 to 76
     * only 1.58), so no fixed factor can work. The table is at `Theme.corner` in
     * `Sources/tvOS/Style.swift`; it gives **14 / 16 / 18 / 24** there, halved:
     *
     *     cornerSmall   14 -> 7      badges and tags
     *     ecke        16 -> 8      button, field
     *     cornerTile  18 -> 9      poster, tile
     *     eckeFlaeche 24 -> 12     panel, sheet
     */
    val corner = TvSpec.corner
    val cornerTile = TvSpec.cornerTile
    /** Badges and tags on a tile. */
    val cornerSmall = TvSpec.cornerSmall
    /** A free-standing surface or panel: action panel, sheet. */
    val cornerArea = TvSpec.cornerArea
    /** Not a scale step but a placeholder bar (`Ladefeld`). */
    val cornerBar = TvSpec.cornerBar
    const val gridColumns = 7
    /** 40 pt (was 50): the posters keep 208 pt, so the 7 columns are 1696 pt wide and the grid sits left at 80. */
    val gridColumn = 20.dp
    val latticeRow = 29.dp

    /**
     * **The focus scale: three steps, by the size of the item.**
     *
     * The criterion is **how far the outline moves**, not the percentage: 8 percent is two dp on a
     * 30 dp profile circle but thirty on a 380 dp wide row. The **longest side** is measured, and the
     * growth should land in the same range everywhere (about 3 to 13 dp, half the tvOS values):
     *
     *     focusMagnifierSmall   1.10   up to 60 dp     profile circle 30, icon button 44
     *     focusMagnifier        1.06   60 to 250       chip 90, button 125, poster 156, landscape tile 224
     *     focusMagnifierWide   1.03   from 250        bar row 310, device row 380
     *
     * Small items grow more, large ones less. No parallax, no flash: Apple's version jumps
     * further and visually pushes the neighbors away in a dense row. The only shadow is `lift`.
     */
    const val focusMagnifierSmall = TvSpec.focusMagnifierSmall
    const val focusMagnifier = TvSpec.focusMagnifier
    const val focusMagnifierWide = TvSpec.focusMagnifierWide
    val focusArea = Color.White.copy(alpha = TvSpec.focusAreaOpacity)
    /** `.easeOut(duration: 0.14)`. */
    val focusCurve = TvSpec.focusCurve
    const val focusDuration = TvSpec.focusMs
    /** Page scroll when switching sections (`TvSections`): calmer than the magnification, same curve. */
    const val sectionDuration = 300

    // MARK: Type: the phone scale, halved from the TV scale
    //
    // The tvOS scale is double the iPhone scale and an Android TV lays out in half the tvOS points,
    // so the numbers (and the tokens) are the same.

    // **Own TV scale.** Since the phone's 1.1 foundation (titleLarge 34, rail 20 semibold) `Theme` is no
    // longer exactly half of the TV scale, so the TV states its levels itself: tvOS value / 2.
    val titleLarge = Theme.titleLarge.copy(fontSize = 28.sp, letterSpacing = (-0.588).sp)       // 56 / lock -1.176
    val subpageTitle = Theme.subpageTitle.copy(fontSize = 22.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-0.308).sp) // 44
    /** Mirrors the `HeaderInfo` title: the page title step. */
    val infoTitle = titleLarge
    /** Mirrors the `HeaderInfo` second line (episode title): 30 pt / 600 on tvOS. */
    val infoSecondRow = Theme.listTitle.copy(fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
    /** Info-row chip text: 24 pt / 500. */
    val mark = Theme.small.copy(fontSize = 12.sp, fontWeight = FontWeight.Medium)
    /** Row and group headings: 44 pt bold on tvOS 1.1. */
    val rail = Theme.rail.copy(fontSize = 22.sp, fontWeight = FontWeight.Bold, letterSpacing = (-0.264).sp)
    val section = rail
    val categoryLarge = Theme.categoryLarge
    /** The label of a button and the row of a list. */
    val button = Theme.listTitle
    val body = Theme.body
    val tile = Theme.tile
    /** The focused tile title: 26 pt / 600. */
    val tileFocused = Theme.tile.copy(fontWeight = FontWeight.SemiBold)
    val small = Theme.small
    val badge = Theme.badge

    // Design caption under a tile: mt 18, one 34 high line, drops 14 when focused (tvOS pt / 2).
    val captionTop = 9.dp
    val captionLine = 17.dp
    val captionDrop = 7.dp
    /** Design tab: 68 high, 28 padding. */
    val tabHeight = 34.dp
    val tabPadding = 14.dp
    /** Info-row chip (`ProofMark`): 44 high, 16 padding, symbol 20, gap 8, between chips 12. */
    val markHeight = 22.dp
    val markCharacter = 10.dp
    val markInner = 8.dp
    val markCharacterSpacing = 4.dp
    val detailsSpacing = 6.dp
    val detailsPadding = 10.dp
    /** Title line 62, detail block left 80 / top 180 / width 1040, buttons 44 under the text. */
    val titleSlot = 31.dp
    val detailTop = 90.dp
    val detailWidth = 520.dp
    val spacingAboveButtons = 22.dp
    /** Between the chip row and the grid below: 48 pt. */
    val capsuleRailPadding = 24.dp

    // MARK: Kopfauskunft: shared by Home, movie and series

    /** Mirrors `Theme.descriptionHeight(_:)`: design body 30 pt at line height 1.45 = 43.5 pt per line. */
    fun descriptionHeight(rows: Int): Dp = (rows * 21.75f).dp

    /** The episode title above the info row: 44 pt. */
    val secondRowHeight = 22.dp

    /**
     * Mirrors `Theme.infoHeight(secondLine:)`. **Computed, not set**, so `HeaderInfo` has the same
     * total height on Home and detail: title slot 62 + second line 44 (only if present) + 20 + chip 44 +
     * 22 + two description lines (tvOS pt / 2).
     */
    fun infoHeight(secondLine: Boolean): Dp =
        titleSlot + (if (secondLine) secondRowHeight else 0.dp) + detailsPadding + markHeight + 11.dp + descriptionHeight(2)

    /**
     * Head zone of a detail page: `Theme.heroHeightDetail` (180 + info + 44 + 76 + 105 - 24 = 616 pt = 308 dp)
     * minus the 14 dp by which the Android strip's own top padding (railsSpacing - railsPadding = 26) exceeds
     * tvOS's `railsHeaderPadding` (12), so the first row heading lands at the design's 640 pt (320 dp).
     */
    val heroHeightDetail: Dp = detailTop + infoHeight(false) + spacingAboveButtons + buttonHeight + 52.5.dp - 12.dp - 14.dp

    /** `.easeOut(duration: 0.3)`: same curve as `focusCurve`, here for `inFade` on movie and
     *  series pages (`TvDetail`, `TvSeries`): the head is there at once, the rest fades in. */
    val showCurve = focusCurve
    const val showDuration = 300

    /** Mirrors `MainView.barPresent` on tvOS, `.easeInOut(duration: 0.26)`. The top bar gives way when a
     *  subpage opens and returns on back, see `TvMain`. */
    val barCurve = TvSpec.easeInOutCurve
    const val barDuration = 260
}

/**
 * The fade-in when a page appears (`inFade` on tvOS): 0 to 1 over `showDuration` with
 * `showCurve`, restarted every time `key` changes.
 *
 * **Why not plain `animateFloatAsState` + `LaunchedEffect { inFade = true }`:** the animation
 * was invisible on the emulator, the buttons just popped in. Two causes: (1) the value was read in
 * composition (`Modifier.alpha(value)`), so every animation frame recomposed the **whole** detail
 * page; (2) the animation started in the frame right after the first build, exactly the expensive
 * frames in which the page sets up rows, images and focus. The animation runs on the clock, so the
 * 300 ms were over before a calm frame came. Now: wait for two drawn frames (the page stands at
 * alpha 0), then animate, and read the value only in the draw phase (`graphicsLayer`, see
 * `Modifier.tvInFade`), so there is no recomposition per frame.
 */
@Composable
fun rememberTvFadeIn(key: Any?, ready: Boolean = true): androidx.compose.runtime.State<Float> {
    val value = remember(key) { androidx.compose.animation.core.Animatable(0f) }
    // `ready`: only fade in once the content is there (movie page: everything below the head arrives at once).
    LaunchedEffect(key, ready) {
        if (!ready || value.value == 1f) return@LaunchedEffect
        withFrameNanos { }
        withFrameNanos { }
        value.animateTo(1f, tween(TvTheme.showDuration, easing = TvTheme.showCurve))
    }
    return value.asState()
}

/** Alpha from a fade-in, read only while drawing; see `rememberTvFadeIn`. */
fun Modifier.tvInFade(opacity: () -> Float): Modifier = this.graphicsLayer { alpha = opacity() }

/** A spec animation: the given time and curve, or the short linear one under "Reduce motion"
 *  (tvOS: `Theme.motion(_:)`). */
@Composable
fun <T> tvTween(ms: Int, easing: androidx.compose.animation.core.Easing = TvSpec.focusCurve):
        androidx.compose.animation.core.FiniteAnimationSpec<T> =
    if (motionReduced()) tween(TvSpec.reducedMs, easing = androidx.compose.animation.core.LinearEasing)
    else tween(ms, easing = easing)

/** The calm surface of a focused row, eased in and out with the focus curve (tvOS: `.animation(Theme.focusAnimation, value: focus)`). */
@Composable
fun tvFocusSurface(focus: Boolean): Color =
    androidx.compose.animation.animateColorAsState(
        if (focus) TvTheme.focusArea else TvTheme.focusArea.copy(alpha = 0f),
        tvTween(TvSpec.focusMs), label = "focusSurface").value

/** Whether the Filme/Serien grid is scrolled under the tabs (`LibraryScroll` on tvOS); the soft shade shows only then. */
object TvLibraryScroll {
    var scrolled by mutableStateOf(false)
}

/**
 * A focusable surface with magnification; `TileStyle`, `ThemedButtonStyle` and `TabStyle` share it.
 * **No glow, no ring; the only shadow is `lift`** (black 12 %, blur 3 dp, y 1 dp, focused only; tvOS
 * values halved). Heavier shadows looked muddy in a row with six neighbors.
 *
 * **Carries its own `FocusRequester`** and reports to `FocusRemember` when triggered, so a panel or
 * sheet opened from this surface can hand focus back on close. tvOS leaves the trigger in place and
 * focus stays there by itself; Compose needs this detour (see `FocusRemember`, `LocalWithinPanel`).
 */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun FocusArea(modifier: Modifier = Modifier, magnifier: Float = TvTheme.focusMagnifier, focusChanged: (Boolean) -> Unit = {},
                 /** Menu key or long OK: the tile menu (`tileMenuPanel`). */
                 lengthy: (() -> Unit)? = null,
                 /** The one shadow of the TV system (`lift`): posters only; tabs, buttons, chips and rings have none. */
                 lift: Boolean = false,
                 /** Corner of the lift shadow's shape: tile 9 dp, button 8 dp, capsule/circle 100 dp. */
                 liftCorner: Dp = TvTheme.cornerTile,
                 perform: () -> Unit, content: @Composable BoxScope.(focus: Boolean) -> Unit) {
    var focus by remember { mutableStateOf(false) }
    // **"Reduce motion" applies here too**: focus stays visible, only the curve becomes short and
    // linear, as on the phone (`Theme.focusAnimation` on tvOS).
    val calm = motionReduced()
    val mass by animateFloatAsState(if (focus) magnifier else 1f,
        if (calm) Motion.fadeReduced() else tween(TvTheme.focusDuration, easing = TvTheme.focusCurve), label = "lupe")
    val ownFocus = remember { FocusRequester() }
    val withinPanel = LocalWithinPanel.current
    val locked = LocalFocusLocked.current
    /** The held OK has already opened the menu — repeats and the release no longer belong to the click. */
    val longPressed = remember { booleanArrayOf(false) }
    Box(modifier
            .focusProperties { if (locked) canFocus = false }
            .focusRequester(ownFocus)
            .onFocusChanged { if (focus != it.isFocused) { focus = it.isFocused; focusChanged(it.isFocused) } }
            .graphicsLayer {
                scaleX = mass; scaleY = mass
                if (focus && lift) {
                    shadowElevation = 3.dp.toPx()
                    ambientShadowColor = Color.Black.copy(alpha = 0.12f)
                    spotShadowColor = Color.Black.copy(alpha = 0.12f)
                    shape = androidx.compose.foundation.shape.RoundedCornerShape(liftCorner)
                    clip = false
                }
            }
            .then(if (lengthy == null) Modifier else Modifier.onPreviewKeyEvent { e ->
                // **Long OK by hand.** `combinedClickable` (Compose 1.7) knows the long press only for touch; a held
                // OK on the remote fired the click on release and started the episode. Android reports the held
                // button as a repeat with `FLAG_LONG_PRESS` (measured on a TCL TV: after 400 ms) — then the menu,
                // and the rest of the press does not count. Remotes without a menu key reach the menu only this way.
                val n = e.nativeKeyEvent
                if (n.keyCode == android.view.KeyEvent.KEYCODE_DPAD_CENTER || n.keyCode == android.view.KeyEvent.KEYCODE_ENTER ||
                    n.keyCode == android.view.KeyEvent.KEYCODE_NUMPAD_ENTER) {
                    if (e.type == androidx.compose.ui.input.key.KeyEventType.KeyDown) {
                        if (n.repeatCount == 0) { longPressed[0] = false; return@onPreviewKeyEvent false }
                        if (longPressed[0]) return@onPreviewKeyEvent true
                        if (n.isLongPress || n.eventTime - n.downTime >= android.view.ViewConfiguration.getLongPressTimeout()) {
                            longPressed[0] = true
                            FocusRemember.lastOne = ownFocus
                            KeysLock.afterLongPress()
                            lengthy()
                            return@onPreviewKeyEvent true
                        }
                        return@onPreviewKeyEvent false
                    }
                    if (e.type == androidx.compose.ui.input.key.KeyEventType.KeyUp && longPressed[0]) {
                        longPressed[0] = false
                        return@onPreviewKeyEvent true
                    }
                    return@onPreviewKeyEvent false
                }
                // **The remote's menu key** opens the tile menu, like a long press.
                if (e.key != androidx.compose.ui.input.key.Key.Menu) return@onPreviewKeyEvent false
                if (e.type == androidx.compose.ui.input.key.KeyEventType.KeyDown && e.nativeKeyEvent.repeatCount == 0) {
                    FocusRemember.lastOne = ownFocus
                    KeysLock.afterLongPress()
                    lengthy()
                }
                true
            })
            .combinedClickable(remember { MutableInteractionSource() }, null,
                onLongClick = lengthy?.let { l -> { FocusRemember.lastOne = ownFocus; KeysLock.afterLongPress(); l() } },
                onClick = {
                // Not inside an open panel: otherwise a selection row *in* it would overwrite the way back to the
                // row that opened it.
                if (!withinPanel) FocusRemember.lastOne = ownFocus
                perform()
            })) {
        content(focus)
    }
}

/**
 * Who opened a panel or sheet, so `TvPanel`/`TvWiedergabeblatt`/`TvFolgenblatt` return focus there
 * on close (selection **or** back) instead of leaving it to Compose's arbitrary focus search (which
 * would otherwise land on, say, the first focusable element of the page).
 */
object FocusRemember {
    var lastOne: FocusRequester? = null
        set(value) { field = value; setAround = android.os.SystemClock.elapsedRealtime() }
    private var setAround = 0L

    /**
     * **The player's trigger**: the tile, episode or button playback was started from. The player
     * runs in its own activity and clears `letzter` there; `TvMain` therefore remembers it here
     * before starting and restores focus after closing. Only a fresh click counts: a start without a
     * click (Watch Next, remote control) would otherwise hit a stale button of another page.
     */
    var prePlayer: FocusRequester? = null

    fun playerStarted() {
        prePlayer = lastOne.takeIf { android.os.SystemClock.elapsedRealtime() - setAround < 3000 }
    }

    /** Where focus went back to after the player; the return strip hands it back there. */
    var postPlayer: FocusRequester? = null

    fun playerTo() {
        val target = prePlayer ?: return
        prePlayer = null
        postPlayer = target
        val met = runCatching { target.requestFocus() }.isSuccess
        AppLog.writeOut("[Fokus] nach dem Player ${if (met) "zurück am Auslöser" else "Auslöser nicht mehr da"}")
    }

    /** Requests the remembered trigger back, otherwise `substitute` (if given), and then forgets it so a
     *  later close without a new trigger does not hit the same button. */
    fun reclaim(substitute: FocusRequester? = null) {
        val target = lastOne
        lastOne = null
        val met = target != null && runCatching { target.requestFocus() }.isSuccess
        if (!met) substitute?.let { runCatching { it.requestFocus() } }
    }

    /**
     * Call **before** closing, while the panel still exists. When Compose removes a focused node,
     * focus falls at once to the first focusable node of the window (on the profile page the "+" in
     * the account strip); a later `reclaim` only fetches it afterwards, and that
     * intermediate stop flashed. If focus is already on the trigger when the panel disappears,
     * there is nothing to fall from.
     *
     * The marker stays: if a panel row selects the next panel right away, the same trigger still
     * applies. For that the panel must release its exit (`exit`), see `TvPanel`.
     */
    fun backGive(substitute: FocusRequester? = null): Boolean {
        val target = lastOne
        if (target != null && runCatching { target.requestFocus() }.isSuccess) return true
        return substitute != null && runCatching { substitute.requestFocus() }.isSuccess
    }
}

/** True inside an open panel/sheet (`TvPanel`, `TvWiedergabeblatt`, `TvFolgenblatt`): a clicked
 *  `FocusArea` there does not count as a trigger for `FocusRemember`, otherwise the last selected
 *  row would always be the "trigger". */
val LocalWithinPanel = compositionLocalOf { false }

/**
 * The page behind the profile picker. A `focusProperties { canFocus = false }` on a parent does not
 * reach the `focusGroup()`s inside the page (the walk up stops at the first focus target), so every
 * `FocusArea` takes the lock itself.
 */
val LocalFocusLocked = compositionLocalOf { false }

/**
 * Mirrors `ThemedButtonStyle`: the focused version is the iPhone primary button character for character,
 * white with dark text. 10 % white when unfocused.
 *
 * **`released`: dimmed, not translucent** (`ThemedButtonStyle.foreground`/`background` when
 * `!released`): same reasoning as tvOS, white at 40 percent would look like a button that is
 * still waiting. Defaults to `true`, so no existing call breaks.
 */
@Composable
fun TvButton(text: String?, symbol: Glyph? = null, modifier: Modifier = Modifier, height: Dp = TvTheme.buttonHeight,
            released: Boolean = true, symbolToText: Boolean = false, description: String? = text, active: Boolean? = null,
            /** Menu key or long OK: the tile menu (`tileMenuPanel`). */
            lengthy: (() -> Unit)? = null,
            focusChanged: (Boolean) -> Unit = {}, perform: () -> Unit) {
    // **Icon-only buttons** (no visible text) still need a description for TalkBack; `description`
    // falls back to `text` where both coincide.
    FocusArea(modifier.semantics {
            role = Role.Button
            active?.let { selected = it }
            if (text == null) description?.let { contentDescription = it }
        }, magnifier = TvTheme.focusMagnifier, focusChanged = focusChanged, lengthy = lengthy, lift = true, liftCorner = TvTheme.corner,
        perform = { if (released) perform() }) { focus ->
        // The active watchlist button stays white (its filled symbol says it); Direct Play is the only colored mark.
        val color = if (!released) Theme.fontVeryQuiet else if (focus) Theme.reason else Theme.font
        // **A symbol alone has no surface at rest** below the 76 pt button row (the heart, bar icons); in the row it
        // carries the same .10 fill as the labelled buttons.
        val bare = text == null && height < TvTheme.buttonHeight
        Row(Modifier.height(height).then(if (text == null) Modifier.width(height) else Modifier)
                .clip(RoundedCornerShape(TvTheme.corner))
                .background(if (!released) Theme.area else if (focus) Color.White else if (bare) Color.Transparent else Color.White.copy(alpha = 0.10f))
                .padding(horizontal = if (text == null) 0.dp else 20.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally)) {
            val symbolContent: @Composable () -> Unit = { symbol?.let { Symbol(it, 15.dp, color = color, strength = Strength.Semibold, description = if (text != null) text else null) } }
            val textContent: @Composable () -> Unit = { text?.let { Text(it, style = TvTheme.button, color = color, maxLines = 1) } }
            // **Sort buttons show the arrow after the word** ("A-Z v" on tvOS), not a leading icon like every
            // other `TvButton`.
            if (symbolToText) { textContent(); symbolContent() } else { symbolContent(); textContent() }
        }
    }
}

/**
 * **Lets the remote leave a text field again**, for `TvField` and the search field (`TvSearch`).
 *
 * `BasicTextField` consumes Up and Down itself (caret to start/end of line) and reports them as
 * handled, so the D-pad could not leave the field, e.g. neither to "Next" nor to "Advanced" on the
 * server page once the keyboard was closed. And **OK brings the keyboard back**: Compose shows it
 * only on first focus, so after closing it with Back, OK did not reopen it. Only the remote's
 * center key; Enter on a real keyboard still triggers the keyboard action.
 */
@Composable
fun Modifier.remoteBarField(): Modifier {
    val focus = androidx.compose.ui.platform.LocalFocusManager.current
    val keyboard = androidx.compose.ui.platform.LocalSoftwareKeyboardController.current
    return onPreviewKeyEvent { e ->
        when (e.key) {
            Key.DirectionUp, Key.DirectionDown -> {
                if (e.type == KeyEventType.KeyDown)
                    focus.moveFocus(if (e.key == Key.DirectionUp) androidx.compose.ui.focus.FocusDirection.Up else androidx.compose.ui.focus.FocusDirection.Down)
                true
            }
            Key.DirectionCenter -> { if (e.type == KeyEventType.KeyUp) keyboard?.show(); true }
            else -> false
        }
    }
}

/**
 * Mirrors `Eingabefeld` in `Sources/tvOS/RootView.swift`. There an almost invisible `TextField`
 * sits behind the custom drawing, because tvOS forces a white capsule with glow and shadow on every
 * text field and it cannot be turned off. Compose needs no such detour: `BasicTextField` draws
 * nothing by itself and `decorationBox` takes over the whole surface, as in the search field in
 * `TvSearch`.
 */
@Composable
fun TvField(value: String, change: (String) -> Unit, placeholder: String, modifier: Modifier = Modifier,
          secret: Boolean = false, imeAction: ImeAction = ImeAction.Next,
          keyboardType: KeyboardType = KeyboardType.Text, keyboardAction: () -> Unit = {},
          /** Off while the page works on what was typed (`.disabled(...)` on tvOS). */
          enabled: Boolean = true) {
    var focus by remember { mutableStateOf(false) }
    val focusSteerer = androidx.compose.ui.platform.LocalFocusManager.current
    val keyboard = androidx.compose.ui.platform.LocalSoftwareKeyboardController.current
    // **The on-screen keyboard's key must always lead somewhere.** Custom `KeyboardActions` replace the
    // default behavior (close keyboard): a field without `keyboardAction` had a "Done" that did
    // nothing, so from the user name one could not reach the password. The default is therefore "Next"
    // into the next field; the final action dismisses the keyboard so the D-pad drives the page again.
    val complete = { keyboard?.hide(); keyboardAction() }
    if (secret) VisibilityProtection()
    val color = if (focus) Theme.reason else Theme.font
    BasicTextField(value, change, singleLine = true, enabled = enabled,
        textStyle = TvTheme.body.copy(color = color),
        cursorBrush = SolidColor(color),
        visualTransformation = if (secret) PasswordVisualTransformation() else VisualTransformation.None,
        keyboardOptions = KeyboardOptions(imeAction = imeAction, keyboardType = keyboardType),
        keyboardActions = KeyboardActions(onDone = { complete() }, onGo = { complete() }, onSearch = { complete() },
            onNext = { focusSteerer.moveFocus(androidx.compose.ui.focus.FocusDirection.Next) }),
        modifier = modifier.height(TvTheme.buttonHeight).onFocusChanged { focus = it.isFocused }.remoteBarField(),
        decorationBox = { inner ->
            // **No border**: a field is a filled capsule, not a drawn outline, on TV as well. At rest `area`,
            // not `erhoeht`: `erhoeht` is what lies **on** a surface.
            Box(Modifier.fillMaxSize().clip(RoundedCornerShape(TvTheme.corner))
                    .background(if (focus) Color.White else Theme.area)
                    .padding(horizontal = 15.dp), contentAlignment = Alignment.CenterStart) {
                if (value.isEmpty()) Text(placeholder, style = TvTheme.body,
                                        color = if (focus) Theme.reason.copy(alpha = 0.45f) else Theme.fontVeryQuiet)
                inner()
            }
        })
}

/**
 * Mirrors `ChipStyle`.
 *
 * **The selected chip carries the accent as its surface, a deliberate exception.** `erhoeht` against
 * `area` is #303030 against #262626: visible at a desk, not from three meters. A brightness step
 * does not survive distance, a color change does, and distance is the reason TV may deviate.
 * `reason` on `accent` gives 10.8:1.
 *
 * It used to be **filled white with dark text**, character for character the primary button, and
 * the library page shows several chips; only one filled surface per page is allowed.
 *
 * Focus is unaffected: on the selected chip the **light** accent replaces the veil, so it also
 * brightens instead of staying put. The border is gone: a surface says "can be pressed", focus says
 * the rest. **One weight**: 13 Medium, selected like at rest.
 */
@Composable
fun TvChip(text: String, an: Boolean, modifier: Modifier = Modifier, perform: () -> Unit) {
    FocusArea(modifier, magnifier = TvTheme.focusMagnifier, perform = perform) { focus ->
        Box(Modifier.heightIn(min = TvTheme.chipHeight).clip(CircleShape)
                .background(when {
                    an -> if (focus) Theme.accentLight else Theme.accent
                    focus -> TvTheme.focusArea
                    else -> Theme.area
                })
                .padding(horizontal = 11.dp),
            contentAlignment = Alignment.Center) {
            Text(text, style = TvTheme.tile, color = if (an) Theme.reason else Theme.fontQuiet, maxLines = 1)
        }
    }
}

/**
 * Mirrors `CapsuleStyle`: a capsule that expands something (library, filter, sort). Shape and height
 * as `TvChip` so the row has one shape. Background `erhoeht`, calm surface when focused; text
 * `tile` (13 Medium) in `font`.
 *
 * **With `symbol`, an icon in front instead of the trailing arrow, like the `ValuePill` on iPhone.**
 * Filter and sort appear there as a pill with icon and value, no arrow. Icon and arrow use alpha 0.6
 * instead of their own color so they follow the text. Sizes halved: icon 22 -> 11, arrow 18 -> 9,
 * gap 10 -> 5, inset 22 -> 11.
 */
@Composable
fun TvCapsule(text: String, modifier: Modifier = Modifier,
             /** `CapsuleStyle(symbol:)`; `null` means the trailing arrow. */
             symbol: Glyph? = null,
             /** `CapsuleStyle(arrow:)`: down when it expands something, right when it leads on. */
             arrow: Glyph = Glyph.AngleDown,
             /** `CapsuleStyle(active:)`: painted like focus while its panel is open (the opening pill stays white). */
             active: Boolean = false, perform: () -> Unit) {
    FocusArea(modifier, magnifier = TvTheme.focusMagnifier, lift = true, liftCorner = 100.dp, perform = perform) { focus0 ->
        val focus = focus0 || active
        val ink = if (focus) Theme.reason else Theme.font
        Row(Modifier.height(TvTheme.chipHeight).clip(CircleShape)
                .background(if (focus) Color.White else Color.White.copy(alpha = 0.10f))
                .padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            val quiet = ink.copy(alpha = 0.6f)
            symbol?.let { Symbol(it, 11.dp, color = quiet, strength = Strength.Medium) }
            Text(text, style = TvTheme.button.copy(fontSize = 13.sp), color = ink, maxLines = 1)
            if (symbol == null) Symbol(arrow, 11.dp, color = quiet, strength = Strength.Semibold)
        }
    }
}

/** Mirrors `RowsStyle`: selection lists and action panel: no magnification, just a calm surface. */
@Composable
fun TvRow(text: String, symbol: Glyph? = null, right: String? = null, checkmark: Boolean = false,
            modifier: Modifier = Modifier,
            /** The selected row of a selection panel carries its icon in the accent (`Handlungstafel.selected`). */
            symbolColor: Color = Theme.font,
            /** A long text may wrap (up to 3 lines) and the row grows with it, instead of being cut off. */
            wraps: Boolean = false, perform: () -> Unit) {
    FocusArea(modifier.fillMaxWidth(), magnifier = 1f, perform = perform) { focus ->
        Row(Modifier.fillMaxWidth().then(if (wraps) Modifier.heightIn(min = TvTheme.rowsHeight) else Modifier.height(TvTheme.rowsHeight)).clip(RoundedCornerShape(TvTheme.corner))
                .background(if (focus) TvTheme.focusArea else Color.Transparent).padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            symbol?.let { Symbol(it, 13.dp, color = symbolColor, strength = Strength.Medium) }
            // 15, and semibold when focused. A **vertical** list, so the weight change moves no neighbors
            // (as in `RowsStyle`).
            Text(text, style = if (focus) TvTheme.button else TvTheme.body.copy(fontWeight = FontWeight.Medium),
                 color = Theme.font, maxLines = if (wraps) 3 else 1, overflow = TextOverflow.Ellipsis,
                 modifier = Modifier.weight(1f).then(if (wraps) Modifier.padding(vertical = 8.dp) else Modifier))
            right?.let { Text(it, style = TvTheme.tile, color = Theme.fontQuiet, maxLines = 1) }
            if (checkmark) Symbol(Glyph.Checkmark, 13.dp, color = Theme.accent, strength = Strength.Semibold)
        }
    }
}

/**
 * Mirrors `MenuRowStyle` and the rows of the action panel (tvOS 1.1): 72 pt (36 dp) high, 20 pt padding, r16, 30/500
 * in fontQuiet; the selected one white 600; focus a white surface with dark text, no magnification.
 *
 * `check` set: a selection menu (sort, filter, library): a 30 pt check in a 32 pt slot, empty on the other rows.
 * `check` null: an action list with its own symbol in a 38 pt column.
 */
@Composable
fun TvMenuRow(text: String, modifier: Modifier = Modifier, symbol: Glyph? = null, check: Boolean? = null,
              selected: Boolean = false, cautionary: Boolean = false, right: String? = null,
              wraps: Boolean = false, perform: () -> Unit) {
    FocusArea(modifier.fillMaxWidth(), magnifier = 1f, perform = perform) { focus ->
        val ink = when {
            focus -> Theme.reason
            cautionary -> Theme.warning
            selected || check == true -> Theme.font
            else -> Theme.fontQuiet
        }
        Row(Modifier.fillMaxWidth().then(if (wraps) Modifier.heightIn(min = 36.dp) else Modifier.height(36.dp))
                .clip(RoundedCornerShape(TvTheme.corner))
                .background(if (focus) Color.White else Color.Transparent).padding(horizontal = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(if (check != null) 10.dp else 11.dp)) {
            if (check != null) {
                Box(Modifier.width(16.dp), contentAlignment = Alignment.Center) {
                    if (check) Symbol(Glyph.Checkmark, 15.dp, color = ink, strength = Strength.Semibold)
                }
            } else symbol?.let {
                Box(Modifier.width(19.dp), contentAlignment = Alignment.Center) { Symbol(it, 13.dp, color = ink, strength = Strength.Medium) }
            }
            Text(text, style = TvTheme.body.copy(fontWeight = if (focus || selected || check == true) FontWeight.SemiBold else FontWeight.Medium),
                 color = ink, maxLines = if (wraps) 3 else 1, overflow = TextOverflow.Ellipsis,
                 modifier = Modifier.weight(1f).then(if (wraps) Modifier.padding(vertical = 8.dp) else Modifier))
            right?.let { Text(it, style = TvTheme.tile, color = if (focus) Theme.reason else Theme.fontQuiet, maxLines = 1) }
        }
    }
}

/**
 * Mirrors `TileContent`: image, below it title and subtitle, **always there**, never over the
 * image and never only on focus. The magnification is the only focus indicator.
 */
@Composable
fun TvTile(image: String?, title: String, subline: String?, landscape: Boolean = false, progress: Double? = null,
             mark: String? = null, markCount: Int = 0,
             modifier: Modifier = Modifier, opacity: Float = 1f, titleQuiet: Boolean = false,
             /** Watched: the image is only darker, not translucent (`WATCHED_DIM`, like `Gesehenhaken`). */
             dimmed: Boolean = false,
             /** Menu key or long OK: the tile menu. */
             lengthy: (() -> Unit)? = null,
             focusChanged: (Boolean) -> Unit = {},
             /**
              * **A replacement for the image** (`TileContent.substitute`), only on a collection without its
              * own poster (`Sammlungsmosaik`). `null` everywhere else, and the image is shown as usual.
              */
             substitute: (@Composable () -> Unit)? = null, perform: () -> Unit) {
    val width = if (landscape) TvTheme.landscapeWidth else TvTheme.posterWidth
    // **The tile speaks as a whole**: title plus progress or badge, not just the title from the image
    // (the info below the image is visible, but TalkBack would not reach it otherwise).
    val share = progress?.takeIf { it > 0.0 && it < 1.0 }
    val marksWording = when (mark) {
        "offen" -> translated("%lld offen", markCount)
        "staffeln" -> if (markCount == 1) translated("1 Staffel") else translated("%lld Staffeln", markCount)
        "gesehen" -> translated("Gesehen")
        else -> null
    }
    val description = listOfNotNull(
        title, subline,
        share?.let { translated("%lld Prozent gesehen", (it * 100).toInt()) } ?: marksWording
    ).joinToString(", ")
    // The caption reads the tile's focus (`TileContent`): the focused title is white and semibold and drops 14 pt.
    var tileFocus by remember { mutableStateOf(false) }
    val drop by animateFloatAsState(if (tileFocus) TvTheme.captionDrop.value else 0f,
        if (motionReduced()) Motion.fadeReduced() else tween(TvTheme.focusDuration, easing = TvTheme.focusCurve), label = "titelsenkung")
    Column(modifier.width(width)) {
        FocusArea(modifier = Modifier.semantics(mergeDescendants = true) { contentDescription = description },
                  focusChanged = { tileFocus = it; focusChanged(it) }, lengthy = lengthy, lift = true, perform = perform) {
            Box(Modifier.size(width, if (landscape) TvTheme.landscapeHeight else TvTheme.posterHeight)
                    .clip(RoundedCornerShape(TvTheme.cornerTile)).background(Theme.area)) {
                // No placeholder drawing of its own: if the image is missing or still loading, `Theme.area`
                // stays visible, as `Picture` does in `Sources/tvOS/Style.swift` (also just a surface, no icon).
                if (substitute != null) Box(Modifier.fillMaxSize().alpha(opacity)) { substitute() }
                // Decorative: the tile already announces its description above, as a whole.
                else AsyncImage(model = image, contentDescription = null, contentScale = ContentScale.Crop,
                                colorFilter = if (dimmed) de.paulherter.swiftly.WATCHED_DIM else null,
                                modifier = Modifier.fillMaxSize().alpha(opacity))
                // Mirrors `ProgressBar` in `Sources/tvOS/Style.swift`: **flush with the bottom edge, full
                // width, square**; the rounding comes only from the tile's clipping.
                progress?.takeIf { it > 0 && de.paulherter.swiftly.LocalProgressShow.current }?.let { a ->
                    // 4 high (tvOS 8, halved), track **white 22 %** (was 30 in 1.0).
                    Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(4.dp)
                            .background(Color.White.copy(alpha = 0.22f))) {
                        Box(Modifier.fillMaxWidth(a.toFloat().coerceIn(0f, 1f)).fillMaxHeight().background(Theme.accent))
                    }
                }
                // Mirrors `Kachelplakette` in `Sources/tvOS/TVComponents.swift`: check mark, "N open" or "N seasons".
                // Also shown over a missing poster, as on tvOS.
                mark?.let { TvTileBadge(it, markCount, Modifier.align(Alignment.TopEnd)) }
            }
        }
        // **Only the focused tile's title is white and semibold**; the others step back to fontQuiet (watched titles
        // too, `titleQuiet`). Design: caption mt 18, 26/500, one 34 high line, drops 14 when focused (pt / 2 here).
        Column(Modifier.padding(top = TvTheme.captionTop).graphicsLayer { translationY = drop.dp.toPx() }) {
            Text(title, style = if (tileFocus) TvTheme.tileFocused else TvTheme.tile,
                 color = if (tileFocus) Theme.font else Theme.fontQuiet,
                 maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.height(TvTheme.captionLine))
            subline?.let { Text(it, style = TvTheme.small, color = Theme.fontVeryQuiet, maxLines = 1, overflow = TextOverflow.Ellipsis) }
        }
    }
}

/**
 * Mirrors `TileBadge` (tvOS 1.1): "N offen" 36 high, padding 12, r10, 20/600 tracked .5 on #101010 72 %, 14 from the
 * corner; the seen mark a 44 square, r12, check 26, #101010 70 %, 16 from the corner (all pt / 2 here).
 */
@Composable
fun TvTileBadge(mark: String, figure: Int, modifier: Modifier = Modifier) {
    val wording = when (mark) {
        "offen" -> translated("%lld offen", figure)
        "staffeln" -> if (figure == 1) translated("1 Staffel") else translated("%lld Staffeln", figure)
        else -> null
    }
    val ink = Color(0xFF101010)
    if (mark == "gesehen") {
        Box(modifier.padding(8.dp).size(22.dp).clip(RoundedCornerShape(6.dp)).background(ink.copy(alpha = 0.7f)),
            contentAlignment = Alignment.Center) {
            Symbol(Glyph.Checkmark, 13.dp, color = Theme.font, strength = Strength.Semibold)
        }
    } else if (wording != null) {
        Box(modifier.padding(7.dp).height(18.dp).clip(RoundedCornerShape(5.dp)).background(ink.copy(alpha = 0.72f))
                .padding(horizontal = 6.dp), contentAlignment = Alignment.Center) {
            Text(wording, style = TvTheme.badge.copy(letterSpacing = 0.25.sp), color = Theme.font, maxLines = 1)
        }
    }
}

/** Row title: above the strip, inset like the tiles. */
@Composable
fun TvRailsTitle(text: String, modifier: Modifier = Modifier) {
    Text(text, style = TvTheme.rail, color = Theme.font, maxLines = 1,
         modifier = modifier.padding(start = TvTheme.edgePage, bottom = TvTheme.titleSpacing - TvTheme.railsPadding))
}

/**
 * Mirrors `HeaderHistory`: darkens the top edge so the top bar stays legible over continuous
 * imagery. **Only on subpages of the sections**, not on Home: there a fixed hero zone sits above
 * the scrolling list and nothing slides under the bar, the same reason tvOS omits the gradient there.
 *
 * Point values from tvOS **halved to dp**, same stops as there (three would show a visible edge
 * where the slope changes).
 */
@Composable
fun TvHeaderHistory(modifier: Modifier = Modifier, headerHeight: Dp = 64.dp, outro: Dp = 110.dp,
                    soft: Boolean = false, strength: Float = 1f) {
    val total = if (soft) 150.dp else headerHeight + outro
    fun point(y: Dp, coverage: Float) = (y.value / total.value).coerceIn(0f, 1f) to Theme.reason.copy(alpha = coverage * strength)
    // `soft`: tvOS 1.1 `HeaderHistory(soft:)`: 300 pt (150 dp) high, .92 at the top, .6 at 55 %, 0 at the end.
    val levels = if (soft) listOf(
        0f to Theme.reason.copy(alpha = 0.92f * strength),
        0.55f to Theme.reason.copy(alpha = 0.6f * strength),
        1f to Theme.reason.copy(alpha = 0f),
    ) else listOf(
        point(0.dp, 0.92f),
        point(headerHeight, 0.90f),
        point(headerHeight + 9.dp, 0.72f),
        point(headerHeight + 18.dp, 0.52f),
        point(headerHeight + 27.dp, 0.34f),
        point(headerHeight + 36.dp, 0.18f),
        point(headerHeight + 43.dp, 0.09f),
        point(headerHeight + 52.dp, 0.04f),
        point(headerHeight + 66.dp, 0.015f),
        point(total, 0f),
    )
    Box(modifier.fillMaxWidth().height(total)
            .background(Brush.verticalGradient(colorStops = levels.toTypedArray())))
}

/**
 * Mirrors `Hinweisstreifen` in `Sources/tvOS/Style.swift`: warning band with triangle and text,
 * disappears after six seconds. Sizes halved against tvOS, like everywhere in `TvTheme`. Wired as on
 * the phone (`TitlePage.Hinweisstreifen`): its own `meldung` state per page, no shared place like
 * `AppModel.errorMessage` on tvOS, since Android has no such source.
 */
@Composable
fun TvHintStrip(text: String, modifier: Modifier = Modifier, close: () -> Unit) {
    LaunchedEffect(text) {
        kotlinx.coroutines.delay(6000)
        close()
    }
    Row(modifier.widthIn(max = 550.dp)
            .clip(RoundedCornerShape(TvTheme.corner))
            .background(Theme.raised)
            .border(1.dp, Theme.warning.copy(alpha = 0.3f), RoundedCornerShape(TvTheme.corner))
            .padding(horizontal = 15.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        Symbol(Glyph.Warning, 13.dp, color = Theme.warning)
        Text(text, style = TvTheme.tile, color = Theme.warning, maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
}

/**
 * Mirrors the Discord notice on tvOS (`CodeSheet(target: .discord)`): **once per installation**, after
 * the fifth finished title (`Community.kickoff`). Instead of the QR code the invitation to type
 * in, since a QR image would need a library of its own here. Back closes.
 */
@Composable
fun TvDiscordHint(invitation: String, close: () -> Unit) {
    androidx.activity.compose.BackHandler(onBack = close)
    val focus = remember { androidx.compose.ui.focus.FocusRequester() }
    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
    Box(Modifier.fillMaxSize().background(Theme.reason), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(translated("Swiftly hat einen Discord"), style = TvTheme.titleLarge, color = Theme.font)
            Text(translated("Da kannst du Fragen stellen und Fehler melden. Neue Builds stehen da auch zuerst."),
                 style = TvTheme.body.copy(textAlign = TextAlign.Center), color = Theme.fontQuiet,
                 modifier = Modifier.widthIn(max = 550.dp).padding(top = 8.dp))
            Text(invitation, style = TvTheme.titleLarge, color = Theme.font, modifier = Modifier.padding(top = 36.dp))
            TvButton(translated("Zurück"), modifier = Modifier.padding(top = 36.dp).focusRequester(focus), perform = close)
        }
    }
}

/**
 * Mirrors `SettingsRowsStyle` (settings look) on tvOS: a row of the design, 84 pt (42 dp) at least, 30/500 white,
 * no surface at rest. In focus a white surface reaches 13 dp (26 pt) over the group on both sides, r8,
 * dark type, 1.03 larger, with the lift shadow. The group around it pads the same 13 dp horizontally.
 */
@Composable
fun TvSettingsRow(modifier: Modifier = Modifier, enabled: Boolean = true, focusChanged: (Boolean) -> Unit = {},
                  spacing: Dp = 0.dp, perform: () -> Unit, content: @Composable RowScope.(focus: Boolean) -> Unit) {
    FocusArea(modifier.fillMaxWidth().focusProperties { canFocus = enabled }, magnifier = TvTheme.focusMagnifierWide, lift = true,
              liftCorner = TvTheme.corner, focusChanged = focusChanged, perform = { if (enabled) perform() }) { focus ->
        Box(Modifier.fillMaxWidth().heightIn(min = TvTheme.rowsHeight)) {
            if (focus) Box(Modifier.matchParentSize()
                .layout { m, c -> val p = m.measure(c.copy(minWidth = c.maxWidth + 26.dp.roundToPx(), maxWidth = c.maxWidth + 26.dp.roundToPx())); layout(c.maxWidth, p.height) { p.place(-13.dp.roundToPx(), 0) } }
                .clip(RoundedCornerShape(TvTheme.corner)).background(Color.White))
            Row(Modifier.fillMaxWidth().heightIn(min = TvTheme.rowsHeight).alpha(if (enabled) 1f else 0.4f),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(spacing), content = { content(focus) })
        }
    }
}
