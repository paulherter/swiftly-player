import Foundation
import Synchronization
import Testing

@testable import SwiftlyCore

/// Plain stand-ins for the host's stores.
final class MemoryKeyValue: KeyValueStore {
    let values = Mutex<[String: Data]>([:])
    func get(key: String) -> Data? { values.withLock { $0[key] } }
    func set(key: String, value: Data) { values.withLock { $0[key] = value } }
    func remove(key: String) { values.withLock { _ = $0.removeValue(forKey: key) } }
}

final class FakeSecrets: SecretStore {
    let values = Mutex<[String: String]>([:])
    func get(name: String) -> String? { values.withLock { $0[name] } }
    func set(name: String, value: String) { values.withLock { $0[name] = value } }
    func remove(name: String) { values.withLock { _ = $0.removeValue(forKey: name) } }
}

/// Loopback needs no local-network permission, so a refused connection must fail at once
/// (the app's configuration waits for connectivity).
func testHttp() -> URLSessionHttpClient {
    let configuration = URLSessionHttpClient.defaultConfiguration()
    configuration.waitsForConnectivity = false
    return URLSessionHttpClient(configuration: configuration)
}

func makeCore(
    platform: FakePlatform = FakePlatform(), store: any KeyValueStore = MemoryKeyValue()
) -> Core {
    Core(platform: platform, secrets: FakeSecrets(), store: store, http: testHttp())
}

func account(_ server: FixtureServer, token: String = "TOKEN-A") -> AccountRef {
    AccountRef(
        baseUrl: server.address, userId: "user-\(token.lowercased())", token: token,
        serverKind: .jellyfin, deviceId: "test-device")
}

/// Waits (event driven, no polling) until the status is `ready` with data from the server;
/// returns how long that took.
func untilReady(_ vm: HomeVm) async throws -> Duration {
    let clock = ContinuousClock()
    let start = clock.now
    var seen = vm.version()
    while true {
        let status = vm.status()
        if status.status == .ready && !status.preview { return clock.now - start }
        let change = try await vm.changed(seen: seen)
        seen = change.version
        if clock.now - start > .seconds(20) { throw CoreError.Failed(message: "timed out") }
    }
}

@MainActor
func eventuallyOnMain(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<500 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@Suite(.serialized) struct HomeModelTests {
    @Test @MainActor func coldLoadFillsTheRails() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        let vm = try makeCore().homeVm(account: account(server), locale: "de")
        let model = HomeModel(vm: vm)
        #expect(model.status.status == .loading)
        #expect(model.rails.rails.isEmpty)
        let observing = Task { @MainActor in await model.observe() }

        model.load()
        #expect(await eventuallyOnMain { model.status.status == .ready && !model.status.preview })

        #expect(model.rails.rails.map(\.title) == ["Weiterschauen", "Nächste Folge", "Zuletzt hinzugefügt"])
        let resume = try #require(model.rails.rails.first)
        #expect(resume.titleKey == "Weiterschauen")
        #expect(resume.ids == ["r1", "e1"])
        let movie = try #require(resume.tiles.first)
        #expect(movie.title == "Der Weg zurück")
        #expect(movie.subtitle == "2019")
        #expect(abs((movie.progress ?? 0) - 0.4) < 0.001)
        #expect(movie.image?.kind == .backdrop)
        #expect(movie.image?.address.hasPrefix("\(server.address)/Items/r1/Images/Backdrop") == true)
        #expect(resume.tiles[1].subtitle == "S1 · F3")
        #expect(model.rails.rails[1].ids == ["e2"])

        // What the server saw: the token only in the header, never in the address of a data call.
        let seen = server.seen
        #expect(seen.count >= 5)
        #expect(seen.allSatisfy { $0.authorization.contains("Token=\"TOKEN-A\"") })
        #expect(seen.allSatisfy { !$0.target.contains("TOKEN-A") })

        observing.cancel()
        await observing.value
    }

    @Test @MainActor func loadSettledReturnsWhenReadyAndCarriesTheFacts() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        let model = HomeModel(vm: try makeCore().homeVm(account: account(server), locale: "de"))
        var calls = 0
        await model.loadSettled { calls += 1 }
        #expect(model.status.status == .ready && !model.status.preview && !model.status.refreshing)
        #expect(calls >= 1)
        let episode = try #require(model.rails.rails.first?.tiles.first { $0.facts.kind == "Episode" })
        #expect(episode.facts.seriesId != nil)
        #expect(episode.facts.episodeNumber != nil)
        let movie = try #require(model.rails.rails.first?.tiles.first { $0.facts.kind == "Movie" })
        #expect(movie.facts.name == "Der Weg zurück")
        // A second load on a standing page settles again (refreshing goes true and back).
        await model.loadSettled()
        #expect(model.status.status == .ready && !model.status.refreshing)
    }

    @Test func cancellingTheObserverDropsTheRustFutureButNotTheLoad() async throws {
        let server = try await FixtureServer.start(hold: true)
        defer { server.stop() }
        let vm = try makeCore().homeVm(account: account(server), locale: "de")
        let observer = Task { try await vm.changed(seen: vm.version()) }
        #expect(await eventually { vm.waiters() == 1 })
        vm.send(intent: .load)
        #expect(await eventually { !server.seen.isEmpty })

        observer.cancel()
        await #expect(throws: CancellationError.self) { try await observer.value }
        #expect(await eventually { vm.waiters() == 0 })

        // The load belongs to the core: it finishes although nobody observes.
        server.release()
        #expect(await eventually { vm.status().status == .ready && !vm.status().preview })
        #expect(vm.rails().rails.count == 3)
    }

    @Test @MainActor func anAccountSwitchMidLoadShowsOnlyTheNewAccount() async throws {
        let server = try await FixtureServer.start(hold: true)
        defer { server.stop() }
        let vm = try makeCore().homeVm(account: account(server), locale: "de")
        let model = HomeModel(vm: vm)
        let observing = Task { @MainActor in await model.observe() }

        model.load()
        #expect(await eventuallyOnMain { !server.seen.isEmpty })
        model.switchAccount(account(server, token: "TOKEN-B"))
        #expect(vm.rails().rails.isEmpty, "empty at once")
        #expect(model.status.status == .loading)

        server.release()
        #expect(await eventuallyOnMain { model.status.status == .ready && !model.status.preview })
        #expect(model.rails.rails.map(\.title) == ["Weiterschauen", "Zuletzt hinzugefügt"])
        #expect(model.rails.rails.flatMap(\.tiles).map(\.title) == ["Zweiter Film", "Neues Konto"])

        model.switchAccount(nil)
        #expect(await eventuallyOnMain { model.status.status == .signedOut })
        #expect(model.rails.rails.isEmpty)
        observing.cancel()
        await observing.value
    }

    /// A fresh cache folder for one test.
    private func cacheFolder() -> String {
        let folder = URL.temporaryDirectory.appending(path: "core-cache-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.path
    }

    @Test func theStoredPreviewComesFirstAndOfflineKeepsIt() async throws {
        let folder = cacheFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let server = try await FixtureServer.start()
        let owner = account(server)
        let firstCore = makeCore(platform: FakePlatform(cache: folder))
        let first = try firstCore.homeVm(account: owner, locale: "de")
        first.send(intent: .load)
        _ = try await untilReady(first)
        let remembered = first.rails().rails.map(\.title)

        // The server is gone (its port is closed): the next launch, a second Core over the same folder,
        // shows the old page, then says offline.
        server.stop()
        try await Task.sleep(for: .milliseconds(100))
        let second = try makeCore(platform: FakePlatform(cache: folder)).homeVm(account: owner, locale: "de")
        second.send(intent: .load)
        #expect(await eventually { second.status().preview })
        #expect(second.rails().rails.map(\.title) == remembered)
        #expect(await eventually { second.status().status == .offline })
        #expect(second.rails().rails.map(\.title) == remembered)

        // Another account over the same folder sees nothing of it.
        let other = try makeCore(platform: FakePlatform(cache: folder))
            .homeVm(account: account(server, token: "TOKEN-B"), locale: "de")
        other.send(intent: .load)
        #expect(await eventually { other.status().status == .offline })
        #expect(!other.status().preview)
        #expect(other.rails().rails.isEmpty)
    }

    @Test func forgettingAnAccountWipesItsCachedPage() async throws {
        let folder = cacheFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let server = try await FixtureServer.start()
        let owner = account(server)
        let first = try makeCore(platform: FakePlatform(cache: folder)).homeVm(account: owner, locale: "de")
        first.send(intent: .load)
        _ = try await untilReady(first)
        server.stop()
        try await Task.sleep(for: .milliseconds(100))

        // Control: before the wipe a second Core over the folder shows the stored page.
        let core = makeCore(platform: FakePlatform(cache: folder))
        let before = try core.homeVm(account: owner, locale: "de")
        before.send(intent: .load)
        #expect(await eventually { before.status().preview })
        #expect(await eventually { before.status().status == .offline })

        core.cacheForget(account: owner)
        let after = try makeCore(platform: FakePlatform(cache: folder)).homeVm(account: owner, locale: "de")
        after.send(intent: .load)
        #expect(await eventually { after.status().status == .offline })
        #expect(!after.status().preview)
        #expect(after.rails().rails.isEmpty)
    }

    @Test func theCacheTakesEventsAndListChangesWithoutAFolder() throws {
        // No cache folder: everything stays in memory and the calls are harmless.
        let core = makeCore()
        let user = AccountRef(
            baseUrl: "http://127.0.0.1:1", userId: "u", token: "T", serverKind: .jellyfin, deviceId: "d")
        core.cacheEvent(account: user, message: #"{"MessageType":"LibraryChanged","Data":{}}"#)
        core.cacheListsChanged(account: user)
        core.cacheForget(account: user)
        #expect(core.cacheDiskBytes() == 0)
    }

    @Test func settingsAndSecretsCrossTheBoundary() async throws {
        let secrets = FakeSecrets()
        secrets.set(name: "token", value: "x")
        let core = Core(platform: FakePlatform(), secrets: secrets, store: MemoryKeyValue(), http: testHttp())
        #expect(core.hasSecret(name: "token"))
        #expect(!core.hasSecret(name: "other"))

        let defaults = try #require(UserDefaults(suiteName: "swiftly-core-tests"))
        defaults.removePersistentDomain(forName: "swiftly-core-tests")
        let store = UserDefaultsKeyValueStore(defaults: defaults)
        store.set(key: "a", value: Data([1, 2, 3]))
        #expect(store.get(key: "a") == Data([1, 2, 3]))
        store.remove(key: "a")
        #expect(store.get(key: "a") == nil)
        defaults.removePersistentDomain(forName: "swiftly-core-tests")
    }

    @Test func measureFirstLoadAndReadingTwoHundredTiles() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        let genres = (1...9).map { "Genre\($0)" }
        let prefs = HomePrefs(disconnected: false, genreChips: false, startGenres: genres)
        let vm = try makeCore().homeVmWith(account: account(server), locale: "de", prefs: prefs)
        vm.send(intent: .load)
        let firstLoad = try await untilReady(vm)
        let requests = server.seen.count

        let rails = vm.rails().rails
        for rail in rails { vm.send(intent: .visible(rail: rail.id)) }
        let all = vm.rails().rails
        let tiles = all.reduce(0) { $0 + $1.tiles.count }
        #expect(tiles >= 200)

        let clock = ContinuousClock()
        var best = Duration.seconds(1)
        var total = Duration.zero
        for _ in 0..<50 {
            let took = clock.measure { _ = vm.rails() }
            best = min(best, took)
            total += took
        }
        var window = Duration.seconds(1)
        for _ in 0..<50 {
            window = min(window, clock.measure { _ = vm.tiles(rail: "genre:Genre1", start: 0, count: 24) })
        }
        var version = Duration.seconds(1)
        for _ in 0..<200 { version = min(version, clock.measure { _ = vm.version() }) }
        print(
            "home first load (loopback, \(requests) requests, \(all.count) rails): \(firstLoad); "
                + "rails() with \(tiles) tiles: best \(best), mean \(total / 50); tiles(24): \(window); version(): \(version)"
        )
        #expect(firstLoad < .seconds(5))
        #expect(best < .milliseconds(50))
    }
}
