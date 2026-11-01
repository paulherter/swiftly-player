import AuthenticationServices
import SwiftUI

// **The small parts the Plex and Emby sign-in and the picker share between iPhone, iPad and Mac.**
//
// Kept out of the views so the Mac draws the same breathing mark, the same code boxes and
// the same sign-in window without a second copy; only the window anchor differs by system.

extension View {
    /// **Something is being prepared here**: the opacity breathes, as on the empty
    /// state's icon. Scoped to the opacity, the trap described at `LoadField`; still
    /// under Reduce Motion, where the words carry it alone.
    func breathing(_ on: Bool) -> some View {
        animation(on && !Theme.motionReduced
                  ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                  : Theme.reveal) {
            $0.opacity(on ? 0.45 : 1)
        }
    }
}

/// **The sign-in window as an object, so it can be closed from outside.** SwiftUI's
/// `webAuthenticationSession` action only returns when the page forwards back to the
/// app, which Plex's page does not do here; `ASWebAuthenticationSession.cancel()` is the
/// documented way to dismiss a window that is showing.
@MainActor
final class PlexBrowser: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    /// Which window is current; the late answer of one closed earlier must not count.
    private var generation = 0

    /// - Parameter ended: the window is gone without the app having closed it.
    func open(_ url: URL, callbackScheme: String?, ended: @escaping (Error?) -> Void) {
        close()
        generation += 1
        let mine = generation
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] _, error in
            Task { @MainActor in
                // Our own `close()` has already taken the session away.
                guard let self, self.generation == mine, self.session != nil else { return }
                self.session = nil
                ended(error)
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        if !session.start() {
            self.session = nil
            ended(nil)
        }
    }

    func close() {
        guard let session else { return }
        self.session = nil
        session.cancel()
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(macOS)
            // The window the person is looking at; the sheet of the sign-in hangs from it.
            return NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow
                ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
            #else
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            return active?.keyWindow ?? active?.windows.first ?? ASPresentationAnchor()
            #endif
        }
    }
}

/// **A code in single boxes**, the build of the Quick Connect code: nobody reads four
/// or six characters in a row off a screen without errors. `active` marks the box the
/// next digit goes into with the stronger edge, the way `InputField` shows focus.
struct CodeBoxes: View {
    let characters: [Character]
    var active: Int?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(characters.enumerated()), id: \.offset) { index, character in
                Text(String(character))
                    .font(Theme.titleLarge)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(Theme.font)
                    .frame(width: 46, height: 60)
                    .background(Theme.area, in: RoundedRectangle(cornerRadius: Theme.cornerField, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.cornerField, style: .continuous)
                            .strokeBorder(Theme.margin, lineWidth: active == index ? 2 : 0)
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: String(characters).trimmingCharacters(in: .whitespaces)))
    }
}

/// Round symbol for an account on the sign-in page.
struct AccountCharacter: View {
    let name: String
    let image: URL?
    let selected: Bool

    var body: some View {
        VStack(spacing: 8) {
            // **The building block, not a copy of it.**
            //
            // The symbol was built a second time by hand here: `erhoeht` as the
            // background instead of the gradient, a white 2 pt ring instead of
            // `highlighted`, 20 semibold as the letter instead of `size * 0.38`,
            // and the image via `Picture` instead of the image store, i.e. without the
            // synchronous lookup that prevents the letter from flashing. The same
            // thing in two builds means two profile rings in one app. That the ring
            // is white here and not accent is correct and is now `selected` in the
            // block.
            ProfileCharacter(name: name, image: image, size: 60, selected: selected)
            Text(name)
                // Title under a symbol: 13 from the scale, before a literal. One weight,
                // not two: `semibold` is wider than `medium`, and with two lines and
                // `minimumScaleFactor` the width decides the line break, so the name
                // wrapped differently when selected. Tone and ring express the choice.
                .font(Theme.tile)
                .foregroundStyle(selected ? Theme.font : Theme.fontQuiet)
                // Two lines and a bit more width: an eleven-character name was truncated
                // to ten characters at 66 pt and one line, and a truncated name on a
                // sign-in screen looks like an error.
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.85)
        }
        .frame(width: 84)
        // **The choice is not expressed only through tone and ring.** Both are
        // color, and color alone reaches nobody who has the page read aloud:
        // VoiceOver said the same for every account. `.isSelected` is the trait
        // the system knows for this.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
