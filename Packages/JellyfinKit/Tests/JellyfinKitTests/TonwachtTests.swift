import Foundation
import Testing
@testable import JellyfinKit

@Suite("Tonwacht")
struct TonwachtTests {

    @Test("Echter Gerätewechsel im Betrieb baut neu auf")
    func normal() {
        #expect(Tonwacht.ausgangNeuAufbauen(echterGeraetewechsel: true,
                                            spielt: true, seitUebernahme: 30))
    }

    @Test("Im Anlauf nicht — daran ist der Apple TV gestorben")
    func anlauf() {
        #expect(!Tonwacht.ausgangNeuAufbauen(echterGeraetewechsel: true,
                                             spielt: true, seitUebernahme: 4.9))
        #expect(Tonwacht.ausgangNeuAufbauen(echterGeraetewechsel: true,
                                            spielt: true, seitUebernahme: 5.1))
    }

    @Test("Was kein Gerätewechsel ist, zählt nicht")
    func keinWechsel() {
        // `categoryChange` und `routeConfigurationChange` feuern, wenn die
        // App ihre eigene Tonsitzung einrichtet.
        #expect(!Tonwacht.ausgangNeuAufbauen(echterGeraetewechsel: false,
                                             spielt: true, seitUebernahme: 30))
    }

    @Test("Ein angehaltener Player braucht keinen neuen Ausgang")
    func angehalten() {
        #expect(!Tonwacht.ausgangNeuAufbauen(echterGeraetewechsel: true,
                                             spielt: false, seitUebernahme: 30))
    }
}
