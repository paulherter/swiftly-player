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
    /// **Eine Bibliothek als eigene Seite — und deshalb kein Eintrag in der
    /// Leiste.**
    ///
    /// Sie steht in dieser Aufzaehlung, weil sie dieselbe Rasterseite
    /// benutzt: Kopf, Filter, Sortierung, Nachladen am unteren Rand liegen
    /// in Woerterbuechern ueber `Bereich`, und eine zweite Fassung davon
    /// waere genau die kopierte Funktion, gegen die die Regel steht. In
    /// `obenGruppe` und `meinsGruppe` taucht sie nicht auf, also erscheint
    /// sie nie als Zeile.
    ///
    /// **Warum ueberhaupt eine eigene Seite:** vorher fuehrte ein Klick auf
    /// eine Sammlung in den Filme-Bereich und waehlte sich dort aus — ueber
    /// „Filmabend" stand dann die Ueberschrift „Filme", und eine Sammlung,
    /// die weder `movies` noch `tvshows` ist, tat gar nichts. Auf dem Mac ist
    /// genau das behoben (`Seitenziel.bibliothek`); hier stand es noch.
    case bibliothek

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
        case .bibliothek: ""
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
        case .bibliothek: "bibliothek"
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
        // `arrow.down.circle` auf dem Mac. Adwaita hat keinen Pfeil im
        // Kreis, der nach unten zeigt und nicht „aktualisieren" heisst;
        // der Ladeordner ist das naechstliegende und wird ueberall sonst
        // fuer dasselbe benutzt.
        case .downloads: "folder-download-symbolic"
        case .suche:  "system-search-symbolic"
        case .bibliothek: "folder-symbolic"
        }
    }
}
