import CoreGraphics
import ImageIO
import SwiftUI

/// Ein Bild aus dem Netz — geholt, **abseits des Hauptlaufs entschlüsselt**,
/// gemerkt und eingeblendet.
///
/// **Liegt seit dem 05.09.2026 hier statt in `Sources/macOS`.** Vorher gab es
/// drei Bildlader: diesen, `Bild` in `Sources/Shared/Stil.swift` für iPhone
/// und iPad, und noch einmal dasselbe `Bild` in `Sources/tvOS/Stil.swift` —
/// eine Kopie mit demselben Kommentar. Die beiden anderen tragen einen
/// Anlaufzähler gegen `NSURLErrorCancelled`; das ist ein Verband um eine
/// Eigenschaft von `AsyncImage` und kein Bau, der das Problem nicht hat.
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

    /// **Zwei Zahlen, die die Plattform setzt, keine Festwerte.**
    ///
    /// Sie waren auf dem Mac eingetragen, und dort waren sie richtig. Auf dem
    /// Apple TV sind die Kacheln größer, der Arbeitsspeicher aber deutlich
    /// kleiner — wer die Mac-Zahlen dorthin mitnimmt, rät zweimal. Also
    /// stehen sie da, wo jemand sie beantworten kann.
    ///
    /// `hoechstzahl` ist die Zahl der Bilder im Speicher; auf dem Mac reicht
    /// sie für zwei volle Raster. `kantenlaenge` ist die längste Kante beim
    /// Entschlüsseln — größer heißt schärfer und teurer.
    static var hoechstzahl = 240
    static var kantenlaenge = 1600

    func bild(_ url: URL) -> Image? { bekannt[schluessel(url)] }

    /// **Der Zugang gehört nicht zum Bild.** Jede Bildadresse trägt
    /// `api_key` — nach einem Kontowechsel hiesse dasselbe Plakat plötzlich
    /// anders, und der ganze Speicher wäre auf einen Schlag kalt: jede Kachel
    /// neu geholt, und die alten Einträge bleiben liegen, bis sie hinten
    /// herausfallen. Bei 240 Plätzen für zwei Konten ist das die Hälfte.
    ///
    /// Ein Plakat ist aber für beide Konten dasselbe Bild — der Server gibt
    /// es unter derselben Kennung heraus, und `tag` (Jellyfins Fingerabdruck)
    /// bleibt im Schlüssel, eine geänderte Fassung fällt also weiterhin auf.
    /// Geholt wird mit dem vollen Weg, gemerkt ohne das Merkmal.
    ///
    /// Das ist G3 an einer Stelle, an der die Frage noch niemand gestellt
    /// hatte — mit dem Unterschied, dass hier nichts zu verwerfen ist: ein
    /// Bild trägt keinen Sehstand.
    private func schluessel(_ url: URL) -> URL {
        guard var teile = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let werte = teile.queryItems, werte.contains(where: { $0.name == "api_key" })
        else { return url }
        teile.queryItems = werte.filter { $0.name != "api_key" }
        return teile.url ?? url
    }

    func laden(_ url: URL) async -> Image? {
        let merkmal = schluessel(url)
        if let da = bekannt[merkmal] { return da }
        if let lauf = laufend[merkmal] { return await lauf.value }

        // **Vor dem Abzweig gelesen.** `kantenlaenge` gehört dem Hauptlauf;
        // von der abgetrennten Aufgabe aus wäre der Zugriff ein Sprung über
        // die Isolationsgrenze, den Swift 6 zu Recht nicht durchlässt.
        let kante = Self.kantenlaenge
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
                    kCGImageSourceThumbnailMaxPixelSize: kante
                ]
                guard let roh = CGImageSourceCreateThumbnailAtIndex(
                    quelle, 0, regeln as CFDictionary) else { return nil }
                return Bildkiste(bild: roh)
            }.value
            guard let kiste else { return nil }
            return Image(decorative: kiste.bild, scale: 1)
        }

        laufend[merkmal] = lauf
        let ergebnis = await lauf.value
        laufend[merkmal] = nil
        if let ergebnis { merken(ergebnis, fuer: merkmal) }
        return ergebnis
    }

    private func merken(_ bild: Image, fuer url: URL) {
        if bekannt[url] == nil { reihenfolge.append(url) }
        bekannt[url] = bild
        while reihenfolge.count > Self.hoechstzahl {
            bekannt[reihenfolge.removeFirst()] = nil
        }
    }
}

struct Netzbild: View {
    let url: URL?
    /// Wie das Bild seine Fläche füllt.
    var art: ContentMode = .fill
    /// Was stehen soll, wenn kein Bild kommt — als Systemzeichen.
    ///
    /// **Eine leere Fläche sieht aus wie ein Fehler in der App**, und genau so
    /// wurde sie gemeldet. Ein Zeichen sagt: hier gehört ein Bild hin, der
    /// Server hat keins. Steht seit je in der iPhone-Fassung; der Mac hatte
    /// es nie.
    var zeichen: String?

    @State private var bild: Image?
    @State private var sichtbar = false
    /// Kein Bild zu erwarten: keine Adresse, oder der Abruf kam ohne Bild
    /// zurück. Erst dann tritt das Zeichen ein — nicht schon währenddessen,
    /// sonst blitzte es vor jeder Kachel kurz auf.
    @State private var ohneBild = false

    /// **Was bekannt ist, steht sofort** — nicht erst im nächsten Durchgang.
    /// Ein nachgereichter Wert kommt zu spät, der leere Durchgang hat dann
    /// schon stattgefunden, und genau der ist das Aufblitzen.
    @MainActor init(url: URL?, art: ContentMode = .fill, zeichen: String? = nil) {
        self.url = url
        self.art = art
        self.zeichen = zeichen
        let sofort = url.flatMap { Bildspeicher.geteilt.bild($0) }
        _bild = State(initialValue: sofort)
        _sichtbar = State(initialValue: sofort != nil)
        _ohneBild = State(initialValue: url == nil)
    }

    var body: some View {
        ZStack {
            if let bild {
                bild.resizable().aspectRatio(contentMode: art)
                    .opacity(sichtbar ? 1 : 0)
            } else if ohneBild, let zeichen {
                Image(systemName: zeichen)
                    .font(.system(size: 22))
                    .foregroundStyle(Stil.schriftSehrLeise)
            }
        }
        .task(id: url) {
            guard let url else { ohneBild = true; return }
            guard bild == nil else { return }
            ohneBild = false
            guard let geladen = await Bildspeicher.geteilt.laden(url) else {
                ohneBild = true
                return
            }
            bild = geladen
            // 220 ms, dieselbe Zeit wie ein Sprung im Player — lang genug,
            // dass fünfzig Kacheln wie eine Bewegung wirken statt wie fünfzig.
            withAnimation(.easeOut(duration: 0.22)) { sichtbar = true }
        }
    }
}
