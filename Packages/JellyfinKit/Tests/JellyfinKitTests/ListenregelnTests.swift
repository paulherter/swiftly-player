import Testing
@testable import JellyfinKit

private func item(_ id: String, _ name: String = "x") -> Item {
    Item(id: id, name: name)
}

@Suite("Listenregeln")
struct ListenregelnTests {

    @Test("Doppelte fallen heraus, die erste bleibt stehen")
    func doppelteFallenHeraus() {
        let liste = [item("a", "erste"), item("b"), item("a", "zweite"), item("c")]
        let sauber = Listenregeln.ohneDoppelte(liste)
        #expect(sauber.map(\.id) == ["a", "b", "c"])
        #expect(sauber.first?.name == "erste")
    }

    @Test("Ohne Doppelte bleibt alles, wie es war")
    func nichtsZuTun() {
        let liste = [item("a"), item("b"), item("c")]
        #expect(Listenregeln.ohneDoppelte(liste).map(\.id) == ["a", "b", "c"])
    }

    @Test("Leere Liste bleibt leer")
    func leer() {
        #expect(Listenregeln.ohneDoppelte([]).isEmpty)
    }

    @Test("Anhaengen laesst nur wirklich Neues zu")
    func anhaengen() {
        let da = [item("a"), item("b")]
        let neu = [item("b"), item("c"), item("c")]
        #expect(Listenregeln.anhaengen(neu, an: da).map(\.id) == ["a", "b", "c"])
    }

    // MARK: Nachladen

    @Test("Der Ausloeser sitzt in der drittletzten Reihe")
    func ausloeserDrittletzteReihe() {
        // 30 Eintraege, 5 Spalten — drei Reihen sind 15, also Nummer 15.
        let liste = (0..<30).map { item("i\($0)") }
        #expect(Listenregeln.nachladenAb(liste, spalten: 5) == "i15")
    }

    @Test("Sind es weniger als drei Reihen, ist es der erste")
    func kuerzerAlsDreiReihen() {
        // Sonst rechnete `count - 3 * spalten` ins Negative.
        let liste = (0..<7).map { item("i\($0)") }
        #expect(Listenregeln.nachladenAb(liste, spalten: 5) == "i0")
    }

    @Test("Eine leere Liste hat keinen Ausloeser")
    func leereListe() {
        #expect(Listenregeln.nachladenAb([], spalten: 5) == nil)
    }

    @Test("Nachschub gibt es, solange nicht alles dasteht")
    func nochMehrDa() {
        #expect(Listenregeln.nochMehrDa(geladen: 40, gesamt: 120))
        #expect(!Listenregeln.nochMehrDa(geladen: 120, gesamt: 120))
        // Mehr geladen als gemeldet: der Server hat die Gesamtzahl gesenkt,
        // waehrend geblaettert wurde. Nachladen waere dann falsch.
        #expect(!Listenregeln.nochMehrDa(geladen: 121, gesamt: 120))
    }
}
