import SwiftUI

/// Die Farben — das einzige Stück Erscheinungsbild, das beide Plattformen
/// wörtlich teilen.
///
/// Maße und Schriftgrößen stehen bewusst **nicht** hier: iPhone und Apple TV
/// haben nichts gemeinsam, was Abstände angeht. Ein Poster misst auf dem
/// iPhone 112 × 168 und auf dem Fernseher 208 × 312, und eine Zeile, die auf
/// Armlänge mit 15 Punkt lesbar ist, braucht über drei Meter 29. Jede
/// Plattform erweitert `Stil` deshalb um ihre eigenen Werte —
/// `Sources/iOS/Stil.swift` und `Sources/tvOS/Stil.swift`.
///
/// Die Farben dagegen sind Entfernung egal. Sie liegen einmal hier, damit sie
/// nicht auseinanderlaufen.
enum Stil {

    /// Fast schwarz, aber nicht ganz — reines Schwarz wirkt auf OLED hart,
    /// wo Flächen aneinanderstoßen.
    static let grund   = Color(red: 0.043, green: 0.043, blue: 0.051)   // #0B0B0D
    static let flaeche = Color(red: 0.086, green: 0.086, blue: 0.098)   // #161619
    static let erhoeht = Color(red: 0.118, green: 0.118, blue: 0.133)   // #1E1E22

    static let schrift          = Color.white
    static let schriftLeise     = Color.white.opacity(0.62)

    /// **0,48 und nicht 0,38 — bei 0,38 war es zu blass, um es zu lesen.**
    ///
    /// Ausgerechnet, nicht geschaetzt. Weiss mit 0,38 Deckkraft ergibt gegen
    /// die drei Untergruende dieser App Kontraste von 3,52 (`grund`), 3,58
    /// (`flaeche`) und 3,54 (`erhoeht`). Gefordert sind fuer Text unter 18 pt
    /// **4,5** — und dieser Ton traegt genau solchen Text: Nebenzeilen,
    /// Hinweise, Leerzustaende, quer durch alle sechs Fassungen bei 12 bis
    /// 13 pt.
    ///
    /// 0,46 haette gereicht (4,67 / 4,65 / 4,54), liegt aber auf `erhoeht`
    /// nur vier Hundertstel ueber der Schwelle — eine Nachkommastelle
    /// Rundung, und wir waeren wieder darunter. 0,48 traegt mit 4,99 / 4,96 /
    /// 4,82 und bleibt trotzdem deutlich hinter `schriftLeise` (7,73)
    /// zurueck: die Abstufung, um die es hier geht, bleibt sichtbar.
    ///
    /// Der Ton traegt auch Zeichen und Kreise, die keine 4,5 braeuchten. Die
    /// werden dadurch eine Spur heller — kein Verlust, und es waere die
    /// falsche Reihenfolge, achtundachtzig Aufrufstellen einzeln zu sortieren,
    /// um einem Zeichen sein Grau zu erhalten.
    static let schriftSehrLeise = Color.white.opacity(0.48)
    static let linie            = Color.white.opacity(0.07)
    static let rand             = Color.white.opacity(0.12)

    /// Trägt nur Fortschritt, Auswahl und den Direct-Play-Beleg — nie
    /// Flächen oder Knöpfe. Bewusst weder Plex-Orange noch Netflix-Rot.
    ///
    /// Auf tvOS trägt er zusätzlich den Fokusring — das ist dieselbe Regel,
    /// nicht ihre Aufweichung: der Ring zeigt eine Auswahl.
    static let akzent  = Color(red: 0.361, green: 0.820, blue: 0.761)   // #5CD1C2

    /// Erscheint ausschließlich, wenn der Server transkodiert.
    static let warnung = Color(red: 0.910, green: 0.514, blue: 0.227)   // #E8833A
}
