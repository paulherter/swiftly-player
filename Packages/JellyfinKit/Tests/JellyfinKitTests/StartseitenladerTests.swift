import Foundation
import Testing
@testable import JellyfinKit

/// **Die Startseite nach einer Regel — geprueft ohne Server.**
@Suite("Startseitenlader")
struct StartseitenladerTests {

    private struct Quelle: Startseitenquelle {
        var weiter: [Item]? = []
        var naechste: [Item]? = []
        var neu: [String: [Item]] = [:]   // Schluessel: Bibliothek, "" fuer alle
        var gattungen: [String: [Item]] = [:]
        struct Weg: Error {}

        func resumeItems(limit: Int) async throws -> [Item] {
            guard let weiter else { throw Weg() }; return weiter
        }
        func nextUp(limit: Int) async throws -> [Item] {
            guard let naechste else { throw Weg() }; return naechste
        }
        func zuletztHinzugefuegt(in bibliothek: String?, holen: Int, zeigen: Int) async -> [Item]? {
            neu[bibliothek ?? ""]
        }
        func titel(gattung: String, limit: Int) async -> [Item]? { gattungen[gattung] }
        var sichten: [Item]? = []
        func bibliotheken() async -> [Item]? { sichten }
        /// Was der Server fuer `IncludeItemTypes=<Gattung>` ohne ParentId
        /// liefert; fehlt der Eintrag, die gemischte Liste nach Gattung gefiltert.
        var getypt: [String: [Item]] = [:]
        func neuzugaenge(gattung: String, holen: Int, zeigen: Int) async -> [Item]? {
            getypt[gattung] ?? neu[""]?.filter { $0.type == gattung }
        }
        /// Was `IncludeItemTypes=Series` liefert; Schluessel „" fuer alle Bibliotheken.
        var serien: [String: [Item]] = [:]
        func neueSerien(in bibliothek: String?, zeigen: Int) async -> [Item]? {
            serien[bibliothek ?? ""]
        }
    }

    private func t(_ id: String) -> Item { Item(id: id, name: id) }

    @Test("Was in Weiterschauen steht, fehlt in Nächste Folge")
    func naechsteOhneAngefangenes() async {
        let q = Quelle(weiter: [t("a")], naechste: [t("a"), t("b")])
        let s = await Startseitenlader.laden(von: q, .init(getrennt: false))
        #expect(s.naechsteFolge?.map(\.id) == ["b"])
    }

    @Test("Kommt Weiterschauen nicht durch, zaehlt der bisherige Stand")
    func naechsteGegenBisherigenStand() async {
        let q = Quelle(weiter: nil, naechste: [t("a"), t("b")])
        let s = await Startseitenlader.laden(von: q, .init(getrennt: false, bisherWeiterschauen: [t("a")]))
        #expect(s.weiterschauen == nil)
        #expect(s.naechsteFolge?.map(\.id) == ["b"])
    }

    @Test("Getrennt holt je Bibliothek, gemeinsam nur eine Reihe")
    func getrenntOderGemeinsam() async {
        let q = Quelle(neu: ["": [t("x")], "filme": [t("f")], "serien": [t("s")]])
        let getrennt = await Startseitenlader.laden(von: q, .init(getrennt: true, filmBibliothek: "filme", serienBibliothek: "serien"))
        #expect(getrennt.zuletzt == nil)
        #expect(getrennt.neueFilme?.map(\.id) == ["f"])
        #expect(getrennt.neueSerien?.map(\.id) == ["s"])
        let gemeinsam = await Startseitenlader.laden(von: q, .init(getrennt: false))
        #expect(gemeinsam.zuletzt?.map(\.id) == ["x"])
        #expect(gemeinsam.neueFilme == nil && gemeinsam.neueSerien == nil)
    }

    @Test("Getrennt ohne Kennung: je Art die erste Bibliothek, nie alle zusammen")
    func getrenntOhneKennung() async {
        // Film-, Serien- und gemischte Bibliothek; ohne ParentId kaemen die
        // Neuzugaenge aller — Filme in „Neue Serien".
        let sichten = [Item(id: "mix", name: "Gemischt"),
                       Item(id: "filme", name: "Filme", collectionType: "movies"),
                       Item(id: "serien", name: "Serien", collectionType: "tvshows")]
        let q = Quelle(neu: ["": [t("film")], "filme": [t("f")], "serien": [t("s")], "mix": [t("m")]],
                       sichten: sichten)
        let s = await Startseitenlader.laden(von: q, .init(getrennt: true))
        #expect(s.neueFilme?.map(\.id) == ["f"])
        #expect(s.neueSerien?.map(\.id) == ["s"])
    }

    private func film(_ id: String) -> Item { Item(id: id, name: id, type: "Movie") }
    private func folge(_ id: String) -> Item { Item(id: id, name: id, type: "Episode") }

    /// Die Neuzugaenge aller Bibliotheken, wie sie ohne `ParentId` kommen.
    private var ueberAlle: [Item] { [film("f1"), folge("e1"), film("f2"), folge("e2")] }

    @Test("Nur gemischte Bibliotheken: Rueckfall ohne Bibliothek, je Gattung getrennt")
    func nurGemischte() async {
        // Bibliotheken ohne CollectionType und mit „mixed" — auf Apple ist
        // dann auch keine Bibliothek gewaehlt.
        let q = Quelle(neu: ["": ueberAlle, "a": [film("x")], "b": [folge("y")]],
                       sichten: [Item(id: "a", name: "Medien"),
                                 Item(id: "b", name: "Mediathek", collectionType: "mixed")])
        let s = await Startseitenlader.laden(von: q, .init(getrennt: true))
        #expect(s.neueFilme?.map(\.id) == ["f1", "f2"])
        #expect(s.neueSerien?.map(\.id) == ["e1", "e2"])
    }

    @Test("Nur Filmbibliothek: Neue Serien faellt auf die Folgen aller Bibliotheken zurueck")
    func nurFilme() async {
        let q = Quelle(neu: ["": ueberAlle, "filme": [film("f")]],
                       sichten: [Item(id: "filme", name: "Filme", collectionType: "movies")])
        let s = await Startseitenlader.laden(von: q, .init(getrennt: true))
        #expect(s.neueFilme?.map(\.id) == ["f"])
        #expect(s.neueSerien?.map(\.id) == ["e1", "e2"])
    }

    @Test("Mehrere Filmbibliotheken, die erste leer: die naechste mit Neuzugaengen")
    func mehrereDerArt() async {
        let q = Quelle(neu: ["": ueberAlle, "leer": [], "filme2": [film("g")], "serien": [folge("s")]],
                       sichten: [Item(id: "leer", name: "4K", collectionType: "movies"),
                                 Item(id: "filme2", name: "Films", collectionType: "movies"),
                                 Item(id: "serien", name: "Séries", collectionType: "tvshows")])
        let s = await Startseitenlader.laden(von: q, .init(getrennt: true))
        #expect(s.neueFilme?.map(\.id) == ["g"])
        #expect(s.neueSerien?.map(\.id) == ["s"])
    }

    @Test("CollectionType in anderer Schreibung wird erkannt")
    func schreibung() async {
        let q = Quelle(neu: ["": ueberAlle, "filme": [film("f")], "serien": [folge("s")]],
                       sichten: [Item(id: "filme", name: "Filme", collectionType: "Movies"),
                                 Item(id: "serien", name: "Serien", collectionType: "TvShows")])
        let s = await Startseitenlader.laden(von: q, .init(getrennt: true))
        #expect(s.neueFilme?.map(\.id) == ["f"])
        #expect(s.neueSerien?.map(\.id) == ["s"])
    }

    @Test("Gewaehlte Bibliothek leer oder nicht erreichbar: Rueckfall statt leerer Reihe")
    func gewaehlteLeer() async {
        let q = Quelle(neu: ["": ueberAlle, "filme": []])
        let s = await Startseitenlader.laden(von: q, .init(getrennt: true, filmBibliothek: "filme",
                                                           serienBibliothek: "weg"))
        #expect(s.neueFilme?.map(\.id) == ["f1", "f2"])
        #expect(s.neueSerien?.map(\.id) == ["e1", "e2"])
    }

    @Test("Bibliotheksliste nicht lesbar (aelterer Server): Rueckfall; kommt gar nichts: nil")
    func bibliothekenWeg() async {
        let q = Quelle(neu: ["": ueberAlle], sichten: nil)
        let s = await Startseitenlader.laden(von: q, .init(getrennt: true))
        #expect(s.neueFilme?.map(\.id) == ["f1", "f2"])
        #expect(s.neueSerien?.map(\.id) == ["e1", "e2"])
        let weg = Quelle(neu: [:], sichten: nil)
        let w = await Startseitenlader.laden(von: weg, .init(getrennt: true))
        #expect(w.neueFilme == nil && w.neueSerien == nil)
    }

    @Test("Viele neue Filme fuellen die gemischte Liste: Neue Serien fragt nur nach Folgen")
    func filmeVerdraengenFolgen() async {
        // Serienbibliothek ohne Art; zuletzt kamen viele Filme dazu, die
        // gemischte Liste enthaelt keine einzige Folge mehr.
        let filme = (1...24).map { film("f\($0)") }
        let q = Quelle(neu: ["": filme], sichten: [Item(id: "a", name: "Filme", collectionType: "movies"),
                                                   Item(id: "b", name: "Serien")],
                       getypt: ["Episode": [folge("e1")]])
        let s = await Startseitenlader.laden(von: q, .init(getrennt: true, filmBibliothek: "a"))
        #expect(s.neueSerien?.map(\.id) == ["e1"])
    }

    @Test("Server erkennt keine Folgen (gemischte Art): Rueckfall wie bis 1.0.4")
    func keineFolgenWie104() async {
        let gemischt = [film("f1"), Item(id: "v1", name: "v1", type: "Video")]
        let q = Quelle(neu: ["": gemischt], sichten: [Item(id: "m", name: "Alles", collectionType: "mixed")],
                       getypt: ["Episode": []])
        let s = await Startseitenlader.laden(von: q, .init(getrennt: true))
        #expect(s.neueFilme?.map(\.id) == ["f1"])
        // Nie Filme in „Neue Serien" — auch nicht im letzten Rueckfall.
        #expect(s.neueSerien?.map(\.id) == ["v1"])
    }

    @Test("Nur Filme neu, Serien ohne Bibliothekstyp: die Serien-Abfrage traegt die Reihe")
    func serienOhneBibliothekstyp() async {
        let filme = (1...24).map { film("f\($0)") }
        let q = Quelle(neu: ["": filme + [folge("e1")]],
                       sichten: [Item(id: "a", name: "Filme", collectionType: "movies"),
                                 Item(id: "b", name: "Serien")],
                       getypt: ["Episode": []],
                       serien: ["": [Item(id: "s1", name: "s1", type: "Series")]])
        let s = await Startseitenlader.laden(von: q, .init(getrennt: true, filmBibliothek: "a"))
        #expect(s.neueSerien?.map(\.id) == ["s1"])
        #expect(s.neueFilme?.allSatisfy { $0.type == "Movie" } == true)
        let zeilen = Protokollring.geteilt.auszug(sekunden: 60).joined(separator: "\n")
        #expect(zeilen.contains("Neu tvshows: Serien-Abfrage"))
    }

    @Test("Serienreihe zeigt nie Filme, auch wenn alles andere leer ist")
    func serienNieFilme() async {
        let q = Quelle(neu: ["": [film("f1"), film("f2")]], sichten: nil)
        let s = await Startseitenlader.laden(von: q, .init(getrennt: true))
        #expect(s.neueSerien?.isEmpty == true)
        #expect(s.neueFilme?.map(\.id) == ["f1", "f2"])
    }

    @Test("Gruppierte Antwort (Serien statt Folgen) wird nicht weggefiltert")
    func gruppierteSerien() async {
        // Wie Items/Latest mit GroupItems: Serienobjekte statt Folgen.
        let serie = Item(id: "s1", name: "Serie", type: "Series")
        let q = Quelle(neu: ["": [film("f1"), serie]], sichten: [Item(id: "b", name: "Serien")],
                       getypt: ["Episode": [serie]])
        let s = await Startseitenlader.laden(von: q, .init(getrennt: true))
        #expect(s.neueSerien?.map(\.id) == ["s1"])
    }

    @Test("Der Rueckfall steht mit Grund im Protokoll")
    func rueckfallImProtokoll() async {
        let q = Quelle(neu: ["": ueberAlle], sichten: [Item(id: "a", name: "Medien")])
        _ = await Startseitenlader.laden(von: q, .init(getrennt: true))
        let zeilen = Protokollring.geteilt.auszug(sekunden: 60).joined(separator: "\n")
        #expect(zeilen.contains("Neu movies: keine Bibliothek der Art"))
        #expect(zeilen.contains("Neu tvshows: keine Bibliothek der Art"))
    }

    @Test("Nichts kam an: gestört; eine einzige Reihe genuegt dagegen")
    func gestoert() async {
        let nichts = Quelle(weiter: nil, naechste: nil, neu: [:])
        #expect(await Startseitenlader.laden(von: nichts, .init(getrennt: false)).gestoert)
        let etwas = Quelle(weiter: nil, naechste: nil, neu: ["": []])
        #expect(!(await Startseitenlader.laden(von: etwas, .init(getrennt: false)).gestoert))
    }

    @Test("Genre-Reihen in der gewaehlten Folge, leere fallen weg, ohne Doppelte")
    func gattungsreihen() async {
        let q = Quelle(gattungen: ["Drama": [t("d"), t("d")], "Horror": [], "Komödie": [t("k")]])
        let s = await Startseitenlader.laden(von: q, .init(getrennt: false, gattungen: ["Komödie", "Horror", "Drama", "Fehlt"]))
        #expect(s.gattungsreihen.map(\.name) == ["Komödie", "Drama"])
        #expect(s.gattungsreihen.last?.items.map(\.id) == ["d"])
    }

    @Test("Als Chips: keine Genre-Reihen")
    func chipsOhneReihen() async {
        let q = Quelle(gattungen: ["Drama": [t("d")]])
        let s = await Startseitenlader.laden(von: q, .init(getrennt: false, gattungen: nil))
        #expect(s.gattungsreihen.isEmpty)
    }
}
