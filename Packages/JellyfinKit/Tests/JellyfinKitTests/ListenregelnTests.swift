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

    @Test("Jede Kachel der letzten drei Reihen loest aus")
    func ausloeserDrittletzteReihe() {
        // 30 Eintraege, 5 Spalten — drei Reihen sind 15, also ab Nummer 15.
        let liste = (0..<30).map { item("i\($0)") }
        #expect(!Listenregeln.imNachladebereich("i14", in: liste, spalten: 5))
        #expect(Listenregeln.imNachladebereich("i15", in: liste, spalten: 5))
        #expect(Listenregeln.imNachladebereich("i29", in: liste, spalten: 5))
    }

    @Test("Sind es weniger als drei Reihen, loest jede aus")
    func kuerzerAlsDreiReihen() {
        let liste = (0..<7).map { item("i\($0)") }
        #expect(Listenregeln.imNachladebereich("i0", in: liste, spalten: 5))
    }

    @Test("Eine leere Liste hat keinen Ausloeser")
    func leereListe() {
        #expect(!Listenregeln.imNachladebereich("i0", in: [], spalten: 5))
    }

    /// Der Fehler vom Apple TV, nachgestellt: 2000 Titel, Seiten zu 60,
    /// sieben Spalten. Nach dem Zurueckkommen wird neu geladen, waehrend die
    /// Kacheln am Ende schon im Bild stehen. Vorher kuerzte das auf 60, und
    /// der eine Ausloeser war verbraucht.
    @Test("Neuladen kuerzt die Liste nicht, und am Ende loest es weiter aus")
    func grosseBibliothekNachZurueck() {
        let server = (0..<2000).map { item("i\($0)") }
        func seite(ab: Int) -> [Item] { Array(server[ab ..< min(ab + 60, server.count)]) }

        var liste: [Item] = []
        // Blaettern bis 180, wie beim Runterscrollen.
        while liste.count < 180 { liste = Listenregeln.anhaengen(seite(ab: liste.count), an: liste) }
        #expect(liste.count == 180)

        // Zurueck von der Detailseite: erste Seite frisch.
        liste = Listenregeln.auffrischen(seite(ab: 0), in: liste, gesamtVorher: 2000, gesamtJetzt: 2000)
        #expect(liste.map(\.id) == server.prefix(180).map(\.id))

        // Die Kachel, die gerade im Bild steht, loest weiter aus.
        #expect(Listenregeln.imNachladebereich("i170", in: liste, spalten: 7))

        // Und bis zum Ende laeuft es durch, ohne Luecke.
        while liste.count < server.count { liste = Listenregeln.anhaengen(seite(ab: liste.count), an: liste) }
        #expect(liste.map(\.id) == server.map(\.id))
    }

    @Test("Aendert sich die Gesamtzahl, wird ersetzt")
    func auffrischenMitNeuemTitel() {
        let alt = (0..<120).map { item("i\($0)") }
        let neu = [item("neu")] + (0..<59).map { item("i\($0)") }
        let ergebnis = Listenregeln.auffrischen(neu, in: alt, gesamtVorher: 120, gesamtJetzt: 121)
        #expect(ergebnis.map(\.id) == neu.map(\.id))
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
