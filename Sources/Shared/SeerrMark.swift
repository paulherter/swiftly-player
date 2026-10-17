import JellyfinKit
import SwiftUI

/// What a Seerr state looks like, **in one place, not two.**
///
/// The table existed twice: `SeerrTile` carried plus, clock and two colors of
/// its own, `SeerrDetailView` carried checkmark, clock, arrow and other colors.
/// Both described the same five states and promptly drifted apart: on the tile
/// "loading" had no symbol at all, while the page behind it had an arrow in a
/// circle.
///
/// **Two words per state, which is no contradiction.** On a 112 pt tile "Not on
/// your server" does not fit; there the short word stands, or none. That both
/// stand side by side here is the point: it shows when one is changed and the
/// other is not.
extension SeerrState {

    var symbol: String {
        switch self {
        case .opened, .deleted: "plus.circle"
        case .waitsSharing: "clock"
        case .loads: "arrow.down.circle"
        case .partWayPresent: "circle.lefthalf.filled"
        case .present: "checkmark"
        }
    }

    /// The full sentence, for the detail page.
    ///
    /// **`loads` means "Requested", not "Loading now".** In Seerr this state means
    /// the request went through and is with the fetcher; whether anything is
    /// actually on the wire there, nobody knows. "Loading now" claimed exactly that.
    /// Seerr's own interface also calls this state "Requested".
    var word: String {
        switch self {
        case .opened, .deleted: String(localized: "Nicht auf deinem Server")
        case .waitsSharing: String(localized: "Wartet auf Freigabe")
        case .loads: String(localized: "Angefragt")
        case .partWayPresent: String(localized: "Teilweise vorhanden")
        case .present: String(localized: "Auf deinem Server")
        }
    }

    /// The short word, for the tile. `nil` means: here it says nothing that is not
    /// already there.
    ///
    /// For `opened`, "Can be requested" stands as a heading above the whole block; a
    /// word on the tile would only repeat it. For `present` there is no mark; the tile
    /// then lies in the upper block anyway.
    var shortWord: String? {
        switch self {
        case .opened, .deleted: nil
        case .waitsSharing: String(localized: "wartet")
        case .loads: String(localized: "angefragt")
        case .partWayPresent: String(localized: "teilweise")
        case .present: nil
        }
    }

    /// The color, the same on both surfaces: the text on the page, the fill of the
    /// mark on the tile.
    /// **Two colors instead of four.** There was an amber and a blue of their own
    /// that appeared in no token file; Seerr was the only corner of the app with its
    /// own color world.
    ///
    /// Now: `warning` for the one case where someone must act, `accent` for anything
    /// in progress, and `schriftLeise` for the normal case. That "requested" and
    /// "partially available" are both teal is no loss: they carry different symbols,
    /// and state is distinguished by shape, not by a second color.
    ///
    /// "On your server" is not a state at all but the normal case, and therefore
    /// carries no color.
    var color: Color {
        switch self {
        case .waitsSharing: Theme.warning
        case .present: Theme.font
        case .opened, .deleted: Theme.fontQuiet
        default: Theme.accent
        }
    }

    /// What the speech output says.
    var announcement: String {
        switch self {
        case .opened, .deleted: String(localized: "kann angefragt werden")
        case .waitsSharing: String(localized: "wartet auf Freigabe")
        case .loads: String(localized: "angefragt")
        case .partWayPresent: String(localized: "teilweise vorhanden")
        case .present: String(localized: "auf deinem Server")
        }
    }

    /// The sentence under the button when there is nothing to press.
    var hint: String {
        switch self {
        case .waitsSharing:
            String(localized: "Deine Anfrage liegt beim Verwalter des Servers. Du musst nichts weiter tun.")
        case .loads:
            String(localized: "Deine Anfrage ist durch. Der Titel erscheint von selbst in deiner Bibliothek.")
        default:
            String(localized: "Dieser Titel liegt bereits auf deinem Server.")
        }
    }
}
