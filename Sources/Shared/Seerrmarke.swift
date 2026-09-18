import JellyfinKit
import SwiftUI

/// Wie ein Seerr-Stand aussieht — **an einer Stelle, nicht an zweien.**
///
/// Es gab die Tabelle zweimal: `Seerrkachel` trug Plus, Uhr und zwei eigene
/// Farben, `SeerrDetailView` trug Haken, Uhr, Pfeil und andere Farben. Beide
/// beschrieben dieselben fuenf Zustaende, und sie liefen prompt auseinander —
/// auf der Kachel stand „laedt" ganz ohne Symbol, waehrend auf der Seite
/// dahinter ein Pfeil im Kreis stand. "*
///
/// **Zwei Woerter je Stand, und das ist kein Widerspruch.** Auf einer Kachel
/// von 112 Punkt passt „Nicht auf deinem Server" nicht; dort steht das kurze
/// Wort oder gar keines. Dass beide hier nebeneinander stehen, ist der Punkt —
/// so faellt auf, wenn eines geaendert wird und das andere nicht.
extension Seerrstand {

    var symbol: String {
        switch self {
        case .offen, .geloescht: "plus.circle"
        case .wartetAufFreigabe: "clock"
        case .laedt: "arrow.down.circle"
        case .teilweiseDa: "circle.lefthalf.filled"
        case .da: "checkmark"
        }
    }

    /// Der ganze Satz — fuer die Detailseite.
    ///
    /// **`laedt` heisst „Angefragt", nicht „Laedt gerade".** Der Stand
    /// bedeutet bei Seerr, dass die Anfrage durch ist und beim Beschaffer
    /// liegt; ob dort gerade etwas ueber die Leitung geht, weiss niemand.
    /// „Laedt gerade" hat genau das behauptet Seerrs eigene Oberflaeche nennt
    /// diesen Stand ebenfalls „Requested".
    var wort: String {
        switch self {
        case .offen, .geloescht: String(localized: "Nicht auf deinem Server")
        case .wartetAufFreigabe: String(localized: "Wartet auf Freigabe")
        case .laedt: String(localized: "Angefragt")
        case .teilweiseDa: String(localized: "Teilweise vorhanden")
        case .da: String(localized: "Auf deinem Server")
        }
    }

    /// Das kurze Wort — fuer die Kachel. `nil` heisst: hier sagt es nichts,
    /// was nicht schon dasteht.
    ///
    /// Bei `offen` steht „Kann angefragt werden" als Ueberschrift ueber dem
    /// ganzen Block; ein Wort auf der Kachel wiederholte es nur. Bei `da`
    /// gibt es keine Marke — die Kachel liegt dann ohnehin im oberen Block.
    var kurzwort: String? {
        switch self {
        case .offen, .geloescht: nil
        case .wartetAufFreigabe: String(localized: "wartet")
        case .laedt: String(localized: "angefragt")
        case .teilweiseDa: String(localized: "teilweise")
        case .da: nil
        }
    }

    /// Die Farbe, auf beiden Flaechen dieselbe: auf der Seite die Schrift,
    /// auf der Kachel die Fuellung der Marke.
    var farbe: Color {
        switch self {
        case .wartetAufFreigabe: Color(red: 0.85, green: 0.60, blue: 0.17)
        case .laedt: Color(red: 0.29, green: 0.56, blue: 0.85)
        default: Stil.akzent
        }
    }

    /// Was die Sprachausgabe sagt.
    var ansage: String {
        switch self {
        case .offen, .geloescht: String(localized: "kann angefragt werden")
        case .wartetAufFreigabe: String(localized: "wartet auf Freigabe")
        case .laedt: String(localized: "angefragt")
        case .teilweiseDa: String(localized: "teilweise vorhanden")
        case .da: String(localized: "auf deinem Server")
        }
    }

    /// Der Satz unter dem Knopf, wenn es nichts zu druecken gibt.
    var hinweis: String {
        switch self {
        case .wartetAufFreigabe:
            String(localized: "Deine Anfrage liegt beim Verwalter des Servers. Du musst nichts weiter tun.")
        case .laedt:
            String(localized: "Deine Anfrage ist durch. Der Titel erscheint von selbst in deiner Bibliothek.")
        default:
            String(localized: "Dieser Titel liegt bereits auf deinem Server.")
        }
    }
}
