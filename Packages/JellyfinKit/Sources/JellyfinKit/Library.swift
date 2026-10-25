import Foundation

/// How a library is sorted.
public enum Sorting: String, CaseIterable, Sendable, Identifiable {
    case name, latest = "neueste", rating = "bewertung", erscheinung
    public var id: String { rawValue }

    public var label: String {
        switch self {
        // "By name", not "A–Z": the order is natural (digits, Latin, then other
        // scripts; ``NaturalOrder``), not just the Latin alphabet.
        case .name:        translated("Nach Name")
        case .latest:     translated("Zuletzt")
        case .rating:   translated("Bewertung")
        case .erscheinung: translated("Jahr")
        }
    }

    /// Jellyfin's field name.
    public var inputField: String {
        switch self {
        case .name:        "SortName"
        case .latest:     "DateCreated"
        case .rating:   "CommunityRating"
        case .erscheinung: "PremiereDate"
        }
    }

    /// Names ascending, everything else descending: nobody wants the oldest first for
    /// "Recent".
    public var bearing: String { self == .name ? "Ascending" : "Descending" }
}

/// Narrows the list.
public enum LibraryFilter: String, CaseIterable, Sendable, Identifiable {
    case all = "alle", begun = "angefangen", watchlist = "merkliste", unwatched = "ungesehen"
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all:       translated("Alle")
        case .begun: translated("Angefangen")
        case .watchlist:  translated("Merkliste")
        case .unwatched:  translated("Ungesehen")
        }
    }

    public var jellyfinFilter: [String] {
        switch self {
        case .begun: ["IsResumable"]
        case .watchlist:  ["IsFavorite"]
        default:          []
        }
    }

    /// Only "Unwatched" needs its own switch: `Filters=IsUnplayed` exists but works per
    /// episode for series.
    public var isWatched: Bool? { self == .unwatched ? false : nil }
}

/// **What the watchlist shows**: movies, series or both.
///
/// **Not "All".** On the library page a pill with the same word sits in the same place but
/// means the *state* (all, started, saved, unwatched); here it means the *kind*. Same word,
/// same icon, same place, two meanings is a trap, not brevity.
///
/// Lives in the package so Linux and Windows get the pill too.
public enum RememberGenre: String, CaseIterable, Sendable, Identifiable {
    case all = "alle", movies = "filme", seriesList = "serien"
    public var id: String { rawValue }

    public var label: String {
        switch self {
        // "All" like the first filter for movies and series (`LibraryFilter.all`):
        // same choice, same word.
        case .all:   translated("Alle")
        case .movies:  translated("Filme")
        case .seriesList: translated("Serien")
        }
    }

    /// **The funnel narrows, the grid selects.** The library uses the funnel, the watchlist
    /// this icon.
    public var symbol: String {
        switch self {
        case .all:   "square.grid.2x2"
        case .movies:  "film"
        case .seriesList: "tv"
        }
    }

    /// Jellyfin's `CollectionType`.
    public var art: String? {
        switch self {
        case .all:   nil
        case .movies:  "movies"
        case .seriesList: "tvshows"
        }
    }

    /// Which `IncludeItemTypes` follow from it.
    public var types: [String] {
        switch self {
        case .all:   ["Movie", "Series"]
        case .movies:  ["Movie"]
        case .seriesList: ["Series"]
        }
    }

    public static func toward(art: String?) -> RememberGenre {
        allCases.first { $0.art == art } ?? .all
    }
}
