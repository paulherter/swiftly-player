import Foundation
import Testing
@testable import JellyfinKit

@Suite("Bildablage-Schlüssel")
struct ImageStoreKeyTests {

    @Test("Host, Port und Zugang fallen weg, tag bleibt")
    func withoutHostAndAccess() {
        let atHome = URL(string: "http://192.168.1.5:8096/Items/abc/Images/Primary?fillHeight=600&tag=f00&ApiKey=geheim")!
        let onTheGo = URL(string: "https://tv.example.org/Items/abc/Images/Primary?fillHeight=600&tag=f00&api_key=anders")!
        let a = ImageStoreKey.of(atHome)
        #expect(a == "/Items/abc/Images/Primary?fillHeight=600&tag=f00")
        #expect(a == ImageStoreKey.of(onTheGo))
    }

    @Test("Ein anderer tag ist ein anderes Bild")
    func tagCounts() {
        let alt = URL(string: "https://s/Items/abc/Images/Primary?tag=1")!
        let new = URL(string: "https://s/Items/abc/Images/Primary?tag=2")!
        #expect(ImageStoreKey.of(alt) != ImageStoreKey.of(new))
    }

    @Test("Ohne tag kein Platz auf der Platte")
    func withoutTag() {
        #expect(ImageStoreKey.of(URL(string: "https://s/Items/abc/Images/Primary?fillHeight=600")!) == nil)
        #expect(ImageStoreKey.of(URL(string: "https://s/Items/abc/Images/Primary?tag=")!) == nil)
    }
}
