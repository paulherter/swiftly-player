import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import JellyfinKit

/// **What the filmography orders from the server.**
///
/// The request is checked, not the response: the three decisions that
/// sit in the parameters and are easy to miss when rebuilding on another
/// platform: sort order, kind restriction, person ID.
@Suite("Filmografie einer Person", .serialized)
struct PeopleTests {

    /// Intercepts the request and answers with a fixed list.
    final class Spy: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var captured: URLRequest?
        /// What comes back. Two entries carry the same ID, which is what
        /// the duplicate check hangs on.
        nonisolated(unsafe) static var body = Data("""
        {"Items":[{"Id":"a","Name":"Erster","Type":"Movie"},
                  {"Id":"b","Name":"Zweiter","Type":"Series"},
                  {"Id":"a","Name":"Erster","Type":"Movie"}],
         "TotalRecordCount":3}
        """.utf8)

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }

        override func startLoading() {
            Self.captured = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func spyClient() async -> JellyfinClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Spy.self]
        let c = JellyfinClient(baseURL: URL(string: "https://tv.example.de")!,
                               deviceID: "dev-42", deviceName: "Prüfgerät",
                               urlSession: URLSession(configuration: config))
        await c.setSession(Session(accessToken: "tok", userID: "u1",
                                   userName: "Testnutzer",
                                   serverURL: URL(string: "https://tv.example.de")!))
        return c
    }

    private func query() throws -> [String: String] {
        let url = try #require(Spy.captured?.url)
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return Dictionary(uniqueKeysWithValues:
            (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    @Test("Fragt nach Jahr absteigend, mit SortName als zweitem Schlüssel")
    func sorting() async throws {
        _ = await (await spyClient()).title(person: "p1")
        let q = try query()
        // A filmography is read from the back.
        #expect(q["SortOrder"] == "Descending")
        // Without the second key the server decides among titles of the
        // same year, and the list looks different between two fetches.
        #expect(q["SortBy"] == "ProductionYear,SortName")
    }

    /// Without a kind restriction the individual episodes would come too, each with
    /// its series' poster, so the same image many times side by side.
    /// Same reasoning as for search.
    @Test("Holt nur Filme und Serien, keine Folgen")
    func onlyFilmAndSeries() async throws {
        _ = await (await spyClient()).title(person: "p1")
        let types = try query()["IncludeItemTypes"] ?? ""
        #expect(types.contains("Movie"))
        #expect(types.contains("Series"))
        #expect(!types.contains("Episode"))
    }

    @Test("Gibt die Personenkennung mit und sucht rekursiv")
    func personAndRecursive() async throws {
        _ = await (await spyClient()).title(person: "p42")
        let q = try query()
        #expect(q["PersonIds"] == "p42" || q["personIds"] == "p42",
                "Personenkennung fehlt in der Abfrage: \(q)")
        // Without `Recursive` Jellyfin only searches the top level.
        #expect((q["Recursive"] ?? "").lowercased() == "true")
    }

    /// The server can return the same title twice. On Apple that makes
    /// `ForEach` fall over; on GTK the tile would appear twice in the grid.
    @Test("Doppelte Kennungen fallen weg")
    func withoutDouble() async throws {
        let title = await (await spyClient()).title(person: "p1")
        #expect(title?.map(\.id) == ["a", "b"])
    }

    /// **The difference that matters.** A silent server gives `nil`,
    /// not `[]`; otherwise the person page shows "Nothing here from ...",
    /// although it never received an answer.
    @Test("Ein stummer Server ergibt nil, keine leere Liste")
    func serverMuted() async throws {
        Spy.body = Data("kein JSON".utf8)
        defer {
            Spy.body = Data(#"{"Items":[],"TotalRecordCount":0}"#.utf8)
        }
        let title = await (await spyClient()).title(person: "p1")
        #expect(title == nil)
    }

    /// The control: a genuinely empty response stays `[]`.
    @Test("Eine leere Antwort bleibt eine leere Liste")
    func reallyEmpty() async throws {
        Spy.body = Data(#"{"Items":[],"TotalRecordCount":0}"#.utf8)
        let title = await (await spyClient()).title(person: "p1")
        #expect(title?.isEmpty == true)
    }
}

extension PeopleTests {

    private func client() async -> JellyfinClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Spy.self]
        let c = JellyfinClient(baseURL: URL(string: "https://tv.example.de")!,
                               deviceID: "d", deviceName: "P",
                               urlSession: URLSession(configuration: config))
        await c.setSession(Session(accessToken: "t", userID: "u1", userName: "T",
                                   serverURL: URL(string: "https://tv.example.de")!))
        return c
    }

    private func q() -> [String: String] {
        let t = URLComponents(url: Spy.captured!.url!, resolvingAgainstBaseURL: false)
        return Dictionary(uniqueKeysWithValues: (t?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    @Test("Person und Genre liefern die Gesamtzahl des Servers und reichen startIndex durch")
    func figure() async throws {
        Spy.body = Data("""
        {"Items":[{"Id":"a","Name":"A","Type":"Movie"},{"Id":"b","Name":"B","Type":"Series"}],
         "TotalRecordCount":800}
        """.utf8)
        let c = await client()
        let p = try #require(await c.titleWithNumber(person: "p1", limit: 2, startIndex: 4))
        #expect(p.total == 800 && p.items.count == 2)
        #expect(q()["StartIndex"] == "4")
        let g = try #require(await c.titleWithNumber(genre: "Krimi", limit: 2))
        #expect(g.total == 800)
        #expect(q()["SortBy"] == "DateCreated")
    }

    @Test("Staffeln und Folgen fragen ohne fehlende Folgen")
    func missing() async throws {
        Spy.body = Data(#"{"Items":[],"TotalRecordCount":0}"#.utf8)
        let c = await client()
        _ = try await c.seasons(seriesID: "s")
        #expect(q()["isMissing"] == "false")
        _ = try await c.episodes(seriesID: "s", seasonID: "x")
        #expect(q()["isMissing"] == "false")
        #expect(q()["seasonId"] == "x")
    }

    @Test("Ohne Doppel kostet je Werk einmal keine Abfrage, auch mit durchgereichten Bibliotheken")
    func withoutDoubleNoQuery() async {
        Spy.captured = nil
        let c = await client()
        let a = [Item(id: "a", name: "A", type: "Movie")]
        let r = await c.jeItemInTimes(a, libraries: [])
        #expect(r.count == 1 && Spy.captured == nil)
    }
}
