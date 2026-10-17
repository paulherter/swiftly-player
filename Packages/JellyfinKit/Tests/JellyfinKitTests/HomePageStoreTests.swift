import Foundation
import Testing
@testable import JellyfinKit

@Suite("Startseitenablage")
struct HomePageStoreTests {

    /// An entry as the server sends it, with state, images and
    /// provider IDs, so the round trip checks more than ID and name.
    private func episode() throws -> Item {
        let json = """
        {"Id":"f1","Name":"Pilot","Type":"Episode","SeriesId":"s1","SeriesName":"Serie",
         "IndexNumber":1,"ParentIndexNumber":2,"Overview":"Worum es geht.",
         "ImageTags":{"Primary":"abc"},"BackdropImageTags":["b1"],
         "ProviderIds":{"Tvdb":"42"},"RunTimeTicks":27000000000,
         "UserData":{"PlaybackPositionTicks":6000000000,"Played":false,"IsFavorite":true}}
        """
        return try JSONDecoder().decode(Item.self, from: Data(json.utf8))
    }

    @Test("Rundreise: was abgelegt wird, kommt gleich zurück")
    func roundTrip() throws {
        let f = try episode()
        let store = HomeStore(libraries: [Item(id: "b", name: "Serien")],
                                       continueWatching: [f], nextEpisode: [f], recent: [],
                                       newMovies: [], newSeries: [f],
                                       genreRails: [.init(name: "Drama", items: [f])])
        let back = try #require(HomeStore.read(try store.data()))
        #expect(back == store)
        #expect(back.continueWatching.first?.userData?.playbackPositionTicks == 6000000000)
        #expect(back.continueWatching.first?.imageTags?["Primary"] == "abc")
    }

    @Test("Andere Fassung, Kaputtes und Leeres werden nicht gezeigt")
    func discarded() throws {
        let f = try episode()
        var alt = HomeStore(libraries: [], continueWatching: [f], nextEpisode: [],
                                    recent: [], newMovies: [], newSeries: [], genreRails: [])
        alt.version = HomeStore.currentVersion + 1
        #expect(HomeStore.read(try alt.data()) == nil)
        #expect(HomeStore.read(Data("{\"fassung\":1".utf8)) == nil)
        let empty = HomeStore(libraries: [Item(id: "b", name: "x")], continueWatching: [],
                                     nextEpisode: [], recent: [], newMovies: [], newSeries: [],
                                     genreRails: [.init(name: "Drama", items: [])])
        #expect(HomeStore.read(try empty.data()) == nil)
    }

    @Test("Dateiname je Konto, stabil und ohne Adresse")
    func fileName() {
        let a = HomeStore.fileName(account: "https://server.example|u1")
        #expect(a == HomeStore.fileName(account: "https://server.example|u1"))
        #expect(a != HomeStore.fileName(account: "https://server.example|u2"))
        #expect(!a.contains("server"))
        #expect(a.hasSuffix(".json"))
    }
}
