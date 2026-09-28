import Foundation
import Testing
@testable import JellyfinKit

/// Seitenwechsel ohne Überblendung, und die Kurven dazu.
@Suite struct BlendzeitenTests {
    /// **Nie beide gleichzeitig:** solange die alte Seite Deckung hat, hat
    /// die neue keine.
    @Test func nieUeberblenden() {
        var t = 0.0
        while t <= Blendzeiten.seiteGesamt + 0.05 {
            let d = Blendzeiten.seitenwechsel(t)
            #expect(d.alt == 0 || d.neu == 0, "bei \(t): \(d)")
            t += 0.005
        }
    }

    @Test func anfangUndEnde() {
        let a = Blendzeiten.seitenwechsel(0)
        #expect(a.alt == 1 && a.neu == 0)
        let mitte = Blendzeiten.seitenwechsel(Blendzeiten.seiteHinaus)
        #expect(mitte.alt == 0 && mitte.neu == 0)
        let e = Blendzeiten.seitenwechsel(Blendzeiten.seiteGesamt)
        #expect(e.alt == 0 && e.neu == 1)
    }

    /// Hinaus kürzer als herein; die Pfeile im Bereich 150–200 ms.
    @Test func dauern() {
        #expect(Blendzeiten.seiteHinaus < Blendzeiten.seiteHerein)
        #expect(Blendzeiten.pfeile >= 0.15 && Blendzeiten.pfeile <= 0.2)
    }

    /// `easeIn` fängt langsam an, `easeOut` hört langsam auf, beide treffen
    /// 0 und 1.
    @Test func kurven() {
        for k in [Blendzeiten.easeIn, Blendzeiten.easeOut, Blendzeiten.easeInOut] {
            #expect(abs(k(0)) < 1e-9 && abs(k(1) - 1) < 1e-9)
        }
        #expect(Blendzeiten.easeIn(0.5) < 0.5)
        #expect(Blendzeiten.easeOut(0.5) > 0.5)
        #expect(abs(Blendzeiten.easeInOut(0.5) - 0.5) < 0.01)
    }
}
