import Foundation
import Testing
@testable import JellyfinKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// "Add another account": the new account signs in without taking the
/// trait away from the already signed-in client. Otherwise the cleanup
/// for the old account (leaving the group) would go out under the new one's name.
@Suite("Konto hinzufügen", .serialized)
struct AccountAddTests {

    final class FallbackServer: URLProtocol, @unchecked Sendable {
        struct Invocation: Sendable { let path: String; let header: String }
        nonisolated(unsafe) static var calls: [Invocation] = []
        static let barrier = NSLock()

        static func reset() { barrier.withLock { calls = [] } }
        static func header(_ path: String) -> [String] {
            barrier.withLock { calls.filter { $0.path == path }.map(\.header) }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }

        override func startLoading() {
            let path = String(request.url!.path.dropFirst())
            let header = request.value(forHTTPHeaderField: "Authorization") ?? ""
            Self.barrier.withLock { Self.calls.append(.init(path: path, header: header)) }
            let body: Data
            let status: Int
            if path == "Users/AuthenticateByName" {
                status = 200
                body = Data(#"{"AccessToken":"merkmal-b","ServerId":"s1","User":{"Id":"konto-b","Name":"B"}}"#.utf8)
            } else {
                status = 204
                body = Data()
            }
            let answer = HTTPURLResponse(url: request.url!, statusCode: status,
                                          httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: answer, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private static let server = URL(string: "https://tv.example.de")!

    private static func signedIn() -> JellyfinClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FallbackServer.self]
        return JellyfinClient(baseURL: server, deviceID: "dev-1", deviceName: "Prueflauf",
                              session: .init(accessToken: "merkmal-a", userID: "konto-a",
                                             userName: "A", serverURL: server),
                              urlSession: URLSession(configuration: config))
    }

    @Test func newAccountLetsOldClientState() async throws {
        FallbackServer.reset()
        let alt = Self.signedIn()
        let new = alt.withoutAccount()
        #expect(new !== alt)
        #expect(await new.currentSession() == nil)

        let s = try await new.authenticate(username: "b", password: "x")
        #expect(s.userID == "konto-b")
        #expect(await new.currentSession()?.accessToken == "merkmal-b")
        #expect(await alt.currentSession()?.accessToken == "merkmal-a")

        // Whatever still goes through the old client afterwards (leaving the
        // group) carries its trait.
        _ = await alt.sessionAppliesStill()
        let headers = FallbackServer.barrier.withLock { FallbackServer.calls }
            .filter { $0.path != "Users/AuthenticateByName" }.map(\.header)
        #expect(!headers.isEmpty)
        #expect(headers.allSatisfy { $0.contains("merkmal-a") })
    }

    @Test func sameDevicesIdAndServer() async throws {
        FallbackServer.reset()
        let new = Self.signedIn().withoutAccount()
        #expect(new.baseURL == Self.server)
        _ = try await new.authenticate(username: "b", password: "x")
        let header = FallbackServer.header("Users/AuthenticateByName").first ?? ""
        #expect(header.contains("DeviceId=\"dev-1\""))
        #expect(!header.contains("merkmal-a"))
    }
}
