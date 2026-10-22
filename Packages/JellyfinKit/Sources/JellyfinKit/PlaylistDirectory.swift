import Foundation

/// A Jellyfin playlist (`Playlist`) that holds video, with what it contains.
public struct VideoPlaylist: Sendable, Equatable, Identifiable {
    public let item: Item
    public let movies: Int
    public let episodes: Int

    public var id: String { item.id }

    public init(item: Item, members: [Item]) {
        self.item = item
        movies = members.filter { $0.type == "Movie" }.count
        episodes = members.filter { $0.type == "Episode" || $0.type == "Series" }.count
    }

    /// How many entries count in this section.
    ///
    /// - Parameter art: `movies` or `tvshows`.
    public func count(art: String) -> Int {
        switch art.lowercased() {
        case "movies":  movies
        case "tvshows": episodes
        default:        0
        }
    }

    /// Whether the list is video at all. Music playlists carry `Audio`; a server that
    /// leaves `MediaType` out of the answer is not trusted either way, then the
    /// members decide.
    /// An entry that can be shown and played here; songs in a mixed list drop out.
    static func isVideoEntry(_ entry: Item) -> Bool {
        switch entry.type {
        case "Movie", "Episode", "Series", "Video", "MusicVideo": true
        default: entry.mediaType == "Video"
        }
    }

    static func isVideo(_ playlist: Item) -> Bool {
        playlist.type == "Playlist" && (playlist.mediaType == nil || playlist.mediaType == "Video")
    }
}

/// **The video playlists of an account.**
///
/// Playlists are not a library and not a collection: they sit in the same menu as
/// collections, only when the account has any. A playlist appears under Movies if it
/// holds a movie, under Series if it holds an episode; a mixed one in both.
/// Music playlists never appear.
public struct PlaylistDirectory: Sendable, Equatable {
    public let all: [VideoPlaylist]

    public init(_ all: [VideoPlaylist]) { self.all = all }

    public static let empty = PlaylistDirectory([])

    /// The playlists with entries of this section, in server order.
    public func playlists(art: String) -> [VideoPlaylist] {
        all.filter { $0.count(art: art) > 0 }
    }
}

public extension JellyfinClient {

    /// Fetches the video playlists of the account, each with its entry types.
    ///
    /// One query for the list, one lean query per playlist (no images, no user
    /// data), at most six at once. If one fails, everything fails, as with
    /// ``collectionDirectory(viewList:)``: a partial list would look complete.
    func playlistDirectory() async throws -> PlaylistDirectory {
        let found = try await items(limit: 500, recursive: true,
                                    includeItemTypes: ["Playlist"]).items
            .filter(VideoPlaylist.isVideo)
        var members: [String: [Item]] = [:]
        try await withThrowingTaskGroup(of: (String, [Item]).self) { group in
            var rest = found.makeIterator()
            for _ in 0..<6 {
                guard let list = rest.next() else { break }
                group.addTask { (list.id, try await self.playlistEntries(list.id, lean: true)) }
            }
            while let (id, entries) = try await group.next() {
                members[id] = entries
                if let list = rest.next() {
                    group.addTask { (list.id, try await self.playlistEntries(list.id, lean: true)) }
                }
            }
        }
        return PlaylistDirectory(found.map { VideoPlaylist(item: $0, members: members[$0.id] ?? []) })
    }
}
