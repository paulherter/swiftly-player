import Foundation
import Synchronization
import Testing

@testable import SwiftlyCore

/// A Swift implementation of the foreign `Platform` trait.
final class FakePlatform: Platform {
    let lines = Mutex<[String]>([])

    func deviceName() -> String { "Test Mac" }
    func log(line: String) { lines.withLock { $0.append(line) } }
    let cache: String?
    init(cache: String? = nil) { self.cache = cache }
    func cacheDir() -> String? { cache }
}

/// A Swift implementation of the foreign `EngineProbe` trait. Events go back into Rust from
/// inside the call (`load`) and from other threads (`play`, `seek`, `pause`).
final class FakeEngine: EngineProbe {
    let probe = Mutex<PlayerProbe?>(nil)
    let calls = Mutex<[String]>([])

    private func send(_ event: EngineEvent) {
        probe.withLock { $0 }?.engineEvent(event: event)
    }

    func load(request: EngineLoad) {
        calls.withLock { $0.append("load \(request.url)") }
        send(.state(state: .loading))  // re-enters Rust while Rust is inside this call
    }

    func play() {
        calls.withLock { $0.append("play") }
        Task.detached { [self] in
            send(.state(state: .playing))
            send(.firstFrame)
        }
    }

    func pause() {
        calls.withLock { $0.append("pause") }
        Task.detached { [self] in send(.state(state: .paused)) }
    }

    func seek(seconds: Double) {
        calls.withLock { $0.append("seek \(seconds)") }
        Task.detached { [self] in
            send(.state(state: .seeking))
            send(.clock(position: seconds))
        }
    }

    func selectSubtitle(serverIndex: Int32) -> SubtitleRoute {
        calls.withLock { $0.append("subtitle \(serverIndex)") }
        return serverIndex == 3 ? .cues : .unsupported
    }
}

/// Polls until `condition` holds (a few seconds at most).
func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<500 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@Suite struct SwiftlyCoreTests {
    @Test func pingAwaitsTheRuntimeAndCallsBackIntoSwift() async throws {
        let platform = FakePlatform()
        let core = makeCore(platform: platform)
        let answer = try await core.ping(n: 7)
        #expect(answer == "pong 7 from Test Mac")
        #expect(platform.lines.withLock { $0 } == ["core: created", "core: ping 7"])

        // Latency of the whole round trip (Swift -> tokio sleep of 2 ms -> Swift -> Swift).
        let clock = ContinuousClock()
        var best = Duration.seconds(1)
        for n in 0..<50 {
            let took = try await clock.measure { _ = try await core.ping(n: UInt32(n)) }
            best = min(best, took)
        }
        print("ping round trip, best of 50: \(best)")
        #expect(best < .milliseconds(50))
    }

    @Test func changedReturnsAtOnceWhenNewerAndWaitsOtherwise() async throws {
        let core = makeCore(platform: FakePlatform())
        let vm = core.helloVm()
        #expect(vm.state() == HelloState(greeting: "Hello", count: 0))
        let first = try await vm.changed(seen: 0)  // newer than 0: returns at once
        #expect(first.version == vm.version())

        let waiting = Task { try await vm.changed(seen: first.version) }
        #expect(await eventually { vm.waiters() == 1 })
        vm.send(intent: .increment)
        let next = try await waiting.value
        #expect(next.version == first.version + 1)
        #expect(vm.state().count == 1)
        #expect(vm.waiters() == 0)

        vm.send(intent: .setGreeting(text: "Hallo"))
        vm.send(intent: .setGreeting(text: "Hallo"))  // same value: no new version
        #expect(vm.version() == next.version + 1)
    }

    @Test func cancellingTheTaskDropsTheRustFuture() async throws {
        let core = makeCore(platform: FakePlatform())
        let vm = core.helloVm()
        let waiting = Task { try await vm.changed(seen: vm.version()) }
        #expect(await eventually { vm.waiters() == 1 })
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(await eventually { vm.waiters() == 0 })

        // The view model still works afterwards.
        vm.send(intent: .increment)
        #expect(vm.state().count == 1)
    }

    @Test func manyObserversCancelledTogether() async throws {
        let core = makeCore(platform: FakePlatform())
        let vm = core.helloVm()
        let tasks = (0..<100).map { _ in Task { try await vm.changed(seen: vm.version()) } }
        #expect(await eventually { vm.waiters() == 100 })
        for task in tasks { task.cancel() }
        for task in tasks { _ = try? await task.value }
        #expect(await eventually { vm.waiters() == 0 })
    }

    @Test func engineProbeIsDrivenFromAsyncRustAndSendsEventsBack() async throws {
        let platform = FakePlatform()
        let core = makeCore(platform: platform)
        let engine = FakeEngine()
        let probe = core.playerProbe(engine: engine)
        engine.probe.withLock { $0 = probe }

        let report = try await probe.runScript()
        #expect(report.subtitleRoute == .cues)
        #expect(report.finalPosition == 30)
        #expect(report.seen.first == "State { state: Loading }")
        #expect(report.seen.contains("FirstFrame"))
        #expect(report.seen.last == "State { state: Paused }")
        let calls = engine.calls.withLock { $0 }
        #expect(calls == ["load https://example.invalid/film.mkv", "play", "seek 30.0", "subtitle 3", "pause"])
        #expect(platform.lines.withLock { $0.contains("probe: done") })

        // A second run is refused with a Swift error, not a trap.
        await #expect(throws: CoreError.self) { try await probe.runScript() }
    }

    @Test @MainActor func observableAdapterFollowsTheViewModelOnTheMainActor() async throws {
        let core = makeCore(platform: FakePlatform())
        let model = HelloModel(vm: core.helloVm())
        let observing = Task { @MainActor in await model.observe() }
        await Task.yield()
        model.send(.increment)
        model.send(.increment)
        for _ in 0..<500 where model.state.count != 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.state.count == 2)
        observing.cancel()
        await observing.value  // returns: the loop ended with the cancel
    }
}
