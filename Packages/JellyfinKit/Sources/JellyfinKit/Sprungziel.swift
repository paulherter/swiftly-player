import Foundation

/// **Eine Stelle im Titel, die sich sicher in ganze Millisekunden wandeln
/// laesst.**
///
/// Der Player rechnet Sprungziele in `Int(sekunden * 1000)` um, und diese
/// Umwandlung bricht das Programm ab, wenn der Wert NaN, unendlich oder
/// groesser als `Int` ist — sie prueft nicht, sie stuerzt. Ein solcher Wert
/// entsteht leicht: ein Anteil mal einer Laufzeit, die der Server als null
/// meldet, ein Fortschritt geteilt durch null. Deshalb wird am Eingang
/// begrenzt und nicht an jeder der Stellen, die spaeter umwandeln.
public enum Sprungziel {

    /// Rund elf Tage. Kein Titel ist so lang; die Grenze ist nur dafuer da,
    /// dass die Umwandlung in Millisekunden nie ueberlaeuft.
    public static let obergrenze: Double = 1_000_000

    /// Der Wert zwischen null und ``obergrenze`` — oder `nil`, wenn er keine
    /// Zahl ist.
    public static func sekunden(_ wert: Double) -> Double? {
        guard wert.isFinite else { return nil }
        return min(max(0, wert), obergrenze)
    }
}
