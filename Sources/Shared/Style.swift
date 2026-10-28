import JellyfinKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Dimensions, font sizes and building blocks for the iPhone. The colors live in
/// `Colors.swift` because both platforms share them.
///
/// Deliberately not using iOS standard materials: no `.ultraThinMaterial`, no
/// glass effects, no system backgrounds. Surfaces are flat and opaque so that
/// the artwork is the only color in the room.
extension Theme {

/// **What replaces every curve under "Reduce Motion".**
///
/// Apple replaces motion not with stillness but with a short crossfade; a hard
/// cut would be worse than gentle motion. The 0.14 seconds used to be spelled
/// out four times in the curves below: one role, four places, and anyone
/// writing a fifth curve would type it a fifth time. (`toggle` has its own,
/// shorter fade of 0.10; it belongs to a switch, not to a page change.)
static let fadeReduced: Animation = .linear(duration: 0.14)

    /// How a section changes: the content arrives from slightly too small a
/// scale and fades in.
///
/// **Very subtle, on purpose.** 0.97 and 0.22 seconds: you don't see it, you
/// feel it. This is exactly what iOS does when switching tabs, and it is why a
/// switch there feels soft instead of like a cut.
static var sectionSwitch: Animation {
    motionReduced ? fadeReduced
                      : .snappy(duration: 0.20, extraBounce: 0)
}
/// How compressed the incoming section starts out.
///
/// **0.995, corrected downward three times.** At 0.97 the top edge of an
/// 844 pt page moved twelve points inward, at 0.99 still four; both were
/// visible as an edge. Two points is the limit where the motion still works and
/// nothing stands out.
static var sectionMetric: CGFloat { motionReduced ? 1 : 0.995 }

/// How content appears once it has arrived from the server.
///
/// **The loading spinner is gone from the UI.** It sat on every page that
/// fetches something, and a spinning ring only says "wait": it shows neither
/// what is coming nor how much. In its place are placeholders shaped like the
/// coming content, and once it arrives it is crossfaded in.
static var reveal: Animation {
    Motion.change
}

/// How a progress arc follows a new value: **linear**, so it does not
/// accelerate and brake on every update, and just under half a second so it
/// runs calmly and never falls back. Under Reduce Motion it simply jumps to the
/// new value.
static var progressTravel: Animation? {
    motionReduced ? nil : .linear(duration: 0.4)
}

/// How a sheet slides in from the bottom.

/// How a sheet slides in from the bottom.
    ///
    /// **Matched to Apple's sheet, not guessed.** Fast approach, no overshoot:
    /// the same curve `.sheet` shows. It lives here and not at the call sites,
    /// otherwise four sheets would have four curves.
    static var sheetMotion: Animation {
        Motion.sheet
    }

    /// **A row that responds to the press, not only to the release.**
    ///
    /// `onTapGesture` has no pressed state: nothing happens between touch-down and
    /// release, and that tenth of a second decides whether a surface feels awake.
    /// Apple therefore puts the feedback on the press; `apple-design` calls this the
    /// point where the feeling of immediacy "falls off the cliff".
    ///
    /// **Rows dim, buttons shrink.** A full-width row that contracts looks like a
    /// bug; a small button that only changes color feels dull. Hence two styles
    /// instead of one.
    /// **The press is instant, the release may fade out.**
    ///
    /// Making both equally fast was the first instinct and is wrong: feedback to
    /// the finger must have no duration, since every millisecond there is one where
    /// immediacy is lost. Going back, on the other hand, is a system response and
    /// may be soft. `nil` here explicitly means "no animation", not "default".
    static func pressCurve(_ pressed: Bool) -> Animation? {
        // easeOut, not linear: the release should run out, not stop abruptly.
        pressed ? nil : .easeOut(duration: 0.12)
    }

    struct PressRow: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background(Theme.font.opacity(configuration.isPressed ? 0.06 : 0))
                .animation(Theme.pressCurve(configuration.isPressed),
                           value: configuration.isPressed)
        }
    }

    /// **Press via opacity only**, for text that sits directly on artwork color.
    /// `active: false` behaves like ``Druckzeile``.
    struct PressText: ButtonStyle {
        var active = true
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background(Theme.font.opacity(!active && configuration.isPressed ? 0.06 : 0))
                .opacity(active && configuration.isPressed ? 0.6 : 1)
                .animation(Theme.pressCurve(configuration.isPressed),
                           value: configuration.isPressed)
        }
    }

    struct PressButton: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !motionReduced ? 0.97 : 1)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .animation(Theme.pressCurve(configuration.isPressed),
                           value: configuration.isPressed)
        }
    }

    /// **A short tap to confirm.**
    ///
    /// Apple's "Designing Fluid Interfaces" treats haptics not as decoration but as
    /// a second channel of the same feedback: motion says *what* happens, the tap
    /// says *that* it happened. Without it, a button that triggers a network request
    /// feels indecisive.
    ///
    /// **Phone only.** A TV has nothing that could vibrate, and on the Mac it only
    /// exists under the trackpad, where it would be more irritating than helpful on
    /// a button.
    ///
    /// It fires on the **press**, not after the server's reply: a tap that arrives
    /// half a second later no longer feels connected to anything.
    /// `erfolg` used to exist as a third case and was never triggered; a message the
    /// server confirms comes too late for a tap (see above: it fires on press).
    /// Removed instead of left standing as an offer.
    enum JerkKind { case lightweight, medium }

    @MainActor
    static func jerk(_ art: JerkKind) {
        #if os(iOS)
        guard !motionReduced else { return }
        switch art {
        case .lightweight:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .medium:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        #endif
    }

    /// **Has the user turned on "Reduce Motion"?**
    ///
    /// Apple then replaces motion with a crossfade, not with stillness; a hard cut
    /// would be worse than gentle motion. So the curves above return a short linear
    /// fade in this case, and `sectionMetric` falls back to 1 so nothing scales at
    /// all.
    ///
    /// **Central here, not at 31 call sites.** `einblenden` alone appears 31 times
    /// in the code; asking at each site would be exactly the kind of duplication
    /// that drifts apart later.
    static var motionReduced: Bool {
        #if canImport(UIKit)
        return UIAccessibility.isReduceMotionEnabled
        #elseif canImport(AppKit)
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        return false
        #endif
    }


    // MARK: Dimensions - iPhone

    /// **The corner scale: four numbers, and the larger the surface, the rounder.**
    /// It used to be not a rule but four numbers at forty places; as a result the
    /// info box on the Seerr page took the field radius although it is a surface.
    /// Whoever builds something new takes the number that fits the kind of thing,
    /// not the one that happened to be nearby.
    ///
    /// | What | Corner | |---|---| | Button, poster, tile | 10 | | Field, input
    /// | 12 | | Surface, sheet, panel | 16 | | Chip, hint | capsule |
    ///
    /// **Rounded up once by four points.** It used to be 6/8/10/12, and a
    /// two-point difference between two things standing side by side is read not as
    /// a hierarchy but as a mistake.
    ///
    /// Button and tile therefore carry the **same** corner: both are small objects,
    /// and the hierarchy only starts above them.
    static let corner: CGFloat = 10
    /// Posters and tiles: the same corner as a button.
    static let cornerTile: CGFloat = 10
    /// Search and input fields.
    static let cornerField: CGFloat = 12
    /// **Width of the audio and subtitle columns in the player.** "Russian · AC-3 · 5.1"
    /// and "English · Forced · SRT · File" fit; 210 cut them after the codec. Two
    /// columns of 300 stand side by side in a landscape iPhone. The Mac has its own
    /// value (`Sources/macOS/Style.swift`).
    static let trackColumnWidth: CGFloat = 300
    static let trackColumnWidthPad: CGFloat = 360

    /// **The small corner, for things under 34 pt height.** The corner grows with
    /// the thing: 10 on a height of 48 is 0.21, and the same ratio gives 8 on a
    /// height of 30. Used by the tier field and the badges.
    static let cornerSmall: CGFloat = 8
    /// What counts as a surface of its own: the panel, info boxes.
    ///
    /// **Not the sheet from below**: that takes `cornerSheet` (28) and used to be
    /// listed here as an example anyway. Whoever read the note instead of looking at
    /// the building block built a sheet with 16.
    static let cornerArea: CGFloat = 16

    /// **The card: 14.** It used to carry `eckeFlaeche` (16) and was therefore as
    /// round as a sheet: two kinds of object with one corner. 14 stands in the
    /// ladder for cards and groups.
    static let cornerCard: CGFloat = 14

    /// **The sheet from below: 28.** It carried 16 and so looked more angular than
    /// every system sheet next to it.
    static let cornerSheet: CGFloat = 28
    /// **One side margin per sheet**: heading, groups, buttons and texts start and end on
    /// this line (the row of look icons may sit further out on purpose).
    static let sheetInset: CGFloat = 24
    static let edgeSpacing: CGFloat = 18
    static let tileSpacing: CGFloat = 12
    static let railsSpacing: CGFloat = 28

    /// Posters are portrait everywhere, 2:3. Reduced from 132 × 198: the tiles were
    /// too bulky, and more fit side by side.
    static let tileWidth: CGFloat = 112
    static let tileHeight: CGFloat = 168

    /// Hero image on the detail pages, the **same** for movies and series.
    static let heroHeightValue: CGFloat = 300

    /// Height of the navigation bar without the home-indicator area.
    static let stripHeight: CGFloat = 54

    /// **The path along which the value row closes and releases.**
    ///
    /// 30 pt pill height plus the 14 spacing above it.
    static let valueRailsDistance: CGFloat = 44


    // MARK: Dimensions - iPad

    /// The bar sits on the **left** on iPad, not on top.
    ///
    /// The TV has it on top, and the temptation to copy that was big. But there a
    /// remote control is used, so reachability doesn't matter. On a held iPad the
    /// top edge is the worst spot of all. What comes from the TV is therefore the
    /// composition of the pages, not the grip height.
    ///
    /// 88 pt, because the wordmark at 20 pt height is 59 wide and fits with 14 pt
    /// of air on each side.
    static let sidebarWidth: CGFloat = 88
    /// iPhone Duo: width of the symbol bar on the right edge, and the height the
    /// system's status column (clock, Wi-Fi) takes at its top.
    static let duoBarWidth: CGFloat = 96
    /// Duo outer display: no top safe area, but the corner and camera sit at the edge.
    static let duoTop: CGFloat = 30
    static let duoStatusColumn: CGFloat = 160

    /// Side margin on the wide layout. Between iPhone (18) and TV (80); on the TV
    /// half of the 80 is overscan at the screen edge, which doesn't exist here.
    static let edgePageWide: CGFloat = 28

    /// Hero image on the wide layout.
    ///
    /// Sized by the **content**, not the screen: poster 252 plus 40 below plus 128
    /// of air above. On the TV the hero fills the whole 1080 pt, and that works
    /// there; at 768 full height would only mean scrolling to reach the description.
    static let heroHeightWide: CGFloat = 420

    /// Poster on the wide layout's detail pages: 2:3 as everywhere.
    static let heroPosterWidth: CGFloat = 168
    static var heroPosterHeight: CGFloat { heroPosterWidth * 1.5 }

    /// Target width of a tile in the grid. Feeds into `columns(usableNow:wide:)`.
    ///
    /// Narrow 104, and this is not freely chosen: it makes the formula yield exactly
    /// three columns on **every** iPhone, from 375 (SE) to 440 (Pro Max). The shipped
    /// behavior stays exactly as it is.
    ///
    /// Wide 124. With 104 on iPad, nine columns came out and thus tiles of 104 pt,
    /// **narrower than on iPhone**, where they measure 110. The smallest posters on
    /// the biggest screen was visibly wrong at first glance.
    static func tileTarget(wide: Bool) -> CGFloat { wide ? 124 : 104 }

    /// Width for body text and list rows on the wide layout.
    ///
    /// A description wider than 1036 pt is a line of 140 characters, and an episode
    /// row wider than 1036 pt puts the checkmark half a meter from the title.
    /// Galleries and grids still use the full width; they are for skimming, not
    /// reading.
    static let readWidth: CGFloat = 700

    static func margin(wide: Bool) -> CGFloat { wide ? edgePageWide : edgeSpacing }

    /// Where the hairline between two rows starts: after the icon.
    ///
    /// The 52 on iPhone is not freely chosen but margin 18 plus icon 20 plus spacing
    /// 14. With the wide margin that becomes 62; whoever changes only the margin and
    /// leaves this number gets lines that shift relative to the text.
    ///
    /// **Not flush with the text, and that is not carelessness but a measurement.**
    /// `SeparatorLine` itself adds `.padding(.leading, edgeSpacing)`, so the line starts
    /// another 18 pt to the right of the text. On iPhone it has always been that way.
    /// This formula yields the same relation on iPad: measured in the simulator, text
    /// at 167, line at 184.
    static func separatorInset(wide: Bool) -> CGFloat { margin(wide: wide) + 34 }

    /// The same inset **inside a card**.
    ///
    /// The card is already indented by `rand`; taking the full inset there pushes the
    /// hairline too far right by exactly that margin. `SeparatorLine` brings its own 18
    /// along, hence 34 and not 52.
    static func separatorInsetCard(wide: Bool) -> CGFloat { 34 }

    /// How far below the safe area a page header starts.
    ///
    /// The same value the wordmark in the sidebar uses; otherwise heading and
    /// wordmark sit at different heights, which is immediately visible: the page
    /// starts at the top, the sidebar next to it a bit lower.
    static let headerTop: CGFloat = 26

    /// Tile dimensions of the rows on the home page.
    ///
    /// On iPhone, row and grid measure practically the same (112 vs 110), and on the
    /// TV one number serves both (208). On iPad only the grid grew with the width and
    /// the rows stayed at 112: the same poster was a fifth smaller on the home page
    /// than in the library. One device, two sizes.
    ///
    /// The rows still stay **fixed**: with more room they show more, not bigger. Only
    /// the fixed value differs in the wide layout, chosen in the middle of what the
    /// grid yields there: 126 portrait, 138 landscape.
    static func railsWidth(wide: Bool) -> CGFloat { wide ? 132 : tileWidth }
    static func railsHeight(wide: Bool) -> CGFloat { railsWidth(wide: wide) * 1.5 }

    /// Horizontal 16:9 for "Continue Watching", about twice as wide as a poster:
    /// the same ratio as on iPhone (236 to 112) and on the TV (448 to 208).
    static func railsLandscapeWidth(wide: Bool) -> CGFloat { wide ? 280 : 236 }
    static func railsLandscapeHeight(wide: Bool) -> CGFloat { wide ? 158 : 133 }

    /// From this window width on, the play button and the action row sit side by
    /// side. Poster 168 + 32 spacing + about 620 button row + twice the margin make
    /// just under 900.
    static let landscapeHeaderOffWidth: CGFloat = 900

    /// Width for sign-in, server and Quick Connect.
    ///
    /// An input field wider than 1288 pt is no longer a field but a strip, and the
    /// way from the start of the row to the button below is absurd. 420 is the width
    /// these pages have on a big iPhone; a form of three rows needs no more.
    static let formWidth: CGFloat = 420

    /// How many columns fit into the usable width.
    ///
    /// The TV has a constant for this (`gridColumns = 7`), which is enough there:
    /// its screen is always 1920 wide. An iPad is not like that: in split screen only
    /// 320 of it remain.
    ///
    /// At least two. At 320 pt window width three tiles would be 87 pt wide, and
    /// below that a poster is no longer a poster.
    static func columns(usableNow: CGFloat, wide: Bool) -> Int {
        max(2, Int((usableNow + tileSpacing) / (tileTarget(wide: wide) + tileSpacing)))
    }

    /// Whether the device is an iPad, regardless of how wide the window currently
    /// is.
    ///
    /// `@MainActor`, and that is not decoration: `UIDevice.current` belongs to the
    /// main actor. Without it this was a non-isolated property accessing main-actor
    /// state, the same class of bug as in the playback hub, only the other way
    /// around. The compiler reported it here because nothing had been promised that
    /// it could have trusted.
    @MainActor
    static var atPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// **A phone whose screen is as roomy as a small tablet**: the inner display of
    /// iPhone Duo. The idiom stays `.phone` there, so `atPad` says no, yet the
    /// layout, rotation and player must behave like on an iPad.
    ///
    /// Measured by the shorter side of the current screen, not by a device name:
    /// the widest iPhone is 440 points, the Duo's inner display well above 500,
    /// and on its outer display this is false again, so it follows the fold.
    @MainActor
    static var innerDisplay: Bool {
        guard UIDevice.current.userInterfaceIdiom == .phone,
              let bounds = UIApplication.shared.connectedScenes
                  .compactMap({ $0 as? UIWindowScene }).first?.screen.bounds
        else { return false }
        return min(bounds.width, bounds.height) >= 500
    }

    /// Layout, rotation and player of a tablet: an iPad, or the Duo's inner display.
    /// **This, not `atPad`, answers "may I use the room"**; `atPad` stays for what
    /// only an iPad has (window buttons, multitasking).
    @MainActor
    static var roomy: Bool { atPad || innerDisplay }

    // MARK: Type: iPhone

    // Everything one step larger than before; the text was too small.
    // Scale taken from Plex, the exact values are in the canvas under "Maßstab".
    // Ten steps, no more. The ladder is defined in the brand document, section 2;
    // Mac and iPad carry the same one, the TV double.
    static let titleLarge  = Font.system(size: 28, weight: .bold)
    /// **The same size as `titleLarge`.** The title above a hero image *is* the page
    /// title; a second step for the same role only means the wrong one will apply
    /// somewhere eventually. It used to be 27.
    static let title       = Font.system(size: 28, weight: .bold)
    /// **Subpage title.** It was in the ladder but had no token; the
    /// `SubpageHeader` set 22 Semibold as a literal.
    static let subpageTitle = Font.system(size: 22, weight: .semibold)
    static let rail       = Font.system(size: 20, weight: .semibold)
    /// Sheet heading and detail bar.
    static let categoryLarge = Font.system(size: 17, weight: .semibold)
    static let listTitle = Font.system(size: 15, weight: .semibold)
    static let body     = Font.system(size: 15)
    // **Scaling versions of the same steps.**
    //
    // The spec says: "Body text, lists, settings and empty states follow the system
    // font. Posters, bars and player stay fixed." Exactly these four steps are the
    // ones, and they were all fixed: whoever enlarged the font on the iPhone saw
    // **no change** in settings, profile, downloads, search and all lists. The
    // fixed versions remain alongside: tiles, bars and player need them, otherwise
    // they overflow their frame.
    // Whoever wants one to scale uses `.growing(15, .semibold)` instead of
    // `.font(Theme.listTitle)`: the modifier computes with `@ScaledMetric`, which a
    // `Font` constant cannot.
    /// Title under a poster. It used to be 14; 14 is on no ladder, and the tile
    /// should be quieter than a list row.
    static let tile      = Font.system(size: 13, weight: .medium)
    static let small       = Font.system(size: 12)
    /// **Uppercase, +0.14 em tracking, and currently unused.**
    ///
    /// It was the heading above a group. `Gruppentitel` has carried 20 Semibold in
    /// normal case since the rework, and with the search heading the last place that
    /// still set 11 in uppercase is gone. The step stays in the ladder because the type scale
    /// lists it; whoever uses it again should know it is **not** the group heading.
    static let group      = Font.system(size: 11, weight: .semibold)
    static let badge    = Font.system(size: 10, weight: .semibold)

    // MARK: Tracking
    //
    // **It belongs to the step, not to the call site.** It used to be a literal at
    // seventeen call sites, and the same step carried two values: the row heading
    // -0.24 in the building block and -0.3 in `HomeView`, the sheet heading -0.136
    // here and -0.14 in the profile, the empty state -0.3 at 20 pt instead of -0.24.
    // Not a slip, but the result of the number sitting next to the font call
    // instead of with the font: whoever sets a step estimates the tracking along
    // with it.
    //
    // Every value is the em value from the type scale times the point size.
    /// 28 · −0,021 em
    static let lockTitle      = -0.6
    /// 22 · −0,014 em
    static let lockSubpage = -0.308
    /// 20 · −0,012 em
    static let lockRail      = -0.24
    /// 17 · −0,008 em
    static let lockCategory     = -0.136
    /// 11 · +0,14 em
    static let lockGroup     = 1.54
    /// Badge tracking: +0.10 em at 10 pt is 1.0.
    static let badgeLock: CGFloat = 1.0
}

// MARK: - Wide version

private struct WideKey: EnvironmentKey {
    static let defaultValue = false
}

private struct RoomyKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Enough width to put the detail page's button row **next to** the poster.
    ///
    /// `wide` alone is not enough for that, and that was an expensive mistake: an
    /// iPad in portrait is `regular`, but next to the poster it has only 476 pt.
    /// "Resume at 53 min" plus "From start" plus four action buttons need about 620.
    /// SwiftUI then set the labels vertically, one letter per line.
    ///
    /// On the TV that could not show up: it is always landscape.
    var broad: Bool {
        get { self[RoomyKey.self] }
        set { self[RoomyKey.self] = newValue }
    }

    /// The wide layout: sidebar instead of bottom bar, detail pages composed in
    /// landscape, settings in two columns.
    ///
    /// It is set **once** in `RootView` from size class and device, not recomputed
    /// everywhere. Both conditions are needed: an iPhone Pro Max in landscape also
    /// reports `regular`, and a sidebar would be wrong there. The app is locked to
    /// portrait there anyway, but I don't want to rely on that.
    var wide: Bool {
        get { self[WideKey.self] }
        set { self[WideKey.self] = newValue }
    }

    /// iPhone Duo: the system keeps a status column (clock, Wi-Fi) at the right edge
    /// and the app's symbol bar stands in it instead of at the bottom. Set once in
    /// `RootView` from the measured trailing safe area.
    var duoColumn: Bool {
        get { self[DuoColumnKey.self] }
        set { self[DuoColumnKey.self] = newValue }
    }
}

private struct DuoColumnKey: EnvironmentKey {
    static let defaultValue = false
}

// MARK: - Font that scales

/// A font size that follows the system setting.
///
/// `@ScaledMetric` returns exactly the passed number at the default setting, so
/// the design looks unchanged and only grows once someone enlarges the font.
/// That is exactly why there is no switch to Apple's text styles here:
/// `Font.system(.body)` is 17 pt, our body text measures 15, and that would be a
/// visible change for no reason.
///
/// **Deliberately not applied everywhere.** Tiles, the navigation bar and the
/// player controls use fixed point sizes (112 × 168, bar height 54, buttons 44).
/// There a larger font would overflow the frame instead of stretching it. It is
/// applied where the frame goes along: body text, list rows, settings, empty
/// states. The rest is a work block of its own, since it requires going through
/// every fixed height.
struct Growing: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight

    init(size: CGFloat, weight: Font.Weight) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight))
    }
}

extension View {
    /// Like `.font(.system(size:weight:))`, except the size follows the system
    /// setting.
    func growing(_ size: CGFloat, _ weight: Font.Weight = .regular) -> some View {
        modifier(Growing(size: size, weight: weight))
    }
}

// MARK: - Buttons

/// The big white button at the top of every detail page. White with black text so
/// it stays readable over any poster.
struct PrimaryButtonStyle: ButtonStyle {
    /// Disabled means muted, not translucent.
    ///
    /// White at 40 percent over our background gives a strong gray, which looks like
    /// a button that simply does not respond, instead of one still waiting for
    /// input. A dark surface with quiet text says the same as everywhere else in
    /// the app.
    @Environment(\.isEnabled) private var released

    /// Full width, or only as wide as the label.
    ///
    /// Narrow, full width is right: the button stands alone in its row. Wide, it
    /// stands next to the action row and must not squeeze it out.
    var stretches = true

    /// **What the disabled button sits on.** Disabled, it falls back to `area`;
    /// on a sheet that is itself `area` it would vanish entirely, leaving quiet
    /// text without a button. There it sits one level higher, like the cards above it
    /// (load selection).
    var lockedArea: Color = Theme.area

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // Primary button: 17 semibold. 16 is on no ladder; 17 is the sheet heading's
            // step, and a primary button is at least as loud.
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(released ? Theme.onAccent : Theme.fontVeryQuiet)
            .padding(.horizontal, stretches ? 0 : 28)
            .frame(maxWidth: stretches ? .infinity : nil, minHeight: 48)
            .background(area(pressed: configuration.isPressed),
                        in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            // **The primary button shrinks too.** It used to signal the press only through
            // its surface, which made it the only button without a scale effect. The surface
            // stays: a white surface that darkens reads more clearly under the finger than a
            // scale effect alone.
            .scaleEffect(configuration.isPressed && !Theme.motionReduced ? 0.97 : 1)
            .animation(Theme.pressCurve(configuration.isPressed),
                       value: configuration.isPressed)
    }

    /// **White, everywhere.**
    ///
    /// For a while a different fill could be set here, for the Request button on
    /// Seerr, in accent. That is gone again: on a Seerr page the status already
    /// carries the accent, and a button in the same color next to it turns a signal
    /// for *state* into a base color.
    ///
    /// **the accent rule says exactly this:** the accent carries progress, selection and the
    /// Direct Play proof, never the base color of a button. The rule existed before
    /// the parameter did.
    private func area(pressed: Bool) -> Color {
        guard released else { return lockedArea }
        return Color.white.opacity(pressed ? 0.75 : 1)
    }
}

/// Secondary: muted surface, white text.
///
/// **The same height as the primary button.** It was two points shorter, and on
/// the movie page as on the sign-in page both stand directly on top of each
/// other, so the offset was visible. There was no reason for it; surface and font
/// size carry the difference, the height need not.
struct SecondaryButtonStyle: ButtonStyle {
    var stretches = true
    /// **The text in accent, the surface not.**
    ///
    /// For the second route to the same goal: Quick Connect sits below the sign-in
    /// button and is not a replacement for it but an offer. The accent on the text
    /// makes it visible without putting a second filled surface on the page; the
    /// one belongs to the primary button.
    ///
    /// Calculated: `accent` on `area` gives a contrast of 8.55:1.
    var accent = false
    /// The surface; one step up (`raised`) on a panel that is itself `area`.
    var area: Color = Theme.area
    /// Disabled means muted text, the same reasoning as on the primary button, and it
    /// was missing here entirely: "From start" looked usable while no plan existed,
    /// and did nothing.
    @Environment(\.isEnabled) private var released

    private var fontColor: Color {
        guard released else { return Theme.fontVeryQuiet }
        return accent ? Theme.accent : Theme.font
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(fontColor)
            .padding(.horizontal, stretches ? 0 : 22)
            .frame(maxWidth: stretches ? .infinity : nil, minHeight: 48)
            // **The press was invisible.** This used `Theme.erhoeht.opacity(1.6)`; opacity
            // above 1 clamps to 1.0, and `erhoeht` is opaque, so pressed looked pixel for
            // pixel like resting. Now a separate, lighter surface.
            .background(configuration.isPressed ? Theme.pressedArea : area,
                        in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            // And the same scale effect as on every other button: without it, the secondary
            // button was the only one that stood still on press.
            .scaleEffect(configuration.isPressed && !Theme.motionReduced ? 0.97 : 1)
            .animation(Theme.pressCurve(configuration.isPressed),
                       value: configuration.isPressed)
    }
}

// MARK: - Small parts



/// Thin progress bar at the bottom edge of a tile.
///
/// Measures itself instead of the surrounding frame. `containerRelativeFrame`
/// took the width of the nearest *container*; in a horizontal row that is the
/// whole row, not the tile. The bar then ran far beyond the tile and even pushed
/// the title down in the "Continue Watching" row. `GeometryReader` doesn't work
/// here either: it expands greedily. `onGeometryChange` measures without touching
/// the layout.
struct ProgressBar: View {
    let share: Double
    /// **Capsule where it stands free in a row**, as in the download list. On a tile
    /// it stays square: there it forms the edge of the image, and a rounded edge would
    /// sit in front of it.
    var round = false
    @State private var width: CGFloat = 0

    /// **Flush with the bottom edge, not floating.**
    ///
    /// It used to float: eight points of spacing, capsule shape. Feedback on device:
    /// it looked better at the bottom. A bar that forms the edge reads as part of the
    /// image; one that floats inside reads as a second thing on top of it.
    var body: some View {
        ZStack(alignment: .leading) {
            // **Light track, not dark.**
            //
            // It was light once, then dark, and the reason for that was "a light gray
            // disappears on light posters". That is true for a *gray*; white at 30 percent
            // does not disappear, it lies on top as a veil, and it is what Apple's TV app
            // shows on its cards. Feedback: "we had it light before too, that looked
            // better."
            //
            // The difference is not taste. Read as dark, the bar says "something is missing
            // here"; read as light, it says "this is how long the whole thing is, and this
            // is how far you are": the track is the length, not the remainder. And on a tile
            // that is itself framed dark, the dark track vanished into the edge.
            Rectangle().fill(Color.white.opacity(0.30))
            // The filled part is a capsule itself, otherwise it ends straight on the inside.
            (round ? AnyShape(Capsule()) : AnyShape(Rectangle()))
                .fill(Theme.accent)
                .frame(width: width * min(max(share, 0), 1))
        }
        .clipShape(round ? AnyShape(Capsule()) : AnyShape(Rectangle()))
        // Four points instead of three; at three it was barely visible on the tiles.
        .frame(height: 4)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// The same bar, but only if the setting allows it.
///
/// The setting is called "Progress on tiles" and means exactly that; the bar under
/// the play button on the series page is unaffected and therefore keeps using the
/// bare `ProgressBar`.
///
/// Having the check here and not in `Picture` is no subtlety: `@AppStorage` attaches
/// an observer to the defaults, and in `Picture` every tile got one; with a hundred
/// visible posters that is a hundred observers for a setting that never changes
/// while scrolling. Here only the few titles that have any progress get one.
struct TileProgress: View {
    let share: Double
    @AppStorage("fortschritt") private var showItem = true

    var body: some View {
        if showItem { ProgressBar(share: share) }
    }
}

/// Image at a fixed size.
///
/// Important: the size comes from the frame, the image only overlays it. If you
/// put `aspectRatio(.fill)` directly on the image instead, it becomes wider than
/// its frame; `clipped()` then clips the rendering but not the layout size, and
/// everything around it shifts.
struct Picture<Placeholder: View>: View {
    let url: URL?
    var width: CGFloat?
    var height: CGFloat?
    /// Instead of a fixed height: the height follows the width.
    ///
    /// Needed as soon as the tile fills its column instead of having a fixed size.
    /// Before, the poster grid computed the height from `tileWidth`; on iPhone
    /// that happened to be right because three columns are about 110 pt wide there.
    /// On iPad and Mac the columns are wider, the height stayed at 168, and the
    /// posters were squashed.
    var ratio: CGFloat?
    var corner: CGFloat = Theme.corner
    /// Progress at the bottom edge. Deliberately **here** and not as an overlay from
    /// outside: an overlay lies outside the mask, so the bar would stick out past the
    /// rounded corners with square ends.
    var progress: Double? = nil
    @ViewBuilder var placeholder: () -> Placeholder

    /// Profile → Appearance. See `EnvironmentValues.progressOnTiles`.
    @Environment(\.progressOnTiles) private var barShow

    /// **Loads via ``ImageCache``, not via `AsyncImage`.**
    ///
    /// This used `AsyncImage`, while `NetworkImage.swift` already held a loader that
    /// avoids exactly its three faults: it decodes off the main thread, remembers the
    /// result and downsamples to the required edge length. The users of it were the
    /// Mac, the download page and the profile icon, **but not the home page and the
    /// library**, the two surfaces that get scrolled and where fifty posters decode
    /// at the same time.
    ///
    /// Built and not connected, the same class as the two download rules. No test
    /// sees this: both loaders work.
    ///
    /// **The retry counter goes away**, and that is no loss. It counted
    /// `NSURLErrorCancelled`, the cancellation `AsyncImage` triggers itself as soon as
    /// its tile leaves the screen, only to remain in the error state afterwards. A
    /// bandage around somebody else's property. `ImageCache` fetches in a task of
    /// its own that doesn't hang on the tile; there is nothing to cancel and nothing
    /// to retry.
    @State private var loaded: Image?
    @State private var visible = false
    /// No image to be expected: no address, or the fetch came back without one. Only
    /// then does the caller's placeholder step in, not already during loading,
    /// otherwise it flashes briefly in front of every tile.
    @State private var withoutImage = false

    /// **Look up what is known once at creation, not on every draw.**
    ///
    /// The cache lookup used to sit in `body`. It looked harmless and wasn't:
    /// `ImageCache.image(_:)` first takes the address apart to remove the access
    /// token (`URLComponents`, filter, reassemble). In `body` that means on **every**
    /// pass, for **every** tile, on the main thread. A detail page draws many images
    /// and goes through several passes; this was work that took the track away from
    /// loading without ever contributing anything.
    ///
    /// So here, as `NetworkImage` has done from the start: ask once before drawing. A
    /// value supplied later would come one pass too late, and that one pass is the
    /// flash.
    @MainActor
    init(url: URL?, width: CGFloat? = nil, height: CGFloat? = nil,
         ratio: CGFloat? = nil, corner: CGFloat = Theme.corner,
         progress: Double? = nil,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.width = width
        self.height = height
        self.ratio = ratio
        self.corner = corner
        self.progress = progress
        self.placeholder = placeholder
        let immediate = url.flatMap { ImageCache.shared.image($0) }
        _loaded = State(initialValue: immediate)
        _visible = State(initialValue: immediate != nil)
        _withoutImage = State(initialValue: url == nil)
    }

    var body: some View {
        frameRect
            .overlay {
                if let loaded {
                    loaded.resizable().aspectRatio(contentMode: .fill)
                        .opacity(visible ? 1 : 0)
                } else if url != nil, !withoutImage {
                    // **No placeholder while loading.** The callers' placeholder is the film symbol
                    // and means "there is no image for this title". During the fetch that is simply
                    // wrong, and you could see it.
                    LoadField(corner: 0)
                } else {
                    placeholder()
                }
            }
            .task(id: url) {
                guard let url else { loaded = nil; withoutImage = true; return }
                withoutImage = false
                if let present = ImageCache.shared.image(url) {
                    loaded = present
                    visible = true
                    return
                }
                loaded = nil
                visible = false
                // **The tile knows its size, so it says so.**
                //
                // Without it every image is decoded at 1200 pt, twelve times the memory for a
                // poster 112 pt wide. The screen has at most three pixels per point; add a bit
                // so a poster doesn't fray on spring animations, and nobody needs more.
                //
                // Where no fixed width is available (in the grid the column sets it), it stays at
                // the full edge length.
                let needed = [width, height].compactMap { $0 }.max()
                    .map { Int($0 * 3.2) }
                guard let new = await ImageCache.shared.load(url, border: needed) else {
                    withoutImage = true
                    return
                }
                loaded = new
                withAnimation(Theme.reveal) { visible = true }
            }
            .overlay(alignment: .bottom) {
                // **Zero is not progress.**
                //
                // This was only `if let progress`. But for a title never started, Jellyfin
                // returns not `nil` but **0**, so the bar was drawn with width zero. As long as
                // its track was dark this hardly showed; since it became light (white 30 %), a
                // light stripe lies on every series not started. Feedback: "stripe also shows up
                // on series I haven't started."
                //
                // A bar says "this is how far you are". Whoever hasn't started has no position,
                // and then nothing belongs there.
                if let progress, progress > 0, barShow {
                    TileProgress(share: progress)
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }

    /// The surface everything is measured against.
    private var area: some View {
        Color.clear
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
    }

    /// **`aspectRatio` only when there is a ratio.**
    ///
    /// `aspectRatio(nil, contentMode: .fit)` doesn't mean "leave it" but "take the
    /// content's ratio", and the content here is a `Color.clear`, which has none.
    /// Where a width is set this doesn't show: the surface is fixed anyway. Where only
    /// a height is set, nothing is left for the width to hang on, and the surface
    /// collapsed to a strip at the left edge.
    ///
    /// That is exactly how `Heldbild` came about (height yes, width no, ratio no),
    /// and with it the image at the top of every detail page in the narrow layout. The
    /// ratio was added later from main, for the poster grid; callers without one were
    /// not considered.
    @ViewBuilder
    private var frameRect: some View {
        if let ratio {
            area.aspectRatio(ratio, contentMode: .fit)
        } else {
            area
        }
    }
}

extension Picture where Placeholder == Color {
    init(url: URL?, width: CGFloat? = nil, height: CGFloat? = nil,
         ratio: CGFloat? = nil, corner: CGFloat = Theme.corner,
         progress: Double? = nil) {
        self.init(url: url, width: width, height: height,
                  ratio: ratio, corner: corner,
                  progress: progress) {
            Theme.area
        }
    }
}

/// Own selection instead of `Menu` or `Picker`.
///
/// Apple's menu brings its own appearance: rounded glass, its own font, its own
/// spacing. Next to our flat, dark design it looks like a foreign body. This
/// selection belongs to us entirely: dimmed backdrop, flat surface, our font, our
/// accent.
struct SelectionSheet<Record: Identifiable>: View {
    @Binding var opened: Bool
    /// How tall the entries are together: measured, not assumed.
    @State private var contentHeight: CGFloat = 0
    let title: LocalizedStringKey
    let entries: [Record]
    let label: (Record) -> String
    let isSelected: (Record) -> Bool
    let select: (Record) -> Void
    /// **A heading before an entry**: separator line, heading below. In the title menu
    /// of Movies and Series, "Libraries" sits above the individual libraries, set off
    /// from "All" and "Collections", which are not libraries.
    var category: (Record) -> LocalizedStringKey? = { _ in nil }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .sheet(opened: $opened) {
                SheetCategory(text: Text(title))

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(entries) { entryRecord in
                            if let over = category(entryRecord) {
                                VStack(alignment: .leading, spacing: 0) {
                                    SeparatorLine()
                                    Text(over)
                                        .font(Theme.group)
                                        .tracking(Theme.lockGroup)
                                        .textCase(.uppercase)
                                        .foregroundStyle(Theme.fontVeryQuiet)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, Theme.edgeSpacing)
                                        .padding(.top, Theme.tileSpacing)
                                        .padding(.bottom, 4)
                                        .accessibilityAddTraits(.isHeader)
                                }
                            }
                            Button {
                                select(entryRecord)
                                opened = false
                            } label: {
                                // **The selection row, as in the player.**
                                //
                                // The checkmark sits on the **left** and is always there as space, even when it
                                // shows nothing. Otherwise all labels shift as soon as the choice changes.
                                //
                                // Selected means **full white and semibold**, not accent: the accent carries
                                // state, never ranking, and "this is the one" is ranking. The checkmark used to
                                // sit on the right in turquoise, and the row was 50 tall.
                                // **17, not 15, and 52 tall, not 40.**
                                //
                                // A sheet that comes from below is not a list excerpt within a page: it stands on
                                // its own, has only a few rows and all the room for them. At 15 on 40 they sat on
                                // top of each other like fine print. Feedback: "the spacing between rows is too
                                // small, the rows themselves are so thin, it looks squeezed."
                                //
                                // 17 is Apple's `body` (read out with `Werkzeuge/systemcolors.sh`) and the size
                                // every system menu uses here; 52 gives the row a good 17 pt of air above and
                                // below.
                                HStack(spacing: 14) {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(isSelected(entryRecord) ? Theme.font : .clear)
                                        .frame(width: 18)
                                        .accessibilityHidden(true)
                                    Text(label(entryRecord))
                                        .font(.system(size: 17,
                                                      weight: isSelected(entryRecord) ? .semibold : .regular))
                                        .foregroundStyle(isSelected(entryRecord) ? Theme.font
                                                                              : Theme.fontQuiet)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, Theme.edgeSpacing)
                                // `minHeight`: with a larger font the row must be allowed to grow, otherwise it
                                // clips.
                                .frame(minHeight: 52)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(Theme.PressRow())
                            // The checkmark is only an image; VoiceOver reports the selected state.
                            .accessibilityAddTraits(isSelected(entryRecord) ? .isSelected : [])
                        }
                    }
                    // Measured, not assumed; see below.
                    .onGeometryChange(for: CGFloat.self) { $0.size.height }
                        action: { contentHeight = $0 }
                }
                // **As tall as the entries, at most 340.**
                //
                // `.frame(maxHeight:)` alone is not enough: a `ScrollView` is vertically greedy
                // and takes the 340 even when four rows need only 204. What remained was an empty
                // space below the last row that does nothing.
                .frame(height: min(contentHeight, 340))
                .scrollIndicators(.hidden)

                SheetCancel { opened = false }
            }
    }
}

/// Own switch instead of `Toggle`.
///
/// Apple's switch brings its own dimensions, radius and animation, and looks like
/// a foreign body next to flat surfaces.
struct ToggleSwitch: View {
    @Binding var an: Bool
    /// **Disabled means muted, not translucent**.
    ///
    /// Both button styles knew the state long ago; `Schalter` and `Eingabefeld`
    /// didn't know it at all: a disabled switch stood there in full accent and looked
    /// usable. The mapping is the same as on the primary button: the filled surface
    /// falls back to `area`, the white on it to `schriftSehrLeise`.
    @Environment(\.isEnabled) private var operable

    var body: some View {
        Button {
            // The light tick that Apple's switch also gives.
            Theme.jerk(.lightweight)
            an.toggle()
        } label: {
            ZStack(alignment: an ? .trailing : .leading) {
                Capsule()
                    // Off: `rand`, not an opacity of its own. The same role as every resting border,
                    // so the same token.
                    .fill(an ? (operable ? Theme.accent : Theme.area) : Theme.margin)
                    .frame(width: 46, height: 28)
            // **The hit area fills the row instead of inflating it.**
            //
            // This used `.frame(height: 44)`, meant as a minimum target, and it was a fixed
            // height. As a result the switch made **every row with a switch 72 pt tall**,
            // while one without sits at 47: 44 plus twice 14 padding. That was visible in the
            // settings. Feedback: "why is that so huge? They can go back to how they were."
            //
            // `maxHeight: .infinity` takes whatever height the row has anyway and demands
            // nothing. A row with a subtitle is a good 60 tall, one without just under 50; in
            // both cases more than the 44 that mattered, and the row determines its own
            // height again.
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
                Circle()
                    .fill(operable ? (an ? Theme.reason : Color.white)
                                    : Theme.fontVeryQuiet)
                    .frame(width: 22, height: 22)
                    .padding(.horizontal, 3)
            }
        }
        // **`.plain` stays here, on purpose.** A switch responds through its knob, which
        // moves; Apple's switches don't shrink on press, and `PressButton` would shrink
        // the whole pill. The three other `.plain` uses in the app (the "x" in the search
        // field, the expanding description, the eye in the password field) had no
        // response and now have one.
        .buttonStyle(.plain)
        .animation(Theme.toggle, value: an)
        // Custom controls are initially just "button" to VoiceOver. `isToggle` says what
        // this is and also reads out the state.
        .accessibilityRepresentation {
            Toggle(isOn: $an) { Text("Ein") }
        }
    }
}

/// Heading above a group of rows.
///
/// **It existed twice.** Here with tracking 0.7 and `schriftSehrLeise`, in
/// `Einstellungsgruppe` with tracking 1.2 and its own "white 40 %": the same role,
/// two versions, visible side by side on the profile page and in settings. Now
/// one: the wider tracking, because uppercase at 11 pt otherwise crowds together,
/// and the **token** instead of the own number.
/// **A group as a surface of its own.**
///
/// The settings pages used to carry their rows edge to edge between two
/// hairlines. That is the app's older style and looked visibly older next to home
/// and detail; decided for the card because it delimits the group without empty
/// space and because it is the form known from the device.
///
/// **It is the one exception to "at most one filled surface per page".** A
/// settings page has no main thing, so the one filled button isn't missing here;
/// there is none at all. The rule protects the primary button's statement, and
/// where there is none, it protects nothing.
struct CardView<ContentBody: View>: View {
    @Environment(\.wide) private var wide
    @ViewBuilder var content: () -> ContentBody

    var body: some View {
        VStack(spacing: 0) { content() }
            // Card = 14, not 16: 16 belongs to surfaces of their own and the sheet
            // background, 14 to cards and groups. And `group` instead of `area`: a large
            // block carries the same tone lighter than a button; the reasoning is at the
            // token.
            .background(Theme.groupsArea,
                        in: RoundedRectangle(cornerRadius: Theme.cornerCard, style: .continuous))
            .padding(.horizontal, Theme.margin(wide: wide))
    }
}

/// **Normal case, not uppercase.**
///
/// It used to be 11 pt, in capitals, with +0.14 em tracking, the iOS 6 pattern
/// Apple hasn't used for years. In the TV app a group simply has "Automatic
/// Playback" above it: the same size as a row heading, in a muted tone, written
/// normally. Feedback with pictures from the TV app as direction.
///
/// The gain is not just fashion: uppercase is harder to read, needs tracking to
/// be legible at all, and VoiceOver spells it out depending on the word. And 11 pt
/// was the smallest size in the app, above a group whose rows carry 15; the
/// heading was quieter than what it heads.
struct GroupsTitle: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .font(Theme.rail)
            .tracking(Theme.lockRail)
            .foregroundStyle(Theme.fontQuiet)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.edgeSpacing)
            // 10 instead of 8: the size grew from 11 to 20, and a spacing that suited an
            // 11 pt line sticks under a 20.
            .padding(.bottom, 10)
    }
}

/// Heading plus the rows below it, framed top and bottom by a hairline.
///
/// It used to exist twice, in `SettingsView` and in
/// `PlaybackSettingsView`, character for character down to the comment on
/// `textCase`. The Mac side reported it when rebuilding: it had it as **one**
/// building block from the start.
///
/// No card, no outline: separation only by empty space and the small tracked
/// title.
struct SettingGroup<ContentBody: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: () -> ContentBody

    // `Style.swift` only goes into the iOS target; TV and Mac have their own
    // versions. Nothing can drift apart here; on iPhone `wide` stays false and
    // everything stays as it was.
    @Environment(\.wide) private var wide

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // **Not set again by hand.** That is exactly how the two headings drifted apart;
            // `Gruppentitel` brings size, weight, tracking, color and the bottom spacing
            // along.
            GroupsTitle(text: title)
                .padding(.horizontal, Theme.margin(wide: wide) - Theme.edgeSpacing)
                .padding(.top, 26)
                .padding(.bottom, 2)
            CardView { content() }
        }
    }
}

/// **The quiet line below a group or a page.**
///
/// It appeared three times almost identically: the version line in settings, the
/// same line in the profile, and the hint under the row list in the appearance
/// settings. Three places, one size, one color, each with its own note next to it
/// about why it is 12 and not 13.
///
/// **Scaling, not fixed**: it sits in settings, and those follow the
/// system font. Margin and spacing stay at the call site; one sits in a list, the
/// other in a stack.
struct Footer: View {
    let text: Text

    init(_ text: Text) { self.text = text }
    /// For fixed labels; `Text(verbatim:)` for everything that comes from the server
    /// or from the bundle.
    init(_ key: LocalizedStringKey) { self.text = Text(key) }

    var body: some View {
        text
            // 12 Regular is what the ladder says. There is no 13 Regular there; 13 is the
            // step below the poster and carries Medium.
            .growing(12)
            // White 30 percent would give 2.60:1, calculated, not estimated. For text 4.5:1
            // is the limit; `schriftSehrLeise` has 5.9:1.
            .foregroundStyle(Theme.fontVeryQuiet)
    }
}

/// Hairline between rows, indented on the left as in the design.
struct SeparatorLine: View {
    var body: some View {
        Rectangle().fill(Theme.line).frame(height: 1)
            .padding(.leading, Theme.edgeSpacing)
    }
}

/// **The way back from every subpage: a round button, not a bare arrow.**
///
/// It used to appear three times almost identically, in `SubpageHeader`,
/// `DetailHeader` and `PagesArrow`, and once even with two different hit areas. An
/// arrow is also the same arrow three times.
///
/// **No disc.** It briefly had one, modeled on Apple's TV app. Feedback came the
/// same day: the back button as such a fat button isn't so nice, it was nicer
/// when it was just a small thing.
///
/// The point behind it holds generally: we don't have to copy everything Apple
/// does; we have our own design and stay with it. From the TV app come the colors
/// and the shape of the corners, not the furniture.
///
/// The building block stays anyway: it existed three times almost identically,
/// once even with two different hit areas. 20 pt icon, 44 as target.
struct BackButton: View {
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            Image(systemName: "chevron.left")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.font)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        // **Without this, VoiceOver reads "chevron.left".** The way back from every
        // subpage: the spot where a missing label hits not one view but all of them.
        .accessibilityLabel(Text("Zurück"))
    }
}

/// Header of a subpage: arrow on the left, title left-aligned next to it. Not
/// Apple's centered title, no gray circle.
struct SubpageHeader<Right: View>: View {
    /// Carries the name of a library; it comes from the server and is therefore not
    /// translated.
    let title: String
    /// `nil` means: **this page is a root, not a path.**
    ///
    /// On iPad the watchlist is an area in the bar, and on iPhone a page that slides
    /// in from the right. The same header, two roles, and a back arrow on a root
    /// points nowhere.
    var back: (() -> Void)?
    /// **What stays free below the header.**
    ///
    /// It used to bring a fixed 18. If a value row sits below, the 18 adds to its own
    /// spacing: on the watchlist together 32, while library and downloads had 14. The
    /// same spot, three numbers. Whoever puts a row below passes 0 here and lets the
    /// spacing come from the stack.
    var bottom: CGFloat = 18
    @ViewBuilder var right: () -> Right
    @Environment(\.duoColumn) private var duoColumn

    var body: some View {
        HStack(spacing: 4) {
            if let back {
                BackButton(perform: back)
            } else {
                // Without an arrow the title starts where it would otherwise stand; otherwise it
                // would jump 44 pt to the left on the root, and the page would look different
                // from its neighbors.
                Color.clear.frame(width: 12, height: 44)
            }

            Text(title)
                .font(Theme.subpageTitle)
                .tracking(Theme.lockSubpage)
                .foregroundStyle(Theme.font)
                .lineLimit(1)

            Spacer(minLength: 0)
            right()
        }
        // **Eight, not twelve, and therefore without `BlurHeader`.** The same number
        // as in `PagesArrow`: with 8 the icon sits 30 pt from the edge, exactly where it
        // stands on every other subpage.
        //
        // Wrapping this header in `BlurHeader` adds its 18 pt margin on top: 48
        // instead of 30, and when switching between two pages the arrow visibly jumps.
        // It doesn't need that wrapper: it stands above the scroll area, not inside it,
        // so nothing runs underneath it.
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .padding(.top, duoColumn ? Theme.duoTop : 0)
        .padding(.bottom, bottom)
    }
}

extension SubpageHeader where Right == EmptyView {
    init(title: String, back: @escaping () -> Void) {
        self.init(title: title, back: back) { EmptyView() }
    }
}

/// Round button with label below: the action row on detail pages.
/// A secondary action on a detail page: watchlist, trailer, watched, more.
///
/// **Four fields, no circles.** It used to be four filled discs with a label
/// below, and with that the only circles in the whole app: otherwise there are
/// only rectangles with our corner and capsules. Of twelve streaming apps
/// checked, exactly one uses circles, and it places them **next to** the play
/// button instead of below.
///
/// The choice fell on Paramount+'s form: four equally wide fields, icons only, no
/// words. The price is known and accepted: four icons without labels have to be
/// learned. For speech output the label is kept; it just no longer appears in the
/// image.
///
/// **What is on carries the accent: the icon, not the surface.** A filled accent
/// disc would be the accent as a base color, and the accent rule forbids that.
struct ActionButton: View {
    @Environment(\.onImageTint) private var onImage
    let symbol: String
    /// No longer in the image, but in the speech output.
    let title: LocalizedStringKey
    var active: Bool = false
    /// Full width, or only as wide as necessary.
    ///
    /// Narrow, four fields share the row. Wide, the row stands next to the play
    /// button and must not squeeze it out.
    var stretches = true
    let action: () -> Void

    var body: some View {
        // A light tap for all buttons of the row, central instead of at the call sites:
        // they used to behave differently.
        Button {
            Theme.jerk(.lightweight)
            action()
        } label: {
            Image(systemName: symbol)
                // Icon button in the header: 17. 19 is on no scale.
                .font(Theme.categoryLarge)
                .foregroundStyle(active ? Theme.accent : Theme.font)
                .frame(maxWidth: stretches ? .infinity : nil)
                // 48, not 44: 44 is the hit area, 48 the dimension. And square when it stands
                // alone: a button without a label is square, the spec says.
                .frame(width: stretches ? nil : 48, height: 48)
                // **Surface without border.** With a border every field had an edge, and four
                // fields side by side formed a grid. Feedback: "better without". The surface
                // alone is enough: it says "you can press here" without drawing.
                .background(Theme.buttonArea(onImage: onImage),
                            in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}

/// Tab row with an accent line under the active entry.
struct PageTab: View {
    let title: [LocalizedStringKey]
    @Binding var selected: Int

    var body: some View {
        HStack(spacing: 26) {
            ForEach(Array(title.enumerated()), id: \.offset) { pair in
                let active = pair.offset == selected
                Button {
                    withAnimation(Theme.toggle) { selected = pair.offset }
                } label: {
                    Text(pair.element)
                        // **One weight.** `active ? .semibold : .regular` in a horizontal row shifts the
                        // neighbors to its right when switching, since semibold is wider. Which tab is
                        // open is told by tone and line, and neither changes a width.
                        .font(Theme.listTitle)
                        .foregroundStyle(active ? Theme.font : Theme.fontQuiet)
                        .padding(.bottom, 11)
                        .overlay(alignment: .bottom) {
                            // **White, not accent.** The accent carries state, never ranking, and "this tab
                            // is selected" is ranking. The line stays: it shows *which* one, and weight alone
                            // cannot do that on three words.
                            Rectangle()
                                .fill(active ? Theme.font : .clear)
                                .frame(height: 2)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(Theme.PressButton())
                // Which tab was open depended solely on the accent line and on the bold weight;
                // for VoiceOver all three were the same. Found on tvOS too: wherever a state
                // depends only on color, it is not spoken.
                .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.edgeSpacing)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }
}

/// Row in the file summary: label on the left, value on the right.
///
/// **No more `highlighted`.** The value was in accent, and the call site passed
/// it **unconditionally** for every audio track, so the accent was always on and
/// marked no state at all. A track name is a plain statement, and
/// the accent never carries a statement. For subtitles it depended on
/// `!subtitle.isEmpty`, i.e. on something the adjacent text already says.
struct FileRow: View {
    /// Video, audio, subtitles: fixed labels.
    let designation: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(designation)
                .foregroundStyle(Theme.fontQuiet)
            Spacer(minLength: 0)
            Text(value)
                .foregroundStyle(Theme.font)
                .multilineTextAlignment(.trailing)
        }
        // **Tabular.** The values stand right-aligned in five rows one below the other
        // and are resolutions, frame rates and bitrates, exactly the kind of column
        // The tabular rule is for. The size is `small` from the ladder, previously a literal.
        .font(Theme.small.monospacedDigit())
        // 8, at 12 pt font: 9 sat next to the ladder for no reason.
            .padding(.vertical, 8)
    }
}

/// Round portrait with name and role.
struct CastTile: View {
    let image: URL?
    let name: String
    let role: String?

    var body: some View {
        VStack(spacing: 7) {
            Picture(url: image, width: 76, height: 76, corner: 38)
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.font)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let role, !role.isEmpty {
                Text(role)
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontQuiet)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
            }
        }
        .frame(width: 84)
        // One element: name and role; the image adds nothing.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [name, role ?? ""].filter { !$0.isEmpty }
            .joined(separator: ", ")))
    }
}

/// Pill under which a list expands directly, modeled on Netflix. Not a sheet from
/// below: the decision stays at the place where it was triggered.
struct ExpandList<Record: Identifiable>: View {
    @Environment(\.onImageTint) private var onImage
    @Environment(\.imageColorSource) private var imageTint
    let label: String
    let entries: [Record]
    let text: (Record) -> String
    let isSelected: (Record) -> Bool
    let select: (Record) -> Void
    @Binding var opened: Bool
    /// In the player it takes the place of the meta line under the title; smaller
    /// there, otherwise the same choice.
    /// **15 semibold, not 13.** Netflix sets the season choice at the size of a list
    /// row, not of a detail; it is the switch that changes the whole list below, and
    /// 13 read like a footnote next to it. In the player it stays smaller: there it
    /// replaces the meta line.
    var font: Font = Theme.listTitle
    var height: CGFloat = 34
    /// **A field, not a bare heading.** In the player it sits between title and
    /// episodes and carries no surface there.
    var asField = true

    var body: some View {
        Button {
            if entries.count > 1 { withAnimation(Theme.leap) { opened.toggle() } }
        } label: {
            // **A quiet field, not a heading.**
            //
            // First it was a filled box at row-heading size, then a bare heading at 20,
            // which made it as loud as "Continue Watching" although it is only a filter.
            // Feedback: "Why is Season 1 so huge?"
            //
            // Now the quiet step in a surface: you can see it can be pressed, and it doesn't
            // shout. The same build on all devices; on the TV 26 / 60 and corner 14: the
            // corner there is `cornerSmall`, which keeps the iPhone ratio 8 to 34 at 60 pt
            // height instead of doubling with the font.
            HStack(spacing: 7) {
                Text(label)
                    .font(font)
                    .foregroundStyle(Theme.font)
                if entries.count > 1 {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.fontVeryQuiet)
                        .rotationEffect(.degrees(opened ? 180 : 0))
                }
            }
            .padding(.horizontal, asField ? 11 : 0)
            // The hit area stays, even without a surface beneath it.
            .frame(height: height)
            .background(asField ? Theme.buttonArea(onImage: onImage) : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
            .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .accessibilityHint(entries.count > 1 ? "Öffnet die Auswahl" : "")
        .buttonStyle(Theme.PressButton())
        .overlay(alignment: .topLeading) {
            if opened {
                VStack(spacing: 0) {
                    ForEach(entries) { entryRecord in
                        Button {
                            select(entryRecord)
                            withAnimation(Theme.leap) { opened = false }
                        } label: {
                            HStack(spacing: 12) {
                                // **Selected means white and weight, not color.** The accent carries state,
                                // never ranking, and "this is the one" is ranking. That is how it is in the
                                // player, and the player sets the tone.
                                // **The checkmark marks, the weight doesn't.**
                                //
                                // Selected used to be additionally in semibold. That is a second statement for
                                // the same thing, and semibold is wider, so the choice changed the width of the
                                // panel. Netflix sets only the checkmark.
                                //
                                // The column is 18 wide as in the selection sheet; 14 was the third checkmark
                                // width in the app.
                                Image(systemName: "checkmark")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(isSelected(entryRecord) ? Theme.font : .clear)
                                    .frame(width: 18)
                                    .accessibilityHidden(true)
                                Text(text(entryRecord))
                                    .font(Theme.listTitle)
                                    .foregroundStyle(isSelected(entryRecord) ? Theme.font
                                                                          : Theme.fontQuiet)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14)
                            // 9 instead of 12: with 12 every row became 43 tall, and with eight seasons the
                            // panel took half the screen. Netflix's rows are just over 30, the same number a
                            // selection row carries in a list.
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        // Rows in a selection are buttons and must respond to the press, not only to the
                        // choice.
                        .buttonStyle(Theme.PressRow())
                        // The checkmark is only an image; VoiceOver reports the selected state.
                        .accessibilityAddTraits(isSelected(entryRecord) ? .isSelected : [])
                    }
                }
                // **As wide as the longest name, not a fixed 200.**
                //
                // "Season 1" needs 140, "Specials" too, and 200 left a gap on the right that
                // looked like a bug. With a season with a long name it was truncated instead.
                // `fixedSize` takes what the text needs; the lower bound keeps narrow panels from
                // looking like a mistake.
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 180, alignment: .leading)
                // **The brand color, not a hand-typed one.** It used 0.090/0.090/0.102;
                // `Theme.area` is 0.086/0.086/0.098. The difference was invisible and for that
                // very reason dangerous: a color that should follow the brand but doesn't.
                // Corner `corner` (10), not `eckeFlaeche` (16): the panel is small and sits at a
                // button, not a surface of its own. At 16 it looked unfittingly round next to
                // its trigger (8).
                // **Over artwork in the page's color** (experiment `experiment-glas`): opaque,
                // because episodes sit below that would otherwise show through the list, but in
                // the tone of the page at this spot (the same net, `ImageTone.farbe`), with the
                // white of the other surfaces on top. A fixed gray stood there like a foreign
                // body.
                .background {
                    RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                        .fill(Theme.area)
                        .overlay {
                            if onImage, let imageTint {
                                ZStack {
                                    Theme.reason
                                    MoodLoader(url: imageTint) { tones in
                                        ImageTone.color(tones, at: SIMD2<Float>(0.2, 0.55))
                                    }
                                    Theme.surfaceTranslucent
                                }
                                .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                            }
                        }
                }
                // **No shadow.** Depth comes from surface brightness, not from drop shadows;
                // `erhoeht` already sits one step above the card beneath. The shadow was also the
                // only one in the entire iPhone version.
                .offset(y: height + 6)
                .zIndex(10)
                // **It grows out of its trigger.** Before, it appeared abruptly: no transition,
                // no origin. A list from nowhere leaves open what it belongs to; one that grows
                // out of the button answers that without a word. The anchor is top left because
                // that is where it hangs, and 0.94 instead of 0, since nothing in reality
                // appears from nothing.
                .transition(.scale(scale: 0.94, anchor: .topLeading)
                    .combined(with: .opacity))
            }
        }
    }
}

/// Spinning ring for waiting times.
///
/// Own building block instead of ProgressView: the system ring brings its own
/// stroke width and its own gray and stands out next to the other blocks. Here
/// accent color and thickness determine the look.
extension Theme {
    /// For everything that jumps: buttons like double tap.
    ///
    /// The motion itself is done by SF Symbols with '.bounce'. An own rotation angle
    /// was a mistake: it could only be added up, never taken back, and the buttons
    /// stayed crooked.
    /// Jump: 0.22 `snappy`. Under Reduce Motion a short fade instead of a jump, which
    /// is the point of the setting.
    static var leap: Animation {
        motionReduced ? fadeReduced : .snappy(duration: 0.22)
    }
    /// Switching between two states, such as play and pause.
    ///
    /// 0.10 `easeOut`, not `snappy`: a switch doesn't spring, it flips.
    static var toggle: Animation {
        motionReduced ? .linear(duration: 0.1) : .easeOut(duration: 0.1)
    }
}


/// Seek bar in the player: 4 pt bar, 6 pt with a handle while scrubbing.
///
/// Own building block instead of Slider. Apple's slider brings a large shadowed
/// handle and its own track height; next to the rest of the player that looks like
/// a foreign body, and the design shows a thin line. The handle area still stays
/// 28 pt tall so a thumb can hit it; only three points of it are visible.
struct TimeSlider: View {
    /// "1 hour, 12 minutes" instead of "1:12:30": VoiceOver reads colons as colons.
    ///
    /// **Via the formatter, not as a sentence of our own.** This used a fixed German
    /// text "\(stunden) Stunden \(minuten) Minuten": on an English device VoiceOver
    /// said "12 Minuten" and "1 Stunden". The formatter speaks the device's language
    /// and knows the singular.
    static func spoken(_ seconds: Double) -> String {
        let whole = Int(max(0, seconds))
        let f = DateComponentsFormatter()
        f.unitsStyle = .full
        f.allowedUnits = whole < 60 ? [.second] : [.hour, .minute]
        f.zeroFormattingBehavior = .dropLeading
        return f.string(from: TimeInterval(whole)) ?? ""
    }

    @Binding var value: Double
    let until: Double
    /// **Where the sections begin, in seconds.**
    ///
    /// The player has long loaded them, for the skip card and the countdown, and the
    /// slider knew nothing about it. A slider that shows the notches says at a glance
    /// how the film is built: where the intro ends, where the credits begin. Empty
    /// means "none known", and then the slider looks as before.
    var marks: [Double] = []
    /// **The file's chapters** (``Kapitelleiste/brauchbar(_:)``); they divide the
    /// slider into pieces. Empty: one piece, as before.
    var chapter: [Chapter] = []
    /// **How far the hit area extends beyond the slider** (upward, never downward):
    /// below the slider sits the home indicator, and whoever swipes up there wants to
    /// leave the app, not scrub.
    var hitTop: CGFloat = 0
    var onPush: (Bool) -> Void

    @State private var width: CGFloat = 0
    @State private var atPush = false
    /// Runs as long as a finger is down. If the system cancels the gesture (swipe to
    /// the home screen), it resets itself; `onEnded` doesn't come then.
    @GestureState private var touched = false
    /// Whether this touch was taken over as scrubbing. `nil`: still open.
    @State private var adopted: Bool?
    /// The notch the slider is currently snapped to, so that the tick fires once on
    /// snapping, not on every movement on it.
    @State private var inSnapped: Double?

    private var share: CGFloat {
        guard until > 0 else { return 0 }
        return min(max(CGFloat(value / until), 0), 1)
    }

    /// The section boundaries as a fraction, without those at the two edges.
    private var notches: [CGFloat] {
        guard until > 0 else { return [] }
        return marks.map { CGFloat($0 / until) }
            .filter { $0 > 0.01 && $0 < 0.99 }
    }

    /// Gap between two chapters: as wide as a notch.
    private static let gap: CGFloat = 2
    /// No piece gets narrower; a tighter cut is dropped
    /// (``Kapitelleiste/stuecke(grenzen:dauer:breite:mindestbreite:)``).
    private static let minWidth: CGFloat = 8

    private var pieces: [ChapterBar.Piece] {
        ChapterBar.pieces(limits: ChapterBar.limits(chapter, duration: until), duration: until,
                              width: Double(width), minWidth: Double(Self.minWidth))
    }

    /// **What the slider snaps to:** the notches of the sections and the cuts between
    /// chapters, but only those that are visible and only with room next to them
    /// (``Kapitelleiste/fangschnitte(_:dauer:breite:)``). Otherwise, with densely set
    /// chapters, it would only jump from one to the next.
    private func snapMarks(_ pieces: [ChapterBar.Piece]) -> [Double] {
        marks + ChapterBar.snapCuts(pieces, duration: until, width: Double(width))
    }

    /// For VoiceOver: position, length and, if there is one, the chapter.
    private var spokenValue: String {
        let spot = String(localized: "\(Self.spoken(value)) von \(Self.spoken(until))")
        guard let name = ChapterBar.chapter(at: value, in: chapter)?.name, !name.isEmpty
        else { return spot }
        return String(localized: "\(spot), \(name)")
    }

    private static let thickness: CGFloat = 4
    private static let thicknessRaised: CGFloat = 6

    /// **Track, bar and notches, at full height, without shape.** The corners, the
    /// gaps and how thick each piece is are given only by the mask.
    private var track: some View {
        ZStack(alignment: .leading) {
            // **White 18 %.** The player controls sit on pure black, so the track
            // carries a light tone and the bar above it the full white. The note about a
            // *dark* track that stood here belonged to the sheet handle and has been moved
            // back there; the track stays dark only where it lies over a poster, on the tile
            // bar.
            Rectangle().fill(Color.white.opacity(0.18))
            // At the thickness of the slider, not of the mask: otherwise the end of the bar
            // at rest would be a flat arc instead of a round one.
            Capsule().fill(.white)
                .frame(width: width * share, height: atPush ? Self.thicknessRaised : Self.thickness)

            // **Notches at the section boundaries.**
            //
            // Two points wide, in `reason`, so dark, since they lie both on the light track
            // and on the white bar and must be visible on both. A light line would have
            // vanished on the bar.
            //
            // The boundary at 0 and the one at the total length are dropped: one coincides
            // with the start, the other with the end, and a notch right at the edge reads as
            // fraying.
            ForEach(notches, id: \.self) { spot in
                Rectangle().fill(Theme.reason)
                    .frame(width: 2)
                    .offset(x: width * spot - 1)
            }
        }
        .frame(height: Self.thicknessRaised)
    }

    var body: some View {
        // **At rest only the line, while scrubbing a handle in accent color.** That is
        // how the player design has it: four points without a handle, six points and a
        // handle when touched; the only place in the player where the accent color
        // appears.
        //
        // **With chapters only the piece under the finger rises** to six points, the
        // others stay at four: while scrubbing you see which chapter you are in without
        // having to read the preview. Without chapters the whole bar is the one piece,
        // and everything stays as in the design.
        let grip: CGFloat = 18
        let pieces = pieces

        ZStack(alignment: .leading) {
            track
                // The shape comes from the mask: a capsule, or one piece per chapter.
                .mask(alignment: .leading) {
                    ChapterMask(pieces: pieces, width: width, gap: Self.gap,
                                 thickness: Self.thickness,
                                 elevated: atPush
                                     ? ChapterBar.piece(at: Double(share), in: pieces) : nil,
                                 thicknessRaised: Self.thicknessRaised, motion: Theme.toggle)
                }

            Circle().fill(Theme.accent).frame(width: grip, height: grip)
                .scaleEffect(atPush ? 1 : 0.4)
                .opacity(atPush ? 1 : 0)
                .offset(x: width * share - grip / 2)
        }
        .animation(Theme.toggle, value: atPush)
        // For VoiceOver a slider, not a nameless surface: `adjustableAction` also lets
        // the position be changed by swiping.
        .accessibilityElement()
        .accessibilityLabel("Abspielstelle")
        .accessibilityValue(spokenValue)
        .accessibilityAdjustableAction { bearing in
            let step = max(until / 20, 10)
            switch bearing {
            case .increment: value = min(until, value + step)
            case .decrement: value = max(0, value - step)
            @unknown default: break
            }
            onPush(false)
        }
        // 44 instead of 28: the bar is three points tall, yet it must be hit with a
        // thumb. Only the line stays visible.
        .frame(height: 44)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // **The hit area grows upward.** It hangs as a background at the bottom edge and
        // is `hitTop` taller than the slider.
        .background(alignment: .bottom) {
            Color.clear
                .frame(height: 44 + hitTop)
                .contentShape(Rectangle())
                .gesture(shove)
        }
        .onChange(of: touched) { _, now in
            // Cancelled by the system: clean up without jumping.
            if !now, atPush { complete() }
            if !now { adopted = nil }
        }
    }

    /// **Only a predominantly horizontal drag is taken over.**
    ///
    /// Until the finger has moved `decision` points, nothing happens. If it then
    /// moves more vertically than horizontally, the touch belongs to the system (home
    /// swipe, notifications) and the slider doesn't move. A tap without movement
    /// jumps to that position on release.
    private static let decision: CGFloat = 8

    private func pointSet(_ x: CGFloat) {
        guard width > 0 else { return }
        let raw = Double(min(max(x / width, 0), 1)) * until
        // **It snaps to the notches** (`NotchesSnap`): close enough to a section
        // boundary it stands exactly on it, with a light tick on snapping.
        if let notch = NotchesSnap.notch(value: raw, until: until, marks: snapMarks(pieces),
                                        width: Double(width)) {
            value = notch
            if inSnapped != notch {
                inSnapped = notch
                Theme.jerk(.lightweight)
            }
        } else {
            value = raw
            inSnapped = nil
        }
    }

    private func complete() {
        inSnapped = nil
        atPush = false
        onPush(false)
    }

    private var shove: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($touched) { _, condition, _ in condition = true }
            .onChanged { gesture in
                if adopted == nil {
                    let dx = abs(gesture.translation.width), dy = abs(gesture.translation.height)
                    guard max(dx, dy) >= Self.decision else { return }
                    adopted = dx > dy
                    guard adopted == true else { return }
                    atPush = true
                    onPush(true)
                }
                guard adopted == true else { return }
                pointSet(gesture.location.x)
            }
            .onEnded { gesture in
                defer { adopted = nil }
                if adopted == nil {
                    // Tap: barely moved, so jump.
                    atPush = true
                    onPush(true)
                    pointSet(gesture.location.x)
                    complete()
                } else if adopted == true {
                    complete()
                }
            }
    }
}

// MARK: - Navigation bar

/// The four areas at the bottom. Replaces the "Movies" and "Series" buttons that
/// used to be tiles on the home page.
enum Region: Int, CaseIterable, Identifiable {
    // **`downloads` comes last, although it is shown earlier.**
    //
    // The raw values are field indices: `MainView` keeps its page stacks as
    // `pfade[section.rawValue]`. If `downloads` were inserted between `seriesList` and
    // `search`, `search` would move from 3 to 4 and every stack would then sit under
    // the wrong area. Where it stands in the bar is determined by
    // ``sichtbare(downloads:)``, not by the order here.
    case start, movies, seriesList, search, downloads, watchlist
    var id: Int { rawValue }

    /// The bar, in its order. **** without the setting the download space does not
    /// exist at all.
    ///
    /// Downloads sits left of search, and search stays at the far right: it is the
    /// only one you can hit with your thumb half asleep, and it has been there since
    /// the first version.
    ///
    /// **The watchlist exists only in the wide layout.** Narrow, it hangs on the icon
    /// at the top right, next to the profile; at the bottom there would be six tabs,
    /// and the space there belongs to the four places you switch between constantly.
    /// Wide, the icon group doesn't exist, it lives in the bar; there the watchlist is
    /// a row like Movies and Series. Before, it stood there as a `NavigationLink` at
    /// the bottom among the destinations and did **nothing**, because the sidebar lies
    /// outside the `NavigationStack` and a link without a stack points nowhere.
    ///
    /// Switched off in Appearance, the watchlist is not in the bar at all.
    static func visibleOnes(downloads: Bool, wide: Bool = false, watchlist: Bool = true) -> [Region] {
        var list: [Region] = [.start, .movies, .seriesList]
        if wide, watchlist { list.append(.watchlist) }
        if downloads { list.append(.downloads) }
        list.append(.search)
        return list
    }

    var name: LocalizedStringKey {
        switch self {
        case .start:     "Start"
        case .movies:     "Filme"
        case .seriesList:    "Serien"
        case .search:     "Suche"
        case .downloads: "Downloads"
        case .watchlist: "Merkliste"
        }
    }

    var symbol: String {
        switch self {
        case .start:     "house"
        case .movies:     "film"
        case .seriesList:    "tv"
        case .search:     "magnifyingglass"
        // **The circle belongs to it.** A bare arrow between house, film, TV and
        // magnifier reads as a direction sign, not as a place.
        case .downloads: "arrow.down.circle"
        case .watchlist: "bookmark.fill"
        }
    }
}

/// An area in the bar: at the bottom on iPhone, on the left on iPad.
///
/// **One building block for both bars.** It used to exist twice, seventeen lines
/// verbatim, and the comment on `Seitenleiste` said it itself: "same icons, same
/// sizes, same accent". That is exactly how versions start to drift: whoever
/// changes the selection color changes one of two bars and sees the other only on
/// the other device.
///
/// Only two things differ, and both are parameters now: the sidebar gives a fixed
/// row height, and in it none of the four areas carries the selection while the
/// profile is open.
private struct SectionButton: View {
    let section: Region
    let active: Bool
    /// Fixed row height. The bottom bar gives none: there the four share the bar's
    /// own height.
    var height: CGFloat?
    /// How many downloads are currently running. `0` means: no badge.
    ///
    /// **The number of running ones, not of finished ones.** A badge that permanently
    /// says "12" is invisible after two days; one that appears and disappears says
    /// something.
    var runningCount: Int = 0
    /// Vertical bar on the Duo: symbols only, the name stays for VoiceOver.
    var iconOnly = false
    let select: () -> Void

    var body: some View {
        Button(action: select) { content }
            .buttonStyle(Theme.PressButton())
            .accessibilityLabel(Text(section.name))
            .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var content: some View {
        let kern = VStack(spacing: 4) {
            Image(systemName: section.symbol)
                .font(.system(size: iconOnly ? 25 : 20, weight: active ? .semibold : .regular))
                .overlay(alignment: .topTrailing) {
                    if runningCount > 0 {
                        Text(verbatim: runningCount.formatted())
                            // Badge: 10 semibold. 9 is on no scale.
                            .font(.system(size: 10, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.reason)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Theme.accent, in: Capsule())
                            // Offset outward: on the icon itself it covers the arrow, and then you can no
                            // longer see which tab it is.
                            .offset(x: 11, y: -7)
                            .accessibilityLabel(Text("\(runningCount) laden gerade"))
                    }
                }
            if !iconOnly {
                Text(section.name)
                    .font(.system(size: 10, weight: active ? .semibold : .medium))
            }
        }
        // **The one exception: here the accent carries the selection.**
        //
        // "Selected means white and weight" applies to everything except the bottom bar.
        // Apple's own apps color the selected tab there in the accent, without
        // exception: Music, Photos, App Store, Settings. That is not a matter of taste
        // but the place where every user sees an app's color for the first time. A bar
        // in white would not be more distinctive but more foreign; it would look like an
        // app that forgot its color.
        //
        // The tabs **within** a page (`Reiter`) stay with white and weight: there the
        // accent is not convention, and a second selection mark in the same color on the
        // same screen would be one too many.
        .foregroundStyle(active ? Theme.accent : Theme.fontVeryQuiet)
        .frame(maxWidth: .infinity)

        // Not `.frame(height: height)` with a `nil`: that inserts a frame layer even when
        // none is meant. Here the bottom bar should get exactly the tree it had before.
        if let height {
            kern.frame(height: height).contentShape(Rectangle())
        } else {
            kern.contentShape(Rectangle())
        }
    }
}

/// Own bar instead of `TabView`.
///
/// On iOS 26 Apple's bar brings its own glass material, plus its own height,
/// icon sizes and a selection color that can only be partly set. This one belongs
/// to us: blurred background in our tone, hairline on top, 22 pt icons.
struct NavBar: View {
    @Binding var selected: Region
    /// without the setting the fifth slot does not exist.
    var withDownloads = false
    var runningCount = 0

    var body: some View {
        // **Continuous, not floating: reverted.**
        //
        // It was a capsule with spacing to all three edges, modeled on Apple's TV app.
        // Feedback came immediately: "you made the nav bar kind of round, go back."
        //
        // The reason you don't see beforehand: Apple's capsule carries **five** entries
        // with short names and has air on left and right. Ours carries four to five with
        // "Downloads" and "Watchlist" in them, and inset by twice 16 points that becomes
        // squeezed columns. A form that results from air at Apple results in tightness
        // at ours.
        HStack(spacing: 0) {
            ForEach(Region.visibleOnes(downloads: withDownloads)) { section in
                SectionButton(section: section, active: section == selected,
                              runningCount: section == .downloads ? runningCount : 0) {
                    selected = section
                }
            }
        }
        .padding(.top, 9)
        .frame(height: Theme.stripHeight, alignment: .top)
        // The background must run to the bottom edge, not only to the safe area;
        // otherwise content keeps showing through below the bar, in the home-indicator
        // area.
        .background {
            // **Opaque, not glass.** "Almost opaque" meant 14 percent of the content showed
            // through, and on an area change you saw exactly that: tiles visibly sliding
            // through the bar.
            //
            // `Theme.reason` and not `area`: the bar should not be a surface of its own but
            // the ground the page ends on. The hairline above it is all it needs.
            Theme.reason.ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }
}

/// The destinations at the top right, the same on **every** root page, in the
/// same order, with the same spacing.
///
/// **They belong together, so they stand together.** Watchlist and profile used
/// to stand side by side on the home page and alone on Movies and Series; the
/// same corner of the screen offered different things on two pages.
///
/// `vorn` is the place for what only one page has: on the home page the offer
/// "continue watching here". It stands left of the rest because it comes and
/// goes; in between it would push the permanent destinations back and forth.
struct HeaderTargets<Front: View>: View {
    let name: String
    let image: URL?
    @ViewBuilder var front: () -> Front
    @Environment(\.watchlistShown) private var watchlistShown

    /// **The offer belongs to the group, not to the home page.**
    ///
    /// It used to be there only, with the reasoning that a tap on it starts playback
    /// and the player hangs off the home page. That was a reason from the build, not
    /// from use: whoever is on "Movies" while something plays in the living room
    /// wants to take it over just as much, and an icon that appears on only one of
    /// five pages looks like a mistake. The player therefore moved one level up, into
    /// ``MainView``.
    ///
    /// Optional so the block works without the environment: `nil` simply means "no
    /// offer".
    @Environment(TakeoverModel.self) private var takeover: TakeoverModel?
    /// Duo: heart, watchlist, profile and the offer live in the bar at the right edge.
    @Environment(\.duoColumn) private var duoColumn

    var body: some View {
        if duoColumn {
            // Keeps the row as tall as the profile picture was, so the page title stays
            // where it is on the other pages.
            HStack(spacing: 0) { front(); Color.clear.frame(width: 0, height: 44) }
        } else { row }
    }

    private var row: some View {
        HStack(spacing: 0) {
            // **Left of the permanent destinations**: it comes and goes and
            // would shift watchlist and profile if placed between them.
            // Together with "Watch Together": **one** badge, with a counter for both
            // (design A).
            front()

            // **The heart on every main page**, in the fixed header like watchlist and
            // profile. Gone for supporters. While something plays elsewhere (or a group
            // exists), the offer takes its place instead of squeezing in another icon.
            if OfferingBadge(takeover: takeover).count > 0 {
                OfferingBadge(takeover: takeover)
            } else {
                SupportHeart()
            }

            if watchlistShown {
                NavigationLink(value: WatchlistRoute()) {
                    // **Filled, not outlined.** A hollow bookmark at 20 pt is almost only contour. In
                    // the button row on detail pages, filled means "saved"; here it is not a state
                    // but a destination, and it stands alone there.
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.font)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(Theme.PressButton())
                .accessibilityLabel(Text("Merkliste"))
            }

            ProfileTarget(name: name, image: image)
        }
        .animation(Theme.leap, value: takeover?.offering?.id)
        .animation(Theme.leap, value: SharedModel.shared.offerings.map(\.id))
    }
}

extension HeaderTargets where Front == EmptyView {
    init(name: String, image: URL?) {
        self.init(name: name, image: image) { EmptyView() }
    }
}

/// The profile picture at the top right, in the same place on **every** root
/// page.

/// The profile picture at the top right, in the same place on **every** root
/// page.
///
/// **It existed twice and promptly drifted.** On the home page a hit area of
/// 44 pt came in with the watchlist, on Movies and Series it stayed the bare
/// circle of 30, so the same image sat in two places on two pages.
///
/// The 44 are right, but they extend 7 pt beyond the circle; without the
/// compensation the circle would sit 7 pt further in than the page margin. This
/// calculation belongs in **one** place.
struct ProfileTarget: View {
    let name: String
    let image: URL?

    var body: some View {
        NavigationLink(value: ProfileRoute()) {
            ProfileCharacter(name: name, image: image,
                          withoutImage: image.map { AccountSwitchTransition.shared.withoutImage.contains($0) } ?? false)
                // **One view per image address** (experiment `experiment-glas`): otherwise, on
                // an account switch, the old image stayed in the state until the fetch of the new
                // one was done, and on landing the old profile picture appeared briefly.
                .id(image)
                // While the new profile picture flies in here, there is none yet.
                .opacity(AccountSwitchTransition.shared.transition.map { $0.replaced } ?? true ? 1 : 0)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frameRect in
            AccountSwitchTransition.shared.targetReport(frameRect)
        }
        .padding(.trailing, -7)
    }
}

/// Where a tap on the area bar goes, or `nil` where there is none.
///
/// Via the environment and not as an argument: otherwise every root view would
/// have to pass the binding through, and the next one added would forget it.
private struct SectionSelectionKey: EnvironmentKey {
    static let defaultValue: Binding<Region>? = nil
}

/// Is this area the frontmost? Controls the pull-in on switching.
private struct SectionActiveKey: EnvironmentKey {
    static let defaultValue = true
}

/// Whether the downloads tab exists and how many are currently running.
///
/// **Via the environment for the same reason as ``bereichswahl``:** the bar is
/// created by three root views, and a fourth added later would forget to pass it
/// through. Both in one value because both concern the same bar and are always
/// set together.
struct DownloadBar: Equatable {
    var an = false
    var runningCount = 0
}

private struct DownloadBarKey: EnvironmentKey {
    static let defaultValue = DownloadBar()
}

/// **How often the already open tab was tapped again.**
///
/// A counter and not a switch: the page should react every time, not only the
/// first, and a switch would have to be reset by someone.
///
/// The path goes via ``bereichswahl``: the bar writes there even when nothing
/// changes, and ``MainView`` recognizes the second tap by that. Every other app
/// does it this way: the first tap takes you there, the second does something.
private struct TabStillTimesKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    var sectionSelection: Binding<Region>? {
        get { self[SectionSelectionKey.self] }
        set { self[SectionSelectionKey.self] = newValue }
    }

    var sectionActive: Bool {
        get { self[SectionActiveKey.self] }
        set { self[SectionActiveKey.self] = newValue }
    }

    var downloadBar: DownloadBar {
        get { self[DownloadBarKey.self] }
        set { self[DownloadBarKey.self] = newValue }
    }

    var tabStillTimes: Int {
        get { self[TabStillTimesKey.self] }
        set { self[TabStillTimesKey.self] = newValue }
    }
}

extension View {
    /// Attaches the area bar at the bottom to this view.
    ///
    /// **It belongs in the root view, not above the page stack.** It used to hang
    /// there, and two errors followed that looked like two and were one:
    ///
    /// **When navigating to a subpage it vanished abruptly.** It depended on "is the
    /// path empty" and was detached while the new page was still sliding in from the
    /// right. In the root, the stack pushes the new page over it by itself; there is
    /// nothing to detach.
    /// - **A sheet lay underneath.** A sheet hangs in the page, the bar sat one level
    /// higher. The detour via a bottom inset only hid it; the attempt to lift the page
    /// stack above it covered the bar with an opaque background, so it was gone
    /// instead of dimmed.
    ///
    /// In the root the order is right by itself: content, bar, sheet. That is why this
    /// call comes **before** a page's sheets.
    func sectionBar() -> some View {
        modifier(SectionBar())
    }

    /// Pulls this content in a notch when switching areas.
    ///
    /// **Belongs on the scroll area, not on the page.** It sat on the whole page
    /// body, and that carries the header at the top: on Movies and Series title and
    /// profile picture moved along, on the home page they didn't, where it happened
    /// to lie in the right place already. Two pages, two behaviors, on top of that.
    ///
    /// The header is a bar like the bottom one: it stays fixed, and the content moves
    /// beneath it.
    func areaContent() -> some View {
        modifier(SectionContent(underStatus: nil))
    }

    /// Like ``bereichsinhalt()``, only with a layer of its own **between background
    /// and content**.
    ///
    /// The background behind the scroll area is opaque. Whoever wants to show
    /// something behind it cannot get there otherwise and puts it on top at the end,
    /// and then it lies over text and posters too. The layer belongs to the
    /// background: the content scrolls over it.
    func areaContent<U: View>(@ViewBuilder underStatus: () -> U) -> some View {
        modifier(SectionContent(underStatus: AnyView(underStatus())))
    }

    /// **Only the pull-in, without a background of its own.**
    ///
    /// `areaContent()` puts an opaque surface behind the content so nothing is
    /// revealed at the edges while pulling in. An empty state, however, lies **over**
    /// the scroll area and thus over its header; an opaque surface would hide the
    /// header.
    ///
    /// It doesn't need it either: it sits in the middle and leaves the background at
    /// the edges anyway. All it lacked was the motion, and that is why the downloads
    /// page was the one that jumped hard into view on opening while Home, Movies and
    /// Series pull in. Feedback: "nobody will notice, but I notice."
    func sectionWithPull() -> some View {
        modifier(SectionWithPull())
    }
}

private struct SectionWithPull: ViewModifier {
    @Environment(\.sectionActive) private var active

    func body(content: Content) -> some View {
        content
            // Anchor at the top, as in `SectionContent`: anchored at the bottom it visibly
            // came up from below while the pages next to it pull in from above. Feedback:
            // "animates in wrong, somehow from below, that doesn't fit."
            .scaleEffect(active ? 1 : Theme.sectionMetric, anchor: .top)
            .opacity(active ? 1 : 0)
            .animation(Theme.sectionSwitch, value: active)
    }
}

private struct SectionContent: ViewModifier {
    @Environment(\.sectionActive) private var active
    let underStatus: AnyView?

    func body(content: Content) -> some View {
        content
            // **Anchored at the top, not at the bottom.**
            //
            // Center won't work: then both edges move. So the question is only which one
            // should stand still, and for a while the answer was the wrong one.
            //
            // Anchored at the bottom, the lower edge stands still and the **upper** one
            // moves. But the header gradient lies there, and at the top it is practically
            // opaque at 0.98: during the 0.2 seconds the bare background gapes beneath it
            // where posters otherwise run through. On the device that is exactly what you
            // see. Feedback: "with the gradient at the top there is a black area for a few
            // ms instead of the gradient."
            //
            // Anchored at the top, the edge below the header stands still. The lower one
            // moves instead, and there it has no consequence because the nav bar lies above
            // it: 54 pt of opaque background behind which those few points disappear. The
            // edge once thought to be the visible one is the covered one.
            .scaleEffect(active ? 1 : Theme.sectionMetric, anchor: .top)
            // **A fixed background behind the moving content.**
            //
            // As it pulls in, it frees something at all the edges, and what shows up there
            // no longer belongs to it. This background is the same tone and does not move
            // along; so there is nothing to free there.
            .background {
                ZStack(alignment: .top) {
                    Theme.reason.ignoresSafeArea()
                    if let underStatus { underStatus }
                }
            }
            .animation(Theme.sectionSwitch, value: active)
    }
}

private struct SectionBar: ViewModifier {
    @Environment(\.wide) private var wide
    @Environment(\.duoColumn) private var duoColumn
    @Environment(\.sectionSelection) private var choice
    @Environment(\.downloadBar) private var downloads

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if !wide, !duoColumn, let choice {
                NavBar(selected: choice, withDownloads: downloads.an,
                           runningCount: downloads.runningCount)
                    // **The full frame in front is not decoration.** The overlay measures itself
                    // against its host, and with the keyboard open the host has already shrunk: the
                    // bar then stood in the middle of the image, above the keyboard. Only the full
                    // frame plus ignoring the keyboard area hangs it on the **real** bottom edge
                    // again.
                    //
                    // On the search page that is exactly what is wanted: the keyboard lies over it,
                    // the bar stays underneath and is back as soon as the field closes.
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .ignoresSafeArea(.keyboard, edges: .bottom)
            }
        }
    }
}

/// The same bar, rotated by 90 degrees, for the wide layout.
///
/// **Not the top bar of the TV.** It sits at the top there because a remote
/// control is used and reachability doesn't matter. On a held iPad the top edge is
/// the worst spot. From the TV comes the composition of the pages, not the grip
/// height.
///
/// Same icons, same sizes, same accent, same glass as `NavBar`; only the
/// hairline sits on the right instead of the top.
///
/// Wordmark and profile icon move in here. On iPhone they sit in each page's
/// header; that costs nothing there because the header exists anyway. Side gain:
/// the profile is thus reachable from **all four** areas for the first time; in
/// search it was missing.
///
/// It does **not** retreat on subpages, unlike the bottom one on iPhone. There,
/// retreating gives back 54 pt of height; here it would give back 88 pt of width
/// and shift every poster. A horizontal jump disturbs more than a vertical one.
struct Sidebar: View {
    @Environment(\.windowButtons) private var windowButtons
    /// Optional, as in `HeaderTargets`: without the model in the environment there is
    /// simply no offer.
    @Environment(TakeoverModel.self) private var takeover: TakeoverModel?
    @Environment(\.downloadBar) private var downloads
    @Environment(\.watchlistShown) private var watchlistShown
    @Binding var selected: Region
    /// The profile page is open; then none of the four areas carries the selection,
    /// but the icon at the bottom does.
    var inProfile = false
    let name: String
    var image: URL?
    /// Duo: a narrow symbol column on the right edge, below the system's status
    /// column (clock, Wi-Fi), instead of the iPad bar on the left.
    var onRight = false
    let onProfile: () -> Void

    private var width: CGFloat { onRight ? Theme.duoBarWidth : Theme.sidebarWidth }

    var body: some View {
        VStack(spacing: 0) {
            if onRight {
                Color.clear.frame(height: Theme.duoStatusColumn)
            } else {
                Wordmark(height: 20)
                    .padding(.top, Theme.headerTop + (windowButtons ? WindowButtons.height : 0))
                    .padding(.bottom, 32)
            }

            ForEach(Region.visibleOnes(downloads: downloads.an, wide: true,
                                       watchlist: watchlistShown)) { section in
                SectionButton(section: section,
                              active: section == selected && !inProfile,
                              height: 64,
                              runningCount: section == .downloads ? downloads.runningCount : 0,
                              iconOnly: onRight) {
                    selected = section
                }
            }

            Spacer(minLength: 0)

            // **The watchlist used to be here and now sits at the top with the areas.** As a
            // `NavigationLink` it did nothing here: the sidebar lies outside the
            // `NavigationStack`, and a link without a stack points nowhere. That left only
            // the profile at the bottom, which is also more fitting, since the profile is not
            // a place in the app but who you are.

            // **"Continue watching here" above the profile.** On iPhone it sits in
            // `HeaderTargets`, left of the profile picture. Those don't exist in the wide layout
            // (profile and watchlist live in this bar), so when the offer moved into the
            // header destinations it dropped out entirely on iPad. Here it stands again with
            // what it belongs to: the same form as on iPhone, the same place as on Mac,
            // above the account.
            // On the Duo bar there is room for one of the two: the offer takes the
            // heart's place while it exists.
            let offered = OfferingBadge(takeover: takeover).count > 0
            if !onRight || offered {
                OfferingBadge(takeover: takeover, bottom: 12)
            }

            // **The heart of the home page header**, here because the wide layout has no
            // header; above the account, like the offer.
            if !(onRight && offered) {
                SupportHeart()
                    .padding(.bottom, 8)
            }

            Button(action: onProfile) {
                // **The account switch lands here** (design D, wide iPad): like ``Profilziel`` at
                // the top right on iPhone, one view per image address, and while the new image
                // flies in here, there is none yet.
                ProfileCharacter(name: name, image: image, highlighted: inProfile,
                              withoutImage: image.map { AccountSwitchTransition.shared.withoutImage.contains($0) } ?? false)
                    .id(image)
                    .opacity(AccountSwitchTransition.shared.transition.map { $0.replaced } ?? true ? 1 : 0)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frameRect in
                        // The image sits in the middle of the bar; its right edge lies half a bar width
                        // away.
                        AccountSwitchTransition.shared.targetInBarReport(
                            frameRect, size: 34, contentOff: frameRect.midX + (onRight ? -width : width) / 2)
                    }
            }
            .buttonStyle(Theme.PressButton())
            .padding(.bottom, 24)
        }

        .animation(Theme.leap, value: takeover?.offering?.id)
        .animation(Theme.leap, value: SharedModel.shared.offerings.map(\.id))
        .frame(width: width)
        // As below: the background must run to both edges, not only to the safe area.
        .background {
            // Opaque like the bottom bar on iPhone and like both headers: the same
            // reasoning, the same color.
            Theme.reason.ignoresSafeArea()
        }
        .overlay(alignment: onRight ? .leading : .trailing) {
            Rectangle().fill(Theme.line).frame(width: 1).ignoresSafeArea()
        }
    }
}

/// Blurred background that fades out softly downward.
///
/// **The mask must live in UIKit, not in SwiftUI.** A `UIVisualEffectView` blurs
/// what is *behind* it in the layer hierarchy. SwiftUI's `.mask` moves it into a
/// separate drawing layer, where there is no background any more, and only the
/// material's own color remains. That is exactly what was visible before: a gray
/// strip, but never blur.
///
/// As `layer.mask` on the same view the background is kept.
struct Blur: UIViewRepresentable {
    /// The thinnest material; any thicker one visibly brightens.
    ///
    /// It gets dark not through the choice of material but through the base tone on
    /// top. All materials carry a light layer, the thicker the more. `.dark` would be
    /// dark by itself, but has been deprecated since iOS 13 and does not draw at all
    /// with a layer mask.
    var style: UIBlurEffect.Style = .systemUltraThinMaterialDark
    /// Fraction of the height up to which the blur is at full strength. Below that it
    /// fades out. `nil` means: over the whole area, without a gradient.
    var fullUntil: CGFloat? = nil
    /// 0 to 1. Controlled via the **mask**, not via `.opacity`; the latter moves the
    /// view into a separate drawing layer, and then it has no background left to blur.
    var strength: Double = 1

    final class HostView: UIVisualEffectView {
        let history = CAGradientLayer()
        var withHistory = false

        override func layoutSubviews() {
            super.layoutSubviews()
            // Without this the mask stays at size zero and the whole view is invisible.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            history.frame = bounds
            CATransaction.commit()
        }
    }

    func makeUIView(context: Context) -> HostView {
        let viewRef = HostView(effect: UIBlurEffect(style: style))
        viewRef.isUserInteractionEnabled = false
        viewRef.history.startPoint = CGPoint(x: 0.5, y: 0)
        viewRef.history.endPoint = CGPoint(x: 0.5, y: 1)
        assign(viewRef)
        return viewRef
    }

    func updateUIView(_ viewRef: HostView, context: Context) { assign(viewRef) }

    private func assign(_ viewRef: HostView) {
        viewRef.effect = UIBlurEffect(style: style)
        let a = CGFloat(min(max(strength, 0), 1))

        guard let fullUntil else {
            // Without a gradient: the strength then sits in a uniform mask.
            viewRef.history.colors = [UIColor.black.withAlphaComponent(a).cgColor,
                                      UIColor.black.withAlphaComponent(a).cgColor]
            viewRef.history.locations = [0, 1]
            viewRef.layer.mask = a < 1 ? viewRef.history : nil
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        viewRef.history.colors = [UIColor.black.withAlphaComponent(a).cgColor,
                                  UIColor.black.withAlphaComponent(a).cgColor,
                                  UIColor.black.withAlphaComponent(a * 0.45).cgColor,
                                  UIColor.clear.cgColor]
        viewRef.history.locations = [0, NSNumber(value: Double(fullUntil)),
                                     NSNumber(value: Double((fullUntil + 1) / 2)), 1]
        viewRef.layer.mask = viewRef.history
        CATransaction.commit()
    }
}

/// A bar like in Apple's apps: uniformly blurred, with a hairline.
///
/// **No gradient.** It looked restless because the blur started to disappear at
/// half height and the edges of the letters behind it became sharp again. Apple's
/// bars are the same over their whole height and put a hairline at the bottom,
/// which reads as a surface, not as a veil.
/// **Currently nobody uses this, and that is on purpose.**
///
/// All three glass bars of the iPhone version were switched to an opaque surface:
/// the area bar at the bottom, the library header and the header of the detail
/// pages. The reason is documented at each one and is the same everywhere:
/// **Apple's materials all carry a light layer**, even the thinnest. Over our
/// background (#0B0B0D) and colorful posters it becomes a gray block, and it
/// flashes on spring animations because `Unschaerfe` controls its strength via a
/// mask that is recomputed per frame.
///
/// The block stays because it holds a measurement that would otherwise be done
/// twice (see `Unschaerfe`: `.dark` has been deprecated since iOS 13 and does not
/// draw at all with a layer mask). **Whoever reuses it should first check on the
/// device whether the bar is lighter than the page.**
struct BarGlass: View {
    var strength: Double = 1
    /// How much base tone plays in.
    var depth: Double = 0.5

    var body: some View {
        ZStack {
            Blur(strength: strength)
            Theme.reason.opacity(depth * strength)
        }
        .allowsHitTesting(false)
    }
}

/// Header that blurs when scrolling instead of cutting off hard.
///
/// Before, there was a black surface with a hard edge. The content now visibly
/// runs underneath.
struct BlurHeader<ContentBody: View>: View {
    @Environment(\.wide) private var wide
    @Environment(\.duoColumn) private var duoColumn
    @Environment(\.windowButtons) private var windowButtons
    /// How far the page has scrolled. **Only whoever passes it gets the hairline.**
    /// On the home page tiles run through and an edge is wrong there. In the library
    /// text runs through, and without an edge the transition looks like mush instead
    /// of a separation.
    var offset: CGFloat?
    /// How strong the gradient is, **only for the case without offset.**
    ///
    /// At rest there is no content beneath the header yet: the scroll area starts
    /// below it. So the gradient covers nothing there; it is pure decoration, and this
    /// design has none. Whoever passes a number here lets it come up only when
    /// something really runs underneath.
    var historyStrength: Double = 1
    /// A layer **above** `HeaderHistory` and **below** the header content.
    ///
    /// The order is the whole point: what is put in here is not covered by the
    /// gradient.
    var status: AnyView?
    @ViewBuilder var content: () -> ContentBody

    /// The same mechanics as in `DetailHeader`: over thirty points of travel the line is
    /// at full strength.
    private var border: Double {
        guard let offset else { return 0 }
        return Double(min(max(offset / 30, 0), 1))
    }

    var body: some View {
        content()
            .padding(.horizontal, Theme.margin(wide: wide))
            .padding(.top, (wide ? Theme.headerTop : 0)
                     + (duoColumn ? Theme.duoTop : 0)
                     + (windowButtons ? WindowButtons.height : 0))
            .padding(.bottom, 12)
            // **No hairline any more.** It was the bottom edge of the bar, and there is no
            // bar any more: the gradient fades out against pure black and has no edge that
            // would need hiding. A line over a gradient would be a second sign for the same
            // thing.
            .background {
                // **A gradient, not glass, and always the same one.**
                //
                // This used to be something different three times: glass with 0.62 base tone,
                // then a bare gradient, then glass with 0.28 plus a hairline, and on top of that
                // the case distinction "without offset a gradient, with offset a bar". Two
                // builds for the same spot, depending on whether the page carries tiles or text,
                // and on the device you see exactly that: the headers don't behave the same.
                //
                // Feedback, for the third time on this spot: "scrolling down at the top doesn't
                // look good, can we remove that again, so it doesn't become transparent."
                //
                // Of the two offered ways, surface plus line or gradient, the gradient is the
                // better one, for a reason you only see on black: `reason` is **pure black** as of
                // today, so the gradient fades out against the same color that lies below. There
                // is no edge where it ends, and so it needs no hairline to hide one. A surface
                // with a line, on the other hand, would have a visible cutoff edge over posters,
                // which is exactly what disturbs on the home page.
                //
                // One build, both kinds of page, no blur.
                HeaderHistory()
                    // Without offset the call site sets the strength (the home page lets it come up
                    // with the hero image); with offset it grows over the same 30 points over which
                    // the hairline used to come.
                    .opacity(offset == nil ? historyStrength : border)
                    .overlay(alignment: .bottom) { if let status { status } }
            }
    }
}

/// **The value row goes away when scrolling instead of scrolling along.**
///
/// "All" and "A-Z" sit under the page title and say how the list is currently
/// sorted. You want to know that **before** scrolling, not in the middle: whoever
/// is in the list has already decided. They stayed anyway because they sit in the
/// header, and took 44 points there permanently, which on an iPhone is half a tile
/// row. Feedback: "they don't need to be there anymore when you scroll down. That
/// would have solved many problems."
///
/// **Go away, not scroll away.** Scrolling along would mean pushing them under the
/// header, so two things run over each other, and the header would have to cover
/// them. Instead the row folds up in place: height and opacity go to zero
/// together, and the title above softly sinks to its final position. After that,
/// what stands at the top is exactly what stands at the top of every root page:
/// title, watchlist, profile.
///
/// **On the finger, not on a button press.** The value hangs directly on the
/// scroll offset, so the row opens and closes with the thumb and can be reversed
/// mid-motion. An animation of fixed duration would have a jump at the same spot.
///
/// The 44 are calculated: 30 pt pill height plus the 14 spacing above it, which
/// disappears with it. The row closes over exactly that distance, so it is gone
/// once you have scrolled as far as it was tall.
struct ValueRail<ContentBody: View>: View {
    /// How far it has scrolled. Zero at rest.
    let offset: CGFloat
    @ViewBuilder var content: () -> ContentBody

    /// Fully open at 1, fully closed at 0.
    private var opened: Double {
        1 - Double(min(max(offset / Theme.valueRailsDistance, 0), 1))
    }

    var body: some View {
        content()
            // **No more height change: it was an endless loop.**
            //
            // The row sat in the header, and the header is a safe-area inset of the scroll
            // area. If the inset changes its height, the inset changes; if the inset changes,
            // the area recomputes its geometry; that produces a new offset, which changes the
            // height. Scrolling down it runs through; scrolling up it tips over exactly at
            // the edge where the row opens again, and there the app stands still until the
            // system kills it. Feedback: "I scroll up again and always at the same spot,
            // bang, frozen frame."
            //
            // The row still fades out with scrolling; it no longer releases its space. That
            // is less than was planned, and it is what works without feedback. The space
            // would only be given back if the row moved into the scroll area instead of the
            // header; then it scrolls along, and that was exactly not wanted.
            .opacity(opened)
            // Otherwise the pills stick out at the bottom while collapsing.
            .clipped()
            // Half collapsed, nothing sensible can be hit anymore, and a sheet that opens
            // from a vanishing row is a trap.
            .allowsHitTesting(opened > 0.5)
            .accessibilityHidden(opened < 0.5)
            .padding(.top, 14)
    }
}

/// The gradient at the top edge of scrollable pages.
///
/// Strong at the top, soft at the bottom. With three stops the transition looked
/// like an edge: SwiftUI interpolates linearly between two values, and a straight
/// falloff reads as a kink. Seven points, unevenly spaced (wide at the start,
/// dense at the end) give the soft fade-out.
struct HeaderHistory: View {
    /// How far it extends below the header.
    ///
    /// Kept tight, and that is the point: the gradient should support the header, not
    /// tint the content below.
    ///
    /// Calculated for the tightest page, the home page. The header ends there at about
    /// 101 pt (safe area 59 + wordmark 30 + spacing 12), the first row, "Continue
    /// Watching", starts at 117. Between them lie 16 pt, and the fade-out just fits
    /// into those. With 60 it lay 44 pt above the row, with 88 it was 72; both visibly
    /// darkened the text.
    ///
    /// Whoever raises this must check the number against the home page's
    /// `contentMargins(.top:)`, which is the tightest in the project.
    ///
    /// **From 14 to 17.** "Really absolutely minimally deeper." The fade-out now
    /// reaches just up to the first row of the home page; nothing of it is visible
    /// there, since it is already below eight percent.
    var gift: CGFloat = 17

    /// **Stronger, but without a kink.**
    ///
    /// The first attempt simply multiplied the old values by 1.2 and clamped at the
    /// top at 0.98. That is exactly what produces the kink the paragraph above warns
    /// about: the clamp flattens the start, and whatever falloff is lost has to be
    /// carried by the next stretch; from -0.8 per unit it became -2.4.
    ///
    /// **Not the value counts but the slope.** Nine stops whose slope first increases
    /// and then decreases again: nowhere more than -2.2 per unit, which is less than
    /// in the old gradient. It is stronger anyway: at half height it covers 0.84
    /// instead of 0.80.
    var body: some View {
        LinearGradient(stops: [
            .init(color: Theme.reason.opacity(0.98), location: 0),
            .init(color: Theme.reason.opacity(0.94), location: 0.30),
            .init(color: Theme.reason.opacity(0.85), location: 0.48),
            .init(color: Theme.reason.opacity(0.70), location: 0.62),
            .init(color: Theme.reason.opacity(0.52), location: 0.73),
            .init(color: Theme.reason.opacity(0.34), location: 0.82),
            .init(color: Theme.reason.opacity(0.19), location: 0.89),
            .init(color: Theme.reason.opacity(0.09), location: 0.95),
            .init(color: Theme.reason.opacity(0),    location: 1),
        ], startPoint: .top, endPoint: .bottom)
        .padding(.bottom, -gift)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }
}


/// Search field in the house style. No `.searchable`, which brings system height,
/// system gray and system corners.
struct SearchField: View {
    @Binding var text: String
    var placeholder: LocalizedStringKey = "Filme, Serien, Folgen"
    /// Controlled from outside so a Cancel button can dismiss the keyboard.
    @FocusState.Binding var atTap: Bool
    /// What the keyboard's search key triggers.
    var submit: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17))
                .foregroundStyle(Theme.fontVeryQuiet)

            TextField("", text: $text, prompt: Text(placeholder)
                .foregroundColor(Theme.fontVeryQuiet))
                // Search field: body text, so 15.
                .font(.system(size: 15))
                .foregroundStyle(Theme.font)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($atTap)
                .onSubmit { submit?() }

            if !text.isEmpty {
                Button { text = "" } label: {
                    // **A filled circle again.** It once was one, became a bare cross ("with the four
                    // action circles the circle shape disappeared from the app"), and thereby stands
                    // as the only icon without a body in a field where everything else has a
                    // surface. Apple's search fields carry it filled without exception, from the home
                    // screen to the TV app, and that is not fashion: in a field currently holding
                    // text, a clear icon must be recognizable as a button and not as another
                    // character in the text.
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        // Two tones: cross in `area`, disc in `schriftSehrLeise`, so the cross reads
                        // as a cut-out and not as a stroke on top.
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Theme.area, Theme.fontVeryQuiet)
                        // **The icon stays 17, the target becomes 44.** It was the smallest hit area in
                        // the app, less than half of Apple's minimum. Nothing changes visibly; the edge
                        // extends into the field's right inner padding, where nothing lies anyway.
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                // **Response to the finger.** `.plain` means no reaction: 44 pt hit area, and
                // visibly nothing happened on press. Apple starts the feedback on touch-down, not
                // on release.
                .buttonStyle(Theme.PressButton())
                .accessibilityLabel("Eingabe löschen")
                // Otherwise the 44 target would push the field apart.
                .padding(.trailing, -13)
            }
        }
        .padding(.horizontal, 14)
        // **48 like every other field.** It was the only one at 44. The same role, the same dimension: a field is a field,
        // and next to a 48 Cancel button it sat four points too flat.
        // `minHeight`, so the field may grow with a larger system font instead of
        // clipping the row.
        .frame(minHeight: 48)
        // A search field is a filled capsule, not a drawn border: that is how it is on
        // the home screen, in the TV app and everywhere else. The border was the last
        // drawn edge in the app.
        .background(Theme.area, in: RoundedRectangle(cornerRadius: Theme.cornerField, style: .continuous))
    }
}

/// Description that stands on one line and expands on tap.
///
/// The full text was too heavy on the detail pages.
struct CollapsibleText: View {
    @Environment(\.onImageTint) private var onImage
    let text: String
    @State private var opened = false

    var body: some View {
        Button {
            withAnimation(Theme.leap) { opened.toggle() }
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Text(text)
                    .growing(15)
                    .lineSpacing(3)
                    .foregroundStyle(Theme.font)
                    .lineLimit(opened ? nil : 1)
                    .multilineTextAlignment(.leading)
                    // Without this, the one-line text reports the width of the *whole* sentence as
                    // its ideal size. The stack around it adapted to that, and on expanding the whole
                    // page jumped by a point or two in width.
                    .fixedSize(horizontal: false, vertical: true)
                    // **`minWidth: 0`: never wider than the space.** Without a lower bound a frame
                    // takes the width of its content if that is wider; a long paragraph that couldn't
                    // be wrapped pulled the whole page along when expanding.
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .rotationEffect(.degrees(opened ? 180 : 0))
                    .padding(.top, 4)
            }
            .contentShape(Rectangle())
        }
        // A row, not a button: `PressRow` colors the surface instead of shrinking the
        // paragraph. Before it was `.plain`, i.e. nothing at all.
        // **No surface over artwork color** (experiment `experiment-glas`): there a light
        // box appeared behind the text on press. The press then shows only in the text's
        // opacity.
        .buttonStyle(Theme.PressText(active: onImage))
        // VoiceOver reads the whole text anyway; the truncation is purely visual. So
        // only a hint of what the tap does is given here.
        .accessibilityLabel(text)
        .accessibilityHint(opened ? "Zuklappen" : "Aufklappen")
    }
}

/// Soft fade-out at the bottom edge of the hero image.
///
/// Before, the image met the dark surface below hard.
///
/// **From 130 to 190 points.** Title and subline sit about 70 points above the
/// bottom edge; at 130 only a good half of the coverage was there, and on light
/// posters the title stood almost bare on the image.
///
/// Higher **and** flatter: the start stays far below the old value so the gradient
/// doesn't eat half the image; it only begins earlier and reaches the text line
/// with more coverage.
struct HeroRunOut: View {
    /// **The header image whose color the fade-out takes on** (experiment
    /// `experiment-glas`). When set, it ends not in `reason` but in the mesh of the
    /// ``Stimmungsgrund``, exactly the crop that lies beneath at that spot. `nil`: as
    /// before.
    var image: URL? = nil
    /// Height of the header image, so the crop is right.
    var since: CGFloat = Theme.heroHeightValue

    private static let height: CGFloat = 190
    private static let coverage: [(Double, Double)] = [
        (0, 0), (0.28, 0.32), (0.58, 0.56), (0.85, 0.78), (1, 1),
    ]

    var body: some View {
        LinearGradient(stops: Self.coverage.map {
            .init(color: Theme.reason.opacity($0.0), location: $0.1)
        }, startPoint: .top, endPoint: .bottom)
        .overlay(alignment: .top) {
            if let image {
                // The same steps, only in the image's mesh: opaque at the bottom and thus exactly
                // the background below.
                MoodLoader(url: image) { tones in
                    MoodReason.network(tones, since: since)
                        .offset(y: -(since - Self.height))
                        .frame(height: Self.height, alignment: .top)
                        .clipped()
                        .mask {
                            LinearGradient(stops: Self.coverage.map {
                                .init(color: .black.opacity($0.0), location: $0.1)
                            }, startPoint: .top, endPoint: .bottom)
                        }
                }
            }
        }
        .frame(height: Self.height)
        .allowsHitTesting(false)
    }
}

/// The line under the play button: Direct Play, rating, age rating.
///
/// It used to sit above the button, together with year, runtime and genres in two
/// lines, which was overloaded. Year and runtime now sit in the hero image; only
/// what concerns playback stays here.
struct ProofRow: View {
    var directPlayFlag: Bool = false
    var hint: String?
    var rating: Double?
    var sharing: String?
    /// **A free proof instead of the playback plan.**
    ///
    /// Nobody knows how a title will play that the own server doesn't have at all; on
    /// the Seerr page the status stands at this spot instead. Before, the same line
    /// stood there a second time, with the same numbers: icon 11 semibold, word 13
    /// medium, spacing 6 and 8. If someone changes a size, two lines drift apart that
    /// should look the same side by side.
    var own: (symbol: String, word: String, color: Color)?

    var body: some View {
        // **8 between shells, not 14.** 14 dates from when only Direct Play carried a
        // shell and the rating stood bare next to it. Since all three marks have
        // surfaces, they stand like value pills and the fields of the action row: 8
        // apart.
        HStack(spacing: 8) {
            if let own {
                mark(own.symbol, Text(verbatim: own.word),
                      color: own.color, weight: .semibold)
            } else if directPlayFlag {
                // **Semibold, not `.heavy`.** Extra bold was a fourth weight besides Regular,
                // Medium and Semibold, and thus the only violation of "at most three weights"
                //. The icon is a checkmark at 11 pt; what makes it louder is the
                // accent color, not the weight.
                mark("checkmark", Text("Direct Play"),
                      color: Theme.accent, weight: .semibold)
            } else if let hint {
                mark("exclamationmark.triangle.fill", Text(hint),
                      color: Theme.warning, weight: .regular)
            }

            // In the same shell as Direct Play: before, the rating was the only item in the
            // row standing bare.
            if let rating {
                mark("star.fill",
                      Text(verbatim: String(format: "%.1f", rating).replacingOccurrences(of: ".", with: ",")),
                      color: Theme.fontQuiet, weight: .semibold)
            }

            // **Corner 8, not the default of 3.** The scale is 10/10/12/16 as of today, and a
            // mark with 3 sits right next to things with 10; it was the most angular element
            // on the page. Here and not at the building block: `Badge` is also used in the
            // Mac and TV targets, and those have their own scale.
            if let sharing { Badge(text: sharing, rounding: 8) }

            Spacer(minLength: 0)
        }
    }

    /// The shell in which all three proofs sit.
    ///
    /// **Why a mark and not loose text.** Before, icon and word stood bare on the
    /// background, and right next to them the age rating lay as an outlined badge: two
    /// different forms for two statements of equal weight. Now both carry the same
    /// corner and read as a pair; which kind of statement it is, the color says.
    ///
    /// **Fifteen percent, no fill.** The white play button stays the only filled
    /// object on the page. At this opacity the mark reads as a statement; from about a
    /// third it becomes a second button, which takes away the first one's message.
    ///
    /// **One shell, not three.** This is exactly how this row has drifted apart once
    /// before: the same numbers typed twice, and on the next touch only one half was
    /// right.
    private func mark(_ symbol: String, _ word: Text,
                       color: Color, weight: Font.Weight) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: weight))
            word.font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(color)
        // Narrower on the left than on the right: the icon is narrower than its glyph
        // cell, otherwise the word sits visibly off-center.
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
    }
}

/// Header of a detail page: back arrow that becomes a blurred bar with title when
/// scrolling.
///
/// Before, content ran unchecked under time and battery while scrolling, and the
/// arrow floated over the text for no reason.
struct DetailHeader: View {
    @Environment(\.windowButtons) private var windowButtons
    @Environment(\.duoColumn) private var duoColumn
    let title: String
    /// How far it has scrolled. From `since` the bar is at full strength.
    let offset: CGFloat
    var since: CGFloat = Theme.heroHeightValue - 150
    let back: () -> Void
    /// A button on the right, such as Edit. Without it, an empty field of 44 keeps the
    /// title centered between the edges.
    var right: AnyView? = nil

    private var strength: Double {
        guard since > 0 else { return 1 }
        return Double(min(max((offset - since) / 70, 0), 1))
    }

    var body: some View {
        HStack(spacing: 0) {
            // **44, not 40.** The same arrow existed with two hit areas: `SubpageHeader`
            // with 44, here and in `PagesArrow` with 40. You don't see the difference, you
            // hit it: 40 is below Apple's minimum. The icon stays at 20; nothing changes
            // visibly.
            BackButton(perform: back)

            // **The title comes when the hero image goes.**
            //
            // It was gone altogether for a while, with the reasoning "the same statement
            // twice, and one of them in motion". That holds for the page header, where the
            // large title **stays**; on a detail page it scrolls away, though, and then you
            // are in an episode list without knowing which series it belongs to. Feedback:
            // "the name of the series should be at the top, it's gone now, that's a
            // regression."
            //
            // Nor is it a double statement: it fades in only once the large title has left
            // the top of the screen, so the two are never visible together. The same strength
            // as the bar behind it, so carrier and content arrive together.
            Text(verbatim: title)
                .font(Theme.categoryLarge)
                .tracking(Theme.lockCategory)
                .foregroundStyle(Theme.font)
                .lineLimit(1)
                .opacity(strength)
                .padding(.horizontal, 4)
                .accessibilityHidden(true)

            Spacer(minLength: 0)

            // So the title is centered to the arrow and doesn't stick to its left: the same
            // space on the right that the arrow takes on the left.
            if let right { right } else { Color.clear.frame(width: 44, height: 1) }
        }
        // 8 as in the subpage header: with 6 the arrow sat 28 from the edge on detail
        // pages and 30 on subpages, a jump of two points when navigating.
        .padding(.leading, 8)
        .padding(.trailing, Theme.edgeSpacing)
        .padding(.top, (windowButtons ? WindowButtons.height : 0) + (duoColumn ? Theme.duoTop : 0))
        .padding(.bottom, 6)
        .background(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1).opacity(strength)
        }
        .background {
            ZStack {
                // **At rest a gradient, when scrolling glass.**
                //
                // On the root pages the blur is gone: tiles run through there, and a gradient
                // against pure black ends without an edge. Here the situation differs, and so
                // does the answer: the bar carries a **title**, and episode images and text run
                // through underneath it. Something that has to keep text readable over text needs
                // more than a gradient. Feedback: "on the detail pages I would make the glass
                // element come in at the top when scrolling down, I found that more sensible
                // there."
                //
                // As long as the hero image is at the top, only the gradient: it keeps the way
                // back readable on a light image without claiming a bar that doesn't exist yet.
                HeaderHistory().opacity(0.7 * (1 - strength))
                // `BarGlass` and not `.ultraThinMaterial`: the material inside a SwiftUI
                // `background` blurs nothing because it sits in a layer of its own; only its own
                // color remains, a gray strip. The measurement is documented at `BarGlass`.
                BarGlass(strength: strength, depth: 0.28)
            }
            .ignoresSafeArea(edges: .top)
        }
    }
}

/// Row that can be pulled to the left, revealing an action.
///
/// **No drag gesture of our own.** Letting two gestures fight over the same
/// movement doesn't end cleanly: with `.gesture` the list lost vertical
/// scrolling, with `.simultaneousGesture` the finger stuck on the rows. UIKit has
/// always made the decision whether a movement is meant horizontally or
/// vertically itself; you just have to pose the question.
///
/// So every row is a horizontal scroll area with two fields: the content at full
/// width and the action next to it. Vertical scrolling still belongs to the list,
/// snapping is handled by `scrollTargetBehavior`, and the bounce comes for free.
///
/// `.swipeActions` would be the shorter way but exists only in `List`, and the
/// episode list sits in the middle of a running page on the series page.
struct SwipeRow<ContentBody: View>: View {
    let symbol: String
    let label: LocalizedStringKey
    var color: Color = Theme.accent
    let action: () -> Void
    let onTap: () -> Void
    @ViewBuilder var content: () -> ContentBody

    private enum Field: Hashable { case content, action }
    @State private var visible: Field? = .content
    @State private var range: CGFloat = 0
    @State private var triggered = false
    /// Counts up to rebuild the scroll area.
    @State private var run = 0

    private let width: CGFloat = 96
    /// From here the pull triggers by itself, without hitting the button.
    private let threshold: CGFloat = 168

    /// Perform the action and close the row again.
    private func fire() {
        triggered = true
        // Destructive actions get the stronger tap.
        Theme.jerk(color == Theme.error ? .medium : .lightweight)
        action()
        // Rebuild the scroll area instead of resetting it.
        //
        // Via `scrollPosition` it wouldn't close: it finishes setting its own position
        // during release and overwrites the set value, even a beat later. A fresh area
        // always starts at zero. The price is that it snaps shut instead of sliding; as
        // the row switches its checkmark at the same moment, that goes unnoticed.
        run += 1
        visible = .content
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                // **A button, not a tap gesture.** Only so there is a pressed state; the swipe
                // area is unaffected, because SwiftUI releases a button inside a scroll area by
                // itself when dragging.
                Button { onTap() } label: {
                    content()
                        .containerRelativeFrame(.horizontal)
                        // Opaque only while being pulled: then the action color lies underneath and must
                        // not show through. When closed the row is transparent; a fixed background would
                        // otherwise draw a hard edge at the first episode over artwork color
                        // (experiment `experiment-glas`).
                        .background(range > 0.5 ? Theme.reason : .clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(Theme.PressRow())
                // The action behind the swipe as an action of the row: with VoiceOver you swipe
                // up or down and select it, instead of having to look for a button outside the
                // image.
                .accessibilityAction(named: Text(label)) { action() }
                    #if os(iOS)
                    // Must sit **in** the content, not as the background of the scroll area: from
                    // there the helper view doesn't find it at all when walking up the hierarchy.
                    .overlay(alignment: .topLeading) {
                        EdgeGesturePreRank().frame(width: 0, height: 0)
                    }
                    #endif
                    .id(Field.content)

                Button { fire() } label: {
                    VStack(spacing: 4) {
                        // Icon of a page arrow: 17, the next step on the ladder. Before 18.
                        Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                        Text(label).font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Theme.reason)
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                }
                .buttonStyle(Theme.PressButton())
                .accessibilityHidden(true)
                .id(Field.action)
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, new in
            range = new
            // Pulled far enough: trigger without hitting the button.
            if new > threshold, !triggered { fire() }
            if new <= 1 { triggered = false }
        }
        // The action color lies under the whole row, not only under the button. Pulling
        // beyond the stop, it fills along instead of exposing an edge; iOS does it the
        // same way.
        //
        // Only when actually pulling: otherwise it flashes briefly while the list is
        // built, for instance when switching between tabs.
        .background(range > 0.5 ? color : .clear)
        // Snaps either fully shut or fully open; nothing stays half open.
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $visible, anchor: .leading)
        .id(run)
    }
}

/// Back arrow at the top left on subpages without their own header.
///
/// Own building block because otherwise it gets a different height on every page;
/// exactly that was visible between profile and Quick Connect.
struct PagesArrow: View {
    @Environment(\.windowButtons) private var windowButtons
    let back: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                BackButton(perform: back)
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            .padding(.top, 6 + (windowButtons ? WindowButtons.height : 0))
            // The gradient hangs here because all subpages get it through the arrow;
            // otherwise content there would scroll hard under the status bar while fading
            // out softly on the other pages.
            .background { HeaderHistory() }
            Spacer(minLength: 0)
        }
    }
}

/// A row on the profile page: icon, text, arrow, hairline below.
///
/// The line starts only after the icon, so the group reads as belonging together
/// instead of falling apart into equally wide strips.
struct ProfileRow<Destination: Hashable>: View {
    @Environment(\.wide) private var wide
    let symbol: String
    let title: LocalizedStringKey
    var under: LocalizedStringKey?
    /// The whole row in accent, for a warning action.
    var accent = false
    /// **Only the icon in accent.**
    ///
    /// For the one row on a page that *does* something while all others lead on or
    /// display. The icon carries the color, the title stays white: the row stands out
    /// without claiming a ranking among siblings.
    var characterAccent = false
    var last = false
    /// If the row leads on, it carries a destination; otherwise an action on the spot.
    var target: Destination?
    var action: () -> Void = {}

    var body: some View {
        Group {
            if let target {
                NavigationLink(value: target) { shell }
            } else {
                Button(action: action) { shell }
            }
        }
        .buttonStyle(Theme.PressButton())
    }

    private var shell: some View {
        VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: symbol)
                        .font(.system(size: 17))
                        .foregroundStyle(characterAccent ? Theme.accent
                                                       : (accent ? Theme.accent : Theme.font))
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(Theme.listTitle)
                        if let under {
                            Text(under)
                                .font(Theme.small)
                                .foregroundStyle(Theme.fontVeryQuiet)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.fontVeryQuiet)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(accent ? Theme.accent : Theme.font)
                .padding(.horizontal, Theme.margin(wide: wide))
                // 14, not 15: the same number as in every other list row, and 15 sits next to the
                // grid.
                .padding(.vertical, 14)

            if !last {
                SheetLine()
            }
        }
        .contentShape(Rectangle())
    }
}

extension ProfileRow where Destination == Never {
    init(symbol: String, title: LocalizedStringKey, under: LocalizedStringKey? = nil,
         accent: Bool = false, last: Bool = false,
         action: @escaping () -> Void) {
        self.init(symbol: symbol, title: title, under: under, accent: accent,
                  last: last, target: nil, action: action)
    }
}

/// Hero image that grows on overscroll instead of slipping away.
///
/// The top edge stays attached to the top of the screen; only the bottom edge is
/// pulled down. On release it springs back.
///
/// **Not via the scroll offset in state:** it arrives one frame too late, and that
/// one frame was the hard edge that flashed at the top.
///
/// **And no longer with `GeometryReader`.** It rebuilt `Picture` on every frame of
/// scrolling, including the image-cache lookup, just to pass on one number.
/// `visualEffect` gets the same position in the same pass but computes only when
/// drawing: the image is scaled up from the bottom edge, which with `.fill` is
/// exactly what the taller frame height showed before.
struct HeroImage: View {
    let url: URL?
    var height: CGFloat = Theme.heroHeightValue
    var space: String = "blatt"

    var body: some View {
        Picture(url: url, height: height, corner: 0)
            .visualEffect { [height, space] content, status in
                let stretch = max(0, status.frame(in: .named(space)).minY)
                let mass = (height + stretch) / max(height, 1)
                return content.scaleEffect(mass, anchor: .bottom)
            }
    }
}

/// **A pill that shows its value and opens a sheet.**
///
/// The difference to `SelectionChip` is the question it answers: the chip is *one
/// possibility among several open ones* and lights up when it applies; the pill is
/// *the applicable value itself*. A row of chips reads as an expanded menu someone
/// left open; a row of pills as a toolbar. That is what caused the unfinished
/// impression.
///
/// It had existed once before as a build, in the middle of the library page, only
/// for sorting. With the second need it would have stood there twice.
struct ValuePill: View {
    let symbol: String
    let text: String
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.fontQuiet)
                    .accessibilityHidden(true)
                Text(verbatim: text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.font)
            }
            .padding(.horizontal, 11)
            // `minHeight`: the pill carries text, and a fixed height clips it as soon as the
            // system font grows.
            .frame(minHeight: 30)
            // **Fill without border.** They were the only buttons in the app with an outline
            // and therefore looked like a foreign kind. Feedback on "All" and "A-Z": "they
            // look so different, they have this outline that nothing else has." The surface
            // alone says "you can press here"; the border says the same a second time and
            // draws an edge no other button has.
            .background(Theme.area, in: Capsule())
        }
        .buttonStyle(Theme.PressButton())
    }
}

/// How many titles are in this library.
///
/// **A statement, not an action**, so quiet text and no box. Plex sets it as a
/// filled capsule; there it is a button. It answers "am I through here?", and
/// without it you scroll into uncertainty.
struct CountMark: View {
    let count: Int

    var body: some View {
        Text(verbatim: count.formatted())
            .font(.system(size: 13, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Theme.fontVeryQuiet)
            .accessibilityLabel(Text("\(count) Titel"))
    }
}

/// Selection chip: one possibility out of a few, without a list.
///
/// For filters and short value ranges. A list would be more effort than benefit
/// here, since you see everything at once anyway.
struct SelectionChip: View {
    let text: String
    /// An icon before the word: the funnel at the selected sort value, as on the Mac.
    /// `nil` means: only the word.
    var symbol: String?
    let an: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // **Selected is white, not accent.**
            //
            // It used to be the accent, which made the same chip row look different on iPad
            // than on Mac, where it is white. It also fits the rule better: the accent
            // carries state, and "this filter currently applies" is a selection. On the TV it
            // was changed for the same reason.
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(text)
                    // **One weight, not two.**
                    //
                    // This used `an ? .semibold : .regular`. Semibold is wider than Regular, and the
                    // chips stand **side by side horizontally**: when switching, every neighbor to
                    // its right shifted. With the accent that didn't happen, since color changes no
                    // width. 13 Medium is the step in between, and it applies in both states.
                    .font(.system(size: 13, weight: .medium))
            }
                .foregroundStyle(an ? Theme.font : Theme.fontQuiet)
                .padding(.horizontal, 13)
                // `minHeight`: a fixed height plus text is the trap that already struck at
                // `Schalter`.
                .frame(minHeight: 30)
                // **No second primary button.**
                //
                // Selected used `Theme.font` as surface with `reason` as text: character for
                // character the primary button, and on the library page several chips stand
                // there, so several fully filled objects. Only one is allowed. When the
                // accent was removed, the inversion was chosen instead of the rule.
                //
                // Now the choice carries three quiet signs at once (surface `selected`, full
                // border, full text), and none of them changes a dimension.
                // **Two fills instead of fill and border.**
                //
                // Selected used to carry a full white border, which made the chip the only button
                // in the app with a drawn edge. `selected` (white at 8 percent) also came out
                // **darker** than `area` on the page: the choice made the chip darker instead
                // of lighter, exactly backwards.
                //
                // Now one step up the ladder and full text: two signs that both go in the right
                // direction, and none changes a dimension.
                .background(an ? Theme.raised : Theme.area, in: Capsule())
        }
        .buttonStyle(Theme.PressButton())
        .accessibilityLabel(text)
        .accessibilityAddTraits(an ? [.isButton, .isSelected] : .isButton)
    }
}

/// **A sheet from below: ours, recalculated with Apple's physics.**
///
/// Three attempts, and the third is the one that stays. In order, since each
/// attempt contributed something:
///
/// 1. **Self-built, without sliding up.** `.transition(.move)` left the background
/// in the safe zone on closing; a strip remained under the sheet. 2. **Self-built,
/// with a measured card.** The strip was gone and the slide-up was there, but it
/// rightly felt wrong: everything that makes a motion smooth was missing, rubber
/// band, throw velocity, a spring that takes over the finger's momentum.
/// 3. **Apple's `sheet`.** That solved it but brought **iOS 26** along: there a
/// sheet with a partial height floats, with margin left and right and spacing at
/// the bottom; it goes to the edge only at full height. Checked, not guessed:
/// **there is no API against it.**
///
/// So ours again, but this time with what was missing in attempt 2, and that is
/// computable and no feeling:
///
/// - **Rubber band upward.** Upward there is nothing to see, so it may hardly
/// move, but it must move *something*, otherwise the finger feels like it is on
/// concrete. The same formula as `UIScrollView`.
/// - **The momentum goes into the spring.** `DragGesture` provides `velocity`
/// since iOS 17; the velocity at release is converted to the remaining distance
/// and passed as `initialVelocity`. That is the whole difference between "snaps
/// back" and "glides back".
/// - **A fast swipe closes, even if short.** Above 700 points per second a
/// centimeter is enough.
/// - **The threshold depends on the sheet height**, not on a fixed number: a sheet
/// with three rows must not demand the same distance as one with twelve.
struct SheetModifier<SheetContent: View>: ViewModifier {
    @Binding var opened: Bool
    /// `false`: no scrim and no tap-to-close, the page behind stays visible and reachable
    /// outside the card (the looks panel, which shows the page in the look being tried).
    var dimmed = true
    /// A tone of light at the top of the card, drawn on the whole card (handle strip
    /// included) and clipped to its rounded corners, so it fades out without an edge.
    var light: Color?
    /// A faint second tone mixed into `light` (the look's mark gradient); `nil` is one tone.
    var lightTint: Color?
    @ViewBuilder var sheetContent: () -> SheetContent

    /// How tall the card is: determines how far it travels out, how much the rubber
    /// band gives, and when a pull is enough to close. **Measured, not assumed.**
    @State private var cardsHeight: CGFloat = 400
    /// How far the finger has currently displaced it.
    @State private var pull: CGFloat = 0

    /// **Opening is one frame later than `opened`.** A step that changes the sheet's content
    /// in the same moment (the gift sheet goes from nothing to the looks panel) inserts its
    /// views inside the slide-up animation, and SwiftUI does not carry a freshly inserted
    /// view along with the animated offset of its parent: the card rose, the content stood
    /// at its end position and faded in (measured, simulator video, 19.10.2026). So the
    /// content is inserted while the card is still below the screen, and only then does it
    /// rise, as one view.
    @State private var settled = false

    /// On iPad (regular width) the card is a centered panel of sensible width instead of the
    /// full screen width; on iPhone and in compact iPad windows nothing changes.
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var cardWidth: CGFloat { sizeClass == .regular ? 600 : .infinity }

    /// Opened *and* the content has had its frame: what the card's position follows.
    private var present: Bool { opened && settled }

    func body(content: Content) -> some View {
        content
            .overlay { sheet }
            .onChange(of: opened, initial: true) { _, now in
                if now {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(40))
                        if opened { settled = true }
                    }
                } else {
                    var plain = Transaction()
                    plain.disablesAnimations = true
                    withTransaction(plain) { settled = false }
                }
            }
    }

    private var sheet: some View {
        ZStack(alignment: .bottom) {
            Rectangle()
                // The scrim opens with the pull: pulling the sheet down already brightens the
                // page behind it.
                .fill(.black.opacity(present && dimmed ? 0.55 * (1 - share) : 0))
                .ignoresSafeArea()
                // **The same curve as the card.** It hung only on the card, not on the scrim, and
                // the scrim was therefore set hard: on opening it was there at once while the
                // card was still coming up. On closing it wasn't noticeable because
                // `close(with:)` wraps the change in an animation anyway and the scrim takes
                // it along.
                //
                // It does not hang on the pull: `value: opened` means only opening and closing
                // run. While the finger pulls, the scrim follows it one to one.
                .animation(Theme.sheetMotion, value: present)
                .animation(Theme.sheetMotion, value: dimmed)
                .allowsHitTesting(dimmed)
                .onTapGesture { close(with: 0) }

            VStack(spacing: 0) {
                // **White 18 %, not dark**.
                //
                // The handle used `reason` at 78 %; calculated on `area` that is about #0D0D0F
                // on #161619, so **darker than the card it lies on**. Putting something
                // darker into a lighter card reverses the direction and reads as a hole, not as a
                // handle. That the same value is right on the progress bar and the tile badge
                // changes nothing: those lie over a poster, not on a surface.
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 36, height: 5)
                    .padding(.top, 8)
                    // Too narrow to hit, and that doesn't matter: the whole sheet is dragged. For
                    // VoiceOver it is nothing.
                    .accessibilityHidden(true)

                sheetContent()
            }
            .frame(maxWidth: cardWidth, alignment: .leading)
            .background {
                // **The surface extends further down than the card ever travels.** The spring
                // overshoots on opening, so the card lifts briefly. If the surface ended at its
                // bottom edge, the content underneath would flash through at that moment. "The
                // bounce on opening is great."
                UnevenRoundedRectangle(topLeadingRadius: Theme.cornerSheet,
                                       topTrailingRadius: Theme.cornerSheet)
                    .fill(Theme.area)
                    .overlay(alignment: .top) {
                        if let light {
                            CardLight(tone: light, tint: lightTint)
                        }
                    }
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: Theme.cornerSheet,
                                                      topTrailingRadius: Theme.cornerSheet))
                    .padding(.bottom, -400)
                    .ignoresSafeArea(edges: .bottom)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height }
                action: { cardsHeight = $0 }
            .offset(y: present ? pull : cardsHeight + 400)
            // **The slide-up belongs here, not at the call sites.**
            //
            // It used to hang on a `withAnimation` at every opener: five places, and when
            // switching to Apple's `sheet` all five were dropped, because a system sheet
            // animates itself. After that the sheet was "just there, bang" on opening and
            // only slid out.
            //
            // **In both directions.** On closing, this used `nil` so the spring from
            // `close(with:)` with the finger's momentum applies. That worked only when
            // pulling shut: whoever presses "Cancel", taps next to it or selects something
            // sets `opened` without any animation, and then the sheet was gone abruptly.
            //
            // The price is small and the safety great: the finger's momentum keeps working
            // where you feel it, in the spring-back, which runs via `pull` and doesn't touch
            // this animation at all.
            .animation(Theme.sheetMotion, value: present)
            .gesture(drag)
            // **Closed means gone, for VoiceOver too.** The closed sheet lay only below the
            // screen edge; VoiceOver found its buttons anyway and read "Remove all" in the
            // settings (checked with a font sample). When open, `isModal` keeps the focus in
            // the sheet.
            .accessibilityElement(children: .contain)
            .accessibilityHidden(!opened)
            .accessibilityAddTraits(opened ? .isModal : [])
        }
        // The stack must fill the screen; otherwise the overlay is sized to its content
        // and the card sits at the top.
        //
        // **Without `ignoresSafeArea` on the stack**, and that is the difference between
        // a button above the home indicator and one below it: the content ends at the
        // safe area, only the surface runs beyond.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(opened)
        // **Otherwise VoiceOver users can't get out.** Closing happens by dragging or by
        // a tap on the scrim, and neither exists with VoiceOver, and not every sheet
        // carries a Cancel row. `.escape` is the gesture the system knows for this; the
        // player already does it at its three levels.
        .accessibilityAction(.escape) { if opened { close(with: 0) } }
    }

    /// How far the sheet is on its way out, 0 to 1; the scrim hangs on it.
    private var share: Double {
        Double(min(max(pull, 0) / max(cardsHeight, 1), 1))
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                let distance = value.translation.height
                // Downward one to one, upward with resistance.
                pull = distance >= 0 ? distance : -rubber(-distance)
            }
            .onEnded { value in
                let fast = value.velocity.height
                // A quarter of the sheet height, or a fast swipe.
                if value.translation.height > cardsHeight * 0.25 || fast > 700 {
                    close(with: fast)
                } else {
                    withAnimation(spring(to: 0, with: fast)) { pull = 0 }
                }
            }
    }

    /// `UIScrollView`'s rubber band: the further you pull, the less it gives. `c =
    /// 0.55` is Apple's coefficient.
    private func rubber(_ distance: CGFloat) -> CGFloat {
        let d = max(cardsHeight, 1)
        return (1 - (1 / (distance * 0.55 / d + 1))) * d
    }

    /// A spring that takes over the finger's momentum.
    ///
    /// `initialVelocity` counts in **units of value change per second**, not in
    /// points; hence divide by the remaining distance. Without this conversion the
    /// number is either ineffective or flings.
    private func spring(to target: CGFloat, with momentum: CGFloat) -> Animation {
        let leg = max(abs(target - pull), 1)
        let beginning = min(max(Double(momentum / leg), -25), 25)
        return .interpolatingSpring(mass: 1, stiffness: 280, damping: 32,
                                    initialVelocity: beginning)
    }

    private func close(with momentum: CGFloat) {
        withAnimation(spring(to: cardsHeight + 400, with: momentum)) {
            opened = false
            pull = 0
        }
    }
}

extension View {
    /// A sheet from below. See ``Blattmodifikator``.
    ///
    /// **Always attach, never inside an `if opened`.** In an `if`, `opened` is already
    /// true when it is attached, the card sits at its place at once, and the slide-up
    /// doesn't happen.
    ///
    /// **This is the only bottom sheet of the app that sits flush with the screen's
    /// edge.** Apple's `.sheet` with a partial height floats on iOS 26 (margin all around,
    /// the page showing under it); see `Fallen/swiftui.md`. Every sheet that is not full
    /// height comes through here, and `Werkzeuge/check.sh` fails on one that does not.
    func sheet<ContentBody: View>(opened: Binding<Bool>, dimmed: Bool = true, light: Color? = nil, lightTint: Color? = nil,
                             @ViewBuilder content: @escaping () -> ContentBody) -> some View {
        modifier(SheetModifier(opened: opened, dimmed: dimmed, light: light, lightTint: lightTint, sheetContent: content))
    }
}

/// The heading above a sheet's content.
///
/// Takes `Text` and no key: sometimes a fixed title ("Sort") stands there,
/// sometimes a movie title from the server, which must not be translated.
///
/// **13 pt gray was too quiet.** The size was built for a sheet with four rows; a
/// filter sheet takes half the screen, and there the same title read like a
/// footnote above the main thing. Now 17 semibold in white, with an edge below;
/// Plex's sheets do the same, only centered. **We don't adopt the centering:** our
/// headers are left-aligned everywhere, and the left-alignment rule says so for headers too.
struct SheetCategory: View {
    let text: Text

    var body: some View {
        VStack(spacing: 0) {
            text
                .font(Theme.categoryLarge)
                // -0.008 em on 17 pt is -0.136; -0.2 was estimated.
                .tracking(Theme.lockCategory)
                .foregroundStyle(Theme.font)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.edgeSpacing)
                // 8 for the handle, 5 for its height, 5 here: together the same 18 as before,
                // when nothing stood above the title.
                .padding(.top, 5)
                .padding(.bottom, 14)
            // **No line below the heading.** It used to be here and separated the title from
            // what it announces: two means for the same statement, and the spacing already
            // does it. The spec says so explicitly: "Heading 17 Semibold without a line
            // below."
        }
    }
}

/// The badge at the top right of a tile.
///
/// **White on dark, not accent.** The accent carries progress and selection; a
/// badge is a statement.
///
/// Which statement is on it is decided by `DisplayRules.tileMark` in the
/// package; here only the wording and the look live.
struct TileBadge: View {
    let mark: TileMark

    var body: some View {
        HStack(spacing: 3) {
            if mark == .watched {
                // Checkmark of the tile badge: 10, like its text. Before 9.
                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
            }
            if let text = wording {
                // **Without tracking.**
                //
                // The ladder gives the badge step +0.10 em, and that is right for **uppercase**.
                // What otherwise clumps together as a block is tracked; capitals do that,
                // lowercase doesn't. This mark carries "3 open" and "2 seasons", ordinary words,
                // and 1.0 pt on a size of 10 visibly pulls them apart. Feedback: "remove the gaps
                // in O P E N."
                //
                // The token stays: it still applies to the step, this mark just has no
                // uppercase.
                Text(verbatim: text)
                    .font(Theme.badge)
            }
        }
        .foregroundStyle(Theme.font)
        .padding(.horizontal, wording == nil ? 5 : 6)
        .padding(.vertical, 3)
        .background {
            // 9, not 6: the tile beneath has 10, and a mark more angular than its ground
            // stands out.
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.reason.opacity(0.78))

        }
        .padding(6)
    }

    private var wording: String? {
        switch mark {
        case .watched: nil
        case .opened(let n): String(localized: "\(n) offen")
        case .seasons(let n): n == 1 ? String(localized: "1 Staffel")
                                      : String(localized: "\(n) Staffeln")
        }
    }
}

/// The line above a sheet's footer, **across the full width.**
///
/// `SeparatorLine` indents 18 points because it sits between rows with icons. Above a
/// button that takes the full width, the same line looks like a mistake;
/// **The divider in a sheet, and continuous.**
///
/// Three builds ran side by side in the sheets: `SeparatorLine` with its side inset
/// of 18, the same with an additional 38 for indented episodes, and a calculated
/// one that started after the icon (`separatorInset - edgeSpacing`). Three starts in
/// one sheet, and none coincided with an edge. Feedback: "the lines don't go all
/// the way through, they stop at the icon, that looks very messy."
///
/// An inset is right in a **list** that stands at the screen edge: it says the
/// rows belong together and the icon in front leads the group. In a sheet the card
/// itself is already the group; its rounded edge says it louder than an inset
/// could. Then the inset is only a second edge that aligns with no other.
///
/// Continuous means: from card edge to card edge, without exception.
struct SheetLine: View {
    var body: some View {
        Rectangle().fill(Theme.line).frame(height: 1)
    }
}

/// The Cancel row at the foot of a sheet.
struct SheetCancel: View {
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            Text("Abbrechen")
                // Cancel is a secondary button: 15 semibold. Before 16.
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.fontQuiet)
                .frame(maxWidth: .infinity, minHeight: 54)
        }
        .buttonStyle(Theme.PressRow())
    }
}

/// List of actions that opens from below.
///
/// Unlike `SelectionSheet`: there you choose a value and see which one applies. Here
/// each row triggers something and the sheet closes.
///
/// It hangs on an empty surface because a sheet is a modifier and not a view in
/// the stack, so the call sites stay as they were.
struct ActionSheet: View {
    @Binding var opened: Bool
    /// What the sheet works on, not the word "More". That was already on the button,
    /// and the spot is too valuable to repeat it.
    let title: String
    /// The type lives in `TitleAction` and not here: bound to this building block,
    /// the other platforms couldn't build the same lists although the actions are the
    /// same everywhere.
    let actions: [TitleAction]

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .sheet(opened: $opened) {
                SheetCategory(text: Text(verbatim: title))

                ForEach(Array(actions.enumerated()), id: \.element.id) { pair in
                    // Continuous; the reasoning is at `SheetLine`.
                    if pair.offset > 0 { SheetLine() }
                    Button {
                        opened = false
                        pair.element.perform()
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: pair.element.symbol)
                                .font(.system(size: 17))
                                .frame(width: 20)
                                .accessibilityHidden(true)
                            Text(pair.element.text)
                                // 17 like the selection row next to it; the reasoning is there.
                                .font(.system(size: 17))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(pair.element.cautionary ? Theme.warning : Theme.font)
                        .padding(.horizontal, Theme.edgeSpacing)
                        // `minHeight`, not `height`: with a larger font a fixed height would clip the
                        // text. 52 like every other row in a sheet.
                        .frame(minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(Theme.PressRow())
                }

                SheetLine()
                SheetCancel { opened = false }
            }
    }
}

/// Short feedback at the bottom edge.
///
/// For things the server does in the background: there is nothing to confirm, only
/// to say that it arrived.
struct HintStrip: View {
    let text: String
    let close: () -> Void

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            Text(text)
                // Empty-state text in a panel: 13, not 14; 14 is on
                                // no ladder. It used to be 14.
                .font(.system(size: 13))
                .foregroundStyle(Theme.font)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                // Fill without border, like every other button; see `ValuePill`.
                .background(Theme.area, in: Capsule())
                .padding(.bottom, 34)
                .padding(.horizontal, 24)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
        .id(text)
        .task(id: text) {
            // For VoiceOver: the strip appears without focus, so announce it.
            #if os(iOS)
            AccessibilityNotification.Announcement(text).post()
            #endif
            // Longer texts take longer to read: 3 s, at most 6.
            try? await Task.sleep(for: .seconds(min(6, max(3, Double(text.count) / 18))))
            guard !Task.isCancelled else { return }
            close()
        }
    }
}

// MARK: - Empty and disturbed views

/// What to see when there is nothing to see.
///
/// Before, something like this hung directly below the header: a small system
/// icon, gray text, a gray pill, and below it two thirds black. That reads as a
/// crash, not as a hint. Here the block sits centered in the available space, the
/// icon stands in the same circular surface that otherwise carries surfaces, and
/// the text names names.
struct EmptyState: View {
    let symbol: String
    let headerLine: LocalizedStringKey
    let text: LocalizedStringKey
    /// `loads` lets the icon breathe, for "being tried right now".
    ///
    /// Here it said "instead of the icon a ring spins", while the implementation forty
    /// lines further down says: "No ring, not here either: the icon itself breathes."
    /// Two notes in the same type that contradict each other; the code breathes, so
    /// the second is right.
    var loads = false
    var primaryButton: (title: LocalizedStringKey, perform: () -> Void)?
    var quietButton: (title: LocalizedStringKey, perform: () -> Void)?

    var body: some View {
        // **The spacings are in the spec, not in feeling:** icon, 22, heading, 7, text,
        // 24, primary button, 16, quiet button. Before, everything went through a
        // `spacing: 16` plus two manual additions, and heading and text stood as far
        // apart as text and button, although the two above belong together.
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .fill(Theme.area)
                    .frame(width: 78, height: 78)
                // No ring, not here either: the icon itself breathes while it runs. A ring would
                // have said "wait"; the icon keeps saying what it is about.
                // `.light` no longer exists: three weights, and Regular is the lightest.
                // 44, not 30: "icon **or** emoji (44)", one size for both, otherwise they are two
                // empty states.
                Image(systemName: symbol)
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.fontQuiet)
                    // Limited to the opacity, the same trap as in `Ladefeld`: an endless loop via
                    // `value:` captures everything that changes on the view in the same pass.
                    // The breathing is dropped under Reduce Motion.
                    .animation(loads && !Theme.motionReduced
                               ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                               : Theme.reveal) {
                        $0.opacity(loads ? 0.45 : 1)
                    }
            }
            .padding(.bottom, 22)

            Text(headerLine)
                .padding(.bottom, 7)
                .growing(20, .semibold)
                .tracking(Theme.lockRail)
                .foregroundStyle(Theme.font)

            Text(text)
                .growing(15)
                .foregroundStyle(Theme.fontQuiet)
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 262)
                .padding(.bottom, 24)

            // The primary button is otherwise as wide as the page. Here it stands centered
            // and only as wide as its text; a disturbance is not a form to fill out.
            //
            // **`stretches: false`, not `fixedSize` alone.** The stretching style has no inner
            // padding; squeezed, the white surface lay flush against the text, without margin
            // left and right ("Try again" didn't look like a button). Narrow, it brings its
            // 28 along, like Mac and TV.
            if let primaryButton {
                Button(primaryButton.title, action: primaryButton.perform)
                    .buttonStyle(PrimaryButtonStyle(stretches: false))
                    .fixedSize()
                    .padding(.bottom, 16)
            }
            if let quietButton {
                Button(quietButton.title, action: quietButton.perform)
                    .buttonStyle(Theme.PressButton())
                    .font(.system(size: 15, weight: .medium))
                    // The quiet button carries the accent: it is the second action, and the accent
                    // marks it as one.
                    .foregroundStyle(Theme.accent)
                    // **44 tall**. It carried only 15 pt of text, so a good 20 pt of hit
                    // area, and on the home page this is "Switch server", the way out of an error
                    // state. The width stays at the text.
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 34)
        // **The entry belongs in the component, not with the callers.**
        //
        // An empty state is rare and emotional: the server doesn't answer, or the
        // library is empty. That is exactly where the bit of budget for motion lies, and
        // until now it jumped hard into view. With the curve here, all call sites get it
        // and none can invent its own.
        //
        // The *timing* stays with the caller: a `.transition` only works if the insertion
        // itself is animated. That is the division SwiftUI prescribes: the how here, the
        // when there.
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }
}

extension EmptyState {
    /// **"Server has gone missing" as a whole page: once, not six times.**
    ///
    /// It used to be verbatim in home, library, collection, genre, watchlist and
    /// search. The same wording as `DisturbHint` below, only as a whole page. Without
    /// `erneut` no primary button, without `wechseln` no quiet one; while `loads`,
    /// neither.
    static func serverDived(_ model: AppModel, loads: Bool = false,
                                 retry: (() -> Void)?,
                                 switchTo: (() -> Void)? = nil) -> EmptyState {
        EmptyState(
            symbol: "externaldrive.badge.xmark",
            // A harmless error: nothing is lost, so the title may still say what's going on;
            // the joke is in the second sentence. That is the tone for harmless errors.
            headerLine: "Server ist abgetaucht",
            text: "\(model.serverAddress ?? String(localized: "Der Server")) antwortet nicht. Läuft er noch, oder hängt das WLAN?",
            loads: loads,
            primaryButton: loads ? nil : retry.map { (title: LocalizedStringKey("Erneut versuchen"), perform: $0) },
            quietButton: loads ? nil : switchTo.map { (title: LocalizedStringKey("Server wechseln"), perform: $0) })
    }
}

/// **A disturbed section *within* a page.**
///
/// The counterpart to `emptyHint`: there it says "nothing here", here it says "I
/// don't know, the server didn't answer". Until recently this distinction existed
/// only on whole pages: home, search, watchlist. Sections of a detail page said
/// "Nothing similar found" on every network error or disappeared silently, and
/// the app lied in twenty-five places.
///
/// **The wording is the same as in the full-page `Leerzustand`**: the same two
/// catalog keys, only set smaller because the page header already stands here. A
/// second wording for the same situation would be a second answer to the same
/// question.
struct DisturbHint: View {
    let model: AppModel
    /// Where there is something to repeat, the button is there. Where the section is
    /// reloaded with the whole page, it is missing: a button that loads the page twice
    /// is worse than none.
    var retry: (() -> Void)?
    /// 40 below an empty hint, 0 below a row heading that already brings its spacing.
    var spacingTop: CGFloat = 40
    /// **Who didn't answer.** Without a value, the own Jellyfin server. On a Seerr
    /// page it is Seerr: the same sentence, but the wrong address in it would mean the
    /// wrong troubleshooting: the own Jellyfin would be checked while Jellyseerr was
    /// down.
    var address: String?

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "externaldrive.badge.xmark")
                .font(.system(size: 30))
                .foregroundStyle(Theme.fontQuiet)
                .padding(.bottom, 14)

            Text("Server ist abgetaucht")
                .growing(17, .semibold)
                .foregroundStyle(Theme.font)
                .padding(.bottom, 6)

            Text("\(address ?? model.serverAddress ?? String(localized: "Der Server")) antwortet nicht. Läuft er noch, oder hängt das WLAN?")
                .growing(14)
                .foregroundStyle(Theme.fontVeryQuiet)
                .lineSpacing(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 262)

            if let retry {
                Button("Erneut versuchen", action: retry)
                    .buttonStyle(Theme.PressButton())
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    // 44 high, width follows the text.
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 34)
        .padding(.top, spacingTop)
    }
}

// MARK: - Input field

/// Our field instead of `.roundedBorder`.
///
/// The same values as the search field (surface, hairline, corner 10), only 48
/// instead of 44 tall so it forms a row with the 48 primary button below.
struct InputField: View {
    @Binding var text: String
    let symbol: String
    /// As a key, not a string: otherwise the placeholder stays in the source language
    /// while the page around it is translated. That is exactly what showed on the
    /// sign-in page: "Benutzername" and "Passwort" in German between all-English
    /// labels.
    var placeholder: LocalizedStringKey = ""
    var secret = false
    var keyboard: Way = .normal
    var completion: () -> Void = {}

    enum Way { case normal, address }

    @State private var shows = false
    @FocusState private var atTap: Bool
    /// Disabled means muted text, the same mapping as on the button styles, and it
    /// was missing here entirely.
    @Environment(\.isEnabled) private var operable

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(Theme.fontVeryQuiet)
                .frame(width: 20)
                .accessibilityHidden(true)

            Group {
                if secret, !shows {
                    SecureField("", text: $text, prompt: slot)
                } else {
                    TextField("", text: $text, prompt: slot)
                }
            }
            // Input field: body text, so 15.
            .font(.system(size: 15))
            .foregroundStyle(operable ? Theme.font : Theme.fontVeryQuiet)
            .focused($atTap)
            .onSubmit(completion)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(keyboard == .address ? .URL : .default)
            .submitLabel(.go)
            #endif

            if secret, !text.isEmpty {
                Button { shows.toggle() } label: {
                    Image(systemName: shows ? "eye.slash" : "eye")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.fontVeryQuiet)
                        // The icon stays 15, the target becomes 44.
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(Theme.PressButton())
                .accessibilityLabel(shows ? Text("Passwort verbergen")
                                          : Text("Passwort zeigen"))
                // Otherwise the 44 target would push the field apart.
                .padding(.trailing, -13)
            }
        }
        .padding(.horizontal, 14)
        // `minHeight`: with a larger system font the field must be allowed to grow,
        // otherwise it clips the row.
        .frame(minHeight: 48)
        .background(Theme.area, in: RoundedRectangle(cornerRadius: Theme.cornerField, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cornerField, style: .continuous)
                // **No focus ring.** This used an accent border at 55 percent, a raw opacity,
                // and the focus would have depended on color alone. Now the stroke width says
                // where you are typing: 2 instead of 1, the same color. Disabled has no focus, so
                // not the stronger edge either.
                .strokeBorder(Theme.margin, lineWidth: atTap && operable ? 2 : 1)
        }
        .animation(Theme.toggle, value: atTap)
        #if os(iOS)
        // The image in the app switcher shows no sign-in form, but only while a secret
        // field is visible; player and picture-in-picture stay free.
        .background { if secret { VisibilityProtectionAnchor().frame(width: 0, height: 0) } }
        #endif
    }

    private var slot: Text {
        Text(placeholder).foregroundColor(Theme.fontVeryQuiet)
    }
}

#if os(iOS)
/// **Privacy screen for the secret field.** When the scene loses the foreground
/// (app switcher, home, Control Center), a dark blur lies over the window before
/// iOS takes the image for the switcher; with "show password" the password would
/// otherwise be in it in plain text. It disappears again on returning to the
/// foreground. Attached only while the field is mounted; the counterpart on
/// Android: `VisibilityProtection` with `FLAG_SECURE`.
private struct VisibilityProtectionAnchor: UIViewRepresentable {
    func makeUIView(context: Context) -> AnchorView { AnchorView() }
    func updateUIView(_ uiView: AnchorView, context: Context) {}

    final class AnchorView: UIView {
        private var cover: UIView?
        private var observer: [NSObjectProtocol] = []

        /// Also unregistering the observers: when the field leaves the window, this call
        /// comes with `window == nil`.
        override func didMoveToWindow() {
            super.didMoveToWindow()
            observer.forEach(NotificationCenter.default.removeObserver)
            observer = []
            distance()
            guard let scene = window?.windowScene else { return }
            let nc = NotificationCenter.default
            observer = [
                nc.addObserver(forName: UIScene.willDeactivateNotification, object: scene,
                               queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.covers() }
                },
                nc.addObserver(forName: UIScene.didActivateNotification, object: scene,
                               queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.distance() }
                },
            ]
        }

        private func covers() {
            guard cover == nil, let window = window else { return }
            let d = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterialDark))
            d.frame = window.bounds
            d.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            window.addSubview(d)
            cover = d
        }

        private func distance() {
            cover?.removeFromSuperview()
            cover = nil
        }
    }
}
#endif


// MARK: - Placeholders instead of a spinner

/// A surface in the shape of what comes next.
///
/// Called `Ladefeld` and not `Placeholder`, because `Picture` already uses that
/// generic name for itself: two identical names in one file are not told apart by
/// anyone, the compiler least of all.
///
/// **Why no spinning ring.** A ring says "wait"; a placeholder says *what* is
/// coming and how much: the page already stands, it is just still empty. That is
/// the difference between "the app hangs" and "almost there", and it costs
/// nothing.
///
/// The pulsing runs via `.opacity` with `repeatForever`: Core Animation takes that
/// over and keeps computing on the render server without SwiftUI having to
/// rebuild anything per frame. A `TimelineView` per tile would be thirty clocks
/// for thirty placeholders.
struct LoadField: View {
    var corner: CGFloat = Theme.cornerTile
    @State private var bright = false

    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(Theme.area)
            // **The endless loop applies only to the opacity.** Before, `onAppear` started it
            // with `withAnimation(...repeatForever)`, and whoever had just come from sign-in
            // stood in the middle of the animated phase change (`RootView`,
            // `.animation(value: model.phase)`). Under iOS 18 the endless transaction took
            // the frames and margins of that transition along: the whole home page moved up
            // and down in a permanent loop (iOS 18.6 simulator: top margin 120 to 58, height
            // 654 to 640, content still). After a restart there was no transition, hence no
            // oscillation. The scoped `animation(_:body:)` cannot capture anything outside
            // its block.
            // Likewise: a placeholder that doesn't pulse is still a placeholder; permanent
            // pulsing against the setting is not.
            .animation(Theme.motionReduced ? nil
                       : .easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                $0.opacity(bright ? 1 : 0.5)
            }
            // Set without a transaction, not in the transition: `task` runs after insertion,
            // not in its animation.
            .task { bright = true }
            // To speech output a placeholder is nothing; it should hear "Loading", and so the
            // frame says that.
            .accessibilityHidden(true)
    }
}

/// A poster with two text lines below it, all as placeholders.
struct TilePlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            LoadField()
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
            VStack(alignment: .leading, spacing: 5) {
                LoadField(corner: 3).frame(height: 11)
                LoadField(corner: 3).frame(width: 42, height: 9)
            }
        }
    }
}

/// A grid of poster placeholders, as wide as the real one.
struct GridPlaceholder: View {
    let columns: Int
    /// How many rows. Two are enough: nobody sees more before the answer arrives, and
    /// every additional one is work for nothing.
    var rails: Int = 3

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.tileSpacing),
                                 count: columns),
                  alignment: .leading, spacing: 20) {
            ForEach(0 ..< (columns * rails), id: \.self) { _ in
                TilePlaceholder()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lädt")
    }
}

/// A row of poster placeholders, for the home page.
struct RailsPlaceholder: View {
    @Environment(\.wide) private var wide
    var landscape = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LoadField(corner: 4)
                .frame(width: 148, height: 18)
                .padding(.horizontal, Theme.margin(wide: wide))
            // **As an overlay, not as content.** Four tiles side by side are about 1000
            // points wide, and that is how wide the whole home page including the bar became
            // while the placeholders stood (measured in the simulator: page 440, home 1016).
            // A frame with `maxWidth` doesn't help because the scroll area asks for the ideal
            // width. The overlay contributes nothing to the size; the row is as wide as there
            // is room and clips.
            Color.clear
                .frame(height: landscape ? Theme.railsLandscapeHeight(wide: wide)
                                    : Theme.railsHeight(wide: wide))
                .overlay(alignment: .leading) {
                    HStack(spacing: Theme.tileSpacing) {
                        ForEach(0 ..< 4, id: \.self) { _ in
                            LoadField()
                                .frame(width: landscape ? Theme.railsLandscapeWidth(wide: wide)
                                                   : Theme.railsWidth(wide: wide),
                                       height: landscape ? Theme.railsLandscapeHeight(wide: wide)
                                                    : Theme.railsHeight(wide: wide))
                        }
                    }
                    .padding(.horizontal, Theme.margin(wide: wide))
                }
                .clipped()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lädt")
    }
}

