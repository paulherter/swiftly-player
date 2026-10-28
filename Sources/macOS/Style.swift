import SwiftUI
import JellyfinKit

/// Sizes, font sizes and base shapes for the Mac.
///
/// Colors live in `Sources/Shared/Colors.swift` and are identical to iPhone and
/// TV. Everything here is Mac-specific for two reasons only:
/// **pointer instead of finger** and **window instead of screen**.
///
/// The type steps match the iPhone: 28 / 20 / 16 / 15 / 14 / 12 / 10. A Mac is
/// viewed from about the same distance as a phone in hand; the area changes,
/// not the reading distance. All aspect ratios carry over too: poster 2:3,
/// landscape tile 16:9. Only the absolute values grow.
extension Theme {
    /// Same hairline as on iPhone, so the shared components in `Sources/Shared`
    /// find it here too.

    /// **Same names as on iPhone**, so the shared components in `Sources/Shared`
    /// find them here too. The values are this platform's; the role is the same.
    static var motionReduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// With Reduce Motion, a short cross-fade replaces the movement. Same value as
    /// on iPhone, for the shared parts (episode card, image color).
    static let fadeReduced: Animation = .linear(duration: 0.14)

    /// **The small corner radius, for things shorter than 34 pt.** The radius scales
    /// with the element: 10 on a height of 48 is a ratio of 0.21, and the same ratio
    /// gives 8 on a height of 30. On TV everything is doubled, so 16 there.
    static let cornerSmall: CGFloat = 8

    // MARK: - Press feedback

    /// **The same two styles as on iPhone**, so the shared components in
    /// `Sources/Shared` find them here too. A row gets a highlight surface, a
    /// button shrinks. Every button responds to a press.
    struct PressRow: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View { BodyShell(pressed: configuration.isPressed) { configuration.label } }

        private struct BodyShell<ContentBody: View>: View {
            let pressed: Bool
            @ViewBuilder let content: ContentBody
            @Environment(\.isFocused) private var focused

            var body: some View {
                content
                    .background(Theme.hoverArea.opacity(pressed || focused ? 1 : 0),
                                in: RoundedRectangle(cornerRadius: Theme.corner,
                                                     style: .continuous))
                    .animation(Theme.pressCurve(pressed), value: pressed)
                    .animation(Theme.timeFloat, value: focused)
            }
        }
    }

    struct PressButton: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View { BodyShell(pressed: configuration.isPressed) { configuration.label } }

        private struct BodyShell<ContentBody: View>: View {
            let pressed: Bool
            @ViewBuilder let content: ContentBody
            @Environment(\.isFocused) private var focused

            var body: some View {
                content
                    .scaleEffect(pressed && !Theme.motionReduced ? 0.97 : 1)
                    .opacity(pressed ? 0.85 : 1)
                    // **Where keyboard focus is.** Our own button styles cover the system focus
                    // ring and only knew the hover state, which depends on the mouse. With Full
                    // Keyboard Access on, you would walk through the window blind.
                    //
                    // There is no ring. Focus uses the same surface as hover: one signal for
                    // "you are here", once with the pointer, once with the keyboard.
                    //
                    // **Implemented as its own view rather than `@Environment` in the style
                    // itself**: a `ButtonStyle` is not a `View`, and environment values read inside
                    // it are never updated.
                    .background(Theme.hoverArea.opacity(focused ? 1 : 0),
                                in: RoundedRectangle(cornerRadius: Theme.corner,
                                                     style: .continuous))
                    .animation(Theme.pressCurve(pressed), value: pressed)
                    .animation(Theme.timeFloat, value: focused)
            }
        }
    }

    /// **The surface under the pointer.** White at 6 percent, kept as one value
    /// because it was repeated as a literal in many call sites. Hover is the one
    /// state that exists only on the Mac, and it means "the pointer is here", not
    /// "selected".
    static let hoverArea = Color.white.opacity(0.06)

    // MARK: - Motion
    //
    // **Same names and same numbers as on iPhone.** The `.linear(0.14)` fallback
    // for Reduce Motion gets its own name instead of being repeated in the code.

    /// What replaces every animation curve when Reduce Motion is on.
    static let linearReduced = Animation.linear(duration: 0.14)

    /// Press: instant in, 0.12 s out.
    static func pressCurve(_ pressed: Bool) -> Animation? {
        pressed ? nil : .easeOut(duration: 0.12)
    }

    /// Switches and checkmarks: 0.10 s.
    static var toggle: Animation {
        motionReduced ? linearReduced : .easeOut(duration: 0.10)
    }

    /// Panels, expanding sections, action list: 0.22 s.
    static var leap: Animation {
        motionReduced ? linearReduced : .snappy(duration: 0.22)
    }

    /// How strongly the incoming area scales up as it arrives.
    static var sectionMetric: CGFloat { motionReduced ? 1 : sectionSmaller }


    // MARK: Window

    /// Smallest window size at which the grid still works:
    /// sidebar plus two tile columns plus margins.
    static let windowMinWidth: CGFloat = 900
    static let windowMinHeight: CGFloat = 560

    /// **Maximum width of a settings page.**
    ///
    /// The pages follow the iPad layout: two columns, left-aligned with the content,
    /// not centered in the window. On iPad the device sets the limit (1366 pt in
    /// landscape on the largest model). A window has no such limit; without one, a
    /// large screen would show two cards of 900 pt each side by side, with the
    /// switch a hand's width away from its title.
    static let settingWidth: CGFloat = 1366

    /// **Reading width for a single-column subpage.** Same value as the iPhone and
    /// iPad version (`Theme.readWidth`): a row of icon, title and a value on the
    /// right, stretched across half the window, leaves nothing but empty space
    /// between the two ends.
    static let readWidth: CGFloat = 700

    /// **Width of a form** (sign-in, adding a server, Seerr). Same value as on
    /// iPhone, wide variant.
    static let formWidth: CGFloat = 420

    /// **Width of a column on the player's layers** (picture, sleep timer, quality):
    /// short words such as "Original" or "30 Min.", five columns side by side in the
    /// smallest window.
    static let layerColumnWidth: CGFloat = 200

    /// **Width of the audio and subtitle columns.** A track row carries language, flags,
    /// format and file ("Английский · Принудительные · SRT · Файл"); at 200 such rows
    /// truncated while most of the layer stood empty. 360 fits that row at body size, and
    /// two columns with their spacing stay well inside `windowMinWidth`.
    static let trackColumnWidth: CGFloat = 360

    /// Space for the window traffic lights, **in the sidebar only.**
    ///
    /// The three dots sit at the top left of the window, above the sidebar. They end
    /// at about 27 pt; the wordmark also brings its own space, because its artwork
    /// includes the dot over the "i" and the descender of the "y" while the letters
    /// fill only half the height. 40 is therefore enough.
    ///
    /// How far from the top the zone extends in which the traffic lights appear in
    /// the player. Slightly more generous than the lights themselves, so they are
    /// easy to find.
    static let signalZone: CGFloat = 90

    static let signalHeight: CGFloat = 40

    /// Top margin in the **content area**, the same as the side margin.
    ///
    /// Nothing needs to be kept clear here: content starts to the right of the
    /// sidebar, and the traffic lights are not above it. A larger top margin looked
    /// like a huge gap above the first heading, so it uses the same value as the
    /// side margin, as **the same** value rather than a second 24: changing the side
    /// margin changes the top one with it.
    static let contentTop: CGFloat = edgeSpacing

    /// **The bar that appears when scrolling** (`Bestandsleiste`).
    ///
    /// 40, not `contentTop`: it has to hold a 17 pt line and the 40 pt tall back
    /// arrow, and it is deliberately shorter than the top margin of resting content.
    /// It should be a bar, not a second header.
    static let headerBarHeight: CGFloat = 40


    /// Height of a detail page's header bar (arrow and fading-in title).
    static let titleHeight: CGFloat = 52

    static let sidebarWidth: CGFloat = 220

    // MARK: Dimensions

    /// **The corner radius scale.** Same rule as on iPhone: the larger the surface,
    /// the rounder, and button and tile share the smallest step because both are
    /// small objects. A difference of two points between two neighboring elements
    /// reads as a mistake, not as a hierarchy.
    static let corner: CGFloat = 10
    static let cornerTile: CGFloat = 10
    static let cornerField: CGFloat = 12
    /// **Card and group**: the settings card, the group in a list. Same 14 as on
    /// iPhone.
    static let cornerCard: CGFloat = 14
    /// What counts as a surface of its own: panels, info boxes.
    static let cornerArea: CGFloat = 16
    /// **The sheet.** Nothing slides in from the bottom on the Mac; the action list
    /// expands in place. The value exists here anyway, so a shared component finds it
    /// and nobody hard-codes 28.
    static let cornerSheet: CGFloat = 28
    /// One side margin per sheet (same value as on iPhone).
    static let sheetInset: CGFloat = 24
    static let edgeSpacing: CGFloat = 24

    /// **Where the hairline starts in a settings card.**
    ///
    /// It aligns with the text, not with the card edge: 12 inner padding plus 20
    /// icon column plus 14 gap to the text.
    static let separatorInsetCard: CGFloat = 46
    static let tileSpacing: CGFloat = 12
    static let railsSpacing: CGFloat = 28

    /// **Scroll distance over which the value row fades out**: 44, as on iPhone.
    /// The distance drives opacity only, never a height: as soon as a header height
    /// depends on the scroll offset, it changes the safe-area inset that is part of
    /// the measurement, and the header never settles.
    static let valueRailsDistance: CGFloat = 44

    /// Poster, 2:3 (112 x 168 on iPhone).
    static let tileWidth: CGFloat = 150
    static let tileHeight: CGFloat = 225

    /// Continue Watching is landscape, 16:9 (240 x 135 on iPhone).
    static let landscapeWidth: CGFloat = 280
    static let landscapeHeight: CGFloat = 158

    /// The header zone of the detail page.
    ///
    /// **Exactly the content, no spare space**: 150 above plus a 230 block.
    ///
    /// All the spare space is **above**. There must be none below: the gap from the
    /// button row to the first heading should match the gap between all other
    /// sections (26). Any slack in this zone would add to it, and the "Cast" row
    /// would sit further from the row above than "Similar" does.
    static let heroHeightValue: CGFloat = 380

    // MARK: Hit targets - smaller than on iPhone

    /// A pointer is more precise than a finger. Apple's own sidebars use 28; 32 gives
    /// 15 pt text a bit more room.
    static let rowHeight: CGFloat = 32
    /// **The icon field of the action row** (48 x 48 on iPhone).
    ///
    /// A button without a label is square, and 40 instead of 48 is the one allowed
    /// deviation: a pointer is more precise than a finger.
    static let buttonField: CGFloat = 40
    /// The main button stays 48 tall but does **not** span the full width:
    /// a pointer hits a button, a thumb needs the area.
    static let primaryButtonHeight: CGFloat = 48

    /// **Fixed width of the main button.**
    ///
    /// Otherwise the rest of the row adapts to the label length, and the watchlist
    /// and More buttons sit in a different place on every page. 200 fits
    /// "Fortsetzen" and "Abspielen" (Resume and Play) with room to spare.
    static let primaryButtonWidth: CGFloat = 200

    /// **The main button under the pointer.** White at 88 percent, the step between
    /// resting (full) and pressed (75).
    static let primaryButtonHovers = Color.white.opacity(0.88)

    // MARK: Type - same scale as on iPhone

    static let titleLarge = Font.system(size: 28, weight: .bold)
    /// **The title over a hero image *is* the page title.** It used to be 34 on the
    /// Mac, a separate step for the same role, which the shared scale does not have.
    /// This name previously carried the 22 of the subpage title, which now has its
    /// own name.
    static let title      = titleLarge
    /// **Subpage title**, 22 semibold, same name as on iPhone.
    static let subpageTitle = Font.system(size: 22, weight: .semibold)
    static let rail      = Font.system(size: 20, weight: .semibold)
    /// Sheet heading and detail bar.
    static let categoryLarge = Font.system(size: 17, weight: .semibold)
    /// Old name of the same step. Kept while call sites still use it.
    static let bar     = categoryLarge
    static let listTitle = Font.system(size: 15, weight: .semibold)
    static let body    = Font.system(size: 15)
    /// Title under a poster: 13, not 14, because 14 is not on the scale.
    static let tile      = Font.system(size: 13, weight: .medium)
    /// Old name of the same step.
    static let tileTitleText = tile
    /// Meta line: year, role, runtime.
    static let small      = Font.system(size: 12)
    /// Old name of the same step.
    static let secondLine = small
    static let badge   = Font.system(size: 10, weight: .semibold)
    /// Group title, 11 semibold.
    static let group     = Font.system(size: 11, weight: .semibold)
    /// Old name of the same step.
    static let category     = group

    // MARK: Tracking
    //
    // **It belongs to the type step, not to the call site.** Each value is the em
    // value of the scale times the point size, the same numbers as on iPhone, since
    // Mac and iPhone share the same scale.

    /// 28 · -0.021 em
    static let lockTitle      = -0.6
    /// 22 · -0.014 em
    static let lockSubpage = -0.308
    /// 20 · -0.012 em
    static let lockRail      = -0.24
    /// 17 · -0.008 em
    static let lockCategory     = -0.136
    /// 11 · +0.14 em
    static let lockGroup     = 1.54
    /// 10 · +0.10 em
    static let badgeLock: CGFloat = 1.0

    // MARK: Durations - verbatim from the iPhone version

    /// Hover: 0.12 s, the same duration as the press.
    static let timeFloat   = Animation.easeOut(duration: 0.12)

    /// The paging arrows of a row fade in and out softly (`FadeTimes.arrows`),
    /// the same on Linux and Windows.
    static let timeArrow = Animation.easeInOut(duration: FadeTimes.arrows)

    // MARK: Page transitions - three motions, each tied to a meaning
    //
    // Every call site used to do something different: switching areas did nothing,
    // switching phases used `.default`, the player had its own duration. From
    // outside it looked as if the app sometimes animated and sometimes did not.
    //
    // The rule: **what the motion means decides how it looks.**
    //
    // Replace      The content area shows something else, such as Start vs.
    //              Movies, or sign-in vs. library. Nothing travels, so it
    //              cross-fades.
    // Deeper       One level in: detail page, settings. It slides in from the
    //              right, and the way back is familiar. `NavigationStack` does
    //              this by itself.
    // Rise         The player takes the whole window. It comes from below and
    //              returns there, which is why the chevron at the top left
    //              points down.

    /// How content appears once it has arrived, the same curve as on iPhone.
    /// **Nothing appears abruptly**: images fade in, content replaces placeholders.
    static var reveal: Animation {
        motionReduced ? linearReduced : .easeInOut(duration: 0.28)
    }

    // MARK: Switching in the bar - first out, then in

    // **No cross-fade.** The old content goes first, briefly with `easeIn`; only
    // once it is gone does the new content arrive with `easeOut`. Overlapping the
    // two put two half-visible pages on top of each other in the middle, which looks
    // untidy. Blur and a hint of zoom were removed as well; only opacity animates.
    // The numbers live in the package (`FadeTimes`) so Linux and Windows use the
    // same ones.

    /// The old content leaves.
    static let timeSectionToOut = Animation.easeIn(duration: FadeTimes.pageToOut)
    /// The new content arrives only afterwards, hence the delay of the full length.
    static let timeSectionFromIn = Animation.easeOut(duration: FadeTimes.pageFromIn)
        .delay(FadeTimes.pageToOut)

    /// How little tab content grows when it appears (`sectionMetric`, used in the
    /// shared `Theme`): 99.6 %, about three points at the window edge. Switching
    /// areas itself no longer scales.
    static let sectionSmaller: CGFloat = 0.996

    /// Cross-fade when replacing. 180 ms ease-out, the same duration in which the
    /// player controls appear on iPhone.
    static let timePage = Animation.easeOut(duration: 0.18)

    /// The slide when going deeper.
    ///
    /// **Measured, not estimated.** The curve was recorded frame by frame; the numbers
    /// below come from that.
    ///
    /// `smooth(0.50)`, a spring, looked right on paper and was not: it covered **90 %
    /// of the distance in 320 ms** and crept through the remaining ten percent over
    /// 1.2 seconds. A rush at the start, nothing at the end. That reads as "too fast
    /// and abrupt" even though "0.5 seconds" is stated: for a spring, the duration is
    /// a feel, not a distance.
    ///
    /// `easeInOut` spreads evenly (half the distance in half the time) and stops when
    /// it is done. 450 ms, which is 50 % longer than the 300 ms that was too short.
    static let timePagesPush = Animation.easeInOut(duration: durationPagesPush)

    /// **The "Hier weiterschauen" (Continue Watching) badge in the sidebar**: its
    /// height and its distance from every edge it touches (left, right, bottom). One
    /// value, so the three cannot drift apart again; Linux and Windows use the same
    /// numbers.
    static let badgeHeight: CGFloat = 40
    static let badgeEdge: CGFloat = 12
    /// The same number for `InTravel`: how long to wait for what comes from the server.
    static let durationPagesPush: Double = 0.45
}

extension AnyTransition {
    /// Switching in the bar: sequential, opacity only (see `Theme.timeSectionToOut`).
    ///
    /// Computed rather than stored: `AnyTransition` is not `Sendable`, so a stored
    /// property would be shared mutable state under Swift 6.
    static var sectionSwitch: AnyTransition { .asymmetric(
        insertion: .opacity.animation(Theme.timeSectionFromIn),
        removal: .opacity.animation(Theme.timeSectionToOut)) }
}

/// **One hairline, one component**, on the Mac too.
///
/// The shared views in `Sources/Shared` use `SeparatorLine()`. Two versions of the
/// same line are one too many.
struct SeparatorLine: View {
    var body: some View {
        Rectangle()
            .fill(Theme.line)
            .frame(height: 1)
            .padding(.leading, Theme.edgeSpacing)
    }
}

/// **The divider in a panel or sheet: full width.**
///
/// The shared component `Uebernahmeauswahl` reads it. An inset is right in a list
/// at the screen edge; in a panel the rounded edge already is the group, and an
/// inset would only be a second edge that aligns with nothing. The full reasoning
/// is in `Sources/Shared/Style.swift`, where the iPhone version carries it.
struct SheetLine: View {
    var body: some View {
        Rectangle().fill(Theme.line).frame(height: 1)
    }
}
