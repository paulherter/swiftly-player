import Foundation
import Synchronization
import Testing

import JellyfinKit
@testable import SwiftlyCore

/// **The core plays a Plex title (`PlayerVm` over a fake engine, over the app's `PlayReporter` on a Plex account)
/// against the old path (`PlexClient` timeline calls in the order the screen made them)**: start, pause, resume,
/// seek, the app's stop, an episode switch, and one start and one stop per playback. A difference is a core bug.
@Suite(.serialized) struct CorePlexPlaybackTests {
    typealias Row = PlexReportParityTests.Row

    final class Server: HttpClient {
        let rows = Mutex<[Row]>([])
        func send(request: NetRequest) async throws -> NetResponse {
            rows.withLock { $0.append(Row(url: URL(string: request.url))) }
            return NetResponse(status: 200, headers: [], body: Data(), url: request.url)
        }
        var timelines: [Row] { rows.withLock { $0 }.filter { $0.path.hasSuffix("timeline") } }
    }

    /// The Plex server of the old calls (its own copy: the other suite's rows must not mix in).
    final class OldServer: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var rows: [Row] = []
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            Self.rows.append(Row(url: request.url))
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    static let account = AccountRef(baseUrl: "https://plex.example.test", userId: "u1", token: "TOKEN",
                                    serverKind: .plex, deviceId: "client-1")

    @MainActor func play(_ core: Core, _ reporter: PlayReporter, itemId: String, startAt: Double)
        throws -> (model: PlayerModel, port: RecordingPort, driver: PlayerEngineDriver) {
        let port = RecordingPort()
        let driver = PlayerEngineDriver(port: port)
        var start = playerStart()
        start.itemId = itemId
        start.playSessionId = nil
        start.mediaSourceId = "m1"
        start.startAt = startAt
        start.runtime = 3600
        start.seriesId = nil
        start.trackTitle = nil
        let vm = try core.playerVmShared(
            account: Self.account, accountKey: "u1", locale: "de", start: start, prefs: playerPrefs, engine: driver,
            reporter: reporter)
        let model = PlayerModel(vm: vm)
        driver.connect { model.engineEvent($0) }
        model.start()
        return (model, port, driver)
    }

    func settle(_ seconds: Double = 0.7) async { try? await Task.sleep(for: .seconds(seconds)) }

    @Test @MainActor func aWholePlexPlaybackSendsWhatThePlexClientSent() async throws {
        // Old: the screen's calls through the Plex client.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OldServer.self]
        OldServer.rows = []
        let client = PlexClient(
            baseURL: URL(string: Self.account.baseUrl)!, token: "TOKEN",
            identity: PlexIdentity(clientID: "client-1", product: "Test", version: "1.0", platform: "iOS",
                                   device: "iPhone", deviceName: "Test"),
            urlSession: URLSession(configuration: configuration))
        let plan = try PlexReportParityTests.plan()
        try await client.reportStart(itemID: "10", plan: plan, ticks: JellyfinClient.ticks(fromSeconds: 12))
        try await client.reportProgress(itemID: "10", plan: plan, positionTicks: JellyfinClient.ticks(fromSeconds: 12), paused: true)
        try await client.reportProgress(itemID: "10", plan: plan, positionTicks: JellyfinClient.ticks(fromSeconds: 12), paused: false)
        try await client.reportProgress(itemID: "10", plan: plan, positionTicks: JellyfinClient.ticks(fromSeconds: 300), paused: false)
        try await client.reportStopped(itemID: "10", plan: plan, positionTicks: JellyfinClient.ticks(fromSeconds: 300))
        let old = OldServer.rows.filter { $0.path.hasSuffix("timeline") }

        let server = Server()
        let core = Core(platform: FakePlatform(), secrets: FakeSecrets(), store: MemoryKeyValue(), http: server)
        let reporter = try core.playReporter(account: Self.account, locale: "de", accountKey: "u1")
        let playback = try play(core, reporter, itemId: "10", startAt: 12)
        #expect(await eventually { server.timelines.count >= 1 })
        await settle()
        playback.model.send(.enginePause)
        playback.port.emit?(.state(state: .paused))
        await settle()
        playback.model.send(.enginePlay)
        playback.port.emit?(.state(state: .playing))
        await settle()
        playback.model.send(.engineSeek(seconds: 300))
        await settle()
        let report = PlayReportPlan(playSessionId: nil, mediaSourceId: "m1", method: .directPlay, runtimeMs: 3_600_000)
        let stop = try await reporter.stop(itemId: "10", plan: report, seconds: 300)
        // A second stop of the same playback (a screen that closes twice) is dropped.
        playback.model.send(.close)
        await settle()
        let second = try await reporter.stop(itemId: "10", plan: report, seconds: 301)
        #expect("\(stop)" == "sent" && "\(second)" == "discarded")

        let new = server.timelines
        // Same states, positions and length as the old calls (start, pause, resume, seek, stop).
        #expect(new.map(\.description) == old.map(\.description), "old \(old)\nnew \(new)")
    }

    @Test @MainActor func aPlexEpisodeSwitchStopsTheOldBeforeTheNewStart() async throws {
        let server = Server()
        let core = Core(platform: FakePlatform(), secrets: FakeSecrets(), store: MemoryKeyValue(), http: server)
        let reporter = try core.playReporter(account: Self.account, locale: "de", accountKey: "u1")
        let first = try play(core, reporter, itemId: "10", startAt: 12)
        #expect(await eventually { server.timelines.count >= 1 })
        let report = PlayReportPlan(playSessionId: nil, mediaSourceId: "m1", method: .directPlay, runtimeMs: 3_600_000)
        _ = try await reporter.stop(itemId: "10", plan: report, seconds: 1500)
        first.driver.finish()
        let second = try play(core, reporter, itemId: "11", startAt: 0)
        #expect(await eventually { server.timelines.contains { $0.query.contains("ratingKey=11") } })
        _ = try await reporter.stop(itemId: "11", plan: report, seconds: 30)
        _ = second
        let rows = server.timelines.map { r in
            (r.query.first { $0.hasPrefix("ratingKey=") } ?? "", r.query.first { $0.hasPrefix("state=") } ?? "")
        }
        let stops = rows.filter { $0.1 == "state=stopped" }.map(\.0)
        #expect(stops == ["ratingKey=10", "ratingKey=11"], "\(rows)")
        let stopOld = rows.firstIndex { $0 == ("ratingKey=10", "state=stopped") } ?? 99
        let startNew = rows.firstIndex { $0.0 == "ratingKey=11" } ?? -1
        #expect(stopOld < startNew, "\(rows)")
        // Nothing for the old title after its stop.
        #expect(!rows.dropFirst(stopOld + 1).contains { $0.0 == "ratingKey=10" }, "\(rows)")
    }
}

