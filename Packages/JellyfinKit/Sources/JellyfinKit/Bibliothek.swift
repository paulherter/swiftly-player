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

/// **Was die Merkliste zeigt** — Filme, Serien oder beides.
///
/// **Nicht „Alle".** Auf der Bibliotheksseite steht an derselben Stelle eine
/// Pille mit demselben Wort — die meint dort aber den *Zustand* (alle,
/// angefangen, gemerkt, ungesehen), hier die *Gattung*. Gleiches Wort,
/// gleiches Zeichen, gleicher Platz, zwei Bedeutungen: das ist keine Kürze,
/// sondern eine Falle (E25).
///
/// Stand in `Sources/Shared/Merklistenmodell.swift` und erreichte Linux und
/// Windows damit nicht — dort fehlte die Pille ganz.
public enum Merkgattung: String, CaseIterable, Sendable, Identifiable {
    case alle, filme, serien
    public var id: String { rawValue }

    public var beschriftung: String {
        switch self {
        case .alle:   uebersetzt("Filme & Serien")
        case .filme:  uebersetzt("Filme")
        case .serien: uebersetzt("Serien")
        }
    }

    /// **Trichter engt ein, Raster waehlt aus** (E25). Die Bibliothek nimmt
    /// den Trichter, die Merkliste dieses Zeichen.
    public var symbol: String {
        switch self {
        case .alle:   "square.grid.2x2"
        case .filme:  "film"
        case .serien: "tv"
        }
    }

    /// Jellyfins `CollectionType`.
    public var art: String? {
        switch self {
        case .alle:   nil
        case .filme:  "movies"
        case .serien: "tvshows"
        }
    }

    /// Welche `IncludeItemTypes` daraus folgen.
    public var typen: [String] {
        switch self {
        case .alle:   ["Movie", "Series"]
        case .filme:  ["Movie"]
        case .serien: ["Series"]
        }
    }

    public static func zu(art: String?) -> Merkgattung {
        allCases.first { $0.art == art } ?? .alle
    }
}
