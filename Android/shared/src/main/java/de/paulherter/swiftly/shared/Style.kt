package de.paulherter.swiftly.shared

import android.content.Context
import android.provider.Settings
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * **The phone's look, copied, not invented.**
 *
 * Source: `Sources/Shared/Colors.swift` (colors) and `Sources/Shared/Style.swift` (dimensions,
 * type; sections "Maße — iPhone" and "Schrift — iPhone"). **Never from `Sources/macOS/Style.swift`**:
 * that is the Mac file with different numbers, and mixing them up cost a whole round on Linux.
 *
 * If a value changes there, it changes here, with the same names.
 *
 * **dp instead of pt.** An iOS point and an Android dp are the same measure (1/160 inch vs 1/163
 * on Apple), so the numbers are taken unchanged. Type sizes are `sp` so the system font size
 * scales them (Dynamic Type on Android, at no cost).
 */
/**
 * **The phone's motion**, mirroring the curves in `Sources/Shared/Style.swift` (`einblenden`,
 * `sectionSwitch`, `sprung`, `toggle`, `sheetMotion`) and the `NavigationStack` push.
 * `.smooth` and `.snappy` do not spring back: quick in, soft out.
 */
object Motion {
    val soft = CubicBezierEasing(0.2f, 0f, 0f, 1f)
    /** `easeOut`: Apple's curve, same numbers as `UIView.AnimationCurve.easeOut`. */
    val outro = CubicBezierEasing(0f, 0f, 0.58f, 1f)
    /**
     * **UIKit's navigation curve, measured**, the one compose-cupertino uses for
     * `UINavigationController`. Several own attempts looked wrong at pixel level.
     */
    val cupertino = CubicBezierEasing(0.2833f, 0.99f, 0.31833f, 0.99f)
    /** `Theme.einblenden`: `.smooth(duration: 0.28)`. Tiles, images, placeholder to content. */
    fun <T> reveal(): FiniteAnimationSpec<T> = tween(280, easing = soft)
    /** `Theme.sectionSwitch`: `.snappy(duration: 0.20)`. */
    fun <T> sectionSwitch(): FiniteAnimationSpec<T> = tween(200, easing = soft)
    /** `Theme.sprung`: `.snappy(duration: 0.22)`. Expanding, chevrons. */
    fun <T> leap(): FiniteAnimationSpec<T> = tween(220, easing = soft)
    /** `Theme.toggle`: `.easeOut(duration: 0.1)`. */
    fun <T> toggle(): FiniteAnimationSpec<T> = tween(100, easing = outro)
    /** `Theme.sheetMotion`: `.spring(response: 0.35, dampingFraction: 0.86)`; stiffness (2π / 0.35)² ≈ 322. */
    fun <T> sheet(): FiniteAnimationSpec<T> = spring(dampingRatio = 0.86f, stiffness = 322f)
    /** `Motion.change`: `.smooth(duration: 0.28)`. A look's colors and glow, a step of a sheet. */
    fun <T> change(): FiniteAnimationSpec<T> = tween(280, easing = soft)
    /** `Motion.select`: `.smooth(duration: 0.25)`. The segments' surface, the ring around a dot. */
    fun <T> select(): FiniteAnimationSpec<T> = tween(250, easing = soft)
    /** `Motion.land`: `.spring(response: 0.45, dampingFraction: 0.86)`; stiffness (2π / 0.45)² ≈ 195. */
    fun <T> land(): FiniteAnimationSpec<T> = spring(dampingRatio = 0.86f, stiffness = 195f)
    /** `Motion.pageBeforeSheet`: the page goes first, the sheet follows 0.18 s later. */
    const val PageBeforeSheetMs = 180L
    /** `Theme.fadeReduced`: 0.14 s linear, when reduced motion is on. */
    fun <T> fadeReduced(): FiniteAnimationSpec<T> = tween(140, easing = LinearEasing)
    /**
     * The `NavigationStack` push: about 350 ms, quick start, long tail. **Not the UIKit curve**: for
     * opening it was too fast at pixel level; for going back it is right.
     */
    fun <T> page(): FiniteAnimationSpec<T> = tween(350, easing = CubicBezierEasing(0.25f, 0.8f, 0.25f, 1f))
    /** Back via the button: **same length as opening**; unequal durations read as a wrong curve. */
    fun <T> back(): FiniteAnimationSpec<T> = tween(350, easing = cupertino)
    /**
     * **After a gesture, continue at the finger's speed** with no overshoot, so a fling does not first
     * brake and then restart. For the back gesture and a thrown sheet.
     */
    // As compose-cupertino on release: a fast spring without overshoot (StiffnessMedium).
    fun <T> toss(): FiniteAnimationSpec<T> = spring(dampingRatio = 1f, stiffness = 1500f)
    /**
     * `pressCurve` on release: 0.12 s **`easeOut`**, not linear. The press itself has **no**
     * duration: feedback that fades in comes too late.
     */
    fun <T> release(): FiniteAnimationSpec<T> = tween(120, easing = outro)
    /** `Theme.sectionMetric`: corrected downward three times; 0.97 and 0.99 were visible at the top edge. */
    const val SectionMetric = 0.995f
    /** `Theme` press scale: 0.97 on **every** button. */
    const val PressMetric = 0.97f

    /**
     * **"Remove animations" / "Reduce motion".**
     *
     * With animations off, Android sets the duration of all Compose animations to zero itself, so
     * one-off motion needs nothing. **Continuous motion is not covered:** an endless loop with
     * duration 0 keeps running, just harshly. Anything that pulses (loading grid, breathing glyph)
     * checks this, as `Theme.motionReduced` is checked on Apple.
     */
    fun reduced(context: Context): Boolean =
        Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
}

/**
 * The same, **read once per view instead of once per frame.**
 *
 * `Motion.reduziert` queries system storage; in `FocusArea` the call sits behind every tile
 * of a row and would rerun on each recomposition. The setting does not change during a view.
 */
@Composable
fun motionReduced(): Boolean {
    val context = LocalContext.current
    return remember(context) { Motion.reduced(context) }
}

object Theme {
    // MARK: Colors (verbatim from Colors.swift)
    //
    // **All neutral tones are truly neutral: R = G = B, chroma 0.000.** They were once at hue 285.9
    // (read reddish), then at the accent's hue (greenish), then on Apple's blue track. Read the
    // brand rules before changing hue again.
    //
    // Ground and surfaces are counted out pixel by pixel from a reference app: measured, not chosen.
    // Pure black exists in exactly one place: behind the picture in the player.

    /** The ground of **every** page. */
    val reason = Color(0xFF101010)
    /** The card on a settings page: one large, calm block. */
    val groupsArea = Color(0xFF1E1E1E)
    /** **Everything you can touch:** buttons, fields, pills, sheets. One tone, not two. */
    val area = Color(0xFF262626)
    /** What lies on a `area`: selected chip, selected row. */
    val raised = Color(0xFF303030)
    /**
     * The surface of a **pressed** secondary button. Own value, not `erhoeht.copy(alpha = 1.6f)`:
     * alpha above 1 clamps to 1.0 and the press was invisible. **Only full-strength text on it**
     * (`schriftSehrLeise` has 3.94:1 here).
     */
    val pressedArea = Color(0xFF3A3A3A)

    /**
     * **Solid values, no alpha.** Alpha changes its effect as soon as something lies beneath: over a
     * poster "quiet" became "unreadable". Contrast on `reason`: 19.03 / 11.85 / 6.60; on `area`
     * 15.13 / 9.42 / 5.25; on `erhoeht` 13.20 / 8.22 / 4.58.
     */
    val font = Color(0xFFFFFFFF)
    val fontQuiet = Color(0xFFCCCCCC)
    val fontVeryQuiet = Color(0xFF989898)

    /** Hairline between rows. Alpha, because it also lies over posters. */
    val line = Color.White.copy(alpha = 0.07f)
    /** The few places that need an edge. **Not buttons, fields or pills.** */
    val margin = Color.White.copy(alpha = 0.12f)
    /** The surface of a selected or playing row. */
    val selected = Color.White.copy(alpha = 0.08f)

    /**
     * **Carries state: never rank, never a surface, never a mere label.**
     * Progress, selection, Direct Play proof.
     */
    val accent: Color get() = tones.value.main
    /** The accent lightened: **only the selected filter chip while focused on TV.** */
    val accentLight: Color get() = tones.value.light
    /** The surface under accent text (badges use 15 %; this is that tone computed out). */
    val accentQuiet: Color get() = tones.value.quiet
    /** Text on an accent surface. */
    val onAccent: Color get() = tones.value.on

    /** Something is waiting for someone. An orange or red look turns it amber (see `LookAccent.warning`). */
    val warning: Color get() = tones.value.warning

    /**
     * **The accent's tones as state**, so a look change redraws everything that reads them. Only
     * the phone activity ever sets them (`applyTones`); everything else keeps today's turquoise.
     */
    class Tones(val main: Color, val light: Color, val quiet: Color, val on: Color,
                val warning: Color = Color(0xFFE8833A))

    private val tones = androidx.compose.runtime.mutableStateOf(
        Tones(Color(0xFF50D5DA), Color(0xFF7AE6EA), Color(0xFF113435), Color(0xFF061212)))
    fun applyTones(value: Tones) { tones.value = value }

    /** The play mark of the wordmark, top left to bottom right; one color is a flat fill. */
    private val gradient = androidx.compose.runtime.mutableStateOf<List<Color>?>(null)
    val markGradient: List<Color>? get() = gradient.value
    fun applyMarkGradient(colors: List<Color>?) { gradient.value = colors }

    /** Something went wrong: **not the same as "waiting".** Carries no text on `erhoeht` (4.23). */
    val error = Color(0xFFEF6567)

    /**
     * **The eight tones of the profile glyphs**: eight hues 45 degrees apart, the first is the
     * accent's, all with the same lightness and saturation (OKLCH L 0.52 / C 0.105 top, L 0.36 /
     * C 0.085 bottom). The color is computed from the name, so the same person always gets the
     * same one. They say nothing about state, they only tell people apart.
     */
    val profileAudio: List<Pair<Color, Color>> = listOf(
        Color(0xFF007A7F) to Color(0xFF004A4E),
        Color(0xFF286EA1) to Color(0xFF054166),
        Color(0xFF675EA1) to Color(0xFF3C3467),
        Color(0xFF8D5082) to Color(0xFF572A50),
        Color(0xFF9C4D51) to Color(0xFF62282B),
        Color(0xFF925A1B) to Color(0xFF5B3100),
        Color(0xFF6E6D14) to Color(0xFF414000),
        Color(0xFF2E7A4C) to Color(0xFF0A4A27),
    )

    // MARK: Corners (Style.swift)
    //
    // Nested: outer = inner + padding. **No shadows, no drawn borders**: a surface says "you can
    // press here", a border would say it a second time.
    //
    // Compose rounds like Apple's `.circular`; Apple's `.continuous` starts flatter and runs out
    // longer. At 8 to 16 dp the difference is barely at the threshold of perception and would need
    // a custom `Shape` (own Bezier math in every component). Deliberately not done.

    /** Button, poster, tile: under 48 dp height. */
    val corner = 10.dp
    val cornerTile = 10.dp
    /** Search and input field. */
    val cornerField = 12.dp
    /** Under 34 dp height: season field, badges. */
    val cornerSmall = 8.dp
    /** Settings card, group. */
    val cornerCard = 14.dp
    /** Own surface, panel, info box. */
    val cornerArea = 16.dp
    /** Sheet from below: top corners only. */
    val cornerSheet = 28.dp

    // MARK: Space (Style.swift, "Maße — iPhone")

    /** The page margin, and thus the most common spacing in the app. */
    val edgeSpacing = 18.dp
    /** The page margin in the wide layout (tablet, unfolded foldable). */
    val edgePageWide = 28.dp
    val tileSpacing = 12.dp
    /** Row to row on the home page. */
    val railsSpacing = 28.dp
    /** Row spacing in the grid: library, watchlist, genre, search. */
    val gridRow = 20.dp
    val headerTop = 26.dp
    val tileWidth = 112.dp
    val tileHeight = 168.dp
    val heroHeightValue = 300.dp
    val heroHeightWide = 420.dp
    val stripHeight = 54.dp
    val sidebarWidth = 88.dp
    /** 30 pill height + 14 spacing: how far the value row collapses when scrolling. */
    val valueRailsDistance = 44.dp
    val readWidth = 700.dp
    val formWidth = 420.dp

    /** Height of every button and every input field. */
    val buttonHeight = 48.dp
    /** Height of value pill and choice chip (as minimum height). */
    val pillsHeight = 30.dp
    /** Hit area of a quiet button. */
    val stillHeight = 44.dp

    /** Target width of a grid tile: `tileTarget(wide: false)`. */
    const val tileTarget = 104f

    /** `Theme.rand(wide:)`: 18 narrow, 28 wide. */
    fun margin(wide: Boolean) = if (wide) edgePageWide else edgeSpacing

    /** `Theme.columns(usableNow:wide:)`: tiles stretch, every phone ends up with three. */
    fun columns(usableNow: Float): Int = maxOf(2, ((usableNow + 12f) / (tileTarget + 12f)).toInt())

    // MARK: Type (Style.swift, "Schrift — iPhone")
    //
    // **Ten levels, nine sizes, three weights.** Regular, Medium, Semibold, plus Bold exactly once
    // on the page title. There is no `.light` or `.heavy`, without exception.
    //
    // **Tracking belongs to the level, not to the place of use**; each value is the em value times
    // the point size. In Compose `letterSpacing` in `sp` is the same measure as SwiftUI's `tracking`
    // in points.
    //
    // **Only uppercase text is tracked**: the tile badge carries "3 offen", ordinary words, and does
    // not take its level's tracking.

    /** 28 Bold: the title of a root page, also over a hero image. */
    val titleLarge = TextStyle(fontSize = 28.sp, fontWeight = FontWeight.Bold, letterSpacing = (-0.6).sp)
    /** Same level. `title` and `titleLarge` are the same value on iPhone. */
    val title = titleLarge
    /** 22 Semibold: a subpage, i.e. one with a way back. */
    val subpageTitle = TextStyle(fontSize = 22.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-0.308).sp)
    /** 20 Semibold: row heading, group title, header of an empty state. */
    val rail = TextStyle(fontSize = 20.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-0.24).sp)
    /** 17 Semibold: sheet heading, detail bar, main button. */
    val categoryLarge = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-0.136).sp)
    /** 15 Semibold: the list row. */
    val listTitle = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
    /** 15 Regular: body text. */
    val body = TextStyle(fontSize = 15.sp)
    /** 15 Medium: secondary and quiet button. */
    val buttonText = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.Medium)
    /** 13 Medium: title under a poster, value pill, count badge, choice chip. */
    val tile = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium)
    /** 13 Semibold: the chevron at the right of a row. */
    val angle = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
    /** 12 Regular: detail line: year, role, runtime, subtitle. */
    val small = TextStyle(fontSize = 12.sp)
    /** 11 Semibold, tracked: group title in uppercase. */
    val group = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.54.sp)
    /** 10 Semibold, tracked: badge and tile badge. */
    val badge = TextStyle(fontSize = 10.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.0.sp)

    // MARK: Glyphs
    //
    // Control glyphs are as large as the text next to them: 17 in a 20-wide column in a row, 17 in
    // a field, 20 in the nav bar.
    val symbolText = 17.dp
    val characterColumn = 20.dp
    val characterBar = 20.dp
    /** The glyph in an empty state, in a circle of 78. */
    val characterEmpty = 44.dp
    val circleEmpty = 78.dp
}
