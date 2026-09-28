import Foundation

/// **Beim Spulen rastet der Regler an den Abschnittsgrenzen ein.**
///
/// Die Kerben auf der Leiste zeigen, wo Vorspann und Abspann anfangen und
/// aufhören. Mit dem Daumen trifft man die Stelle auf ein paar Punkt genau —
/// bei einer Folge von 45 Minuten sind das zehn, zwanzig Sekunden daneben.
/// Kommt der Finger nah genug an eine Kerbe, steht der Regler genau darauf,
/// und ein leichter Tick sagt, dass er dort sitzt.
///
/// Gemessen wird in Punkt, nicht in Sekunden: die Hand trifft auf dem
/// Bildschirm, und eine lange Laufzeit soll das Einrasten nicht breiter
/// machen.
public enum Kerbenfang {

    /// So nah muss der Finger an die Kerbe, in Punkt.
    public static let fangweite: Double = 8

    /// Die Kerbe, auf der der Regler stehen soll, oder `nil`, wenn keine nah
    /// genug ist. Bei zweien die nähere.
    ///
    /// - Parameters:
    ///   - wert: die Stelle unter dem Finger, in Sekunden.
    ///   - bis: die Laufzeit, in Sekunden.
    ///   - marken: die Abschnittsgrenzen, in Sekunden.
    ///   - breite: die Breite der Leiste, in Punkt.
    public static func kerbe(wert: Double, bis: Double, marken: [Double],
                             breite: Double) -> Double? {
        guard bis > 0, breite > 0, wert.isFinite else { return nil }
        let proPunkt = bis / breite
        let weite = fangweite * proPunkt
        return marken
            .filter { $0 > 0 && $0 < bis }
            .map { ($0, abs($0 - wert)) }
            .filter { $0.1 <= weite }
            .min { $0.1 < $1.1 }?.0
    }
}
