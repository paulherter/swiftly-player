import Foundation

/// Ab welcher Sekunde fortgesetzt wird — oder gar nicht.
///
/// **Die Regel hatte nur eine Haelfte.** „Unter einer Minute lohnt Fortsetzen
/// nicht" stand seit jeher da. Dass es am *anderen* Ende genauso ist, fiel
/// erst am 04.09.2026 auf, und zwar teuer: eine Folge lief durch, der Server
/// merkte sich 3707 s von 3707 s, und beim naechsten Oeffnen war das die
/// Fortsetzstelle. Die App setzte am Dateiende fort, VLC meldete sofort `end
/// of stream`, die Folgenende-Erkennung griff — und
///
/// Dass es vorher nicht auffiel, lag am Weg dorthin: der alte Sprung setzte
/// erst *nach* dem Anlaufen ein, und ein Sprung ans eigene Ende ist harmlos.
/// Der Fehler lag trotzdem schon da.
///
/// Deshalb hier, im Paket: eine Regel mit zwei Grenzen, ohne Abspieler
/// pruefbar, fuer alle vier Plattformen dieselbe.
public enum Fortsetzstelle {

    /// Darunter lohnt sich Fortsetzen nicht — wer eine halbe Minute gesehen
    /// hat, will von vorn.
    public static let mindestens: TimeInterval = 60

    /// So nah am Ende gilt der Titel als gesehen.
    ///
    /// Bewusst ein fester Abstand und kein Anteil: bei 90 % waeren es in
    /// einer Stunde sechs Minuten, und wer im Abspann aufhoert, will beim
    /// naechsten Mal genau dort weiter — nicht sechs Minuten frueher und
    /// erst recht nicht von vorn.
    public static let schlussabstand: TimeInterval = 60

    /// - Parameters:
    ///   - position: Die gemerkte Stelle in Sekunden.
    ///   - laufzeit: Die Laufzeit in Sekunden, oder `nil`, wenn der Server
    ///     keine nennt. Ohne Laufzeit greift nur die untere Grenze — raten
    ///     waere hier schlimmer als nichts zu tun.
    /// - Returns: Die Sekunde zum Fortsetzen, oder `nil` fuer „von vorn".
    public static func ab(position: Double?, laufzeit: Double?) -> Double? {
        guard let position, position > mindestens else { return nil }
        if let laufzeit, laufzeit > 0, position >= laufzeit - schlussabstand { return nil }
        return position
    }
}
