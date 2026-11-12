import Foundation
import OSLog
import JellyfinKit

/// What the sign-in screen knows about the last server.
struct ServerReminder: Codable, Equatable {
    enum CodingKeys: String, CodingKey {
        case address = "adresse"
        case name
        case version
    }
    let address: String
    let name: String
    let version: String
}

extension AppModel {

    // MARK: - Last connected

    private static let lastServerKey = "letzterServer"

    /// The second time nobody types the address again.
    var lastServer: ServerReminder? {
        guard let raw = UserDefaults.standard.data(forKey: Self.lastServerKey) else {
            return nil
        }
        return try? JSONDecoder().decode(ServerReminder.self, from: raw)
    }

    /// Only the host name, without scheme, the way you would tell someone.
    ///
    /// From the stored value and not from the client: that is an actor, and a line of
    /// text is not worth a hop across the actor boundary.
    var serverAddress: String? { lastServer?.address }

    func serverRemember(address: String, name: String, version: String) {
        let e = ServerReminder(address: address, name: name, version: version)
        guard let raw = try? JSONEncoder().encode(e) else { return }
        UserDefaults.standard.set(raw, forKey: Self.lastServerKey)
    }

    // MARK: - Custom headers (Issue #4)

    /// One entry for all servers: the whole table from ``OwnHeaders``.
    private static let headersKey = "eigenkoepfe"

    /// At launch, before the first request.
    static func ownHeadersLoad() {
        OwnHeaders.load(Keychain.load(key: headersKey))
    }

    /// What is registered for a server, for "Advanced".
    func ownHeaders(for server: URL?) -> [OwnHeader] {
        server.map(OwnHeaders.registered(for:)) ?? []
    }

    /// Set and store. An empty list removes the server.
    ///
    /// **In the keychain, not in the settings**: the values are credentials like the
    /// header itself. Only the names go to the log.
    func ownHeadersSafe(_ headers: [OwnHeader], for server: URL) {
        OwnHeaders.setDown(headers, for: server)
        let panel = OwnHeaders.store()
        if panel == Data("{}".utf8) {
            Keychain.delete(key: Self.headersKey)
        } else {
            try? Keychain.save(panel, key: Self.headersKey)
        }
        let names = OwnHeaders.names(OwnHeaders.registered(for: server))
        Self.log.info("Eigene Header gesichert: \(names, privacy: .public)")
    }

    // MARK: - Who is watching

    /// Empty does not mean "error" here but "the server does not give the list"; then you just type the name.
    func publicUser() async -> [PublicUser] {
        guard let client, client is any QuickSignIn else { return [] }
        let found = await AccountsHost.shared.publicUsers(address: client.baseURL)
        userImages = found.images
        return found.users
    }

    /// The image addresses came with the list; the core builds them.
    func imageAddresses(_ folks: [PublicUser]) async -> [String: URL] {
        userImages.filter { key, _ in folks.contains { $0.id == key } }
    }

    // MARK: - Quick Connect as a sign-in path

    /// Whether the server has Quick Connect switched on; a page that offers only what
    /// works asks before showing the button. Only Jellyfin has it at all.
    func quickConnectOffered() async -> Bool {
        #if DEBUG
        if Self.snapshotQuickConnect { return true }
        #endif
        guard let client = client as? JellyfinClient else { return false }
        return await AccountsHost.shared.quickConnectOffered(address: client.baseURL)
    }

    func quickConnectStart() async throws -> LoginCode {
        guard let client, client is any QuickSignIn else { throw JellyfinError.notAuthenticated }
        return try await AccountsHost.shared.quickStart(address: client.baseURL)
    }

    /// How a wait for approval ended: the core signs in itself when the code is approved.
    enum QuickConnectOutcome {
        case approved
        case ended(String)
        case stopped
        case failed(String)
    }

    /// Waits for the approval of `preGait` (at the server being added, or the one the app is connected
    /// to). `rest` hears the seconds left. On `.approved` the account is saved; the view then calls
    /// ``signInWithQuickConnect(_:)`` (or the new-server twin) to take it over.
    func quickConnectWait(_ preGait: LoginCode, atNewServer: Bool,
                          rest: @escaping @Sendable (Int64) -> Void) async -> QuickConnectOutcome {
        guard let server = atNewServer ? onboardingServer : client else { return .failed(readable(JellyfinError.notAuthenticated)) }
        do {
            switch try await AccountsHost.shared.quickWait(address: server.baseURL, code: preGait, rest: rest) {
            case .approved: return .approved
            case .ended(let text): return .ended(text)
            case .stopped: return .stopped
            }
        } catch {
            return .failed(readable(error))
        }
    }

    /// The core signed in when the code was approved (`quickConnectWait`): takes the account over.
    func signInWithQuickConnect(_ preGait: LoginCode) async {
        errorMessage = nil
        adoptSignedIn()
    }

    /// Errors the way you would tell someone.
    ///
    /// **Now lives in the package** (``readableError(_:)``). It hung on
    /// `String(localized:)` with the app catalog and was unreachable for the Linux
    /// version, where every failed sign-in showed the raw `error.localizedDescription`,
    /// which violates D3.
    func readable(_ error: any Error) -> String { readableError(error) }
}

/// A row in "Advanced": name and value of a custom header.
///
/// **Its own identity, not the index.** Whoever removes the second of three rows
/// should not watch the third's value slide into the second while still typing.
struct HeaderRow: Identifiable, Equatable {
    let id = UUID()
    var name = ""
    var value = ""

    /// Swiftly sets this one itself: the row says so instead of silently doing nothing.
    var locked: Bool { OwnHeaders.isLocked(name) }

    static func from(_ headers: [OwnHeader]) -> [HeaderRow] {
        headers.map { HeaderRow(name: $0.name, value: $0.value) }
    }
}

extension Array where Element == HeaderRow {
    /// What of this may go out, through the same gate as everywhere.
    var headers: [OwnHeader] {
        OwnHeaders.cleaned(map { OwnHeader(name: $0.name, value: $0.value) })
    }
}
