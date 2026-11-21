import Foundation

/// **Which saved accounts are leftovers of fixture runs, and the backup written before they go.**
///
/// Debug proof runs sign a made-up account in at a server on this very machine (`127.0.0.1:<port>`). An account whose
/// server address is on the local machine is such a leftover; every other address (a real server, a LAN address, a
/// Plex relay) is never selected. Pure functions, so the rule is tested without a Keychain.
public enum FixtureAccountPrune {

    /// Whether the address points at this machine (`127.0.0.1`, `localhost`, `::1`, any port).
    public static func isLocal(_ url: URL) -> Bool {
        guard let host = url.host(percentEncoded: false)?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
    }

    /// The accounts to remove: only those whose server is on this machine.
    public static func selection(from accounts: [Session]) -> [Session] {
        accounts.filter { isLocal($0.serverURL) }
    }

    /// One account in the backup: no token, no password.
    public struct Entry: Codable, Equatable, Sendable {
        public let accountKey: String
        public let serverURL: String
        public let userName: String
        public let kind: String
        public let remove: Bool
    }

    /// The backup file's content: every account found, marked when it is going to be removed.
    public static func backup(of accounts: [Session], at date: Date = Date()) throws -> Data {
        let marked = Set(selection(from: accounts).map(\.accountKey))
        let entries = accounts.map {
            Entry(accountKey: $0.accountKey, serverURL: $0.serverURL.absoluteString, userName: $0.userName,
                  kind: $0.kind.rawValue, remove: marked.contains($0.accountKey))
        }
        struct File: Encodable { let created: Date; let accounts: [Entry] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(File(created: date, accounts: entries))
    }
}
