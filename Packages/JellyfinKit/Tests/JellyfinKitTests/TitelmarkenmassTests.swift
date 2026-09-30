import Testing
@testable import JellyfinKit

@Suite struct TitelmarkenmassTests {
    /// 6×4 Bild, ein deckendes Rechteck (Spalten 2–3, Zeilen 1–2).
    private func bild(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: 6 * 4 * 4)
        for y in 1...2 { for x in 2...3 {
            let i = (y * 6 + x) * 4
            px[i] = r; px[i + 1] = g; px[i + 2] = b; px[i + 3] = 255
        } }
        return px
    }

    @Test func alphaBoxSchneidetRandAb() throws {
        let m = try #require(Titelmarkenmass.messen(rgba: bild(255, 255, 255), breite: 6, hoehe: 4))
        #expect(m.x == 2 && m.y == 1 && m.breite == 2 && m.hoehe == 2)
        #expect(m.dichte == 1)
    }

    @Test func leeresBildGibtNil() {
        #expect(Titelmarkenmass.messen(rgba: [UInt8](repeating: 0, count: 6 * 4 * 4), breite: 6, hoehe: 4) == nil)
    }

    @Test func schwacheKantePixelZaehlenNicht() throws {
        var px = bild(255, 255, 255)
        px[3] = 8   // Ecke oben links, gerade unter der Schwelle
        px[(3 * 6 + 5) * 4 + 3] = 9 // knapp drüber
        let m = try #require(Titelmarkenmass.messen(rgba: px, breite: 6, hoehe: 4))
        #expect(m.x == 2 && m.y == 1 && m.breite == 4 && m.hoehe == 3)
    }

    @Test func dunkelErkennung() throws {
        let schwarz = try #require(Titelmarkenmass.messen(rgba: bild(0, 0, 0), breite: 6, hoehe: 4))
        let weiss = try #require(Titelmarkenmass.messen(rgba: bild(255, 255, 255), breite: 6, hoehe: 4))
        let rot = try #require(Titelmarkenmass.messen(rgba: bild(230, 30, 30), breite: 6, hoehe: 4))
        #expect(Titelmarkenmass.istDunkel(luminanz: schwarz.luminanz))
        #expect(!Titelmarkenmass.istDunkel(luminanz: weiss.luminanz))
        #expect(!Titelmarkenmass.istDunkel(luminanz: rot.luminanz + 0.2))
    }

    @Test func dichtefaktorBegrenzt() {
        #expect(Titelmarkenmass.dichtefaktor(1) == 0.85)
        #expect(Titelmarkenmass.dichtefaktor(0.01) == 1.15)
        #expect(Titelmarkenmass.dichtefaktor(0.5) == 1)
    }

    @Test func gleichesGewichtStattGleicherHoehe() {
        let z = 28.0, maxB = 250.0
        let from = Titelmarkenmass.groesse(seitenverhaeltnis: 3, dichte: 0.5, zeile: z, maxBreite: maxB)
        let breitFlach = Titelmarkenmass.groesse(seitenverhaeltnis: 8, dichte: 0.5, zeile: z, maxBreite: maxB)
        let quadrat = Titelmarkenmass.groesse(seitenverhaeltnis: 1.2, dichte: 0.5, zeile: z, maxBreite: maxB)
        #expect(breitFlach.hoehe > z && breitFlach.breite <= maxB + 0.001)
        #expect(breitFlach.breite > from.breite)
        #expect(quadrat.hoehe > from.hoehe)
        // Nie über 2,2 Zeilen, nie unter einer.
        #expect(quadrat.hoehe <= 2.2 * z + 0.001)
        let winzig = Titelmarkenmass.groesse(seitenverhaeltnis: 20, dichte: 0.5, zeile: z, maxBreite: 1000)
        #expect(winzig.hoehe >= z - 0.001)
    }

    @Test func dichteLogosSindKleiner() {
        let dicht = Titelmarkenmass.groesse(seitenverhaeltnis: 3, dichte: 0.9, zeile: 28, maxBreite: 250)
        let duenn = Titelmarkenmass.groesse(seitenverhaeltnis: 3, dichte: 0.25, zeile: 28, maxBreite: 250)
        #expect(dicht.hoehe < duenn.hoehe)
    }

    @Test func titelfachDeckeltDieHoehe() {
        let g = Titelmarkenmass.groesse(seitenverhaeltnis: 1.2, dichte: 0.5, zeile: 28,
                                        maxBreite: 500, maxHoehe: 42)
        #expect(g.hoehe <= 42.001)
        #expect(abs(g.breite - g.hoehe * 1.2) < 0.001)
    }
}
