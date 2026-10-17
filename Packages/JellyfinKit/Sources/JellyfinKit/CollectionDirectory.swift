import Foundation

/// A Jellyfin collection (`BoxSet`) with the IDs of its movies and series.
public struct ItemCollection: Sendable, Equatable, Identifiable {
    public let item: Item
    public let movies: Set<String>
    public let seriesList: Set<String>

    public var id: String { item.id }

    public init(item: Item, members: [Item]) {
        self.item = item
        movies = Set(members.filter { $0.type == "Movie" }.map(\.id))
        seriesList = Set(members.filter { $0.type == "Series" }.map(\.id))
    }

    /// - Parameter art: `movies` or `tvshows`.
    public func count(art: String) -> Int {
        switch art.lowercased() {
        case "movies":  movies.count
        case "tvshows": seriesList.count
        default:        0
        }
    }

    public func contains(_ id: String) -> Bool {
        movies.contains(id) || seriesList.contains(id)
    }

    /// "3 movies" or "3 series" under a collection tile, defined once for all
    /// platforms.
    ///
    /// - Parameter art: `movies` or `tvshows`.
    public static func countText(art: String, count: Int) -> String {
        art.lowercased() == "tvshows" ? translated("\(count) Serien") : translated("\(count) Filme")
    }
}

/// **All collections of an account, including membership.**
///
/// **Why a directory and not one query per title.** Jellyfin 10 has no field
/// telling a movie which collection it belongs to. Jellyfin 12 adds
/// `GET /Items/{id}/Collections`, but that only answers where *one* title
/// belongs, not how many movies a collection has, which the menu needs (the
/// threshold); servers on 10.x lack it entirely. `ChildCount` does not help
/// either: it counts everything, including series in a movie collection.
///
/// So the collections are fetched once per account, with their members: one
/// query for the list, one lean query per collection (ID and type only, no
/// images). Both questions are then answered without more network calls:
/// which collections exist in a section, and which one a movie belongs to.
public struct CollectionDirectory: Sendable, Equatable {
    /// **A collection only counts from two titles in the section.** A collection
    /// with one movie is none. Jellyfin creates these automatically when a library
    /// has "automatically add movies to collections" and only part of the series is
    /// on disk.
    public static let threshold = 2

    public let all: [ItemCollection]

    public init(_ all: [ItemCollection]) { self.all = all }

    public static let empty = CollectionDirectory([])

    /// The collections in the section, in server order.
    public func collections(art: String) -> [ItemCollection] {
        all.filter { $0.count(art: art) >= Self.threshold }
    }

    /// The collections this title belongs to, only those that exist in the
    /// title's section. A movie collection with just this one movie would have no
    /// *other* titles to show.
    public func collections(with title: Item) -> [ItemCollection] {
        guard let art = LibraryGenre.art(toType: title.type) else { return [] }
        return collections(art: art).filter { $0.contains(title.id) }
    }

    /// **Has the user hidden collections in Jellyfin?**
    ///
    /// If the "Collections" folder (`CollectionType` `boxsets`) is removed from
    /// "My Media" in the profile's home settings, it no longer appears in
    /// `UserViews`, but does with `includeHidden`. Swiftly follows that choice
    /// without a setting of its own.
    ///
    /// **If the folder is missing from both lists, collections are shown anyway.**
    /// Some servers (seen on Jellyfin 12) never list the folder, even with
    /// `includeHidden`, although collections exist. Whether any exist is therefore
    /// decided by the `BoxSet` query, not by the views list.
    public static func hidden(visible: [Item], withHidden: [Item]) -> Bool {
        func folder(_ list: [Item]) -> Bool {
            list.contains { $0.collectionType?.lowercased() == "boxsets" }
        }
        return folder(withHidden) && !folder(visible)
    }
}

public extension JellyfinClient {

    /// Fetches all collections with their members.
    ///
    /// At most six queries at once; a small server cannot take more without
    /// strain, and with twenty collections that is about a second. If one fails,
    /// everything fails: a partial directory would look complete and nobody would
    /// notice.
    ///
    /// - Parameter ansichten: The views including hidden ones. If the recursive
    ///   search returns nothing, the "Collections" folder is searched, if present;
    ///   Jellyfin does not attach collections to the tree that the recursive
    ///   search walks on every server.
    func collectionDirectory(viewList: [Item] = []) async throws -> CollectionDirectory {
        var crates = try await items(limit: 2000, recursive: true,
                                     includeItemTypes: ["BoxSet"]).items
        if crates.isEmpty,
           let folder = viewList.first(where: { $0.collectionType?.lowercased() == "boxsets" }) {
            crates = try await items(parentID: folder.id, limit: 2000,
                                     includeItemTypes: ["BoxSet"]).items
        }
        var members: [String: [Item]] = [:]
        try await withThrowingTaskGroup(of: (String, [Item]).self) { group in
            var rest = crates.makeIterator()
            for _ in 0..<6 {
                guard let container = rest.next() else { break }
                group.addTask { (container.id, try await self.collectionMembers(container.id)) }
            }
            while let (id, list) = try await group.next() {
                members[id] = list
                if let container = rest.next() {
                    group.addTask { (container.id, try await self.collectionMembers(container.id)) }
                }
            }
        }
        return CollectionDirectory(crates.map {
            ItemCollection(item: $0, members: members[$0.id] ?? [])
        })
    }

    /// Movies and series per library that can contain both.
    ///
    /// Two count queries per such library; pure movie or series libraries cost
    /// nothing. A library that does not answer is missing, so it is (for now) in
    /// no section.
    func libraryShares(views: [Item]) async -> [String: LibraryShare] {
        let mixed = views.filter { LibraryGenre.canBeMixed($0.collectionType) }
        var result: [String: LibraryShare] = [:]
        await withTaskGroup(of: (String, LibraryShare?).self) { group in
            for view in mixed {
                group.addTask {
                    async let movies = self.count(parentID: view.id, types: ["Movie"])
                    async let seriesList = self.count(parentID: view.id, types: ["Series"])
                    guard let f = try? await movies, let s = try? await seriesList
                    else { return (view.id, nil) }
                    return (view.id, LibraryShare(movies: f, seriesList: s))
                }
            }
            for await (id, share) in group {
                if let share { result[id] = share }
            }
        }
        return result
    }
}
