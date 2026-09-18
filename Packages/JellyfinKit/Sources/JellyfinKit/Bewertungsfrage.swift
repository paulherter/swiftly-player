import Foundation

/// **Wann die App nach einer Bewertung im App Store fragt.**
///
/// Nach dem dritten fertig geschauten Titel, und höchstens einmal je Fassung.
/// Früher wäre es eine Frage an jemanden, der die App noch gar nicht kennt;
/// öfter wäre es lästig. Apple selbst zeigt die Abfrage ohnehin höchstens
/// dreimal im Jahr — diese Regel entscheidet nur, *wann* wir sie anbieten.
public enum Bewertungsfrage {

    /// Ab so vielen fertig geschauten Titeln.
    public static let schwelle = 3

    /// Ab diesem Anteil gilt ein Titel als fertig geschaut. Der Abspann zählt
    /// nicht mit — wer ihn überspringt, hat trotzdem zu Ende geschaut.
    public static let fertigAnteil = 0.9

    /// Ein Trailer oder ein kurzer Clip ist kein geschauter Titel.
    public static let mindestDauer: Double = 60

    public static func zaehltAlsFertig(position: Double, dauer: Double) -> Bool {
        dauer >= mindestDauer && position / dauer >= fertigAnteil
    }

    /// - Parameters:
    ///   - fertig: Wie viele Titel bisher fertig geschaut wurden.
    ///   - zuletztGefragt: Die Fassung, in der zuletzt gefragt wurde.
    ///   - fassung: Die laufende Fassung.
    public static func faellig(fertig: Int, zuletztGefragt: String?, fassung: String) -> Bool {
        fertig >= schwelle && zuletztGefragt != fassung
    }
}
