import Foundation
import Testing

@testable import SwiftlyCore

/// A `liste.json` as the Swift `DownloadManager` wrote it (German keys, dates as seconds since 2001, optionals
/// omitted) must be read by `DownloadsVm`, and what the core writes back must keep every other account's titles
/// and the same keys, so the older build still reads the list.
@Suite(.serialized) struct DownloadFixtureTests {
    private static let oldList = """
        [
         {"id":"f1","konto":"u1","art":"film","titel":"Film Eins","container":"mkv","quelle":"src1","bytes":850000000,
          "geladen":850000000,"stand":"fertig","gesehen":true,"nochAufDemServer":true,"angelegt":700000000,"bildcodec":"hevc","tonIndex":2,
          "abschnitte":[{"Type":"Intro","StartTicks":100000000,"EndTicks":700000000}],"stelleTicks":123000000},
         {"id":"e1","konto":"u1","art":"folge","titel":"Folge 1","serie":"Serie","serienId":"s1","staffel":1,"folge":1,
          "container":"mkv","bytes":1000000000,"geladen":1000000000,"stand":"fertig","gesehen":false,"nochAufDemServer":true,"angelegt":700000001},
         {"id":"e2","konto":"u1","art":"folge","titel":"Folge 2","serie":"Serie","serienId":"s1","staffel":1,"folge":2,
          "container":"mkv","bytes":1000000000,"geladen":400000000,"stand":"laedt","gesehen":false,"nochAufDemServer":true,"angelegt":700000002},
         {"id":"e3","konto":"u1","art":"folge","titel":"Folge 3","serie":"Serie","serienId":"s1","staffel":1,"folge":3,
          "container":"mkv","bytes":1000000000,"geladen":0,"stand":"fehler","grund":"Kein Platz","gesehen":false,"nochAufDemServer":true,"angelegt":700000003},
         {"id":"x1","konto":"other","art":"film","titel":"Fremdes Konto","container":"mp4","bytes":500,"geladen":500,
          "stand":"fertig","gesehen":false,"nochAufDemServer":true,"angelegt":700000004}
        ]
        """

    private func setup() throws -> (URL, UserDefaultsKeyValueStore, UserDefaults, String) {
        let name = "swiftly.downloads.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(Self.oldList.utf8).write(to: dir.appendingPathComponent("liste.json"))
        return (dir, UserDefaultsKeyValueStore(defaults: defaults, downloadsFolder: dir), defaults, name)
    }

    @Test @MainActor func oldListIsReadForOneAccountAndTheOthersSurvive() async throws {
        let (dir, store, defaults, name) = try setup()
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: dir)
        }
        let host = FakeDownloadHost()
        let vm = makeCore(store: store).downloadsVm(host: host, locale: "de", onlyOverWlan: true, nextAuto: false)
        let model = DownloadsModel(vm: vm)
        let observing = Task { @MainActor in await model.observe() }
        defer { observing.cancel() }
        try model.send(.signIn(account: "u1", client: true))
        try model.send(.networkChanged(wlan: true, none: false))
        #expect(await eventuallyOnMain { model.list.rows.count == 2 })

        // Only the signed-in account's titles; the film and the series group.
        #expect(model.list.rows.count == 2)
        #expect(model.list.rows.contains { $0.id == "f1" && $0.state == .done })
        #expect(!model.list.rows.contains { $0.id == "x1" })
        let series = try #require(model.list.rows.first { $0.id == "serie-s1" })
        #expect(series.items.map(\.id) == ["e1", "e2", "e3"])
        // What was loading last time waits again (nothing runs in this process), the failure keeps its reason.
        #expect(series.items[1].state != .loading || host.log.contains { $0.hasPrefix("address e2") })
        #expect(series.items[2].state == .failed)
        #expect(series.items[2].reason == "Kein Platz")

        // The whole items come back in the file's own format: German keys, nothing renamed.
        let items = try #require(JSONSerialization.jsonObject(with: vm.itemsJson()) as? [[String: Any]])
        #expect(items.count == 4)
        let film = try #require(items.first { $0["id"] as? String == "f1" })
        #expect(film["konto"] as? String == "u1")
        #expect(film["stand"] as? String == "fertig")
        #expect(film["gesehen"] as? Bool == true)
        #expect(film["bildcodec"] as? String == "hevc")
        #expect(film["tonIndex"] as? Int == 2)
        #expect(film["stelleTicks"] as? Int == 123_000_000)
        #expect((film["abschnitte"] as? [[String: Any]])?.count == 1)
        #expect(film["angelegt"] as? Double == 700_000_000)
        #expect(vm.fileFor(id: "f1") == "u1-f1.mkv")
        #expect(vm.fileFor(id: "e3") == nil)

        // A change rewrites the file: the other account's title and the keys stay.
        try model.send(.delete(ids: ["f1"]))
        store.flush()
        let written = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("liste.json"))) as? [[String: Any]])
        #expect(written.contains { $0["id"] as? String == "x1" && $0["konto"] as? String == "other" })
        #expect(!written.contains { $0["id"] as? String == "f1" })
        #expect(written.contains { $0["id"] as? String == "e1" && $0["serienId"] as? String == "s1" })
        #expect(host.log.contains("delete media u1-f1.mkv"), "host log: \(host.log)")
    }

    @Test @MainActor func playbackRememberedMarksWatchedWithoutNetwork() async throws {
        let (dir, store, defaults, name) = try setup()
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: dir)
        }
        let vm = makeCore(store: store).downloadsVm(host: FakeDownloadHost(), locale: "de", onlyOverWlan: true, nextAuto: false)
        let model = DownloadsModel(vm: vm)
        try model.send(.signIn(account: "u1", client: true))
        try model.send(.playbackRemembered(id: "e1", ticks: 5_000_000_000, now: 800_000_000))
        let items = try #require(JSONSerialization.jsonObject(with: vm.itemsJson()) as? [[String: Any]])
        #expect(items.count == 4, "ids: \(items.map { $0["id"] ?? "?" })")
        let episode = try #require(items.first { $0["id"] as? String == "e1" })
        #expect(episode["stelleTicks"] as? Int == 5_000_000_000)
    }

    /// The rules the old Swift manager kept, now the core's: Wi-Fi only holds a title back, a pause is not an
    /// error (the cancellation reported afterwards carries the old generation), free space is measured.
    @Test @MainActor func wifiOnlyPauseAndFreeSpaceBehaveLikeTheOldManager() async throws {
        let (dir, store, defaults, name) = try setup()
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: dir)
        }
        let host = FakeDownloadHost()
        let vm = makeCore(store: store).downloadsVm(host: host, locale: "de", onlyOverWlan: true, nextAuto: false)
        let model = DownloadsModel(vm: vm)
        try model.send(.signIn(account: "u1", client: true))
        // Mobile data with "only over Wi-Fi": the waiting title waits, nothing is asked of the server.
        try model.send(.networkChanged(wlan: false, none: false))
        #expect(!host.log.contains { $0.hasPrefix("address e2") }, "host log: \(host.log)")
        // Wi-Fi arrives: it starts (the address is asked first, the state is `loading` before the answer).
        try model.send(.networkChanged(wlan: true, none: false))
        #expect(host.log.contains { $0.hasPrefix("address e2") }, "host log: \(host.log)")
        let generation = try #require(host.generation("e2"))
        try model.send(.addressReady(id: "e2", generation: generation, address: "http://server/e2"))
        #expect(host.log.contains("start e2 http://server/e2"))
        // Pause: the running task is cancelled; the cancellation error that follows carries the old generation.
        try model.send(.pause(id: "e2"))
        #expect(host.log.contains("cancel e2"))
        try model.send(
            .transferFailed(id: "e2", generation: generation, file: "u1-e2.mkv", reason: "cancelled", resume: nil))
        let items = try #require(JSONSerialization.jsonObject(with: vm.itemsJson()) as? [[String: Any]])
        #expect(items.first { $0["id"] as? String == "e2" }?["stand"] as? String == "angehalten")
        // Free space: a title that fits, and one that does not (the reserve counts).
        try model.send(.spaceChanged(bytes: 10_000_000_000))
        #expect(model.inquiry(bytes: 1_000_000_000).suffices)
        #expect(!model.inquiry(bytes: 9_900_000_000).suffices)
    }

    @Test func taskDescriptionsOfTheOldManagerAreUnderstood() {
        let sep = "\u{1F}"
        // New form: id, generation, file. Old form without generation counts as generation 0.
        #expect(URLSessionDownloadHost.parts("e1\(sep)42\(sep)u1-e1.mkv") == .init(id: "e1", generation: 42, file: "u1-e1.mkv"))
        #expect(URLSessionDownloadHost.parts("e1\(sep)u1-e1.mkv") == .init(id: "e1", generation: 0, file: "u1-e1.mkv"))
        #expect(URLSessionDownloadHost.parts("") == nil)
        #expect(URLSessionDownloadHost.description(id: "e1", generation: 42, file: "f.mkv") == "e1\(sep)42\(sep)f.mkv")
    }
}
