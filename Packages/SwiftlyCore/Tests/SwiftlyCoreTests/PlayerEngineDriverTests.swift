import Foundation
import Testing

@testable import SwiftlyCore

/// A platform engine that records what the driver hands it and can report back like a real one.
@MainActor
final class RecordingPort: PlayerEnginePort {
    var calls: [String] = []
    var emit: (@MainActor (PlayerEngineEvent) -> Void)?
    var attempt: UInt32 = 0
    /// Answer a `load` like a working engine does.
    var answersLoads = true
    var failsLoads = false

    func attach(_ emit: @escaping @MainActor (PlayerEngineEvent) -> Void) { self.emit = emit }
    func load(_ request: PlayerLoad) {
        calls.append("load \(request.url)")
        attempt += 1
        let mine = attempt
        guard answersLoads else { return }
        if failsLoads {
            emit?(.loadFailed(attempt: mine, message: "boom", kind: nil))
            return
        }
        emit?(.loadFinished(attempt: mine))
        emit?(.duration(seconds: 3600))
        emit?(.tracks(audio: Self.audio, subtitles: Self.subtitles, activeAudio: 1, activeSubtitle: nil))
        emit?(.state(state: .playing))
        emit?(.firstFrame)
    }
    func play() { calls.append("play") }
    func pause() { calls.append("pause") }
    func seek(_ seconds: Double) { calls.append("seek \(seconds)") }
    func setRate(_ tempo: Float) { calls.append("rate \(tempo)") }
    func setVolume(_ percent: UInt8) { calls.append("volume \(percent)") }
    func setAudioDelay(milliseconds: Int32) { calls.append("audio-delay \(milliseconds)") }
    func setSubtitleDelay(milliseconds: Int32) { calls.append("subtitle-delay \(milliseconds)") }
    func selectAudio(_ serverIndex: Int32) { calls.append("audio \(serverIndex)") }
    func selectSubtitle(_ serverIndex: Int32) { calls.append("subtitle \(serverIndex)") }
    func setFill(_ on: Bool) { calls.append("fill \(on)") }
    func place(_ rect: PlayerRect) { calls.append("place") }
    func stop(resetDisplay: Bool) { calls.append("stop \(resetDisplay)") }
    func pip(_ command: PlayerPip) { calls.append("pip") }

    static let audio = [
        PlayerTrack(id: 1, codec: "ac3", language: "eng", name: "English", channels: 6, isDefault: true, isForced: false),
        PlayerTrack(id: 2, codec: "eac3", language: "deu", name: "Deutsch", channels: 6, isDefault: false, isForced: false),
    ]
    static let subtitles = [
        PlayerTrack(id: 5, codec: "subrip", language: "deu", name: "Deutsch", channels: 0, isDefault: false, isForced: false)
    ]
}

@Suite(.serialized) struct PlayerEngineDriverTests {
    @Test @MainActor func commandsFromAnyThreadArriveInOrderAndReturnAtOnce() async throws {
        let port = RecordingPort()
        let driver = PlayerEngineDriver(port: port)
        // The main actor is busy for the whole loop; a command that waited for it would never return.
        let done = Task.detached {
            for i in 0..<200 { driver.seek(seconds: Double(i)) }
            driver.pause()
            driver.setRate(tempo: 1.5)
            return true
        }
        #expect(await done.value)
        #expect(await eventuallyOnMain { port.calls.last == "rate 1.5" })
        let seeks = port.calls.filter { $0.hasPrefix("seek ") }
        #expect(seeks == (0..<200).map { "seek \(Double($0))" })
        #expect(port.calls.suffix(2) == ["pause", "rate 1.5"])
    }

    @Test @MainActor func answeringCommandsUseTheListsTheEngineReported() async throws {
        let port = RecordingPort()
        port.answersLoads = false
        let driver = PlayerEngineDriver(port: port)
        // Before any list: queued, optimistic (the engine checks).
        #expect(driver.selectAudio(serverIndex: 9))
        #expect(driver.selectSubtitle(serverIndex: 9) == .cues)

        driver.receive(.tracks(audio: RecordingPort.audio, subtitles: RecordingPort.subtitles, activeAudio: 1, activeSubtitle: nil))
        #expect(driver.selectAudio(serverIndex: 2))
        #expect(!driver.selectAudio(serverIndex: 9))
        #expect(driver.selectSubtitle(serverIndex: 5) == .cues)
        #expect(driver.selectSubtitle(serverIndex: 7) == .unsupported)
        #expect(driver.selectSubtitle(serverIndex: -1) == .cues)
        #expect(await eventuallyOnMain { port.calls.contains("subtitle -1") })
        // A refused track is not sent to the engine.
        #expect(!port.calls.contains("audio 9") || port.calls.firstIndex(of: "audio 9")! < port.calls.firstIndex(of: "audio 2")!)
        #expect(!port.calls.contains("subtitle 7"))

        // A new load forgets the lists.
        driver.load(request: loadRequest())
        #expect(driver.selectAudio(serverIndex: 9))
    }

    @Test @MainActor func everyLoadGetsAFreshEngineClockAtItsStartPosition() async throws {
        let port = RecordingPort()
        port.answersLoads = false
        let driver = PlayerEngineDriver(port: port)
        var clocks: [Double] = []
        driver.connect { event in
            if case .clock(let position, let source) = event, position == source { clocks.append(position) }
        }
        var first = loadRequest()
        first.start = 120
        driver.load(request: first)
        #expect(await eventuallyOnMain { clocks == [120] })
        // A retry or the next title: the old position must not survive.
        var next = loadRequest()
        next.start = nil
        driver.load(request: next)
        #expect(await eventuallyOnMain { clocks == [120, 0] })
        #expect(port.calls.filter { $0.hasPrefix("load") }.count == 2)
    }

    @Test @MainActor func aTitlePlaysThroughTheDriverAndReportsToTheServer() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        let port = RecordingPort()
        let driver = PlayerEngineDriver(port: port)
        let model = PlayerModel(
            vm: try makeCore().playerVm(
                account: account(server), locale: "de", start: playerStart(), prefs: playerPrefs, engine: driver))
        driver.connect { model.engineEvent($0) }
        let observing = Task { @MainActor in await model.observe() }

        model.start()
        #expect(await eventuallyOnMain { model.transport.phase == .playing && model.transport.pictureShown })
        #expect(model.transport.duration == 3600)
        #expect(model.tracks.audio.count == 2)
        #expect(port.calls.first == "load https://tv.example.test/v")
        #expect(await eventually { server.seen.contains { $0.target.hasSuffix("/Sessions/Playing") } })

        model.send(.togglePlay)
        #expect(await eventuallyOnMain { port.calls.contains("pause") })
        model.send(.close)
        #expect(model.takeEffects().contains(.close))
        #expect(await eventuallyOnMain { port.calls.contains { $0.hasPrefix("stop") } })
        #expect(await eventually { server.seen.contains { $0.target.hasSuffix("/Sessions/Playing/Stopped") } })

        observing.cancel()
        await observing.value
    }

    @Test @MainActor func aFailedLoadThroughTheDriverCanBeRetried() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        let port = RecordingPort()
        port.failsLoads = true
        let driver = PlayerEngineDriver(port: port)
        let model = PlayerModel(
            vm: try makeCore().playerVm(
                account: account(server), locale: "de", start: playerStart(), prefs: playerPrefs, engine: driver))
        driver.connect { model.engineEvent($0) }
        let observing = Task { @MainActor in await model.observe() }
        model.start()
        #expect(await eventuallyOnMain { model.transport.phase == .failed })
        #expect(model.transport.failure?.primary == "Erneut versuchen")
        port.failsLoads = false
        model.send(.retry)
        #expect(await eventuallyOnMain { model.transport.phase == .playing })
        #expect(port.calls.filter { $0.hasPrefix("load ") }.count == 2)
        observing.cancel()
        await observing.value
    }

    private func loadRequest() -> PlayerLoad {
        PlayerLoad(
            url: "https://tv.example.test/v", headers: [], start: nil, audioServerIndex: nil, subtitleServerIndex: -1,
            externalSubtitles: [], softwareDecode: false, bufferLevel: .normal, frameRateMatch: false)
    }
}
