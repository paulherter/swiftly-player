import CoreGraphics
import ImageIO
import JellyfinKit
import SwiftUI

/// Ein vermessenes, zugeschnittenes Logo, fertig zum Zeichnen.
struct Titellogo: @unchecked Sendable {
    let bild: CGImage
    let messung: Logomessung
    var dunkel: Bool { Titelmarkenmass.istDunkel(luminanz: messung.luminanz) }
}

/// Holt Logos, schneidet den transparenten Rand ab, misst — abseits des
/// Hauptlaufs — und merkt das Ergebnis je Adresse.
@MainActor
final class Titellogospeicher {
    static let geteilt = Titellogospeicher()
    private var bekannt: [URL: Titellogo] = [:]
    /// Adressen ohne brauchbares Logo, damit nicht jedes Erscheinen neu holt.
    private var leer: Set<URL> = []
    private var laufend: [URL: Task<Titellogo?, Never>] = [:]

    func vorhanden(_ url: URL) -> Titellogo? { bekannt[url] }

    func laden(_ url: URL) async -> Titellogo? {
        if let da = bekannt[url] { return da }
        if leer.contains(url) { return nil }
        if let lauf = laufend[url] { return await lauf.value }
        let lauf = Task<Titellogo?, Never> {
            guard let (daten, antwort) = try? await URLSession.shared.data(for: .mitEigenenKoepfen(url)),
                  (antwort as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return await Task.detached(priority: .userInitiated) { Self.vermessen(daten) }.value
        }
        laufend[url] = lauf
        let ergebnis = await lauf.value
        laufend[url] = nil
        if let ergebnis { bekannt[url] = ergebnis } else { leer.insert(url) }
        return ergebnis
    }

    /// Entschlüsseln (höchstens 800 px), in RGBA vormultipliziert lesen,
    /// vermessen, auf die deckende Box zuschneiden.
    nonisolated private static func vermessen(_ daten: Data) -> Titellogo? {
        guard let quelle = CGImageSourceCreateWithData(daten as CFData, nil),
              let roh = CGImageSourceCreateThumbnailAtIndex(quelle, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: 800,
              ] as CFDictionary) else { return nil }
        let b = roh.width, h = roh.height
        var puffer = [UInt8](repeating: 0, count: b * h * 4)
        let gezeichnet = puffer.withUnsafeMutableBytes { rohbytes -> Bool in
            guard let ctx = CGContext(data: rohbytes.baseAddress, width: b, height: h,
                                      bitsPerComponent: 8, bytesPerRow: b * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(roh, in: CGRect(x: 0, y: 0, width: b, height: h))
            return true
        }
        guard gezeichnet,
              let m = Titelmarkenmass.messen(rgba: puffer, breite: b, hoehe: h),
              let zu = roh.cropping(to: CGRect(x: m.x, y: m.y, width: m.breite, height: m.hoehe))
        else { return nil }
        return Titellogo(bild: zu, messung: m)
    }
}

/// Der Titel einer Detailseite: der Text — oder, wenn „Titel als Logo" an ist
/// (iPhone und iPad: Profil → Darstellung; Mac und Fernseher ebenso) und der
/// Server eins führt, das Logo.
///
/// Das Logo kommt auf die Textkante zugeschnitten und nach gleichem
/// optischen Gewicht bemessen (`Titelmarkenmass`); überwiegend dunkle Logos
/// stehen als helle Silhouette. Bis Zuschnitt und Messung fertig sind, steht
/// der Text an seinem Platz; scheitert der Abruf, bleibt er. Aus: reiner
/// Text, kein Abruf.
///
/// Der Maßstab ist die Titelzeile der Plattform (`zeile`: 28 auf Telefon,
/// Tablet und Mac, 56 auf dem Fernseher). Wo der Titel in einem Block mit
/// festen Stellen steht (Mac, Fernseher), bleibt das Logo in dessen Höhe —
/// nichts darunter wandert.
struct Titelmarke: View {
    /// Wie viel Platz der Titel hat.
    enum Platz {
        /// Freistehend auf der Seite: höchstens 70 % der Bildschirmbreite.
        case seite
        /// In einer Spalte (breiter Kopf): höchstens 70 % ihrer Breite,
        /// der Text bricht auf zwei Zeilen um.
        case spalte
        /// Ein Titelfach fester Höhe: eine Zeile Text, das Logo nie höher.
        case fach(hoehe: CGFloat)
    }

    let titel: String
    let logo: URL?
    let platz: Platz

    @AppStorage("titelAlsLogo") private var alsLogo = false
    @ScaledMetric private var zeile: CGFloat
    @State private var marke: Titellogo?
    @State private var breite: CGFloat = 0

    init(titel: String, logo: URL?, zeile: CGFloat = 28, platz: Platz = .seite) {
        self.titel = titel
        self.logo = logo
        self.platz = platz
        _zeile = ScaledMetric(wrappedValue: zeile, relativeTo: .title)
    }

    var body: some View {
        if !alsLogo || logo == nil {
            text
        } else {
            rahmen
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { breite = $0 }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(titel)
                .accessibilityAddTraits(.isHeader)
                .task(id: logo) {
                    guard let logo else { return }
                    if let da = Titellogospeicher.geteilt.vorhanden(logo) { marke = da; return }
                    marke = nil
                    let geladen = await Titellogospeicher.geteilt.laden(logo)
                    withAnimation(Stil.einblenden) { marke = geladen }
                }
        }
    }

    @ViewBuilder
    private var rahmen: some View {
        let inhalt = ZStack(alignment: .leading) {
            text.opacity(bereit == nil ? 1 : 0)
            if let bereit {
                zeichnung(bereit.0, bereit.1)
                    .transition(.opacity)
            }
        }
        switch platz {
        case .seite:
            inhalt
                .frame(minHeight: zeile * 2, alignment: .bottomLeading)
                .containerRelativeFrame(.horizontal, alignment: .leading) { breite, _ in breite * 0.7 }
        case .spalte:
            inhalt
                .frame(minHeight: zeile * 2, alignment: .bottomLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .fach(let hoehe):
            inhalt
                .frame(maxWidth: .infinity, minHeight: hoehe, maxHeight: hoehe, alignment: .leading)
        }
    }

    /// Erst wenn Messung und Breite da sind, steht die Größe fest.
    private var bereit: (Titellogo, CGSize)? {
        guard let marke, breite > 0 else { return nil }
        var hoechst: Double?
        var maxBreite = Double(breite)
        switch platz {
        case .seite: break
        case .spalte: maxBreite *= 0.7
        case .fach(let hoehe): hoechst = Double(hoehe)
        }
        let g = Titelmarkenmass.groesse(seitenverhaeltnis: marke.messung.seitenverhaeltnis,
                                        dichte: marke.messung.dichte,
                                        zeile: Double(zeile), maxBreite: maxBreite,
                                        maxHoehe: hoechst)
        return (marke, CGSize(width: g.breite, height: g.hoehe))
    }

    @ViewBuilder
    private func zeichnung(_ marke: Titellogo, _ groesse: CGSize) -> some View {
        let bild = Image(decorative: marke.bild, scale: 1).resizable()
        Group {
            if marke.dunkel {
                bild.renderingMode(.template).foregroundStyle(Stil.schrift)
            } else {
                bild
            }
        }
        .frame(width: groesse.width, height: groesse.height)
    }

    @ViewBuilder
    private var text: some View {
        let t = Text(titel)
            .font(Stil.titelGross)
            .tracking(Stil.sperrungTitel)
            .foregroundStyle(Stil.schrift)
        switch platz {
        case .seite: t
        case .spalte: t.lineLimit(2)
        case .fach(let hoehe):
            t.lineLimit(1)
                // Ein langer Titel schrumpft, statt die Seite zu verschieben.
                .minimumScaleFactor(0.62)
                .frame(height: hoehe, alignment: .leading)
        }
    }
}
