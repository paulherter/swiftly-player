import Foundation
import Synchronization
import Testing

import JellyfinKit
@testable import SwiftlyCore

/// **Skip sections, trickplay and chapters: the old `JellyfinClient` calls (what `AppModel.sections` /
/// `trickplay` / `chapter` used) against `PlayExtras` (the core)** on the same server answers, compared on the
/// result and on the requests that went out (path and query). Answers: a full section list with every type and
/// an unknown one, no endpoint (404), a broken server (500); chapters with names, blanks, time-named ones and one
/// without a position, asked for the title, for a version that has chapters of its own, for one the server does not
/// know and for the title written in another case; trickplay for one source, for two and for a broken server.
@Suite(.serialized) struct PlayExtrasParityTests {
    /// What the "server" answers: status and body for a path and its `Fields`.
    static func answer(path: String, fields: String?) -> (Int, String) {
        func ticks(_ s: Double) -> Int64 { Int64(s * 10_000_000) }
        switch (path, fields) {
        case ("/MediaSegments/ep1", _):
            return (200, """
                {"Items":[
                 {"Type":"Intro","StartTicks":\(ticks(5)),"EndTicks":\(ticks(95.5))},
                 {"Type":"Recap","StartTicks":0,"EndTicks":\(ticks(4))},
                 {"Type":"Preview","StartTicks":\(ticks(2400)),"EndTicks":\(ticks(2450))},
                 {"Type":"Commercial","StartTicks":\(ticks(1200)),"EndTicks":\(ticks(1260))},
                 {"Type":"Outro","StartTicks":\(ticks(2500)),"EndTicks":\(ticks(2600))},
                 {"Type":"Banana","StartTicks":\(ticks(1)),"EndTicks":\(ticks(2))},
                 {"StartTicks":\(ticks(7)),"EndTicks":\(ticks(8))},
                 {"Type":"Intro","StartTicks":"wrong"}
                ]}
                """)
        case ("/MediaSegments/empty", _): return (200, #"{"Items":[]}"#)
        case ("/MediaSegments/err500", _): return (500, "{}")
        case ("/MediaSegments/none404", _): return (404, "{}")
        case ("/Items/ep1", "Chapters"), ("/Items/EP1", "Chapters"):
            return (200, """
                {"Id":"ep1","Chapters":[
                 {"Name":"Ghost"},
                 {"Name":"Opening","StartPositionTicks":0},
                 {"Name":"  Fight  ","StartPositionTicks":\(ticks(300))},
                 {"Name":"","StartPositionTicks":\(ticks(600))},
                 {"Name":"Chapter 4","StartPositionTicks":\(ticks(900))},
                 {"Name":"No position"},
                 {"Name":"End","StartPositionTicks":\(ticks(1500))}
                ]}
                """)
        case ("/Items/v2", "Chapters"):
            return (200, """
                {"Id":"v2","Chapters":[{"Name":"Cut A","StartPositionTicks":0},{"Name":"Cut B","StartPositionTicks":\(ticks(100))}]}
                """)
        case ("/Items/v3", "Chapters"): return (404, "{}")
        case ("/Items/ep1", "Trickplay"):
            return (200, """
                {"Id":"ep1","Trickplay":{"src1":{
                 "320":{"Width":320,"Height":180,"TileWidth":10,"TileHeight":10,"ThumbnailCount":356,"Interval":10000},
                 "160":{"Width":160,"Height":90,"TileWidth":10,"TileHeight":10,"ThumbnailCount":356,"Interval":10000}}}}
                """)
        case ("/Items/two", "Trickplay"):
            return (200, """
                {"Id":"two","Trickplay":{
                 "a":{"320":{"Width":320,"Height":180,"TileWidth":10,"TileHeight":10,"ThumbnailCount":10,"Interval":5000}},
                 "b":{"320":{"Width":320,"Height":176,"TileWidth":8,"TileHeight":8,"ThumbnailCount":20,"Interval":4000}}}}
                """)
        case ("/Items/none", "Trickplay"): return (200, #"{"Id":"none"}"#)
        case ("/Items/err500", _): return (500, "{}")
        default: return (404, "{}")
        }
    }

    // MARK: Old side

    final class OldServer: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var requests: [String] = []
        static let lock = NSLock()
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            let url = request.url!
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let fields = items.first { $0.name == "Fields" }?.value
            Self.lock.lock()
            Self.requests.append(Self.describe(path: url.path, items: items.map { ($0.name, $0.value ?? "") }))
            Self.lock.unlock()
            let (status, body) = PlayExtrasParityTests.answer(path: url.path, fields: fields)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
        static func describe(path: String, items: [(String, String)]) -> String {
            let query = items.filter { $0.0.lowercased() != "api_key" && $0.0.lowercased() != "apikey" }
                .map { "\($0.0)=\($0.1)" }.sorted().joined(separator: "&")
            return "\(path)?\(query)"
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
            let items = components?.queryItems ?? []
            let path = components?.path ?? ""
            requests.withLock {
                $0.append(OldServer.describe(path: path, items: items.map { ($0.name, $0.value ?? "") }))
            }
            let (status, body) = PlayExtrasParityTests.answer(path: path, fields: items.first { $0.name == "Fields" }?.value)
            return NetResponse(status: UInt16(status), headers: [NetHeader(name: "Content-Type", value: "application/json")],
                               body: Data(body.utf8), url: request.url)
        }
    }

    func newCore(_ http: NewServer) -> (Core, AccountRef) {
        (Core(platform: FakePlatform(), secrets: FakeSecrets(), store: MemoryKeyValue(), http: http),
         AccountRef(baseUrl: "http://srv.test", userId: "u1", token: "TOKEN", serverKind: .jellyfin,
                    deviceId: "test-device"))
    }

    // MARK: Scenarios

    @Test func sectionsAreTheSame() async throws {
        for id in ["ep1", "empty", "err500", "none404", "unknown"] {
            OldServer.requests = []
            let old = await oldClient().sections(for: id)
            let http = NewServer()
            let (core, account) = newCore(http)
            let new = await PlayExtras.sections(core: core, account: account, itemID: id, locale: "de")
            #expect(old == new, "\(id): old \(old) core \(new)")
            #expect(OldServer.requests == http.requests.withLock { $0 }, "\(id) requests")
        }
        // The full list really has the six known kinds and drops what it cannot read.
        let full = await oldClient().sections(for: "ep1")
        #expect(full.count >= 5)
    }

    @Test func chaptersAreTheSame() async throws {
        let cases: [(String, String?)] = [
            ("ep1", nil), ("ep1", "v2"), ("ep1", "v3"), ("ep1", "EP1"), ("ep1", "ep1"), ("nothing", nil),
        ]
        for (id, source) in cases {
            OldServer.requests = []
            let old = await oldClient().chapter(itemID: id, mediaSourceID: source)
            let http = NewServer()
            let (core, account) = newCore(http)
            let new = await PlayExtras.chapters(core: core, account: account, itemID: id, source: source, locale: "de")
            #expect(old == new, "\(id)/\(source ?? "-"): old \(old) core \(new)")
            #expect(OldServer.requests == http.requests.withLock { $0 }, "\(id)/\(source ?? "-") requests")
        }
    }

    @Test func trickplayIsTheSame() async throws {
        let cases: [(String, String?)] = [
            ("ep1", nil), ("ep1", "src1"), ("ep1", "SRC1"), ("ep1", "other"), ("two", "a"), ("two", "b"), ("two", nil),
            ("two", "c"), ("none", nil), ("err500", nil),
        ]
        for (id, source) in cases {
            OldServer.requests = []
            let old = await oldClient().trickplay(itemID: id, mediaSourceID: source)
            let http = NewServer()
            let (core, account) = newCore(http)
            let new = await PlayExtras.trickplay(core: core, account: account, itemID: id, source: source, locale: "de")
            #expect(old == new, "\(id)/\(source ?? "-"): old \(String(describing: old)) core \(String(describing: new))")
            #expect(OldServer.requests == http.requests.withLock { $0 }, "\(id)/\(source ?? "-") requests")
        }
    }
}
