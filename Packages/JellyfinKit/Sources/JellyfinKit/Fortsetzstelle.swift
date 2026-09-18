import Foundation

/// Ab welcher Sekunde fortgesetzt wird — oder gar nicht.
///
/// **Die Regel hatte nur eine Haelfte.** „Unter einer Minute lohnt
/// Fortsetzen nicht" stand seit jeher da; dass es am *anderen* Ende genauso
/// ist, stand nirgends. Eine Stelle drei Sekunden vor Schluss ist als
/// „weiterschauen" sinnlos — dafuer ist diese Datei da.
///
/// **Sie ist ausdruecklich nicht die Behebung, als die sie entstand.** Am
/// 04.09.2026 sprang die App zweimal in die naechste Folge, und ich hielt
/// die Fortsetzstelle fuer den Grund: 3707 s, dann 3721 s, beides klang nach
/// dem Ende einer Folge. Die Messung sagt etwas anderes — `Stelle 3721 s,
/// Laufzeit 6683 s`, also knapp ueber der Haelfte. Die Ursache lag bei
/// `:start-time` selbst und ist weiterhin offen.
///
/// Der Eintrag steht hier, damit niemand diese Regel fuer die Loesung jenes
/// Fehlers haelt und die Suche dort beendet.
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
