import Testing
@testable import JellyfinKit

@Suite struct KerbenfangTests {
    // 2700 s auf 270 Punkt: ein Punkt sind zehn Sekunden, die Fangweite 80 s.
    @Test func nahDranRastetEin() {
        #expect(Kerbenfang.kerbe(wert: 150, bis: 2700, marken: [90, 2500], breite: 270) == 90)
    }

    @Test func weitWegBleibtFrei() {
        #expect(Kerbenfang.kerbe(wert: 400, bis: 2700, marken: [90, 2500], breite: 270) == nil)
    }

    @Test func dieNaehereGewinnt() {
        #expect(Kerbenfang.kerbe(wert: 100, bis: 2700, marken: [60, 110], breite: 270) == 110)
    }

    @Test func kantenZaehlenNicht() {
        #expect(Kerbenfang.kerbe(wert: 5, bis: 2700, marken: [0, 2700], breite: 270) == nil)
    }

    @Test func ohneBreiteKeinFang() {
        #expect(Kerbenfang.kerbe(wert: 90, bis: 2700, marken: [90], breite: 0) == nil)
    }
}
