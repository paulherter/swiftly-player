import Foundation
import JellyfinKit
import SwiftUI

/// Dimensions, type sizes and building blocks for the TV.
///
/// The colors live in `Sources/Shared/Colors.swift` and match the iPhone.
/// Everything else is TV-specific: 1920 × 1080 instead of 390 × 844, three meters
/// of distance instead of arm's length, a remote instead of a finger.
///
/// **The one rule that carries everything: focus is white, selection is accent.**
/// The white focus fill is the same button that is called `PrimaryButtonStyle` on
/// iOS: white surface, black text. On tvOS it means "the remote is here". The
/// accent ring around a focused tile does not break the iOS rule, it applies it:
/// accent carries progress, **selection** and the Direct Play proof.
///
/// No Apple standard controls, as on iOS: no `TabView`, no `List`, no
/// `.buttonStyle(.card)`. Apple's card adds shadow, parallax and a flash that
/// don't fit a flat design.
extension Theme {
    /// **Same names as on the iPhone**, so the shared building blocks in
    /// `Sources/Shared` find them here. The values are this platform's; the role is
    /// the same.
    static var motionReduced: Bool {
        UIAccessibility.isReduceMotionEnabled
    }
    /// Short cross-fade used when Reduce Motion is on. Same value as on the iPhone,
    /// for the shared transitions (`AccountSwitchTransition`).
    static let fadeReduced: Animation = .linear(duration: 0.14)
    static let listTitle = Font.system(size: 30, weight: .semibold)

    // The corner ladder is further down under "MARK: Ecken", all four levels in one
    // place with the math.

    // MARK: - Press feedback

    /// **Press: in immediately, out over 0.12 s**, as on iPhone and Mac. Symmetric
    /// was wrong: feedback on a press must have no duration, the release may.
    static func pressCurve(_ pressed: Bool) -> Animation? {
        pressed ? nil : .linear(duration: 0.12)
    }

    /// **Same two styles as on the iPhone**, so the shared building blocks in
    /// `Sources/Shared` find them here. A row gets a surface, a button gets smaller:
    /// every button answers the press.
    struct PressRow: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background(Theme.font.opacity(configuration.isPressed ? 0.06 : 0))
                .animation(Theme.pressCurve(configuration.isPressed), value: configuration.isPressed)
        }
    }

    struct PressButton: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .animation(Theme.pressCurve(configuration.isPressed), value: configuration.isPressed)
        }
    }


    // MARK: Dimensions — Apple TV

    /// The safe area on 1920 × 1080. Apple's guideline, and it holds: TVs crop at the
    /// edge, some more, some less.
    ///
    /// **Measured from the screen edge, not from the system margin.** tvOS already
    /// keeps 80 free on the sides; putting `edgePage` on top gives 160, twice as far
    /// in as the design. `MainView` therefore removes the system margin once for all
    /// sections.
    ///
    /// Less than 80 would be a risk, not polish: below that TVs crop, and the
    /// simulator never shows it.
    static let edgePage: CGFloat = 80
    static let edgeTop: CGFloat = 60

    // MARK: Header bar

    /// Top edge of the bar, measured from the screen edge: the safe area.
    ///
    /// Apple's guideline gives the **system bar** a fixed 46 pt from the top. Copied,
    /// it looked off, for a reason the number doesn't show: Apple's bar is
    /// horizontally **centered** and narrow, ours is left-aligned and starts at 80.
    /// 46 on top against 80 on the sides reads as a mistake.
    ///
    /// So the safe area: 60 on top, 80 on the sides. That is the ratio the margin is
    /// meant for on tvOS anyway, with more at the sides because of overscan.
    static let barTop: CGFloat = edgeTop
    static let stripHeight: CGFloat = 68
    /// Bottom edge. The header gradient hangs on it, so it follows if the bar ever
    /// moves.
    static var barBottom: CGFloat { barTop + stripHeight }

    // MARK: Corners

    /// **The corner ladder: the same roundness as on the iPhone, not the same
    /// number.**
    ///
    /// **The measure is the ratio of radius to the size of the thing it rounds.**
    /// Only that decides how round a corner *looks*: 10 on a 112 wide poster is
    /// 0.089, 16 on a 208 wide one only 0.077, so the TV poster was flatter than the
    /// phone's despite the bigger number. And since things don't all grow equally on
    /// the TV (poster 112 → 208 is 1.86, button 48 → 76 only 1.58), a fixed factor
    /// for corners cannot exist.
    ///
    /// Per level: take the iPhone ratio, multiply by the TV size of the **same
    /// thing**, round to an even number.
    ///
    ///     Level          iPhone: thing / corner   Ratio   TV: thing            Calculation     new
    ///     cornerSmall      badge 24 high /  8       0.333   badge 47 high        47 × 0.333 = 15.7
    ///                    Plakette 24 high / 8     0.333   Plakette.fern 41     41 × 0.333 = 13.7   14
    ///     ecke           button 48 high / 10      0.208   button 76 high       76 × 0.208 = 15.8   16
    ///     cornerTile     poster 112 wide / 10     0.089   poster 208 wide      208 × 0.089 = 18.6  18
    ///     eckeFlaeche    board, row 58 / 16       0.276   board, row 84        84 × 0.276 = 23.2   24
    ///
    /// The ladder is therefore **14 / 16 / 18 / 24**. Two points of difference are
    /// the right step on a TV: 1920 pt at three meters covers about the same visual
    /// angle as 390 pt at arm's length, so a TV point is roughly a fifth of an iPhone
    /// point.
    ///
    /// Only `cornerSmall` stands out: it **drops** from 16 to 14 while everything else
    /// grows. Same math: small badges grow less from phone to TV than the rest (24 →
    /// 41…47).
    static let corner: CGFloat = 16
    /// Posters and tiles. On the iPhone the same number as the button (both 10); here
    /// two more than the button because the poster grew more than it did. Two points
    /// are no rank at three meters, just honest rounding: to merge them, use 18 for
    /// both.
    static let cornerTile: CGFloat = 18
    /// **The small corner, for badges and pills.** Used by the `ProofRow` badge,
    /// `Badge.far` and the badge on top of a tile, all between 36 and 47 pt high.
    static let cornerSmall: CGFloat = 14
    /// **A surface or board of its own:** the `Handlungstafel` and the season sheet
    /// of the Seerr page, both 620 pt wide with rows of `rowsHeight`.
    ///
    /// Measured by **row height**, not width: the board is 620 wide on the TV against
    /// 342 on the iPhone, but content width is 1760 against 354. By width the corner
    /// would come out at 80, clearly no longer a board. The row is the thing the
    /// roundness is read from.
    static let cornerArea: CGFloat = 24

    /// **Not a ladder level, but a placeholder bar.** A `Ladefeld` standing for a
    /// line of text is 16 to 30 pt high; the same 0.23 as for the small field gives 4
    /// to 7 there. One number for all three, because a point of difference on a bar
    /// that only says "text goes here" tells nothing.
    static let cornerBar: CGFloat = 5

    /// Posters stay 2:3 as on the iPhone, just larger.
    static let posterWidth: CGFloat = 208
    static let posterHeight: CGFloat = 312

    /// 16:9 landscape, for "Continue Watching", where a still says more than the
    /// cover.
    static let landscapeWidth: CGFloat = 448
    /// Image width. tvOS always works in 1920 × 1080 points.
    static let screenWidth: CGFloat = 1920
    static let landscapeHeight: CGFloat = 252

    /// All spacing is chosen so the **focused** tile has room, not the resting one.
    /// At ×1.08 a poster grows by 25 pt, a good 12 per side; a landscape tile by 20.
    /// Sizing the spacing on the resting state makes it too tight at first focus.
    static let tileSpacing: CGFloat = 40
    /// Height of the fixed info zone, measured from the screen edge.
    ///
    /// **It sets the row window: 1080 − 510 = 570.** That window must hold a whole
    /// row section, or tvOS cannot free title and tiles together and the title slides
    /// out:
    ///
    ///     Poster row    = 24 + 45 + 16 + (20 + 390 + 20) + 28 = 543
    ///     Landscape row = 24 + 45 + 16 + (20 + 331 + 20) + 28 = 484
    ///
    /// 510 rather than 560: with 560 only 520 remain, and the poster row would not
    /// fit.
    static let heroHeight: CGFloat = 510

    /// **How much lower a detail page sits than the start page.**
    ///
    /// The start page puts its text block at 196, the detail page's design at 140,
    /// because the header bar sits above the start page and nothing above the detail
    /// page. On screen it is the same info for the same film, and on press it jumped
    /// up by these 56.
    ///
    /// The bar is not drawn, but its space is kept. **The background does not move**:
    /// the backdrop is in the same stack and keeps its position.
    ///
    /// The whole block moves, not the spacing inside it. The header zone therefore
    /// grows by the same amount, and the board dimensions still hold:
    ///
    ///     196 + 68 + 8 + 40 + 22 + 80 + 36 + 76 = 526   block ends at 566
    ///     + 24 = 590   row title: 590 − 526 = 64, as in the board
    static let headerOffsetDetail: CGFloat = 56

    /// Line height and line spacing of the description.
    ///
    /// **Calculated, not estimated.** The board gives a line height of 40; measured
    /// at 29 pt type it is about 35 plus the 11 `lineSpacing`, so 46 per line from
    /// the second. With the 120 from the board math only two lines fit although
    /// `lineLimit` was three: the third was silently cut off.
    ///
    /// **37, now that body text is 30.** The 35 applied to 29 pt; the same math (line
    /// height about 1.21 × size) gives about 36.2 at 30. Rounded up to 37 so the
    /// third line is not cut off at the decimal again.
    static let descriptionRow: CGFloat = 37
    static let descriptionPadding: CGFloat = 11

    /// How high `rows` lines of description stand: 3 → 133, 2 → 85.
    static func descriptionHeight(_ rows: Int) -> CGFloat {
        CGFloat(rows) * descriptionRow + CGFloat(rows - 1) * descriptionPadding
    }

    /// The episode title above the info row: 44 high, 10 spacing.
    static let secondRowHeight: CGFloat = 54

    /// **Fixed height of the head block: title, info row, description.**
    ///
    /// Title 68 + `detailsPadding` 8 + `markHeight` 40 + 22 + description 127 = 265.
    /// Fixed so nothing below depends on content: a film without description, a long
    /// title, an episode with a subtitle. The block is always the same height, so the
    /// button row always sits in the same place.
    ///
    /// **The top edge of every main page** (Home, Movies, Shows, Watchlist, Search),
    /// measured from the screen edge. On Home the title starts here, on Movies, Shows
    /// and Watchlist the chip row, in Search the field.
    ///
    /// Aligning the **bottom** edges instead made each page derive its spacing back
    /// from the height of its first element, which lines pages up on an invisible
    /// line; what is visible is where something starts. The 48-high chips began at
    /// 216, 20 lower than the Home title, and the page felt top-heavy. Now everything
    /// starts on one line: 196.
    static let contentTop: CGFloat = 196

    /// Where the grid below the chip row begins, measured from the safe edge where
    /// the scroll area starts. The loading placeholder sits exactly where the first
    /// posters will stand.
    static var gridTop: CGFloat { contentTop - edgeTop + chipHeight + capsuleRailPadding }
    /// Between the chip row and the grid below.
    static let capsuleRailPadding: CGFloat = 30

    // MARK: Info row

    /// **One height for all badges of the info row**: rating, age rating, Direct
    /// Play.
    ///
    /// There used to be two shapes: the badge (symbol 22, word 26, 8 vertical, about
    /// 47 high) and the age-rating pill (24 in 14/6, about 41). Side by side the age
    /// rating looked like a different element, though it is the same kind of info.
    /// And 47 was too heavy: the play button is 76 high, so the badge was over half
    /// as loud as the one thing to press here. Order: title > play button > info.
    ///
    /// Now one height, set rather than derived from type and padding, so a symbol
    /// next to the word cannot shift it. 40 is double the iPhone badge (13 medium in
    /// 4 vertical, about 24), rounded down to the step that suits the info type.
    static let markHeight: CGFloat = 40
    /// Type in the badge: the info level (24), medium, so year, runtime and the words
    /// in the badges share **one** size on one baseline.
    static let markFont = Font.system(size: 24, weight: .medium)
    /// The symbol before the word, one step below the type.
    static let markCharacter: CGFloat = 18
    /// Horizontal padding. Before a symbol, two less on the left: the symbol is
    /// narrower than its cell, otherwise the word sits visibly off-center.
    static let markInner: CGFloat = 14
    /// Between symbol and word.
    static let markCharacterSpacing: CGFloat = 8
    /// **One gap across the whole row**: between "2019 · 1 h 52 min" and the first
    /// badge just as between badges. A 24 gap between everything let the badges fall
    /// apart; 16 is double the iPhone's 8.
    static let detailsSpacing: CGFloat = 16
    /// Between title and info row. 8 instead of 14 because the row is 6 higher (40
    /// instead of 34): the block stays as high as before and the button row stays in
    /// place.
    static let detailsPadding: CGFloat = 8

    static var infoHeight: CGFloat { infoHeight(secondLine: false) }

    /// **One description line fewer with an episode title.**
    ///
    /// Three lines are right while the title stands alone. An episode title costs 54
    /// pt, and the third line ran into the row title below.
    ///
    ///     without: 68 + 8 + 40 + 22 + 127 = 265
    ///     with:    68 + 54 + 8 + 40 + 22 + 81 = 273
    ///
    /// The block grows by only eight instead of 54: the episode title takes its space
    /// mostly from the description, not from the page.
    static func infoHeight(secondLine: Bool) -> CGFloat {
        68 + (secondLine ? secondRowHeight : 0) + detailsPadding + markHeight + 22
        + descriptionHeight(secondLine ? 2 : 3)
    }

    /// Head zone of a detail page, **calculated, not set.**
    ///
    ///     196 (block begins)  + 258 (infoHeight) = 454
    ///     + 36 + 76 (button row)                     = 566
    ///     + 64 (spacing from the board) − 24 (railsHeaderPadding)
    ///     = 606
    ///
    /// Larger than the 510 of Home, and it has to be: the button row is added and the
    /// block sits 56 lower. Home does not need the room, its block ends at 454 and
    /// the rows still begin at 534.
    static var heroHeightDetail: CGFloat {
        edgeTop + headerOffsetDetail + 80 + infoHeight
        + 36 + buttonHeight + spacingUnderButtonRail - railsHeaderPadding
    }

    /// The spacing below the button row: 64.
    ///
    /// Shortening it to 36 was based on the belief that the first row sticks 26 pt
    /// off the screen. **It does not.** Measured against a screenshot with the tile
    /// width as scale, the row ends with its caption at about 1005, leaving 75 pt.
    /// The shorter figure rested on two overestimated values (row title 46, caption
    /// 122). Focus behavior does not depend on this height.
    static let spacingUnderButtonRail: CGFloat = 64

    /// Vertical room in the horizontal strip.
    ///
    /// The focused tile grows by 1.08 beyond its layout size, about 25 pt for a
    /// poster, a good 12 per side. Without this room the surface clips the tile at
    /// the top and its subline at the bottom.
    static let railsPadding: CGFloat = 20

    /// Above the row title: the upper part of the row spacing.
    ///
    /// It belongs **inside the section**, not between sections. Only then does it
    /// count when tvOS frees the section on focus; between sections it would be
    /// filler again.
    static let railsHeaderPadding: CGFloat = 24

    /// From row to row. Three parts, all inside the section: space below the strip
    /// (28) + its focus room (20) + room above the next title (24).
    static let railsSpacing: CGFloat = 72

    /// Between row title and the tiles below. The strip's focus room counts; the head
    /// carries only the rest.
    static let titleSpacing: CGFloat = 36

    /// Below the last row, **in addition**.
    ///
    /// At the end stop the bottom edge of the content sits on the window edge. Below
    /// it is already the last section's spacing with focus room, 28 + 20 = 48. Only
    /// the rest up to the 60 that tvOS keeps free at the bottom comes here. More
    /// would be the "huge gap at the bottom"; derived rather than set, it cannot
    /// drift apart.
    static var completionPadding: CGFloat {
        edgeTop - (railsSpacing - railsPadding - railsHeaderPadding) - railsPadding
    }

    /// The library as a grid.
    static let gridColumns = 7
    /// **50, not 56, otherwise the grid does not fit the screen.**
    ///
    ///     7 × 208 + 6 × 56 + 2 × 80 = 1952   at 1920 width
    ///     7 × 208 + 6 × 50 + 2 × 80 = 1916
    ///
    /// With 56 `LazyVGrid` squeezes the posters to make the row fit. They then stand
    /// narrower than the same 208 on Home, and the row looks cramped for no visible
    /// reason. With 50 the posters stay what they are and the four points left over
    /// spread out.
    static let gridColumn: CGFloat = 50
    static let latticeRow: CGFloat = 72

    static let buttonHeight: CGFloat = 76
    static let chipHeight: CGFloat = 48
    /// Between two chips in a row, as in the library's chip row.
    static let chipSpacing: CGFloat = 20
    static let rowsHeight: CGFloat = 84

    // MARK: Focus

    /// **The focus ladder: three levels, by object size.**
    ///
    /// Focused things used to grow in six steps (1.03 · 1.04 · 1.06 · 1.08 · 1.10 ·
    /// 1.12), and only 1.08 was a token. Six numbers for **one** statement ("the
    /// remote is here") grew rather than were designed; whoever changes one changes a
    /// fifth of the app without knowing.
    ///
    /// **The criterion is how far the outline travels**, not the percentage. A
    /// percentage says nothing on a TV: 8 % on a 60 pt profile circle is five points,
    /// invisible from three meters, while on a 760 pt wide row it is sixty-one. So
    /// the **longest side** is measured, and the growth should land in the same range
    /// everywhere, about 6 to 25 pt:
    ///
    ///     Level               Value   longest side   Examples                        Growth
    ///     focusMagnifierSmall      1.10    up to 120      profile circle 60, icon button 88   +6 … +9
    ///     focusMagnifier           1.06    120 to 500     chip 180, button 250,
    ///                                                poster 312, landscape tile 448  +11 … +27
    ///     focusMagnifierWide      1.03    from 500       bar row 620,
    ///                                                device row 760                  +19 … +23
    ///
    /// Small things grow more, large ones less. Before it was the reverse: the
    /// profile circle at 1.12 **and** the tile at 1.08 had the big growth, the chips
    /// at 1.06 the small.
    ///
    /// **Only scaling, never a fixed amount added.**
    ///
    /// Free-standing images additionally get a ring (`ProfileStyle`,
    /// `AccountStripStyle`): an image cannot brighten like a tile, and six points of
    /// growth alone are too quiet at three meters.
    ///
    /// No shadow, no parallax, no flash: Apple's card jumps much further and visually
    /// pushes the neighbors away in a dense row.
    static let focusMagnifierSmall: CGFloat = 1.10
    /// The base value: tiles, posters, buttons, chips, tabs, everything between 120
    /// and 500 pt longest side. On a tile it is the only thing that marks focus: no
    /// ring, no surface, no shadow.
    static let focusMagnifier: CGFloat = 1.06
    /// Rows and boards from 500 pt wide. Three percent is already twenty points
    /// there, the same visible movement as ten percent on a profile circle.
    static let focusMagnifierWide: CGFloat = 1.03
    /// The calm surface that means focus wherever there is no button: list rows,
    /// chips, episode rows. White is reserved for action buttons, where it is the
    /// iPhone's primary button.
    static let focusArea = Color.white.opacity(0.12)

    /// Focus changes should take effect immediately; the remote is slow enough
    /// already.
    ///
    /// **"Reduce Motion" applies here too.** Focus itself stays visible; only the
    /// curve becomes short and linear, as on the iPhone.
    static var focusAnimation: Animation {
        motionReduced ? .linear(duration: 0.1) : .easeOut(duration: 0.14)
    }

    /// How content appears once it has arrived, the same curve as on the iPhone.
    /// **Nothing appears hard**: images fade in, content replaces placeholders.
    ///
    /// **A spring, not a fixed curve:** a fixed duration cannot be interrupted, and
    /// `.smooth` does not overshoot and keeps the characteristic.
    static var reveal: Animation {
        motionReduced ? .linear(duration: 0.14) : .smooth(duration: 0.28)
    }

    /// **A fixed curve that respects Reduce Motion.** On the iPhone `Theme` reads the
    /// setting centrally, and every curve then returns a short linear fade. Here the
    /// curves go through this one switch, which keeps their own duration.
    static func motion(_ curve: Animation) -> Animation {
        motionReduced ? .linear(duration: 0.14) : curve
    }

    // MARK: - Page transitions

    /// Cross-fade between two sections.
    ///
    /// A pure fade, no offset; the system bar on tvOS does no more either. `easeInOut`
    /// because something happens at both ends: one thing leaves, the other arrives.
    ///
    /// The player controls come and go, and everything attached to them (the technique
    /// badge) with the same curve.
    static var controlsFade: Animation {
        motion(.easeInOut(duration: 0.2))
    }

    /// The breathing of a placeholder. Call only when motion is allowed; an endless
    /// pulse has no reduced version, it stands still instead.
    static let pulsate = Animation.easeInOut(duration: 0.9).repeatForever(autoreverses: true)

    static var pagesSwitch: Animation {
        motionReduced ? .linear(duration: 0.14) : .easeInOut(duration: 0.25)
    }

    // MARK: - Type — Apple TV

    /// **Exactly double the iPhone**: one rule instead of a second table.
    ///
    /// It used to follow Apple's tvOS ramp (57 / 38 / 31 / 29 / 27 / 25 / 21). None
    /// of those values was double, and `tile` still carried the old 14 as its
    /// template. Changing a level on the iPhone changes the TV with it; that is the
    /// point of the rule.
    static let titleLarge = Font.system(size: 56, weight: .bold)       // iOS 28
    static let subpageTitle = Font.system(size: 44, weight: .semibold) // iOS 22
    static let rail      = Font.system(size: 40, weight: .semibold)   // iOS 20
    static let categoryLarge = Font.system(size: 34, weight: .semibold)  // iOS 17
    static let button      = Font.system(size: 30, weight: .semibold)   // iOS 15
    static let body    = Font.system(size: 30)                      // iOS 15
    static let tile     = Font.system(size: 26, weight: .medium)     // iOS 13
    static let small      = Font.system(size: 24)                      // iOS 12
    static let group     = Font.system(size: 22, weight: .semibold)   // iOS 11
    static let badge   = Font.system(size: 20, weight: .semibold)   // iOS 10

    // MARK: Tracking — the em value from the type scale times the point size
    /// 56 · −0.021 em
    static let lockTitle      = -1.176
    /// 44 · −0.014 em
    static let lockSubpage = -0.616
    /// 34 · −0.008 em
    static let lockCategory     = -0.272
    /// 22 · +0.14 em
    static let lockGroup     = 3.08
    /// 20 · +0.10 em
    static let badgeLock   = 2.0

    /// **Tracking of the row heading.** −0.012 em at 40 pt.
    static let lockRail = -0.48
}

// MARK: - Image

/// Image at a fixed size, with placeholder.
///
/// Same approach as on iOS: the size comes from the frame, the image only lies
/// over it. `aspectRatio(.fill)` directly on the image makes it wider than its
/// frame; `clipped()` then trims the rendering, not the layout size, and
/// everything around shifts.
struct Picture: View {
    let url: URL?
    var width: CGFloat?
    var height: CGFloat?
    var corner: CGFloat = Theme.cornerTile
    /// Progress along the bottom edge, inside the mask.
    var progress: Double? = nil
    /// **What to show when no image arrives**: a system symbol instead of an empty
    /// surface, as on iPhone and Mac. Only once it is certain (no URL, or the fetch
    /// has finally failed), not while loading: otherwise it would flash on every
    /// tile.
    var symbolText: String? = nil

    /// Profile → Appearance. See `EnvironmentValues.progressOnTiles`.
    @Environment(\.progressOnTiles) private var barShow

    var body: some View {
        Color.clear
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .overlay {
                // **Via the `ImageCache`, not `AsyncImage`**, as on iPhone and Mac.
                // `AsyncImage` decodes on the main thread, remembers nothing but the network
                // response, and cancels as soon as the tile leaves the screen. `NetworkImage`
                // decodes off the main thread at tile size and stores the file on disk
                // (`ImageStore`).
                //
                // The surface stays underneath so a loading tile looks as before.
                Theme.area
                    .overlay {
                        NetworkImage(url: url, symbolText: symbolText, displayEdge: displayEdge,
                                 characterSize: 44)
                    }
            }
            .overlay(alignment: .bottom) {
                if let progress, barShow {
                    ProgressBar(share: progress)
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }

    /// The edge length the image is fetched for, only when both dimensions are known.
    /// Without a width the tile spans the full row, and any estimate is too small.
    private var displayEdge: CGFloat? {
        guard let width, let height else { return nil }
        return max(width, height)
    }

    /// A cancelled fetch: the only failure worth another attempt. For `Backdrop`,
    /// which loads through `AsyncImage`.
    static func cancelled(_ phase: AsyncImagePhase) -> Bool {
        guard case let .failure(f) = phase else { return false }
        return (f as NSError).code == NSURLErrorCancelled
    }
}

/// Thin bar at the bottom of a tile. 6 pt on the TV; at 2, as on the iPhone, it
/// is invisible from three meters.
struct ProgressBar: View {
    let share: Double

    var body: some View {
        GeometryReader { frameRect in
            ZStack(alignment: .leading) {
                // Light track as on the iPhone: the track is the length of the whole, not the
                // missing rest.
                Rectangle().fill(Color.white.opacity(0.30))
                Rectangle().fill(Theme.accent)
                    .frame(width: frameRect.size.width * min(max(share, 0), 1))
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Small parts

// `RailTitle`, `Badge`, `Loader` and `ProfileCharacter` live in
// `Sources/Shared/Components.swift`. They used to exist three times (here, iOS,
// macOS) because `Shared/Style.swift` mixed iPhone dimensions with neutral
// building blocks, so this target could not include the file. Copies drift
// apart.
//
// **The dimensions stay here, the building blocks don't.** The shared block
// takes them as parameters and each target passes its own.

/// The proofs of an info row (rating, age rating, Direct Play), **without a stack
/// of their own**.
///
/// They sit directly in the row they are placed in: in the head block next to
/// "2019 · 1 h 52 min", in the `ProofRow` on their own. A nested stack kept its
/// spacing even when empty, and the badges behind it ended up 24 or 48 apart
/// depending on the neighbor. Now each badge is a child of the row, and what is
/// missing costs no spacing.
///
/// **One shell for all three** (`ProofMark`). The age rating was a `Badge`
/// with its own dimensions: the same kind of info, a different element.
struct ProofMarks: View {
    var directPlayFlag: Bool = false
    var hint: String?
    var rating: Double?
    var sharing: String?
    /// The proof comes last.
    ///
    /// On the detail head the row runs "year · runtime", rating, age rating, proof:
    /// the facts about the title first, the statement about **playback** last. In the
    /// playback sheet it is reversed: there the proof is the reason the row exists at
    /// all.
    var proofLast = false
    /// **A free proof instead of the playback plan**: on the Seerr page the status of
    /// the request, in the same shell as Direct Play and the rating. Like
    /// `ProofRow.eigen` on the iPhone.
    var own: (symbol: String, word: String, color: Color)? = nil

    var body: some View {
        if !proofLast { proof }
        // In the same shell as Direct Play; otherwise the rating would be the only bare
        // item in the row.
        if let rating {
            ProofMark(symbol: "star.fill",
                       word: Text(verbatim: String(format: "%.1f", rating)
                           .replacingOccurrences(of: ".", with: ",")),
                       color: Theme.fontQuiet, weight: .semibold)
        }
        if let sharing {
            ProofMark(word: Text(verbatim: sharing), color: Theme.fontQuiet)
        }
        if proofLast { proof }
    }

    @ViewBuilder
    private var proof: some View {
        if let own {
            ProofMark(symbol: own.symbol, word: Text(verbatim: own.word),
                       color: own.color, weight: .semibold)
        } else if directPlayFlag {
            // Semibold, not `.heavy`, as on the iPhone. Extra bold would be a fourth weight,
            // one too many.
            ProofMark(symbol: "checkmark", word: Text("Direct Play"),
                       color: Theme.accent, weight: .semibold)
        } else if let hint {
            ProofMark(symbol: "exclamationmark.triangle.fill", word: Text(hint),
                       color: Theme.warning, weight: .regular)
        }
    }
}

/// The proof that the server does not transcode, the reason for this app, as a
/// row of its own: in the playback sheet and on the Seerr page.
///
/// Deliberately **not** in the player: there the picture matters, and whoever has
/// started playback has seen the proof.
struct ProofRow: View {
    var directPlayFlag: Bool
    var hint: String?
    var rating: Double?
    var sharing: String?
    var proofLast = false
    var own: (symbol: String, word: String, color: Color)? = nil

    var body: some View {
        // Aligned on the center, not the baseline: a badge with a symbol would otherwise
        // report the SF Symbol's baseline, and the shells sat up to 3 pt apart. See
        // `HeaderInfo`.
        HStack(alignment: .center, spacing: Theme.detailsSpacing) {
            ProofMarks(directPlayFlag: directPlayFlag, hint: hint,
                        rating: rating, sharing: sharing,
                        proofLast: proofLast, own: own)
        }
    }
}

/// **The one shell** for rating, age rating and proof.
///
/// **Why a badge and not loose text.** Symbol and word stood bare on the
/// background, with the age rating next to them as an outlined pill: two shapes
/// for two facts of equal weight. Now all three share the same shape; the color
/// says which kind of info it is.
///
/// **The height is set, not derived** (see `Theme.markHeight`), so the age rating
/// without a symbol is exactly as high as the rating with one.
///
/// Fifteen percent tint, no fill: the white focus stays the only filled surface
/// on screen. Corner `cornerSmall`: 14 on 40 is 0.35, the ratio of the iPhone badge
/// (8 on 24).
struct ProofMark: View {
    var symbol: String?
    let word: Text
    let color: Color
    var weight: Font.Weight = .semibold

    var body: some View {
        HStack(spacing: Theme.markCharacterSpacing) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: Theme.markCharacter, weight: weight))
                    .accessibilityHidden(true)
            }
            word.font(Theme.markFont)
        }
        .lineLimit(1)
        .foregroundStyle(color)
        .padding(.leading, symbol == nil ? Theme.markInner : Theme.markInner - 2)
        .padding(.trailing, Theme.markInner)
        .frame(height: Theme.markHeight)
        .background(color.opacity(0.15),
                    in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
    }
}

/// The loading ring at TV size: 68 instead of the phone's 34.
///
/// Like `Badge.far` only a set of numbers. The shared block also draws the
/// faint background ring.
extension Loader {
    static var far: Loader { Loader(size: 68, strength: 5) }
}

/// When there is nothing.
struct EmptyState: View {
    let symbol: String
    let title: LocalizedStringKey
    var hint: LocalizedStringKey?
    /// A way out, not a dead-end sign.
    ///
    /// On the iPhone every empty state has one ("Refresh", "Reset filters"). Without
    /// it you stand there unable to do anything, which is worse with a remote than
    /// with a finger.
    var button: (title: LocalizedStringKey, perform: () -> Void)?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: symbol)
                // 88 regular: on the iPhone the symbol is 44 and carries no weight of its own;
                // regular is the lightest of three weights.
                .font(.system(size: 88))
                .foregroundStyle(Theme.fontVeryQuiet)
            Text(title)
                .font(Theme.rail)
                .foregroundStyle(Theme.font)
            if let hint {
                Text(hint)
                    .font(Theme.body)
                    .foregroundStyle(Theme.fontQuiet)
                    .multilineTextAlignment(.center)
            }
            if let button {
                Button(button.title, action: button.perform)
                    .buttonStyle(ThemedButtonStyle())
                    .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // **The entrance belongs in the component**, as on iPhone and Mac: an empty
        // state would otherwise jump hard into view. The caller decides when; a
        // `.transition` only works if the insertion itself is animated.
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }
}


/// **One wording for "the server did not answer", not thirteen.**
///
/// The same `Leerzustand` that library, Home and Search show, instead of a copy
/// in every file (series page, person page, genre picker, Seerr page). Copying it
/// several times is several chances for one of them to sound different.
///
/// `address` is optional: on a Seerr page Jellyseerr was silent, not the own
/// server, and the wrong address in the sentence would send the user looking in
/// the wrong place.
struct DisturbState: View {
    let model: AppModel
    var address: String?
    var retry: (() -> Void)?

    var body: some View {
        EmptyState(
            symbol: "externaldrive.badge.xmark",
            title: "Server ist abgetaucht",
            hint: "\(address ?? model.serverAddress ?? String(localized: "Der Server")) antwortet nicht. Läuft er noch, oder hängt das WLAN?",
            button: retry.map { perform in (title: LocalizedStringKey("Erneut versuchen"), perform: perform) })
    }
}


// MARK: - Header gradient

/// Darkens the top edge so the header bar stays readable over running image
/// material.
///
/// **The safe area counts.** The gradient ignores it (`ignoresSafeArea`) and
/// starts at zero, while the bar sits inside it, 60 pt lower. The strong zone
/// then lay over empty margin and the wordmark was already in the fade-out,
/// practically unprotected on light posters.
///
/// Hence `headerHeight` is computed from the screen edge, not the safe area: 60
/// margin plus 56 spacing plus 60 row.
///
/// The row title sits at about 240, in the fade-out, where about 15 percent
/// remain. On the base tone that is nothing, and where a poster sits it is
/// intended.
///
/// Seven stops. Three would produce a visible edge where the slope jumps.
struct HeaderHistory: View {
    /// Bottom edge of the header bar, measured from the screen edge.
    var headerHeight: CGFloat = Theme.barBottom
    /// How far the fade-out reaches below.
    ///
    /// Long, and that is the point: the transition must be soft, or the edge where it
    /// ends is visible. Kept short, it would have to fall from 90 percent to zero in
    /// a few dozen points, which **is** an edge; no distribution helps.
    var outro: CGFloat = 220

    /// A single long falloff instead of the stepped curve.
    ///
    /// The steps below are for pages where tiles scroll under the bar: there the
    /// strong zone should be short so the first row is not grayed. On Home nothing
    /// scrolls up; a landscape image sits there, and on light motifs every step shows
    /// as a band. Only softness counts here.
    var soft = false

    /// Scales every stop. Below 1 the scrim stays a quiet shadow, so the look's glow
    /// behind the page is not darkened by it.
    var strength: Double = 1

    /// The stops in **points**, not fractions.
    ///
    /// Fractions failed: whenever `headerHeight` changed, the whole curve moved and the
    /// strong zone suddenly ended beside the bar. In points every stop hangs on the
    /// bottom edge of the bar and stays there.
    ///
    /// Gap and softness are **the same screw**: the further the falloff is drawn, the
    /// softer it gets, and the lower the first row has to begin so the falloff does
    /// not gray it.
    ///
    /// The way out is not to aim for zero: at the row title about 10 percent remain,
    /// which nobody sees on white type. So the falloff can be short (104 points)
    /// while the fade-out still runs over 220, just inaudibly quiet instead of
    /// visibly ending.
    private var anchorPoints: [Gradient.Stop] {
        let total = headerHeight + outro
        func point(_ y: CGFloat, _ coverage: Double) -> Gradient.Stop {
            Gradient.Stop(color: Theme.reason.opacity(coverage * strength),
                          location: min(max(y / total, 0), 1))
        }
        if soft {
            return [
                point(0,                    0.72),
                point(headerHeight,            0.44),
                point(headerHeight + outro * 0.45, 0.14),
                point(total,               0.00),
            ]
        }
        return [
            point(0,               0.92),
            point(headerHeight,       0.90),
            point(headerHeight +  18, 0.72),
            point(headerHeight +  36, 0.52),
            point(headerHeight +  54, 0.34),
            point(headerHeight +  72, 0.18),
            point(headerHeight +  86, 0.09),
            point(headerHeight + 104, 0.04),
            point(headerHeight + 132, 0.015),
            point(total,          0.00),
        ]
    }

    var body: some View {
        LinearGradient(stops: anchorPoints, startPoint: .top, endPoint: .bottom)
        .frame(height: headerHeight + outro)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}


// MARK: - Notices

/// Short message above everything that goes away by itself.
///
/// Every server error lands here, as on the iPhone.
struct HintStrip: View {
    let text: String
    var close: () -> Void = {}

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 26))
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.tile)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(Theme.warning)
        .padding(.horizontal, 30)
        .padding(.vertical, 20)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .strokeBorder(Theme.warning.opacity(0.3), lineWidth: 2)
        }
        .frame(maxWidth: 1100)
        // **Bound to the text**, as on the iPhone. Without `id` the timeout of the first
        // message kept running when a second one arrived while the first was still
        // showing, and took the second away after the remaining time.
        .task(id: text) {
            // Goes away by itself: on tvOS there is no convenient way to tap a message away,
            // and it should not stay.
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            close()
        }
    }
}

// MARK: - Wrapping row

/// Heading above a group of rows. **Sentence case, not capitals**, the same
/// decision as on the iPhone: capitals are harder to read and need tracking to be
/// legible at all, and 21 pt above a group whose rows carry 30 was quieter than
/// what it heads. At three meters that counts double.
struct GroupsTitle: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .font(Theme.rail)
            .tracking(Theme.lockRail)
            .foregroundStyle(Theme.fontQuiet)
            .padding(.leading, 26)
            .padding(.bottom, 16)
    }
}

/// **The divider in a board or sheet: full width.**
///
/// The shared `Uebernahmeauswahl` reads it. An inset is right in a list at the
/// screen edge; in a board the rounded edge already is the group, and an inset
/// would be a second edge that lines up with nothing. The full reasoning is in
/// `Sources/Shared/Style.swift`, where the iPhone version carries it.
struct SheetLine: View {
    var body: some View {
        Rectangle().fill(Theme.line).frame(height: 1)
    }
}
