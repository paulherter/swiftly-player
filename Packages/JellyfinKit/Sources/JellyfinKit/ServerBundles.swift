import Foundation

/// **One bundle of accounts per kind of server, and which kind is current.**
///
/// The Jellyfin bundle is the `AccountBundle` that was always stored as `konten`, byte for
/// byte. Emby and Plex get their own (`konten.emby`, `konten.plex`) instead of sharing
/// one list, so that an older app version that only knows `konten` never meets an
/// account it would treat as Jellyfin. This type only holds and (de)serializes them;
/// where the bytes go (keychain on Apple, file elsewhere) is decided by the caller through
/// the closures of ``load(read:)`` and ``save(write:)``.
public struct ServerBundles: Sendable, Equatable {

    /// Where the pointer to the current kind is kept.
    public static let pointerKey = "aktiveArt"

    public private(set) var bundles: [ServerKind: AccountBundle]
    public private(set) var activeKind: ServerKind

    public init(bundles: [ServerKind: AccountBundle] = [:], activeKind: ServerKind = .jellyfin) {
        self.bundles = bundles
        self.activeKind = bundles[activeKind] != nil ? activeKind : Self.firstKind(in: bundles) ?? activeKind
    }

    /// The bundle of the current kind, if the user is signed in with it.
    public var active: AccountBundle? { bundles[activeKind] }

    public func bundle(for kind: ServerKind) -> AccountBundle? { bundles[kind] }

    /// Kinds that have accounts, in the fixed order of ``ServerKind``.
    public var kinds: [ServerKind] { ServerKind.allCases.filter { bundles[$0] != nil } }

    /// Replaces (or with `nil` removes) the bundle of one kind. If the current kind loses
    /// its bundle, another kind with accounts takes over.
    public mutating func set(_ bundle: AccountBundle?, for kind: ServerKind) {
        bundles[kind] = bundle
        if bundles[activeKind] == nil, let other = Self.firstKind(in: bundles) { activeKind = other }
    }

    /// Makes a kind current; ignored when it has no bundle.
    public mutating func switchTo(_ kind: ServerKind) {
        if bundles[kind] != nil { activeKind = kind }
    }

    private static func firstKind(in bundles: [ServerKind: AccountBundle]) -> ServerKind? {
        ServerKind.allCases.first { bundles[$0] != nil }
    }

    // MARK: Storage

    /// - Parameter read: returns the stored bytes for a key, or `nil` if there are none.
    ///   An entry that cannot be decoded counts as missing.
    public static func load(read: (String) throws -> Data?) rethrows -> ServerBundles {
        var found: [ServerKind: AccountBundle] = [:]
        for kind in ServerKind.allCases {
            if let data = try read(kind.bundleStorageKey),
               let bundle = try? JSONDecoder().decode(AccountBundle.self, from: data) {
                found[kind] = bundle
            }
        }
        let pointer = try read(pointerKey)
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap(ServerKind.init(rawValue:))
        return ServerBundles(bundles: found, activeKind: pointer ?? .jellyfin)
    }

    /// Writes every kind (`nil` data removes the entry) and the pointer.
    public func save(write: (String, Data?) throws -> Void) throws {
        for kind in ServerKind.allCases {
            try write(kind.bundleStorageKey, try bundles[kind].map { try JSONEncoder().encode($0) })
        }
        try write(Self.pointerKey, bundles.isEmpty ? nil : Data(activeKind.rawValue.utf8))
    }
}
