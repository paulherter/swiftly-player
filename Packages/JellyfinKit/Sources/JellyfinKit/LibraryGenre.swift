import Foundation

/// Which kind of item a library of this type holds.
///
/// **Why this is not obvious.** If Jellyfin is asked for the content of a series
/// library without naming the kind, then depending on server settings it returns not
/// the series but the library's virtual folders: “Continue Watching”, “Next Up”,
/// “Latest”, “Shows”, “Favorite Shows”, “Favorite Episodes”, “Genres”. They have no
/// posters.
///
/// This showed up as seven empty tiles with these names instead of the series. It did
/// not occur on every server, so it was visible in a screenshot but not in a
/// measurement.
///
/// Jellyfin's own web UI always passes the kind and queries recursively. On servers
/// without these folders that changes nothing: same titles in the same order.
public enum LibraryGenre {

    /// - Parameter art: Jellyfin's `CollectionType` of the library.
    /// - Returns: The values for `IncludeItemTypes`, or empty if there is no useful
    ///   restriction for this type.
    public static func types(toward art: String?) -> [String] {
        switch art?.lowercased() {
        case "movies":     ["Movie"]
        case "tvshows":    ["Series"]
        case "music":      ["MusicAlbum"]
        case "homevideos": ["Video", "Photo"]
        case "books":      ["Book"]
        // **Unknown means: do not restrict.** A mixed library or an unknown kind should
        // show everything instead of nothing. Better one folder too many than an empty
        // page.
        default:           []
        }
    }

    /// Whether this type must be queried recursively.
    ///
    /// Only when the kind is fixed: otherwise the server would search the whole tree and
    /// also return what is in subfolders, with no way to restrict it.
    public static func recursive(toward art: String?) -> Bool {
        !types(toward: art).isEmpty
    }
}
