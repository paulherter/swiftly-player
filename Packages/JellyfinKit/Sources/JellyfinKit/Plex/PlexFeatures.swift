import Foundation

/// **What a Plex server gives the app**, in the vocabulary of ``ServerCapability``.
///
/// Left out on purpose: SyncPlay, Quick Connect, remote control, "play on another device"
/// and settings sync have no counterpart in the Plex client API we use (Plex Companion is
/// a different protocol and not planned), and there is no list of public users to pick
/// from. Trakt is in: it needs only the external ids, which come from `Guid` (see
/// ``PlexMapper/item(_:)``). Seerr is out: its sign-in is the media server's user name and
/// password (`/api/v1/auth/jellyfin`), and a Plex account has no such pair.
///
/// Some entries depend on the server, not on us: intro and credits markers exist only when
/// the server's owner has Plex Pass and the server has analysed the library; preview
/// pictures (``PlexBIF``) only when the server made them. When they are missing the lists
/// are simply empty, so nothing shows.
public enum PlexFeatures {

    public static let capabilities: Set<ServerCapability> = [
        .trickplay, .introSegments, .chapters, .collections, .playlists, .favorites,
        .markWatched, .similar, .extras, .genres, .downloads,
    ]

    /// The ones deliberately missing, for a test that keeps both lists complete.
    public static let missing: Set<ServerCapability> = Set(ServerCapability.allCases)
        .subtracting(capabilities)
}
