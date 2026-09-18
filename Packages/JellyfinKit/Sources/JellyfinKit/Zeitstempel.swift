import Foundation

/// Liest Jellyfins Zeitstempel.
///
/// **`.iso8601` reicht nicht, und das faellt nicht auf.** Der Server schickt
/// `2026-09-03T14:10:09.2201736Z` — sieben Nachkommastellen. Swifts
/// `dateDecodingStrategy = .iso8601` kennt keine Bruchteile und wirft; steht
/// das Feld dann in einem `try?`, verschwindet der Wert lautlos. Am Server
/// nachgemessen, an `/Sessions`.
///
/// Genau daran waere die Stillefrist in ``Uebernahme`` gescheitert: ohne
/// Datum gilt eine Sitzung als frisch, und eine abgestuerzte App waere
/// minutenlang weiter zur Uebernahme angeboten worden.
///
/// Deshalb **zwei** Formen, in dieser Reihenfolge: mit Bruchteilen, dann
/// ohne. Beide kommen vor — `PremiereDate` etwa hat keine.
enum Zeitstempel {

    /// **Die Formatierer entstehen je Aufruf, und das ist Absicht.**
    ///
    /// `ISO8601DateFormatter` ist nicht `Sendable`; als geteilte Statische
    /// lehnt Swift 6 sie ab, und mit `nonisolated(unsafe)` waere es eine
    /// Zusicherung, die niemand geprueft hat. Hier laufen ein paar Aufrufe je
    /// Abfrage, keine Schleife — der Preis ist nicht messbar.
    static func lesen(aus decoder: any Decoder) throws -> Date {
        let text = try decoder.singleValueContainer().decode(String.self)

        let mitBruch = ISO8601DateFormatter()
        mitBruch.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = mitBruch.date(from: text) { return d }

        let ohneBruch = ISO8601DateFormatter()
        ohneBruch.formatOptions = [.withInternetDateTime]
        if let d = ohneBruch.date(from: text) { return d }

        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "Kein lesbarer Zeitstempel: \(text)"))
    }
}
