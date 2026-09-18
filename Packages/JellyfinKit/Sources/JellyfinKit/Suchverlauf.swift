import Foundation

/// **Was zuletzt gesucht wurde — die letzten acht, jüngstes zuerst.**
///
/// Stand zuerst als zwei Funktionen in der iPhone-Suche. Seit der Fernseher
/// dieselbe Liste zeigt, liegt die Regel hier: eine kopierte Funktion wäre
/// der Anfang zweier Fassungen, die beim nächsten Durchgang auseinanderlaufen.
///
/// Gespeichert wird eine Zeichenkette mit einem Begriff je Zeile, weil
/// `@AppStorage` keine Felder nimmt. Der Schlüssel ist auf allen Geräten
/// derselbe; geteilt wird trotzdem nichts — jedes Gerät merkt sich, was auf
/// ihm gesucht wurde.
public enum Suchverlauf {
    public static let schluessel = "letzteSuchen"
    public static let hoechstens = 8

    public static func liste(_ roh: String) -> [String] {
        roh.split(separator: "\n").map(String.init)
    }

    /// Nimmt einen Begriff auf und gibt den neuen Stand zurück.
    ///
    /// Unter zwei Zeichen nichts — ab zwei wird überhaupt erst gesucht.
    /// Derselbe Begriff in anderer Schreibung ersetzt den alten und rückt nach
    /// vorn, statt ein zweites Mal dazustehen.
    public static func merken(_ wort: String, in roh: String) -> String {
        let sauber = wort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sauber.count >= 2 else { return roh }
        var neu = liste(roh).filter { $0.caseInsensitiveCompare(sauber) != .orderedSame }
        neu.insert(sauber, at: 0)
        return neu.prefix(hoechstens).joined(separator: "\n")
    }
}
