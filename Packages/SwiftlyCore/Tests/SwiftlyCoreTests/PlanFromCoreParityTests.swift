import Foundation
import Synchronization
import Testing

import JellyfinKit
@testable import SwiftlyCore

/// **The plan of a title: the old `JellyfinClient.playbackPlan` (what `AppModel.plan` called) against
/// `PlanFromCore` (the core's `playPlanOnly`)** on the same server answers. Compared: the whole `PlaybackPlan`
/// (address, delivery, version, session, container, reasons and the decoded `MediaSource`), the requests that
/// went out (path, query and the profile in the body, key by key) and, when it fails, the sentence the user
/// reads (`readableError`). Answers: direct play, a direct and a converting version (the cheaper wins, a picked
/// one beats it), conversion only, no source, the refusals 401/403/404/500, a refusal with an `ErrorCode`, a
/// broken answer and a server that does not answer (timeout, no host).
@Suite(.serialized) struct PlanFromCoreParityTests {
    enum Reply {
        case body(String)
        case status(Int)
        case network(Int)
    }

    nonisolated(unsafe) static var reply: Reply = .status(404)

    // MARK: Old side

    final class OldServer: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var requests: [String] = []
        static let lock = NSLock()
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            let url = request.url!
            let body = Self.bodyOf(request)
            Self.lock.lock()
            Self.requests.append(Self.describe(method: request.httpMethod ?? "GET", path: url.path,
                                               items: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                                               body: body))
            Self.lock.unlock()
            switch PlanFromCoreParityTests.reply {
            case .network(let code):
                client?.urlProtocol(self, didFailWithError: URLError(URLError.Code(rawValue: code)))
            case .status(let status):
                respond(status, "{}")
            case .body(let text):
                respond(200, text)
            }
        }
        func respond(_ status: Int, _ text: String) {
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}

        static func bodyOf(_ request: URLRequest) -> Data {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            return data
        }

        static func describe(method: String, path: String, items: [(String, String)], body: Data) -> String {
            let query = items.filter { !["api_key", "apikey"].contains($0.0.lowercased()) }
                .map { "\($0.0)=\($0.1)" }.sorted().joined(separator: "&")
            var text = body.isEmpty ? "" : String(decoding: body, as: UTF8.self)
            if let object = try? JSONSerialization.jsonObject(with: body),
               let sorted = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
                text = String(decoding: sorted, as: UTF8.self)
            }
            return "\(method) \(path)?\(query) \(text)"
        }
    }

    func oldClient() -> JellyfinClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OldServer.self]
        return JellyfinClient(
            baseURL: URL(string: "http://srv.test")!, deviceID: "test-device", deviceName: "Test",
            session: Session(accessToken: "TOKEN", userID: "u1", userName: "", serverURL: URL(string: "http://srv.test")!),
            urlSession: URLSession(configuration: configuration))
    }

    // MARK: New side

    final class NewServer: HttpClient {
        let requests = Mutex<[String]>([])
        func send(request: NetRequest) async throws -> NetResponse {
            let components = URLComponents(string: request.url)
            requests.withLock {
                $0.append(OldServer.describe(
                    method: request.method == .post ? "POST" : "GET", path: components?.path ?? "",
                    items: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                    body: request.body ?? Data()))
            }
            switch PlanFromCoreParityTests.reply {
            case .network(let code): throw HttpFailure.Network(code: Int32(code))
            case .status(let status):
                return NetResponse(status: UInt16(status), headers: [], body: Data("{}".utf8), url: request.url)
            case .body(let text):
                return NetResponse(status: 200, headers: [NetHeader(name: "Content-Type", value: "application/json")],
                                   body: Data(text.utf8), url: request.url)
            }
        }
    }

    // MARK: Scenarios

    static func direct(_ id: String = "m1") -> String { PlayPlanParityTests.source(id, direct: true) }

    func compare(_ name: String, _ reply: Reply, sourceID: String? = nil) async throws {
        Self.reply = reply
        OldServer.requests = []
        let bitrate = 120_000_000
        let client = oldClient()
        var oldPlan: PlaybackPlan?
        var oldText: String?
        do {
            oldPlan = try await client.playbackPlan(for: "m1", profile: .vlc(maxBitrate: bitrate), mediaSourceID: sourceID)
        } catch {
            oldText = readableError(error)
        }

        let http = NewServer()
        let core = Core(platform: FakePlatform(), secrets: FakeSecrets(), store: MemoryKeyValue(), http: http)
        let account = AccountRef(baseUrl: "http://srv.test", userId: "u1", token: "TOKEN", serverKind: .jellyfin,
                                 deviceId: "test-device")
        let outcome = await PlanFromCore.plan(core: core, account: account, itemID: "m1", sourceID: sourceID,
                                              maxBitrate: bitrate, locale: "de")
        switch outcome {
        case .plan(let plan):
            #expect(oldPlan == plan, "\(name): old \(String(describing: oldPlan)) core \(plan)")
        case .noSource:
            #expect(oldPlan == nil && oldText == nil, "\(name): core says no source, old \(String(describing: oldPlan)) \(oldText ?? "")")
        case .failed(let error):
            #expect(oldText == readableError(error), "\(name): old '\(oldText ?? "-")' core '\(readableError(error))'")
        }
        #expect(OldServer.requests == http.requests.withLock { $0 }, "\(name) requests")
    }

    @Test func theSameAnswerGivesTheSamePlan() async throws {
        try await compare("direct play", .body(PlayPlanParityTests.info([Self.direct()])))
        try await compare("direct + converting, cheaper wins",
                          .body(PlayPlanParityTests.info([PlayPlanParityTests.source("a", direct: false, transcodingUrl: "/videos/m1/main.m3u8?x=1"), PlayPlanParityTests.source("b", direct: true)])))
        try await compare("picked beats cheaper",
                          .body(PlayPlanParityTests.info([PlayPlanParityTests.source("a", direct: false, transcodingUrl: "/videos/m1/main.m3u8?x=1"), PlayPlanParityTests.source("b", direct: true)])),
                          sourceID: "a")
        try await compare("unknown picked falls back", .body(PlayPlanParityTests.info([PlayPlanParityTests.source("a", direct: true), PlayPlanParityTests.source("b", direct: true)])),
                          sourceID: "zzz")
        try await compare("conversion only", .body(PlayPlanParityTests.info([PlayPlanParityTests.source("a", direct: false, transcodingUrl: "/videos/m1/main.m3u8?x=1")])))
        try await compare("another session id", .body(PlayPlanParityTests.info([Self.direct()], session: "ps-9")))
    }

    @Test func noSourceAndFailuresReadTheSame() async throws {
        try await compare("no source", .body(#"{"MediaSources":[],"PlaySessionId":"ps-1"}"#))
        try await compare("rejected", .body(#"{"ErrorCode":"NotAllowed"}"#))
        try await compare("rate limit", .body(#"{"ErrorCode":"RateLimitExceeded"}"#))
        try await compare("other refusal", .body(#"{"ErrorCode":"NoCompatibleStream"}"#))
        for status in [401, 403, 404, 500, 503, 418] { try await compare("status \(status)", .status(status)) }
        try await compare("broken answer", .body("<html>nope</html>"))
        for code in [-1001, -1003, -1004, -1005, -1009] { try await compare("network \(code)", .network(code)) }
    }
}
