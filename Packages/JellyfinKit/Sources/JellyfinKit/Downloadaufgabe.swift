import Foundation

/// **Welche Aufgabe eine Rückmeldung meint.**
///
/// Eine Hintergrundsitzung meldet Fortschritt, Ende und Fehler zu einer
/// *Aufgabe*, die App aber führt *Titel*. Solange je Titel nur eine Aufgabe
/// lief, reichte die Kennung des Titels. Das stimmt nicht mehr, sobald
/// jemand anhält und gleich wieder fortsetzt: die alte Aufgabe meldet ihren
/// Abbruch erst, wenn die neue schon läuft — und setzte den Titel dann auf
/// „angehalten" oder „Fehler", obwohl er lud.
///
/// Deshalb trägt jede Aufgabe eine **Generation**: eine Zahl, die bei jedem
/// Start, jedem Anhalten und jedem Entfernen des Titels weiterzählt. Eine
/// Rückmeldung gilt nur, wenn ihre Generation noch die aktuelle ist.
public enum Downloadaufgabe {

    public struct Teile: Equatable, Sendable {
        public let id: String
        /// `0` bei einer Aufgabe aus einer Fassung ohne Generation.
        public let generation: Int
        public let datei: String

        public init(id: String, generation: Int, datei: String) {
            self.id = id; self.generation = generation; self.datei = datei
        }
    }

    static let trenner = "\u{1F}"

    /// Was an `taskDescription` steht: Kennung, Generation, Dateiname.
    public static func beschreibung(id: String, generation: Int, datei: String) -> String {
        [id, String(generation), datei].joined(separator: trenner)
    }

    /// Zurück in die Teile. Die alte Form `id␟datei` bekommt Generation 0.
    public static func zerlegen(_ text: String?) -> Teile? {
        let stuecke = (text ?? "").components(separatedBy: trenner)
        switch stuecke.count {
        case 2 where !stuecke[0].isEmpty:
            return Teile(id: stuecke[0], generation: 0, datei: stuecke[1])
        case 3... where !stuecke[0].isEmpty:
            guard let g = Int(stuecke[1]) else {
                // Kein Zahlfeld: dann war es die alte Form, und der
                // Dateiname trug das Trennzeichen selbst.
                return Teile(id: stuecke[0], generation: 0,
                             datei: stuecke.dropFirst().joined(separator: trenner))
            }
            return Teile(id: stuecke[0], generation: g,
                         datei: stuecke.dropFirst(2).joined(separator: trenner))
        default:
            return nil
        }
    }

    /// Ob eine Rückmeldung zählt.
    ///
    /// Kennt die App für den Titel noch keine Generation — frisch gestartet,
    /// die Aufgabe lief im System weiter —, zählt sie: sonst ginge ein
    /// Download verloren, der im Hintergrund fertig wurde.
    public static func gilt(gemeldet: Int, aktuell: Int?) -> Bool {
        guard let aktuell else { return true }
        return gemeldet == aktuell
    }
}
