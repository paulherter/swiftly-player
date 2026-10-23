import Testing
import Foundation
@testable import JellyfinKit

@Suite("Wiedergabelisten")
struct PlaylistDirectoryTests {

    private func decode(_ json: String) throws -> [Item] {
        try JSONDecoder().decode(ItemsResponse.self, from: Data(json.utf8)).items
    }

    @Test("Eine Wiedergabeliste liest Typ und Medienart")
    func decoding() throws {
        let list = try decode("""
        {"Items":[
          {"Id":"p1","Name":"Watchlist","Type":"Playlist","MediaType":"Video","ChildCount":3},
          {"Id":"p2","Name":"Musik","Type":"Playlist","MediaType":"Audio"}
        ],"TotalRecordCount":2}
        """)
        #expect(list.map(\.type) == ["Playlist", "Playlist"])
        #expect(list.map(\.mediaType) == ["Video", "Audio"])
        #expect(list.filter(VideoPlaylist.isVideo).map(\.id) == ["p1"])
    }

    @Test("Ohne Medienart zählt die Liste, ein anderer Typ nicht")
    func withoutMediaType() {
        #expect(VideoPlaylist.isVideo(Item(id: "a", name: "", type: "Playlist")))
        #expect(!VideoPlaylist.isVideo(Item(id: "b", name: "", type: "BoxSet", mediaType: "Video")))
        #expect(!VideoPlaylist.isVideo(Item(id: "c", name: "", type: "Playlist", mediaType: "Audio")))
    }

    @Test("Einträge: Videos bleiben, Lieder fallen heraus")
    func entries() throws {
        let list = try decode("""
        {"Items":[
          {"Id":"m","Name":"Film","Type":"Movie","MediaType":"Video"},
          {"Id":"e","Name":"Folge","Type":"Episode","MediaType":"Video"},
          {"Id":"s","Name":"Lied","Type":"Audio","MediaType":"Audio"},
          {"Id":"v","Name":"Clip","Type":"Trailer","MediaType":"Video"}
        ]}
        """)
        #expect(list.filter(VideoPlaylist.isVideoEntry).map(\.id) == ["m", "e", "v"])
    }

    @Test("Anzeige: Filme unter Filme, Folgen unter Serien, ohne Bereich alles, Reihenfolge bleibt")
    func shown() throws {
        let list = try decode("""
        {"Items":[
          {"Id":"e1","Name":"A","Type":"Episode"},
          {"Id":"m1","Name":"B","Type":"Movie"},
          {"Id":"e2","Name":"C","Type":"Episode"}
        ]}
        """)
        #expect(VideoPlaylist.shown(list, art: "movies").map(\.id) == ["m1"])
        #expect(VideoPlaylist.shown(list, art: "tvshows").map(\.id) == ["e1", "e2"])
        #expect(VideoPlaylist.shown(list, art: nil).map(\.id) == ["e1", "m1", "e2"])
    }

    private func playlist(_ id: String, movies: Int = 0, episodes: Int = 0) -> VideoPlaylist {
        VideoPlaylist(item: Item(id: id, name: id, type: "Playlist", mediaType: "Video"),
                      members: (0..<movies).map { Item(id: "\(id)f\($0)", name: "", type: "Movie") }
                        + (0..<episodes).map { Item(id: "\(id)e\($0)", name: "", type: "Episode") })
    }

    @Test("Bereiche: Filme unter Filme, Folgen unter Serien, Gemischtes in beiden")
    func sections() {
        let d = PlaylistDirectory([playlist("film", movies: 2), playlist("folge", episodes: 3),
                                   playlist("beides", movies: 1, episodes: 1), playlist("leer")])
        #expect(d.playlists(art: "movies").map(\.id) == ["film", "beides"])
        #expect(d.playlists(art: "tvshows").map(\.id) == ["folge", "beides"])
        #expect(d.playlists(art: "music").isEmpty)
        #expect(d.all.first { $0.id == "film" }?.count(art: "movies") == 2)
    }

    @Test("Menü: nur wer Wiedergabelisten hat, bekommt den Eintrag")
    func menu() {
        let film = Item(id: "f", name: "", collectionType: "movies")
        let without = SectionOffering.compose(art: "movies", views: [film], shares: [:],
                                              directory: nil, playlists: PlaylistDirectory([]))
        #expect(!without.isMenu)
        #expect(without.entries == [.all])
        let with = SectionOffering.compose(art: "movies", views: [film], shares: [:], directory: nil,
                                           playlists: PlaylistDirectory([playlist("x", movies: 1)]))
        #expect(with.isMenu)
        #expect(with.entries == [.all, .playlists])
        #expect(with.choice(remembered: "wiedergabelisten") == .playlists)
        // Only episodes: the movies section stays as it was.
        let onlySeries = SectionOffering.compose(art: "movies", views: [film], shares: [:], directory: nil,
                                                 playlists: PlaylistDirectory([playlist("y", episodes: 2)]))
        #expect(!onlySeries.isMenu)
        #expect(SectionSelection(rememberValue: SectionSelection.playlists.rememberValue) == .playlists)
    }

    @Test("Die Ansichtswahl der Startseite bleibt ohne Wiedergabelisten")
    func startSelection() {
        let list = Item(id: "pl", name: "", collectionType: "playlists")
        #expect(!StartLibraries.selectable(list))
    }
}
