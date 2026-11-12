import Foundation
import JellyfinKit
import SwiftlyCore

/// A failure of the core with its sentence already readable (`readableError` shows `errorDescription`).
struct AccountFailure: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

/// **Where accounts are made and kept: the core's `AccountsModel`.**
///
/// Sign-in with name and password (Jellyfin, Emby), Quick Connect (code, wait, sign-in), the Plex sign-in,
/// switching, removing and the new address of a Plex server all run in the core, which saves the
/// accounts under the very Keychain entries `ServerBundles` always used (`konten`, `konten.emby`,
/// `konten.plex`, `aktiveArt`; `AccountsParityTests`). The app reads the saved state back with
/// `ServerBundles.load` and builds its `Session`s from it, so old and new builds share the data.
///
/// This file imports `SwiftlyCore` and `JellyfinKit` side by side; the names both have (`ServerKind`)
/// are written with their module.
@MainActor
final class AccountsHost {
    static let shared = AccountsHost()

    private var model: AccountsModel?
    /// The core's server and sign-in calls; one object, because it remembers the server it checked.
    private var login: LegacyLogin?

    private init() {}

    /// The core's model. Swift still writes the bundle in two places (the debug test session) and the
    /// core keeps its own copy, so every call starts by reading what is stored.
    /// The single session of the time before multiple accounts: the core does not read it, so it goes into
    /// the Jellyfin bundle first (what `AppModel.loadBundles` adopts in memory); the old entry stays.
    private static func adoptSingleSession() {
        var stored = ServerBundles.load { Keychain.load(key: $0) }
        guard stored.bundle(for: .jellyfin) == nil,
            let old = AccountBundle.outStore(bundle: nil, individual: Keychain.load(key: "session"))
        else { return }
        let active = stored.activeKind
        stored.set(old, for: .jellyfin)
        if stored.bundle(for: active) != nil { stored.switchTo(active) }
        try? stored.save { key, data in
            if let data { try Keychain.save(data, key: key) } else { Keychain.delete(key: key) }
        }
    }

    private func fresh() throws -> AccountsModel {
        Self.adoptSingleSession()
        let m: AccountsModel
        if let model { m = model } else {
            do { m = try AppCore.shared.accounts() } catch { throw Self.failure(error) }
            model = m
        }
        m.reload()
        return m
    }

    /// The core's sentence; for a network code it has no sentence for, the system's text (the old
    /// `readableError` on Apple), from the answer the HTTP client saw last.
    private static func failure(_ error: any Error, in model: AccountsModel? = nil) -> any Error {
        guard case CoreError.Failed(let message) = error else { return error }
        if let model, let last = NetworkMemory.shared.take() {
            return AccountFailure(
                text: model.failureTextSystem(message: message, code: last.code, systemText: last.text))
        }
        return AccountFailure(text: message)
    }

    private static func coreKind(_ kind: JellyfinKit.ServerKind) -> SwiftlyCore.ServerKind {
        switch kind {
        case .jellyfin: .jellyfin
        case .emby: .emby
        case .plex: .plex
        }
    }

    // MARK: Password

    /// Signs in at `address` and saves the account (it becomes the one in use).
    func signIn(address: URL, kind: JellyfinKit.ServerKind, user: String, password: String) async throws {
        let m = try fresh()
        NetworkMemory.shared.clear()
        do {
            _ = try await m.signIn(
                address: address.absoluteString, kind: Self.coreKind(kind), user: user, password: password)
        } catch { throw Self.failure(error, in: m) }
    }

    // MARK: Quick Connect

    func quickStart(address: URL) async throws -> LoginCode {
        let m = try fresh()
        NetworkMemory.shared.clear()
        do {
            let code = try await m.quickConnectStart(address: address.absoluteString)
            return LoginCode(code: code.code, confidential: code.confidential)
        } catch { throw Self.failure(error, in: m) }
    }

    /// How a wait for approval ended.
    enum QuickOutcome {
        /// Approved: the core signed in and saved the account.
        case approved
        /// Ran out or failed: the closing sentence.
        case ended(String)
        /// The caller stopped it.
        case stopped
    }

    private final class Rest: QuickConnectListener {
        private let handler: @Sendable (Int64) -> Void
        init(_ handler: @escaping @Sendable (Int64) -> Void) { self.handler = handler }
        func rest(seconds: Int64) { handler(seconds) }
    }

    /// Waits for the approval of `code`; `rest` hears the seconds left once a second.
    func quickWait(address: URL, code: LoginCode, rest: @escaping @Sendable (Int64) -> Void) async throws
        -> QuickOutcome
    {
        let m = try fresh()
        NetworkMemory.shared.clear()
        do {
            let end = try await m.quickConnectWait(
                address: address.absoluteString,
                code: QuickCode(code: code.code, confidential: code.confidential), listener: Rest(rest))
            if end.signedIn != nil { return .approved }
            if let message = end.message { return .ended(message) }
            return .stopped
        } catch is CancellationError {
            return .stopped
        } catch { throw Self.failure(error, in: m) }
    }

    // MARK: Server check (Emby)

    /// What the core's `embyCheck` found at an address.
    struct EmbyCheck: Decodable {
        struct Account: Decodable { let id: String; let name: String; let image: String? }
        let result: String
        let name: String
        let version: String
        let adresse: String
        let konten: [Account]
        let found: String?
        let message: String?
    }

    /// Checks `raw` as an Emby server (scheme guess, fallback, "looks like Jellyfin", the accounts of its sign-in
    /// page). The custom headers are put down in the app's table by the caller: the HTTP client reads that one.
    func embyCheck(_ raw: String) async -> EmbyCheck? {
        guard let m = try? fresh() else { return nil }
        let text = await legacy(m).embyCheck(address: raw, headers: "[]")
        return try? JSONDecoder().decode(EmbyCheck.self, from: Data(text.utf8))
    }

    /// The core's server calls for the network search (a plain object the search loop uses off the main actor).
    func legacyForSearch() throws -> LegacyLogin { legacy(try fresh()) }

    private func legacy(_ m: AccountsModel) -> LegacyLogin {
        if let login { return login }
        let l = m.legacyLogin()
        login = l
        return l
    }

    // MARK: Server check (Jellyfin)

    /// The server the core found at an address (the scheme it answered on included).
    struct Linked: Decodable {
        let name: String
        let version: String
        let adresse: String
    }

    /// Checks `raw` as a Jellyfin server: the scheme guess and, only for an address typed without
    /// one, the other scheme. Throws the core's sentence of the **first** attempt.
    func linkUp(_ raw: String) async throws -> Linked {
        let m = try fresh()
        NetworkMemory.shared.clear()
        do {
            let text = try await legacy(m).linkUp(address: raw, headers: "[]")
            return try JSONDecoder().decode(Linked.self, from: Data(text.utf8))
        } catch { throw Self.failure(error, in: m) }
    }

    // MARK: Who is watching, Quick Connect offer

    /// The public users of the server at `address` and the image address of each (empty when the
    /// server does not give the list).
    func publicUsers(address: URL) async -> (users: [PublicUser], images: [String: URL]) {
        guard let m = try? fresh() else { return ([], [:]) }
        let l = legacy(m)
        l.onboardingRemember(address: address.absoluteString, emby: false)
        let text = await l.publicUser(newServer: true)
        struct Row: Decodable { let kennung: String; let name: String; let bild: String? }
        guard let rows = try? JSONDecoder().decode([Row].self, from: Data(text.utf8)) else { return ([], [:]) }
        var users: [PublicUser] = []
        var images: [String: URL] = [:]
        for row in rows {
            let json = Data(#"{"Id":\#(Self.quoted(row.kennung)),"Name":\#(Self.quoted(row.name))}"#.utf8)
            if let u = try? JSONDecoder().decode(PublicUser.self, from: json) { users.append(u) }
            if let bild = row.bild, let url = URL(string: bild) { images[row.kennung] = url }
        }
        return (users, images)
    }

    private static func quoted(_ s: String) -> String {
        (try? String(data: JSONEncoder().encode(s), encoding: .utf8)) ?? "\"\""
    }

    /// Whether the Jellyfin server at `address` has Quick Connect switched on.
    func quickConnectOffered(address: URL) async -> Bool {
        guard let m = try? fresh() else { return false }
        let l = legacy(m)
        l.onboardingRemember(address: address.absoluteString, emby: false)
        return await l.quickConnectOffered(newServer: true)
    }

    // MARK: Switch, remove

    /// Makes the saved account `key` the one in use.
    func switchTo(key: String) {
        guard let m = try? fresh() else { return }
        _ = m.switchTo(key: key)
    }

    /// Removes the saved account `key` (and what the core cached for it).
    func remove(key: String) {
        guard let m = try? fresh() else { return }
        _ = m.remove(key: key)
    }

    /// Signs the account out for real: gone locally at once, the server told afterwards.
    func removeAndSignOff(key: String) {
        guard let m = try? fresh() else { return }
        _ = m.removeAndSignOffLater(key: key)
    }

    // MARK: Plex

    /// The Plex sign-in of this installation: same identity the Swift `PlexIdentity.thisDevice` made.
    func plexSignIn() throws -> PlexSignIn {
        let m = try fresh()
        #if os(iOS)
        let platform = "iOS"
        #elseif os(tvOS)
        let platform = "tvOS"
        #else
        let platform = "macOS"
        #endif
        return m.plexSignIn(
            clientId: AppModel.deviceID, appVersion: VersionNumber.outBundle, platform: platform,
            device: platform, deviceName: AppModel.deviceName)
    }

    /// The Plex client asks for another address (the network changed, a request did not get through):
    /// plex.tv's list, every address probed, the best that answers. Same answer as
    /// `PlexClient.standardResolver`, from the core.
    static func plexRoute(_ details: PlexSessionDetails) async throws -> PlexResolvedRoute {
        let route: PlexRouteInfo?
        // One log line with the time of the whole search (plex.tv's list and every probe): the first Plex load of a
        // session waits for it, and nothing else showed where the seconds went.
        let began = Date()
        do {
            route = try await shared.plexSignIn().bestRoute(
                accountToken: details.accountToken, machineIdentifier: details.machineIdentifier, remembered: nil)
        } catch {
            AppLog.writeOut("[Plex] Adresssuche fehlgeschlagen nach \(Int(Date().timeIntervalSince(began) * 1000)) ms")
            throw failure(error)
        }
        AppLog.writeOut("[Plex] Adresssuche \(Int(Date().timeIntervalSince(began) * 1000)) ms · "
            + (route.map { "\($0.isLocal ? "lokal" : $0.isRelay ? "Relay" : "extern")" } ?? "keine Antwort"))
        guard let route, let uri = URL(string: route.uri) else { throw PlexError.serverUnreachable }
        return PlexResolvedRoute(
            connection: PlexChosenConnection(
                machineIdentifier: details.machineIdentifier, uri: uri, isLocal: route.isLocal,
                isRelay: route.isRelay),
            token: route.token)
    }

    /// The resolver the Plex client gets (`MediaServerFactory`).
    nonisolated static let plexResolver: PlexClient.Resolver = { details in
        try await AccountsHost.plexRoute(details)
    }

    /// A Plex client moved to another address: keeps it in the saved account.
    func plexMoved(key: String, address: URL, token: String, local: Bool, relay: Bool) {
        guard let m = try? fresh() else { return }
        _ = m.movePlexRoute(
            key: key, route: PlexRouteInfo(uri: address.absoluteString, isLocal: local, isRelay: relay, token: token))
    }
}

/// Hears the seconds left of the Plex code.
final class PlexRest: PlexPinListener {
    private let handler: @Sendable (Int64) -> Void
    init(_ handler: @escaping @Sendable (Int64) -> Void) { self.handler = handler }
    func rest(seconds: Int64) { handler(seconds) }
}
