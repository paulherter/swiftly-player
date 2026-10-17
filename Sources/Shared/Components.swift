import JellyfinKit
// Components.swift
// Swiftly
//
// **Building blocks that are the same on every platform.**
//
// They used to exist three times, here, in `Sources/tvOS` and in
// `Sources/macOS`, because `Style.swift` mixed iPhone dimensions and neutral
// blocks in one file, so the other targets could not include it. Copies drift
// apart: it happened with `loadMore()`, `hitInfo` and `PlayTime`.
//
// **The seam is `Theme`.** Colors come from `Colors.swift` and are shared anyway;
// sizes come from each target's own `Theme`. A block here may therefore only use
// what **all** targets have:
//
// Farben      akzent, rand, schrift, schriftLeise, flaeche
// Stil        plakette, reihe
//
// `Theme.edgeSpacing` is not among them, since tvOS lacks it. Spacing is
// therefore set by the caller, not by the block.

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Heading above a row.
struct RailTitle: View {
    var text: LocalizedStringKey = ""
    /// **When the heading comes from the server.** A genre is called what it is
    /// called and must not go through the translation table.
    var name: String? = nil
    var body: some View {
        Group {
            if let name { Text(verbatim: name) } else { Text(text) }
        }
            .font(Theme.rail)
            // −0.012 em at 20 pt is −0.24; −0.3 was an estimate.
            .tracking(Theme.lockRail)
            .foregroundStyle(Theme.font)
    }
}

/// Small label such as "FSK 16" or "4K".
struct Badge: View {
    let text: String
    /// **The color is a parameter, not a fixed value.** The file summary colors the
    /// warning orange when the server transcodes after all. That is the one place
    /// where a badge does not just label but alarms. Were it fixed, tvOS would have
    /// lost exactly this signal when taking over the shared version.
    var color: Color = Theme.fontQuiet
    /// Dimensions as parameters: on TV the iPhone values are too small. This way
    /// every platform works without its own copy.
    var innerLevelRight: CGFloat = 10
    var innerVerticalRight: CGFloat = 4
    var rounding: CGFloat = Theme.cornerSmall
    /// **The font is a dimension too**, the only one that was fixed.
    ///
    /// Padding and corner radius could be set per platform, the 13 could not. On TV
    /// the rating then appeared in phone size inside a box blown up to double, next
    /// to text at 27.
    var size: CGFloat = 13

    var body: some View {
        // **A 15 percent surface, not an outline.**
        //
        // It was 10 semibold in a box with corner 3 and padding 5/2, about 16 high,
        // with a stroke instead of a fill. The detail line in `Style.swift` already
        // builds the same badge correctly beside it: 13 medium, corner 8,
        // `farbe.opacity(0.15)`. Two badges with the same meaning in two shapes were the
        // bug, not the numbers.
        Text(text)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, innerLevelRight)
            .padding(.vertical, innerVerticalRight)
            .background(color.opacity(0.15),
                        in: RoundedRectangle(cornerRadius: rounding, style: .continuous))
    }
}

struct Loader: View {
    var size: CGFloat = 34
    var strength: CGFloat = 3

    @State private var rotating = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.22)
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: strength, lineCap: .round))
            .frame(width: size, height: size)
            // **Faster spins feel faster.** At the same load time a quick ring feels
            // shorter than a leisurely one; this is perceived, not measured performance.
            // 0.9 s per turn was sluggish; 0.7 s says the same more briskly. It stays
            // linear; a curve would stutter in a continuous rotation.
            //
            // **Scoped to the rotation.** An endless loop via `value:` took the frames of a
            // simultaneous transition with it on iOS 18 (see `Ladefeld`).
            // With Reduce Motion it does not spin: an endless rotation is exactly what that
            // setting should turn off.
            .animation(Theme.motionReduced ? nil
                       : .linear(duration: 0.7).repeatForever(autoreverses: false)) {
                $0.rotationEffect(.degrees(rotating ? 360 : 0))
            }
            .background {
                Circle()
                    .stroke(Theme.accent.opacity(0.18), lineWidth: strength)
                    .frame(width: size, height: size)
            }
            .task { rotating = true }
    }
}


/// Round profile mark with the initial.
struct ProfileCharacter: View {
    let name: String
    var image: URL?
    var size: CGFloat = 34
    var highlighted = false
    /// This account is the chosen one of several: white ring, two points.
    var selected = false

    /// **Whatever has already been fetched shows in the first pass.**
    ///
    /// There used to be an `AsyncImage` here, which starts from scratch in every new
    /// view even if the same image has been in memory since launch. While it runs,
    /// only the green gradient shows: tapping the profile picture left it briefly
    /// missing on the page, replaced by a green background. The same happened on the
    /// first switch to Movies or Series, for the same reason.
    ///
    /// Two attempts removed the **letter** without touching the cause: the view
    /// refetches the image although it is already there. `ImageCache` answers
    /// exactly that question, and **synchronously**, which is why it is checked in
    /// `init` and not in `task`. A value delivered later arrives one pass too late,
    /// and that one pass is the flash.
    @State private var loaded: Image?
    /// The fetch failed, usually because the account has no image at all. Then the
    /// letter belongs there, not the empty gradient.
    @State private var withoutImage = false

    /// `withoutImage`: it is already known that there is no image, so the letter shows in
    /// the first pass rather than after the failed fetch. For views that are drawn
    /// only once (`ImageRenderer`) or must be right in the first frame.
    init(name: String, image: URL? = nil, size: CGFloat = 34,
         highlighted: Bool = false, selected: Bool = false, withoutImage: Bool = false) {
        self.name = name
        self.image = image
        self.size = size
        self.highlighted = highlighted
        self.selected = selected
        let present = image.flatMap { ImageCache.shared.image($0) }
        _loaded = State(initialValue: present)
        _withoutImage = State(initialValue: withoutImage && present == nil)
    }

    var body: some View {
        ZStack {
            // The gradient always applies: it sits behind the image and is not noticeable
            // when one is present.
            reason

            // **The letter is a fallback, not a base layer.** It used to sit underneath
            // with the image on top; during the image's fade-in it showed through, and
            // someone with a profile picture saw a big "P" in it for a moment. It belongs in
            // the branch where no image arrives. **And `.empty` means "still running", not
            // "no image".**
            //
            // The paragraph above moved the letter from the base layer to the fallback
            // branch, but the branch still caught *every* case except success, including a
            // running fetch. So it kept flashing: no longer under the image but in front of
            // it. Strongest on the **first** switch from Home to Movies or Series, because a
            // new view is created there and its `AsyncImage` starts over although the image
            // has long been in memory.
            //
            // While the fetch runs, only the gradient shows. The same distinction as in
            // `Picture`, same cause, same fix.
            if let loaded {
                loaded.resizable().aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else if image == nil || withoutImage {
                // Also when the fetch fails: the address is set for every account, whether it
                // has an image or not.
                // **The letter is a fallback, not a base layer.** It belongs in the branch where
                // there is no image at all; underneath, it showed through during the fade-in.
                letter
            }
        }
        .animation(Theme.reveal, value: loaded == nil)
        // A new address means a new attempt; whatever was there stays until then
        // instead of swapping to the gradient.
        .task(id: image) {
            guard let image else { loaded = nil; return }
            if let present = ImageCache.shared.image(image) { loaded = present; withoutImage = false; return }
            loaded = await ImageCache.shared.load(image, onDevice: true)
            withoutImage = loaded == nil
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            // **Two different questions, two rings.**
            //
            // `highlighted` means "you are in the profile area". That is state, and state
            // is carried by the accent. It appears only in the bar below, which is one of
            // the two justified accent exceptions.
            //
            // `selected` means "this account of several". That is rank among siblings, and
            // that is never carried by the accent. White and the second stroke width say it.
            // `RootView` had built a second mark by hand for this (`AccountCharacter`), with a
            // different reason, ring and letter size: the same thing in two builds, hence
            // two profile rings in one app.
            Circle().strokeBorder(ringColor, lineWidth: selected ? 2 : highlighted ? 1.5 : 1)
        }
        .accessibilityElement()
        .accessibilityLabel("Profil von \(name)")
    }

    private var ringColor: Color {
        if selected { return Theme.font }
        return highlighted ? Theme.accent : Theme.margin
    }

    /// **A tone derived from the name.**
    ///
    /// This background went through three attempts. First a green gradient from two
    /// raw values, then `accentQuiet`, which gave **every** profile mark in the app
    /// a teal gradient, noticed as a green cast. Then two depths of the ladder, i.e.
    /// gray, which looks dead.
    ///
    /// Each was reasonable on its own and missed the point: a profile mark is a
    /// placeholder, but it stands for a **person**, and eight gray circles in a
    /// column look like a list that has not finished loading.
    ///
    /// The color is therefore computed from the name: the same person always gets the
    /// same one, on every device and after every restart, with nothing stored
    /// anywhere. Eight tones on a circle, all with **the same lightness and
    /// saturation** (OKLCH L 0.52 / C 0.105 on top, 0.36 / 0.085 at the bottom), so
    /// none is louder than another, and the letter on it has a contrast of 5.13 to
    /// 5.84 against white (computed, not estimated).
    ///
    /// The circle's first tone is the accent's hue. That is no accident: with only
    /// one contact you see the app's color.
    private var reason: some View {
        let tones = Theme.profileAudio[abs(namesDigit) % Theme.profileAudio.count]
        return Circle()
            .fill(LinearGradient(colors: [tones.top, tones.bottom],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    /// A fixed number from the name: `hashValue` will not do, since it differs on
    /// every app launch and the mark would change color on every restart.
    private var namesDigit: Int {
        name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 1_000_003 }
    }

    private var letter: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(Theme.font)
    }
}

// MARK: - Takeover: which device?

/// If something is running on several of the user's own devices, we ask instead
/// of guessing.
///
/// **The scrim is why this is not a `confirmationDialog`.** The system dialog
/// brings its own very bright one; over a dark home page full of posters it
/// hardly stands out. Here it belongs to us.
///
/// And the choice has consequences: what is chosen here **closes the player on
/// the other device**. That belongs in front of the eyes, not in one line.
struct TakeoverSelection: View {
    let sessions: [RemoteSession]
    var select: (RemoteSession) -> Void
    var cancel: () -> Void

    var body: some View {
        ZStack {
            Self.scrim(cancel: cancel)
            TakeoverCard(sessions: sessions, select: select, cancel: cancel)
        }
    }

    /// Also swallows the press so nothing behind reacts.
    ///
    /// `reason`, not `Color.black`: the scrim is the page showing through, which is
    /// `#101010`. Pure black exists in exactly one place, behind the image in the
    /// player.
    ///
    /// Reachable separately so the iPhone can bring in scrim and card separately:
    /// the scrim fades, the card grows out of the badge (experiment
    /// `experiment-glas`).
    static func scrim(cancel: @escaping () -> Void) -> some View {
        Theme.reason.opacity(0.62)
            .ignoresSafeArea()
            .onTapGesture(perform: cancel)
    }
}

/// The panel of ``Uebernahmeauswahl`` without its scrim.
struct TakeoverCard: View {
    let sessions: [RemoteSession]
    var select: (RemoteSession) -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // No system fonts or system colors here: the panel was the only place in the
            // app with `.headline`, `.caption` and `.secondary`, three values set by Apple
            // that nobody here determines.
            VStack(spacing: 8) {
                Text("Wo weiterschauen?")
                    .font(Theme.listTitle)
                Text("Auf dem anderen Gerät hört die Wiedergabe auf. Hier läuft sie an derselben Stelle weiter.")
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            ForEach(sessions) { s in
                SheetLine()
                Button { select(s) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: s.devicesCharacter)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 26)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.deviceName ?? String(localized: "Gerät"))
                                // `listTitle` is exactly this step; 15 semibold stood here as a number.
                                .font(Theme.listTitle)
                            Text(s.titleLine)
                                .font(Theme.small)
                                // The note above says there are no system colors here, yet `.secondary` still
                                // appeared twice below and was the last occurrence in the whole iPhone version.
                                // It is white with system opacity, exactly what the design rules exclude: "full
                                // values, no opacity".
                                .foregroundStyle(Theme.fontQuiet)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Text(PlayTime.text(s.state?.spot ?? 0))
                            // 12 regular is the scale's entry. 13 regular is in no step; 13 exists only as
                            // medium.
                            .font(Theme.small.monospacedDigit())
                            .foregroundStyle(Theme.fontVeryQuiet)
                    }
                    .padding(.horizontal, 20)
                    // `minHeight`: two lines of text in a fixed height are the first thing to tear
                    // once someone enlarges the font. 58 was the tightest case in the app.
                    .frame(minHeight: 58)
                    .contentShape(Rectangle())
                }
                .buttonStyle(Theme.PressRow())
            }

            // `Theme.rand`, not `font` at 12 %: that was a near-token. `rand` is white at
            // 12 %, here #F5F5F8 at 12 % stood. A color that should follow the brand and
            // does not.
            Divider().overlay(Theme.margin)
            Button("Abbrechen", action: cancel)
                .font(.system(size: 15, weight: .medium))
                .frame(maxWidth: .infinity)
                // The same height as the entries above. They stood at 58 and 52 on top of each
                // other, a six-point offset within one sheet, visible because they touch.
                .frame(minHeight: 58)
                .contentShape(Rectangle())
                .buttonStyle(Theme.PressRow())
        }
        .foregroundStyle(Theme.font)
        // `eckeFlaeche` (16), not `corner` (10): 10 is the button size. A floating panel
        // with a scrim is a surface of its own, and the corner grows with the object
        //.
        .background(Theme.area, in: RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous))
        .frame(maxWidth: 420)
        .padding(.horizontal, 24)
        // **No shadow.** The reference excludes it: depth comes from surface lightness.
        // This one, with radius 30, was the largest in the app and lifted a panel that
        // already lies on a scrim.
        // **Without this, VoiceOver users cannot get out.** The scrim closes on tap, but
        // a rotor swipe is not a tap, and the panel has no exit other than "Cancel",
        // which has to be found first. `.escape` is the gesture the system knows for it.
        .accessibilityAction(.escape, cancel)
    }
}

// MARK: - Clipboard

/// **One click, and the code is on the clipboard.**
///
/// Whoever opens Quick Connect has to enter the code somewhere else right after,
/// usually in a browser window on the same device. Copying it by hand while it is
/// right there is the kind of work an app should take over.
///
/// **TV has none.** tvOS has no clipboard, and the code is shown there to be
/// entered on a *different* device anyway. There the display stays as it is.
enum Clipboard {

    /// Whether this device has one.
    static var givesEs: Bool {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }

    static func copyText(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
    }
}

extension View {
    /// Makes the view clickable: the text goes to the clipboard and "Copied" shows
    /// briefly below.
    func copyable(_ text: String) -> some View { modifier(Copyable(text: text)) }
}

private struct Copyable: ViewModifier {
    let text: String
    @State private var copied = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if Clipboard.givesEs {
            Button {
                Clipboard.copyText(text)
                withAnimation(.easeOut(duration: 0.15)) { copied = true }
            } label: {
                content.contentShape(Rectangle())
            }
            .buttonStyle(Theme.PressButton())
            #if os(macOS)
            .help(Text("Zum Kopieren klicken"))
            #endif
            .accessibilityLabel(Text("\(text), zum Kopieren"))
            // **The feedback lies over the display, not under it.** A hint appearing under
            // the code pushes everything below it down by its height and back again.
            .overlay(alignment: .bottom) {
                if copied {
                    // **No accent.** The tone carries progress, selection and the Direct Play
                    // verdict; a confirmation that disappears after a second and a half does not
                    // belong there. A raised surface with a border says the same
                    // without using up the tone.
                    Text("Kopiert")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.font)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Theme.area, in: Capsule())
                        .offset(y: 16)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(1.4))
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.25)) { copied = false }
            }
        } else {
            content
        }
    }
}

// MARK: - Progress on tiles

extension EnvironmentValues {
    /// **Whether tiles show their progress bar**, Profile → Appearance.
    ///
    /// It existed as a setting and was stored, but **nobody** read it: the tiles
    /// always drew the bar. A switch that does nothing, on four versions: the
    /// pattern known as "built but not connected".
    ///
    /// **Via the environment, not via 33 call sites.** That many pass `progress:`
    /// along; touching all of them would mean writing the same check thirty-three
    /// times, and the thirty-fourth call would not have it. It is read at the one
    /// place per platform where the bar is actually created.
    @Entry var progressOnTiles: Bool = true
}

// MARK: - Watched

/// **Watch state on a thumbnail**: watched means darkened, with a checkmark on a
/// dark disc at the top right. The same badge in the episode list and in the
/// download list. It stood twice verbatim in the episode lists of iPhone and Mac,
/// and the download list needed it as a third place.
///
/// **0.78, like every other dark disc on an image**, 10 semibold like the tile
/// badge (`Theme.badge`). Edge and spacing are set by the caller; the Mac
/// computes on its own grid.
struct WatchedCheckmark: ViewModifier {
    let an: Bool
    var border: CGFloat = 18
    var spacing: CGFloat = 5

    func body(content: Content) -> some View {
        content
            // **Multiplied, not translucent.** With `opacity` the background showed
            // through: on a page in the color of its header image, every watched still got
            // that tint. This way it only becomes darker and the corners stay what they
            // were.
            .colorMultiply(Color(white: an ? 0.45 : 1))
            .overlay(alignment: .topTrailing) {
                if an {
                    Image(systemName: "checkmark")
                        .font(Theme.badge)
                        .foregroundStyle(Theme.font)
                        .frame(width: border, height: border)
                        .background(Theme.reason.opacity(0.78), in: Circle())
                        .padding(spacing)
                }
            }
            .animation(Theme.reveal, value: an)
    }
}

extension View {
    func watchedCheckmark(_ an: Bool, border: CGFloat = 18, spacing: CGFloat = 5) -> some View {
        modifier(WatchedCheckmark(an: an, border: border, spacing: spacing))
    }
}
