import Foundation
import Testing
@testable import JellyfinKit

/// Die Bildfarbe, wie Apple und Android sie rechnen.
@Suite struct BildtonrechnungTests {
    private func flaeche(_ r: UInt8, _ g: UInt8, _ b: UInt8, punkte: Int = 256) -> [UInt8] {
        (0 ..< punkte).flatMap { _ in [r, g, b, 255] }
    }

    /// **Ein rotes Bild hat den Ton Rot**, ein graues keinen.
    @Test func toeneAusDemBild() throws {
        let rot = Bildtonrechnung.toene(rgba: flaeche(200, 30, 30))
        let ton = try #require(rot.first)
        #expect(Farbwahl.abstand(ton, 0) < 6)
        #expect(Bildtonrechnung.toene(rgba: flaeche(120, 120, 120)).isEmpty)
    }

    /// **Zwei Farben, zwei Töne** — mit Mindestabstand, nach Gewicht.
    @Test func zweiGipfel() {
        let bild = flaeche(20, 60, 200, punkte: 300) + flaeche(220, 140, 20, punkte: 100)
        let toene = Bildtonrechnung.toene(rgba: bild)
        #expect(toene.count == 2)
        #expect(Farbwahl.abstand(toene[0], 225) < 12)
        #expect(Farbwahl.abstand(toene[1], 38) < 12)
    }

    /// **Der Auslauf endet genau auf `grund`** und beginnt ohne Sprung.
    @Test func auslaufEndetImGrund() {
        #expect(Bildtonrechnung.abklingen(y: 100, ab: 300, auslauf: 1300) == 1)
        #expect(Bildtonrechnung.abklingen(y: 1600, ab: 300, auslauf: 1300) == 0)
        #expect(abs(Bildtonrechnung.abklingen(y: 301, ab: 300, auslauf: 1300) - 1) < 0.0001)
        let c = Bildtonrechnung.farbe([200], x: 0.9, y: 0.1, abklingen: 0)
        #expect(abs(c.r - 16.0 / 255) < 0.003 && abs(c.g - 16.0 / 255) < 0.003 && abs(c.b - 16.0 / 255) < 0.003)
    }

    /// **Oben rechts am hellsten** — dort sitzt die Kulisse.
    @Test func kulisseObenRechts() {
        let nah = Bildtonrechnung.hsb([200], x: 1, y: 0)
        let fern = Bildtonrechnung.hsb([200], x: 0, y: 1)
        #expect(nah.helligkeit > fern.helligkeit)
        #expect(abs(nah.helligkeit - (Bildtonrechnung.helligkeit + Bildtonrechnung.helligkeitNah)) < 0.0001)
    }

    /// **Punkte für die Fläche**: Anzahl, volle Deckung, ohne Töne Grund.
    @Test func punkte() {
        let p = Bildtonrechnung.punkte([30, 200], spalten: 5, zeilen: 8, hoehe: 1000, farbhoehe: 900,
                                       ab: 300, auslauf: 600)
        #expect(p.count == 40)
        #expect(p.allSatisfy { UInt32(bitPattern: $0) >> 24 == 0xFF })
        let grau = Bildtonrechnung.punkte([], spalten: 2, zeilen: 2, hoehe: 10, farbhoehe: 10, ab: 10, auslauf: 0)
        #expect(grau.allSatisfy { UInt32(bitPattern: $0) == 0xFF10_1010 })
    }
}
