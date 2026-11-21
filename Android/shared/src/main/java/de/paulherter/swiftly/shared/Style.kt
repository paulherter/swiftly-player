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
    /** `PressButton`: opacity 0.85 while pressed, together with the 0.97 scale. */
    const val PressOpacity = 0.85f

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

/** The typeface: Inter Variable, bundled (`res/font/inter_variable.ttf`), as on every Apple platform. */
@OptIn(androidx.compose.ui.text.ExperimentalTextApi::class)
val Inter = androidx.compose.ui.text.font.FontFamily(
    listOf(400, 500, 600, 700, 800).map { w ->
        androidx.compose.ui.text.font.Font(R.font.inter_variable, androidx.compose.ui.text.font.FontWeight(w),
            variationSettings = androidx.compose.ui.text.font.FontVariation.Settings(
                androidx.compose.ui.text.font.FontVariation.weight(w)))
    })

object Theme {
    /**
     * Android TV keeps its own look for now (separate pass); the phone reads every colour, radius and spacing below
     * from `DesignTokens` (touch layout, generated). Set once in `TvActivity.onCreate`.
     */
    @JvmStatic var tvMode: Boolean = false

    // MARK: Colors (verbatim from Colors.swift)
    //
    // **All neutral tones are truly neutral: R = G = B, chroma 0.000.** They were once at hue 285.9
    // (read reddish), then at the accent's hue (greenish), then on Apple's blue track. Read the
    // brand rules before changing hue again.
    //
    // Ground and surfaces are counted out pixel by pixel from a reference app: measured, not chosen.
    // Pure black exists in exactly one place: behind the picture in the player.

    // Ground and the four surface steps read the palette tokens on phone and TV alike (TV had its own greys).
    /** The ground of **every** page. */
    val reason get() = Color(DesignTokens.Palette.SURFACE_BASE)
    /** The card on a settings page: one large, calm block. */
    val groupsArea get() = Color(DesignTokens.Palette.SURFACE_GROUP)
    /** **Everything you can touch:** buttons, fields, pills, sheets. One tone, not two. */
    val area get() = Color(DesignTokens.Palette.SURFACE_CONTROL)
    /** What lies on a `area`: selected chip, selected row. */
    val raised get() = Color(DesignTokens.Palette.SURFACE_RAISED)
    /**
     * The surface of a **pressed** secondary button. Own value, not `erhoeht.copy(alpha = 1.6f)`:
     * alpha above 1 clamps to 1.0 and the press was invisible. **Only full-strength text on it**
     * (`schriftSehrLeise` has 3.94:1 here).
     */
    val pressedArea get() = Color(DesignTokens.Palette.SURFACE_PRESSED)

    /**
     * **Solid values, no alpha.** Alpha changes its effect as soon as something lies beneath: over a
     * poster "quiet" became "unreadable". Contrast on `reason`: 19.03 / 11.85 / 6.60; on `area`
     * 15.13 / 9.42 / 5.25; on `erhoeht` 13.20 / 8.22 / 4.58.
     */
    val font get() = if (tvMode) Color(0xFFFFFFFF) else Color(DesignTokens.Palette.TEXT_PRIMARY)
    val fontQuiet get() = if (tvMode) Color(0xFFCCCCCC) else Color(DesignTokens.Palette.TEXT_SECONDARY)
    val fontVeryQuiet get() = if (tvMode) Color(0xFF989898) else Color(DesignTokens.Palette.TEXT_TERTIARY)

    /** Hairline between rows. Alpha, because it also lies over posters. */
    val line get() = if (tvMode) Color.White.copy(alpha = 0.07f) else Color(DesignTokens.Palette.BORDER_HAIRLINE)
    /** The few places that need an edge. **Not buttons, fields or pills.** */
    val margin get() = if (tvMode) Color.White.copy(alpha = 0.12f) else Color(DesignTokens.Palette.BORDER_EDGE)
    /** The surface of a selected or playing row. */
    val selected get() = if (tvMode) Color.White.copy(alpha = 0.08f) else Color(DesignTokens.Palette.SURFACE_SELECTED)

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

    /** Something went wrong: **not the same as "waiting".** Carries no text on `erhoeht` (4.23). */
    val error get() = Color(DesignTokens.Palette.STATE_ERROR)

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

    /**
     * The tone of a profile glyph, from the name (`ProfileCharacter.reason`): the same number as on Apple
     * (31 times the sum so far plus the code point, modulo 1,000,003), so the same person has the same
     * colour on every device.
     */
    fun profileBrush(name: String): androidx.compose.ui.graphics.Brush {
        var digit = 0
        name.codePoints().forEach { digit = (digit * 31 + it) % 1_000_003 }
        val (top, bottom) = profileAudio[digit % profileAudio.size]
        return androidx.compose.ui.graphics.Brush.linearGradient(listOf(top, bottom))
    }

    // MARK: Corners (Style.swift)
    //
    // Nested: outer = inner + padding. **No shadows, no drawn borders**: a surface says "you can
    // press here", a border would say it a second time.
    //
    // Compose rounds like Apple's `.circular`; Apple's `.continuous` starts flatter and runs out
    // longer. At 8 to 16 dp the difference is barely at the threshold of perception and would need
    // a custom `Shape` (own Bezier math in every component). Deliberately not done.

    /** Button, poster, tile: under 48 dp height. */
    val corner get() = if (tvMode) 10.dp else DesignTokens.Touch.RADIUS_CONTROL.dp
    val cornerTile get() = if (tvMode) 10.dp else DesignTokens.Touch.RADIUS_TILE.dp
    /** Search and input field. */
    val cornerField get() = if (tvMode) 10.dp else DesignTokens.Touch.RADIUS_FIELD.dp
    /** Under 34 dp height: season field, badges. */
    val cornerSmall get() = if (tvMode) 8.dp else DesignTokens.Touch.RADIUS_SMALL.dp
    /** Settings card, group. */
    val cornerCard get() = if (tvMode) 16.dp else DesignTokens.Touch.RADIUS_CARD.dp
    /** Own surface, panel, info box. */
    val cornerArea get() = if (tvMode) 16.dp else DesignTokens.Touch.RADIUS_AREA.dp
    /** Sheet from below: top corners only. */
    val cornerSheet get() = if (tvMode) 28.dp else DesignTokens.Touch.RADIUS_SHEET.dp
    /** The primary button on a detail page (the continue / play button). */
    val cornerButton get() = if (tvMode) 10.dp else DesignTokens.Touch.RADIUS_BUTTON.dp
    /** Height of the thin progress line inside the primary button. */
    val buttonProgressHeight get() = DesignTokens.Touch.SIZE_BUTTON_PROGRESS.dp
    /** Height of the primary button. */
    val primaryHeight get() = if (tvMode) 48.dp else DesignTokens.Touch.SIZE_PRIMARY_HEIGHT.dp

    // MARK: Space (Style.swift, "Maße — iPhone")

    /** The page margin, and thus the most common spacing in the app. */
    val edgeSpacing get() = if (tvMode) 18.dp else DesignTokens.Touch.SPACE_PAGE.dp
    /** The page margin in the wide layout (tablet, unfolded foldable). */
    val edgePageWide = 28.dp
    val tileSpacing = 12.dp
    /** Row to row on the home page. */
    val railsSpacing = 40.dp
    /** Row spacing in the grid: library, watchlist, genre, search. */
    val gridRow = 32.dp
    val headerTop get() = if (tvMode) 28.dp else DesignTokens.Touch.SPACE_HEADER_TOP.dp
    val tileWidth = 116.dp
    val tileHeight = 174.dp
    val heroHeightValue = 350.dp
    val heroHeightWide = 420.dp
    val stripHeight = 54.dp
    val sidebarWidth = 88.dp
    /** 30 pill height + 14 spacing: how far the value row collapses when scrolling. */
    val valueRailsDistance = 44.dp
    val readWidth = 700.dp
    val formWidth = 420.dp

    /** Height of every button and every input field: token `size.control-height` (Android TV keeps 56). */
    val buttonHeight get() = if (tvMode) 56.dp else DesignTokens.Touch.SIZE_CONTROL_HEIGHT.dp
    /** A list row (`rowHeight`). */
    val rowHeight = 60.dp
    /** One side margin per sheet (`sheetInset`). */
    val sheetInset = 24.dp
    /** Space above a settings group (`groupTop`) and between cards (`cardGap`). */
    val groupTop = 48.dp
    val cardGap = 32.dp
    // Round 2 system sizes (`Theme` in Sources/Shared/Style.swift).
    /** Icon column, title size, symbol size and vertical padding of a list row. */
    val rowIconWidth = 26.dp
    val rowTitleSize = 17.sp
    val rowSymbolSize = 20.dp
    val rowPadV get() = if (tvMode) 10.dp else DesignTokens.Touch.SPACE_ROW_PAD_V.dp
    /** Left and right padding of a settings row. */
    val rowPadH get() = DesignTokens.Touch.SPACE_ROW_PAD_H.dp
    /** Pulls the first settings group up under the subpage title (`firstGroupTrim`). */
    val firstGroupTrim = 20.dp
    /** Back arrow inset (`backInset`). */
    val backInset = 2.dp
    /** Action symbol (heart, bookmark, profile mark) and the gaps in the detail header. */
    val actionSymbol = 22.dp
    val actionGap = 16.dp
    val blockGap = 20.dp
    /** Landscape row tile on Start. */
    val heroRowWidth = 280.dp
    val heroRowHeight = 158.dp
    /** Cast circle. */
    val castSize = 88.dp
    val castWidth = 88.dp
    /** Episode thumbnail, and while it is the ongoing one. */
    val episodeWidth = 148.dp
    val episodeWidthOngoing = 168.dp
    val episodeHeight = 83.dp
    /** Empty state: disc, symbol and text width. */
    val emptyDisc = 120.dp
    val emptySymbol = 52.dp
    val emptyTextWidth = 300.dp
    /** Highest a sheet's list grows before it scrolls. */
    val sheetListMax = 420.dp
    val tabIconHeight = 26.dp

    /** Height of value pill and choice chip (as minimum height). */
    val pillsHeight get() = if (tvMode) 30.dp else DesignTokens.Touch.SIZE_CHIP_HEIGHT.dp
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

    /** Phone text style from a `type` token (size, weight, tracking); Android TV keeps its own style. */
    private fun role(tvStyle: TextStyle, size: Float, weight: Int, tracking: Float) =
        if (tvMode) tvStyle
        else TextStyle(fontFamily = Inter, fontSize = size.sp, fontWeight = FontWeight(weight), letterSpacing = tracking.sp)
    private fun tv(size: Int, weight: FontWeight, tracking: Float = 0f) =
        TextStyle(fontFamily = Inter, fontSize = size.sp, fontWeight = weight, letterSpacing = tracking.sp)

    /** Token `title.large`: the title of a root page, also over a hero image. */
    val titleLarge get() = role(tv(34, FontWeight.Bold, -0.7f), DesignTokens.Touch.TEXT_TITLE_LARGE_SIZE,
        DesignTokens.Touch.TEXT_TITLE_LARGE_WEIGHT, DesignTokens.Touch.TEXT_TITLE_LARGE_TRACKING)
    /** Same level. `title` and `titleLarge` are the same value on iPhone. */
    val title get() = titleLarge
    /** Token `title.subpage`: a subpage, i.e. one with a way back. */
    val subpageTitle get() = role(tv(28, FontWeight.Bold, -0.4f), DesignTokens.Touch.TEXT_TITLE_SUBPAGE_SIZE,
        DesignTokens.Touch.TEXT_TITLE_SUBPAGE_WEIGHT, DesignTokens.Touch.TEXT_TITLE_SUBPAGE_TRACKING)
    /** Token `heading.section`: rail title on Start, group title, sheet heading. */
    val section get() = role(tv(22, FontWeight.Bold, -0.484f), DesignTokens.Touch.TEXT_HEADING_SECTION_SIZE,
        DesignTokens.Touch.TEXT_HEADING_SECTION_WEIGHT, DesignTokens.Touch.TEXT_HEADING_SECTION_TRACKING)
    /** Token `heading.rail`: row heading, group title, header of an empty state. */
    val rail get() = role(tv(20, FontWeight.SemiBold, -0.24f), DesignTokens.Touch.TEXT_HEADING_RAIL_SIZE,
        DesignTokens.Touch.TEXT_HEADING_RAIL_WEIGHT, DesignTokens.Touch.TEXT_HEADING_RAIL_TRACKING)
    /** Token `heading.category`: sheet row, detail bar, main button. */
    val categoryLarge get() = role(tv(17, FontWeight.SemiBold, -0.136f), DesignTokens.Touch.TEXT_HEADING_CATEGORY_SIZE,
        DesignTokens.Touch.TEXT_HEADING_CATEGORY_WEIGHT, DesignTokens.Touch.TEXT_HEADING_CATEGORY_TRACKING)
    /** Token `label.row-title`: the list row. */
    val listTitle get() = role(tv(15, FontWeight.SemiBold), DesignTokens.Touch.TEXT_LABEL_ROW_TITLE_SIZE,
        DesignTokens.Touch.TEXT_LABEL_ROW_TITLE_WEIGHT, DesignTokens.Touch.TEXT_LABEL_ROW_TITLE_TRACKING)
    /** Token `body.default`: body text. */
    val body get() = role(tv(15, FontWeight.Normal), DesignTokens.Touch.TEXT_BODY_DEFAULT_SIZE,
        DesignTokens.Touch.TEXT_BODY_DEFAULT_WEIGHT, DesignTokens.Touch.TEXT_BODY_DEFAULT_TRACKING)
    /** Token `label.button`: secondary and quiet button. */
    val buttonText get() = role(tv(15, FontWeight.SemiBold), DesignTokens.Touch.TEXT_LABEL_BUTTON_SIZE,
        DesignTokens.Touch.TEXT_LABEL_BUTTON_WEIGHT, DesignTokens.Touch.TEXT_LABEL_BUTTON_TRACKING)
    /** Token `label.tile`: title under a poster, value pill, count badge, choice chip. */
    val tile get() = role(tv(13, FontWeight.Medium), DesignTokens.Touch.TEXT_LABEL_TILE_SIZE,
        DesignTokens.Touch.TEXT_LABEL_TILE_WEIGHT, DesignTokens.Touch.TEXT_LABEL_TILE_TRACKING)
    /** 13 Semibold: the chevron at the right of a row (no token of its own). */
    val angle = TextStyle(fontFamily = Inter, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
    /** Token `caption.small`: detail line: year, role, runtime, subtitle. */
    val small get() = role(tv(12, FontWeight.Normal), DesignTokens.Touch.TEXT_CAPTION_SMALL_SIZE,
        DesignTokens.Touch.TEXT_CAPTION_SMALL_WEIGHT, DesignTokens.Touch.TEXT_CAPTION_SMALL_TRACKING)
    /** Token `overline.group`: group title in uppercase. */
    val group get() = role(tv(11, FontWeight.SemiBold, 1.54f), DesignTokens.Touch.TEXT_OVERLINE_GROUP_SIZE,
        DesignTokens.Touch.TEXT_OVERLINE_GROUP_WEIGHT, DesignTokens.Touch.TEXT_OVERLINE_GROUP_TRACKING)
    /** Token `overline.badge`: badge and tile badge. */
    val badge get() = role(tv(10, FontWeight.SemiBold, 1.0f), DesignTokens.Touch.TEXT_OVERLINE_BADGE_SIZE,
        DesignTokens.Touch.TEXT_OVERLINE_BADGE_WEIGHT, DesignTokens.Touch.TEXT_OVERLINE_BADGE_TRACKING)

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
