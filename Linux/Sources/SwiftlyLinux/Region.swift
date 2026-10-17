import Foundation

/// The sidebar sections, the same as in the iPhone bar, at the top on tvOS and
/// on the left on the Mac.
///
/// **Icons are the one place where Linux cannot follow.** Apple draws SF
/// Symbols, which do not exist here and may not be bundled. The closest icon
/// from the Adwaita set, present on every GTK system, is used instead:
///
/// | Mac | Linux |
/// |---|---|
/// | `house` | `user-home-symbolic` |
/// | `film` | `video-x-generic-symbolic` |
/// | `tv` | `tv-symbolic` |
/// | `bookmark.fill` | `user-bookmarks-symbolic` |
/// | `arrow.down.circle` | `folder-download-symbolic` |
/// | `magnifyingglass` | `system-search-symbolic` |
enum Region: CaseIterable {
    case start, movies, seriesList, watchlist, downloads, search
    /// **A collection as a subpage, hence no sidebar entry** (like
    /// `MacCollection.swift` on the Mac).
    ///
    /// It is listed here because it uses the same grid page: header, filter,
    /// sort order and paging at the bottom edge are keyed by `Region`, and a
    /// second version of that would be exactly the copied function the rules
    /// forbid. It is absent from `topGroup` and `mineGroup`, so it never
    /// appears as a row. Libraries are reached from the title menu of Movies and
    /// Shows, as on the Mac.
    case collection

    /// **All titles of a genre, from the chips above the home page.**
    ///
    /// Like ``library`` in this list, it uses the same grid page, and like it
    /// it has no sidebar entry: it comes from a chip, not from navigation.
    case genre

    /// **Top group: what the server has.** Four rows.
    static let topGroup: [Region] = [.start, .movies, .seriesList, .search]

    /// **Bottom group: what is mine.**
    ///
    /// Copied verbatim from the Mac, with its reasoning: six equal rows in one
    /// list read as a list where nothing belongs together. Watchlist and
    /// Downloads are not the same kind of place as Movies and Shows: those two
    /// are **collections of the server**, these two are **mine**: what I saved
    /// and what I downloaded to this machine.
    ///
    /// The downloads row only exists if the download switch is on.
    static func mineGroup(downloads: Bool) -> [Region] {
        downloads ? [.watchlist, .downloads] : [.watchlist]
    }

    var label: String {
        switch self {
        case .start:  translated("Start")
        case .movies:  translated("Filme")
        case .seriesList: translated("Serien")
        case .watchlist: translated("Merkliste")
        case .downloads: translated("Downloads")
        case .search:  translated("Suche")
        // The title comes from the opened item, not from here.
        case .collection: ""
        // The genre name comes from the server and is **not** translated.
        case .genre: ""
        }
    }

    /// **The keyboard shortcut, as shown in the hint.**
    ///
    /// The same as on the Mac (`Sources/macOS/SwiftlyApp.swift`), with Ctrl
    /// instead of Cmd. They already worked here, but could be read nowhere
    /// because a Wayland window has no menu bar.
    var abbreviation: String? {
        switch self {
        case .start:  String(format: translated("Strg+%@"), "1")
        case .movies:  String(format: translated("Strg+%@"), "2")
        case .seriesList: String(format: translated("Strg+%@"), "3")
        case .search:  String(format: translated("Strg+%@"), "F")
        default:      nil
        }
    }

    /// The page's name in the `GtkStack`.
    var identifier: String {
        switch self {
        case .start:  "start"
        case .movies:  "filme"
        case .seriesList: "serien"
        case .watchlist: "merkliste"
        case .downloads: "downloads"
        case .search:  "suche"
        case .collection: "sammlung"
        case .genre: "gattung"
        }
    }

    var symbol: String {
        switch self {
        case .start:  "user-home-symbolic"
        case .movies:  "video-x-generic-symbolic"
        case .seriesList: "tv-symbolic"
        // `bookmark.fill` on the Mac; in the Adwaita set that is the bookmark.
        case .watchlist: "bookmark-new-symbolic"
        // `arrow.down.circle` on the Mac. Adwaita has no downward arrow in a circle
        // that does not mean "refresh"; the download folder is the closest and is
        // used for the same thing everywhere else.
        case .downloads: "folder-download-symbolic"
        case .search:  "system-search-symbolic"
        case .collection: "folder-symbolic"
        // Never in the sidebar; the icon is only used for the header.
        case .genre: "tag-symbolic"
        }
    }
}
