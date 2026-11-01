import Foundation

/// **Where Emby differs from Jellyfin in the request paths** (measured against Emby 4.10.2).
///
/// ``JellyfinClient`` speaks the Jellyfin 10.9+ paths. Emby is the older relative: the
/// user is part of the path there (`Users/{id}/Items`), the flat `UserViews`, `UserItems`,
/// `UserFavoriteItems`, `UserPlayedItems` do not exist (404). Everything else the client
/// calls (`Shows/…`, `Genres`, `Items/{id}/Similar`, `Items/{id}/Ancestors`, `Sessions/…`,
/// `Playlists/{id}/Items`, `Videos/{id}/stream`) answers at the same path.
///
/// Measured, not assumed: neither the `/emby` prefix nor a special header is needed. Emby
/// takes the `MediaBrowser` scheme in `Authorization` including `Token=` as Jellyfin does,
/// and lists the client with its name, device and version.
///
/// The one thing that is a spelling difference rather than a path: the token in a query
/// string is `api_key`. Emby answers `ApiKey` with 401, Jellyfin 12 answers `api_key` with
/// 401 (``tokenName(for:)``).
public enum EmbyPaths {

    /// The Jellyfin path of the client, turned into the one Emby answers.
    /// Without a user there is nothing to build a user path from, so the path stays.
    static func rewrite(_ path: String, userID: String?) -> String {
        guard let userID, !userID.isEmpty else { return path }
        let user = "Users/\(userID)/"
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first else { return path }
        switch (first, parts.count) {
        case ("UserViews", 1):
            return user + "Views"
        case ("Items", 1):
            return user + "Items"
        case ("Items", 2):
            return user + path
        case ("Items", 3) where ["SpecialFeatures", "LocalTrailers"].contains(parts[2]):
            return user + path
        case ("UserItems", 2) where parts[1] == "Resume":
            return user + "Items/Resume"
        case ("UserItems", 3) where parts[2] == "UserData":
            return user + "Items/\(parts[1])/UserData"
        case ("UserFavoriteItems", 2):
            return user + "FavoriteItems/\(parts[1])"
        case ("UserPlayedItems", 2):
            return user + "PlayedItems/\(parts[1])"
        default:
            return path
        }
    }

    /// The query name that carries the token in an address the player or the image loader
    /// opens without headers.
    public static func tokenName(for kind: ServerKind) -> String {
        switch kind {
        case .emby: "api_key"
        case .plex: "X-Plex-Token"
        case .jellyfin: "ApiKey"
        }
    }
}

extension ServerKind {

    /// **What the app offers on an Emby server**: only what was measured against Emby 4.10.2
    /// (`Notizen/Mehrserver/EMBY.md`). Left out on purpose:
    /// - `quickConnect`: `QuickConnect/Enabled` is 404.
    /// - `syncPlay`: `SyncPlay/List` and `GetUtcTime` are 404.
    /// - `remoteControl`, `playOnOtherDevice`: the Jellyfin socket protocol and session
    ///   commands are not measured against Emby.
    /// - `settingsSync`: `DisplayPreferences` answers differently and is not measured.
    /// - `trickplay`: Emby serves `index.bif`; there is no BIF reader in the package yet.
    /// - `introSegments`: `MediaSegments` is 404; Emby marks the intro as chapter markers
    ///   (Premiere), not measurable on the test server.
    /// - `seerr`: the sign-in against Seerr for Emby is not measured.
    static let embyCapabilities: Set<ServerCapability> = [
        .publicUsers, .chapters, .collections, .playlists, .favorites, .markWatched,
        .similar, .extras, .genres, .downloads,
    ]
}
