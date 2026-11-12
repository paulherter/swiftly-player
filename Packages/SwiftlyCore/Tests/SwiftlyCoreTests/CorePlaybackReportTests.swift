import Foundation
import Synchronization
import Testing

import JellyfinKit
@testable import SwiftlyCore

/// **The core plays a title (`PlayerVm` over a fake engine, over the app's `PlayReporter` queue) against the old way
/// (the app's `reportStart/Progress/Stopped` calls, in the order the screens made them)**, compared on the requests
/// that reach the server: which, in which order, at which position and with which pause flag. Scripts: a whole
/// playback (first picture, pause, resume, seek, stop), a track change, an episode switch, a start that fails, a stop
/// the server does not get (plane). And the main risk of the switch: **exactly one start and one stop per playback**.
///
/// Periodic progress (every 10 s) is the state machine's own tick and is covered where the clock can be driven
/// (`swiftly-vm/tests/player_vm.rs`); here the scripts run in real time and use the reports that happen at once.
@Suite(.serialized) struct CorePlaybackReportTests {
    /// A server that takes everything; `refuseStop` makes the stop fail like a plane.
    final class Server: HttpClient {
        let requests = Mutex<[Row]>([])
        let refuseStop = Mutex(false)
        /// No network at all (a download played in flight mode).
        let refuseAll = Mutex(false)
        func send(request: NetRequest) async throws -> NetResponse {
            let path = URL(string: request.url)?.path ?? ""
            var object: [String: Any] = [:]
            if let body = request.body, let parsed = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                object = parsed
            }
            requests.withLock {
                $0.append(Row(
                    path: path, ticks: (object["PositionTicks"] as? NSNumber)?.int64Value,
                    paused: object["IsPaused"] as? Bool, item: object["ItemId"] as? String,
                    session: object["PlaySessionId"] as? String))
            }
            if refuseAll.withLock({ $0 }) { throw HttpFailure.Network(code: -1009) }
            if refuseStop.withLock({ $0 }) && path.hasSuffix("/Stopped") { throw HttpFailure.Network(code: -1009) }
            return NetResponse(status: 204, headers: [], body: Data(), url: request.url)
        }
        var rows: [Row] { requests.withLock { $0 }.filter { $0.path != "/Sessions/Capabilities/Full" } }
        func count(_ suffix: String) -> Int { rows.filter { $0.path.hasSuffix(suffix) }.count }
    }

    struct Row: Equatable, CustomStringConvertible {
        var path: String
        var ticks: Int64?
        var paused: Bool?
        var item: String?
        var session: String?
        var description: String { "\(path.replacingOccurrences(of: "/Sessions/Playing", with: "")) \(ticks.map { $0 / 10_000_000 } ?? -1)s paused=\(paused.map(String.init) ?? "-") \(item ?? "-")/\(session ?? "-")" }
        /// What the old calls of the screen would have sent for the same moment.
        static func old(_ path: String, _ seconds: Double, paused: Bool?, item: String = "ep1", session: String = "s1") -> Row {
            Row(path: "/Sessions/Playing" + path, ticks: Int64(seconds * 10_000_000), paused: paused, item: item, session: session)
        }
    }

    static let account = AccountRef(baseUrl: "http://srv.test", userId: "u1", token: "TOKEN", serverKind: .jellyfin,
                                    deviceId: "test-device")
    static let plan = PlayReportPlan(playSessionId: "s1", mediaSourceId: "m1", method: .directPlay, runtimeMs: nil)

    func core(_ server: Server, store: MemoryKeyValue = MemoryKeyValue()) -> Core {
        Core(platform: FakePlatform(), secrets: FakeSecrets(), store: store, http: server)
    }

    /// A playback by the core: the model, the fake engine and the app's queue.
    @MainActor struct Playback {
        let model: PlayerModel
        let port: RecordingPort
        let driver: PlayerEngineDriver
        let reporter: PlayReporter
    }

    @MainActor func play(_ core: Core, _ reporter: PlayReporter, itemId: String = "ep1", session: String = "s1",
                         startAt: Double = 12) throws -> Playback {
        let port = RecordingPort()
        let driver = PlayerEngineDriver(port: port)
        var start = playerStart()
        start.itemId = itemId
        start.playSessionId = session
        start.startAt = startAt
        start.seriesId = nil
        start.trackTitle = nil
        let vm = try core.playerVmShared(
            account: Self.account, accountKey: "u1", locale: "de", start: start, prefs: playerPrefs, engine: driver,
            reporter: reporter)
        let model = PlayerModel(vm: vm)
        driver.connect { model.engineEvent($0) }
        model.start()
        return Playback(model: model, port: port, driver: driver, reporter: reporter)
    }

    func settle(_ seconds: Double = 0.7) async { try? await Task.sleep(for: .seconds(seconds)) }

    // MARK: A whole playback

    @Test @MainActor func aWholePlaybackSendsWhatTheOldCallsSent() async throws {
        // Old: the screen's calls.
        let oldServer = Server()
        let oldReporter = try core(oldServer).playReporter(account: Self.account, locale: "de", accountKey: "u1")
        oldReporter.start(itemId: "ep1", plan: Self.plan, seconds: 12, audio: 1, subtitle: nil)
        _ = oldReporter.progress(itemId: "ep1", plan: Self.plan, seconds: 12, paused: true, audio: 1, subtitle: nil)
        _ = oldReporter.progress(itemId: "ep1", plan: Self.plan, seconds: 12, paused: false, audio: 1, subtitle: nil)
        _ = oldReporter.progress(itemId: "ep1", plan: Self.plan, seconds: 300, paused: false, audio: 1, subtitle: nil)
        _ = try await oldReporter.stop(itemId: "ep1", plan: Self.plan, seconds: 300)
        // The old queue coalesces waiting progress; wait for the real sequence of the wire to compare against.
        await settle(0.3)

        // New: the core plays, the app only stops.
        let server = Server()
        let c = core(server)
        let reporter = try c.playReporter(account: Self.account, locale: "de", accountKey: "u1")
        let playback = try play(c, reporter)
        #expect(await eventually { server.count("/Sessions/Playing") >= 1 })
        await settle()
        playback.model.send(.enginePause)
        playback.port.emit?(.state(state: .paused))
        await settle()
        playback.model.send(.enginePlay)
        playback.port.emit?(.state(state: .playing))
        await settle()
        playback.model.send(.engineSeek(seconds: 300))
        await settle()
        _ = try await reporter.stop(itemId: "ep1", plan: Self.plan, seconds: 300)

        let new = server.rows
        // Start at the first picture, then pause, resume and the seek at once, then the app's stop.
        #expect(new.map(\.path) == [
            "/Sessions/Playing", "/Sessions/Playing/Progress", "/Sessions/Playing/Progress",
            "/Sessions/Playing/Progress", "/Sessions/Playing/Stopped",
        ], "\(new)")
        #expect(new.map(\.paused) == [false, true, false, false, false] || new.map(\.paused) == [nil, true, false, false, nil], "\(new)")
        #expect(new.map(\.ticks) == [120_000_000, 120_000_000, 120_000_000, 3_000_000_000, 3_000_000_000], "\(new)")
        // The old way: the same sequence at the same positions (the old queue may fold waiting progress; this one is
        // read after everything went out, so compare the positions and flags it kept).
        let old = oldServer.rows
        #expect(old.first?.path == "/Sessions/Playing" && old.last?.path == "/Sessions/Playing/Stopped", "\(old)")
        #expect(old.last?.ticks == new.last?.ticks)
        #expect(old.first?.ticks == new.first?.ticks)
        #expect(old.map(\.session).allSatisfy { $0 == "s1" } && new.map(\.session).allSatisfy { $0 == "s1" })
        #expect(new.map(\.item).allSatisfy { $0 == "ep1" })
    }

    // MARK: One start and one stop

    @Test @MainActor func exactlyOneStartAndOneStopPerPlayback() async throws {
        let server = Server()
        let c = core(server)
        let reporter = try c.playReporter(account: Self.account, locale: "de", accountKey: "u1")
        let playback = try play(c, reporter)
        #expect(await eventually { server.count("/Sessions/Playing") >= 1 })

        // What the screen still calls while the core owns the title: `AppModel.reportStart/Progress` ask the route
        // first, so nothing goes out for them; the stop is the app's.
        for _ in 0..<3 {
            if ReportRoute.appSends(.start, coreOwns: true) {
                reporter.start(itemId: "ep1", plan: Self.plan, seconds: 12, audio: 1, subtitle: nil)
            }
            if ReportRoute.appSends(.progress, coreOwns: true) {
                _ = reporter.progress(itemId: "ep1", plan: Self.plan, seconds: 13, paused: false, audio: 1, subtitle: nil)
            }
        }
        await settle()
        // The screen's close: the app's awaited stop, then the facade stops the engine; the core must not add one.
        let first = try await reporter.stop(itemId: "ep1", plan: Self.plan, seconds: 40)
        playback.model.send(.close)
        await settle()
        // A second stop for the same playback (a screen that closes twice) is discarded by the shared lock.
        let second = try await reporter.stop(itemId: "ep1", plan: Self.plan, seconds: 41)

        #expect(server.count("/Sessions/Playing") == 1, "\(server.rows)")
        #expect(server.rows.filter { $0.path == "/Sessions/Playing" }.count == 1)
        #expect(server.count("/Stopped") == 1, "\(server.rows)")
        #expect(first == .sent && second == .discarded)
        // Nothing for this playback goes out after its stop.
        #expect(server.rows.last?.path.hasSuffix("/Stopped") == true, "\(server.rows)")
    }

    @Test func theRouteSendsOnlyWhatTheCoreDoesNot() {
        #expect(ReportRoute.appSends(.start, coreOwns: false) && ReportRoute.appSends(.progress, coreOwns: false))
        #expect(!ReportRoute.appSends(.start, coreOwns: true) && !ReportRoute.appSends(.progress, coreOwns: true))
        #expect(ReportRoute.appSends(.stop, coreOwns: true) && ReportRoute.appSends(.stop, coreOwns: false))
        #expect(ReportRoute.appSends(.background, coreOwns: true))
    }

    // MARK: Tracks, next episode, failures

    @Test @MainActor func aSliderReleaseSeeksLikeTheOldSeek() async throws {
        let server = Server()
        let c = core(server)
        let reporter = try c.playReporter(account: Self.account, locale: "de", accountKey: "u1")
        let playback = try play(c, reporter)
        #expect(await eventually { server.count("/Sessions/Playing") >= 1 })
        playback.model.send(.scrubStart)
        playback.model.send(.scrubMove(seconds: 200))
        playback.model.send(.scrubEnd(seconds: 300))
        #expect(await eventuallyOnMain { playback.port.calls.contains("seek 300.0") || playback.port.calls.contains("seek 300") })
        // Exactly one seek reached the engine, and the report carries the target like the old jump report.
        #expect(playback.port.calls.filter { $0 == "seek 300.0" }.count == 1, "\(playback.port.calls)")
        #expect(await eventually { server.rows.last?.ticks == 3_000_000_000 }, "\(server.rows)")
    }

    @Test @MainActor func aTrackChoiceReachesTheEngine() async throws {
        let server = Server()
        let c = core(server)
        let reporter = try c.playReporter(account: Self.account, locale: "de", accountKey: "u1")
        let playback = try play(c, reporter)
        #expect(await eventually { server.count("/Sessions/Playing") >= 1 })
        playback.model.send(.selectAudio(index: 2))
        playback.model.send(.selectSubtitle(index: -1))
        playback.model.send(.tempo(tempo: 1.5))
        playback.model.send(.volume(percent: 40))
        #expect(await eventuallyOnMain { playback.port.calls.contains("audio 2") && playback.port.calls.contains("rate 1.5") })
        #expect(playback.port.calls.contains("volume 40"))
    }

    @Test @MainActor func anEpisodeSwitchReportsTheOldEndBeforeTheNewStartOnOneQueue() async throws {
        let server = Server()
        let c = core(server)
        let reporter = try c.playReporter(account: Self.account, locale: "de", accountKey: "u1")
        let first = try play(c, reporter, itemId: "ep1", session: "s1", startAt: 12)
        #expect(await eventually { server.count("/Sessions/Playing") >= 1 })
        // The screen's switch: stop the old one (app), then the next title plays.
        let planA = Self.plan
        _ = try await reporter.stop(itemId: "ep1", plan: planA, seconds: 1500)
        first.driver.finish()
        let second = try play(c, reporter, itemId: "ep2", session: "s2", startAt: 0)
        #expect(await eventually { server.rows.contains { $0.item == "ep2" || $0.session == "s2" } })
        _ = try await reporter.stop(itemId: "ep2", plan: PlayReportPlan(playSessionId: "s2", mediaSourceId: "m1", method: .directPlay, runtimeMs: nil), seconds: 30)
        _ = second

        let paths = server.rows.map { "\($0.path.replacingOccurrences(of: "/Sessions/Playing", with: "").isEmpty ? "start" : $0.path.hasSuffix("Stopped") ? "stop" : "progress") \($0.session ?? "-")" }
        #expect(paths.filter { $0.hasPrefix("start") } == ["start s1", "start s2"], "\(paths)")
        #expect(paths.filter { $0.hasPrefix("stop") } == ["stop s1", "stop s2"], "\(paths)")
        // The old end comes before the new start.
        #expect((paths.firstIndex(of: "stop s1") ?? 99) < (paths.firstIndex(of: "start s2") ?? -1), "\(paths)")
        // Nothing is sent for the old session after its stop.
        let afterStop = paths.drop { $0 != "stop s1" }.dropFirst()
        #expect(!afterStop.contains { $0.hasSuffix("s1") }, "\(paths)")
    }

    @Test @MainActor func aStartThatFailsReportsNothingToTheServer() async throws {
        let server = Server()
        let c = core(server)
        let reporter = try c.playReporter(account: Self.account, locale: "de", accountKey: "u1")
        let port = RecordingPort()
        port.failsLoads = true
        let driver = PlayerEngineDriver(port: port)
        var start = playerStart()
        start.seriesId = nil
        start.trackTitle = nil
        let vm = try c.playerVmShared(
            account: Self.account, accountKey: "u1", locale: "de", start: start, prefs: playerPrefs, engine: driver,
            reporter: reporter)
        let model = PlayerModel(vm: vm)
        driver.connect { model.engineEvent($0) }
        model.start()
        #expect(await eventuallyOnMain { model.transport.phase == .failed || model.transport.error != nil || port.calls.contains { $0.hasPrefix("load") } })
        await settle(1.2)
        #expect(server.count("/Sessions/Playing") == 0, "\(server.rows)")
        #expect(server.count("/Stopped") == 0)
    }

    @Test @MainActor func aStopTheServerDoesNotGetIsKeptForTheNextConnection() async throws {
        // Old and new through the same app call, so the same words: the stop fails, the position is kept once for the
        // account, a retry goes out and the kept one is dropped.
        let store = MemoryKeyValue()
        let server = Server()
        server.refuseStop.withLock { $0 = true }
        let c = core(server, store: store)
        let reporter = try c.playReporter(account: Self.account, locale: "de", accountKey: "u1")
        let playback = try play(c, reporter)
        #expect(await eventually { server.count("/Sessions/Playing") >= 1 })
        let failed = try await reporter.stop(itemId: "ep1", plan: Self.plan, seconds: 900)
        let kept = try JSONDecoder().decode([PendingReport].self, from: #require(store.get(key: "pending.reports")))
        #expect(failed == .failed)
        #expect(kept.count == 1 && kept.first?.itemID == "ep1" && kept.first?.account == "u1" && kept.first?.ticks == 9_000_000_000)
        server.refuseStop.withLock { $0 = false }
        let retry = try await reporter.stop(itemId: "ep1", plan: Self.plan, seconds: 900)
        #expect(retry == .sent)
        let after = try JSONDecoder().decode([PendingReport].self, from: #require(store.get(key: "pending.reports")))
        #expect(after.isEmpty)
        _ = playback
    }

    @Test @MainActor func aDownloadedTitleInFlightModePlaysAndItsStopIsKept() async throws {
        // A file on the device: no session at the server, no network. The core plays it, its reports fail quietly,
        // and the app's stop is kept for the next connection, once, under the account (the offline rule).
        let store = MemoryKeyValue()
        let server = Server()
        server.refuseAll.withLock { $0 = true }
        let c = core(server, store: store)
        let reporter = try c.playReporter(account: Self.account, locale: "de", accountKey: "u1")
        let port = RecordingPort()
        let driver = PlayerEngineDriver(port: port)
        var start = playerStart()
        start.playSessionId = nil
        start.downloaded = true
        start.url = "file:///var/mobile/Downloads/ep1.mkv"
        start.seriesId = nil
        start.trackTitle = nil
        start.startAt = 12
        let vm = try c.playerVmShared(
            account: Self.account, accountKey: "u1", locale: "de", start: start, prefs: playerPrefs, engine: driver,
            reporter: reporter)
        let model = PlayerModel(vm: vm)
        driver.connect { model.engineEvent($0) }
        model.start()
        #expect(await eventually { server.count("/Sessions/Playing") >= 1 })
        #expect(port.calls.first == "load file:///var/mobile/Downloads/ep1.mkv")
        await settle(1.0)
        let plan = PlayReportPlan(playSessionId: nil, mediaSourceId: nil, method: .directPlay, runtimeMs: nil)
        let outcome = try await reporter.stop(itemId: "ep1", plan: plan, seconds: 777)
        let kept = try JSONDecoder().decode([PendingReport].self, from: #require(store.get(key: "pending.reports")))
        #expect(outcome == .failed)
        #expect(kept.count == 1 && kept.first?.itemID == "ep1" && kept.first?.ticks == 7_770_000_000)
    }
}
