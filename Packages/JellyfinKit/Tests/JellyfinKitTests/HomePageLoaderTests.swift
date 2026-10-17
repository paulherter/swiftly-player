import Foundation
import Testing
@testable import JellyfinKit

/// **The home page by one rule, checked without a server.**
@Suite("Startseitenlader")
struct HomePageLoaderTests {

    private struct Source: HomePageSource {
        var proceed: [Item]? = []
        var next: [Item]? = []
        var new: [String: [Item]] = [:]   // key: library, "" for all
        var genres: [String: [Item]] = [:]
        struct Route: Error {}

        func resumeItems(limit: Int) async throws -> [Item] {
            guard let proceed else { throw Route() }; return proceed
        }
        func nextUp(limit: Int) async throws -> [Item] {
            guard let next else { throw Route() }; return next
        }
        func lastAdded(in library: String?, fetch: Int, showItem: Int) async -> [Item]? {
            new[library ?? ""]
        }
        func title(genre: String, limit: Int) async -> [Item]? { genres[genre] }
        var review: [Item]? = []
        func libraries() async -> [Item]? { review }
        /// What the server returns for `IncludeItemTypes=<kind>` without ParentId;
        /// if the entry is missing, the mixed list filtered by kind.
        var typed: [String: [Item]] = [:]
        func newArrivals(genre: String, fetch: Int, showItem: Int) async -> [Item]? {
            typed[genre] ?? new[""]?.filter { $0.type == genre }
        }
        /// What `IncludeItemTypes=Series` returns; key "" for all libraries.
        var seriesList: [String: [Item]] = [:]
        func newSeries(in library: String?, showItem: Int) async -> [Item]? {
            seriesList[library ?? ""]
        }
    }

    private func t(_ id: String) -> Item { Item(id: id, name: id) }

    @Test("Was in Weiterschauen steht, fehlt in Nächste Folge")
    func nextWithoutStarted() async {
        let q = Source(proceed: [t("a")], next: [t("a"), t("b")])
        let s = await HomeLoader.load(from: q, .init(disconnected: false))
        #expect(s.nextEpisode?.map(\.id) == ["b"])
    }

    @Test("Kommt Weiterschauen nicht durch, zaehlt der bisherige Stand")
    func nextAgainstPreviousState() async {
        let q = Source(proceed: nil, next: [t("a"), t("b")])
        let s = await HomeLoader.load(from: q, .init(disconnected: false, untilFromContinueWatching: [t("a")]))
        #expect(s.continueWatching == nil)
        #expect(s.nextEpisode?.map(\.id) == ["b"])
    }

    @Test("Getrennt holt je Bibliothek, gemeinsam nur eine Reihe")
    func disconnectedOrShared() async {
        let q = Source(new: ["": [t("x")], "filme": [t("f")], "serien": [t("s")]])
        let disconnected = await HomeLoader.load(from: q, .init(disconnected: true, filmLibrary: "filme", seriesLibrary: "serien"))
        #expect(disconnected.recent == nil)
        #expect(disconnected.newMovies?.map(\.id) == ["f"])
        #expect(disconnected.newSeries?.map(\.id) == ["s"])
        let gemeinsam = await HomeLoader.load(from: q, .init(disconnected: false))
        #expect(gemeinsam.recent?.map(\.id) == ["x"])
        #expect(gemeinsam.newMovies == nil && gemeinsam.newSeries == nil)
    }

    @Test("Getrennt ohne Kennung: je Art die erste Bibliothek, nie alle zusammen")
    func disconnectedWithoutId() async {
        // Movie, series and mixed library; without ParentId the new additions
        // of all would come back, with movies under "New series".
        let review = [Item(id: "mix", name: "Gemischt"),
                       Item(id: "filme", name: "Filme", collectionType: "movies"),
                       Item(id: "serien", name: "Serien", collectionType: "tvshows")]
        let q = Source(new: ["": [t("film")], "filme": [t("f")], "serien": [t("s")], "mix": [t("m")]],
                       review: review)
        let s = await HomeLoader.load(from: q, .init(disconnected: true))
        #expect(s.newMovies?.map(\.id) == ["f"])
        #expect(s.newSeries?.map(\.id) == ["s"])
    }

    private func film(_ id: String) -> Item { Item(id: id, name: id, type: "Movie") }
    private func episode(_ id: String) -> Item { Item(id: id, name: id, type: "Episode") }

    /// The new additions of all libraries, as they come without `ParentId`.
    private var overAll: [Item] { [film("f1"), episode("e1"), film("f2"), episode("e2")] }

    @Test("Nur gemischte Bibliotheken: Rueckfall ohne Bibliothek, je Gattung getrennt")
    func onlyMixed() async {
        // Libraries without CollectionType and with "mixed"; on Apple no
        // library is selected then either.
        let q = Source(new: ["": overAll, "a": [film("x")], "b": [episode("y")]],
                       review: [Item(id: "a", name: "Medien"),
                                 Item(id: "b", name: "Mediathek", collectionType: "mixed")])
        let s = await HomeLoader.load(from: q, .init(disconnected: true))
        #expect(s.newMovies?.map(\.id) == ["f1", "f2"])
        #expect(s.newSeries?.map(\.id) == ["e1", "e2"])
    }

    @Test("Nur Filmbibliothek: Neue Serien faellt auf die Folgen aller Bibliotheken zurueck")
    func onlyMovies() async {
        let q = Source(new: ["": overAll, "filme": [film("f")]],
                       review: [Item(id: "filme", name: "Filme", collectionType: "movies")])
        let s = await HomeLoader.load(from: q, .init(disconnected: true))
        #expect(s.newMovies?.map(\.id) == ["f"])
        #expect(s.newSeries?.map(\.id) == ["e1", "e2"])
    }

    @Test("Mehrere Filmbibliotheken, die erste leer: die naechste mit Neuzugaengen")
    func multipleArt() async {
        let q = Source(new: ["": overAll, "leer": [], "filme2": [film("g")], "serien": [episode("s")]],
                       review: [Item(id: "leer", name: "4K", collectionType: "movies"),
                                 Item(id: "filme2", name: "Films", collectionType: "movies"),
                                 Item(id: "serien", name: "Séries", collectionType: "tvshows")])
        let s = await HomeLoader.load(from: q, .init(disconnected: true))
        #expect(s.newMovies?.map(\.id) == ["g"])
        #expect(s.newSeries?.map(\.id) == ["s"])
    }

    @Test("CollectionType in anderer Schreibung wird erkannt")
    func spelling() async {
        let q = Source(new: ["": overAll, "filme": [film("f")], "serien": [episode("s")]],
                       review: [Item(id: "filme", name: "Filme", collectionType: "Movies"),
                                 Item(id: "serien", name: "Serien", collectionType: "TvShows")])
        let s = await HomeLoader.load(from: q, .init(disconnected: true))
        #expect(s.newMovies?.map(\.id) == ["f"])
        #expect(s.newSeries?.map(\.id) == ["s"])
    }

    @Test("Gewaehlte Bibliothek leer oder nicht erreichbar: Rueckfall statt leerer Reihe")
    func selectedEmpty() async {
        let q = Source(new: ["": overAll, "filme": []])
        let s = await HomeLoader.load(from: q, .init(disconnected: true, filmLibrary: "filme",
                                                           seriesLibrary: "weg"))
        #expect(s.newMovies?.map(\.id) == ["f1", "f2"])
        #expect(s.newSeries?.map(\.id) == ["e1", "e2"])
    }

    @Test("Bibliotheksliste nicht lesbar (aelterer Server): Rueckfall; kommt gar nichts: nil")
    func librariesDistance() async {
        let q = Source(new: ["": overAll], review: nil)
        let s = await HomeLoader.load(from: q, .init(disconnected: true))
        #expect(s.newMovies?.map(\.id) == ["f1", "f2"])
        #expect(s.newSeries?.map(\.id) == ["e1", "e2"])
        let distance = Source(new: [:], review: nil)
        let w = await HomeLoader.load(from: distance, .init(disconnected: true))
        #expect(w.newMovies == nil && w.newSeries == nil)
    }

    @Test("Viele neue Filme fuellen die gemischte Liste: Neue Serien fragt nur nach Folgen")
    func moviesDisplaceEpisodes() async {
        // A series library without a kind; many movies were added recently, so
        // the mixed list no longer contains a single episode.
        let movies = (1...24).map { film("f\($0)") }
        let q = Source(new: ["": movies], review: [Item(id: "a", name: "Filme", collectionType: "movies"),
                                                   Item(id: "b", name: "Serien")],
                       typed: ["Episode": [episode("e1")]])
        let s = await HomeLoader.load(from: q, .init(disconnected: true, filmLibrary: "a"))
        #expect(s.newSeries?.map(\.id) == ["e1"])
    }

    @Test("Server erkennt keine Folgen (gemischte Art): Rueckfall wie bis 1.0.4")
    func noEpisodesHow104() async {
        let mixed = [film("f1"), Item(id: "v1", name: "v1", type: "Video")]
        let q = Source(new: ["": mixed], review: [Item(id: "m", name: "Alles", collectionType: "mixed")],
                       typed: ["Episode": []])
        let s = await HomeLoader.load(from: q, .init(disconnected: true))
        #expect(s.newMovies?.map(\.id) == ["f1"])
        // Never movies under "New series", not even in the last fallback.
        #expect(s.newSeries?.map(\.id) == ["v1"])
    }

    @Test("Nur Filme neu, Serien ohne Bibliothekstyp: die Serien-Abfrage traegt die Reihe")
    func seriesWithoutLibraryType() async {
        let movies = (1...24).map { film("f\($0)") }
        let q = Source(new: ["": movies + [episode("e1")]],
                       review: [Item(id: "a", name: "Filme", collectionType: "movies"),
                                 Item(id: "b", name: "Serien")],
                       typed: ["Episode": []],
                       seriesList: ["": [Item(id: "s1", name: "s1", type: "Series")]])
        let s = await HomeLoader.load(from: q, .init(disconnected: true, filmLibrary: "a"))
        #expect(s.newSeries?.map(\.id) == ["s1"])
        #expect(s.newMovies?.allSatisfy { $0.type == "Movie" } == true)
        let rows = LogRing.shared.excerpt(seconds: 60).joined(separator: "\n")
        #expect(rows.contains("Neu tvshows: Serien-Abfrage"))
    }

    @Test("Serienreihe zeigt nie Filme, auch wenn alles andere leer ist")
    func seriesNeverMovies() async {
        let q = Source(new: ["": [film("f1"), film("f2")]], review: nil)
        let s = await HomeLoader.load(from: q, .init(disconnected: true))
        #expect(s.newSeries?.isEmpty == true)
        #expect(s.newMovies?.map(\.id) == ["f1", "f2"])
    }

    @Test("Gruppierte Antwort (Serien statt Folgen) wird nicht weggefiltert")
    func groupedSeries() async {
        // Like Items/Latest with GroupItems: series objects instead of episodes.
        let series = Item(id: "s1", name: "Serie", type: "Series")
        let q = Source(new: ["": [film("f1"), series]], review: [Item(id: "b", name: "Serien")],
                       typed: ["Episode": [series]])
        let s = await HomeLoader.load(from: q, .init(disconnected: true))
        #expect(s.newSeries?.map(\.id) == ["s1"])
    }

    @Test("Der Rueckfall steht mit Grund im Protokoll")
    func fallbackLog() async {
        let q = Source(new: ["": overAll], review: [Item(id: "a", name: "Medien")])
        _ = await HomeLoader.load(from: q, .init(disconnected: true))
        let rows = LogRing.shared.excerpt(seconds: 60).joined(separator: "\n")
        #expect(rows.contains("Neu movies: keine Bibliothek der Art"))
        #expect(rows.contains("Neu tvshows: keine Bibliothek der Art"))
    }

    @Test("Nichts kam an: gestört; eine einzige Reihe genuegt dagegen")
    func disrupted() async {
        let nothing = Source(proceed: nil, next: nil, new: [:])
        #expect(await HomeLoader.load(from: nothing, .init(disconnected: false)).disrupted)
        let something = Source(proceed: nil, next: nil, new: ["": []])
        #expect(!(await HomeLoader.load(from: something, .init(disconnected: false)).disrupted))
    }

    @Test("Genre-Reihen in der gewaehlten Folge, leere fallen weg, ohne Doppelte")
    func genreRails() async {
        let q = Source(genres: ["Drama": [t("d"), t("d")], "Horror": [], "Komödie": [t("k")]])
        let s = await HomeLoader.load(from: q, .init(disconnected: false, genres: ["Komödie", "Horror", "Drama", "Fehlt"]))
        #expect(s.genreRails.map(\.name) == ["Komödie", "Drama"])
        #expect(s.genreRails.last?.items.map(\.id) == ["d"])
    }

    @Test("Als Chips: keine Genre-Reihen")
    func chipsWithoutRails() async {
        let q = Source(genres: ["Drama": [t("d")]])
        let s = await HomeLoader.load(from: q, .init(disconnected: false, genres: nil))
        #expect(s.genreRails.isEmpty)
    }
}
