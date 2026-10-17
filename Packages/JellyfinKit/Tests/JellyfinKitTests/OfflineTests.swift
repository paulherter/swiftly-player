import Foundation
import Testing
@testable import JellyfinKit

/// Downloads without network: sections, next episode, watch state and
/// the report on reconnecting.
@Suite("Offline")
struct OfflineTests {

    private func episode(_ id: String, season: Int?, _ number: Int?,
                       series: String? = "s1", account: String = "u1",
                       state: DownloadState = .done,
                       runtime: Int64 = 1_000) -> DownloadItem {
        DownloadItem(id: id, account: account, art: .episode, title: id,
                       series: "Serie", seriesIdentifier: series, season: season, episode: number,
                       runtimeTicks: runtime, container: "mkv", bytes: 1, state: state)
    }

    // MARK: Next episode

    @Test("Die naechste geladene Folge derselben Staffel")
    func nextInSeason() {
        let list = [episode("e3", season: 1, 3), episode("e1", season: 1, 1), episode("e2", season: 1, 2)]
        #expect(DownloadRules.episodePost("e1", from: list)?.id == "e2")
        #expect(DownloadRules.episodePost("e2", from: list)?.id == "e3")
        #expect(DownloadRules.episodePost("e3", from: list) == nil)
    }

    @Test("Ueber das Staffelende hinweg, und eine Luecke wird uebersprungen")
    func seasonSwitchAndGap() {
        let list = [episode("a", season: 1, 9), episode("b", season: 2, 1), episode("c", season: 2, 4)]
        #expect(DownloadRules.episodePost("a", from: list)?.id == "b")
        #expect(DownloadRules.episodePost("b", from: list)?.id == "c")
    }

    @Test("Specials kommen nach einer regulaeren Folge nicht dran")
    func specials() {
        let list = [episode("a", season: 1, 1), episode("sp", season: 0, 1), episode("b", season: 1, 2)]
        #expect(DownloadRules.episodePost("a", from: list)?.id == "b")
        #expect(DownloadRules.episodePost("b", from: list) == nil)
    }

    @Test("Nur fertige Downloads, nur dieselbe Serie, nur dasselbe Konto")
    func onlyMatching() {
        let list = [episode("a", season: 1, 1),
                     episode("b", season: 1, 2, state: .loads),
                     episode("c", season: 1, 3, series: "andere"),
                     episode("d", season: 1, 4, account: "u2"),
                     episode("e", season: 1, 5)]
        #expect(DownloadRules.episodePost("a", from: list)?.id == "e")
    }

    @Test("Ohne Nummer, ohne Serie oder bei einem Film gibt es keine")
    func notArrange() {
        let film = DownloadItem(id: "f", account: "u1", art: .film, title: "f", bytes: 1, state: .done)
        let list = [episode("a", season: 1, nil), episode("b", season: 1, 2), film,
                     episode("x", season: 1, 1, series: nil)]
        #expect(DownloadRules.episodePost("a", from: list) == nil)
        #expect(DownloadRules.episodePost("f", from: list) == nil)
        #expect(DownloadRules.episodePost("x", from: list) == nil)
        #expect(DownloadRules.episodePost("fehlt", from: list) == nil)
    }

    // MARK: Sections

    @Test("Abschnitte ueberstehen die Ablage — in Ticks, wie vom Server")
    func segmentsStore() throws {
        var p = episode("a", season: 1, 1)
        p.sections = [Segment(art: .introSegment, from: 12.5, until: 71.25),
                        Segment(art: .credits, from: 2_500, until: 2_580)]
        let raw = try JSONEncoder().encode([p])
        let back = try JSONDecoder().decode([DownloadItem].self, from: raw)
        #expect(back[0].sections == p.sections)
        #expect(String(decoding: raw, as: UTF8.self).contains("\"StartTicks\":125000000"))
    }

    @Test("Eine Liste von vor 1.0.5 liest sich weiter")
    func oldList() throws {
        let raw = """
        [{"id":"a","konto":"u1","art":"folge","titel":"A","bytes":1,"geladen":1,
          "stand":"fertig","gesehen":true,"angelegt":1000,"nochAufDemServer":true}]
        """
        let p = try JSONDecoder().decode([DownloadItem].self, from: Data(raw.utf8))
        #expect(p[0].sections == nil)
        #expect(p[0].pointTicks == nil)
        #expect(p[0].recent == nil)
        #expect(p[0].watched)
    }

    @Test("Abgelegte Abschnitte gelten ohne Anfrage, sonst fragt der Server")
    func sectionsSelection() async {
        let server = [Segment(art: .introSegment, from: 1, until: 40)]
        let stored = [Segment(art: .introSegment, from: 2, until: 30)]
        let a = await DownloadRules.sections(stored: stored) {
            Issue.record("mit Abgelegtem wird nicht gefragt"); return server
        }
        #expect(a == stored)
        #expect(await DownloadRules.sections(stored: []) { server } == server)
        #expect(await DownloadRules.sections(stored: nil) { [] }.isEmpty)
    }

    private struct Route: Error {}

    @Test("Naechste Folge: ohne Netz die geladene, ohne Frage an den Server")
    func nextWithoutNetwork() async {
        let list = [episode("e1", season: 1, 1), episode("e2", season: 1, 2)]
        let now = list[0].asItem
        let n = await DownloadRules.episodePost(now, from: list, withoutNetwork: true) {
            Issue.record("ohne Netz wird nicht gefragt"); return nil
        }
        #expect(n?.id == "e2")
    }

    @Test("Naechste Folge: mit Netz wie bisher, bei Fehler die geladene")
    func nextWithNetwork() async {
        let list = [episode("e1", season: 1, 1), episode("e2", season: 1, 2)]
        let now = list[0].asItem
        let fromServer = Item(id: "e2-server", name: "E2")
        #expect(await DownloadRules.episodePost(now, from: list, withoutNetwork: false) { fromServer }?.id == "e2-server")
        // The server says "none"; it stays that way.
        #expect(await DownloadRules.episodePost(now, from: list, withoutNetwork: false) { nil } == nil)
        #expect(await DownloadRules.episodePost(now, from: list, withoutNetwork: false) { throw Route() }?.id == "e2")
        // Not loaded: none on error.
        let foreign = Item(id: "x", name: "X", type: "Episode", seriesId: "s1")
        #expect(await DownloadRules.episodePost(foreign, from: list, withoutNetwork: false) { throw Route() } == nil)
    }

    // MARK: Watch state on the device

    @Test("Ueber 90 Prozent ist gesehen, die Stelle faellt weg")
    func watchedAtEnd() {
        let p = episode("a", season: 1, 1).postPlayback(ticks: 950, moment: Date(timeIntervalSince1970: 5))
        #expect(p.watched)
        #expect(p.pointTicks == nil)
        #expect(p.resumeFrom == 0)
        #expect(p.recent == Date(timeIntervalSince1970: 5))
    }

    @Test("Dazwischen wird die Stelle gemerkt, gesehen bleibt, wie es war")
    func pointBetween() {
        var p = episode("a", season: 1, 1, runtime: 20_000_000_000)
        p = p.postPlayback(ticks: 6_000_000_000, moment: Date())
        #expect(!p.watched)
        #expect(p.pointTicks == 6_000_000_000)
        #expect(p.resumeFrom == 600)
    }

    @Test("Unter 5 Prozent zaehlt nichts als Stelle")
    func tooEarly() {
        var p = episode("a", season: 1, 1)
        p.pointTicks = 500
        p = p.postPlayback(ticks: 20, moment: Date())
        #expect(p.pointTicks == nil)
    }

    @Test("Der Server zieht nach — ausser hier liegt ein neuerer Stand")
    func follow() {
        let alt = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        let server = UserItemData(playbackPositionTicks: 300, played: false,
                                  lastPlayedDate: "1970-01-01T00:25:00.0000000Z")   // 1500
        var p = episode("a", season: 1, 1)
        p.recent = alt
        let q = DownloadRules.follow(p, watchState: server)
        #expect(q.pointTicks == 300)
        #expect(q.recent == Date(timeIntervalSince1970: 1_500))

        var here = episode("a", season: 1, 1).postPlayback(ticks: 950, moment: new)
        here = DownloadRules.follow(here, watchState: server)
        #expect(here.watched, "der Stand von hier ist neuer und noch nicht gemeldet")
        #expect(DownloadRules.follow(p, watchState: nil) == p)

        // After the report the server carries the same timestamp, rounded;
        // then it counts again.
        var reported = episode("a", season: 1, 1).postPlayback(ticks: 500, moment: Date(timeIntervalSince1970: 1_500.4))
        reported = DownloadRules.follow(reported, watchState: server)
        #expect(reported.pointTicks == 300)
    }

    @Test("Der Sehstand kommt beim Anlegen mit")
    func create() {
        let p = DownloadItem(id: "a", account: "u1", art: .film, title: "A", bytes: 1,
                               watchState: UserItemData(playbackPositionTicks: 42, played: true,
                                                      lastPlayedDate: "2026-09-03T14:10:09.2201736Z"))
        #expect(p.watched)
        #expect(p.pointTicks == 42)
        #expect(p.recent != nil)
    }

    // MARK: Report on reconnecting

    private func m(_ item: String, _ sek: TimeInterval, account: String = "u1") -> PendingReport {
        PendingReport(itemID: item, account: account, ticks: 1, moment: Date(timeIntervalSince1970: sek))
    }

    @Test("Der neuere Zeitstempel gewinnt")
    func conflict() {
        #expect(PostReportRules.dispatch(m("a", 200), serverLast: Date(timeIntervalSince1970: 100)))
        #expect(!PostReportRules.dispatch(m("a", 100), serverLast: Date(timeIntervalSince1970: 200)))
        #expect(!PostReportRules.dispatch(m("a", 100), serverLast: Date(timeIntervalSince1970: 100)))
        #expect(PostReportRules.dispatch(m("a", 100), serverLast: nil))
    }

    @Test("Geht eine Meldung doch durch, ist die liegende ueberholt — nur fuer dieses Konto")
    func overFetches() {
        let store = [m("a", 1), m("a", 2, account: "u2"), m("b", 3)]
        let rest = PostReportRules.overFetches(itemID: "a", account: "u1", in: store)
        #expect(rest.map(\.id) == ["u2/a", "u1/b"])
    }

    @Test("LastPlayedDate wird als Text gelesen und bleibt mit jedem Decoder lesbar")
    func moment() throws {
        let raw = #"{"PlaybackPositionTicks":5,"Played":true,"LastPlayedDate":"2026-09-03T14:10:09.2201736Z"}"#
        let d = try JSONDecoder().decode(UserItemData.self, from: Data(raw.utf8))
        let expects = ISO8601DateFormatter().date(from: "2026-09-03T14:10:09Z")!
        #expect(abs(d.lastPlay!.timeIntervalSince(expects) - 0.22) < 0.01)
        // An item with watch state, read back with the ordinary decoder.
        let anew = try JSONDecoder().decode(UserItemData.self, from: JSONEncoder().encode(d))
        #expect(anew == d)
    }
}
