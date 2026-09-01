import Foundation
import Testing
@testable import JellyfinKit

/// Tests gegen den echten Server. Laufen nur, wenn SWIFTLY_LIVE_SERVER gesetzt
/// ist — damit die normale Testsuite offline bleibt.
@Suite("Live-Server", .enabled(if: ProcessInfo.processInfo.environment["SWIFTLY_LIVE_SERVER"] != nil))
struct LiveServerTests {

    private var serverURL: URL {
        URL(string: ProcessInfo.processInfo.environment["SWIFTLY_LIVE_SERVER"]!)!
    }

    private func makeClient() -> JellyfinClient {
        JellyfinClient(baseURL: serverURL, deviceID: "test-device", deviceName: "TestRunner")
    }

    @Test("Server antwortet und meldet seine Version")
    func publicInfo() async throws {
        let info = try await makeClient().publicSystemInfo()
        let version = try #require(info.version)
        #expect(version.hasPrefix("10."), "Unerwartete Serverversion: \(version)")
        #expect(info.serverName?.isEmpty == false)
        print("  → \(info.serverName ?? "?") · Jellyfin \(version)")
    }

    @Test("Ohne Token wird der Zugriff verweigert")
    func unauthenticatedIsRejected() async throws {
        await #expect(throws: JellyfinError.self) {
            _ = try await makeClient().userViews()
        }
    }
}

@Suite("URL-Normalisierung")
struct URLNormalizationTests {
    @Test("Ergänzt https und entfernt Schrägstriche", arguments: [
        ("tv.paulherter.de",            "https://tv.paulherter.de"),
        ("https://tv.paulherter.de/",   "https://tv.paulherter.de"),
        ("http://192.168.1.5:8096",     "http://192.168.1.5:8096"),
        ("  tv.paulherter.de  ",        "https://tv.paulherter.de"),
    ])
    func normalize(input: String, expected: String) {
        #expect(AppModelURLNormalizer.normalize(input)?.absoluteString == expected)
    }

    @Test("Weist Unsinn zurück")
    func rejectsGarbage() {
        #expect(AppModelURLNormalizer.normalize("") == nil)
        #expect(AppModelURLNormalizer.normalize("   ") == nil)
    }
}
