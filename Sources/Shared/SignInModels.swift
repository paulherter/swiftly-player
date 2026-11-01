import Foundation
import JellyfinKit
import Observation

// MARK: - State of the Plex and Emby sign-in pages
//
// **What the screen shows, and nothing that talks to a server.**
//
// The pages read these models and call the closures in `actions`; whoever connects
// them (AppModel, later the TV and the Mac) fills the closures, does the network work
// and writes the answer back into `step`. So the pages can be drawn in a preview in
// every state, and the TV can take the same model with its own view.
//
// Shared by all Apple targets; the views on top are per platform.

// MARK: Plex

/// One server of the Plex account, as the list needs it.
struct PlexServerChoice: Identifiable, Equatable, Sendable {
    /// The machine identifier.
    let id: String
    let name: String
    /// `nil` = the account's own server; otherwise the name of whoever shared it.
    var sharedBy: String?
    /// One of its addresses is in the local network.
    var local: Bool
    /// plex.tv's `presence`. Shown, not trusted: the list stays tappable either way.
    var online: Bool = true
}

/// A person of the Plex Home.
struct PlexProfileChoice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    var image: URL?
    /// Switching to it asks for the four-digit PIN.
    var protected: Bool
}

/// What the browser sign-in needs: the page to open and, for the way without a
/// browser, the code to type at plex.tv/link.
struct PlexPinPrompt: Equatable, Sendable {
    /// The plex.tv auth page including `forwardUrl`, so the window closes by itself.
    let url: URL
    /// The scheme of `forwardUrl`. The app already answers to `swiftly`.
    var callbackScheme: String = "swiftly"
    /// The short code; `nil` hides the row.
    var code: String?
    /// Seconds until the code expires; `nil` hides the countdown.
    var secondsLeft: Int?
}

/// Errors that end the flow. Problems with one server stay in its row (`PlexSignInModel.unreachable`).
enum PlexSignInProblem: Equatable, Sendable {
    /// plex.tv did not answer at all.
    case plexUnreachable
    /// The code expired before the sign-in was finished.
    case expired
    /// Anything else, with the sentence to show (already translated).
    case other(String)
}

@MainActor @Observable
final class PlexSignInModel {
    enum Step: Equatable {
        /// The page with the one button.
        case start
        /// The button was pressed, the code is being fetched. "Wird geöffnet…"
        case opening
        /// The browser is open (or was closed unfinished); the connection polls.
        case waiting(PlexPinPrompt)
        /// Signed in, profiles or servers on their way. Placeholders in the shape of what comes.
        case loading(Placeholder)
        /// Plex Home: who is watching. Comes before the servers because the profile
        /// decides which servers there are.
        case profiles([PlexProfileChoice])
        /// The chosen profile is protected.
        case pin(PlexProfileChoice)
        /// The account's servers; empty = the empty state.
        case servers([PlexServerChoice])
        case failed(PlexSignInProblem)
    }

    enum Placeholder: Equatable { case profiles, servers }

    struct Actions {
        /// "Mit Plex anmelden": fetch a PIN, then set `.waiting`.
        var start: () -> Void = {}
        /// The browser window closed. `finished` = it came back through `forwardUrl`;
        /// `false` = the user closed it. Either way: poll once now.
        var browserClosed: (_ finished: Bool) -> Void = { _ in }
        var pickProfile: (PlexProfileChoice) -> Void = { _ in }
        /// Four digits entered. Wrong → set `pinWrong`, stay on `.pin`.
        var submitPin: (PlexProfileChoice, String) -> Void = { _, _ in }
        /// Connect to the server. Fine → leave the page; nothing answers → put its id into `unreachable`.
        var pickServer: (PlexServerChoice) -> Void = { _ in }
        /// Ask plex.tv again for the server list.
        var reloadServers: () -> Void = {}
        /// Sign out of plex.tv and back to `.start`.
        var otherAccount: () -> Void = {}
        /// The arrow at the top: leave the page, stop polling.
        var cancel: () -> Void = {}
    }

    var step: Step
    /// The plex.tv account's name once known; it becomes the page title.
    var account: String?
    /// The profile chosen in Plex Home; shown above the server list.
    var profile: PlexProfileChoice?
    /// The server being connected to right now. Its row says "Verbinden…", the others wait.
    var connecting: String?
    /// Servers that did not answer at any of their addresses.
    var unreachable: Set<String> = []
    /// The PIN of the profile was wrong.
    var pinWrong = false
    /// The PIN is being checked.
    var pinChecking = false
    var actions = Actions()

    init(step: Step = .start) { self.step = step }

    /// Back within the flow before leaving it: from the PIN to the profiles, from the
    /// servers to the profiles if there were any. `nil` = leave the page.
    var stepBack: Step? {
        guard let profiles = lastProfiles, profiles.count > 1 else { return nil }
        switch step {
        case .pin, .servers, .loading(.servers): return .profiles(profiles)
        default: return nil
        }
    }

    /// Remembered so the PIN page can go back without asking plex.tv again.
    var lastProfiles: [PlexProfileChoice]?

    /// The page title: the account's name once signed in, like the server's name on the
    /// Jellyfin page. Before that the kind: "Mit Plex anmelden" would stand twice, here
    /// and on the button.
    var pageTitle: String {
        switch step {
        case .start, .opening, .waiting, .failed: ServerKind.plex.shownName
        default: account ?? ServerKind.plex.displayName
        }
    }

    /// The arrow at the top: one step back within the flow, or out of it.
    func goBack() {
        if let earlier = stepBack { step = earlier } else { actions.cancel() }
    }
}

// MARK: Emby

/// An account the Emby server offers on its sign-in page.
struct EmbyUserChoice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    var image: URL?
}

enum EmbySignInProblem: Equatable, Sendable {
    /// Nothing answered at the address.
    case unreachable(address: String)
    /// Something answered, but not Emby (often Jellyfin: the two look alike from outside).
    case notEmby(kindFound: String?)
    case other(String)
}

@MainActor @Observable
final class EmbySignInModel {
    enum Step: Equatable {
        /// Where the server is.
        case address
        /// The server answered: name and version for the header.
        case signIn(serverName: String, version: String)
    }

    struct Actions {
        /// Check the address. Answer → `.signIn` and `users`; none → `problem`.
        var check: (_ address: String, _ headers: [OwnHeader]) -> Void = { _, _ in }
        /// Sign in. Wrong → `signInError`.
        var signIn: (_ user: String, _ password: String) -> Void = { _, _ in }
        /// The arrow on the address step: back to the picker.
        var cancel: () -> Void = {}
        /// Jellyfin found where Emby was expected: switch to the Jellyfin page with the same address.
        var useJellyfin: ((String) -> Void)?
    }

    var step: Step = .address
    var address = ""
    var checking = false
    var problem: EmbySignInProblem?
    /// `nil` while being fetched, empty when the server shows none.
    var users: [EmbyUserChoice]?
    var signingIn = false
    var signInError: String?
    var actions = Actions()

    init(step: Step = .address) { self.step = step }

    /// The arrow at the top: from the sign-in back to the address, from the address out.
    func goBack() {
        if case .signIn = step {
            step = .address
            signInError = nil
        } else {
            actions.cancel()
        }
    }
}
