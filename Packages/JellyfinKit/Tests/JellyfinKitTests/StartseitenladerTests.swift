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
