import SwiftUI

/// Ein Bild aus dem Netz — **gemerkt und eingeblendet.**
///
/// `AsyncImage` allein hat zwei Eigenschaften, die auf dem Mac zusammen
/// unruhig wirken:
///
/// 1. **Es merkt sich nichts.** Jedes Erscheinen lädt neu. Auf einer Kachel
///    fällt das kaum auf, aber ein Raster zeigt fünfzig auf einmal, und beim
///    Zurückscrollen fängt alles von vorn an.
/// 2. **Es springt ins Bild.** Fertig geladene Bilder erscheinen hart, eines
///    nach dem anderen — das ist das „Stück für Stück", das man sieht.
///
/// Der Speicher ist von tvOS übernommen (`Kulissenbilder`), nur größer: dort
/// liegen acht Kulissen, hier braucht ein Raster ein Vielfaches davon.
@MainActor
final class Bildspeicher {
    static let geteilt = Bildspeicher()

    private var bekannt: [URL: Image] = [:]
    private var reihenfolge: [URL] = []
    /// Genug für zwei volle Raster; darüber fliegt das Älteste raus.
    private let hoechstzahl = 240

    func bild(_ url: URL) -> Image? { bekannt[url] }

    func merken(_ bild: Image, fuer url: URL) {
        if bekannt[url] == nil { reihenfolge.append(url) }
        bekannt[url] = bild
        while reihenfolge.count > hoechstzahl {
            bekannt[reihenfolge.removeFirst()] = nil
        }
    }
}

struct Netzbild: View {
    let url: URL?
    /// Wie das Bild seine Fläche füllt. Kacheln und Kulissen füllen, ein
    /// Kopfbild in der Besetzung ebenso.
    var art: ContentMode = .fill

    @State private var bild: Image?

    /// **Was bekannt ist, steht sofort** — nicht erst im nächsten Durchgang.
    /// Ein nachgereichter Wert kommt zu spät, der leere Durchgang hat dann
    /// schon stattgefunden, und genau der ist das Aufblitzen.
    @MainActor init(url: URL?, art: ContentMode = .fill) {
        self.url = url
        self.art = art
        _bild = State(initialValue: url.flatMap { Bildspeicher.geteilt.bild($0) })
    }

    var body: some View {
        ZStack {
            if let bild {
                bild.resizable().aspectRatio(contentMode: art)
            } else if let url {
                AsyncImage(url: url) { stufe in
                    if case let .success(geladen) = stufe {
                        geladen.resizable().aspectRatio(contentMode: art)
                            .task { Bildspeicher.geteilt.merken(geladen, fuer: url) }
                    }
                }
                // Eingeblendet statt hineingesprungen. 220 ms, dieselbe Zeit
                // wie ein Sprung im Player — lang genug, dass fünfzig Kacheln
                // wie eine Bewegung wirken statt wie fünfzig.
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.22), value: bild == nil)
    }
}
