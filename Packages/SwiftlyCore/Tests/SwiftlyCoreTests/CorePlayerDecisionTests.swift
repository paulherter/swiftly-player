import Foundation
import Testing

import JellyfinKit
@testable import SwiftlyCore

/// **Step 4: the core decides auto skip and the next episode** (the screens only show the offer ring / card and run
/// the switch the core asks for). Scripted with a fake engine whose clock the test drives; the core's own 250 ms tick
/// runs in real time, so each script takes a few seconds (button fill 8 s, card countdown 7 s).
@Suite(.serialized) struct CorePlayerDecisionTests {
    typealias Server = CorePlaybackReportTests.Server

    static let intro = PlayerSection(kind: .intro, from: 60, until: 90)
    static let credits = PlayerSection(kind: .credits, from: 3500, until: 3600)

    @MainActor struct Run {
        let model: PlayerModel
        let port: RecordingPort
        let reporter: PlayReporter
        let observing: Task<Void, Never>
        let core: Core
        var effects: [PlayerEffectOut] = []

        /// The engine plays: its clock advances in real time (4 reports per second) while the core ticks.
        mutating func play(from start: Double, seconds: Double) async {
            var position = start
            for _ in 0..<Int(seconds * 4) {
                port.emit?(.clock(position: position, sourceTime: position))
                position += 0.25
                effects += model.takeEffects()
                try? await Task.sleep(for: .milliseconds(250))
            }
            effects += model.takeEffects()
        }
        var seeks: [String] { port.calls.filter { $0.hasPrefix("seek") } }
        var switches: [PlayerEffectOut] { effects.filter { if case .startEpisode = $0 { true } else { false } } }
    }

    @MainActor func run(
        _ server: Server, itemId: String = "ep1", session: String = "s1", startAt: Double, autoSkip: Bool,
        next: Bool, sections: [PlayerSection], reuse existing: Run? = nil
    ) throws -> Run {
        let c = existing?.core ?? Core(platform: FakePlatform(), secrets: FakeSecrets(), store: MemoryKeyValue(), http: server)
        let reporter = try existing?.reporter ?? c.playReporter(
            account: CorePlaybackReportTests.account, locale: "de", accountKey: "u1")
        let port = RecordingPort()
        let driver = PlayerEngineDriver(port: port)
        var start = playerStart(next: next)
        start.itemId = itemId
        start.playSessionId = session
        start.startAt = startAt
        start.seriesId = nil
        start.trackTitle = nil
        var prefs = playerPrefs
        prefs.autoSkip = autoSkip
        prefs.nextAutomatic = true
        let vm = try c.playerVmShared(
            account: CorePlaybackReportTests.account, accountKey: "u1", locale: "de", start: start, prefs: prefs,
            engine: driver, reporter: reporter)
        let model = PlayerModel(vm: vm)
        driver.connect { model.engineEvent($0) }
        model.setSections(sections)
        model.start()
        let observing = Task { @MainActor in await model.observe() }
        return Run(model: model, port: port, reporter: reporter, observing: observing, core: c)
    }

    private func isButton(_ offer: PlayerOffer) -> Bool { if case .button = offer { true } else { false } }
    private func isCard(_ offer: PlayerOffer) -> Bool { if case .card = offer { true } else { false } }

    @Test @MainActor func autoSkipOnShowsTheOfferThenActsOnce() async throws {
        let server = Server()
        var r = try run(server, startAt: 62, autoSkip: true, next: false, sections: [Self.intro])
        defer { r.observing.cancel() }
        await r.play(from: 62, seconds: 3)
        #expect(isButton(r.model.offer), "the offer shows first: \(r.model.offer)")
        #expect(r.seeks.isEmpty, "it has not acted yet: \(r.seeks)")
        await r.play(from: 65, seconds: 12)
        #expect(r.seeks.count == 1, "it acts exactly once: \(r.seeks)")
        #expect(r.seeks.first.flatMap { Double($0.dropFirst(5)) }.map { $0 >= 89 } == true, "\(r.seeks)")
    }

    @Test @MainActor func dismissingTheOfferCancelsTheAutoSkip() async throws {
        let server = Server()
        var r = try run(server, startAt: 62, autoSkip: true, next: false, sections: [Self.intro])
        defer { r.observing.cancel() }
        await r.play(from: 62, seconds: 3)
        #expect(isButton(r.model.offer))
        r.model.send(.dismiss)
        await r.play(from: 65, seconds: 12)
        #expect(r.seeks.isEmpty, "a dismissed offer never acts: \(r.seeks)")
        #expect(r.switches.isEmpty)
    }

    @Test @MainActor func autoSkipOffNeverActs() async throws {
        let server = Server()
        var r = try run(server, startAt: 62, autoSkip: false, next: false, sections: [Self.intro])
        defer { r.observing.cancel() }
        await r.play(from: 62, seconds: 3)
        #expect(isButton(r.model.offer), "the button still shows: \(r.model.offer)")
        await r.play(from: 65, seconds: 14)
        #expect(r.seeks.isEmpty, "off means the user presses: \(r.seeks)")
    }

    @Test @MainActor func theNextEpisodeCardCountsDownThenSwitchesWithOneStopAndOneStart() async throws {
        let server = Server()
        var r = try run(server, startAt: 3510, autoSkip: false, next: true, sections: [Self.credits])
        defer { r.observing.cancel() }
        #expect(await eventually { server.count("/Sessions/Playing") >= 1 })
        await r.play(from: 3510, seconds: 3)
        #expect(isCard(r.model.offer), "the card counts down: \(r.model.offer)")
        #expect(r.switches.isEmpty, "not yet")
        await r.play(from: 3513, seconds: 8)
        #expect(r.switches.count == 1, "one switch call: \(r.effects)")
        if case let .startEpisode(id, fromCard, _)? = r.switches.first {
            #expect(id == "ep2" && fromCard)
        }
        // The screen now plans ep2 and the next backend plays it on the same queue.
        var second = try run(server, itemId: "ep2", session: "s2", startAt: 0, autoSkip: false, next: false,
                             sections: [], reuse: r)
        defer { second.observing.cancel() }
        await second.play(from: 0, seconds: 2)
        #expect(await eventually { server.rows.contains { $0.session == "s2" } }, "\(server.rows)")
        let paths = server.rows.map { "\($0.path.hasSuffix("Stopped") ? "stop" : $0.path == "/Sessions/Playing" ? "start" : "progress") \($0.session ?? "-")" }
        #expect(paths.filter { $0.hasPrefix("stop") } == ["stop s1"], "\(paths)")
        #expect(paths.filter { $0.hasPrefix("start") } == ["start s1", "start s2"], "\(paths)")
        #expect((paths.firstIndex(of: "stop s1") ?? 99) < (paths.firstIndex(of: "start s2") ?? -1), "\(paths)")
    }
}
