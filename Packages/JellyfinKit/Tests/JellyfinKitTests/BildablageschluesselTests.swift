import Foundation
import Testing
@testable import JellyfinKit

@Suite("Bildablage-Schlüssel")
struct BildablageschluesselTests {

    @Test("Host, Port und Zugang fallen weg, tag bleibt")
    func ohneHostUndZugang() {
        let daheim = URL(string: "http://192.168.1.5:8096/Items/abc/Images/Primary?fillHeight=600&tag=f00&ApiKey=geheim")!
        let unterwegs = URL(string: "https://tv.example.org/Items/abc/Images/Primary?fillHeight=600&tag=f00&api_key=anders")!
        let a = Bildablageschluessel.fuer(daheim)
        #expect(a == "/Items/abc/Images/Primary?fillHeight=600&tag=f00")
        #expect(a == Bildablageschluessel.fuer(unterwegs))
    }

    @Test("Ein anderer tag ist ein anderes Bild")
    func tagZaehlt() {
        let alt = URL(string: "https://s/Items/abc/Images/Primary?tag=1")!
        let neu = URL(string: "https://s/Items/abc/Images/Primary?tag=2")!
        #expect(Bildablageschluessel.fuer(alt) != Bildablageschluessel.fuer(neu))
    }

    @Test("Ohne tag kein Platz auf der Platte")
    func ohneTag() {
        #expect(Bildablageschluessel.fuer(URL(string: "https://s/Items/abc/Images/Primary?fillHeight=600")!) == nil)
        #expect(Bildablageschluessel.fuer(URL(string: "https://s/Items/abc/Images/Primary?tag=")!) == nil)
    }
}
