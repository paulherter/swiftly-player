import Foundation

/// The kind of a title in terms the interface can switch over, instead of the server's
/// strings. `Item.type` stays as it came; ``Item/kind`` is computed from it, so the model
/// and everything stored with it stay as they are.
public enum ItemKind: Sendable, Equatable {
    case movie
    case series
    case season
    case episode
    case collection
    case playlist
    /// Libraries and plain folders.
    case folder
    case other

    public init(type: String?) {
        switch type {
        case "Movie": self = .movie
        case "Series": self = .series
        case "Season": self = .season
        case "Episode": self = .episode
        case "BoxSet": self = .collection
        case "Playlist": self = .playlist
        case "CollectionFolder", "UserView", "Folder": self = .folder
        default: self = .other
        }
    }
}

public extension Item {
    var kind: ItemKind { ItemKind(type: type) }
}
