import Foundation
import Testing
@testable import JellyfinKit

/// Android-Tester, 16.09.2026: beim Warten auf die Freigabe stand statt des
/// Codes roh `Error Domain=NSURLErrorDomain Code=-1001`. Ein Netzfehler beim
/// Nachfragen darf das Warten nicht beenden; nur der abgelaufene Code tut es.
@Suite struct QuickconnectstandTests {

    @Test func abgelaufenerCodeBeendetDasWarten() {
        let stand = Quickconnectstand(fehler: Quickconnectabgelaufen())
        #expect(stand == .abgelaufen)
        #expect(stand.beendetWarten)
    }

    @Test(arguments: [-1001, -1003, -1004, -1005, -1009])
    func netzfehlerBeendetDasWartenNicht(code: Int) {
        let stand = Quickconnectstand(fehler: NSError(domain: NSURLErrorDomain, code: code))
        #expect(stand == .gescheitert)
        #expect(!stand.beendetWarten)
    }

    @Test func freigabeBeendetDasWarten() {
        #expect(Quickconnectstand.freigegeben.beendetWarten)
        #expect(!Quickconnectstand.offen.beendetWarten)
    }

    @Test func schlusstextUnterscheidetNetzUndFrist() {
        #expect(Quickconnectfrist.schlusstext(letzte: .gescheitert)
                != Quickconnectfrist.schlusstext(letzte: .abgelaufen))
        #expect(Quickconnectfrist.schlusstext(letzte: .offen)
                == Quickconnectfrist.schlusstext(letzte: .abgelaufen))
    }

    /// Kein roher `NSError`-Text, auch nicht fuer Codes ohne eigene Zeile.
    @Test(arguments: [-1001, -1003, -1004, -1005, -1009])
    func netzfehlerWirdLesbar(code: Int) {
        let text = lesbarerFehler(NSError(domain: NSURLErrorDomain, code: code))
        #expect(!text.contains("Error Domain"))
        #expect(!text.isEmpty)
    }
}
