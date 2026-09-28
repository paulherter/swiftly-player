import Foundation

/// **Die Rechnung hinter der Bildfarbe** — aus den Punkten eines Bildes die
/// Töne, und aus den Tönen die Farbe an jeder Stelle einer Seite.
///
/// Stand bis 27.09.2026 in `Sources/Shared/Bildton.swift` (Apple) und als
/// Kotlin-Abschrift in `TvBildgrund.kt` (Android TV). Die Abschrift kannte den
/// OKLab-Auslauf nicht und lief damit schon auseinander; jetzt rechnen Apple
/// und Android dieselben Zahlen aus derselben Stelle. Das Entschlüsseln des
/// Bildes und das Zeichnen bleiben bei der Plattform.
///
/// Begründungen der einzelnen Schritte (Rundmittel, Gewicht mit dem Quadrat
/// der Sättigung, mehrere Gipfel, nur der Ton aus dem Bild) stehen an
/// `Bildton` in `Sources/Shared/Bildton.swift`.
public enum Bildtonrechnung {

    // MARK: Zahlen (Stil-Tokens „Farbe aus dem Bild", `Farben.swift`)

    /// Sättigung fern der Kulisse.
    public static let saettigung = 0.38
    /// Was an der Kulisse an Sättigung dazukommt.
    public static let saettigungNah = 0.20
    /// Helligkeit fern der Kulisse — knapp über `grund`.
    public static let helligkeit = 0.075
    /// Was an der Kulisse an Helligkeit dazukommt.
    public static let helligkeitNah = 0.140
    /// Wie schnell die Helligkeit mit der Entfernung fällt (Exponent).
    public static let abfall = 1.6
    /// Wie weit die Nebentöne vom Hauptton abweichen dürfen (Anteil).
    public static let spannweite = 0.34

    /// `grund` (#101010) in OKLab — hier endet jeder Auslauf, exakt.
    public static let grundL = Farbwahl.oklab(16.0 / 255, 16.0 / 255, 16.0 / 255).L

    // MARK: Töne aus dem Bild

    /// Bis zu fünf Farbtöne in Grad, nach Gewicht — leer, wenn sich keiner
    /// ableiten lässt. `rgba`: Punkte zu je vier Byte (Rot, Grün, Blau,
    /// Deckung), am besten auf höchstens 48 Punkt Kante verkleinert.
    public static func toene(rgba punkte: [UInt8]) -> [Double] {
        let faecher = 36
        var korb = [Double](repeating: 0, count: faecher)
        var gesamt = 0.0

        var i = 0
        while i + 3 < punkte.count {
            let r = Double(punkte[i]) / 255
            let g = Double(punkte[i + 1]) / 255
            let b = Double(punkte[i + 2]) / 255
            i += 4

            let hoch = max(r, g, b), tief = min(r, g, b)
            let spanne = hoch - tief
            guard spanne > 0.04, hoch > 0.08 else { continue }

            let saettigung = spanne / hoch
            var ton: Double
            switch hoch {
            case r: ton = (g - b) / spanne
            case g: ton = 2 + (b - r) / spanne
            default: ton = 4 + (r - g) / spanne
            }
            ton *= 60
            if ton < 0 { ton += 360 }

            let gewicht = saettigung * saettigung * hoch
            korb[min(faecher - 1, Int(ton / 10))] += gewicht
            gesamt += gewicht
        }

        guard gesamt > 0.5 else { return [] }

        // Gipfel ziehen: stärkstes Fach, dann das stärkste mit mindestens
        // drei Fächern (30 Grad) Abstand, und so weiter.
        var gewaehlt: [Double] = []
        var uebrig = korb
        for _ in 0 ..< 5 {
            guard let (fach, wert) = uebrig.enumerated().max(by: { $0.element < $1.element }),
                  wert > gesamt * 0.035 else { break }
            // Der genaue Ton kommt aus dem Fach und seinen Nachbarn, damit er
            // nicht auf Zehnergrad einrastet.
            var x = 0.0, y = 0.0
            for versatz in -1 ... 1 {
                let f = (fach + versatz + faecher) % faecher
                let bogen = (Double(f) * 10 + 5) * .pi / 180
                x += cos(bogen) * korb[f]
                y += sin(bogen) * korb[f]
            }
            var grad = atan2(y, x) * 180 / .pi
            if grad < 0 { grad += 360 }
            gewaehlt.append(grad)
            for versatz in -1 ... 1 { uebrig[(fach + versatz + faecher) % faecher] = 0 }
        }
        return gewaehlt
    }

    // MARK: Farbe an einer Stelle

    /// Der Farbton an der Stelle `lauf` (0…1) — zwischen den gefundenen Tönen
    /// übergeblendet, über den kürzesten Weg auf dem Farbkreis; jeder Ton
    /// rückt dabei um ``spannweite`` zur Hauptfarbe hin.
    public static func tonBei(_ toene: [Double], _ lauf: Double) -> Double {
        guard let leit = toene.first else { return 0 }
        func gedaempft(_ ton: Double) -> Double {
            var weg = ton - leit
            if weg > 180 { weg -= 360 }
            if weg < -180 { weg += 360 }
            return leit + weg * spannweite
        }
        guard toene.count > 1 else { return leit }

        let stelle = lauf * Double(toene.count - 1)
        let a = max(0, min(Int(stelle), toene.count - 2))
        let t = stelle - Double(a)

        let von = gedaempft(toene[a]), bis = gedaempft(toene[a + 1])
        var weg = bis - von
        if weg > 180 { weg -= 360 }
        if weg < -180 { weg += 360 }
        var ton = von + weg * (t * t * (3 - 2 * t))
        if ton < 0 { ton += 360 }
        if ton >= 360 { ton -= 360 }
        return ton
    }

    /// Ton, Sättigung und Helligkeit (je 0…1, Ton in Grad) an einer Stelle
    /// der Fläche: `x` von links nach rechts, `y` von oben nach unten, beide
    /// 0…1. Die Kulisse sitzt oben rechts — dort am hellsten.
    public static func hsb(_ toene: [Double], x: Double, y: Double)
        -> (ton: Double, saettigung: Double, helligkeit: Double) {
        let dx = 1 - x, dy = y
        let naehe = 1 - min(1, (dx * dx + dy * dy).squareRoot() / 1.414)
        return (tonBei(toene, (x + y) / 2),
                saettigung + saettigungNah * naehe,
                helligkeit + helligkeitNah * pow(naehe, abfall))
    }

    /// Dieselbe Farbe als sRGB (0…1), und `abklingen` (1 … 0) führt sie auf
    /// `grund` zurück — **in OKLab**: Helligkeit und Buntheit gemeinsam, bis
    /// bei 0 genau `grund` steht. Ohne Töne: `grund`.
    public static func farbe(_ toene: [Double], x: Double, y: Double, abklingen f: Double = 1)
        -> (r: Double, g: Double, b: Double) {
        let grau = 16.0 / 255
        guard !toene.isEmpty else { return (grau, grau, grau) }
        let t = hsb(toene, x: x, y: y)
        let rgb = hsbNachRGB(t.ton, t.saettigung, t.helligkeit)
        if f >= 1 { return rgb }
        let lab = Farbwahl.oklab(rgb.r, rgb.g, rgb.b)
        let L = grundL + (lab.L - grundL) * f
        return Farbwahl.srgb(L: L, a: lab.a * f, b: lab.b * f) ?? (L, L, L)
    }

    /// Wie weit die Farbe auf dem Weg in den Grund noch steht (1 … 0): bis
    /// `ab` ganz, dann über `auslauf` auf einer Glättkurve (smootherstep)
    /// genau bis null — ohne Knick an Anfang und Ende.
    public static func abklingen(y: Double, ab: Double, auslauf: Double) -> Double {
        guard auslauf > 0 else { return y < ab ? 1 : 0 }
        let t = max(0, min(1, (y - ab) / auslauf))
        return 1 - t * t * t * (t * (t * 6 - 15) + 10)
    }

    /// **Das Netz einer Detailseite, die in `grund` ausläuft**, als Punkte:
    /// `spalten` × `zeilen` Farben (Zeile für Zeile, ARGB mit voller Deckung)
    /// über die Höhe `hoehe`. Oben das Bild des Fernsehers über `farbhoehe`,
    /// ab `ab` über `auslauf` exakt bis `grund`. Die Plattform zieht die
    /// Punkte weich auf die Fläche (bilinear) — das ersetzt das Netz, das
    /// SwiftUI als `MeshGradient` hat. Ohne Auslauf (`auslauf` 0, `ab` ≥
    /// `hoehe`) ist es der Grund einer ganzen Seite wie auf dem Fernseher.
    public static func punkte(_ toene: [Double], spalten: Int, zeilen: Int, hoehe: Double,
                              farbhoehe: Double, ab: Double, auslauf: Double) -> [Int32] {
        guard spalten > 1, zeilen > 1, hoehe > 0 else { return [] }
        var aus: [Int32] = []
        aus.reserveCapacity(spalten * zeilen)
        for z in 0 ..< zeilen {
            let y = hoehe * Double(z) / Double(zeilen - 1)
            let f = abklingen(y: y, ab: ab, auslauf: auslauf)
            for s in 0 ..< spalten {
                let x = Double(s) / Double(spalten - 1)
                let c = farbe(toene, x: x, y: min(1, y / max(farbhoehe, 1)), abklingen: f)
                func k(_ w: Double) -> UInt32 { UInt32(max(0, min(255, (w * 255).rounded()))) }
                let argb: UInt32 = 0xFF00_0000 | (k(c.r) << 16) | (k(c.g) << 8) | k(c.b)
                aus.append(Int32(bitPattern: argb))
            }
        }
        return aus
    }

    /// HSB nach sRGB (0…1).
    public static func hsbNachRGB(_ h: Double, _ s: Double, _ v: Double) -> (r: Double, g: Double, b: Double) {
        let c = v * s, hh = h / 60, x = c * (1 - abs(hh.truncatingRemainder(dividingBy: 2) - 1)), m = v - c
        switch Int(hh) % 6 {
        case 0: return (c + m, x + m, m)
        case 1: return (x + m, c + m, m)
        case 2: return (m, c + m, x + m)
        case 3: return (m, x + m, c + m)
        case 4: return (x + m, m, c + m)
        default: return (c + m, m, x + m)
        }
    }
}
