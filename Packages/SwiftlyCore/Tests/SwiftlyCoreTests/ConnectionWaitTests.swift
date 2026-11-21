import Foundation
import Testing

@testable import SwiftlyCore

/// The app's own configuration waits for connectivity (the local-network prompt). A server that is down
/// must still fail within the grace time, not after the 20 s resource timeout (once per core retry).
@Suite struct ConnectionWaitTests {
    /// A loopback port nothing listens on: the connection is refused.
    private func closedPort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    @Test func refusedConnectionFailsWithinTheGraceTime() async throws {
        let client = URLSessionHttpClient()  // the app's configuration: waitsForConnectivity = true
        let request = NetRequest(
            method: .get, url: "http://127.0.0.1:\(closedPort())/System/Info/Public", headers: [], body: nil, timeoutMs: nil)
        let started = ContinuousClock.now
        do {
            _ = try await client.send(request: request)
            Issue.record("a closed port answered")
        } catch let failure as HttpFailure {
            guard case let .Network(code) = failure else {
                Issue.record("expected a network failure, got \(failure)")
                return
            }
            // Not `.Cancelled`: that would end a load silently. Not `cannotConnectToHost`: the core retries that one,
            // and every retry would wait the grace again.
            #expect(code == Int32(URLError.notConnectedToInternet.rawValue))
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}
