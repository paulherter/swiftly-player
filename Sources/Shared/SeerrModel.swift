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

    /// **Seerr is tied to the server.** The Jellyfin server the currently loaded
    /// account belongs to; each has its own keychain entry.
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

    private var client: SeerrClient? {
        access.map { SeerrClient(access: $0) }
    }

    /// Connecting or disconnecting here; the settings sync takes it to the other devices.
    @ObservationIgnored var changed: (() -> Void)?

    init() { access = loaded() }

    /// The server's form of an address, as `server` holds it.
    static func serverForm(_ url: URL) -> String {
        var form = url.absoluteString.lowercased()
        while form.hasSuffix("/") { form.removeLast() }
        return form
    }

    /// **From another device, through the settings sync.** `nil` is a disconnect made
    /// there. Not reported back as a change of this device's.
    func adopt(_ new: SeerrAccess?) {
        guard new != access else { return }
        if let old = access?.address, old != new?.address { Seerr.cookiesForget(for: old) }
        if let new { secure(new) } else { Keychain.delete(key: key) }
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
    func serverSwitched(_ url: URL?) {
        var new = url?.absoluteString.lowercased()
        while new?.hasSuffix("/") == true { new?.removeLast() }
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
        let addresses = Seerr.addresses(from: typedInput)
        guard !addresses.isEmpty else {
            error = String(localized: "Das ist keine gültige Adresse.")
            return
        }
        reportAn = true
        defer { reportAn = false }

        var lastOne: Error?
        for url in addresses {
            do {
                let new = try await SeerrClient.signIn(an: url, user: user,
                                                         password: password, headers: headers)
                secure(new)
                access = new
                sessionState = .valid
                error = nil
                changed?()
                return
            } catch {
                // The first failure stays when the second attempt only trips over the
                // scheme or a refused redirect: "no server reachable" is the real news.
                lastOne = lastOne.map { Seerr.errorToShow(first: $0, second: error) } ?? error
                // **Only keep trying on a network error.** If Seerr says "wrong password",
                // the address is right and the other scheme would just add a second
                // timeout.
                guard (error as? URLError) != nil else { break }
            }
        }
        error = lastOne.map(readableError)
    }

    /// Disconnect. Our side only; everything stays as it is at Seerr itself.
    func disconnect() {
        // Also the connection cookie, not just the stored credentials:
        // a still-valid session in memory stops Seerr from issuing a new one on the
        // next sign-in (see `Seerr.cookiesForget`).
        if let address = access?.address { Seerr.cookiesForget(for: address) }
        Keychain.delete(key: key)
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
        sessionState = await client.applies()
    }

    // MARK: Using

    /// Search, **without throwing and without blocking.**
    func searching(_ term: String) async -> [SeerrHit] {
        guard let client, DisplayRules.searchTermFits(term) else { return [] }
        return await client.searching(term)
    }

    /// What a person has done as far as Seerr knows, for "Can be requested" on
    /// their page. Does not throw, like `searching`.
    func filmography(person tmdb: Int) async -> [SeerrHit] {
        guard let client else { return [] }
        return await client.filmography(person: tmdb)
    }

    /// Description, rating and seasons, for a title's page.
    func detail(_ hit: SeerrHit) async -> SeerrDetail? {
        guard let client else { return nil }
        return await client.detail(art: hit.art, id: hit.id)
    }

    /// Requests. This one throws: the user pressed the button.
    func askFor(_ hit: SeerrHit, seasons: [Int]? = nil) async throws {
        guard let client else { throw JellyfinError.notAuthenticated }
        try await client.askFor(art: hit.art, id: hit.id, seasons: seasons)
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
