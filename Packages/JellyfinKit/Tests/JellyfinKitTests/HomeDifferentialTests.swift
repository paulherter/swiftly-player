import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import JellyfinKit

/// **The recorded-server differential for the home page.**
///
/// One recorded set of server answers (`crates/swiftly-library/tests/fixtures/home_diff`) is run
/// through the real `HomeLoader`; the rails (ids in order) are the golden the Rust core must
/// reproduce (`crates/swiftly-library/tests/home_differential.rs`). Record again with
/// `SWIFTLY_RECORD_GOLDEN=1 swift test --filter HomeDifferentialTests`.
@Suite("Startseite gegen aufgezeichnete Serverantworten", .serialized)
struct HomeDifferentialTests {

    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("crates/swiftly-library/tests")

    final class Server: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var mode = "ok"
        nonisolated(unsafe) static var files: [String: Data] = [:]
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }

        static func object(_ name: String) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: files[name]!)) as? [String: Any] ?? [:]
        }

        override func startLoading() {
            let url = request.url!
            let q = Dictionary(
                (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                    .map { ($0.name.lowercased(), $0.value ?? "") },
                uniquingKeysWith: { a, _ in a })
            var status = 200
            var body = Data(#"{"Items":[],"TotalRecordCount":0}"#.utf8)
            let path = url.path
            func items(_ name: String) -> [[String: Any]] { Self.object(name)["Items"] as? [[String: Any]] ?? [] }
            func wrap(_ list: [[String: Any]]) -> Data {
                try! JSONSerialization.data(withJSONObject: ["Items": list, "TotalRecordCount": list.count])
            }
            func limited(_ list: [[String: Any]]) -> [[String: Any]] {
                Array(list.prefix(Int(q["limit"] ?? "") ?? list.count))
            }
            if path.hasSuffix("/UserViews") {
                if Self.mode == "views_fail" { status = 500 } else { body = Self.files["views.json"]! }
            } else if path.hasSuffix("/UserItems/Resume") {
                body = wrap(limited(items("resume.json")))
            } else if path.hasSuffix("/Shows/NextUp") {
                body = wrap(limited(items("nextup.json")))
            } else if path.hasSuffix("/Ancestors") {
                let id = path.split(separator: "/").dropLast().last.map(String.init) ?? ""
                if Self.mode == "ancestors_fail" { status = 500 } else {
                    let list = Self.object("ancestors.json")[id] as? [[String: Any]] ?? []
                    body = try! JSONSerialization.data(withJSONObject: list)
                }
            } else if path.hasSuffix("/Items") {
                if let ids = q["ids"] {
                    if Self.mode == "ids_fail", q["fields"] == "ProviderIds" { status = 500 } else {
                        let want = Set(ids.split(separator: ",").map(String.init))
                        body = wrap(items("catalog.json").filter { want.contains($0["Id"] as! String) })
                    }
                } else if (q["sortby"] ?? "").contains("DateCreated"), q["parentid"] == nil {
                    body = wrap(limited(items("latest.json")))
                }
            }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func client() async -> JellyfinClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Server.self]
        let c = JellyfinClient(baseURL: URL(string: "https://tv.example.de")!,
                               deviceID: "dev", deviceName: "Test",
                               urlSession: URLSession(configuration: config))
        await c.setSession(Session(accessToken: "tok", userID: "u1", userName: "t",
                                   serverURL: URL(string: "https://tv.example.de")!))
        return c
    }

    @Test("Weiterschauen, Nächste Folge und Neu gleichen dem aufgezeichneten Stand")
    func rails() async throws {
        for name in ["views", "resume", "nextup", "latest", "catalog", "ancestors"] {
            Server.files[name + ".json"] = try Data(contentsOf: Self.root.appendingPathComponent("fixtures/home_diff/\(name).json"))
        }
        var result: [String: Any] = [:]
        for mode in ["ok", "ids_fail", "ancestors_fail", "views_fail"] {
            Server.mode = mode
            let c = await client()
            let home = await HomeLoader.load(from: c, .init(disconnected: false))
            result[mode] = [
                "continue": (home.continueWatching ?? []).map(\.id),
                "next": (home.nextEpisode ?? []).map(\.id),
                "recent": (home.recent ?? []).map(\.id),
                "disrupted": home.disrupted,
            ] as [String: Any]
        }
        let golden = Self.root.appendingPathComponent("golden/home_diff/swift_expected.json")
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        if ProcessInfo.processInfo.environment["SWIFTLY_RECORD_GOLDEN"] == "1" {
            try FileManager.default.createDirectory(at: golden.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: golden)
        } else {
            let want = try JSONSerialization.jsonObject(with: Data(contentsOf: golden)) as! NSDictionary
            #expect(want.isEqual(to: result))
        }
    }
}
