import Foundation
import Testing
@testable import JellyfinKit

/// The rules behind the tester feedback round: header image, people,
/// filmography.
@Suite("Tester-Runde")
struct TesterRoundTests {

    private let addresses = ImageAddress(base: URL(string: "https://tv.example.de")!, token: "abc")
    private func item(_ json: String) throws -> Item {
        try JSONDecoder().decode(Item.self, from: Data(json.utf8))
    }

    @Test("Kopf: der eigene Hintergrund zuerst")
    func headerBackground() throws {
        let film = try item(#"{"Id":"m1","Name":"Film","BackdropImageTags":["bd"],"ImageTags":{"Primary":"p"}}"#)
        #expect(ImageSelection.header(film, addresses: addresses)?.path.contains("/Items/m1/Images/Backdrop") == true)
    }

    @Test("Kopf: ohne Hintergrund das Vorschaubild")
    func headerPreview() throws {
        let series = try item(#"{"Id":"s1","Name":"Serie","ImageTags":{"Primary":"p","Thumb":"t"}}"#)
        #expect(ImageSelection.header(series, addresses: addresses)?.path.contains("/Items/s1/Images/Thumb") == true)
    }

    @Test("Kopf: nur ein Plakat heisst nichts — dann sucht die App weiter")
    func headerOnlyPoster() throws {
        let series = try item(#"{"Id":"s1","Name":"Serie","ImageTags":{"Primary":"p"}}"#)
        #expect(ImageSelection.header(series, addresses: addresses) == nil)
        #expect(ImageSelection.portrait(series, addresses: addresses) != nil)
    }

    @Test("Person: Geburtstag als Tag, Ort, TMDB-Kennung")
    func person() throws {
        let p = try item(#"{"Id":"p1","Name":"Simon Baker","Type":"Person","PremiereDate":"1969-07-30T00:00:00.0000000Z","ProductionLocations":["Launceston, Tasmania, Australia"],"ProviderIds":{"Tmdb":"1122","Imdb":"nm0048932"}}"#)
        #expect(p.daysDate == DateComponents(year: 1969, month: 7, day: 30))
        #expect(p.productionLocations?.first == "Launceston, Tasmania, Australia")
        #expect(p.tmdbId == 1122)
    }

    @Test("Filmografie: Personen fallen heraus, Doppelte auch")
    func filmography() {
        let json = #"""
        {"id":1,"cast":[
          {"id":10,"mediaType":"movie","title":"L.A. Confidential","releaseDate":"1997-09-19","posterPath":"/a.jpg"},
          {"id":11,"mediaType":"tv","name":"The Guardian","firstAirDate":"2001-09-25"},
          {"id":10,"mediaType":"movie","title":"L.A. Confidential"},
          {"id":12,"mediaType":"person","name":"Niemand"}]}
        """#
        let t = Seerr.hit(fromFilmography: Data(json.utf8))
        #expect(t.map(\.art) == ["movie", "tv"])
        #expect(t.first?.year == 1997)
    }
}
