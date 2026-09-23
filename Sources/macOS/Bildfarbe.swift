import CoreGraphics
import ImageIO
import JellyfinKit
import SwiftUI

/// Die vorherrschende Farbe eines Bildes.
///
/// Apple TV legt über sein Coverbild keinen schwarzen, sondern einen
/// **eingefärbten** Auslauf: unten geht das Bild in einen Ton über, der aus
/// ihm selbst stammt. Deshalb wirkt die Seite wie aus einem Guss, während ein
/// schwarzer Verlauf das Bild abschneidet.
///
/// Gerechnet wird auf einem einzigen Bildpunkt: Das Bild wird auf 1 × 1
/// verkleinert, und was dabei herauskommt, ist der Mittelwert.
///
/// **Das Rechnen läuft nicht auf dem Hauptlauf.** Es sieht billig aus — ein
/// Bildpunkt —, aber davor steht das Dekodieren des ganzen Bildes, und das
/// sind bei einer 1600er Kulisse einige Millisekunden. Sie fielen genau in
/// den Moment, in dem die Seite hereinfährt: das Einfahren ruckelte, das
/// Hinausfahren nicht, weil dort nichts mehr zu bauen war.
@MainActor
@Observable
final class Bildfarbe {
    private(set) var ton: Color = Stil.grund
    private var geladen: URL?

    func laden(_ url: URL?) async {
        guard let url, url != geladen else { return }
        // **Erst merken, wenn es geklappt hat.** Hier stand `geladen = url`
        // vor dem Abruf. Scheitert der — ein Aussetzer genügt —, galt die
        // Adresse trotzdem als erledigt und wurde nie wieder versucht: der
        // Kopf behielt den Ton der vorigen Seite. Dieselbe Klasse Fehler wie
        // ein Zustand, der gesetzt wird, bevor die Sache geglückt ist.
        guard let (daten, _) = try? await URLSession.shared.data(for: .mitEigenenKoepfen(url)) else { return }
        geladen = url
        // Dekodieren und rechnen abseits des Hauptlaufs.
        let gerechnet = await Task.detached(priority: .utility) {
            Self.tonwerte(aus: daten)
        }.value
        guard let werte = gerechnet else { return }
        // Abdunkeln und entsättigen: der Ton soll den Grundton einfärben,
        // nicht ersetzen.
        //
        // **Die Toenung ist nie heller als `Stil.flaeche`.** Sie stand auf
        // 26 %, und das ist heller als `erhoeht` (18,8 %), also heller als
        // die hellste Stufe der Leiter. Nachgerechnet fuer die Knopfreihe
        // unter dem Abspielknopf: der Verlauf laeuft ueber `heldHoehe + 260`
        // = 640 Punkt, die Reihe sitzt mit ihrer Mitte bei 356, also bei
        // 55,6 % — dort kam 0,26 − (0,26 − 0,063) × 0,556 = **0,150** heraus.
        // `Stil.flaeche` ist 0,149. Die Knoepfe standen damit auf genau
        // ihrer eigenen Farbe und waren als Knoepfe nicht mehr zu sehen;
        // Paul am 22.09.: „die Buttons sind doch viel heller" als am iPhone,
        // wo dieselbe Reihe auf `grund` steht.
        //
        // 14,6 % ist der groesste Wert, bei dem die Toenung unter `flaeche`
        // bleibt. An der Knopfreihe kommen damit 0,101 an — eine volle Stufe
        // unter den Knoepfen. Oben bleibt der Ton sichtbar, nur ruhiger.
        // **Nicht springen.** Der Ton färbt einen bildschirmhohen Verlauf;
        // schlägt er ohne Anweisung um, blitzt die halbe Seite die Farbe
        // gewechselt auf. Das kommt aus dem Netz und trifft die Seite
        // irgendwann — oft mitten im Hereinfahren.
        withAnimation(.easeInOut(duration: 0.40)) {
            ton = Color(hue: werte.farbton, saturation: min(werte.saettigung, 0.45),
                        brightness: 0.146)
        }
    }

    /// Farbton und Sättigung des Mittelwerts — **ohne AppKit**, damit die
    /// Rechnung von jedem Lauf aus gehen darf.
    private nonisolated static func tonwerte(aus daten: Data)
        -> (farbton: Double, saettigung: Double)? {
        guard let quelle = CGImageSourceCreateWithData(daten as CFData, nil),
              let bild = CGImageSourceCreateImageAtIndex(quelle, 0, nil),
              let raum = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        var punkt: [UInt8] = [0, 0, 0, 0]
        guard let zeichnung = punkt.withUnsafeMutableBytes({ speicher in
            CGContext(data: speicher.baseAddress, width: 1, height: 1,
                      bitsPerComponent: 8, bytesPerRow: 4, space: raum,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }) else { return nil }
        zeichnung.interpolationQuality = .medium
        zeichnung.draw(bild, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let ergebnis = zeichnung.data else { return nil }
        let werte = ergebnis.assumingMemoryBound(to: UInt8.self)

        let r = Double(werte[0]) / 255, g = Double(werte[1]) / 255, b = Double(werte[2]) / 255
        let hoch = max(r, g, b), tief = min(r, g, b), spanne = hoch - tief
        guard spanne > 0 else { return (0, 0) }

        var farbton: Double
        switch hoch {
        case r:  farbton = (g - b) / spanne
        case g:  farbton = 2 + (b - r) / spanne
        default: farbton = 4 + (r - g) / spanne
        }
        farbton /= 6
        if farbton < 0 { farbton += 1 }
        return (farbton, hoch > 0 ? spanne / hoch : 0)
    }
}
