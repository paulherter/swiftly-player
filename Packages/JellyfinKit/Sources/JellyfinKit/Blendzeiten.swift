import Foundation

/// **Wie lange etwas ein- und ausblendet** — eine Stelle für den Mac, Linux
/// und Windows.
///
/// Stand bis 27.09.2026 als Kopie auf jeder Plattform: der Mac hatte
/// `zeitBereichHinaus`/`zeitBereichHerein` in `Sources/macOS/Stil.swift`,
/// Linux dieselben Zahlen noch einmal in seinem `Stil`. Beide waren
/// auseinandergelaufen, und beide haben **überblendet**.
///
/// Nur Deckkraft, keine Effekte (keine Unschärfe, kein Zoom).
public enum Blendzeiten {

    // MARK: Seitenwechsel — erst weg, dann da

    /// **Die alte Seite geht zuerst**, kurz und mit `easeIn`: sie nimmt
    /// Fahrt auf und ist weg, bevor man hinsieht.
    ///
    /// Vorher überlappten Hinaus (0,20 s) und Herein (0,26 s ab 0,04 s). In
    /// der Mitte standen damit beide Seiten halb durchsichtig übereinander —
    /// eine Überblendung, und die wirkt unsauber (Rückmeldung vom 27.09.).
    public static let seiteHinaus = 0.12
    /// **Danach kommt die neue**, mit `easeOut`. Sie beginnt genau dort, wo
    /// die alte endet — nie beide gleichzeitig.
    public static let seiteHerein = 0.22
    /// Hinaus und Herein hintereinander.
    public static var seiteGesamt: Double { seiteHinaus + seiteHerein }

    /// Deckung der alten und der neuen Seite nach `t` Sekunden.
    ///
    /// Solange die alte noch zu sehen ist, ist die neue es nicht — das ist
    /// die ganze Regel, und der Test hält sie fest.
    public static func seitenwechsel(_ t: Double) -> (alt: Double, neu: Double) {
        let a = min(max(t / seiteHinaus, 0), 1)
        let b = min(max((t - seiteHinaus) / seiteHerein, 0), 1)
        return (1 - easeIn(a), easeOut(b))
    }

    // MARK: Einzelne Dinge

    /// **Die Blätterpfeile einer Reihe**, beim Überfahren und wenn am Ende
    /// nichts mehr zu blättern ist: weich, `easeInOut`. Vorher erschienen sie
    /// auf Linux hart und auf dem Mac in 0,12 s.
    public static let pfeile = 0.18

    /// **Hintergrundbild und Bildton einer Detailseite**, wenn sie nach dem
    /// Öffnen eintreffen: `easeOut`, so lang wie der Bildton auf dem iPhone
    /// (`Stimmungslader`, `.smooth(duration: 0.55)`). Was schon gemerkt ist,
    /// steht sofort da und blendet nicht.
    public static let kopfbild = 0.55

    // MARK: Kurven

    /// `easeIn` wie in CSS und SwiftUI (`cubic-bezier(0.42, 0, 1, 1)`).
    public static func easeIn(_ t: Double) -> Double { bezier(t, 0.42, 0, 1, 1) }
    /// `easeOut` wie in CSS und SwiftUI (`cubic-bezier(0, 0, 0.58, 1)`).
    public static func easeOut(_ t: Double) -> Double { bezier(t, 0, 0, 0.58, 1) }
    /// `easeInOut` wie in CSS und SwiftUI (`cubic-bezier(0.42, 0, 0.58, 1)`).
    public static func easeInOut(_ t: Double) -> Double { bezier(t, 0.42, 0, 0.58, 1) }

    /// Eine kubische Bézierkurve durch (0, 0) und (1, 1): zu `t` auf der
    /// Zeitachse der Wert — über Newton, acht Schritte reichen.
    public static func bezier(_ t: Double, _ x1: Double, _ y1: Double,
                              _ x2: Double, _ y2: Double) -> Double {
        let t = min(max(t, 0), 1)
        func b(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
            3 * p1 * (1 - s) * (1 - s) * s + 3 * p2 * (1 - s) * s * s + s * s * s
        }
        func db(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
            3 * p1 * (1 - s) * (1 - s) + 6 * (p2 - p1) * (1 - s) * s + 3 * (1 - p2) * s * s
        }
        var s = t
        for _ in 0..<8 {
            let d = db(s, x1, x2)
            guard abs(d) > 1e-6 else { break }
            s = min(max(s - (b(s, x1, x2) - t) / d, 0), 1)
        }
        return b(s, y1, y2)
    }
}
