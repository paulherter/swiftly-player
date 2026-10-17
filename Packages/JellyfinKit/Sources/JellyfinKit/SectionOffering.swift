import Foundation

// MARK: - What the title menu of a section contains

/// A choice in the menu on the title of "Movies" or "Series".
///
/// **Collections are not a library.** They therefore sit directly under "All",
/// not at the end of the library list: they are another view of the same
/// holdings, not another folder on disk.
public enum SectionSelection: Hashable, Sendable, Identifiable {
    /// Every title of this kind from every library. The default.
    case all
    /// The collections (Jellyfin: `BoxSet`) with titles of this kind.
    case collections
    /// A single library, by its ID.
    case library(String)

    public var id: String { rememberValue }

    /// How the choice is persisted.
    ///
    /// **Under the same name the library had before**: someone who picked one of
    /// two movie libraries before the rework stays there, because its ID is exactly
    /// this value.
    public var rememberValue: String {
        switch self {
        case .all:               "alle"
        case .collections:         "sammlungen"
        case .library(let id): id
        }
    }

    public init(rememberValue: String?) {
        switch rememberValue {
        case nil, "", "alle": self = .all
        case "sammlungen":    self = .collections
        case let id?:         self = .library(id)
        }
    }
}

/// How many movies and series a library holds that can contain both.
public struct LibraryShare: Sendable, Equatable {
    public var movies: Int
    public var seriesList: Int

    public init(movies: Int, seriesList: Int) {
        self.movies = movies
        self.seriesList = seriesList
    }

    /// - Parameter art: `movies` or `tvshows`.
    public func count(art: String) -> Int {
        switch art.lowercased() {
        case "movies":  movies
        case "tvshows": seriesList
        default:        0
        }
    }
}

/// **What the title of a section offers to choose**, and whether it is a menu
/// at all.
///
/// The rule: *the title becomes a menu as soon as there is more than one thing
/// to choose.* Someone with one movie library, one series library and no
/// collections therefore sees exactly what they saw before: no chevron, no tap
/// target.
///
/// Order in the menu: "All", then "Collections", then under the heading
/// "Libraries" the single libraries in the server's order (it comes from the
/// account's `OrderedViews`; `UserViews` returns it that way).
public struct SectionOffering: Sendable, Equatable {
    /// `movies` or `tvshows`.
    public let art: String
    /// Every library with titles of this kind, even a single one.
    public let libraries: [Item]
    /// How many collections, from the threshold up, are in this section.
    public let collections: Int

    public init(art: String, libraries: [Item], collections: Int) {
        self.art = art
        self.libraries = libraries
        self.collections = collections
    }

    /// **A single library is not a choice.** It showed the same as "All": two
    /// entries, one content.
    public var showsLibraries: Bool { libraries.count > 1 }
    public var showsCollections: Bool { collections > 0 }
    public var isMenu: Bool { showsLibraries || showsCollections }

    public var entries: [SectionSelection] {
        var list: [SectionSelection] = [.all]
        if showsCollections { list.append(.collections) }
        if showsLibraries { list += libraries.map { .library($0.id) } }
        return list
    }

    /// Before which entry the divider and the "Libraries" heading go: before the
    /// first library, if the menu has any.
    public var firstLibrary: SectionSelection? {
        showsLibraries ? libraries.first.map { .library($0.id) } : nil
    }

    public func library(_ id: String) -> Item? {
        libraries.first { $0.id == id }
    }

    /// The remembered choice if it still exists, otherwise "All".
    ///
    /// If a library disappears or someone hides the collections in Jellyfin, the
    /// page silently falls back to "All" instead of standing empty.
    public func choice(remembered: String?) -> SectionSelection {
        let wish = SectionSelection(rememberValue: remembered)
        return entries.contains(wish) ? wish : .all
    }

    /// **What "All" reads from: the libraries of this kind, not the mixed ones.**
    ///
    /// Jellyfin lists loose video files in a mixed library as `Movie`: in one test
    /// library 13 "movies" were episodes with `S01E01` in the name. A kind the
    /// server assigns this way cannot be sorted afterwards. So a mixed library
    /// counts toward "All" only if the section has no library of its own; it stays
    /// selectable in the menu with its share.
    public var allSources: [String] {
        let ownOnes = libraries.filter { $0.collectionType?.lowercased() == art.lowercased() }
        return (ownOnes.isEmpty ? libraries : ownOnes).map(\.id)
    }

    /// The one library, if "All" reads from only one; the query is then the same as
    /// before the rework. Otherwise `nil`: from several, via ``TitleFilter``.
    public var allOut: String? {
        allSources.count == 1 ? allSources[0] : nil
    }

    /// Whether there is anything to show in this section at all.
    public var hasInventory: Bool { !libraries.isEmpty }

    /// - Parameters:
    ///   - views: The account's libraries (`UserViews`). Whatever the user hid
    ///     under "My Media" in Jellyfin is already missing.
    ///   - anteile: Movies and series per mixed library. If one is missing, it
    ///     appears nowhere (yet).
    ///   - verzeichnis: The collections, `nil` while unknown.
    public static func compose(art: String, views: [Item],
                              shares: [String: LibraryShare],
                              directory: CollectionDirectory?) -> SectionOffering {
        let matching = views.filter { belongs($0, toward: art, shares: shares) }
        return SectionOffering(art: art, libraries: matching,
                               collections: directory?.collections(art: art).count ?? 0)
    }

    /// **A mixed library appears in both sections**: under Movies with its
    /// movies, under Series with its series. But only where it has something;
    /// there are no empty entries.
    static func belongs(_ view: Item, toward art: String,
                        shares: [String: LibraryShare]) -> Bool {
        let type = view.collectionType?.lowercased()
        if type == art.lowercased() { return true }
        guard LibraryGenre.canBeMixed(type) else { return false }
        return (shares[view.id]?.count(art: art) ?? 0) > 0
    }
}

extension LibraryGenre {

    /// Whether a library of this kind can hold movies **and** series.
    ///
    /// **No special cases.** Libraries are taken as the server has them: for
    /// anything that does not clearly carry just one kind, items are counted and
    /// the number decides. A home-video library has videos for Jellyfin, not
    /// movies, so it drops out by itself without anyone spelling "home videos".
    public static func canBeMixed(_ art: String?) -> Bool {
        let unambiguous: Set<String> = ["movies", "tvshows", "music", "musicvideos",
                                      "books", "photos", "livetv", "playlists",
                                      "boxsets", "trailers"]
        guard let art = art?.lowercased() else { return true }
        return !unambiguous.contains(art)
    }

    /// Which section belongs to a title kind: `Movie` -> `movies`.
    public static func art(toType type: String?) -> String? {
        switch type {
        case "Movie":  "movies"
        case "Series": "tvshows"
        default:       nil
        }
    }
}

// MARK: - What a grid page reads from

/// **Where a library or collection page gets its titles.**
///
/// Three sources, one page: a library, "All" (without `ParentId`, across all
/// libraries) and a collection. The differences live here and not in the view
/// so Mac, TV and Android issue the same queries.
public struct ShelfSource: Equatable, Sendable {
    /// Library or collection. `nil` means: from several libraries.
    public let parent: String?
    /// Without `parent`: from exactly these libraries. Without `ParentId` Jellyfin
    /// queries **all** libraries of the account, including those hidden under
    /// "My Media" and the mixed ones; whatever does not come from here is
    /// filtered out by ``TitleFilter``.
    public let onlyOut: [String]
    /// The section, `movies` or `tvshows`. Determines the kind.
    public let art: String?
    public let collection: Bool

    public init(parent: String?, art: String?, collection: Bool = false, onlyOut: [String] = []) {
        self.parent = parent
        self.art = art
        self.collection = collection
        self.onlyOut = onlyOut
    }

    /// From several libraries, so filtered: each title once, and only what comes
    /// from `onlyOut`.
    public var isFiltering: Bool { parent == nil && !onlyOut.isEmpty }

    public var types: [String] { LibraryGenre.types(toward: art) }

    /// **A collection is not queried recursively.** Its titles are linked, not
    /// filed; the first level is exactly the content. Recursively, a collection
    /// with series would bring every season and episode, which the kind filter
    /// would have to sort out again.
    ///
    /// "All", by contrast, must query recursively, otherwise Jellyfin without
    /// `ParentId` returns only the top-level folders.
    public var recursive: Bool {
        if collection { return false }
        if parent == nil { return true }
        return LibraryGenre.recursive(toward: art)
    }

    /// **In a collection the year ascends**, so a series of films appears in order,
    /// part 1 before part 2. Everywhere else the sort direction applies.
    public func bearing(_ sorting: Sorting) -> String {
        collection && sorting == .erscheinung ? "Ascending" : sorting.bearing
    }

    /// What it was loaded for; if that changes, it is replaced instead of refreshed.
    public var key: String {
        "\(parent ?? onlyOut.joined(separator: "+"))|\(art ?? "")|\(collection ? "s" : "b")"
    }
}

// MARK: - From several libraries, each title once

/// **"All movies" looks like a library, not like their sum.**
///
/// Measured on a test server: three libraries are hardlinks to the same files,
/// and Jellyfin lists each film there with its own ID. Without `ParentId` 20
/// films came back, 16 of them distinct, and 13 from the mixed library.
///
/// The server sorts and pages (one query without `ParentId`); the filter lets
/// exactly one entry per work through (``Items``, the same rule as on the home
/// page and in search). **Which one is decided beforehand**: the one from the
/// library that comes first in the account's order, not the one the sort
/// happens to bring first. Without provider IDs nothing is merged.
///
/// The response does not say which library an item comes from, so the page
/// first fetches the IDs of the chosen libraries (``allowed``), lean and with
/// the same filters. The count is also known from that.
public struct TitleFilter: Sendable {
    private let allowed: Set<String>
    /// How many distinct titles there are.
    public let total: Int
    private var watched = Set<String>()

    /// - Parameter je: Per chosen library, **in the account's order**, everything
    ///   from it, with kind and provider IDs.
    public init(je libraries: [(library: String, identifiers: [Item])]) {
        var origin: [String: String] = [:]
        for (from, list) in libraries { for i in list { origin[i.id] = from } }
        let mediaWorks = Items.merge(libraries.flatMap(\.identifiers), origin: origin,
                                         libraries: libraries.map { Item(id: $0.library, name: "") })
        allowed = Set(mediaWorks.map(\.id))
        total = mediaWorks.count
    }

    /// Everything from a list; of duplicates the first stays.
    public init(identifiers: [Item]) {
        self.init(je: [("", identifiers)])
    }

    /// What remains of a page, in its order.
    public mutating func seven(_ page: [Item]) -> [Item] {
        page.filter { allowed.contains($0.id) && watched.insert($0.id).inserted }
    }

    /// From the start, when reloading the first page.
    public mutating func fromFront() { watched = [] }
}

public extension JellyfinClient {

    /// **The filter for "All"**: the IDs of every chosen library, fetched side by
    /// side, in the order of `source.onlyOut`. The order decides which copy of a
    /// work stays. With the same filters as the page.
    func titleFilter(_ source: ShelfSource, filters: [String] = [],
                   isWatched: Bool? = nil) async throws -> TitleFilter {
        let types = source.types
        let fetched = try await withThrowingTaskGroup(of: (Int, [Item]).self) { group in
            for (spot, id) in source.onlyOut.enumerated() {
                group.addTask {
                    (spot, try await self.titleIds(parentID: id, types: types,
                                                           filters: filters, isWatched: isWatched))
                }
            }
            var je: [Int: [Item]] = [:]
            for try await (spot, list) in group { je[spot] = list }
            return je
        }
        return TitleFilter(je: source.onlyOut.enumerated().map { ($1, fetched[$0] ?? []) })
    }
}
