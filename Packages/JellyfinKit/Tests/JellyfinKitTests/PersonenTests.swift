import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import JellyfinKit

/// **Was die Filmografie beim Server bestellt.**
///
/// Geprüft wird die Anfrage, nicht die Antwort: die drei Entscheidungen, die
/// in den Parametern stecken und die man beim Nachbauen auf einer anderen
/// Plattform übersieht — Sortierung, Gattungsgrenze, Personenkennung.
@Suite("Filmografie einer Person", .serialized)
struct PersonenTests {

    /// Fängt die Anfrage ab und antwortet mit einer festen Liste.
    final class Spy: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var captured: URLRequest?
        /// Was zurückkommt. Zwei Einträge tragen dieselbe Kennung — daran
        /// hängt die Prüfung auf Doppelte.
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

    private func abfrage() throws -> [String: String] {
        let url = try #require(Spy.captured?.url)
        let teile = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return Dictionary(uniqueKeysWithValues:
            (teile.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    @Test("Fragt nach Jahr absteigend, mit SortName als zweitem Schlüssel")
    func sortierung() async throws {
        _ = await (await spyClient()).titel(person: "p1")
        let q = try abfrage()
        // Eine Filmografie liest man von hinten.
        #expect(q["SortOrder"] == "Descending")
        // Ohne den zweiten Schlüssel entscheidet der Server bei Titeln
        // desselben Jahres, und die Liste steht zwischen zwei Abrufen anders da.
        #expect(q["SortBy"] == "ProductionYear,SortName")
    }

    /// Ohne Gattungsgrenze kämen auch die einzelnen Folgen — jede mit dem
    /// Plakat ihrer Serie, also dasselbe Bild vielfach nebeneinander.
    /// Dieselbe Überlegung wie bei der Suche (A7).
    @Test("Holt nur Filme und Serien, keine Folgen")
    func nurFilmUndSerie() async throws {
        _ = await (await spyClient()).titel(person: "p1")
        let typen = try abfrage()["IncludeItemTypes"] ?? ""
        #expect(typen.contains("Movie"))
        #expect(typen.contains("Series"))
        #expect(!typen.contains("Episode"))
    }

    @Test("Gibt die Personenkennung mit und sucht rekursiv")
    func personUndRekursiv() async throws {
        _ = await (await spyClient()).titel(person: "p42")
        let q = try abfrage()
        #expect(q["PersonIds"] == "p42" || q["personIds"] == "p42",
                "Personenkennung fehlt in der Abfrage: \(q)")
        // Ohne `Recursive` durchsucht Jellyfin nur die oberste Ebene.
        #expect((q["Recursive"] ?? "").lowercased() == "true")
    }

    /// Der Server kann denselben Titel zweimal liefern. Auf Apple faellt das
    /// `ForEach` darueber, auf GTK stuende die Kachel doppelt im Raster.
    @Test("Doppelte Kennungen fallen weg")
    func ohneDoppelte() async throws {
        let titel = await (await spyClient()).titel(person: "p1")
        #expect(titel?.map(\.id) == ["a", "b"])
    }

    /// **Der Unterschied, um den es geht.** Ein stummer Server ergibt `nil`,
    /// nicht `[]` — sonst zeigt die Personenseite „Von … liegt hier nichts",
    /// obwohl sie nie eine Antwort bekommen hat.
    @Test("Ein stummer Server ergibt nil, keine leere Liste")
    func serverStumm() async throws {
        Spy.body = Data("kein JSON".utf8)
        defer {
            Spy.body = Data(#"{"Items":[],"TotalRecordCount":0}"#.utf8)
        }
        let titel = await (await spyClient()).titel(person: "p1")
        #expect(titel == nil)
    }

    /// Die Gegenprobe: eine echte leere Antwort bleibt `[]`.
    @Test("Eine leere Antwort bleibt eine leere Liste")
    func wirklichLeer() async throws {
        Spy.body = Data(#"{"Items":[],"TotalRecordCount":0}"#.utf8)
        let titel = await (await spyClient()).titel(person: "p1")
        #expect(titel?.isEmpty == true)
    }
}

extension PersonenTests {

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
    func zahl() async throws {
        Spy.body = Data("""
        {"Items":[{"Id":"a","Name":"A","Type":"Movie"},{"Id":"b","Name":"B","Type":"Series"}],
         "TotalRecordCount":800}
        """.utf8)
        let c = await client()
        let p = try #require(await c.titelMitZahl(person: "p1", limit: 2, startIndex: 4))
        #expect(p.gesamt == 800 && p.items.count == 2)
        #expect(q()["StartIndex"] == "4")
        let g = try #require(await c.titelMitZahl(gattung: "Krimi", limit: 2))
        #expect(g.gesamt == 800)
        #expect(q()["SortBy"] == "DateCreated")
    }

    @Test("Staffeln und Folgen fragen ohne fehlende Folgen")
    func fehlende() async throws {
        Spy.body = Data(#"{"Items":[],"TotalRecordCount":0}"#.utf8)
        let c = await client()
        _ = try await c.staffeln(seriesID: "s")
        #expect(q()["isMissing"] == "false")
        _ = try await c.folgen(seriesID: "s", seasonID: "x")
        #expect(q()["isMissing"] == "false")
        #expect(q()["seasonId"] == "x")
    }

    @Test("Ohne Doppel kostet je Werk einmal keine Abfrage, auch mit durchgereichten Bibliotheken")
    func ohneDoppelKeineAbfrage() async {
        Spy.captured = nil
        let c = await client()
        let a = [Item(id: "a", name: "A", type: "Movie")]
        let r = await c.jeWerkEinmal(a, bibliotheken: [])
        #expect(r.count == 1 && Spy.captured == nil)
    }
}
