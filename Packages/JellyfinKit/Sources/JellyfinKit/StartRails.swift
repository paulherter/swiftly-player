import Foundation

/// **Which rows the home page has, and in which order.**
///
/// This used to live in `AppModel`, so Linux and Windows did not get it and had the order
/// hard-wired, without hiding or reordering. Which row applies when is not a display
/// question: `passt` decides whether a row exists at all, and the answer must be the same
/// everywhere.
public enum StartRail: String, CaseIterable, Sendable, Identifiable {
    case continueWatching = "weiterschauen", nextEpisode = "naechsteFolge", newMovies = "neueFilme", newSeries = "neueSerien", newArrivals = "neuzugaenge"

    public var id: String { rawValue }

    /// Which rows currently exist: new movies and new series separately, otherwise the
    /// combined one.
    ///
    /// **Separate instead of additional.** When the setting is on, the pair replaces the
    /// combined row; when off, the pair does not exist. So the setting costs nothing while
    /// unused.
    public func fits(disconnected: Bool) -> Bool {
        switch self {
        case .newArrivals:            !disconnected
        case .newMovies, .newSeries: disconnected
        default:                      true
        }
    }

    /// The name in the settings list: **German, because German is the key.**
    ///
    /// **Not the heading on the home page.** There it reads "Recently Added Movies", here
    /// "New Movies": one is the title of a row, the other the name of the line being moved.
    public var listsName: String {
        switch self {
        case .continueWatching: "Weiterschauen"
        case .nextEpisode: "Nächste Folge"
        case .newMovies:     "Neue Filme"
        case .newSeries:    "Neue Serien"
        case .newArrivals:   "Neu hinzugefügt"
        }
    }

    /// The icon in the settings list. **Adwaita names**, because only Linux and Windows
    /// build this list themselves; Apple has its own SF Symbols in the view. Without an
    /// icon the row list looked different from every other list in the app.
    public var symbolText: String {
        switch self {
        case .continueWatching: "media-playback-start-symbolic"
        case .nextEpisode: "media-skip-forward-symbolic"
        case .newMovies:     "video-x-generic-symbolic"
        case .newSeries:    "tv-symbolic"
        case .newArrivals:   "starred-symbolic"
        }
    }

    /// The heading above the row on the home page itself.
    public var railsTitle: String {
        switch self {
        case .continueWatching: "Weiterschauen"
        case .nextEpisode: "Nächste Folge"
        case .newMovies:     "Zuletzt hinzugefügte Filme"
        case .newSeries:    "Zuletzt hinzugefügte Serien"
        case .newArrivals:   "Zuletzt hinzugefügt"
        }
    }
}

/// How the configured order is read and saved.
///
/// **Why a calculation of its own.** A stored list can go stale: a row disappears, one is
/// added, or the file comes from a version that did not know it yet. None of these may
/// empty the home page.
public enum StartRailsEpisode {

    /// The effective order: what is stored, followed by everything missing from it, so that
    /// a new row shows up instead of silently vanishing.
    ///
    /// **Each row exactly once, and this is not just caution.** This calculation added what
    /// was missing but never checked for duplicates. If "neueFilme" was in the store twice,
    /// it came back twice, came out twice on every reorder and was written back twice: the
    /// error does not heal itself, it survives every launch. The home page showed the row
    /// twice, and because `ForEach` matches rows by ID, a tap also landed on the wrong one
    /// (the same class of error `ListRules` catches for title lists).
    ///
    /// **The first entry counts.** Someone who moved a row up did it at its first position;
    /// the later repeat is the straggler, not the intent.
    public static func applicable(stored: [String]) -> [StartRail] {
        let known = clean(stored.compactMap(StartRail.init(rawValue:)))
        let absent = StartRail.allCases.filter { !known.contains($0) }
        return known + absent
    }

    /// Each row exactly once, in the order of first occurrence.
    ///
    /// **Needed on the write path too, not only on the read path.** A store that is already
    /// duplicated must be straightened out on load, otherwise the home page stays broken on
    /// a device that already carries the error, even if nothing duplicate is ever written
    /// again.
    public static func clean(_ rails: [StartRail]) -> [StartRail] {
        var watched = Set<StartRail>()
        return rails.filter { watched.insert($0).inserted }
    }

    /// What ends up on the page: in order, without the hidden ones and those that do not
    /// currently exist.
    public static func visible(stored: [String], from: Set<String>,
                                disconnected: Bool) -> [StartRail] {
        applicable(stored: stored)
            .filter { !from.contains($0.rawValue) && $0.fits(disconnected: disconnected) }
    }

    /// Moves a row by one position, **within the visible ones**.
    ///
    /// What does not currently apply is appended at the end and reappears when toggled; if
    /// it were counted, a row would jump over a gap nobody sees.
    public static func shifted(_ was: StartRail, um step: Int,
                                  stored: [String], disconnected: Bool) -> [String] {
        var visible = applicable(stored: stored).filter { $0.fits(disconnected: disconnected) }
        guard let from = visible.firstIndex(of: was) else { return stored }
        let to = from + step
        guard to >= 0, to < visible.count else { return stored }
        visible.swapAt(from, to)
        let invisible = applicable(stored: stored).filter { !$0.fits(disconnected: disconnected) }
        return (visible + invisible).map(\.rawValue)
    }
}
