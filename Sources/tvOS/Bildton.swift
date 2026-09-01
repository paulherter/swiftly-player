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
    private var bekannt: [URL: Double?] = [:]
    private var laufend: [URL: Task<Double?, Never>] = [:]

    /// **Schon bekannt?** Ohne Warten, ohne `await`.
    ///
    /// Damit die Detailseite den Ton **sofort** setzen kann, statt ihn
    /// aufzublenden. Beim Wechsel von der Startseite ist er meist schon da:
    /// dort wird er beim Bildwechsel mitgerechnet, und beide Seiten holen
    /// dasselbe Bild (`breite: 1600`).
    ///
    /// Der aeussere Optional sagt „noch nie gerechnet", der innere „gerechnet
    /// und nichts gefunden". Das ist nicht dasselbe: bei einem Graustufenbild
    /// soll nicht bei jedem Oeffnen neu gesucht werden.
    func gemerkt(fuer url: URL) -> Double?? { bekannt[url] }

    /// Rechnet im Hintergrund vor, ohne dass jemand auf das Ergebnis wartet.
    func vorrechnen(_ url: URL) {
        guard bekannt[url] == nil, laufend[url] == nil else { return }
        Task { _ = await ton(fuer: url) }
    }

    /// Farbton in Grad, oder `nil` wenn sich keiner ableiten laesst —
    /// Graustufen, kein Bild, Serverfehler. `nil` ist kein Sonderfall,
    /// sondern der Normalzustand vor dem Laden: dann bleibt der Grund stehen.
    func ton(fuer url: URL) async -> Double? {
        if let fertig = bekannt[url] { return fertig }
        if let laeuft = laufend[url] { return await laeuft.value }

        let aufgabe = Task<Double?, Never> {
            guard let (daten, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return Self.tonAus(daten)
        }
        laufend[url] = aufgabe
        let ergebnis = await aufgabe.value
        bekannt[url] = ergebnis
        laufend[url] = nil
        return ergebnis
    }

    /// Auf 32 x 32 heruntergerechnet, dann Punkt fuer Punkt.
    ///
    /// So klein, weil es um den Gesamteindruck geht und nicht um Einzelheiten
    /// — und weil 1024 Punkte in Mikrosekunden durchlaufen sind, waehrend das
    /// volle Bild mehrere Megabyte waere.
    nonisolated static func tonAus(_ daten: Data) -> Double? {
        guard let quelle = CGImageSourceCreateWithData(daten as CFData, nil),
              let bild = CGImageSourceCreateThumbnailAtIndex(quelle, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 32,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return nil }

        let breite = bild.width, hoehe = bild.height
        guard breite > 0, hoehe > 0 else { return nil }

        var punkte = [UInt8](repeating: 0, count: breite * hoehe * 4)
        guard let raum = CGColorSpace(name: CGColorSpace.sRGB),
              let flaeche = CGContext(data: &punkte, width: breite, height: hoehe,
                                      bitsPerComponent: 8, bytesPerRow: breite * 4,
                                      space: raum,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        flaeche.draw(bild, in: CGRect(x: 0, y: 0, width: breite, height: hoehe))

        var x = 0.0, y = 0.0, gewichtSumme = 0.0
        for i in stride(from: 0, to: punkte.count, by: 4) {
            let r = Double(punkte[i]) / 255
            let g = Double(punkte[i + 1]) / 255
            let b = Double(punkte[i + 2]) / 255

            let hoch = max(r, g, b), tief = min(r, g, b)
            let spanne = hoch - tief
            guard spanne > 0.04, hoch > 0.08 else { continue }   // Grau und Schwarz zaehlen nicht mit

            let saettigung = spanne / hoch
            var ton: Double
            switch hoch {
            case r: ton = (g - b) / spanne
            case g: ton = 2 + (b - r) / spanne
            default: ton = 4 + (r - g) / spanne
            }
            ton *= 60
            if ton < 0 { ton += 360 }

            // Quadrat der Saettigung mal Helligkeit: der kraeftigste Fleck
            // fuehrt, ein fahler Hintergrund zieht ihn nicht weg.
            let gewicht = saettigung * saettigung * hoch
            let bogen = ton * .pi / 180
            x += cos(bogen) * gewicht
            y += sin(bogen) * gewicht
            gewichtSumme += gewicht
        }

        // Zu wenig Farbe im Bild — ein Graustufenplakat hat keinen Ton, und
        // einen zu erfinden waere schlimmer als keiner.
        guard gewichtSumme > 0.5, x * x + y * y > 0.0001 else { return nil }

        var grad = atan2(y, x) * 180 / .pi
        if grad < 0 { grad += 360 }
        return grad
    }
}

extension Bildton {
    /// Aus dem Ton die fertige Farbe — **hier stehen Saettigung und
    /// Helligkeit**, und nur hier.
    ///
    /// 0,45 und 0,42 sind so gewaehlt, dass die Farbe auf `#0B0B0D` bei 30
    /// Prozent Deckkraft sichtbar wird, ohne den Text zu bedraengen. Kraeftiger
    /// wird sie zur Flaeche, blasser sieht man sie am Fernseher nicht mehr.
    static func farbe(_ grad: Double) -> Color {
        Color(hue: grad / 360, saturation: 0.45, brightness: 0.42)
    }

    /// **Der Grund der ganzen Seite, leicht eingefaerbt.**
    ///
    /// Nicht Zierde, sondern gegen Streifenbildung. Lief der Verlauf auf
    /// reines `#0B0B0D` aus, ging er ueber tausend Punkte von getoent nach
    /// neutralschwarz — ein flacher Farbverlauf im dunkelsten Bereich, und
    /// genau dort zeigt ein Fernseher Ringe: acht Bit reichen nicht, um so
    /// wenig Unterschied auf so viel Flaeche zu verteilen.
    ///
    /// Nimmt der Grund den Ton schon mit an, ist die Strecke kurz: der
    /// Verlauf muss nur noch von etwas Farbe auf etwas weniger Farbe kommen,
    /// nicht auf gar keine.
    ///
    /// Dunkel bleibt es trotzdem — Helligkeit 0,085 liegt beim Grundton der
    /// App, die Saettigung traegt den Unterschied.
    static func grundfarbe(_ grad: Double) -> Color {
        Color(hue: grad / 360, saturation: 0.38, brightness: 0.085)
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
    @State private var ton: Double?

    func body(content: Content) -> some View {
        content
            .background(alignment: .top) {
                ZStack(alignment: .top) {
                    (ton.map(Bildton.grundfarbe) ?? Stil.grund)
                        .ignoresSafeArea()

                    // Darueber etwas mehr Farbe, dort wo das Bild sitzt.
                    // 1400 hoch, damit der Verlauf **innerhalb** seiner
                    // eigenen Flaeche auf null kommt — sonst steht am
                    // unteren Rand die naechste Kante.
                    if let ton {
                        RadialGradient(colors: [Bildton.farbe(ton).opacity(0.30),
                                                Bildton.farbe(ton).opacity(0)],
                                       center: UnitPoint(x: 0.72, y: 0.03),
                                       startRadius: 0, endRadius: 1180)
                            .frame(height: 1400)
                    }
                }
                .allowsHitTesting(false)
            }
            .animation(.easeInOut(duration: 0.4), value: ton)
            .task(id: url) {
                guard let url else { ton = nil; return }
                // Was schon bekannt ist, wird nicht eingeblendet.
                if let schonDa = Bildton.geteilt.gemerkt(fuer: url) {
                    var ohne = Transaction()
                    ohne.disablesAnimations = true
                    withTransaction(ohne) { ton = schonDa }
                    return
                }
                ton = nil
                ton = await Bildton.geteilt.ton(fuer: url)
            }
    }
}

extension View {
    func bildgrund(url: URL?) -> some View { modifier(Bildgrund(url: url)) }
}
