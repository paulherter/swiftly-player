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
}
