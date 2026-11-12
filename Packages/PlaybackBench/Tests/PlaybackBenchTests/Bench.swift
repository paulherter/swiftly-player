import Foundation
import SwiftlyCore

/// Waits (polling the main actor every 50 ms) until `condition` holds or `seconds` passed; returns how long it took, or nil.
@MainActor
func until(_ seconds: Double, _ condition: () -> Bool) async -> Double? {
    let started = Date()
    while Date().timeIntervalSince(started) < seconds {
        if condition() { return Date().timeIntervalSince(started) }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition() ? Date().timeIntervalSince(started) : nil
}

/// One line per checked cell, read back by `Werkzeuge/wiedergabe-pruefstand.sh` for the matrix table.
enum Record {
    static let lock = NSLock()
    static func note(_ cell: String, _ column: String, _ ok: Bool, _ detail: String = "") {
        let path = ProcessInfo.processInfo.environment["PBENCH_RESULTS"] ?? "/tmp/pbench-results.jsonl"
        let line = (try? JSONSerialization.data(withJSONObject: ["cell": cell, "column": column, "ok": ok, "detail": detail]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        lock.withLock {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile(); handle.write(Data((line + "\n").utf8)); try? handle.close()
            } else {
                try? Data((line + "\n").utf8).write(to: URL(filePath: path))
            }
        }
    }
}

extension Record {
    /// A gap that is the same in the shipping line: shown in the matrix, does not fail the gate.
    static func known(_ cell: String, _ column: String, _ detail: String) {
        note(cell, column, true, "KNOWN GAP (same as shipping): " + detail)
    }
}

/// A title opened the way the app does: the core's plan, then the core's player state machine driving the real engine.
@MainActor
final class Opened {
    let model: PlayerModel
    let port: BenchPort
    let ready: PlayReady
    let observing: Task<Void, Never>
    let core: Core
    let openedAt = Date()

    static func plan(_ id: String, flavour: PlayFlavour = .aether, since: Double? = nil, downloaded: PlayDownloaded? = nil,
                     core: Core = benchCore(), account: AccountRef = BenchServer.shared.account) async throws -> (PlayReady?, PlayPlanAnswer) {
        let answer = try await core.playPlan(account: account, locale: "de",
                                             request: benchRequest(id, flavour: flavour, since: since, downloaded: downloaded))
        if case .ready(let ready) = answer { return (ready, answer) }
        return (nil, answer)
    }

    init(id: String, flavour: PlayFlavour = .aether, since: Double? = nil, downloaded: PlayDownloaded? = nil,
         account: AccountRef = BenchServer.shared.account) async throws {
        core = benchCore()
        let (planned, answer) = try await Self.plan(id, flavour: flavour, since: since, downloaded: downloaded, core: core, account: account)
        guard let planned else { throw NSError(domain: "bench", code: 1, userInfo: [NSLocalizedDescriptionKey: "no plan: \(answer)"]) }
        ready = planned
        port = try BenchPort(start: planned.start)
        let driver = PlayerEngineDriver(port: port)
        let prefs = PlayerPrefs(backSeconds: 10, forwardSeconds: 30, autoSkip: false, nextAutomatic: false,
                                networkFavorable: false, directPlay: false, bitrateLimit: 120_000_000, convertAllowed: true)
        let vm = try core.playerVmKeyed(account: account, accountKey: "u1", locale: "de",
                                        start: planned.start, prefs: prefs, engine: driver)
        model = PlayerModel(vm: vm)
        driver.connect { [weak model] event in model?.engineEvent(event) }
        model.start()
        let observed = model
        observing = Task { @MainActor in await observed.observe() }
    }

    func close() {
        observing.cancel()
        model.send(.close)
        port.stop(resetDisplay: false)
    }

    var position: Double { model.transport.position }
    func playing(within seconds: Double) async -> Double? {
        await until(seconds) { port.state == .playing && port.firstFrame }
    }
    /// Position moves by at least `by` seconds over `over` seconds of wall time.
    func advances(by: Double = 0.8, over: Double = 3) async -> Bool {
        let before = port.position
        return await until(over + 3) { port.position - before >= by } != nil
    }
}
