import Foundation

/// **A library or collection the user pulled onto the home page as its own row.**
///
/// Both ID **and name** are remembered: collections are not in the server's
/// library list, and the settings page should be able to name the row even
/// when the server is not answering.
public struct StartLibrary: Codable, Sendable, Equatable, Identifiable {
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case collection = "sammlung"
    }
    public let id: String
    public let name: String
    /// A collection (`BoxSet`) instead of a library. It is not queried
    /// recursively (`ShelfSource`) and opens its own page.
    public let collection: Bool
    public init(id: String, name: String, collection: Bool = false) {
        self.id = id
        self.name = name
        self.collection = collection
    }

    /// From what the picker shows.
    public init(_ item: Item) {
        self.init(id: item.id, name: item.name, collection: item.type == "BoxSet")
    }

    /// The entry as an item, for the page the row header opens.
    public var item: Item {
        Item(id: id, name: name, type: collection ? "BoxSet" : "CollectionFolder")
    }
}

/// **How the chosen library rows are read, supplemented and saved.**
///
/// The choice belongs to a server (the IDs do), not to the device. An ID that
/// no longer exists there or is not accessible to the profile stays in the
/// choice and just yields no row (`HomeLoader.libraryRails`): if the
/// library returns, so does the row.
public enum StartLibraries {

    /// Each ID once, in order of first appearance.
    public static func clean(_ choice: [StartLibrary]) -> [StartLibrary] {
        var watched = Set<String>()
        return choice.filter { !$0.id.isEmpty && watched.insert($0.id).inserted }
    }

    /// Reads a stored choice. **Never throws:** if something is missing or the
    /// storage is damaged, "no rows" applies and the home page stays as it was.
    /// Each entry is read separately so one broken entry does not take the whole
    /// choice with it.
    public static func read(_ data: Data?) -> [StartLibrary] {
        guard let data,
              let raw = try? JSONDecoder().decode([Record].self, from: data) else { return [] }
        return clean(raw.compactMap { e in
            guard let id = e.id else { return nil }
            return StartLibrary(id: id, name: e.name ?? "", collection: e.collection ?? false)
        })
    }

    public static func data(_ choice: [StartLibrary]) -> Data? {
        try? JSONEncoder().encode(clean(choice))
    }

    private struct Record: Decodable {
        let id: String?
        let name: String?
        let collection: Bool?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            collection = try c.decodeIfPresent(Bool.self, forKey: .collection)
        }
        enum Keys: String, CodingKey { case id, name, collection = "sammlung" }
    }

    /// Whether a library has titles to show; music, playlists and live TV carry no
    /// poster row.
    public static func selectable(_ library: Item) -> Bool {
        switch library.collectionType?.lowercased() {
        case "music", "playlists", "livetv", "books": false
        default: true
        }
    }

    /// What is available to pick: the server's libraries and the collections,
    /// without what is already chosen.
    public static func pick(libraries: [Item], collections: [Item],
                               selected: [StartLibrary]) -> [Item] {
        let already = Set(selected.map(\.id))
        return ListRules.withoutDouble(libraries + collections).filter { !already.contains($0.id) }
    }
}
