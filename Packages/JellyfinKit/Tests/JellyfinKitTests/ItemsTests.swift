import Testing
@testable import JellyfinKit

private func film(_ id: String, tmdb: String? = nil, imdb: String? = nil,
                  state: Bool = false) -> Item {
    var serialNumbers: [String: String] = [:]
    if let tmdb { serialNumbers["Tmdb"] = tmdb }
    if let imdb { serialNumbers["Imdb"] = imdb }
    return Item(id: id, name: "Obsession", type: "Movie",
                userData: state ? UserItemData(playbackPositionTicks: 600_000_000) : nil,
                providerIds: serialNumbers.isEmpty ? nil : serialNumbers)
}

private func episode(_ id: String, series: String, season: Int, nr: Int) -> Item {
    Item(id: id, name: "Folge", type: "Episode", seriesName: "The Mentalist",
         indexNumber: nr, parentIndexNumber: season, seriesId: series)
}

/// As on the test server: "Filme" (movies) and "Videothek" (mixed).
private let libraries = [Item(id: "videothek", name: "Videothek", collectionType: nil),
                            Item(id: "filme", name: "Filme", collectionType: "movies"),
                            Item(id: "kino", name: "Kinoabend", collectionType: "movies")]

@Suite("Werke")
struct ItemsTests {

    @Test("Gleiche TMDb-Nummer aus zwei Bibliotheken: ein Eintrag, der aus „movies“")
    func filmOutMovieLibrary() {
        let list = [film("v", tmdb: "1"), film("f", tmdb: "1")]
        let result = Items.merge(list, origin: ["v": "videothek", "f": "filme"],
                                            libraries: libraries)
        #expect(result.map(\.id) == ["f"])
    }

    @Test("Bei gleicher Art gewinnt die Bibliothek, die zuerst kommt")
    func railsEpisodeLibraries() {
        let list = [film("k", tmdb: "1"), film("f", tmdb: "1")]
        let result = Items.merge(list, origin: ["k": "kino", "f": "filme"],
                                            libraries: libraries)
        #expect(result.map(\.id) == ["f"])
    }

    @Test("Aus derselben Bibliothek gewinnt der Eintrag mit Stand")
    func stateDecides() {
        let list = [film("a", tmdb: "1"), film("b", tmdb: "1", state: true)]
        #expect(Items.merge(list).map(\.id) == ["b"])
    }

    @Test("Eine gemeinsame Nummer reicht, TMDb vor IMDb")
    func numberSuffices() {
        let list = [film("v", tmdb: "1", imdb: "tt9"), film("f", imdb: "TT9")]
        let result = Items.merge(list, origin: ["v": "videothek", "f": "filme"],
                                            libraries: libraries)
        #expect(result.map(\.id) == ["f"])
    }

    @Test("Ohne Anbieternummern wird nichts zusammengefasst")
    func withoutNumbers() {
        let list = [film("a"), film("b")]
        #expect(Items.merge(list).map(\.id) == ["a", "b"])
        #expect(!Items.hasDouble(list))
    }

    @Test("Folgen: gleiche Serie, Staffel und Nummer sind eine")
    func episodes() {
        let seriesList: Items.SeriesNumber = ["s1": ["Tvdb": "80"], "s2": ["Tvdb": "80"], "s3": ["Tvdb": "99"]]
        let list = [episode("a", series: "s2", season: 1, nr: 2),
                     episode("b", series: "s1", season: 1, nr: 2),
                     episode("c", series: "s1", season: 1, nr: 3),
                     episode("d", series: "s3", season: 1, nr: 2)]
        let result = Items.merge(list, origin: ["a": "videothek", "b": "filme"],
                                            libraries: libraries, seriesList: seriesList)
        #expect(result.map(\.id) == ["b", "c", "d"])
    }

    @Test("Folgen ohne Nummern der Serie bleiben getrennt")
    func episodesWithoutSeriesNumber() {
        let list = [episode("a", series: "s1", season: 1, nr: 2),
                     episode("b", series: "s2", season: 1, nr: 2)]
        #expect(Items.merge(list).map(\.id) == ["a", "b"])
        #expect(Items.seriesSuspicion(list) == ["s1", "s2"])
    }

    @Test("Die Reihenfolge der Liste bleibt, der Sieger rückt an den ersten Platz")
    func railsEpisodeStable() {
        let list = [film("x", tmdb: "7"), film("v", tmdb: "1"), film("y", tmdb: "8"),
                     film("f", tmdb: "1"), film("z", tmdb: "9")]
        let result = Items.merge(list, origin: ["v": "videothek", "f": "filme"],
                                            libraries: libraries)
        #expect(result.map(\.id) == ["x", "f", "y", "z"])
    }

    @Test("Sieb für „Alle“: die Kopie aus der ersten Bibliothek bleibt, gezählt je Werk")
    func filterRef() {
        var filterRef = TitleFilter(je: [("filme", [film("f", tmdb: "1"), film("g")]),
                                  ("kino", [film("k", tmdb: "1"), film("h")])])
        #expect(filterRef.total == 3)
        #expect(filterRef.seven([film("k", tmdb: "1"), film("h"), film("f", tmdb: "1"), film("g")])
            .map(\.id) == ["h", "f", "g"])
    }
}
