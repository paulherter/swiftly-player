import Foundation
import Testing
@testable import JellyfinKit

@Suite("Extras")
struct ExtrasTests {
    @Test("Antwort von SpecialFeatures: Liste mit Art, ein kaputter Eintrag nimmt die anderen nicht mit")
    func antwortLesen() throws {
        let json = """
        [{"Id":"a1","Name":"Hinter den Kulissen","Type":"Video","ExtraType":"BehindTheScenes","RunTimeTicks":6000000000},
         {"Name":"ohne Kennung"},
         {"Id":"a2","Name":"Interview","Type":"Video"}]
        """
        let liste = try JSONDecoder().decode(Nachsichtig<Item>.self, from: Data(json.utf8)).werte
        #expect(liste.map(\.id) == ["a1", "a2"])
        #expect(liste.first?.extraType == "BehindTheScenes")
        #expect(liste.last?.extraType == nil)
    }
}
