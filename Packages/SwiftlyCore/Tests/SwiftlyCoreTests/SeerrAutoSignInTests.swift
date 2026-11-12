import Foundation
import Testing

@testable import SwiftlyCore

/// The automatic Seerr sign-in: one outcome per situation, and the host's password is only asked when a
/// new sign-in is really needed.
@Suite(.serialized) struct SeerrAutoSignInTests {

    private final class Secret: SeerrPasswordSource, @unchecked Sendable {
        let value: String?
        private let lock = NSLock()
        private var asked = 0
        init(_ value: String?) { self.value = value }
        var timesAsked: Int { lock.withLock { asked } }
        func password() -> String? { lock.withLock { asked += 1 }; return value }
    }

    private static let stored = SeerrConnection(address: "http://seerr.test:5055", cookie: "connect.sid=abc", headers: [])

    private func run(me: UInt16, login: UInt16, secret: Secret) async throws -> (SeerrAutoState, ParityHttp) {
        let http = ParityHttp { r in
            if r.url.contains("/auth/me") { return (me, Data("{}".utf8)) }
            if r.url.contains("/auth/jellyfin") { return (login, Data(#"{"message":"no"}"#.utf8)) }
            return (404, Data())
        }
        let core = Core(platform: FakePlatform(), secrets: FakeSecrets(), store: MemoryKeyValue(), http: http)
        let state = try await core.seerrAutoSignIn(
            typed: Self.stored.address, user: "paul", stored: Self.stored, secret: secret, headers: [], jar: nil)
        return (state, http)
    }

    @Test func aValidSessionIsKeptAndThePasswordIsNotAsked() async throws {
        let secret = Secret("pw")
        let (state, http) = try await run(me: 200, login: 200, secret: secret)
        #expect(state == .signedIn(connection: Self.stored))
        #expect(secret.timesAsked == 0)
        #expect(!http.requests.contains { $0.url.contains("/auth/jellyfin") })
    }

    @Test func anExpiredSessionWithoutAPasswordAsksTheUser() async throws {
        let secret = Secret(nil)
        let (state, http) = try await run(me: 401, login: 200, secret: secret)
        #expect(state == .noPassword)
        #expect(!http.requests.contains { $0.url.contains("/auth/jellyfin") })
    }

    @Test func aRefusalIsReportedAndNotRetried() async throws {
        let secret = Secret("wrong")
        let (state, http) = try await run(me: 401, login: 401, secret: secret)
        guard case .rejected = state else { Issue.record("expected rejected, got \(state)"); return }
        #expect(secret.timesAsked == 1)
        #expect(http.requests.filter { $0.url.contains("/auth/jellyfin") }.count <= 2)
    }

    @Test func anUnreachableSeerrIsNotAnExpiredSession() async throws {
        let (state, _) = try await run(me: 502, login: 502, secret: Secret("pw"))
        #expect(state == .unreachable)
    }
}
