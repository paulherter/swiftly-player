import Testing
@testable import JellyfinKit

@Suite("Suchverlauf")
struct SuchverlaufTests {

    @Test("Der juengste Begriff steht vorn")
    func juengsterVorn() {
        var roh = ""
        roh = Suchverlauf.merken("Dune", in: roh)
        roh = Suchverlauf.merken("Severance", in: roh)
        #expect(Suchverlauf.liste(roh) == ["Severance", "Dune"])
    }

    @Test("Derselbe Begriff in anderer Schreibung steht nur einmal da")
    func keineDoppelten() {
        var roh = Suchverlauf.merken("dune", in: "")
        roh = Suchverlauf.merken("Severance", in: roh)
        roh = Suchverlauf.merken("Dune", in: roh)
        #expect(Suchverlauf.liste(roh) == ["Dune", "Severance"])
    }

    @Test("Unter zwei Zeichen wird nichts gemerkt")
    func zuKurz() {
        #expect(Suchverlauf.merken(" a ", in: "Dune") == "Dune")
    }

    @Test("Leerraum am Rand wird abgeschnitten")
    func sauber() {
        #expect(Suchverlauf.liste(Suchverlauf.merken("  Dune \n", in: "")) == ["Dune"])
    }

    @Test("Es bleiben hoechstens acht, die aeltesten fallen heraus")
    func hoechstensAcht() {
        var roh = ""
        for i in 1...12 { roh = Suchverlauf.merken("Titel \(i)", in: roh) }
        let liste = Suchverlauf.liste(roh)
        #expect(liste.count == Suchverlauf.hoechstens)
        #expect(liste.first == "Titel 12")
        #expect(liste.last == "Titel 5")
    }

    /// So hat die iPhone-Suche bisher gespeichert. Wer aktualisiert, soll
    /// seine Liste behalten.
    @Test("Der bisherige Stand liest sich unveraendert")
    func bisherigerStand() {
        #expect(Suchverlauf.liste("Dune\nSeverance") == ["Dune", "Severance"])
        #expect(Suchverlauf.liste("").isEmpty)
    }
}
