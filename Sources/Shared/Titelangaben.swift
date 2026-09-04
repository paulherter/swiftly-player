import Foundation
import JellyfinKit

/// Wie ein Titel beschriftet wird — auf beiden Plattformen gleich.
///
/// Lag vorher zweimal fast gleich in den Ansichtsdateien: einmal auf dem
/// iPhone, einmal auf dem Fernseher. Fast gleich ist dabei das Problem — die
/// Fassungen liefen schon auseinander (auf tvOS stand bei Serien „0 Min",
/// weil die Prüfung auf `> 0` fehlte). Solche Angaben gehören einmal
/// aufgeschrieben und von beiden benutzt.

// **`laufzeit`, `zeitText`, `komma`, `nebenzeile` und `fortsetzenAb` liegen
// jetzt im Paket** (`JellyfinKit/Titelangaben.swift`). Sie waren hier an
// `String(localized:)` mit dem App-Katalog gebunden und damit fuer die
// Linux-Fassung unerreichbar — die haette sie abschreiben muessen, und genau
// daran ist die Zeile schon einmal auseinandergelaufen (auf tvOS stand bei
// Serien „0 Min.").
//
// Im Paket laufen sie ueber `uebersetzt(…)` und die `.lproj`-Dateien. Was
// hier bleibt, haengt an `LocalizedStringKey` oder am App-Katalog und kann
// nicht mit.

extension Item {

    /// Die Zeile unter einem Suchtreffer: „Furious · S1 E4 · 52 Min."
    ///
    /// Lag privat in `Trefferzeile` und war damit an eine Ansicht gebunden,
    /// die es auf breiten Schirmen gar nicht gibt — der iPad-Chat brauchte
    /// dieselbe Auskunft unter einem Plakat und hat sie dort herausgezogen.
    /// Dasselbe Muster wie bei `Handlungsblatt.Handlung`: nicht die Ansicht
    /// besitzt die Auskunft, sondern der Titel.
    ///
    /// Beim Umzug fiel auf, dass die Gattung „Film" als **reine
    /// Zeichenkette** angehängt wurde, während „Serie" und „Folge" daneben
    /// übersetzt wurden. Auf Englisch stand dort „Film" statt „Movie".
    var trefferauskunft: String {
        var teile: [String] = []
        switch type {
        case "Movie":   teile.append(String(localized: "Film"))
        case "Series":  teile.append(String(localized: "Serie"))
        case "Episode": teile.append(seriesName ?? String(localized: "Folge"))
        default: break
        }
        if let kuerzel = folgenkuerzel { teile.append(kuerzel) }
        if let jahr = productionYear, type != "Episode" { teile.append(String(jahr)) }
        if let anzahl = childCount, type == "Series" {
            teile.append(String(localized: "\(anzahl) Staffeln"))
        }
        if let s = runtimeSeconds, type != "Series" { teile.append(laufzeit(s)) }
        return teile.joined(separator: " · ")
    }

    /// „Noch 12 Minuten" — oder `nil`, wenn nichts Nennenswertes fehlt.
    ///
    /// Stand zweimal da und war **nicht** gleich: einmal „Noch 12 Minuten",
    /// einmal „Noch 12 min". Schlimmer, die zweite Fassung entstand als reine
    /// Zeichenkette und lief nie durch die Übersetzung — auf einem englischen
    /// Gerät stand dort Deutsch.
    var restzeitText: String? {
        guard let gesamt = runtimeSeconds, gesamt > 0, let ab = fortsetzenAb else { return nil }
        return String(localized: "Noch \(Int((gesamt - ab) / 60)) Minuten")
    }

    /// Beschriftung des Hauptknopfes auf einer Serienseite.
    ///
    /// **Stand hier, weil sie sonst dreimal dasteht.** iOS und tvOS hatten sie
    /// je fuer sich — dieselben vier Faelle, zeichengleich. Genau so sind
    /// `nachladen()`, `trefferauskunft` und `Spielzeit` auseinandergelaufen.
    ///
    /// `folge` ist die naechste anzuspielende Folge, `laedt`, ob die Staffel
    /// noch geholt wird. Ohne Folge und ohne Laden gibt es nichts abzuspielen.
    static func serienknopf(folge: Item?, laedt: Bool) -> String {
        // **Zwei getrennte Aufrufe, kein Fragezeichen im Argument.** Aus einem
        // berechneten Schluessel kann Xcode nichts herausziehen; der Text
        // bliebe in der Ausgangssprache stehen.
        guard let folge else {
            return laedt ? String(localized: "Lädt…")
                         : String(localized: "Keine Folgen")
        }
        let kuerzel = folge.folgenkuerzel ?? folge.name
        let angefangen = (folge.userData?.playbackPositionTicks ?? 0) > 0
        return angefangen ? String(localized: "Fortsetzen \(kuerzel)")
                          : String(localized: "Abspielen \(kuerzel)")
    }
}
