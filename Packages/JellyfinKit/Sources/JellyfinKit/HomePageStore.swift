import Foundation

/// **The home page from last time, so something is on screen at launch.**
///
/// On a cold start the home page was empty until libraries and rows were back from the
/// server (about half a second in the tvOS simulator, more on a slow connection). Infuse
/// shows the last state and refreshes it; this does the same.
///
/// **Only a preview, never the truth.** The stored state is shown until the server's answer
/// arrives and then replaced (same rule as refreshing, `HomeModel.adopt`). A
/// store belongs to exactly one account (``fileName(account:)``).
///
/// This file defines **what** is stored and how it is read; **where** it lives is up to the
/// app.
public struct HomeStore: Codable, Sendable, Equatable {
    enum CodingKeys: String, CodingKey {
        case version = "fassung"
        case libraries = "bibliotheken"
        case continueWatching = "weiterschauen"
        case nextEpisode = "naechsteFolge"
        case recent = "zuletzt"
        case newMovies = "neueFilme"
        case newSeries = "neueSerien"
        case genreRails = "gattungsreihen"
    }
    /// Increases when the shape changes; an older store is then discarded instead of
    /// misread.
    public static let currentVersion = 1

    public struct Rail: Codable, Sendable, Equatable {
        public let name: String
        public let items: [Item]
        public init(name: String, items: [Item]) {
            self.name = name
            self.items = items
        }
    }

    public var version: Int
    public var libraries: [Item]
    public var continueWatching: [Item]
    public var nextEpisode: [Item]
    public var recent: [Item]
    public var newMovies: [Item]
    public var newSeries: [Item]
    public var genreRails: [Rail]

    public init(libraries: [Item], continueWatching: [Item], nextEpisode: [Item],
                recent: [Item], newMovies: [Item], newSeries: [Item],
                genreRails: [Rail]) {
        version = Self.currentVersion
        self.libraries = libraries
        self.continueWatching = continueWatching
        self.nextEpisode = nextEpisode
        self.recent = recent
        self.newMovies = newMovies
        self.newSeries = newSeries
        self.genreRails = genreRails
    }

    /// Nothing worth showing.
    public var empty: Bool {
        continueWatching.isEmpty && nextEpisode.isEmpty && recent.isEmpty
            && newMovies.isEmpty && newSeries.isEmpty
            && genreRails.allSatisfy { $0.items.isEmpty }
    }

    public func data() throws -> Data { try JSONEncoder().encode(self) }

    /// `nil` for anything that is not exactly this version, including a half-written file.
    /// A preview that does not fit is not shown.
    public static func read(_ data: Data) -> HomeStore? {
        guard let store = try? JSONDecoder().decode(HomeStore.self, from: data),
              store.version == currentVersion, !store.empty else { return nil }
        return store
    }

    /// A stable file name per account (FNV-1a, 64 bit). The account key contains the server
    /// address and user ID and does not belong in a file name.
    public static func fileName(account: String) -> String {
        var value: UInt64 = 0xcbf29ce484222325
        for byte in account.utf8 {
            value ^= UInt64(byte)
            value &*= 0x100000001b3
        }
        return "startseite-" + String(value, radix: 16) + ".json"
    }
}
