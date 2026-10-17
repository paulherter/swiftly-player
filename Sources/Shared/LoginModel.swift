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
        guard let client else { return [] }
        return (try? await client.publicUser()) ?? []
    }

    /// Building the address is pure computation, but the client is an actor, so
    /// asynchronous, and the result is taken along when the list loads instead of being
    /// asked again on every draw.
    func imageAddresses(_ folks: [PublicUser]) async -> [String: URL] {
        guard let client else { return [:] }
        var card: [String: URL] = [:]
        for person in folks {
            if let u = await client.userImage(person) { card[person.id] = u }
        }
        return card
    }

    // MARK: - Quick Connect as a sign-in path

    func quickConnectStart() async throws -> LoginCode {
        guard let client else { throw JellyfinError.notAuthenticated }
        return try await client.quickConnectStart()
    }

    /// A poll that never throws; see `QuickConnectWait` in the package.
    func quickConnectAskAgain(_ preGait: LoginCode) async -> QuickConnectState {
        guard let client else { return .failed }
        return await client.quickConnectAskAgain(preGait)
    }

    func signInWithQuickConnect(_ preGait: LoginCode) async {
        // For "Add another account" on a fresh client; see `loginClient()`.
        guard let signInClient = loginClient() else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        do {
            let s = try await signInClient.signInWithQuickConnect(preGait)
            // **Do not load additionally if it was a switch.** Then `sessionAdopt`
            // already cleans up and triggers the reload; a second run alongside races the
            // first, and whoever loses writes something half-finished.
            if !sessionAdopt(s, signedInWith: signInClient) { await loadViews() }
        } catch {
            errorMessage = readable(error)
        }
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
