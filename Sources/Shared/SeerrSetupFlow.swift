import Foundation
import JellyfinKit
import Observation
import SwiftlyCore

/// The Seerr sign-in page's driver: it forwards fields and taps to the core's `SeerrSetupScreen` and redraws after
/// each await. State, sentences (what failed, why, what to do) and the rules (who is asked for the address, which
/// ways exist) are the core's; this class only keeps the secret store, the per-server setting and the session in the
/// `SeerrModel`, like every other host.
@MainActor
@Observable
final class SeerrSetupFlow {
    typealias Info = SwiftlyCore.SeerrSetupInfo

    private let seerr: SeerrModel
    @ObservationIgnored private let screen: SwiftlyCore.SeerrSetupScreen
    /// What the screen shows now (`info()` of the core, read after every await).
    private(set) var info: Info
    /// A call is on its way; the page shows the loading line instead of the form.
    private(set) var working = false
    /// The first `start` has returned: only then does the page know whether it asks for the address.
    private(set) var opened = false

    init(seerr: SeerrModel) {
        self.seerr = seerr
        let screen = SeerrCore.setup()
        self.screen = screen
        info = screen.info()
    }

    /// The ways to sign in as rows. "Mit Plex" only where the host has a plex.tv token (a Plex media server account).
    var methods: [SwiftlyCore.SetupMethodRow] {
        info.methods.filter { $0.method != .plex || seerr.plexToken?() != nil }
    }

    /// Opens the screen: the per-server setting and the media server account go in, the core decides what shows
    /// (address field, "Anmelden" only, one sentence) and signs in by itself where Seerr allows it.
    func open() async {
        let admin = await seerr.isAdmin?() ?? true
        working = true
        try? await screen.start(isAdmin: admin, config: seerr.serverConfig, stored: nil, user: seerr.userName?(),
                           secret: seerr.passwordSource, plexToken: seerr.plexToken?())
        working = false
        opened = true
        refresh()
        adoptIfConnected(password: nil)
    }

    /// One sign-in. `address` and `headers` count only where the core asks for the address (the admin's first one);
    /// `name` is the Jellyfin name or the Seerr e-mail.
    func signIn(_ method: SwiftlyCore.SignInMethod, address: String, headers: [HeaderRow],
                name: String, password: String) async {
        let screen = self.screen
        let own = headers.headers.map { SwiftlyCore.OwnHeader(name: $0.name, value: $0.value) }
        let token = seerr.plexToken?() ?? ""
        working = true
        let call = Task {
            switch method {
            case .jellyfin: try? await screen.signInJellyfin(typed: address, headers: own, user: name, password: password)
            case .local: try? await screen.signInLocal(typed: address, headers: own, email: name, password: password)
            case .plex: try? await screen.signInPlex(typed: address, headers: own, token: token)
            }
        }
        // The core moved to "signing in" before it asked the network: show its loading line meanwhile.
        await Task.yield()
        refresh()
        await call.value
        working = false
        refresh()
        adoptIfConnected(password: method == .jellyfin ? password : nil)
    }

    /// "Adresse ändern" (admin).
    func editAddress() {
        _ = screen.editAddress()
        refresh()
    }

    private func refresh() { info = screen.info() }

    private func adoptIfConnected(password: String?) {
        guard info.phase == .connected, let made = screen.connection(), let access = SeerrCore.access(made) else { return }
        seerr.signedIn(access, serverConfig: info.serverConfig, password: password)
    }
}
