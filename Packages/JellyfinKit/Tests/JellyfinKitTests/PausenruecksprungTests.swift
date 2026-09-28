import Foundation
import Testing
@testable import JellyfinKit

@Suite struct PausenruecksprungTests {
    private let jetzt = Date(timeIntervalSince1970: 1_000_000)

    @Test func kurzePauseBleibtStehen() {
        let seit = jetzt.addingTimeInterval(-Pausenruecksprung.schwelle)
        #expect(Pausenruecksprung.ziel(position: 600, pausiertSeit: seit, jetzt: jetzt,
                                       inGruppe: false) == nil)
    }

    @Test func langePauseSetztZurueck() {
        let seit = jetzt.addingTimeInterval(-Pausenruecksprung.schwelle - 1)
        #expect(Pausenruecksprung.ziel(position: 600, pausiertSeit: seit, jetzt: jetzt,
                                       inGruppe: false) == 600 - Pausenruecksprung.weite)
    }

    @Test func nichtVorDenAnfang() {
        let seit = jetzt.addingTimeInterval(-3600)
        #expect(Pausenruecksprung.ziel(position: 2, pausiertSeit: seit, jetzt: jetzt,
                                       inGruppe: false) == 0)
        #expect(Pausenruecksprung.ziel(position: 0, pausiertSeit: seit, jetzt: jetzt,
                                       inGruppe: false) == nil)
        #expect(Pausenruecksprung.ziel(position: .nan, pausiertSeit: seit, jetzt: jetzt,
                                       inGruppe: false) == nil)
    }

    @Test func inDerGruppeNie() {
        let seit = jetzt.addingTimeInterval(-3600)
        #expect(Pausenruecksprung.ziel(position: 600, pausiertSeit: seit, jetzt: jetzt,
                                       inGruppe: true) == nil)
    }

    @Test func ohnePauseNie() {
        #expect(Pausenruecksprung.ziel(position: 600, pausiertSeit: nil, jetzt: jetzt,
                                       inGruppe: false) == nil)
    }
}
