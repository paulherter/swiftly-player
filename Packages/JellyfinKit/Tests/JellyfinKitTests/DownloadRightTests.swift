import Foundation
import Testing
// On Linux, URLSession is not in Foundation but in a separate
// module. That module does not exist on Apple platforms, so the
// import is conditional and has no effect there.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import JellyfinKit

// .serialized because the three client tests share the static state
// of the response stub; run in parallel they overwrite each other,
// and one then checks the other's right.
@Suite("Downloadrecht", .serialized)
struct DownloadRightTests {

    @Test("Drei Faelle: nichts gesagt, erlaubt, verboten")
    func fromServer() {
        #expect(DownloadPermission.fromServer(nil) == .unknown)
        #expect(DownloadPermission.fromServer(true) == .allowed)
        #expect(DownloadPermission.fromServer(false) == .forbidden)
    }

    /// **A network error must not take anything away.** Only an explicit
    /// `false` blocks.
    @Test("Unbekannt gilt als erlaubt")
    func unknownAllowed() {
        #expect(DownloadPermission.unknown.mayLoad)
        #expect(DownloadPermission.allowed.mayLoad)
        #expect(!DownloadPermission.forbidden.mayLoad)
    }

    @Test("Knopf nur mit Schalter und Recht")
    func offer() {
        #expect(DownloadPermission.offer(rights: .allowed, functionOn: true))
        #expect(DownloadPermission.offer(rights: .unknown, functionOn: true))
        #expect(!DownloadPermission.offer(rights: .forbidden, functionOn: true))
        // Without the switch the feature does not exist at all.
        #expect(!DownloadPermission.offer(rights: .allowed, functionOn: false))
        #expect(!DownloadPermission.offer(rights: .unknown, functionOn: false))
        #expect(!DownloadPermission.offer(rights: .forbidden, functionOn: false))
    }

    @Test("EnableContentDownloading aus /Users/{id}")
    func outResponse() throws {
        func read(_ json: String) throws -> AccountPreGift {
            try JSONDecoder().decode(AccountPreGift.self, from: Data(json.utf8))
        }
        let forbidden = try read(#"{"Id":"x","Policy":{"EnableContentDownloading":false}}"#)
        #expect(forbidden.downloadsAllowed == false)
        #expect(forbidden.downloadPermission == .forbidden)

        let allowed = try read(#"{"Id":"x","Policy":{"EnableContentDownloading":true}}"#)
        #expect(allowed.downloadPermission == .allowed)

        // Older server, no policy block: nothing said, so allowed.
        #expect(try read(#"{"Id":"x"}"#).downloadPermission == .unknown)

        // **Both blocks independent.** Losing Configuration must not
        // lose Policy, and vice versa.
        let onlyRight = try read(#"{"Id":"x","Policy":{"EnableContentDownloading":false}}"#)
        #expect(onlyRight.nextEpisodeAutomatic == nil)
        let onlySelection = try read(#"{"Id":"x","Configuration":{"EnableNextEpisodeAutoPlay":false}}"#)
        #expect(onlySelection.nextEpisodeAutomatic == false)
        #expect(onlySelection.downloadPermission == .unknown)
    }

    // MARK: - The latch in the address

    /// Answers every request with an account whose right is in
    /// ``Antwortstelle/recht``. No network, no server.
    final class ResponsePoint: URLProtocol, @unchecked Sendable {
        /// `"true"`, `"false"` or empty (no `Policy` block).
        nonisolated(unsafe) static var rights = ""

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }

        override func startLoading() {
            let policy = Self.rights.isEmpty ? ""
                : #","Policy":{"EnableContentDownloading":\#(Self.rights)}"#
            let body = Data(#"{"Id":"u1"\#(policy)}"#.utf8)
            let answer = HTTPURLResponse(url: request.url!, statusCode: 200,
                                          httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: answer, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func client(rights: String) -> JellyfinClient {
        ResponsePoint.rights = rights
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ResponsePoint.self]
        return JellyfinClient(baseURL: URL(string: "https://tv.example.de")!,
                              deviceID: "dev-42", deviceName: "Prueflauf",
                              session: .init(accessToken: "tok", userID: "u1",
                                             userName: "nutzer",
                                             serverURL: URL(string: "https://tv.example.de")!),
                              urlSession: URLSession(configuration: config))
    }

    /// **The latch, not the UI.** Without it every other path
    /// to the file would still get through, a resumed queue for example.
    @Test("Verboten: keine Adresse, sondern 403")
    func noAddressIfForbidden() async throws {
        let c = client(rights: "false")
        _ = await c.accountDefaults()
        #expect(await c.downloadPermission() == .forbidden)
        await #expect(throws: JellyfinError.http(status: 403, body: "EnableContentDownloading")) {
            _ = try await c.downloadURL(itemID: "abc", mediaSourceID: nil)
        }
    }

    @Test("Erlaubt und unbekannt geben eine Adresse")
    func addressIfAllowed() async throws {
        for (rights, expects) in [("true", DownloadPermission.allowed), ("", .unknown)] {
            let c = client(rights: rights)
            _ = await c.accountDefaults()
            #expect(await c.downloadPermission() == expects)
            let address = try await c.downloadURL(itemID: "abc", mediaSourceID: nil)
            #expect(address.absoluteString.contains("abc"))
        }
    }

    /// The right is tied to the account: after a switch, "nothing said"
    /// applies again, not the block of the previous account.
    @Test("Kontowechsel setzt das Recht zurueck")
    func accountSwitch() async throws {
        let c = client(rights: "false")
        _ = await c.accountDefaults()
        #expect(await c.downloadPermission() == .forbidden)
        await c.setSession(.init(accessToken: "tok2", userID: "u2", userName: "Zweit",
                                 serverURL: URL(string: "https://tv.example.de")!))
        #expect(await c.downloadPermission() == .unknown)
    }
}
