import Foundation
import Synchronization
import Testing

@testable import SwiftlyCore

/// A link that cannot do WebSocket: the channel must give up at once.
final class UnsupportedLink: WebSocketLink {
    func connect(url: String) async throws { throw SocketFailure.NotSupported }
    func receive() async throws -> String? { throw SocketFailure.NotSupported }
    func send(text: String) async throws {}
    func close() {}
}

@Suite(.serialized) struct ControllerTests {
    @Test func theCorePlatformMakesItsCacheFolderOnDemand() throws {
        let base = URL.temporaryDirectory.appending(path: "core-platform-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let platform = CorePlatform(deviceName: "Test Mac", cachesBase: base)
        #expect(!FileManager.default.fileExists(atPath: base.path))
        let folder = try #require(platform.cacheDir())
        #expect(folder.hasSuffix("de.paulherter.swiftly/core"))
        #expect(FileManager.default.fileExists(atPath: folder))
        #expect(platform.deviceName() == "Test Mac")
    }

    @Test func theCookieJarReadsAndForgetsTheStorage() throws {
        let storage = HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: "controller-tests")
        let jar = HTTPCookieSeerrJar(storage: storage)
        let address = "http://127.0.0.1:5055"
        let cookie = try #require(
            HTTPCookie(properties: [
                .name: "connect.sid", .value: "abc", .domain: "127.0.0.1", .path: "/",
            ]))
        storage.setCookie(cookie)
        #expect(jar.sessionCookie(address: address) == "connect.sid=abc")
        jar.forget(address: address)
        #expect(jar.sessionCookie(address: address) == nil)
    }

    @Test @MainActor func theVisualAndSettingsFunctionsAnswer() {
        #expect(!moodNoiseTile().isEmpty)
        #expect(licensesForPlatform(json: Data("[]".utf8), platform: "ios").isEmpty)
        #expect(!SettingsSyncController.entries.isEmpty)
    }

    @Test @MainActor func signInSavesTheAccountAndSwitchAndRemoveFollow() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        let model = try makeCore().accountsModel(deviceId: "test-device", locale: "de")
        let controller = AccountsController(model: model)
        #expect(controller.accounts.isEmpty)
        #expect(controller.active == nil)

        let check = try await controller.checkServer(server.address, kind: .jellyfin)
        #expect(check.name == "Testserver")

        let signedIn = try await controller.signIn(
            address: server.address, kind: .jellyfin, user: "Anna", password: "pw")
        #expect(signedIn.account.token == "TOKEN-A")
        #expect(controller.accounts.map(\.userName) == ["Anna"])
        #expect(controller.active?.userId == "user-a")

        let key = try #require(controller.accounts.first?.key)
        #expect(controller.switchTo(key)?.userId == "user-a")
        #expect(controller.remove(key) == nil)
        #expect(controller.accounts.isEmpty)
    }

    @Test @MainActor func syncPlayRefreshReachesThePage() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        let host = ClosureSyncPlayHost(step: { _ in }, loadTitle: { _, _ in })
        let model = try makeCore().syncPlayModel(
            account: account(server), locale: "de", selfName: "Anna", host: host)
        let controller = SyncPlayController(model: model)
        let observing = Task { @MainActor in await controller.observe() }
        let before = controller.page.version
        controller.refresh()
        #expect(await eventuallyOnMain { controller.page.version > before })
        observing.cancel()
        _ = await observing.value
        #expect(await eventuallyOnMain { server.seen.contains { $0.target.contains("SyncPlay") } })
    }

    @Test @MainActor func aSeerrControllerKeepsItsAddressAndAnswersASearch() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        let connection = SeerrConnection(address: server.address, cookie: "connect.sid=abc", headers: [])
        let controller = SeerrController(model: makeCore().seerrModel(connection: connection, jar: nil))
        #expect(controller.address.hasPrefix(server.address))
        try await controller.search("Matrix")  // an answer that is no Seerr page is an empty list
        #expect(controller.hits.isEmpty)
    }

    @Test @MainActor func aPersonPageStartsWithTheCastEntry() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        let info = PersonInfo(id: "p1", name: "Anna Muster", role: "Hauptrolle", kind: "Actor", imageTag: nil)
        let model = try makeCore().personModel(account: account(server), locale: "de", person: info, origin: nil)
        let controller = PersonController(model: model)
        #expect(controller.page.name == "Anna Muster")
        controller.toggleBiography()
        #expect(controller.page.biographyExpanded)
    }

    @Test func theWebSocketLinkFailsCleanly() async throws {
        let link = URLSessionWebSocketLink()
        await #expect(throws: SocketFailure.self) { _ = try await link.receive() }
        await #expect(throws: SocketFailure.self) { try await link.connect(url: "ws://127.0.0.1:1/socket") }
        link.close()
    }

    @Test @MainActor func aChannelOnAPlatformWithoutWebSocketGivesUp() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        let remote = try RemoteController(core: makeCore(), account: account(server), link: UnsupportedLink())
        remote.start()
        var given = false
        for await event in remote.events {
            if case .givenUp = event {
                given = true
                break
            }
        }
        #expect(given)
        #expect(!remote.isConnected)
        remote.stop()
    }
}
