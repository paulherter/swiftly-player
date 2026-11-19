import Foundation
import Synchronization
import Testing

import JellyfinKit
@testable import SwiftlyCore

/// The system's language names, counting how often the core asks and how deep the main stack is when it does.
final class CountingNames: LanguageNames {
    let calls = Mutex(0)
    let deepest = Mutex(0)

    private func note() {
        let depth = Thread.callStackReturnAddresses.count
        calls.withLock { $0 += 1 }
        deepest.withLock { $0 = max($0, depth) }
    }

    func languageName(code: String, language: String) -> String? {
        note()
        return Locale(identifier: language).localizedString(forLanguageCode: code)
    }

    func knowsLanguage(code: String) -> Bool {
        note()
        return Locale(identifier: "en").localizedString(forLanguageCode: code) != nil
    }
}

/// **Soak: a film runs for a long time (the crash after ~30 minutes).** The engine reports its clock several times a
/// second for the whole film. Nothing in that path may grow: not the stack (the crash was a stack overflow on the main
/// thread: the driver's sink re-wrapped its closure on every event), and the language names (a system call per track
/// and language) are asked for when the track list or the interface language changes, not on every clock event.
@Suite(.serialized) struct PlayerClockSoakTests {
    typealias Server = CorePlaybackReportTests.Server

    /// A film with two audio tracks and `subtitles` subtitle tracks in as many different languages.
    static func filmStart(subtitles: Int) -> PlayerStart {
        var start = playerStart(next: false)
        let languages = ["deu", "eng", "fra", "spa", "ita", "por", "rus", "jpn", "kor", "zho", "nld", "pol", "tur", "swe", "dan"]
        start.streams += (0..<subtitles).map { i in
            PlayerStream(
                index: Int64(10 + i), kind: "Subtitle", language: languages[i % languages.count], codec: "subrip",
                channels: nil, title: nil, isDefault: false, isForced: i % 7 == 0, isExternal: false,
                isHearingImpaired: i % 5 == 0)
        }
        start.startAt = 0
        start.seriesId = nil
        start.trackTitle = nil
        return start
    }

    @Test @MainActor func aLongFilmsClockEventsDoNotGrowTheStackOrAskForNamesAgain() async throws {
        let server = Server()
        let core = Core(platform: FakePlatform(), secrets: FakeSecrets(), store: MemoryKeyValue(), http: server)
        let names = CountingNames()
        core.setLanguageNames(names: names)
        defer { core.setLanguageNames(names: nil) }
        let reporter = try core.playReporter(account: CorePlaybackReportTests.account, locale: "de", accountKey: "u1")
        let port = RecordingPort()
        let driver = PlayerEngineDriver(port: port)
        let vm = try core.playerVmShared(
            account: CorePlaybackReportTests.account, accountKey: "u1", locale: "de",
            start: Self.filmStart(subtitles: 40), prefs: playerPrefs, engine: driver, reporter: reporter)
        let model = PlayerModel(vm: vm)
        // The depth of the stack where the driver hands an event to the core: the same place the app's closure runs.
        var depthAtCore: [Int] = []
        var received = 0
        driver.connect { event in
            received += 1
            if received % 250 == 0 { depthAtCore.append(Thread.callStackReturnAddresses.count) }
            model.engineEvent(event)
        }
        model.start()
        let observing = Task { @MainActor in await model.observe() }
        defer { observing.cancel() }

        port.emit?(.tracks(audio: RecordingPort.audio, subtitles: RecordingPort.subtitles, activeAudio: 1, activeSubtitle: nil))
        port.emit?(.state(state: .playing))
        port.emit?(.firstFrame)
        _ = model.tracks  // the first look builds the labels once

        // Depth of the main stack as the clock event arrives (same path as the engine's: port -> driver -> model).
        let depthHere = Thread.callStackReturnAddresses.count
        var position = 0.0
        func runClock(_ events: Int) async {
            for i in 0..<events {
                port.emit?(.clock(position: position, sourceTime: position))
                position += 0.25
                if i % 1_000 == 0 { await Task.yield() }
            }
        }
        // The core labels the 40 tracks once while the screen settles (a bounded start-up cost); after that the
        // clock must never ask again.
        await runClock(1_000)
        // (The labelling runs on the observer's turn, which under load comes a little later: wait until it is quiet.)
        var afterSettling = -1
        for _ in 0..<50 where afterSettling != names.calls.withLock({ $0 }) {
            afterSettling = names.calls.withLock { $0 }
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(afterSettling <= 400, "labelling a 42-track film asked the system for names \(afterSettling) times")
        await runClock(20_000)
        let asked = names.calls.withLock { $0 } - afterSettling
        let deepest = names.deepest.withLock { $0 }
        // A handful at most (a late first look); growth per event would be thousands.
        #expect(asked <= 5, "20 000 clock events asked the system for names \(asked) times (the track list did not change)")
        #expect(deepest < depthHere + 120, "the stack grew to \(deepest) frames (started at \(depthHere))")
        let first = depthAtCore.first ?? 0
        #expect(first > 0 && (depthAtCore.max() ?? 0) <= first + 2,
                "the stack at the core grew from \(first) to \(depthAtCore.max() ?? 0) frames over 20 000 clock events")
    }
}
