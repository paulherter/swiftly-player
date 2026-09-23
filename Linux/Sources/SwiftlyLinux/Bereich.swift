import Foundation

/// Die Bereiche der Seitenleiste — dieselben wie in der Leiste auf dem
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
/// | `arrow.down.circle` | `folder-download-symbolic` |
/// | `magnifyingglass` | `system-search-symbolic` |
enum Bereich: CaseIterable {
    case start, filme, serien, merkliste, downloads, suche
    /// **Eine Sammlung als Unterseite — und deshalb kein Eintrag in der
    /// Leiste** (Mac 8ca6269a, `MacSammlung.swift`).
    ///
    /// Sie steht in dieser Aufzaehlung, weil sie dieselbe Rasterseite
    /// benutzt: Kopf, Filter, Sortierung, Nachladen am unteren Rand liegen
    /// in Woerterbuechern ueber `Bereich`, und eine zweite Fassung davon
    /// waere genau die kopierte Funktion, gegen die die Regel steht. In
    /// `obenGruppe` und `meinsGruppe` taucht sie nicht auf, also erscheint
    /// sie nie als Zeile.
    ///
    /// Bis zum 23.09.2026 stand hier die Bibliothek als eigene Seite, aus
    /// der Rubrik „Bibliotheken" der Seitenleiste. Die Rubrik ist weg; die
    /// Bibliotheken stehen jetzt im Titelmenue von Filme und Serien, wie auf
    /// dem Mac.
    case sammlung

    /// **Alle Titel eines Genres — aus den Chips über der Startseite.**
    ///
    /// Wie ``bibliothek`` in dieser Aufzählung, weil sie dieselbe Rasterseite
    /// benutzt, und wie sie kein Eintrag in der Leiste: sie kommt von einem
    /// Chip, nicht aus der Navigation.
    case gattung

    /// **Oben, was der Server hat.** Vier Zeilen, wie eh und je.
    static let obenGruppe: [Bereich] = [.start, .filme, .serien, .suche]

    /// **Und darunter, was mir gehoert.**
    ///
    /// Wortgleich vom Mac uebernommen, samt Begruendung: sechs gleichrangige
    /// Zeilen untereinander lasen sich als eine Liste, in der nichts mehr
    /// zusammengehoert. Merkliste und Downloads sind aber nicht dieselbe
    /// Sorte Ort wie Filme und Serien — die beiden sind **Sammlungen des
    /// Servers**, diese zwei sind **meine**: was ich mir gemerkt und was ich
    /// auf diese Maschine geholt habe.
    ///
    /// Hier stand die Merkliste bisher oben zwischen Serien und Suche. Das
    /// war die Fassung von vor der Gruppierung auf dem Mac; nachgezogen,
    /// damit die beiden nicht auseinanderlaufen.
    ///
    /// H1: ohne den Schalter gibt es die Downloadzeile nicht.
    static func meinsGruppe(downloads: Bool) -> [Bereich] {
        downloads ? [.merkliste, .downloads] : [.merkliste]
    }

    var beschriftung: String {
        switch self {
        case .start:  uebersetzt("Start")
        case .filme:  uebersetzt("Filme")
        case .serien: uebersetzt("Serien")
        case .merkliste: uebersetzt("Merkliste")
        case .downloads: uebersetzt("Downloads")
        case .suche:  uebersetzt("Suche")
        // Der Titel kommt vom geoeffneten Eintrag, nicht von hier.
        case .sammlung: ""
        // Der Genrename kommt vom Server und wird **nicht** uebersetzt (E7).
        case .gattung: ""
        }
    }

    /// **Das Tastenkuerzel, wie es am Kurzhinweis steht.**
    ///
    /// Dieselben wie auf dem Mac (`Sources/macOS/SwiftlyApp.swift:102-110`),
    /// nur mit Strg statt Befehl. Sie funktionierten hier schon; abzulesen
    /// waren sie nirgends, weil ein Wayland-Fenster keine Menueleiste hat.
    var kuerzel: String? {
        switch self {
        case .start:  "Strg+1"
        case .filme:  "Strg+2"
        case .serien: "Strg+3"
        case .suche:  "Strg+F"
        default:      nil
        }
    }

    /// Der Name der Seite im `GtkStack`.
    var kennung: String {
        switch self {
        case .start:  "start"
        case .filme:  "filme"
        case .serien: "serien"
        case .merkliste: "merkliste"
        case .downloads: "downloads"
        case .suche:  "suche"
        case .sammlung: "sammlung"
        case .gattung: "gattung"
        }
    }

    var symbol: String {
        switch self {
        case .start:  "user-home-symbolic"
        case .filme:  "video-x-generic-symbolic"
        case .serien: "tv-symbolic"
        // `bookmark.fill` auf dem Mac; im Adwaita-Satz ist das das
        // Lesezeichen.
        case .merkliste: "bookmark-new-symbolic"
        // `arrow.down.circle` auf dem Mac. Adwaita hat keinen Pfeil im
        // Kreis, der nach unten zeigt und nicht „aktualisieren" heisst;
        // der Ladeordner ist das naechstliegende und wird ueberall sonst
        // fuer dasselbe benutzt.
        case .downloads: "folder-download-symbolic"
        case .suche:  "system-search-symbolic"
        case .sammlung: "folder-symbolic"
        // Steht nie in der Leiste; das Zeichen gilt nur fuer den Kopf.
        case .gattung: "tag-symbolic"
        }
    }
}
