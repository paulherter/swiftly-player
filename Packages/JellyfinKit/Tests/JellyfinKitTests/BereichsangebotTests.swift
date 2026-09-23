import Foundation
import Testing
@testable import JellyfinKit

@Suite("Bereichsangebot")
struct BereichsangebotTests {

    private let filme = Item(id: "f", name: "Filme", collectionType: "movies")
    private let serien = Item(id: "s", name: "Serien", collectionType: "tvshows")
    private let dokus = Item(id: "d", name: "Dokus", collectionType: nil)
    private let zweiteFilme = Item(id: "f2", name: "Filmabend", collectionType: "movies")
    private let musik = Item(id: "m", name: "Musik", collectionType: "music")
    private let heim = Item(id: "h", name: "Heimvideos", collectionType: "homevideos")
    private let ordner = Item(id: "b", name: "Sammlungen", collectionType: "boxsets")

    private func kiste(_ id: String, filme: Int = 0, serien: Int = 0) -> Sammlung {
        let f = (0..<filme).map { Item(id: "\(id)-f\($0)", name: "", type: "Movie") }
        let s = (0..<serien).map { Item(id: "\(id)-s\($0)", name: "", type: "Series") }
        return Sammlung(item: Item(id: id, name: id, type: "BoxSet"), mitglieder: f + s)
    }

    @Test("Nur Filme und Serien: kein Menü, alles wie vorher")
    func nichtsZuWaehlen() {
        let views = [filme, serien, musik]
        for art in ["movies", "tvshows"] {
            let a = Bereichsangebot.bilden(art: art, views: views, anteile: [:], verzeichnis: .leer)
            #expect(!a.istMenue)
            #expect(a.eintraege == [.alle])
            #expect(a.bibliotheken.count == 1)
        }
        // „Alle" liest dann aus genau der einen Bibliothek — dieselbe
        // Abfrage wie vor dem Umbau.
        let a = Bereichsangebot.bilden(art: "movies", views: views, anteile: [:], verzeichnis: nil)
        #expect(a.alleAus == "f")
    }

    @Test("Zwei Filmbibliotheken: Menü, Alle zuerst, dann die Bibliotheken")
    func zweiBibliotheken() {
        let a = Bereichsangebot.bilden(art: "movies", views: [filme, serien, zweiteFilme],
                                       anteile: [:], verzeichnis: nil)
        #expect(a.istMenue)
        #expect(a.eintraege == [.alle, .bibliothek("f"), .bibliothek("f2")])
        #expect(a.ersteBibliothek == .bibliothek("f"))
        #expect(a.alleAus == nil)
    }

    @Test("Sammlungen stehen direkt unter Alle, vor den Bibliotheken")
    func sammlungenVorBibliotheken() {
        let verzeichnis = Sammlungsverzeichnis([kiste("hp", filme: 8)])
        let a = Bereichsangebot.bilden(art: "movies", views: [filme, zweiteFilme, ordner],
                                       anteile: [:], verzeichnis: verzeichnis)
        #expect(a.eintraege == [.alle, .sammlungen, .bibliothek("f"), .bibliothek("f2")])
    }

    @Test("Nur Sammlungen, keine Zusatzbibliothek: zwei Zeilen")
    func nurSammlungen() {
        let verzeichnis = Sammlungsverzeichnis([kiste("hp", filme: 8)])
        let a = Bereichsangebot.bilden(art: "movies", views: [filme, serien, ordner],
                                       anteile: [:], verzeichnis: verzeichnis)
        #expect(a.eintraege == [.alle, .sammlungen])
        #expect(a.ersteBibliothek == nil)
        // Unter Serien gibt es keine Sammlung mit Serien — kein Menü.
        let s = Bereichsangebot.bilden(art: "tvshows", views: [filme, serien, ordner],
                                       anteile: [:], verzeichnis: verzeichnis)
        #expect(!s.istMenue)
    }

    @Test("Gemischte Bibliothek steht in beiden Bereichen, nur wo sie etwas hat")
    func gemischt() {
        let views = [filme, serien, dokus]
        let beides = ["d": Bibliotheksanteil(filme: 38, serien: 6)]
        let f = Bereichsangebot.bilden(art: "movies", views: views, anteile: beides, verzeichnis: nil)
        let s = Bereichsangebot.bilden(art: "tvshows", views: views, anteile: beides, verzeichnis: nil)
        #expect(f.eintraege == [.alle, .bibliothek("f"), .bibliothek("d")])
        #expect(s.eintraege == [.alle, .bibliothek("s"), .bibliothek("d")])

        // Ohne Serien steht sie nur unter Filme.
        let nurFilme = ["d": Bibliotheksanteil(filme: 38, serien: 0)]
        let s2 = Bereichsangebot.bilden(art: "tvshows", views: views, anteile: nurFilme, verzeichnis: nil)
        #expect(!s2.istMenue)

        // Noch nicht gezählt: sie steht (noch) nirgends.
        let f3 = Bereichsangebot.bilden(art: "movies", views: views, anteile: [:], verzeichnis: nil)
        #expect(!f3.istMenue)
    }

    @Test("Keine Sondertypen: gezählt wird, was gemischt sein kann")
    func keineSondertypen() {
        #expect(Bibliotheksgattung.kannGemischtSein(nil))
        #expect(Bibliotheksgattung.kannGemischtSein("mixed"))
        #expect(Bibliotheksgattung.kannGemischtSein("homevideos"))
        #expect(!Bibliotheksgattung.kannGemischtSein("movies"))
        #expect(!Bibliotheksgattung.kannGemischtSein("music"))
        #expect(!Bibliotheksgattung.kannGemischtSein("BoxSets"))
        // Heimvideos ohne Filme stehen nirgends — ohne dass es jemand
        // eigens verbietet.
        let a = Bereichsangebot.bilden(art: "movies", views: [filme, heim],
                                       anteile: ["h": .init(filme: 0, serien: 0)],
                                       verzeichnis: nil)
        #expect(!a.istMenue)
    }

    @Test("Gemerkte Wahl bleibt, verschwundene fällt auf Alle")
    func gemerkt() {
        let verzeichnis = Sammlungsverzeichnis([kiste("hp", filme: 8)])
        let a = Bereichsangebot.bilden(art: "movies", views: [filme, zweiteFilme],
                                       anteile: [:], verzeichnis: verzeichnis)
        #expect(a.wahl(gemerkt: nil) == .alle)
        #expect(a.wahl(gemerkt: "f2") == .bibliothek("f2"))
        #expect(a.wahl(gemerkt: "sammlungen") == .sammlungen)
        #expect(a.wahl(gemerkt: "weg") == .alle)
        // Eine einzelne Bibliothek ist keine Wahl mehr.
        let b = Bereichsangebot.bilden(art: "movies", views: [filme], anteile: [:], verzeichnis: nil)
        #expect(b.wahl(gemerkt: "f") == .alle)
        #expect(b.wahl(gemerkt: "sammlungen") == .alle)
    }

    @Test("Merkwert hin und zurück")
    func merkwert() {
        for w in [Bereichswahl.alle, .sammlungen, .bibliothek("abc")] {
            #expect(Bereichswahl(merkwert: w.merkwert) == w)
        }
    }
}

@Suite("Sammlungsverzeichnis")
struct SammlungsverzeichnisTests {

    private func kiste(_ id: String, filme: [String] = [], serien: [String] = []) -> Sammlung {
        Sammlung(item: Item(id: id, name: id, type: "BoxSet"),
                 mitglieder: filme.map { Item(id: $0, name: $0, type: "Movie") }
                           + serien.map { Item(id: $0, name: $0, type: "Series") }
                           + [Item(id: "folge", name: "", type: "Episode")])
    }

    @Test("Schwelle: erst ab zwei Titeln im Bereich")
    func schwelle() {
        let v = Sammlungsverzeichnis([
            kiste("eins", filme: ["a"]),
            kiste("zwei", filme: ["a", "b"]),
            kiste("gemischt", filme: ["c"], serien: ["x", "y"]),
        ])
        #expect(v.sammlungen(art: "movies").map(\.id) == ["zwei"])
        #expect(v.sammlungen(art: "tvshows").map(\.id) == ["gemischt"])
        #expect(v.sammlungen(art: "music").isEmpty)
    }

    @Test("Teil der Sammlung: nur, wo der Titel mit anderen im Bereich steht")
    func mitgliedschaft() {
        let v = Sammlungsverzeichnis([
            kiste("hp", filme: ["hp1", "hp2", "hp3"]),
            kiste("allein", filme: ["hp1"]),
            kiste("gemischt", filme: ["hp1"], serien: ["x", "y"]),
        ])
        #expect(v.sammlungen(mit: Item(id: "hp1", name: "", type: "Movie")).map(\.id) == ["hp"])
        #expect(v.sammlungen(mit: Item(id: "x", name: "", type: "Series")).map(\.id) == ["gemischt"])
        #expect(v.sammlungen(mit: Item(id: "zz", name: "", type: "Movie")).isEmpty)
        // Folgen gehören zu keinem Bereich.
        #expect(v.sammlungen(mit: Item(id: "folge", name: "", type: "Episode")).isEmpty)
    }

    @Test("Ausgeblendet nur, wenn der Ordner verborgen ist — fehlt er ganz, wird gezeigt")
    func ausgeblendet() {
        let film = Item(id: "f", name: "", collectionType: "movies")
        let ordner = Item(id: "b", name: "", collectionType: "boxsets")
        #expect(Sammlungsverzeichnis.ausgeblendet(sichtbar: [film], mitVerborgenen: [film, ordner]))
        #expect(!Sammlungsverzeichnis.ausgeblendet(sichtbar: [film, ordner], mitVerborgenen: [film, ordner]))
        // Jellyfin 12 am Testserver: der Ordner steht in keiner der beiden.
        #expect(!Sammlungsverzeichnis.ausgeblendet(sichtbar: [film], mitVerborgenen: [film]))
    }
}

@Suite("Regalquelle")
struct RegalquelleTests {

    @Test("Bibliothek wie bisher: Gattung und rekursiv")
    func bibliothek() {
        let q = Regalquelle(eltern: "f", art: "movies")
        #expect(q.typen == ["Movie"])
        #expect(q.rekursiv)
        #expect(q.richtung(.erscheinung) == "Descending")
    }

    @Test("Alle: ohne Eltern, immer rekursiv")
    func alle() {
        let q = Regalquelle(eltern: nil, art: "tvshows")
        #expect(q.typen == ["Series"])
        #expect(q.rekursiv)
    }

    @Test("Sammlung: erste Ebene, Jahr aufsteigend")
    func sammlung() {
        let q = Regalquelle(eltern: "hp", art: "movies", sammlung: true)
        #expect(q.typen == ["Movie"])
        #expect(!q.rekursiv)
        #expect(q.richtung(.erscheinung) == "Ascending")
        #expect(q.richtung(.name) == "Ascending")
        #expect(q.richtung(.neueste) == "Descending")
        #expect(q.schluessel != Regalquelle(eltern: "hp", art: "movies").schluessel)
    }
}

@Suite("Alle aus mehreren Bibliotheken")
struct AlleAusMehrerenTests {

    private func film(_ id: String, _ name: String, tmdb: String? = nil) -> Item {
        Item(id: id, name: name, type: "Movie", productionYear: 2026,
             providerIds: tmdb.map { ["Tmdb": $0] })
    }

    @Test("Alle liest aus den Filmbibliotheken, nicht aus der gemischten")
    func ohneGemischte() {
        let views = [Item(id: "f", name: "Filme", collectionType: "movies"),
                     Item(id: "k", name: "Kinoabend", collectionType: "movies"),
                     Item(id: "m", name: "Mixed", collectionType: nil)]
        let a = Bereichsangebot.bilden(art: "movies", views: views,
                                       anteile: ["m": .init(filme: 13, serien: 0)], verzeichnis: nil)
        // Im Menü steht die gemischte, in „Alle" nicht.
        #expect(a.eintraege.contains(.bibliothek("m")))
        #expect(a.alleQuellen == ["f", "k"])
        #expect(a.alleAus == nil)
        // Gibt es nur die gemischte, liest „Alle" aus ihr.
        let b = Bereichsangebot.bilden(art: "movies", views: [views[2]],
                                       anteile: ["m": .init(filme: 13, serien: 0)], verzeichnis: nil)
        #expect(b.alleAus == "m")
    }

    @Test("Sieb: je Titel einmal, über Seiten hinweg, nur aus den gewählten Bibliotheken")
    func sieb() {
        // Wie am Testserver: derselbe Film aus drei Bibliotheken.
        let erlaubt = [film("f1", "Toy Story 5", tmdb: "1"), film("k1", "Toy Story 5", tmdb: "1"),
                       film("f2", "Exit 8", tmdb: "2")]
        var sieb = Titelsieb(kennungen: erlaubt)
        #expect(sieb.gesamt == 2)
        let seite1 = [film("f1", "Toy Story 5", tmdb: "1"), film("got", "Game.of.Thrones.S01E01")]
        let seite2 = [film("k1", "Toy Story 5", tmdb: "1"), film("f2", "Exit 8", tmdb: "2")]
        #expect(sieb.sieben(seite1).map(\.id) == ["f1"])
        #expect(sieb.sieben(seite2).map(\.id) == ["f2"])
        sieb.vonVorn()
        #expect(sieb.sieben(seite2).map(\.id) == ["k1", "f2"])
    }

    @Test("Dieselbe Serie aus zwei Serienbibliotheken zählt einmal")
    func serien() {
        let a = Item(id: "a", name: "FROM", type: "Series", providerIds: ["Tvdb": "9"])
        let b = Item(id: "b", name: "FROM", type: "Series", providerIds: ["Tvdb": "9"])
        let c = Item(id: "c", name: "Dark", type: "Series")
        #expect(Titelsieb(kennungen: [a, b, c]).gesamt == 2)
    }

    @Test("Quelle aus mehreren siebt, eine Bibliothek nicht")
    func quelle() {
        #expect(Regalquelle(eltern: nil, art: "movies", nurAus: ["f", "k"]).siebt)
        #expect(!Regalquelle(eltern: "f", art: "movies").siebt)
    }
}
