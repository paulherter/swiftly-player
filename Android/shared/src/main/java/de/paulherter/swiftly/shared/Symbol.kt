package de.paulherter.swiftly.shared

import androidx.compose.foundation.layout.requiredSize
import androidx.compose.ui.layout.AlignmentLine
import androidx.compose.ui.layout.FirstBaseline
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.unit.Constraints
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * **Every symbol in the app comes from here**, phone and TV.
 *
 * The set is **Material Symbols Rounded** as a variable font (`res/font/icons_round.ttf`, Apache 2.0,
 * licence under `assets/licenses/`). It replaces a mixed stock (Material Icons in Filled and Outlined,
 * plus hand-drawn vectors in the player), where every glyph had a different size, stroke weight and build.
 * Rounded, because SF Symbols have round stroke ends.
 *
 * **No call site sets the axes itself.** Otherwise they drift apart again.
 *
 * - `wght`: the weight of the SF Symbol at the same place on iPhone (`Staerke`).
 * - `FILL`: 1 where iPhone uses the `.fill` variant; attached to the `Glyph`, not to the call.
 * - `opsz`: the displayed size, clamped between 20 and 48; the optical size adjusts stroke
 *   contrast the way SF Symbols do.
 * - `GRAD`: 0.
 *
 * **`size` is the point size on iPhone**, not the box size. An SF Symbol at size 17 is about
 * 17 pt tall; a Material glyph fills only 20 of 24 units of its em box. The component therefore
 * scales the box by 1.2 so both stand **optically** equally tall next to the same text.
 * `Symbol(Glyph.Checkmark, 17.dp)` gives what `.font(.system(size: 17))` shows on iPhone.
 *
 * ## Mapping SF Symbol → Material Symbol
 *
 * For lookup, not for re-choosing. Where there is no good counterpart, the reason is given.
 *
 * | SF Symbol | Material Symbols Rounded | FILL | Note |
 * |---|---|---|---|
 * | `house` | `home` | 0 |  |
 * | `film` | `movie` | 0 |  |
 * | `tv` | `tv` | 0 |  |
 * | `magnifyingglass` | `search` | 0 |  |
 * | `arrow.down.circle` | `arrow_circle_down` | 0 |  |
 * | `arrow.down.circle.fill` | `arrow_circle_down` | 1 |  |
 * | `arrow.down` | `arrow_downward` | 0 |  |
 * | `bookmark` | `bookmark` | 0 |  |
 * | `bookmark.fill` | `bookmark` | 1 |  |
 * | `person` | `person` | 0 |  |
 * | `person.fill` | `person` | 1 |  |
 * | `lock` | `lock` | 0 |  |
 * | `tag` | `sell` | 0 | SF tag is a hang tag; Material "sell" is exactly that shape |
 * | `star` | `star` | 0 |  |
 * | `star.fill` | `star` | 1 |  |
 * | `plus` | `add` | 0 |  |
 * | `plus.circle` | `add_circle` | 0 |  |
 * | `minus` | `remove` | 0 |  |
 * | `play.fill` | `play_arrow` | 1 |  |
 * | `play.circle` | `play_circle` | 0 |  |
 * | `play.rectangle` | `smart_display` | 0 |  |
 * | `play.tv` | `live_tv` | 0 | Material has no TV with triangle and no antenna |
 * | `pause.fill` | `pause` | 1 |  |
 * | `gobackward`, `gobackward.N` | `replay` | 0 | Material has the arrow circle with a number only for 5/10/30; the player draws the digit itself, the same for every span |
 * | `goforward`, `goforward.N` | `replay` | 0 | drawn mirrored; Material has no clockwise counterpart |
 * | `forward.end.fill` | `skip_next` | 1 |  |
 * | `forward.end` | `skip_next` | 0 |  |
 * | `ellipsis` | `more_horiz` | 0 |  |
 * | `captions.bubble` | `subtitles` | 0 | SF is a speech bubble with lines; Material "subtitles" a rectangle with lines |
 * | `rectangle.stack` | `stack` | 0 |  |
 * | `slider.horizontal.3` | `tune` | 0 |  |
 * | `xmark` | `close` | 0 |  |
 * | `xmark.circle` | `cancel` | 0 |  |
 * | `xmark.circle.fill` | `cancel` | 1 |  |
 * | `checkmark` | `check` | 0 |  |
 * | `checkmark.circle` | `check_circle` | 0 |  |
 * | `checkmark.circle.fill` | `check_circle` | 1 |  |
 * | `square` | `check_box_outline_blank` | 0 |  |
 * | `checkmark.square.fill` | `check_box` | 1 |  |
 * | `chevron.down` | `expand_more` | 0 |  |
 * | `chevron.up` | `expand_less` | 0 |  |
 * | `chevron.left` | `chevron_left` | 0 |  |
 * | `chevron.right` | `chevron_right` | 0 |  |
 * | `arrow.up.arrow.down` | `swap_vert` | 0 |  |
 * | `line.3.horizontal.decrease` | `filter_list` | 0 |  |
 * | `wifi` | `wifi` | 0 |  |
 * | `wifi.slash` | `wifi_off` | 0 |  |
 * | `wifi.exclamationmark` | `signal_wifi_bad` | 0 |  |
 * | `square.grid.2x2` | `grid_view` | 0 |  |
 * | `rectangle.grid.1x2` | `view_agenda` | 0 |  |
 * | `square.split.2x1` | `view_column_2` | 0 |  |
 * | `rectangle.on.rectangle` | `filter_none` | 0 |  |
 * | `link` | `link` | 0 |  |
 * | `exclamationmark.triangle.fill` | `warning` | 1 |  |
 * | `clock.arrow.circlepath` | `history` | 0 |  |
 * | `bubble.left.and.bubble.right` | `forum` | 0 |  |
 * | `arrow.counterclockwise` | `restart_alt` | 0 |  |
 * | `arrow.counterclockwise.circle` | `settings_backup_restore` | 0 |  |
 * | `arrow.clockwise` | `refresh` | 0 |  |
 * | `arrow.uturn.backward` | `undo` | 0 |  |
 * | `externaldrive.badge.xmark` | `database_off` | 0 | Material has no drive with a cross; "database_off" carries the same meaning |
 * | `externaldrive.connected.to.line.below` | `dns` | 0 |  |
 * | `internaldrive` | `hard_drive` | 0 |  |
 * | `trash` | `delete` | 0 |  |
 * | `tray` | `inbox` | 0 |  |
 * | `tray.and.arrow.down` | `move_to_inbox` | 0 |  |
 * | `text.alignleft` | `format_align_left` | 0 |  |
 * | `speaker.wave.2` | `volume_up` | 0 |  |
 * | `sparkles` | `auto_awesome` | 0 |  |
 * | `sparkle.magnifyingglass` | `search_insights` | 0 |  |
 * | `waveform.badge.magnifyingglass` | `graphic_eq` | 0 | Material has no waveform with magnifier |
 * | `rectangle.and.text.magnifyingglass` | `manage_search` | 0 |  |
 * | `rectangle.portrait.and.arrow.right` | `logout` | 0 |  |
 * | `pip.fill` | `picture_in_picture_alt` | 1 |  |
 * | `laptopcomputer` | `laptop_mac` | 0 |  |
 * | `ladybug` | `bug_report` | 0 |  |
 * | `doc.text` | `description` | 0 |  |
 * | `iphone` | `mobile` | 0 |  |
 * | `ipad` | `tablet_mac` | 0 |  |
 * | `globe` | `language` | 0 |  |
 * | `gearshape` | `settings` | 0 |  |
 * | `chart.bar` | `bar_chart` | 0 |  |
 * | `chart.bar.fill` | `bar_chart` | 1 |  |
 * | `capsule` | `toggle_off` | 0 | Material has no plain capsule; "toggle_off" is the closest shape |
 * | `eye.slash` | `visibility_off` | 0 |  |
 * | `info.circle` | `info` | 0 |  |
 * | `circle.lefthalf.filled` | `contrast` | 0 |  |
 * | `circle` | `radio_button_unchecked` | 0 |  |
 * | `line.3.horizontal` | `drag_handle` | 0 |  |
 * | `clock` | `schedule` | 0 |  |
 * | `antenna.radiowaves.left.and.right` | `signal_cellular_alt` | 0 |  |
 * | `desktopcomputer` | `computer` | 0 |  |
 * | `rotate.right` | `screen_rotation_alt` | 0 |  |
 * | `pencil` | `edit` | 0 |  |
 * | `eye` | `visibility` | 0 |  |
 * | `exclamationmark` | `priority_high` | 0 |  |
 * | `person.2` | `group` | 0 |  |
 * | `person.2.fill` | `group` | 1 |  |
 * | `hourglass` | `hourglass` | 0 |  |
 * | `arrow.left.and.right` | `arrow_range` | 0 |  |
 */
enum class Glyph(val code: Int, val filled: Boolean, val mirrored: Boolean) {
    House(0xE88A, false, false),
    Film(0xE02C, false, false),
    Tv(0xE333, false, false),
    Magnifier(0xE8B6, false, false),
    LoadCircle(0xF181, false, false),
    LoadCircleFilled(0xF181, true, false),
    ArrowDown(0xE5DB, false, false),
    Bookmark(0xE866, false, false),
    BookmarkFilled(0xE866, true, false),
    Person(0xE7FD, false, false),
    PersonFilled(0xE7FD, true, false),
    Padlock(0xE88D, false, false),
    Tag(0xE54E, false, false),
    Star(0xE838, false, false),
    StarFilled(0xE838, true, false),
    Plus(0xE145, false, false),
    PlusCircle(0xE147, false, false),
    Minus(0xE15B, false, false),
    MinusCircle(0xF08C, false, false),
    Keys(0xE73C, false, false),
    Play(0xE037, true, false),
    PlayCircle(0xE038, false, false),
    PlayRectangle(0xF06A, false, false),
    PlayTv(0xE639, false, false),
    Pause(0xE034, true, false),
    Rewind(0xE042, false, false),
    FastForward(0xE042, false, true),
    Skip(0xE044, true, false),
    SkipOutline(0xE044, false, false),
    More(0xE5D3, false, false),
    Subtitle(0xE048, false, false),
    Pile(0xF609, false, false),
    SliderControl(0xE429, false, false),
    Cross(0xE14C, false, false),
    CrossCircle(0xE5C9, false, false),
    CrossCircleFilled(0xE5C9, true, false),
    Checkmark(0xE5CA, false, false),
    CheckmarkCircle(0xE86C, false, false),
    CheckmarkCircleFilled(0xE86C, true, false),
    Checkbox(0xE835, false, false),
    CheckboxFilled(0xE834, true, false),
    AngleDown(0xE5CF, false, false),
    AngleUp(0xE5CE, false, false),
    AngleLeft(0xE408, false, false),
    AngleRight(0xE409, false, false),
    Sort(0xE0C3, false, false),
    Filter(0xE152, false, false),
    Wlan(0xE63E, false, false),
    WlanFrom(0xE648, false, false),
    WlanDisruption(0xF063, false, false),
    Grid(0xE9B0, false, false),
    Rows(0xE8E9, false, false),
    Shared(0xF847, false, false),
    Rectangles(0xE3E0, false, false),
    Chain(0xE157, false, false),
    Warning(0xE002, true, false),
    History(0xE28E, false, false),
    Conversation(0xE0BF, false, false),
    Ruecksetzen(0xF053, false, false),
    ResetCircle(0xE8BA, false, false),
    Reload(0xE5D5, false, false),
    Undo(0xE166, false, false),
    ServerRoute(0xF414, false, false),
    Server(0xE875, false, false),
    Drive(0xF80E, false, false),
    Papierkorb(0xE872, false, false),
    Store(0xE156, false, false),
    StoreLoad(0xE168, false, false),
    TextBlock(0xE236, false, false),
    Speaker(0xE050, false, false),
    Funkeln(0xE65F, false, false),
    SparkleSearch(0xF4BC, false, false),
    WaveSearch(0xE1B8, false, false),
    TextSearch(0xF02F, false, false),
    SignOut(0xE9BA, false, false),
    ImageInImage(0xE911, true, false),
    Laptop(0xE320, false, false),
    Beetle(0xE868, false, false),
    Document(0xE873, false, false),
    Phone(0xE0D4, false, false),
    Tablet(0xE331, false, false),
    Globe(0xE894, false, false),
    Gear(0xE8B8, false, false),
    Bar(0xE26B, false, false),
    BarFilled(0xE26B, true, false),
    Pill(0xE9F5, false, false),
    Auge(0xE8F5, false, false),
    Info(0xE88E, false, false),
    Contrast(0xEB37, false, false),
    Ring(0xE836, false, false),
    Handle(0xE25D, false, false),
    Clock(0xE192, false, false),
    BarReception(0xE202, false, false),
    Computer(0xE30A, false, false),
    Rotate(0xEBEE, false, false),
    Pencil(0xE150, false, false),
    EyeOpen(0xE417, false, false),
    Exclamation(0xE645, false, false),
    Cluster(0xE7EF, false, false),
    ClusterFilled(0xE7EF, true, false),
    Hourglass(0xEBFF, false, false),
    JumpArrows(0xF69B, false, false),
    /** `forward.fill`: the pill while 2× is held. */
    DoubleSpeed(0xE01F, true, false),
    /** `heart` / `heart.fill`: "Support Swiftly", and the supporter badge. */
    Heart(0xE87D, false, false),
    HeartFilled(0xE87D, true, false),
    /** `app.badge`-ish: the app icon picker. */
    AppIcon(0xE5C3, false, false),
    ;

    val text: String get() = String(Character.toChars(code))
}

/** The weight of the SF Symbol on iPhone, `ultralight` 100 to `bold` 700. */
enum class Strength(val wght: Int) {
    UltraLight(100), Thin(200), Lightweight(300), Normal(400), Medium(500), Semibold(600), Bold(700)
}

/** One typeface instance per axis state; otherwise Compose builds a new font for every image. */
private val cuts = HashMap<Long, FontFamily>()

@OptIn(androidx.compose.ui.text.ExperimentalTextApi::class)
private fun cut(wght: Int, fill: Boolean, opsz: Int): FontFamily {
    val key = (wght.toLong() shl 16) or ((if (fill) 1L else 0L) shl 8) or opsz.toLong()
    return cuts.getOrPut(key) {
        FontFamily(Font(R.font.icons_round, variationSettings = FontVariation.Settings(
            FontVariation.weight(wght),
            FontVariation.Setting("FILL", if (fill) 1f else 0f),
            FontVariation.Setting("GRAD", 0f),
            FontVariation.Setting("opsz", opsz.toFloat()),
        )))
    }
}

/**
 * One symbol. `size` = the size on iPhone (see above), `staerke` = its weight there.
 * `description` only where the glyph stands alone; next to a text the text is read.
 *
 * **The glyph is placed, not a text line.** Material Symbols is a font with ascent 1056 and
 * descent 96 on a 960 em box, but the glyphs sit centred in the em box above the baseline (middle
 * at 480). As a text line with `lineHeight` = em and `LineHeightStyle(Center, Trim.Both)` the
 * baseline still landed at 1.1 em below the top edge: every glyph sat a tenth of its box too low
 * (1.3 to 2.5 dp measured on a Pixel emulator) and touched the bottom edge. So the baseline is
 * placed here by hand: box centre plus half an em.
 *
 * **`requiredSize`, not `size`.** Where a caller gives a narrower column (tick in 18, glyph in
 * 20), the box shrank with it, the glyph slid sideways and was clipped at the edge. This way it
 * keeps its size and stays centred in the column.
 */
@Composable
fun Symbol(symbolText: Glyph, size: Dp, modifier: Modifier = Modifier, color: Color = Theme.font,
           strength: Strength = Strength.Normal, filled: Boolean = symbolText.filled, description: String? = null) {
    val four = size * 1.2f
    val density = LocalDensity.current
    val opsz = four.value.toInt().coerceIn(20, 48)
    // Computed in dp, not sp: a control glyph on iPhone grows with a fixed size, not with the
    // system font, and here it should not either.
    val grad = with(density) { four.toSp() }
    val style = TextStyle(fontFamily = cut(strength.wght, filled, opsz), fontSize = grad, color = color,
                         platformStyle = PlatformTextStyle(includeFontPadding = false))
    Layout(
        content = { BasicText(symbolText.text, style = style, softWrap = false, maxLines = 1) },
        modifier = modifier.requiredSize(four)
            .then(if (symbolText.mirrored) Modifier.graphicsLayer { scaleX = -1f } else Modifier)
            .clearAndSetSemantics { if (description != null) contentDescription = description },
    ) { parts, limits ->
        val text = parts.first().measure(Constraints())
        val border = limits.maxWidth
        val reasonLine = text[FirstBaseline].takeIf { it != AlignmentLine.Unspecified } ?: text.height
        layout(border, limits.maxHeight) {
            // Glyph centre = baseline minus half an em; it should land on the box centre.
            text.place((border - text.width) / 2, limits.maxHeight / 2 + border / 2 - reasonLine)
        }
    }
}
