import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import JellyfinKit

/// **"Gesehen von" (the Jelly Twiggy plugin): what is read, drawn and said.**
///
/// The captions are translated, so the wording depends on the device language. The tests
/// check the statement (which numbers appear, which parts are there), not the phrasing.
@Suite("Gesehen von", .serialized)
struct WatchersTests {

    private func watcher(plays: Int = 0, last: Date? = nil, progress: Double? = nil,
                         watched: Int? = nil, total: Int? = nil) -> Watcher {
        Watcher(userID: "u", name: "Anna", imageTag: nil, playCount: plays, lastWatched: last,
                progressPercent: progress, watchedCount: watched, totalCount: total)
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let now = Date(timeIntervalSince1970: 1_800_000_000) // a Friday, 08:00 UTC

    // MARK: Reading

    @Test("Die Antwort des Plugins wird gelesen, auch mit fehlenden Feldern")
    func decoding() throws {
        let json = """
        [{"UserId":"6a1f0c2e9b3d4e5f8a7b6c5d4e3f2a1b","UserName":"Anna","ImageTag":"abc",
          "PlayCount":2,"LastWatched":"2026-11-02T20:15:00.0000000Z","ProgressPercent":null,
          "WatchedCount":null,"TotalCount":null},
         {"UserId":"b2","UserName":"Peter","PlayCount":0,"ProgressPercent":45},
         {"UserId":"c3"}]
        """
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { try TimestampFormat.read(from: $0) }
        let list = try d.decode([Watcher].self, from: Data(json.utf8))
        #expect(list.count == 3)
        #expect(list[0].name == "Anna" && list[0].imageTag == "abc" && list[0].playCount == 2)
        #expect(list[0].lastWatched != nil)
        #expect(list[1].progressPercent == 45 && list[1].lastWatched == nil)
        // Only the user id is required; a nameless watcher still gets a letter.
        #expect(list[2].name.isEmpty && list[2].playCount == 0 && list[2].initial == "?")
    }

    // MARK: Ring

    @Test("Einmal zu Ende gesehen ist der Ring voll, auch beim erneuten Schauen")
    func ringWatched() {
        #expect(watcher(plays: 1).ring == 1)
        #expect(watcher(plays: 3, progress: 45).ring == 1)
    }

    @Test("Nie zu Ende gesehen: der Ring zeigt, wie weit")
    func ringProgress() {
        #expect(watcher(progress: 45).ring == 0.45)
        #expect(watcher(progress: 250).ring == 1)
        #expect(watcher().ring == 0)
    }

    @Test("Eine Serie füllt den Ring nach Folgen")
    func ringSeries() {
        #expect(watcher(plays: 1, watched: 7, total: 10).ring == 0.7)
        #expect(watcher(watched: 10, total: 10).ring == 1)
        // A total of zero must not divide; it falls back to the film rule.
        #expect(watcher(plays: 1, watched: 0, total: 0).ring == 1)
    }

    // MARK: Caption

    @Test("Wie oft erst ab dem zweiten Mal")
    func captionCount() {
        #expect(!watcher(plays: 1).caption(now: now, calendar: calendar).contains("1"))
        #expect(watcher(plays: 3).caption(now: now, calendar: calendar).contains("3"))
    }

    @Test("Eine Serie nennt gesehene und alle Folgen, solange nicht alle gesehen sind")
    func captionSeries() {
        let partly = watcher(watched: 7, total: 10).caption(now: now, calendar: calendar)
        #expect(partly.contains("7") && partly.contains("10"))
        #expect(!watcher(watched: 10, total: 10).caption(now: now, calendar: calendar).contains("10"))
    }

    @Test("Der Fortschritt nur bei einem nie zu Ende gesehenen Film")
    func captionProgress() {
        #expect(watcher(progress: 45).caption(now: now, calendar: calendar).contains("45"))
        // Watched once and started again: the caption says how often, not how far.
        #expect(!watcher(plays: 2, progress: 45).caption(now: now, calendar: calendar).contains("45"))
    }

    @Test("Ohne Angaben bleibt nur der Name")
    func captionEmpty() {
        #expect(watcher(plays: 1).caption(now: now, calendar: calendar).isEmpty)
        #expect(watcher(plays: 1).spoken(now: now, calendar: calendar) == "Anna")
        #expect(watcher(plays: 2).spoken(now: now, calendar: calendar).hasPrefix("Anna, "))
    }

    @Test("Heute, gestern und vor ein paar Tagen sind drei verschiedene Wörter, dann das Datum")
    func days() {
        let hour: TimeInterval = 3600, day: TimeInterval = 86_400
        let today = Watcher.day(of: now - hour, now: now, calendar: calendar)
        // Late last night is yesterday this morning: calendar days, not 24-hour spans.
        let yesterday = Watcher.day(of: now - 9 * hour, now: now, calendar: calendar)
        let threeDays = Watcher.day(of: now - 3 * day, now: now, calendar: calendar)
        let weeks = Watcher.day(of: now - 20 * day, now: now, calendar: calendar)
        #expect(Set([today, yesterday, threeDays, weeks]).count == 4)
        #expect(threeDays.contains("3"))
        let digits = { (text: String) in text.contains { $0.isNumber } }
        #expect(!digits(today) && !digits(yesterday))
        #expect(digits(weeks))
    }

    // MARK: Is the plugin there

    /// Answers every request with the status and body set for the test, and counts them.
    final class Stub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var status = 200
        nonisolated(unsafe) static var body = Data("[]".utf8)
        nonisolated(unsafe) static var paths: [String] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            Self.paths.append(request.url?.path ?? "")
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                           httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func client(kind: ServerKind = .jellyfin) async -> JellyfinClient {
        Stub.paths = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        let c = JellyfinClient(baseURL: URL(string: "https://tv.example.de")!, deviceID: "d", deviceName: "P",
                               urlSession: URLSession(configuration: config), kind: kind)
        await c.setSession(Session(accessToken: "t", userID: "u1", userName: "T",
                                   serverURL: URL(string: "https://tv.example.de")!))
        return c
    }

    @Test("Mit Plugin: die Liste, auch eine leere")
    func pluginThere() async {
        Stub.status = 200
        Stub.body = Data(#"[{"UserId":"a","UserName":"Anna","PlayCount":1}]"#.utf8)
        let c = await client()
        #expect(await c.watchers(itemID: "film")?.map(\.name) == ["Anna"])
        #expect(Stub.paths == ["/JellyTwiggy/Items/film/Watchers"])
        Stub.body = Data("[]".utf8)
        #expect(await c.watchers(itemID: "other") == [])
        #expect(await c.watchersPluginMissing == false)
    }

    @Test("Ohne Plugin: nach zwei verschiedenen 404 wird nicht mehr gefragt")
    func pluginMissing() async {
        Stub.status = 404
        Stub.body = Data()
        let c = await client()
        #expect(await c.watchers(itemID: "a") == nil)
        // One unknown title alone proves nothing, and the same title again neither.
        #expect(await c.watchersPluginMissing == false)
        _ = await c.watchers(itemID: "a")
        #expect(await c.watchersPluginMissing == false)
        _ = await c.watchers(itemID: "b")
        #expect(await c.watchersPluginMissing == true)
        let asked = Stub.paths.count
        #expect(await c.watchers(itemID: "c") == nil)
        #expect(Stub.paths.count == asked)
    }

    @Test("405 heißt sofort: kein Plugin")
    func pluginMethodNotAllowed() async {
        Stub.status = 405
        Stub.body = Data()
        let c = await client()
        #expect(await c.watchers(itemID: "a") == nil)
        #expect(await c.watchersPluginMissing == true)
    }

    @Test("Ein Serverfehler ist kein fehlendes Plugin")
    func serverError() async {
        Stub.status = 500
        Stub.body = Data()
        let c = await client()
        #expect(await c.watchers(itemID: "a") == nil)
        #expect(await c.watchersPluginMissing == false)
    }

    @Test("Emby fragt gar nicht erst")
    func embyNeverAsks() async {
        Stub.status = 200
        Stub.body = Data("[]".utf8)
        let c = await client(kind: .emby)
        #expect(await c.watchers(itemID: "a") == nil)
        #expect(Stub.paths.isEmpty)
    }
}
