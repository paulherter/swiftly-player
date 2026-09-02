import CoreGraphics
import ImageIO
import SwiftUI

/// Ein Bild aus dem Netz — geholt, **abseits des Hauptlaufs entschlüsselt**,
/// gemerkt und eingeblendet.
///
/// Vorher stand hier `AsyncImage`. Drei Dinge waren daran falsch:
///
/// 1. **Es entschlüsselt auf dem Hauptlauf.** Ein Raster mit fünfzig Kacheln
///    entschlüsselt fünfzig Bilder dort, wo auch gezeichnet wird. Das ist
///    das „Stück für Stück", und beim Öffnen einer Seite ist es das Zucken.
/// 2. **Es merkt sich nichts.** Jedes Erscheinen lädt neu.
/// 3. **Die Einblendung lief nie.** `.animation(value: bild == nil)` hing an
///    einem Wert, der sich nach dem Anlegen nie wieder änderte — die Kurve
///    stand da, ist aber nie gefeuert. Deshalb sprangen die Bilder trotz
///    Kommentar weiterhin hart ins Bild.
///
/// Jetzt: `URLSession` holt, `CGImageSourceCreateThumbnailAtIndex` mit
/// `ShouldCacheImmediately` entschlüsselt in einer eigenen Aufgabe — dort,
/// wo es niemanden stört —, und erst das fertige Bild kommt zurück.

/// Ein `CGImage` über eine Laufgrenze tragen. `CGImage` ist unveränderlich,
/// nur nicht als `Sendable` erklärt.
private struct Bildkiste: @unchecked Sendable { let bild: CGImage }

@MainActor
final class Bildspeicher {
    static let geteilt = Bildspeicher()

    private var bekannt: [URL: Image] = [:]
    private var reihenfolge: [URL] = []
    /// Läufe, die schon unterwegs sind. Ohne das holt ein Raster dasselbe
    /// Bild mehrfach, wenn es in zwei Reihen vorkommt.
    private var laufend: [URL: Task<Image?, Never>] = [:]
    /// Genug für zwei volle Raster; darüber fliegt das Älteste raus.
    private let hoechstzahl = 240

    func bild(_ url: URL) -> Image? { bekannt[url] }

    func laden(_ url: URL) async -> Image? {
        if let da = bekannt[url] { return da }
        if let lauf = laufend[url] { return await lauf.value }

        let lauf = Task<Image?, Never> {
            guard let (daten, _) = try? await URLSession.shared.data(from: url) else { return nil }
            let kiste = await Task.detached(priority: .userInitiated) { () -> Bildkiste? in
                guard let quelle = CGImageSourceCreateWithData(daten as CFData, nil) else { return nil }
                let regeln: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    // **Der entscheidende Schalter.** Ohne ihn schiebt
                    // CoreGraphics das Entschlüsseln bis zum ersten Zeichnen
                    // auf — und das ist wieder der Hauptlauf.
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1600
                ]
                guard let roh = CGImageSourceCreateThumbnailAtIndex(
                    quelle, 0, regeln as CFDictionary) else { return nil }
                return Bildkiste(bild: roh)
            }.value
            guard let kiste else { return nil }
            return Image(decorative: kiste.bild, scale: 1)
        }

        laufend[url] = lauf
        let ergebnis = await lauf.value
        laufend[url] = nil
        if let ergebnis { merken(ergebnis, fuer: url) }
        return ergebnis
    }

    private func merken(_ bild: Image, fuer url: URL) {
        if bekannt[url] == nil { reihenfolge.append(url) }
        bekannt[url] = bild
        while reihenfolge.count > hoechstzahl {
            bekannt[reihenfolge.removeFirst()] = nil
        }
    }
}

struct Netzbild: View {
    let url: URL?
    /// Wie das Bild seine Fläche füllt.
    var art: ContentMode = .fill

    @State private var bild: Image?
    @State private var sichtbar = false

    /// **Was bekannt ist, steht sofort** — nicht erst im nächsten Durchgang.
    /// Ein nachgereichter Wert kommt zu spät, der leere Durchgang hat dann
    /// schon stattgefunden, und genau der ist das Aufblitzen.
    @MainActor init(url: URL?, art: ContentMode = .fill) {
        self.url = url
        self.art = art
        let sofort = url.flatMap { Bildspeicher.geteilt.bild($0) }
        _bild = State(initialValue: sofort)
        _sichtbar = State(initialValue: sofort != nil)
    }

    var body: some View {
        ZStack {
            if let bild {
                bild.resizable().aspectRatio(contentMode: art)
                    .opacity(sichtbar ? 1 : 0)
            }
        }
        .task(id: url) {
            guard let url else {
                if Ruckelwache.an, art == .fill {
                    Protokoll.schreib("Bild: KEINE Adresse")
                }
                return
            }
            guard bild == nil else {
                if Ruckelwache.an { Protokoll.schreib("Bild: sofort aus dem Speicher") }
                return
            }
            let start = Date()
            guard let geladen = await Bildspeicher.geteilt.laden(url) else {
                if Ruckelwache.an {
                    Protokoll.schreib("Bild: FEHLGESCHLAGEN nach "
                        + "\(Int(Date().timeIntervalSince(start) * 1000)) ms — \(url.lastPathComponent)")
                }
                return
            }
            if Ruckelwache.an {
                Protokoll.schreib("Bild: sichtbar nach "
                    + "\(Int(Date().timeIntervalSince(start) * 1000)) ms")
            }
            bild = geladen
            // 220 ms, dieselbe Zeit wie ein Sprung im Player — lang genug,
            // dass fünfzig Kacheln wie eine Bewegung wirken statt wie fünfzig.
            withAnimation(.easeOut(duration: 0.22)) { sichtbar = true }
        }
    }
}
