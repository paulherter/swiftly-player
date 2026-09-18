import Foundation

/// Wie eine Bibliothek sortiert wird.
public enum Sortierung: String, CaseIterable, Sendable, Identifiable {
    case name, neueste, bewertung, erscheinung
    public var id: String { rawValue }

    public var beschriftung: String {
        switch self {
        case .name:        uebersetzt("A–Z")
        case .neueste:     uebersetzt("Zuletzt")
        case .bewertung:   uebersetzt("Bewertung")
        case .erscheinung: uebersetzt("Jahr")
        }
    }

    /// Jellyfins Feldname.
    public var feld: String {
        switch self {
        case .name:        "SortName"
        case .neueste:     "DateCreated"
        case .bewertung:   "CommunityRating"
        case .erscheinung: "PremiereDate"
        }
    }

    /// Namen aufsteigend, alles andere absteigend — bei „Zuletzt" will
    /// niemand das Älteste zuerst sehen.
    public var richtung: String { self == .name ? "Ascending" : "Descending" }
}

/// Einschränkung der Liste.
public enum Bibliotheksfilter: String, CaseIterable, Sendable, Identifiable {
    case alle, angefangen, merkliste, ungesehen
    public var id: String { rawValue }

    public var beschriftung: String {
        switch self {
        case .alle:       uebersetzt("Alle")
        case .angefangen: uebersetzt("Angefangen")
        case .merkliste:  uebersetzt("Merkliste")
        case .ungesehen:  uebersetzt("Ungesehen")
        }
    }

    public var jellyfinFilter: [String] {
        switch self {
        case .angefangen: ["IsResumable"]
        case .merkliste:  ["IsFavorite"]
        default:          []
        }
    }

    /// Nur „Ungesehen" braucht den eigenen Schalter — `Filters=IsUnplayed`
    /// gibt es zwar, arbeitet bei Serien aber auf Folgenebene.
    public var istGesehen: Bool? { self == .ungesehen ? false : nil }
}
