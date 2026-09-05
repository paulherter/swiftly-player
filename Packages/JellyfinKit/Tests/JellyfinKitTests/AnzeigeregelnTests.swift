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
