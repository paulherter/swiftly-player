import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

/// **Der Farbton eines Bildes — nur der Ton, nicht die Farbe.**
///
/// Die Detailseite faerbt ihren Grund nach der Kulisse, wie Plex das macht.
/// Der Kniff steckt darin, was *nicht* uebernommen wird: Saettigung und
/// Helligkeit setzt die App selbst, aus dem Bild kommt allein der Farbton.
///
/// Der Grund dafuer ist nachrechenbar. Ein Durchschnitt ueber ein dunkles
/// Filmplakat ergibt Braungrau, und zwar fast immer — dunkle Bilder mitteln
/// sich zu Matsch, weil sich Gegenfarben aufheben. Nimmt man dagegen nur den
/// Ton und setzt den Rest fest, sieht das Ergebnis **immer** nach Swiftly
/// aus: ein kuehler Film wird blaugruen, ein warmer bernstein, und beide
/// bleiben gleich dunkel und gleich zurueckhaltend.
///
/// **Gemittelt wird auf dem Kreis, nicht auf der Zahl.** Farbtoene sind
/// Winkel: 350 Grad und 10 Grad liegen nebeneinander, ihr Zahlenmittel waere
/// 180 — also genau die Gegenfarbe. Deshalb werden sie als Einheitsvektoren
/// addiert und am Ende zurueckgerechnet.
///
/// Gewichtet wird mit dem Quadrat der Saettigung: der farbigste Fleck traegt
/// den Eindruck, den man vom Bild hat, nicht die graue Flaeche ringsum.
///
/// **Versuchsweise hier und nicht in `Sources/Shared`.** Mac und iPad haetten
/// dieselbe Verwendung; sobald es bleibt, gehoert die Rechnung nach der Regel
/// zuerst nach iOS und dann in den geteilten Code. Gemeldet.
@MainActor
final class Bildton {
    static let geteilt = Bildton()

    /// Einmal gerechnet, dann gemerkt. Ohne das rechnet jede Rueckkehr auf
    /// dieselbe Seite neu, und der Hintergrund blendet jedes Mal auf.
    private var bekannt: [URL: [Double]] = [:]
    private var laufend: [URL: Task<[Double], Never>] = [:]

    /// **Schon bekannt?** Ohne Warten, ohne `await`.
    ///
    /// Damit die Detailseite die Toene **sofort** setzen kann, statt sie
    /// aufzublenden. Beim Wechsel von der Startseite sind sie meist schon da:
    /// dort werden sie beim Bildwechsel mitgerechnet, und beide Seiten holen
    /// dasselbe Bild (`breite: 1600`).
    ///
    /// `nil` heisst "noch nie gerechnet", ein leeres Feld "gerechnet und
    /// nichts gefunden". Das ist nicht dasselbe: bei einem Graustufenbild
    /// soll nicht bei jedem Oeffnen neu gesucht werden.
    func gemerkt(fuer url: URL) -> [Double]? { bekannt[url] }

    /// Rechnet im Hintergrund vor, ohne dass jemand auf das Ergebnis wartet.
    func vorrechnen(_ url: URL) {
        guard bekannt[url] == nil, laufend[url] == nil else { return }
        Task { _ = await toene(fuer: url) }
    }

    /// Bis zu drei Farbtoene in Grad, nach Gewicht — leer, wenn sich keiner
    /// ableiten laesst.
    func toene(fuer url: URL) async -> [Double] {
        if let fertig = bekannt[url] { return fertig }
        if let laeuft = laufend[url] { return await laeuft.value }

        let aufgabe = Task<[Double], Never> {
            guard let (daten, _) = try? await URLSession.shared.data(from: url) else { return [] }
            return Self.toeneAus(daten)
        }
        laufend[url] = aufgabe
        let ergebnis = await aufgabe.value
        bekannt[url] = ergebnis
        laufend[url] = nil
        return ergebnis
    }

    /// Auf 32 x 32 heruntergerechnet, dann Punkt fuer Punkt in ein Histogramm
    /// der Farbtoene.
    ///
    /// **Ein Mittelwert reicht nicht.** Die erste Fassung mittelte alle Toene
    /// zu einem einzigen — und ein Bild hat selten nur einen. Stimmt: ein
    /// Sonnenuntergang ist orange **und** blau, und der Mittelwert davon ist
    /// keins von beidem.
    ///
    /// Deshalb 36 Faecher zu je zehn Grad, gewichtet mit dem Quadrat der
    /// Saettigung mal der Helligkeit. Danach werden die staerksten Gipfel
    /// gezogen, und zwar mit Mindestabstand: zwei Faecher nebeneinander sind
    /// derselbe Ton, kein zweiter.
    ///
    /// **Fuenf, nicht drei.** Stimmt — drei war meine Sparsamkeit, nicht die
    /// des Bildes. Mehr Toene heissen mehr Bewegung ueber die Flaeche, und das
    /// ist zugleich das Beste gegen Streifen: je mehr die drei Kanaele
    /// unterschiedlich schnell laufen, desto weniger fallen ihre
    /// Quantisierungsgrenzen zusammen.
    nonisolated static func toeneAus(_ daten: Data) -> [Double] {
        guard let quelle = CGImageSourceCreateWithData(daten as CFData, nil),
              let bild = CGImageSourceCreateThumbnailAtIndex(quelle, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 48,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return [] }

        let breite = bild.width, hoehe = bild.height
        guard breite > 0, hoehe > 0 else { return [] }

        var punkte = [UInt8](repeating: 0, count: breite * hoehe * 4)
        guard let raum = CGColorSpace(name: CGColorSpace.sRGB),
              let flaeche = CGContext(data: &punkte, width: breite, height: hoehe,
                                      bitsPerComponent: 8, bytesPerRow: breite * 4,
                                      space: raum,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        flaeche.draw(bild, in: CGRect(x: 0, y: 0, width: breite, height: hoehe))

        let faecher = 36
        var korb = [Double](repeating: 0, count: faecher)
        var gesamt = 0.0

        for i in stride(from: 0, to: punkte.count, by: 4) {
            let r = Double(punkte[i]) / 255
            let g = Double(punkte[i + 1]) / 255
            let b = Double(punkte[i + 2]) / 255

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

        // Gipfel ziehen: staerkstes Fach, dann das staerkste mit mindestens
        // drei Faechern (30 Grad) Abstand, und so weiter.
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

}

extension Bildton {
    /// Aus dem Ton die fertige Farbe — **hier stehen Saettigung und
    /// Helligkeit**, und nur hier.
    static func farbe(_ grad: Double) -> Color {
        Color(hue: grad / 360, saturation: 0.45, brightness: 0.42)
    }

    /// **Der Grund der ganzen Seite, leicht eingefaerbt.**
    ///
    /// Nicht Zierde, sondern gegen Streifenbildung. Lief der Verlauf auf
    /// reines `#0B0B0D` aus, ging er ueber tausend Punkte von getoent nach
    /// neutralschwarz — ein flacher Farbverlauf im dunkelsten Bereich, und
    /// genau dort zeigt ein Fernseher Ringe.
    static func grundfarbe(_ grad: Double) -> Color {
        Color(hue: grad / 360, saturation: 0.38, brightness: 0.085)
    }

    /// **Weiche Blendstufen statt weniger Stuetzstellen.**
    ///
    /// Ein Verlauf aus drei, vier Stopps hat an jedem davon einen Knick: die
    /// Steigung springt, und das Auge liest den Sprung als Kante. Genau das
    /// waren die "harten Kanten unten und links vom Bild" — sie standen dort,
    /// wo die Blende aufhoerte und die Flaeche deckend wurde.
    ///
    /// `t * t * (3 - 2t)` laeuft an beiden Enden waagerecht aus, hat also
    /// nirgends einen Knick. Mit zwoelf Stufen abgetastet ist davon nichts
    /// mehr zu sehen.
    /// **Feines Rauschen gegen Streifenbildung.**
    ///
    /// Der eigentliche Grund fuer Streifen ist nicht der Verlauf, sondern die
    /// Zahlendarstellung: acht Bit je Kanal geben 256 Stufen, und ein
    /// Farbverlauf, der ueber tausend Punkte nur ein paar Stufen durchlaeuft,
    /// hat zwangslaeufig breite Baender gleicher Farbe. Auf einem grossen
    /// dunklen Schirm sieht man jede Grenze.
    ///
    /// Dagegen hilft kein weicherer Verlauf — die Stufen liegen dann nur
    /// woanders. Es hilft nur, die Grenze **aufzubrechen**: ein Hauch
    /// Zufallsrauschen laesst benachbarte Punkte mal auf die eine, mal auf
    /// die andere Stufe fallen. Das Auge mittelt darueber und sieht den
    /// Uebergang, den die Zahlen nicht hergeben. Genau dafuer gibt es
    /// Dithering, seit es Bildschirme gibt.
    ///
    /// **Die Staerke ist der ganze Trick, und sie ist winzig.** Gebraucht
    /// wird eine Amplitude von etwa **einer** Helligkeitsstufe: gerade genug,
    /// damit ein Punkt mal auf die eine, mal auf die andere Stufe faellt.
    ///
    /// Ein Zwischenstand stand auf 3,5 Prozent — bei Schwarz/Weiss mit voller
    /// Zufallsdeckkraft sind das rund neun Stufen Ausschlag. Das ist kein
    /// Dither mehr, sondern sichtbares Korn, und genau so sah es aus.
    ///
    ///     255 × 0,008 × 0,5 (mittlere Deckkraft) ≈ 1 Stufe
    ///
    /// 96 x 96 gekachelt. Sichtbar ist davon nichts, ausser dass die Baender
    /// weg sind.
    static let rauschen: Image = {
        let kante = 96
        var punkte = [UInt8](repeating: 0, count: kante * kante * 4)
        var zustand: UInt64 = 0x2545F4914F6CDD1D
        for i in stride(from: 0, to: punkte.count, by: 4) {
            // Xorshift: schnell, gleichverteilt genug, und ohne Abhaengigkeit
            // von einer Zufallsquelle, die je Lauf anders aussieht.
            zustand ^= zustand << 13
            zustand ^= zustand >> 7
            zustand ^= zustand << 17
            // **In beide Richtungen.** Die erste Fassung war weiss mit
            // zufaelliger Deckkraft — die konnte nur aufhellen, nie
            // abdunkeln. Ein einseitiger Stoss verschiebt den Verlauf, statt
            // die Stufengrenze aufzubrechen. Hier ist jeder Punkt zufaellig
            // schwarz oder weiss, das Mittel bleibt neutral.
            let hell = (zustand & 1) == 1
            let deckung = UInt8(truncatingIfNeeded: zustand >> 8)
            // Vormultipliziert: bei Schwarz sind die Farbkanaele null, bei
            // Weiss gleich der Deckkraft.
            let kanal: UInt8 = hell ? deckung : 0
            punkte[i] = kanal; punkte[i + 1] = kanal; punkte[i + 2] = kanal
            punkte[i + 3] = deckung
        }
        let raum = CGColorSpace(name: CGColorSpace.sRGB)!
        let flaeche = CGContext(data: &punkte, width: kante, height: kante,
                                bitsPerComponent: 8, bytesPerRow: kante * 4,
                                space: raum,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return Image(decorative: flaeche.makeImage()!, scale: 1)
    }()

    static func blende(bis kante: Double, umgekehrt: Bool = false) -> Gradient {
        let stufen = 12
        var stops: [Gradient.Stop] = []
        for i in 0 ... stufen {
            let t = Double(i) / Double(stufen)
            let weich = t * t * (3 - 2 * t)
            let ort = umgekehrt ? 1 - kante + t * kante : t * kante
            let deckung = umgekehrt ? 1 - weich : weich
            stops.append(.init(color: .white.opacity(deckung), location: ort))
        }
        if !umgekehrt { stops.append(.init(color: .white, location: 1)) }
        else { stops.insert(.init(color: .white, location: 0), at: 0) }
        return Gradient(stops: stops)
    }
}

/// Faerbt den Grund einer ganzen Seite nach ihrem Kulissenbild.
///
/// **An der Seite, nicht am Kopf.** Erst sass das im `Detailkopf`, und damit
/// endete die Faerbung an dessen Unterkante — darunter stand wieder reines
/// `#0B0B0D` und quer ueber dem Schirm eine Naht. Der Grund gehoert unter
/// alles, was die Seite zeigt, die Reihen eingeschlossen.
struct Bildgrund: ViewModifier {
    let url: URL?
    @State private var toene: [Double] = []

    func body(content: Content) -> some View {
        content
            .background(alignment: .top) {
                ZStack(alignment: .top) {
                    // **Der Grund ist ein Verlauf zwischen den Toenen, keine
                    // Flaeche.**
                    //
                    // Und das ist der zweite Teil gegen die Baender. Ein
                    // Verlauf von einer Farbe nach durchsichtig bewegt sich in
                    // RGB fast nur auf einer Geraden — die
                    // Quantisierungsstufen liegen dann alle quer dazu und
                    // bilden saubere, gut sichtbare Baender. Laeuft er von
                    // einer Farbe in eine **andere**, wandern die drei Kanaele
                    // unterschiedlich schnell, ihre Stufengrenzen fallen
                    // auseinander, und es bleibt kein durchgehender Rand mehr
                    // uebrig.
                    grundverlauf.ignoresSafeArea()

                    // **Ein Ton je Gipfel, an verschiedenen Stellen.**
                    //
                    // Der staerkste sitzt oben rechts, wo das Bild steht; die
                    // schwaecheren links darunter. So entsteht der Wechsel
                    // zwischen zwei Farben ueber die Flaeche, statt einer
                    // einzigen Wolke — das ist der Unterschied, den
                    //
                    // 1400 hoch, damit jeder Verlauf **innerhalb** seiner
                    // eigenen Flaeche auf null kommt.
                    ForEach(Array(toene.enumerated()), id: \.offset) { i, ton in
                        RadialGradient(colors: [Bildton.farbe(ton).opacity(staerke(i)),
                                                Bildton.farbe(ton).opacity(0)],
                                       center: mitte(i),
                                       startRadius: 0, endRadius: 1100)
                            .frame(height: 1400)
                    }

                    // Gegen die Baender, die acht Bit auf so viel Flaeche
                    // nicht vermeiden koennen — siehe `Bildton.rauschen`.
                    if !toene.isEmpty {
                        Bildton.rauschen
                            .resizable(resizingMode: .tile)
                            .opacity(0.008)
                            .ignoresSafeArea()
                    }
                }
                .allowsHitTesting(false)
            }
            .animation(.easeInOut(duration: 0.4), value: toene)
            .task(id: url) {
                guard let url else { toene = []; return }
                if let schonDa = Bildton.geteilt.gemerkt(fuer: url) {
                    var ohne = Transaction()
                    ohne.disablesAnimations = true
                    withTransaction(ohne) { toene = schonDa }
                    return
                }
                toene = []
                toene = await Bildton.geteilt.toene(fuer: url)
            }
    }

    /// Ueber die Flaeche von Ton zu Ton, schraeg. Bei nur einem Ton bleibt
    /// die Bewegung erhalten, indem Saettigung und Helligkeit leicht wandern
    /// — auch das laesst die Kanaele verschieden schnell laufen.
    private var grundverlauf: LinearGradient {
        let toenung: [Double]
        switch toene.count {
        case 0:  return LinearGradient(colors: [Stil.grund, Stil.grund],
                                       startPoint: .topTrailing, endPoint: .bottomLeading)
        case 1:  toenung = [toene[0], toene[0]]
        default: toenung = toene
        }

        // **Ohne Knick von Farbe zu Farbe.**
        //
        // Ein `LinearGradient(colors:)` verbindet seine Farben geradlinig und
        // hat an jeder einen Knick — die Steigung springt, und das Auge liest
        // den Sprung als Band. Genau derselbe Fehler wie vorher bei der
        // Blende, nur an der naechsten Stelle.
        //
        // Deshalb wird jeder Abschnitt mit `t² (3 − 2t)` abgetastet: die
        // Kurve laeuft an beiden Enden waagerecht aus, also stossen zwei
        // Abschnitte mit gleicher Steigung null aneinander. Bei einem
        // einzigen Ton wandern stattdessen Saettigung und Helligkeit, damit
        // die drei Kanaele auch dann verschieden schnell laufen.
        var stops: [Gradient.Stop] = []
        let abschnitte = toenung.count - 1
        for a in 0 ..< max(abschnitte, 1) {
            let vonTon = toenung[a], bisTon = toenung[min(a + 1, toenung.count - 1)]
            // Kuerzester Weg ueber den Farbkreis — sonst laeuft ein Uebergang
            // von 350 auf 10 Grad einmal quer durch alle Farben.
            var weg = bisTon - vonTon
            if weg > 180 { weg -= 360 }
            if weg < -180 { weg += 360 }

            for i in 0 ... 8 {
                let t = Double(i) / 8
                let weich = t * t * (3 - 2 * t)
                let ort = (Double(a) + t) / Double(max(abschnitte, 1))
                let ton = vonTon + weg * weich
                let farbe = toene.count == 1
                    ? Color(hue: ton / 360,
                            saturation: 0.38 - 0.14 * weich,
                            brightness: 0.085 - 0.030 * weich)
                    : Bildton.grundfarbe(ton)
                stops.append(.init(color: farbe, location: min(ort, 1)))
            }
        }
        return LinearGradient(gradient: Gradient(stops: stops),
                              startPoint: .topTrailing, endPoint: .bottomLeading)
    }

    private func staerke(_ i: Int) -> Double {
        [0.28, 0.20, 0.15, 0.11, 0.08][min(i, 4)]
    }

    /// Ueber die Flaeche verteilt, nicht uebereinander. Der staerkste sitzt
    /// oben rechts beim Bild, die uebrigen wandern nach links und unten —
    /// so entsteht der Wechsel, statt dass sich alles an einer Stelle
    /// addiert.
    private func mitte(_ i: Int) -> UnitPoint {
        [UnitPoint(x: 0.74, y: 0.02),
         UnitPoint(x: 0.16, y: 0.38),
         UnitPoint(x: 0.94, y: 0.52),
         UnitPoint(x: 0.42, y: 0.72),
         UnitPoint(x: 0.06, y: 0.06)][min(i, 4)]
    }
}

extension View {
    func bildgrund(url: URL?) -> some View { modifier(Bildgrund(url: url)) }
}
