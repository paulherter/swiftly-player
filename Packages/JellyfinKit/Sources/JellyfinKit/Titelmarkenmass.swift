import Foundation

/// Was eine Vermessung an einem Titel-Logo ergibt: der deckende Ausschnitt,
/// wie voll er ist und wie hell.
public struct Logomessung: Equatable, Sendable {
    /// Ausschnitt in Pixeln, ohne transparenten Rand.
    public let x: Int, y: Int, breite: Int, hoehe: Int
    /// Anteil deckender Pixel im Ausschnitt, 0…1.
    public let dichte: Double
    /// Mittlere relative Luminanz der deckenden Pixel, 0…1.
    public let luminanz: Double

    public var seitenverhaeltnis: Double { Double(breite) / Double(max(hoehe, 1)) }
}

/// Die Rechenregeln für Titel-Logos: zuschneiden, messen, Größe wählen.
/// Reine Funktionen — die Bildarbeit selbst steht in der Oberfläche.
public enum Titelmarkenmass {
    /// Ab hier gilt ein Pixel als deckend (von 255).
    public static let alphaSchwelle: UInt8 = 8
    /// Darunter gilt ein Logo als dunkel und wird als helle Silhouette gezeichnet.
    public static let dunkelGrenze = 0.25

    /// Vermisst ein Bild aus 8-Bit-RGBA, **vormultipliziert** (Zeile für
    /// Zeile, `breite * 4` Byte). `nil`, wenn nichts deckt.
    public static func messen(rgba: [UInt8], breite: Int, hoehe: Int) -> Logomessung? {
        guard breite > 0, hoehe > 0, rgba.count >= breite * hoehe * 4 else { return nil }
        var links = breite, rechts = -1, oben = hoehe, unten = -1
        for y in 0..<hoehe {
            let zeile = y * breite * 4
            for x in 0..<breite where rgba[zeile + x * 4 + 3] > alphaSchwelle {
                if x < links { links = x }
                if x > rechts { rechts = x }
                if y < oben { oben = y }
                unten = y
            }
        }
        guard rechts >= links, unten >= oben else { return nil }
        var deckend = 0
        var lichtsumme = 0.0
        for y in oben...unten {
            let zeile = y * breite * 4
            for x in links...rechts {
                let i = zeile + x * 4
                let a = Double(rgba[i + 3]) / 255
                guard rgba[i + 3] > alphaSchwelle else { continue }
                deckend += 1
                // Vormultipliziert: durch Alpha teilen, dann linearisieren.
                let r = linear(Double(rgba[i]) / 255 / a)
                let g = linear(Double(rgba[i + 1]) / 255 / a)
                let b = linear(Double(rgba[i + 2]) / 255 / a)
                lichtsumme += 0.2126 * r + 0.7152 * g + 0.0722 * b
            }
        }
        let b = rechts - links + 1, h = unten - oben + 1
        return Logomessung(x: links, y: oben, breite: b, hoehe: h,
                           dichte: Double(deckend) / Double(b * h),
                           luminanz: deckend > 0 ? lichtsumme / Double(deckend) : 1)
    }

    private static func linear(_ c: Double) -> Double {
        let c = min(max(c, 0), 1)
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    public static func istDunkel(luminanz: Double) -> Bool { luminanz < dunkelGrenze }

    /// Sanfter Ausgleich: sehr volle Logos etwas kleiner, sehr dünne etwas
    /// größer — 0,85…1,15.
    public static func dichtefaktor(_ dichte: Double) -> Double {
        let d = max(dichte, 0.05)
        return min(max((0.5 / d).squareRoot(), 0.85), 1.15)
    }

    /// Größe für gleiches optisches Gewicht: über eine Zielfläche statt einer
    /// festen Höhe. `zeile` ist eine Titelzeile in Punkten.
    ///
    /// h = √(Fläche / Seitenverhältnis) · Dichtefaktor, w = h · Seitenverhältnis;
    /// dann mindestens eine Zeile hoch, höchstens 2,2 Zeilen hoch und
    /// `maxBreite` breit (und, falls gesetzt, höchstens `maxHoehe` hoch) — die
    /// Obergrenzen gewinnen.
    public static func groesse(seitenverhaeltnis: Double, dichte: Double,
                               zeile: Double, maxBreite: Double,
                               maxHoehe: Double? = nil) -> (breite: Double, hoehe: Double) {
        let v = max(seitenverhaeltnis, 0.05)
        let flaeche = 12 * zeile * zeile
        var h = (flaeche / v).squareRoot() * dichtefaktor(dichte)
        h = max(h, zeile)
        h = min(h, 2.2 * zeile)
        // Ein Titelfach fester Höhe (Mac, Fernseher) geht vor der Mindesthöhe.
        if let maxHoehe { h = min(h, max(maxHoehe, 1)) }
        var w = h * v
        if w > maxBreite {
            w = max(maxBreite, 1)
            h = w / v
        }
        return (w, h)
    }
}
