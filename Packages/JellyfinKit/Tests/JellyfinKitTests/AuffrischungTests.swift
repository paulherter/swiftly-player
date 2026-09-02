import Foundation
import Testing
@testable import JellyfinKit

@Suite("Auffrischung")
struct AuffrischungTests {

    @Test("Noch nie geladen — dann auf jeden Fall")
    func nochNie() {
        #expect(Auffrischung.faelligBeiRueckkehr(zuletzt: nil))
    }

    @Test("Kurz weggeschaltet — die Reihen bleiben stehen")
    func kurzWeg() {
        let jetzt = Date()
        let eben = jetzt.addingTimeInterval(-5)
        #expect(!Auffrischung.faelligBeiRueckkehr(zuletzt: eben, jetzt: jetzt))
    }

    @Test("Genau auf der Frist zählt schon als fällig")
    func aufDerKante() {
        let jetzt = Date()
        let genau = jetzt.addingTimeInterval(-Auffrischung.frist)
        #expect(Auffrischung.faelligBeiRueckkehr(zuletzt: genau, jetzt: jetzt))
    }

    /// Der Fall, um den es geht: auf dem Fernseher zu Ende gesehen, dann zum
    /// Handy gegriffen. Ein Gerätewechsel dauert länger als die Frist.
    @Test("Nach einem Gerätewechsel wird neu geholt")
    func geraetewechsel() {
        let jetzt = Date()
        let vorher = jetzt.addingTimeInterval(-90)
        #expect(Auffrischung.faelligBeiRueckkehr(zuletzt: vorher, jetzt: jetzt))
    }

    @Test("Eine eigene Frist gilt statt der voreingestellten")
    func eigeneFrist() {
        let jetzt = Date()
        let vorSechzig = jetzt.addingTimeInterval(-60)
        #expect(!Auffrischung.faelligBeiRueckkehr(zuletzt: vorSechzig,
                                                  jetzt: jetzt, frist: 120))
        #expect(Auffrischung.faelligBeiRueckkehr(zuletzt: vorSechzig,
                                                 jetzt: jetzt, frist: 10))
    }
}
