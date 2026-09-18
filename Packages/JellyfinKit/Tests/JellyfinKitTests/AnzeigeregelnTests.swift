import Foundation
import Testing
@testable import JellyfinKit

@Suite("Anzeigeregeln")
struct AnzeigeregelnTests {

    /// Der Fall, der es auf den Fernseher geschafft hat: eine Serie hat keine
    /// eigene Laufzeit, der Server meldet 0, und auf der Kachel stand
    /// „0 Min." — weil die abgeschriebene Fassung die Prüfung nicht hatte.
    @Test("Null Sekunden sind keine Laufzeit")
    func nullIstNichts() {
        #expect(!Anzeigeregeln.laufzeitZeigen(sekunden: 0))
        #expect(!Anzeigeregeln.laufzeitZeigen(sekunden: nil))
        #expect(!Anzeigeregeln.laufzeitZeigen(sekunden: -5))
    }

    @Test("Eine echte Laufzeit wird gezeigt")
    func echteLaufzeit() {
        #expect(Anzeigeregeln.laufzeitZeigen(sekunden: 1))
        #expect(Anzeigeregeln.laufzeitZeigen(sekunden: 3600))
    }

    @Test("Ein einzelner Buchstabe ist keine Suche")
    func einBuchstabe() {
        #expect(!Anzeigeregeln.suchbegriffTaugt(""))
        #expect(!Anzeigeregeln.suchbegriffTaugt("a"))
        #expect(!Anzeigeregeln.suchbegriffTaugt("   "))
    }

    /// Wer „a " tippt, hat einen Buchstaben getippt — das Leerzeichen macht
    /// daraus keine Suche.
    @Test("Leerzeichen zählen nicht mit")
    func leerzeichenZaehlenNicht() {
        #expect(!Anzeigeregeln.suchbegriffTaugt("a "))
        #expect(!Anzeigeregeln.suchbegriffTaugt(" a"))
        #expect(Anzeigeregeln.suchbegriffTaugt(" ab "))
    }

    @Test("Ab zwei Zeichen wird gesucht")
    func abZwei() {
        #expect(Anzeigeregeln.suchbegriffTaugt("ab"))
        #expect(Anzeigeregeln.suchbegriffTaugt("Mentalist"))
    }
}

@Suite("Kachelmarke")
struct KachelmarkeTests {

    /// Wer eine Serie durchhat, will nicht lesen, wie viele Staffeln sie
    /// hatte.
    @Test("Gesehen schlaegt alles")
    func gesehenGewinnt() {
        #expect(Anzeigeregeln.kachelmarke(art: "Series", staffeln: 7,
                                          gesehen: true, offeneFolgen: 3) == .gesehen)
    }

    /// Sobald jemand angefangen hat, ist „noch 12" nuetzlicher als
    /// „7 Staffeln".
    @Test("Offene Folgen schlagen die Staffelzahl")
    func offeneVorStaffeln() {
        #expect(Anzeigeregeln.kachelmarke(art: "Series", staffeln: 7,
                                          gesehen: false, offeneFolgen: 12) == .offen(12))
    }

    @Test("Ohne offene Folgen kommt die Staffelzahl")
    func staffelzahl() {
        #expect(Anzeigeregeln.kachelmarke(art: "Series", staffeln: 7,
                                          gesehen: false, offeneFolgen: 0) == .staffeln(7))
        #expect(Anzeigeregeln.kachelmarke(art: "Series", staffeln: 7,
                                          gesehen: nil, offeneFolgen: nil) == .staffeln(7))
    }

    /// Eine Zahl, die immer eins waere, ist keine Auskunft.
    @Test("Ein ungesehener Film bekommt nichts")
    func filmOhneMarke() {
        #expect(Anzeigeregeln.kachelmarke(art: "Movie", staffeln: nil,
                                          gesehen: false, offeneFolgen: nil) == nil)
        #expect(Anzeigeregeln.kachelmarke(art: "Movie", staffeln: 1,
                                          gesehen: false, offeneFolgen: 4) == nil)
    }

    @Test("Ein gesehener Film bekommt den Haken")
    func filmGesehen() {
        #expect(Anzeigeregeln.kachelmarke(art: "Movie", staffeln: nil,
                                          gesehen: true, offeneFolgen: nil) == .gesehen)
    }

    /// Ein Server, der Null oder nichts meldet, soll keine Plakette erzeugen,
    /// die wie eine Angabe aussieht.
    @Test("Null und nichts ergeben keine Marke")
    func nullsFallenRaus() {
        #expect(Anzeigeregeln.kachelmarke(art: "Series", staffeln: 0,
                                          gesehen: false, offeneFolgen: 0) == nil)
        #expect(Anzeigeregeln.kachelmarke(art: nil, staffeln: nil,
                                          gesehen: nil, offeneFolgen: nil) == nil)
    }
}
