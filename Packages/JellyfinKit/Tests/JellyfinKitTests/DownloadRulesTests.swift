import Foundation
import Testing
@testable import JellyfinKit

@Suite("Downloadregeln")
struct DownloadRulesTests {

    // MARK: Build helpers

    private func entries(_ id: String,
                        state: DownloadState = .waits,
                        bytes: Int64 = 1_000_000_000,
                        watched: Bool = false,
                        art: DownloadItem.Art = .film,
                        series: String? = nil, seriesIdentifier: String? = nil,
                        season: Int? = nil, episode: Int? = nil,
                        seconds: TimeInterval = 0,
                        account: String = "u1") -> DownloadItem {
        DownloadItem(id: id, account: account, art: art, title: "Titel " + id,
                       series: series, seriesIdentifier: seriesIdentifier,
                       season: season, episode: episode,
                       container: "mkv", bytes: bytes,
                       state: state, watched: watched,
                       created: Date(timeIntervalSince1970: 1_000_000 + seconds))
    }

    // MARK: one after the other

    @Test("Der aelteste Wartende ist dran")
    func oldestFirst() {
        let list = [entries("b", seconds: 20), entries("a", seconds: 10), entries("c", seconds: 30)]
        #expect(DownloadRules.nextOne(from: list, wLAN: true, onlyOverWLAN: true)?.id == "a")
    }

    @Test("Laeuft schon einer, faengt keiner an")
    func onlyOneAtATime() {
        let list = [entries("a", state: .loads), entries("b", seconds: 10)]
        #expect(DownloadRules.nextOne(from: list, wLAN: true, onlyOverWLAN: true) == nil)
    }

    @Test("Angehaltene und fehlgeschlagene faengt niemand von selbst an")
    func onlyWaiting() {
        let list = [entries("a", state: .halted), entries("b", state: .error),
                     entries("c", state: .done)]
        #expect(DownloadRules.nextOne(from: list, wLAN: true, onlyOverWLAN: true) == nil)
    }

    @Test("Ohne WLAN wartet alles, wenn nur ueber WLAN geladen werden soll")
    func withoutWLAN() {
        let list = [entries("a")]
        #expect(DownloadRules.nextOne(from: list, wLAN: false, onlyOverWLAN: true) == nil)
        #expect(DownloadRules.nextOne(from: list, wLAN: false, onlyOverWLAN: false)?.id == "a")
    }

    @Test("Gleiche Zeit: die Kennung entscheidet, nicht die Reihenfolge der Liste")
    func stableSameState() {
        let forward = [entries("a"), entries("b")]
        let backward = [entries("b"), entries("a")]
        #expect(DownloadRules.nextOne(from: forward, wLAN: true, onlyOverWLAN: true)?.id
                == DownloadRules.nextOne(from: backward, wLAN: true, onlyOverWLAN: true)?.id)
    }

    // MARK: Rules

    @Test("Mobilfunk nur, wenn es erlaubt ist")
    func cellular() {
        #expect(DownloadRules.mayLoad(wLAN: true,  onlyOverWLAN: true))
        #expect(DownloadRules.mayLoad(wLAN: true,  onlyOverWLAN: false))
        #expect(DownloadRules.mayLoad(wLAN: false, onlyOverWLAN: false))
        #expect(!DownloadRules.mayLoad(wLAN: false, onlyOverWLAN: true))
    }

    @Test("Unbekanntes Netz: nur ueber WLAN wartet ab, sonst wird geladen")
    func networkUnknown() {
        #expect(DownloadRules.networkVerdict(wLAN: nil, onlyOverWLAN: true) == .waitFor)
        #expect(DownloadRules.networkVerdict(wLAN: nil, onlyOverWLAN: false) == .load)
    }

    @Test("Mobilfunk bei nur ueber WLAN stellt zurueck, statt anzuhalten")
    func networkKnown() {
        #expect(DownloadRules.networkVerdict(wLAN: false, onlyOverWLAN: true) == .putBack)
        #expect(DownloadRules.networkVerdict(wLAN: true, onlyOverWLAN: true) == .load)
        #expect(DownloadRules.networkVerdict(wLAN: false, onlyOverWLAN: false) == .load)
    }

    // MARK: space

    @Test("Reichlich Platz: es reicht, und es gibt nichts zu raeumen")
    func spaceSuffices() {
        let a = DownloadRules.slot(for: 10_000_000_000, free: 100_000_000_000, available: [])
        #expect(a.suffices)
        #expect(a.dispensable.isEmpty)
        #expect(a.sufficesToCleanUp)
    }

    @Test("Die Reserve zaehlt mit: knapp daneben ist nicht knapp genug")
    func paddingStaysFree() {
        // Exactly as much free as the file is large: without a reserve that would be
        // a hit; with a reserve exactly the reserve is missing.
        let a = DownloadRules.slot(for: 10_000_000_000, free: 10_000_000_000, available: [])
        #expect(!a.suffices)
        #expect(a.freeAfter == -DownloadRules.padding)
    }

    @Test("Der Fuss nennt, was danach frei bleibt, solange es reicht")
    func footSuffices() {
        let f = DownloadRules.footSpace(for: 10_000_000_000, free: 61_200_000_000)
        #expect(f == .free(51_200_000_000))
    }

    @Test("Der Fuss nennt den Fehlbetrag, die Reserve eingerechnet")
    func footFew() {
        let f = DownloadRules.footSpace(for: 91_870_000_000, free: 61_200_000_000)
        #expect(f == .few(30_670_000_000 + DownloadRules.padding))
    }

    @Test("Fuss und Blatt sind sich einig, auch knapp an der Reserve")
    func footHowSheet() {
        for free: Int64 in [9_000_000_000, 10_000_000_000, 10_500_000_000,
                            11_073_741_824, 12_000_000_000] {
            let bytes: Int64 = 10_000_000_000
            let suffices = DownloadRules.slot(for: bytes, free: free, available: []).suffices
            if case .free = DownloadRules.footSpace(for: bytes, free: free) {
                #expect(suffices)
            } else {
                #expect(!suffices)
            }
        }
    }

    @Test("Ohne Auswahl fehlt nichts, auch wenn das Geraet fast voll ist")
    func footWithoutSelection() {
        #expect(DownloadRules.footSpace(for: 0, free: 500_000_000) == .free(500_000_000))
    }

    @Test("Fortschritt: feste Einheit und Stellen, von der ersten Zahl an")
    func progressFixed() {
        let de = Locale(identifier: "de_DE")
        let total: Int64 = 2_310_000_000
        let values = [0, 850_000_000, 1_000_000_000, 1_100_000_000, 2_310_000_000]
            .map { DownloadRules.progress(loaded: Int64($0), from: total, locale: de) }
        #expect(values.map(\.loaded) == ["0,00", "0,85", "1,00", "1,10", "2,31"])
        #expect(Set(values.map(\.total)) == ["2,31 GB"])
        // Under one gigabyte: whole megabytes.
        let small = DownloadRules.progress(loaded: 12_345_678, from: 734_000_000, locale: de)
        #expect(small.loaded == "12")
        #expect(small.total == "734 MB")
    }

    @Test("Fortschritt erscheint hoechstens einmal je Sekunde")
    func progressTick() {
        let g: Int64 = 2_000_000_000
        #expect(DownloadRules.progressShow(loaded: 1, total: g, before: nil, elapsed: nil))
        // Loaded enough, but too early.
        #expect(!DownloadRules.progressShow(loaded: 500_000_000, total: g,
                                                   before: 0, elapsed: 0.3))
        // Long enough, but hardly anything added.
        #expect(!DownloadRules.progressShow(loaded: 1_000, total: g,
                                                   before: 0, elapsed: 5))
        #expect(DownloadRules.progressShow(loaded: 500_000_000, total: g,
                                                  before: 0, elapsed: 1.0))
        // A fresh start and the end always get through.
        #expect(DownloadRules.progressShow(loaded: 10, total: g,
                                                  before: 900, elapsed: 0.1))
        #expect(DownloadRules.progressShow(loaded: g, total: g,
                                                  before: g - 5, elapsed: 0.1))
    }

    @Test("Der Schaetzer zaehlt zwischen den Meldungen weiter, nie zurueck")
    func estimator() {
        var s = ProgressEstimator()
        let t0 = Date(timeIntervalSince1970: 0)
        let g: Int64 = 2_000_000_000
        s.report(0, total: g, um: t0)
        s.report(10_000_000, total: g, um: t0.addingTimeInterval(1))
        // Between two reports: continue at the same pace, so more than reported.
        let center = s.value(um: t0.addingTimeInterval(1.5))
        #expect(center > 10_000_000 && center < 20_000_000)
        // The next report is below what is shown: it stays put.
        s.report(12_000_000, total: g, um: t0.addingTimeInterval(2))
        #expect(s.value(um: t0.addingTimeInterval(2)) >= center)
        // After a while without a report the number holds.
        let a = s.value(um: t0.addingTimeInterval(10))
        #expect(s.value(um: t0.addingTimeInterval(20)) == a)
        // Never above the total.
        s.report(g - 1, total: g, um: t0.addingTimeInterval(21))
        #expect(s.value(um: t0.addingTimeInterval(23)) <= g)
    }

    @Test("Angehalten steht die Zahl, und beim Fortsetzen springt sie nicht")
    func estimatorPause() {
        var s = ProgressEstimator()
        let t0 = Date(timeIntervalSince1970: 0)
        let g: Int64 = 2_000_000_000
        s.report(0, total: g, um: t0)
        s.report(10_000_000, total: g, um: t0.addingTimeInterval(1))
        let prePause = s.value(um: t0.addingTimeInterval(1.5))
        s.halt()
        #expect(s.value(um: t0.addingTimeInterval(1.6)) == prePause)
        #expect(s.value(um: t0.addingTimeInterval(60)) == prePause)
        // Resuming after a minute: no pace is computed across the pause,
        // the number stays until the real one catches up.
        s.report(11_000_000, total: g, um: t0.addingTimeInterval(61))
        #expect(s.value(um: t0.addingTimeInterval(61.5)) == prePause)
        s.report(21_000_000, total: g, um: t0.addingTimeInterval(62))
        #expect(s.value(um: t0.addingTimeInterval(62.5)) > 21_000_000)
    }

    @Test("Ein Neuanfang setzt den Schaetzer zurueck")
    func estimatorNew() {
        var s = ProgressEstimator()
        let t0 = Date(timeIntervalSince1970: 0)
        s.report(500, total: 1_000, um: t0)
        _ = s.value(um: t0)
        s.report(100, total: 1_000, um: t0.addingTimeInterval(1))
        #expect(s.value(um: t0.addingTimeInterval(1)) == 100)
    }

    @Test("Abspielen nimmt die erste ungesehene fertige Folge")
    func nextEpisode() {
        let list = [
            entries("s2f1", state: .done, art: .episode, season: 2, episode: 1),
            entries("s1f2", state: .done, watched: true, art: .episode, season: 1, episode: 2),
            entries("s1f1", state: .done, watched: true, art: .episode, season: 1, episode: 1),
            entries("s1f3", state: .loads, art: .episode, season: 1, episode: 3),
        ]
        #expect(DownloadRules.nextEpisode(from: list)?.id == "s2f1")
        // Everything seen: from the start.
        let watched = list.filter { $0.watched }
        #expect(DownloadRules.nextEpisode(from: watched)?.id == "s1f1")
        // Nothing finished: nothing to play.
        #expect(DownloadRules.nextEpisode(from: [list[3]]) == nil)
    }

    @Test("Gesehenes macht den Weg frei, Ungesehenes nicht")
    func cleanUpSuffices() {
        let available = [
            entries("alt", state: .done, bytes: 8_000_000_000, watched: true),
            entries("neu", state: .done, bytes: 9_000_000_000, watched: false),
        ]
        let a = DownloadRules.slot(for: 10_000_000_000, free: 5_000_000_000, available: available)
        #expect(!a.suffices)
        #expect(a.dispensable.map(\.id) == ["alt"])
        #expect(a.dispensableBytes == 8_000_000_000)
        // 5 - 10 - 1 = -6 GB; 8 GB of expendable files covers that.
        #expect(a.sufficesToCleanUp)
    }

    @Test("Reicht auch nach dem Aufraeumen nicht")
    func cleanUpSufficesNot() {
        let available = [entries("alt", state: .done, bytes: 1_000_000_000, watched: true)]
        let a = DownloadRules.slot(for: 60_000_000_000, free: 5_000_000_000, available: available)
        #expect(!a.suffices)
        #expect(!a.sufficesToCleanUp)
    }

    @Test("Angefangene Downloads gelten nie als entbehrlich")
    func startedStays() {
        let available = [
            entries("halb", state: .loads, bytes: 9_000_000_000, watched: true),
            entries("wartet", state: .waits, bytes: 9_000_000_000, watched: true),
        ]
        #expect(DownloadRules.dispensable(from: available).isEmpty)
    }

    @Test("Entbehrliches steht mit dem groessten zuerst")
    func largestFirst() {
        let available = [
            entries("klein", state: .done, bytes: 2_000_000_000, watched: true),
            entries("gross", state: .done, bytes: 20_000_000_000, watched: true),
            entries("mittel", state: .done, bytes: 7_000_000_000, watched: true),
        ]
        #expect(DownloadRules.dispensable(from: available).map(\.id) == ["gross", "mittel", "klein"])
    }

    // MARK: a series is one row

    @Test("Folgen derselben Serie werden eine Gruppe, Filme bleiben einzeln")
    func seriesBecomesRow() {
        let list = [
            entries("f1", art: .episode, series: "Fallout", seriesIdentifier: "S1", season: 1, episode: 2, seconds: 10),
            entries("f2", art: .episode, series: "Fallout", seriesIdentifier: "S1", season: 1, episode: 1, seconds: 20),
            entries("film", seconds: 5),
        ]
        let groups = DownloadRules.grouped(list)
        #expect(groups.count == 2)
        guard case let .series(id, title, episodes) = groups.first(where: { $0.id == "serie-S1" }) else {
            Issue.record("Serie fehlt"); return
        }
        #expect(id == "S1")
        #expect(title == "Fallout")
        // By season and episode, not by access.
        #expect(episodes.map(\.id) == ["f2", "f1"])
    }

    @Test("Die Gruppe traegt die Summe und den juengsten Zugang")
    func groupComputes() {
        let list = [
            entries("f1", bytes: 2_000_000_000, art: .episode, series: "X", seriesIdentifier: "S", season: 1, episode: 1, seconds: 10),
            entries("f2", bytes: 3_000_000_000, art: .episode, series: "X", seriesIdentifier: "S", season: 1, episode: 2, seconds: 90),
        ]
        let g = DownloadRules.grouped(list)[0]
        #expect(g.bytes == 5_000_000_000)
        #expect(g.created == Date(timeIntervalSince1970: 1_000_090))
    }

    @Test("Zwei Serien bleiben zwei Zeilen, neueste zuerst")
    func twoSeries() {
        let list = [
            entries("a", art: .episode, series: "Alt", seriesIdentifier: "A", season: 1, episode: 1, seconds: 10),
            entries("b", art: .episode, series: "Neu", seriesIdentifier: "B", season: 1, episode: 1, seconds: 900),
        ]
        #expect(DownloadRules.grouped(list).map(\.title) == ["Neu", "Alt"])
    }

    @Test("Eine Folge ohne Serienkennung steht einzeln, nicht unter nil")
    func episodeWithoutSeries() {
        let list = [entries("waise", art: .episode, series: "Irgendwas", seriesIdentifier: nil)]
        let g = DownloadRules.grouped(list)
        #expect(g.count == 1)
        guard case .single = g[0] else { Issue.record("haette einzeln stehen muessen"); return }
    }

    // MARK: Numbers

    @Test("Belegung zaehlt nur, was fertig ist")
    func allocation() {
        let list = [
            entries("a", state: .done, bytes: 4_000_000_000),
            entries("b", state: .loads,  bytes: 9_000_000_000),
            entries("c", state: .done, bytes: 1_000_000_000),
        ]
        let b = DownloadRules.allocation(list)
        #expect(b.count == 2)
        #expect(b.bytes == 5_000_000_000)
    }

    @Test("Groesse rechnet in Tausenderstufen, wie der Finder")
    func sizeInGB() {
        // 18.6 GB in steps of a thousand, not 17.3 GiB.
        let text = DownloadRules.size(18_600_000_000)
        #expect(text.contains("18"))
        #expect(text.uppercased().contains("GB"))
    }

    @Test("Russisch: Komma wie dort, Einheit lateinisch")
    func sizeRussianKeepsLatinUnit() {
        let locale = DownloadRules.sizeLocale(Locale(identifier: "ru_RU"))
        let text = Int64(18_600_000_000).formatted(.byteCount(style: .file).locale(locale))
        #expect(text.contains("18,6"))
        #expect(text.contains("GB"))
        #expect(DownloadRules.sizeLocale(Locale(identifier: "en_US")).identifier == "en_US")
    }

    @Test("Ohne Groesse vom Server gibt es keinen Anteil")
    func noShareWithoutSize() {
        var p = entries("a", bytes: 0)
        p.loaded = 500
        #expect(p.share == nil)
        var q = entries("b", bytes: 1000)
        q.loaded = 250
        #expect(q.share == 0.25)
    }

    @Test("Der Dateiname traegt Konto, Kennung und Endung")
    func fileName() {
        let p = entries("abc", account: "u9")
        #expect(p.fileName == "u9-abc.mkv")
        // Two accounts, the same ID: two files. H11.
        #expect(entries("abc", account: "u1").fileName != entries("abc", account: "u2").fileName)
    }

    @Test("Serverdaten bauen keinen Weg aus dem Ordner")
    func fileNameOutServerData() {
        func with(_ container: String?, id: String = "abc", account: String = "u1") -> String {
            DownloadItem(id: id, account: account, art: .film, title: "T",
                           container: container, bytes: 1).fileName
        }
        // Real values stay as they were, so old downloads are found.
        #expect(with("MKV") == "u1-abc.mkv")
        #expect(with("mov,mp4,m4a,3gp,3g2,mj2") == "u1-abc.mov,mp4,m4a,3gp,3g2,mj2")
        #expect(with(nil) == "u1-abc")
        #expect(with("mkv", id: "0f8e2c4a9b7d4e1fa3c5b6d7e8f90123", account: "a1b2c3d4-e5f6")
                == "a1b2c3d4-e5f6-0f8e2c4a9b7d4e1fa3c5b6d7e8f90123.mkv")
        // Everything else falls back to no extension or is neutralized.
        #expect(with("../../../../etc/passwd") == "u1-abc")
        #expect(with("mkv/x") == "u1-abc")
        #expect(with("mk\u{0}v") == "u1-abc")
        #expect(with("sehrlangeendung") == "u1-abc")
        #expect(with("") == "u1-abc")
        #expect(with("mkv", id: "../../x") == "u1-______x.mkv")
        #expect(with("mkv", account: "a/b\nc") == "a_b_c-abc.mkv")
        #expect(with(nil, id: "") == "u1-_")
        for name in [with("mkv", id: ".."), with("../x", id: "a/../b", account: "..")] {
            #expect(!name.contains("/") && !name.contains(".."))
        }
        #expect(DownloadItem.imageName(account: "u1", identifier: "../s") == "u1-___s.jpg")
    }

    @Test("Eine Kennung von aussen ist eine GUID oder wird verworfen")
    func idFromOuter() {
        #expect(PathPart.isId("0f8e2c4a9b7d4e1fa3c5b6d7e8f90123"))
        #expect(PathPart.isId("0f8e2c4a-9b7d-4e1f-a3c5-b6d7e8f90123"))
        #expect(!PathPart.isId(""))
        #expect(!PathPart.isId("../../Users"))
        #expect(!PathPart.isId("abc?x=1"))
        #expect(!PathPart.isId(String(repeating: "a", count: 65)))
    }

    // MARK: the plan from disk

    @Test("Eine Datei vom Geraet ist Direct Play, ohne Sitzung und ohne Grund")
    func planFromSlab() {
        let file = URL(fileURLWithPath: "/tmp/u1-abc.mkv")
        let plan = PlaybackPlan.fromSlab(file, container: "mkv", mediaSourceID: "q1")
        #expect(plan.url == file)
        #expect(plan.method == .directPlay)
        #expect(plan.isLossless)
        // It *is* the unchanged file, so there can be no reason.
        #expect(plan.reasons.isEmpty)
        // Without a server, no session.
        #expect(plan.playSessionID == nil)
        #expect(plan.container == "mkv")
        #expect(plan.mediaSourceID == "q1")
    }

    // MARK: The format holds over time

    @Test("Woertliches JSON — ein umbenanntes Feld faellt hier auf")
    func formatStays() throws {
        let raw = """
        {
          "id": "12ab",
          "konto": "u1",
          "art": "folge",
          "titel": "The End",
          "serie": "Fallout",
          "serienId": "S1",
          "staffel": 1,
          "folge": 1,
          "laufzeitTicks": 38400000000,
          "container": "mkv",
          "quelle": "q1",
          "bytes": 2800000000,
          "geladen": 1400000000,
          "stand": "laedt",
          "gesehen": false,
          "angelegt": 757382400,
          "nochAufDemServer": true
        }
        """
        let p = try JSONDecoder().decode(DownloadItem.self, from: Data(raw.utf8))
        #expect(p.id == "12ab")
        #expect(p.account == "u1")
        #expect(p.art == .episode)
        #expect(p.seriesIdentifier == "S1")
        #expect(p.bytes == 2_800_000_000)
        #expect(p.loaded == 1_400_000_000)
        #expect(p.state == .loads)
        #expect(p.share == 0.5)
        #expect(p.stillOnTheServer)
        #expect(p.fileName == "u1-12ab.mkv")
    }

    @Test("Ein alter Eintrag ohne die spaeteren Felder ist kein Fehler")
    func olderStore() throws {
        // `reason` is missing; that is the normal case as long as nothing went wrong.
        let raw = """
        {"id":"a","konto":"u1","art":"film","titel":"T","bytes":1,
         "geladen":0,"stand":"wartet","gesehen":false,
         "angelegt":757382400,"nochAufDemServer":true}
        """
        let p = try JSONDecoder().decode(DownloadItem.self, from: Data(raw.utf8))
        #expect(p.reason == nil)
        #expect(p.series == nil)
        #expect(p.fileName == "u1-a")
    }
}

@Suite("Nachmeldung")
struct PendingReportTests {

    private func m(_ item: String, _ ticks: Int64, _ sek: TimeInterval,
                   account: String = "u1") -> PendingReport {
        PendingReport(itemID: item, account: account, ticks: ticks,
                    moment: Date(timeIntervalSince1970: 1_000_000 + sek))
    }

    @Test("Eine Angabe je Titel — die neueste gilt")
    func newWins() {
        var a: [PendingReport] = []
        a = PostReportRules.record(m("f1", 100, 10), in: a)
        a = PostReportRules.record(m("f1", 900, 20), in: a)
        #expect(a.count == 1)
        #expect(a[0].ticks == 900)
    }

    @Test("Eine nachtraeglich hereinkommende alte Meldung ueberschreibt nicht")
    func olderLoses() {
        var a: [PendingReport] = []
        a = PostReportRules.record(m("f1", 900, 20), in: a)
        a = PostReportRules.record(m("f1", 100, 10), in: a)
        #expect(a[0].ticks == 900)
    }

    @Test("Zwei Konten teilen sich keinen Stand")
    func accountsDisconnected() {
        var a: [PendingReport] = []
        a = PostReportRules.record(m("f1", 100, 10, account: "u1"), in: a)
        a = PostReportRules.record(m("f1", 900, 20, account: "u2"), in: a)
        #expect(a.count == 2)
        #expect(PostReportRules.due(a, account: "u1").map(\.ticks) == [100])
        #expect(PostReportRules.due(a, account: "u2").map(\.ticks) == [900])
    }

    @Test("Faellig kommt aelteste zuerst")
    func railsEpisode() {
        var a: [PendingReport] = []
        a = PostReportRules.record(m("b", 1, 30), in: a)
        a = PostReportRules.record(m("a", 1, 10), in: a)
        #expect(PostReportRules.due(a, account: "u1").map(\.itemID) == ["a", "b"])
    }

    @Test("Erledigtes faellt heraus, der Rest bleibt")
    func completed() {
        var a: [PendingReport] = []
        a = PostReportRules.record(m("a", 1, 10), in: a)
        a = PostReportRules.record(m("b", 1, 20), in: a)
        let rest = PostReportRules.completed(["u1/a"], in: a)
        #expect(rest.map(\.itemID) == ["b"])
    }

    @Test("Woertliches JSON — das Format traegt ueber die Zeit")
    func format() throws {
        let raw = """
        {"itemID":"abc","konto":"u1","ticks":123456789,"wann":757382400}
        """
        let n = try JSONDecoder().decode(PendingReport.self, from: Data(raw.utf8))
        #expect(n.itemID == "abc")
        #expect(n.ticks == 123_456_789)
        #expect(n.id == "u1/abc")
    }
}

@Suite("Ein Download wird zum Item")
struct DownloadItemItemTests {

    @Test("Eine Folge traegt Serie, Staffel und Nummer mit")
    func episode() {
        let p = DownloadItem(id: "e1", account: "u1", art: .episode, title: "Der Einstieg",
                               series: "Breaking Bad", seriesIdentifier: "s1",
                               season: 1, episode: 3,
                               runtimeTicks: 38_400_000_000, bytes: 1)
        let i = p.asItem
        #expect(i.id == "e1")
        #expect(i.name == "Der Einstieg")
        #expect(i.type == "Episode")
        #expect(i.seriesName == "Breaking Bad")
        #expect(i.seriesId == "s1")
        #expect(i.parentIndexNumber == 1)
        #expect(i.indexNumber == 3)
        #expect(i.runTimeTicks == 38_400_000_000)
    }

    @Test("Ein Film ist ein Film und traegt keine Serie")
    func film() {
        let p = DownloadItem(id: "m1", account: "u1", art: .film, title: "Arrival", bytes: 1)
        let i = p.asItem
        #expect(i.type == "Movie")
        #expect(i.seriesId == nil)
        #expect(i.seriesName == nil)
    }
}
