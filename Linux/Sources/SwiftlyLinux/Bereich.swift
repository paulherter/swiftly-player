import Foundation

/// Die fuenf Bereiche der Seitenleiste — dieselben wie in der Leiste auf dem
/// iPhone, oben auf dem Fernseher und links auf dem Mac.
///
/// **Die Symbole sind die eine Stelle, an der Linux nicht folgen kann.** Apple
/// zeichnet SF Symbols; die gibt es hier nicht und sie dürfen auch nicht
/// mitgeliefert werden. Genommen wird das nächstliegende aus dem
/// Adwaita-Satz, der auf jedem GTK-System liegt:
///
/// | Mac | Linux |
/// |---|---|
/// | `house` | `user-home-symbolic` |
/// | `film` | `video-x-generic-symbolic` |
/// | `tv` | `tv-symbolic` |
/// | `bookmark.fill` | `user-bookmarks-symbolic` |
/// | `magnifyingglass` | `system-search-symbolic` |
enum Bereich: CaseIterable {
    case start, filme, serien, merkliste, suche

    var beschriftung: String {
        switch self {
        case .start:  uebersetzt("Start")
        case .filme:  uebersetzt("Filme")
        case .serien: uebersetzt("Serien")
        case .merkliste: uebersetzt("Merkliste")
        case .suche:  uebersetzt("Suche")
        }
    }

    /// Der Name der Seite im `GtkStack`.
    var kennung: String {
        switch self {
        case .start:  "start"
        case .filme:  "filme"
        case .serien: "serien"
        case .merkliste: "merkliste"
        case .suche:  "suche"
        }
    }

    var symbol: String {
        switch self {
        case .start:  "user-home-symbolic"
        case .filme:  "video-x-generic-symbolic"
        case .serien: "tv-symbolic"
        // `bookmark.fill` auf dem Mac; im Adwaita-Satz ist das das
        // Lesezeichen.
        case .merkliste: "user-bookmarks-symbolic"
        case .suche:  "system-search-symbolic"
        }
    }
}
