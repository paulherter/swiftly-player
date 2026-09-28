import Testing
@testable import JellyfinKit

@Suite struct SprungzielTests {
    @Test func keineZahlIstKeinZiel() {
        #expect(Sprungziel.sekunden(.nan) == nil)
        #expect(Sprungziel.sekunden(.infinity) == nil)
        #expect(Sprungziel.sekunden(-.infinity) == nil)
    }

    @Test func wirdBegrenzt() {
        #expect(Sprungziel.sekunden(-3) == 0)
        #expect(Sprungziel.sekunden(125.5) == 125.5)
        #expect(Sprungziel.sekunden(1e300) == Sprungziel.obergrenze)
    }

    @Test func millisekundenUeberlaufenNie() {
        // Genau die Umwandlung, die der Player danach macht.
        let ms = Int(Sprungziel.sekunden(.greatestFiniteMagnitude)! * 1000)
        #expect(Int32(clamping: ms) == 1_000_000_000)
    }
}
