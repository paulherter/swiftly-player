import Foundation

/// Die Abspielgeschwindigkeiten, die der Player anbietet.
///
/// Fünf Zahlen, die niemand für Logik hält — und genau deshalb standen sie
/// dreimal da, einmal je Plattform. Nimmt eine davon irgendwann 0,5× dazu,
/// haben die anderen es nicht.
public enum Tempostufen {

    public static let werte: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    /// „1,25×" auf Deutsch, „1.25×" auf Englisch.
    ///
    /// **Nicht `String(format: "%g", …)` mit ausgetauschtem Punkt.** So stand
    /// es in der iPhone-Fassung, und es setzte das Komma fest: Englisch sah
    /// „1,25×". Die sprachbewusste Ausgabe trifft beide Fälle und kürzt
    /// „1,0" ebenso zu „1", worauf es bei `%g` ankam.
    public static func beschriftung(_ wert: Float) -> String {
        wert.formatted(.number) + "×"
    }
}

/// Die Stufen des Schlafzeitgebers, in Minuten.
///
/// Dieselbe Geschichte wie bei den Tempostufen: dreimal dieselbe Liste.
public enum Schlafzeiten {
    public static let werte = [15, 30, 45, 60, 90]
}

/// Die laufende Zeit im Player: „1:23" oder „1:23:45".
///
/// Stand dreimal da, einmal je Plattform, und war noch gleich — verschiedene
/// Variablennamen, dasselbe Ergebnis. Genau der Zustand, aus dem
/// `Titelangaben` einmal herausgewachsen ist, bevor eine Fassung die Stunden
/// vergaß.
///
/// Bewusst **nicht** sprachbewusst: Doppelpunkt und Nullen sind bei
/// Laufzeiten überall gleich, anders als beim Dezimaltrenner der Tempostufen.
public enum Spielzeit {
    public static func text(_ sekunden: Double) -> String {
        guard sekunden.isFinite, sekunden >= 0 else { return "0:00" }
        let ganz = Int(sekunden)
        let s = ganz % 60, m = (ganz / 60) % 60, h = ganz / 3600
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}
