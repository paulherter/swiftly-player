import Foundation
import Testing
@testable import JellyfinKit

@Suite("Vorläufige Serie aus einer Folge")
struct VorlaeufigeSerieTests {

    private func folge(serie: String? = "s1", name: String? = "Young Sheldon") -> Item {
        Item(id: "f1", name: "Folge 1", type: "Episode",
             seriesName: name, seriesId: serie)
    }

    @Test("Nimmt Kennung und Namen aus der Folge und gilt als Serie")
    func nimmtWasDaIst() throws {
        let s = try #require(Item.vorlaeufigeSerie(zu: folge()))
        #expect(s.id == "s1")
        #expect(s.name == "Young Sheldon")
        #expect(s.type == "Series")
    }

    /// Ohne Serie gibt es nichts vorwegzunehmen — dann soll die Seite laden,
    /// statt einen Eintrag zu zeigen, der auf nichts zeigt.
    @Test("Ohne Serienkennung oder Serienname kommt nichts zurück")
    func ohneAngabenNichts() {
        #expect(Item.vorlaeufigeSerie(zu: folge(serie: nil)) == nil)
        #expect(Item.vorlaeufigeSerie(zu: folge(name: nil)) == nil)
    }

    @Test("Der Erzeuger füllt nur, was genannt wird")
    func nurGenanntes() {
        let i = Item(id: "x", name: "Ein Film", type: "Movie")
        #expect(i.overview == nil)
        #expect(i.userData == nil)
        #expect(i.genres == nil)
    }
}
