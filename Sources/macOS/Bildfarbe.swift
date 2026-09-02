import AppKit
import SwiftUI

/// Die vorherrschende Farbe eines Bildes.
///
/// Apple TV legt über sein Coverbild keinen schwarzen, sondern einen
/// **eingefärbten** Auslauf: unten geht das Bild in einen Ton über, der aus
/// ihm selbst stammt. Deshalb wirkt die Seite wie aus einem Guss, während ein
/// schwarzer Verlauf das Bild abschneidet.
///
/// Gerechnet wird auf einem einzigen Bildpunkt: Das Bild wird auf 1 × 1
/// verkleinert, und was dabei herauskommt, ist der Mittelwert. Genauer geht
/// es mit Häufungsverfahren, aber der Mittelwert trifft den Eindruck gut und
/// kostet nichts.
///
/// Der Ton wird danach **abgedunkelt und entsättigt**, sonst leuchtet die
/// halbe Seite in Orange — die Gestaltung will das Bild als einzige Farbe im
/// Raum, nicht die Fläche darunter.
@MainActor
@Observable
final class Bildfarbe {
    private(set) var ton: Color = Stil.grund
    private var geladen: URL?

    func laden(_ url: URL?) async {
        guard let url, url != geladen else { return }
        geladen = url
        // **Nicht `Data(contentsOf:)`.** Das ist ein blockierender Aufruf und
        // hier auf dem Hauptakteur — die Oberfläche stünde still, solange das
        // Bild lädt. `URLSession` gibt den Lauf frei.
        guard let (daten, _) = try? await URLSession.shared.data(from: url),
              let bild = NSImage(data: daten) else { return }
        // Das Rechnen selbst ist billig (ein Bildpunkt), darf also bleiben.
        ton = Self.mittelwert(bild) ?? Stil.grund
    }

    private static func mittelwert(_ bild: NSImage) -> Color? {
        guard let quelle = bild.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        var punkt: [UInt8] = [0, 0, 0, 0]
        guard let raum = CGColorSpace(name: CGColorSpace.sRGB),
              let zeichnung = CGContext(data: &punkt, width: 1, height: 1,
                                        bitsPerComponent: 8, bytesPerRow: 4,
                                        space: raum,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        zeichnung.interpolationQuality = .medium
        zeichnung.draw(quelle, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        let farbe = NSColor(srgbRed: CGFloat(punkt[0]) / 255,
                            green: CGFloat(punkt[1]) / 255,
                            blue: CGFloat(punkt[2]) / 255, alpha: 1)
        guard let hsb = farbe.usingColorSpace(.deviceRGB) else { return nil }

        // Abdunkeln und entsättigen: der Ton soll den Grundton einfärben,
        // nicht ersetzen. 26 % Helligkeit liegt nah an `Stil.grund` (5 %),
        // bleibt aber erkennbar warm oder kalt.
        return Color(hue: Double(hsb.hueComponent),
                     saturation: Double(min(hsb.saturationComponent, 0.45)),
                     brightness: 0.26)
    }
}
