import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import JellyfinKit

/// The sessions answer in the server's own shape: what the takeover flow and the views read from the same bytes.
@Suite("Sitzungen: Antwort des Servers", .serialized)
struct SessionAnswerTests {

    final class SessionsServer: URLProtocol, @unchecked Sendable {
        static let body = #"""
        [{"Id":"s1","UserId":"u1","DeviceId":"mac-1","DeviceName":"Mac","Client":"Swiftly Player",
          "LastActivityDate":"2026-11-14T10:00:00.1234567Z","SupportsRemoteControl":true,
          "NowPlayingItem":{"Id":"m1","Name":"Film","Type":"Movie"},
          "PlayState":{"PositionTicks":300000000,"IsPaused":false}}]
        """#

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            let reply = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                        headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: reply, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    @Test("Eine laufende Sitzung mit LastActivityDate wird gelesen, samt der rohen Bytes")
    func playingSessionDecodes() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionsServer.self]
        let c = JellyfinClient(baseURL: URL(string: "https://tv.example.de")!, deviceID: "iphone",
                               deviceName: "Prüfgerät", urlSession: URLSession(configuration: config))
        await c.setSession(Session(accessToken: "tok", userID: "u1", userName: "T",
                                   serverURL: URL(string: "https://tv.example.de")!))
        let answer = try await c.remoteSessionAnswer()
        #expect(answer.sessions.count == 1)
        #expect(answer.sessions.first?.running?.id == "m1")
        #expect(answer.sessions.first?.lastActivity != nil)
        #expect(answer.data == Data(SessionsServer.body.utf8))
        // A bare decoder cannot read the date: the old host's `try? JSONDecoder()` returned an empty list.
        #expect((try? JSONDecoder().decode([RemoteSession].self, from: answer.data)) == nil)
    }
}
