import Foundation
import Testing
@testable import JellyfinKit

/// Die Farbrechnung in OKLab, auf der der Auslauf der Bildfarbe steht.
@Suite struct FarbwahlTests {
    /// **Hin und zurück** ergibt dieselbe Farbe.
    @Test func hinUndZurueck() throws {
        let lab = Farbwahl.oklab(0.6, 0.13, 0.11)
        let rgb = try #require(Farbwahl.srgb(L: lab.L, a: lab.a, b: lab.b))
        #expect(abs(rgb.r - 0.6) < 0.002 && abs(rgb.g - 0.13) < 0.002 && abs(rgb.b - 0.11) < 0.002)
    }

    /// **Grau hat keine Buntheit** — das Ziel jedes Auslaufs.
    @Test func grauIstUnbunt() {
        let lab = Farbwahl.oklab(16.0 / 255, 16.0 / 255, 16.0 / 255)
        #expect(abs(lab.a) < 0.0005 && abs(lab.b) < 0.0005)
    }

    /// **Der Ton bleibt, wenn die Farbe nicht in sRGB passt** — die Buntheit
    /// weicht, nicht der Ton.
    @Test func tonBleibtBeimEinpassen() {
        let f = Farbwahl.srgb(L: 0.25, C: 0.4, h: 29)
        let lab = Farbwahl.oklab(f.r, f.g, f.b)
        var h = atan2(lab.b, lab.a) * 180 / .pi
        if h < 0 { h += 360 }
        #expect(Farbwahl.abstand(h, 29) < 3)
    }
}
