import Foundation
import Testing
@testable import JellyfinKit

@Suite("Bereichsangebot")
struct SectionOfferingTests {

    private let movies = Item(id: "f", name: "Filme", collectionType: "movies")
    private let seriesList = Item(id: "s", name: "Serien", collectionType: "tvshows")
    private let docs = Item(id: "d", name: "Dokus", collectionType: nil)
    private let secondMovies = Item(id: "f2", name: "Filmabend", collectionType: "movies")
    private let music = Item(id: "m", name: "Musik", collectionType: "music")
    private let homeBase = Item(id: "h", name: "Heimvideos", collectionType: "homevideos")
    private let folder = Item(id: "b", name: "Sammlungen", collectionType: "boxsets")

    private func container(_ id: String, movies: Int = 0, seriesList: Int = 0) -> ItemCollection {
        let f = (0..<movies).map { Item(id: "\(id)-f\($0)", name: "", type: "Movie") }
        let s = (0..<seriesList).map { Item(id: "\(id)-s\($0)", name: "", type: "Series") }
        return ItemCollection(item: Item(id: id, name: id, type: "BoxSet"), members: f + s)
    }

    @Test("Nur Filme und Serien: kein Menü, alles wie vorher")
    func notSelect() {
        let views = [movies, seriesList, music]
        for art in ["movies", "tvshows"] {
            let a = SectionOffering.compose(art: art, views: views, shares: [:], directory: .empty)
            #expect(!a.isMenu)
            #expect(a.entries == [.all])
            #expect(a.libraries.count == 1)
        }
        // "All" then reads from exactly that one library, the same
        // query as before the rework.
        let a = SectionOffering.compose(art: "movies", views: views, shares: [:], directory: nil)
        #expect(a.allOut == "f")
    }

    @Test("Zwei Filmbibliotheken: Menü, Alle zuerst, dann die Bibliotheken")
    func twoLibraries() {
        let a = SectionOffering.compose(art: "movies", views: [movies, seriesList, secondMovies],
                                       shares: [:], directory: nil)
        #expect(a.isMenu)
        #expect(a.entries == [.all, .library("f"), .library("f2")])
        #expect(a.firstLibrary == .library("f"))
        #expect(a.allOut == nil)
    }

    @Test("Sammlungen stehen direkt unter Alle, vor den Bibliotheken")
    func collectionsPreLibraries() {
        let directory = CollectionDirectory([container("hp", movies: 8)])
        let a = SectionOffering.compose(art: "movies", views: [movies, secondMovies, folder],
                                       shares: [:], directory: directory)
        #expect(a.entries == [.all, .collections, .library("f"), .library("f2")])
    }

    @Test("Nur Sammlungen, keine Zusatzbibliothek: zwei Zeilen")
    func onlyCollections() {
        let directory = CollectionDirectory([container("hp", movies: 8)])
        let a = SectionOffering.compose(art: "movies", views: [movies, seriesList, folder],
                                       shares: [:], directory: directory)
        #expect(a.entries == [.all, .collections])
        #expect(a.firstLibrary == nil)
        // Under series there is no collection with series, so no menu.
        let s = SectionOffering.compose(art: "tvshows", views: [movies, seriesList, folder],
                                       shares: [:], directory: directory)
        #expect(!s.isMenu)
    }

    @Test("Gemischte Bibliothek steht in beiden Bereichen, nur wo sie etwas hat")
    func mixed() {
        let views = [movies, seriesList, docs]
        let beides = ["d": LibraryShare(movies: 38, seriesList: 6)]
        let f = SectionOffering.compose(art: "movies", views: views, shares: beides, directory: nil)
        let s = SectionOffering.compose(art: "tvshows", views: views, shares: beides, directory: nil)
        #expect(f.entries == [.all, .library("f"), .library("d")])
        #expect(s.entries == [.all, .library("s"), .library("d")])

        // Without series it appears only under movies.
        let onlyMovies = ["d": LibraryShare(movies: 38, seriesList: 0)]
        let s2 = SectionOffering.compose(art: "tvshows", views: views, shares: onlyMovies, directory: nil)
        #expect(!s2.isMenu)

        // Not counted yet: it appears nowhere (yet).
        let f3 = SectionOffering.compose(art: "movies", views: views, shares: [:], directory: nil)
        #expect(!f3.isMenu)
    }

    @Test("Keine Sondertypen: gezählt wird, was gemischt sein kann")
    func noSpecialTypes() {
        #expect(LibraryGenre.canBeMixed(nil))
        #expect(LibraryGenre.canBeMixed("mixed"))
        #expect(LibraryGenre.canBeMixed("homevideos"))
        #expect(!LibraryGenre.canBeMixed("movies"))
        #expect(!LibraryGenre.canBeMixed("music"))
        #expect(!LibraryGenre.canBeMixed("BoxSets"))
        // Home videos without movies appear nowhere, without anyone
        // having to forbid it explicitly.
        let a = SectionOffering.compose(art: "movies", views: [movies, homeBase],
                                       shares: ["h": .init(movies: 0, seriesList: 0)],
                                       directory: nil)
        #expect(!a.isMenu)
    }

    @Test("Gemerkte Wahl bleibt, verschwundene fällt auf Alle")
    func remembered() {
        let directory = CollectionDirectory([container("hp", movies: 8)])
        let a = SectionOffering.compose(art: "movies", views: [movies, secondMovies],
                                       shares: [:], directory: directory)
        #expect(a.choice(remembered: nil) == .all)
        #expect(a.choice(remembered: "f2") == .library("f2"))
        #expect(a.choice(remembered: "sammlungen") == .collections)
        #expect(a.choice(remembered: "weg") == .all)
        // A single library is no longer a choice.
        let b = SectionOffering.compose(art: "movies", views: [movies], shares: [:], directory: nil)
        #expect(b.choice(remembered: "f") == .all)
        #expect(b.choice(remembered: "sammlungen") == .all)
    }

    @Test("Merkwert hin und zurück")
    func rememberValue() {
        for w in [SectionSelection.all, .collections, .library("abc")] {
            #expect(SectionSelection(rememberValue: w.rememberValue) == w)
        }
    }
}

@Suite("Sammlungsverzeichnis")
struct CollectionDirectoryTests {

    private func container(_ id: String, movies: [String] = [], seriesList: [String] = []) -> ItemCollection {
        ItemCollection(item: Item(id: id, name: id, type: "BoxSet"),
                 members: movies.map { Item(id: $0, name: $0, type: "Movie") }
                           + seriesList.map { Item(id: $0, name: $0, type: "Series") }
                           + [Item(id: "folge", name: "", type: "Episode")])
    }

    @Test("Schwelle: erst ab zwei Titeln im Bereich")
    func threshold() {
        let v = CollectionDirectory([
            container("eins", movies: ["a"]),
            container("zwei", movies: ["a", "b"]),
            container("gemischt", movies: ["c"], seriesList: ["x", "y"]),
        ])
        #expect(v.collections(art: "movies").map(\.id) == ["zwei"])
        #expect(v.collections(art: "tvshows").map(\.id) == ["gemischt"])
        #expect(v.collections(art: "music").isEmpty)
    }

    @Test("Teil der Sammlung: nur, wo der Titel mit anderen im Bereich steht")
    func membership() {
        let v = CollectionDirectory([
            container("hp", movies: ["hp1", "hp2", "hp3"]),
            container("allein", movies: ["hp1"]),
            container("gemischt", movies: ["hp1"], seriesList: ["x", "y"]),
        ])
        #expect(v.collections(with: Item(id: "hp1", name: "", type: "Movie")).map(\.id) == ["hp"])
        #expect(v.collections(with: Item(id: "x", name: "", type: "Series")).map(\.id) == ["gemischt"])
        #expect(v.collections(with: Item(id: "zz", name: "", type: "Movie")).isEmpty)
        // Episodes belong to no section.
        #expect(v.collections(with: Item(id: "folge", name: "", type: "Episode")).isEmpty)
    }

    @Test("Ausgeblendet nur, wenn der Ordner verborgen ist — fehlt er ganz, wird gezeigt")
    func hidden() {
        let film = Item(id: "f", name: "", collectionType: "movies")
        let folder = Item(id: "b", name: "", collectionType: "boxsets")
        #expect(CollectionDirectory.hidden(visible: [film], withHidden: [film, folder]))
        #expect(!CollectionDirectory.hidden(visible: [film, folder], withHidden: [film, folder]))
        // Jellyfin 12 on the test server: the folder appears in neither of the two.
        #expect(!CollectionDirectory.hidden(visible: [film], withHidden: [film]))
    }
}

@Suite("Regalquelle")
struct ShelfSourceTests {

    @Test("Bibliothek wie bisher: Gattung und rekursiv")
    func library() {
        let q = ShelfSource(parent: "f", art: "movies")
        #expect(q.types == ["Movie"])
        #expect(q.recursive)
        #expect(q.bearing(.erscheinung) == "Descending")
    }

    @Test("Alle: ohne Eltern, immer rekursiv")
    func all() {
        let q = ShelfSource(parent: nil, art: "tvshows")
        #expect(q.types == ["Series"])
        #expect(q.recursive)
    }

    @Test("Sammlung: erste Ebene, Jahr aufsteigend")
    func collection() {
        let q = ShelfSource(parent: "hp", art: "movies", collection: true)
        #expect(q.types == ["Movie"])
        #expect(!q.recursive)
        #expect(q.bearing(.erscheinung) == "Ascending")
        #expect(q.bearing(.name) == "Ascending")
        #expect(q.bearing(.latest) == "Descending")
        #expect(q.key != ShelfSource(parent: "hp", art: "movies").key)
    }
}

@Suite("Alle aus mehreren Bibliotheken")
struct AllOutMultipleTests {

    private func film(_ id: String, _ name: String, tmdb: String? = nil) -> Item {
        Item(id: id, name: name, type: "Movie", productionYear: 2026,
             providerIds: tmdb.map { ["Tmdb": $0] })
    }

    @Test("Alle liest aus den Filmbibliotheken, nicht aus der gemischten")
    func withoutMixed() {
        let views = [Item(id: "f", name: "Filme", collectionType: "movies"),
                     Item(id: "k", name: "Kinoabend", collectionType: "movies"),
                     Item(id: "m", name: "Mixed", collectionType: nil)]
        let a = SectionOffering.compose(art: "movies", views: views,
                                       shares: ["m": .init(movies: 13, seriesList: 0)], directory: nil)
        // The menu lists the mixed one, "All" does not.
        #expect(a.entries.contains(.library("m")))
        #expect(a.allSources == ["f", "k"])
        #expect(a.allOut == nil)
        // If only the mixed one exists, "All" reads from it.
        let b = SectionOffering.compose(art: "movies", views: [views[2]],
                                       shares: ["m": .init(movies: 13, seriesList: 0)], directory: nil)
        #expect(b.allOut == "m")
    }

    @Test("Sieb: je Titel einmal, über Seiten hinweg, nur aus den gewählten Bibliotheken")
    func filterRef() {
        // As on the test server: the same movie from three libraries.
        let allowed = [film("f1", "Toy Story 5", tmdb: "1"), film("k1", "Toy Story 5", tmdb: "1"),
                       film("f2", "Exit 8", tmdb: "2")]
        var filterRef = TitleFilter(identifiers: allowed)
        #expect(filterRef.total == 2)
        let page1 = [film("f1", "Toy Story 5", tmdb: "1"), film("got", "Game.of.Thrones.S01E01")]
        let page2 = [film("k1", "Toy Story 5", tmdb: "1"), film("f2", "Exit 8", tmdb: "2")]
        #expect(filterRef.seven(page1).map(\.id) == ["f1"])
        #expect(filterRef.seven(page2).map(\.id) == ["f2"])
        // Which copy stays is decided beforehand, not by which comes first.
        filterRef.fromFront()
        #expect(filterRef.seven(page2).map(\.id) == ["f2"])
        #expect(filterRef.seven(page1).map(\.id) == ["f1"])
    }

    @Test("Dieselbe Serie aus zwei Serienbibliotheken zählt einmal")
    func seriesList() {
        let a = Item(id: "a", name: "FROM", type: "Series", providerIds: ["Tvdb": "9"])
        let b = Item(id: "b", name: "FROM", type: "Series", providerIds: ["Tvdb": "9"])
        let c = Item(id: "c", name: "Dark", type: "Series")
        #expect(TitleFilter(identifiers: [a, b, c]).total == 2)
    }

    @Test("Quelle aus mehreren siebt, eine Bibliothek nicht")
    func source() {
        #expect(ShelfSource(parent: nil, art: "movies", onlyOut: ["f", "k"]).isFiltering)
        #expect(!ShelfSource(parent: "f", art: "movies").isFiltering)
    }
}
