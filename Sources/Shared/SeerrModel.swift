import Foundation
import JellyfinKit
import Observation

/// The Jellyseerr/Overseerr integration, as seen by the UI.
///
/// **An add-on, not a foundation.** Users without it should see nothing of it:
/// no empty section, no greyed-out button, no hint that they are missing
/// something. So this model mainly answers one question that all views ask:
/// ``verbunden``.
///
/// **And it never holds up search.** Search runs the own library and Seerr side
/// by side; if Seerr returns nothing or returns late, what the own server has
/// still shows immediately. An add-on must never block the core.
@MainActor
@Observable
final class SeerrModel {

    /// Where the credentials live. Separate key so signing out of Jellyfin does
    /// not take the Seerr login along; they are two services.
    private static let key = "seerr"

    /// **Seerr is tied to the server.** The identity (`Session.serverIdentity`: address of a
    /// Jellyfin server, machine of a Plex one) of the server the currently loaded account
    /// belongs to; each has its own keychain entry.
    private(set) var server: String?
    private var key: String {
        server.map { Self.key + "|" + $0 } ?? Self.key
    }

    private(set) var access: SeerrAccess?
    /// What the last check (or sign-in) found. `.unreachable` is not an expired session.
    private(set) var sessionState = SeerrSessionState.invalid
    var carries: Bool { sessionState == .valid }
    private(set) var error: String?

    /// Is a sign-in running? The view disables its button while it is.
    private(set) var reportAn = false

    var connected: Bool { access != nil }
    var address: String? { access?.address.absoluteString }

    /// The core's Seerr for the stored connection (search, detail, request, session check).
    /// The core's Seerr for the person page; `nil` when not connected.
    var coreClient: SeerrCore.Client? { client }

    private var client: SeerrCore.Client? {
        access.map { SeerrCore.model($0) }
    }

    /// Connecting or disconnecting here; the settings sync takes it to the other devices.
    @ObservationIgnored var changed: (() -> Void)?

    /// The media server's signed-in user name (set by the app model); Seerr signs in with the same account.
    @ObservationIgnored var userName: (() -> String?)?
    private var passwordKey: String { key + "|passwort" }

    init() { access = loaded() }

    /// **From another device, through the settings sync.** `nil` is a disconnect made
    /// there. Not reported back as a change of this device's.
    func adopt(_ new: SeerrAccess?) {
        guard new != access else { return }
        if let old = access?.address, old != new?.address { Self.cookiesForget(for: old) }
        if let new { secure(new) } else { Keychain.delete(key: key); Keychain.delete(key: passwordKey) }
        access = new
        sessionState = .invalid
        error = nil
        if new != nil { Task { await lookUp() } }
    }

    /// When switching to an account on another server, that server's credentials
    /// apply.
    ///
    /// On first call, credentials from before the second server was added move
    /// over to the server that is then active, which is the one they belonged to.
    func serverSwitched(_ identity: String?) {
        let new = identity
        guard new != server else { return }
        server = new
        if let new, Keychain.load(key: Self.key + "|" + new) == nil,
           let alt = Keychain.load(key: Self.key) {
            try? Keychain.save(alt, key: Self.key + "|" + new)
            Keychain.delete(key: Self.key)
        }
        access = loaded()
        sessionState = .invalid
        error = nil
    }

    // MARK: Verbinden

    /// Sign in and store the credentials.
    ///
    /// **The username comes from the Jellyfin sign-in**; the user types the
    /// password. We do not have it and that should stay so. It is not stored
    /// either: only the session that Seerr issues is kept.
    ///
    /// `headers` are the custom headers from "Advanced", for a proxy in front of
    /// Seerr. They end up in the credentials, hence in the keychain.
    func linkUp(address typedInput: String, user: String, password: String,
                   headers: [OwnHeader] = []) async {
        error = nil
        // **Two addresses when the scheme was guessed.**
        //
        // There used to be one. If the guess was wrong, sign-in ran into a timeout
        // and the user had to type `https://` themselves. The media server already
        // falls back to the other scheme in that case; Seerr now does too. If the
        // user typed the scheme, there is no second attempt: that is a decision.
        guard !Seerr.addresses(from: typedInput).isEmpty else {
            error = String(localized: "Das ist keine gültige Adresse.")
            return
        }
        reportAn = true
        defer { reportAn = false }

        do {
            // The core tries the addresses in turn (the second only after a network error), keeps the
            // first failure when the second only trips over the scheme or a refused redirect, and words it.
            let new = try await SeerrCore.signIn(typed: typedInput, user: user, password: password,
                                                 headers: headers)
            secure(new)
            // The same password signs in again when the session expires (Keychain, this device only).
            try? Keychain.save(Data(password.utf8), key: passwordKey)
            access = new
            sessionState = .valid
            error = nil
            changed?()
        } catch {
            self.error = readableError(error)
        }
    }

    /// Disconnect. Our side only; everything stays as it is at Seerr itself.
    func disconnect() {
        // Also the connection cookie, not just the stored credentials:
        // a still-valid session in memory stops Seerr from issuing a new one on the
        // next sign-in (see `Seerr.cookiesForget`).
        if let address = access?.address { Self.cookiesForget(for: address) }
        Keychain.delete(key: key)
        Keychain.delete(key: passwordKey)
        access = nil
        sessionState = .invalid
        error = nil
        changed?()
    }

    /// When opening settings: is the session still valid?
    ///
    /// Sessions expire, and the user should see that on the row rather than only
    /// on the next request.
    func lookUp() async {
        guard let client else { return }
        sessionState = (try? await client.applies()).map(SeerrCore.session) ?? .unreachable
        if sessionState == .invalid { await signInAgain() }
    }

    /// Seerr is set up but its session is gone: sign in again with the media server's account. Without a
    /// stored password nothing happens (the row asks for the manual sign-in); a refusal is shown, not retried.
    private func signInAgain() async {
        guard let stored = access, let user = userName?(), !user.isEmpty else { return }
        let started = key
        let result = await SeerrCore.autoSignIn(
            stored: stored, user: user, secret: KeychainSeerrPassword(key: passwordKey), headers: stored.headers)
        guard started == key, access == stored else { return }
        switch result {
        case .signedIn(let new):
            secure(new)
            access = new
            sessionState = .valid
            error = nil
            changed?()
        case .rejected(let message): error = message
        case .unreachable: sessionState = .unreachable
        case .noPassword, .notConfigured: break
        }
    }

    // MARK: Using

    /// Search, **without throwing and without blocking.**
    func searching(_ term: String) async -> [SeerrHit] {
        guard let client, DisplayRules.searchTermFits(term) else { return [] }
        return ((try? await client.search(term: term)) ?? []).map(SeerrCore.hit)
    }

    /// What a person has done as far as Seerr knows, for "Can be requested" on
    /// their page. Does not throw, like `searching`.
    func filmography(person tmdb: Int) async -> [SeerrHit] {
        guard let client else { return [] }
        return ((try? await client.filmography(personTmdb: Int64(tmdb))) ?? []).map(SeerrCore.hit)
    }

    /// Description, rating and seasons, for a title's page.
    func detail(_ hit: SeerrHit) async -> SeerrDetail? {
        guard let client else { return nil }
        guard let detail = try? await client.detail(art: hit.art, id: Int64(hit.id)) else { return nil }
        return SeerrCore.detail(detail)
    }

    /// Requests. This one throws: the user pressed the button.
    func askFor(_ hit: SeerrHit, seasons: [Int]? = nil) async throws {
        guard let client else { throw JellyfinError.notAuthenticated }
        try await SeerrCore.askFor(client, art: hit.art, id: hit.id, seasons: seasons)
    }

    /// Removes the platform's cookies of the Seerr address (a valid session in memory would stop Seerr from
    /// issuing a new one on the next sign-in).
    private static func cookiesForget(for address: URL) {
        SeerrCore.cookiesForget(for: address)
    }

    // MARK: Ablage

    private func loaded() -> SeerrAccess? {
        guard let data = Keychain.load(key: key) else { return nil }
        return try? JSONDecoder().decode(SeerrAccess.self, from: data)
    }

    private func secure(_ z: SeerrAccess) {
        guard let data = try? JSONEncoder().encode(z) else { return }
        // **In the keychain, not in settings.** The cookie grants access to a
        // service that can request titles.
        try? Keychain.save(data, key: key)
    }
}
