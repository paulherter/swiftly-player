import Testing
@testable import JellyfinKit

@Suite("Bewertungsfrage")
struct BewertungsfrageTests {

    @Test("Erst ab dem dritten fertigen Titel")
    func erstAbSchwelle() {
        #expect(!Bewertungsfrage.faellig(fertig: 2, zuletztGefragt: nil, fassung: "1.0.3"))
        #expect(Bewertungsfrage.faellig(fertig: 3, zuletztGefragt: nil, fassung: "1.0.3"))
    }

    @Test("Hoechstens einmal je Fassung")
    func einmalJeFassung() {
        #expect(!Bewertungsfrage.faellig(fertig: 9, zuletztGefragt: "1.0.3", fassung: "1.0.3"))
        #expect(Bewertungsfrage.faellig(fertig: 9, zuletztGefragt: "1.0.2", fassung: "1.0.3"))
    }

    @Test("Neunzig Prozent gelten als fertig, der Abspann muss nicht mit")
    func neunzigProzent() {
        #expect(Bewertungsfrage.zaehltAlsFertig(position: 5_400, dauer: 6_000))
        #expect(!Bewertungsfrage.zaehltAlsFertig(position: 3_000, dauer: 6_000))
    }

    @Test("Ein kurzer Clip zaehlt nicht")
    func kurzerClip() {
        #expect(!Bewertungsfrage.zaehltAlsFertig(position: 45, dauer: 45))
        #expect(!Bewertungsfrage.zaehltAlsFertig(position: 0, dauer: 0))
    }
}
