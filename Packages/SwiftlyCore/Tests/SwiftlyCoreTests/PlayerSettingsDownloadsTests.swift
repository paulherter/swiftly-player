import Foundation
import Synchronization
import Testing

@testable import SwiftlyCore

/// A scripted engine: records the commands, answers the two that answer.
final class ScriptedPlayerEngine: PlayerEngine {
    let calls = Mutex<[String]>([])
    private func log(_ line: String) { calls.withLock { $0.append(line) } }
    var all: [String] { calls.withLock { $0 } }

    func load(request: PlayerLoad) { log("load \(request.url) start=\(request.start.map { "\($0)" } ?? "nil") buffer=\(request.bufferLevel) files=\(request.externalSubtitles.count)") }
    func play() { log("play") }
    func pause() { log("pause") }
    func seek(seconds: Double) { log("seek \(seconds)") }
    func setRate(tempo: Float) { log("rate \(tempo)") }
    func setVolume(percent: UInt8) { log("volume \(percent)") }
    func setAudioDelay(milliseconds: Int32) { log("audio-delay \(milliseconds)") }
    func setSubtitleDelay(milliseconds: Int32) { log("subtitle-delay \(milliseconds)") }
    func selectAudio(serverIndex: Int32) -> Bool { log("audio \(serverIndex)"); return true }
    func selectSubtitle(serverIndex: Int32) -> PlayerSubtitleRoute { log("subtitle \(serverIndex)"); return .cues }
    func setFill(on: Bool) { log("fill \(on)") }
    func place(rect: PlayerRect) { log("place") }
    func stop(resetDisplay: Bool) { log("stop \(resetDisplay)") }
    func pip(command: PlayerPip) { log("pip") }
}

func playerStart(next: Bool = false, buffer: PlayerBuffer = .normal) -> PlayerStart {
    PlayerStart(
        itemId: "ep1", title: "Pilot", playSessionId: "s1", mediaSourceId: "m1", method: .directPlay,
        url: "https://tv.example.test/v", headers: [],
        streams: [
            PlayerStream(
                index: 1, kind: "Audio", language: "eng", codec: "ac3", channels: 6, title: nil,
                isDefault: true, isForced: false, isExternal: false, isHearingImpaired: false),
            PlayerStream(
                index: 2, kind: "Audio", language: "deu", codec: "eac3", channels: 6, title: nil,
                isDefault: false, isForced: false, isExternal: false, isHearingImpaired: false),
        ],
        runtime: 3600, startAt: 0, audioIndex: 1, subtitleIndex: -1,
        next: next ? PlayerNext(id: "ep2", title: "Second") : nil, seriesId: "show",
        trackTitle: "acct|show", downloaded: false, softwareDecode: false, frameRateMatch: false, bufferLevel: buffer,
        subtitleFiles: [], externalTrackIdBase: 1000)
}

let playerPrefs = PlayerPrefs(
    backSeconds: 10, forwardSeconds: 10, autoSkip: false, nextAutomatic: true, networkFavorable: true,
    directPlay: true, bitrateLimit: 0, convertAllowed: true)

@Suite(.serialized) struct PlayerSettingsDownloadsTests {
    @Test @MainActor func playerDrivesTheEngineAndReportsToTheServer() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        let engine = ScriptedPlayerEngine()
        let vm = try makeCore().playerVm(
            account: account(server), locale: "de", start: playerStart(), prefs: playerPrefs, engine: engine)
        let model = PlayerModel(vm: vm)
        #expect(model.transport.phase == .loading)
        let observing = Task { @MainActor in await model.observe() }

        model.start()
        #expect(engine.all.contains { $0.hasPrefix("load https://tv.example.test/v") })
        model.engineEvent(.loadFinished(attempt: 1))
        model.engineEvent(.duration(seconds: 3600))
        model.engineEvent(.state(state: .playing))
        model.engineEvent(.firstFrame)
        model.engineEvent(.clock(position: 12, sourceTime: 12))
        #expect(await eventuallyOnMain { model.transport.phase == .playing && model.transport.pictureShown })
        #expect(model.transport.duration == 3600)
        // The first picture starts the session on the server.
        #expect(await eventually { server.seen.contains { $0.target.hasSuffix("/Sessions/Playing") } })
        #expect(model.tracks.audio.count == 2)

        model.send(.togglePlay)
        #expect(engine.all.contains("pause"))
        model.send(.audioDelay(milliseconds: 100))
        #expect(engine.all.contains("audio-delay 100"))
        #expect(await eventuallyOnMain { model.tracks.audioDelayMs == 100 })

        model.send(.close)
        #expect(model.takeEffects().contains(.close))
        #expect(await eventually { server.seen.contains { $0.target.hasSuffix("/Sessions/Playing/Stopped") } })
        #expect(server.seen.allSatisfy { !$0.target.contains("TOKEN-A") })

        observing.cancel()
        await observing.value
    }

    @Test @MainActor func aFailedLoadShowsTheRetryScreen() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        let engine = ScriptedPlayerEngine()
        let model = PlayerModel(
            vm: try makeCore().playerVm(
                account: account(server), locale: "de", start: playerStart(), prefs: playerPrefs, engine: engine))
        let observing = Task { @MainActor in await model.observe() }
        model.start()
        model.engineEvent(.loadFailed(attempt: 1, message: "boom", kind: nil))
        #expect(await eventuallyOnMain { model.transport.phase == .failed })
        #expect(model.transport.failure?.primary == "Erneut versuchen")
        model.send(.retry)
        #expect(engine.all.filter { $0.hasPrefix("load ") }.count == 2)
        observing.cancel()
        await observing.value
    }

    @Test @MainActor func settingsFlipASwitchAndRefuseWhatIsNotOffered() async throws {
        let store = MemoryKeyValue()
        let vm = makeCore(store: store).settingsVm(locale: "de", facts: settingsFacts())
        let model = SettingsModel(vm: vm)
        #expect(!model.sections.sections.isEmpty)
        let observing = Task { @MainActor in await model.observe() }

        let rows = model.sections.sections.flatMap(\.rows)
        let target = try #require(
            rows.first {
                if case .switch = $0.control { return $0.enabled }
                return false
            })
        guard case .switch(let before) = target.control else { return }
        try model.setSwitch(target.key, !before)
        #expect(
            await eventuallyOnMain {
                model.sections.sections.flatMap(\.rows).first { $0.key == target.key }
                    .map { if case .switch(let on) = $0.control { on != before } else { false } } ?? false
            })
        // The value reached the host's store and the host is told.
        #expect(store.get(key: "setting.\(target.key)") != nil)
        #expect(model.takeEffects().contains { if case .changed(let key, _) = $0 { key == target.key } else { false } })
        #expect(throws: CoreError.self) { try model.setSwitch("no.such.key", true) }

        observing.cancel()
        await observing.value
    }

    @Test @MainActor func settingsShareTheUserDefaultsKeysWithAppStorage() async throws {
        let suite = "swiftly.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsSettingsStore(defaults: defaults)
        let vm = makeCore().settingsVmNative(store: store, locale: "de", facts: settingsFacts())
        let model = SettingsModel(vm: vm)
        let target = try #require(
            model.sections.sections.flatMap(\.rows).first {
                if case .switch = $0.control { return $0.enabled }
                return false
            })
        guard case .switch(let before) = target.control else { return }
        try model.setSwitch(target.key, !before)
        store.flush()
        // The row key is the @AppStorage key itself, stored as a plain Bool.
        #expect(defaults.object(forKey: target.key) as? Bool == !before)
        // A value written by an @AppStorage view shows up after a reload.
        defaults.set(before, forKey: target.key)
        try model.reload()
        let row = model.sections.sections.flatMap(\.rows).first { $0.key == target.key }
        if case .switch(let on)? = row?.control { #expect(on == before) }
        // Types survive the round trip.
        store.set(key: "t.double", value: .double(value: 0.5))
        store.set(key: "t.int", value: .int(value: 30))
        store.set(key: "t.list", value: .list(value: ["a", "b"]))
        store.flush()
        #expect(store.get(key: "t.double") == .double(value: 0.5))
        #expect(store.get(key: "t.int") == .int(value: 30))
        #expect(store.get(key: "t.list") == .list(value: ["a", "b"]))
        #expect(defaults.integer(forKey: "t.int") == 30)
    }

    @Test @MainActor func playerTakesSectionsTrickplayGroupAndBufferLevel() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        let engine = ScriptedPlayerEngine()
        let vm = try makeCore().playerVm(
            account: account(server), locale: "de", start: playerStart(buffer: .veryBad), prefs: playerPrefs,
            engine: engine)
        let group = FakeGroup()
        vm.setSections(sections: [PlayerSection(kind: .intro, from: 5, until: 60)])
        vm.setTrickplay(trickplay: PlayerTrickplay(width: 320, height: 180, tilesWide: 10, tilesUp: 10, count: 100, interval: 10000))
        vm.setGroup(group: group)
        vm.start()
        vm.send(intent: .togglePlay)
        #expect(engine.all.contains { $0.contains("buffer=veryBad") })
        #expect(group.lines.withLock { $0 }.contains("toggle false") || group.lines.withLock { $0 }.contains("toggle true"))
        vm.setGroup(group: nil)
        vm.setSections(sections: [])
    }

    @Test @MainActor func downloadsRunThroughTheHostsTransfer() async throws {
        let host = FakeDownloadHost()
        let store = MemoryKeyValue()
        let vm = makeCore(store: store).downloadsVm(host: host, locale: "de", onlyOverWlan: false, nextAuto: false)
        let model = DownloadsModel(vm: vm)
        let observing = Task { @MainActor in await model.observe() }

        try model.send(.signIn(account: "u1", client: true))
        try model.send(.networkChanged(wlan: true, none: false))
        try model.send(
            .start(
                items: [
                    DownloadRequest(
                        id: "m1", account: "u1", episodeKind: false, title: "Film", series: nil, seriesId: nil,
                        season: nil, episode: nil, runtimeTicks: nil, container: "mkv", source: "src", bytes: 1000,
                        created: 1_700_000_000, image: nil, quality: nil, audioIndex: nil, audioLanguage: nil,
                        videoCodec: nil, replaces: nil)
                ], images: [], checkSpace: false))
        // The start waits for the free space; the host measures and answers.
        #expect(host.log.contains("space"))
        try model.send(.spaceChanged(bytes: 10_000_000_000))
        try model.send(.tick)
        #expect(host.log.contains { $0.hasPrefix("address m1") }, "host log: \(host.log)")
        #expect(await eventuallyOnMain { model.list.rows.count == 1 })

        let generation = host.generation("m1") ?? 0
        try model.send(.addressReady(id: "m1", generation: generation, address: "https://dl.example.test/m1"))
        #expect(host.log.contains { $0.hasPrefix("start m1") })
        try model.send(
            .transferFinished(id: "m1", generation: generation, file: host.file("m1") ?? "m1.mkv", worked: true, realSize: 1000))
        #expect(await eventuallyOnMain { model.list.rows.first?.state == .done })
        // The list file reached the host's store.
        #expect(store.get(key: "downloads.list") != nil)

        try model.send(.delete(ids: ["m1"]))
        #expect(await eventuallyOnMain { model.list.rows.isEmpty })

        observing.cancel()
        await observing.value
    }
}

func settingsFacts() -> SettingsFacts {
    SettingsFacts(
        platform: .phone, seerr: true, settingsSync: true, downloads: true, server: "", canConvert: true,
        watchersPlugin: false, landscapeLockPossible: true, seerrConnected: false, ownHeaders: 0,
        subtitleLookSummary: "", storedDownloads: 0, storedBytes: 0, accountNextAuto: nil)
}

final class FakeDownloadHost: DownloadHost {
    private let lines = Mutex<[String]>([])
    private let generations = Mutex<[String: Int64]>([:])
    private let files = Mutex<[String: String]>([:])
    var log: [String] { lines.withLock { $0 } }
    func generation(_ id: String) -> Int64? { generations.withLock { $0[id] } }
    func file(_ id: String) -> String? { files.withLock { $0[id] } }
    private func add(_ line: String) { lines.withLock { $0.append(line) } }

    func startTransfer(id: String, generation: Int64, file: String, address: String, resume: Data?) {
        files.withLock { $0[id] = file }
        add("start \(id) \(address)")
    }
    func cancelTransfer(id: String, taskGeneration: Int64?, newGeneration: Int64, wantResumeData: Bool) { add("cancel \(id)") }
    func resumeTransfer(id: String) { add("resume \(id)") }
    func runningTransfers() -> [RunningTransferInfo] { [] }
    func requestAddress(id: String, generation: Int64, source: String?, quality: String, audioIndex: Int64?) {
        generations.withLock { $0[id] = generation }
        add("address \(id)")
    }
    func deleteFile(kind: String, name: String) { add("delete \(kind) \(name)") }
    func fetchImage(name: String, url: String) { add("image \(name)") }
    func measureSpace() { add("space") }
    func fetchSubtitles(id: String, source: String?) { add("subtitles \(id)") }
    func fetchSections(id: String) { add("sections \(id)") }
    func lookupSuccessor(id: String, seriesId: String) { add("successor \(id) \(seriesId)") }
}

final class FakeGroup: PlayerGroupHook {
    let lines = Mutex<[String]>([])
    func toggle(running: Bool) { lines.withLock { $0.append("toggle \(running)") } }
    func jump(to: Double) { lines.withLock { $0.append("jump \(to)") } }
}
