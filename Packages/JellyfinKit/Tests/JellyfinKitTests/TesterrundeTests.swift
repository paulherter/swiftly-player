import Foundation
import Testing
@testable import JellyfinKit

/// Die Regeln hinter der Tester-Runde vom 11.09.2026: Kopfbild, Personen,
/// Filmografie.
@Suite("Tester-Runde")
struct TesterrundeTests {

    private let adressen = Bildadresse(basis: URL(string: "https://tv.example.de")!, token: "abc")
    private func item(_ json: String) throws -> Item {
        try JSONDecoder().decode(Item.self, from: Data(json.utf8))
    }

    @Test("Kopf: der eigene Hintergrund zuerst")
    func kopfHintergrund() throws {
        let film = try item(#"{"Id":"m1","Name":"Film","BackdropImageTags":["bd"],"ImageTags":{"Primary":"p"}}"#)
        #expect(Bildwahl.kopf(film, adressen: adressen)?.path.contains("/Items/m1/Images/Backdrop") == true)
    }

    @Test("Kopf: ohne Hintergrund das Vorschaubild")
    func kopfVorschau() throws {
        let serie = try item(#"{"Id":"s1","Name":"Serie","ImageTags":{"Primary":"p","Thumb":"t"}}"#)
        #expect(Bildwahl.kopf(serie, adressen: adressen)?.path.contains("/Items/s1/Images/Thumb") == true)
    }

    @Test("Kopf: nur ein Plakat heisst nichts — dann sucht die App weiter")
    func kopfNurPlakat() throws {
        let serie = try item(#"{"Id":"s1","Name":"Serie","ImageTags":{"Primary":"p"}}"#)
        #expect(Bildwahl.kopf(serie, adressen: adressen) == nil)
        #expect(Bildwahl.hochkant(serie, adressen: adressen) != nil)
    }

    @Test("Person: Geburtstag als Tag, Ort, TMDB-Kennung")
    func person() throws {
        let p = try item(#"{"Id":"p1","Name":"Simon Baker","Type":"Person","PremiereDate":"1969-07-30T00:00:00.0000000Z","ProductionLocations":["Launceston, Tasmania, Australia"],"ProviderIds":{"Tmdb":"1122","Imdb":"nm0048932"}}"#)
        #expect(p.tagesdatum == DateComponents(year: 1969, month: 7, day: 30))
        #expect(p.productionLocations?.first == "Launceston, Tasmania, Australia")
        #expect(p.tmdbKennung == 1122)
    }

    @Test("Filmografie: Personen fallen heraus, Doppelte auch")
    func filmografie() {
        let json = #"""
        {"id":1,"cast":[
          {"id":10,"mediaType":"movie","title":"L.A. Confidential","releaseDate":"1997-09-19","posterPath":"/a.jpg"},
          {"id":11,"mediaType":"tv","name":"The Guardian","firstAirDate":"2001-09-25"},
          {"id":10,"mediaType":"movie","title":"L.A. Confidential"},
          {"id":12,"mediaType":"person","name":"Niemand"}]}
        """#
        let t = Seerr.treffer(ausFilmografie: Data(json.utf8))
        #expect(t.map(\.art) == ["movie", "tv"])
        #expect(t.first?.jahr == 1997)
    }
}
