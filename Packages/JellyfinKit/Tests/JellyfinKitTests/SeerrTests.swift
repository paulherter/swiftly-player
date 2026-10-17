import Foundation
#if canImport(FoundationNetworking)
// On Linux (also CI) URLSession and HTTPCookie live here.
import FoundationNetworking
#endif
import Testing
@testable import JellyfinKit

@Suite("Seerr")
struct SeerrTests {

    // MARK: Search response

    /// Literal JSON, the way Seerr delivers it, not via our own
    /// encoder. A test that encodes by itself only tests itself.
    private let answer = Data("""
    {"page":1,"totalResults":4,"results":[
      {"id":1,"mediaType":"movie","title":"Mentalist Live","releaseDate":"2014-03-01",
       "posterPath":"/abc.jpg","backdropPath":"/quer.jpg"},
      {"id":2,"mediaType":"tv","name":"The Mentalist","firstAirDate":"2008-09-23",
       "posterPath":"/def.jpg","mediaInfo":{"status":5}},
      {"id":3,"mediaType":"tv","name":"The Mentalist (UK)","firstAirDate":"2011-01-01",
       "mediaInfo":{"status":2}},
      {"id":4,"mediaType":"person","name":"Simon Baker","profilePath":"/ghi.jpg"}
    ]}
    """.utf8)

    @Test("Filme und Serien kommen durch, Personen nicht")
    func peopleDropOut() {
        let t = Seerr.hit(fromSearch: answer)
        #expect(t.count == 3)
        #expect(!t.contains { $0.title == "Simon Baker" })
    }

    @Test("Titel kommt aus title oder name, das Jahr aus dem Datum")
    func titleAndYear() throws {
        let t = Seerr.hit(fromSearch: answer)
        let film = try #require(t.first { $0.id == 1 })
        #expect(film.title == "Mentalist Live")
        #expect(film.year == 2014)
        let series = try #require(t.first { $0.id == 2 })
        #expect(series.title == "The Mentalist")
        #expect(series.year == 2008)
        #expect(series.isSeries)
    }

    /// Seerr creates the entry only with the first request. If it is missing,
    /// nobody asked; that is `opened`, not "unknown".
    @Test("Ohne mediaInfo gilt der Titel als offen")
    func withoutMediaInfoOpen() throws {
        let t = try #require(Seerr.hit(fromSearch: answer).first { $0.id == 1 })
        #expect(t.state == .opened)
        #expect(t.state.requestable)
    }

    @Test("Die Zahlen der Schnittstelle werden übernommen, nicht umgedeutet")
    func statesFromResponse() throws {
        let t = Seerr.hit(fromSearch: answer)
        #expect(try #require(t.first { $0.id == 2 }).state == .present)
        #expect(try #require(t.first { $0.id == 3 }).state == .waitsSharing)
    }

    @Test("Kaputte Antwort liefert nichts, statt zu werfen")
    func brokenResponse() {
        #expect(Seerr.hit(fromSearch: Data("kein JSON".utf8)).isEmpty)
    }

    // MARK: States

    /// A state is not a button: what is waiting or loading cannot
    /// be requested again.
    @Test("Nur offen, gelöscht und teilweise da lassen sich anfragen")
    func onlyWhatMakesSense() {
        #expect(SeerrState.opened.requestable)
        #expect(SeerrState.deleted.requestable)
        #expect(SeerrState.partWayPresent.requestable)
        #expect(!SeerrState.waitsSharing.requestable)
        #expect(!SeerrState.loads.requestable)
        #expect(!SeerrState.present.requestable)
    }

    @Test("Nur `da` gehört in den oberen Block")
    func onlyPresentIsPresent() {
        #expect(SeerrState.present.alreadyPresent)
        #expect(!SeerrState.partWayPresent.alreadyPresent)
        #expect(!SeerrState.loads.alreadyPresent)
    }

    // MARK: Poster

    @Test("Die Bildadresse zeigt auf TMDB, nicht auf Seerr")
    func posterAddress() throws {
        let t = try #require(Seerr.hit(fromSearch: answer).first { $0.id == 1 })
        let u = try #require(t.poster())
        #expect(u.absoluteString == "https://image.tmdb.org/t/p/w342/abc.jpg")
    }

    /// The head of a page needs the landscape image. A stretched poster
    /// is too tall and pushes everything below it down.
    @Test("Das Querbild kommt aus backdropPath, nicht aus dem Plakat")
    func backdropImage() throws {
        let t = try #require(Seerr.hit(fromSearch: answer).first { $0.id == 1 })
        let u = try #require(t.backdrop())
        #expect(u.absoluteString == "https://image.tmdb.org/t/p/w780/quer.jpg")
    }

    /// **No fallback to the poster.** Better no header image at all than one
    /// that pushes half the page down.
    @Test("Ohne Querbild kommt nichts, nicht das Plakat")
    func noFallbackPoster() throws {
        let t = try #require(Seerr.hit(fromSearch: answer).first { $0.id == 2 })
        #expect(t.backdrop() == nil)
        #expect(t.poster() != nil)
    }

    @Test("Ohne Pfad gibt es keine Adresse")
    func withoutPoster() throws {
        let t = try #require(Seerr.hit(fromSearch: answer).first { $0.id == 3 })
        #expect(t.poster() == nil)
    }

    // MARK: Cookie

    @Test("Der Sitzungskeks wird aus dem Kopf geschnitten")
    func cutCookie() {
        let header = "connect.sid=s%3Aabc123.xyz; Path=/; HttpOnly; SameSite=Strict"
        #expect(Seerr.cookie(fromHeader: header) == "connect.sid=s%3Aabc123.xyz")
    }

    /// Multiple cookies arrive joined with a comma. Whoever hopes for a
    /// single one gets nothing from a server behind a load balancer.
    @Test("Aus mehreren Keksen wird der richtige gefunden")
    func multipleCookies() {
        let header = "lb=eu-1; Path=/, connect.sid=s%3Aabc; Path=/; HttpOnly"
        #expect(Seerr.cookie(fromHeader: header) == "connect.sid=s%3Aabc")
    }

    @Test("Ohne Sitzungskeks kommt nichts zurück")
    func noCookie() {
        #expect(Seerr.cookie(fromHeader: "lb=eu-1; Path=/") == nil)
        #expect(Seerr.cookie(fromHeader: "connect.sid=; Path=/") == nil)
    }

    // MARK: Request

    @Test("Ein Film wird ohne Staffeln angefragt")
    func filmWithoutSeasons() {
        let r = Seerr.requestBody(art: "movie", id: 42, seasons: nil)
        #expect(r["mediaType"] as? String == "movie")
        #expect(r["mediaId"] as? Int == 42)
        #expect(r["seasons"] == nil)
    }

    /// Seerr once confused an empty field with "none at all",
    /// so the word `all` is sent in that case.
    @Test("Eine Serie ohne Auswahl fragt alle Staffeln an")
    func seriesWithoutSelection() {
        let r = Seerr.requestBody(art: "tv", id: 7, seasons: nil)
        #expect(r["seasons"] as? String == "all")
        let empty = Seerr.requestBody(art: "tv", id: 7, seasons: [])
        #expect(empty["seasons"] as? String == "all")
    }

    @Test("Gewählte Staffeln gehen als Liste hinaus")
    func selectedSeasons() {
        let r = Seerr.requestBody(art: "tv", id: 7, seasons: [1, 3])
        #expect(r["seasons"] as? [Int] == [1, 3])
    }

    // MARK: Address

    @Test("Die Adresse wird aufgeräumt, egal wie sie getippt wurde")
    func addressCleanUp() throws {
        let expects = "https://seerr.example.de"
        for typedInput in ["seerr.example.de", "https://seerr.example.de/",
                        "https://seerr.example.de/api/v1", "  seerr.example.de/api/  "] {
            let u = try #require(Seerr.address(from: typedInput), "\(typedInput)")
            #expect(u.absoluteString == expects, "\(typedInput)")
        }
    }

    /// Whoever types an IP does not mean `https`, since such hosts practically never have a
    /// certificate. Same rule as for the media server.
    @Test("Eine IP im Heimnetz bekommt http, ein Name https")
    func homeNetworkGetsHttp() throws {
        #expect(try #require(Seerr.address(from: "192.168.1.9:5055")).scheme == "http")
        #expect(try #require(Seerr.address(from: "10.0.0.4")).scheme == "http")
        #expect(try #require(Seerr.address(from: "seerr.local:5055")).scheme == "http")
        #expect(try #require(Seerr.address(from: "seerr.example.de")).scheme == "https")
    }

    @Test("http bleibt http, wenn es dasteht")
    func httpStays() throws {
        let u = try #require(Seerr.address(from: "http://192.168.1.9:5055"))
        #expect(u.absoluteString == "http://192.168.1.9:5055")
    }

    @Test("Leer ist keine Adresse")
    func emptyIsNot() {
        #expect(Seerr.address(from: "   ") == nil)
    }
    // MARK: Detail

    private let series = Data("""
    {"overview":"Ein Berater der Polizei.","episodeRunTime":[45],"voteAverage":8.1,
     "genres":[{"name":"Krimi"},{"name":"Drama"},{"name":"Mystery"}],
     "seasons":[
       {"seasonNumber":0,"episodeCount":3},
       {"seasonNumber":1,"episodeCount":23},
       {"seasonNumber":2,"episodeCount":22}],
     "mediaInfo":{"seasons":[{"seasonNumber":1,"status":5}]}}
    """.utf8)

    @Test("Beschreibung, Laufzeit und Bewertung kommen an")
    func detailFields() throws {
        let d = try #require(Seerr.detail(from: series))
        #expect(d.description == "Ein Berater der Polizei.")
        #expect(d.runtime == 45)
        #expect(d.rating == 8.1)
    }

    /// Two are enough for a secondary line; the third says nothing more and
    /// pushes the runtime out of view.
    @Test("Höchstens zwei Gattungen")
    func atMostTwoGenres() throws {
        let d = try #require(Seerr.detail(from: series))
        #expect(d.genres == ["Krimi", "Drama"])
    }

    /// TMDB files specials under season 0. Whoever requests "all seasons" does not
    /// mean them, and in a list of checkboxes it would be at the very top.
    @Test("Staffel 0 fällt heraus")
    func seasonZeroDropsOut() throws {
        let d = try #require(Seerr.detail(from: series))
        #expect(d.seasons.map(\.number) == [1, 2])
    }

    /// The state is not on the season but in a second list
    /// next to it; the two are merged, not guessed.
    @Test("Der Stand je Staffel wird zugeordnet")
    func seasonStates() throws {
        let d = try #require(Seerr.detail(from: series))
        #expect(d.seasons.first { $0.number == 1 }?.state == .present)
        #expect(d.seasons.first { $0.number == 2 }?.state == .opened)
        #expect(d.seasons.first { $0.number == 2 }?.episodes == 22)
    }

    @Test("Ein Film hat keine Staffeln, aber eine Laufzeit")
    func movieDetail() throws {
        let film = Data(#"{"overview":"Ein Film.","runtime":112,"voteAverage":6.9}"#.utf8)
        let d = try #require(Seerr.detail(from: film))
        #expect(d.seasons.isEmpty)
        #expect(d.runtime == 112)
    }

    /// After a request and when reopening, the state of the detail
    /// response (`mediaInfo.status`) counts, not the old search hit.
    @Test("Die Detailantwort trägt den Stand des Titels")
    func detailState() throws {
        func state(_ json: String) throws -> SeerrState? {
            try #require(Seerr.detail(from: Data(json.utf8))).state
        }
        #expect(try state(#"{"mediaInfo":{"status":2}}"#) == .waitsSharing)
        #expect(try state(#"{"mediaInfo":{"status":3}}"#) == .loads)
        #expect(try state(#"{"mediaInfo":{"status":4}}"#) == .partWayPresent)
        #expect(try state(#"{"mediaInfo":{"status":5}}"#) == .present)
        #expect(try state(#"{"overview":"x"}"#) == .opened)
    }

    /// An empty description is no description; otherwise the page would show
    /// a heading above nothing.
    @Test("Leere Beschreibung zählt als keine")
    func emptyDescription() throws {
        let d = try #require(Seerr.detail(from: Data(#"{"overview":"   "}"#.utf8)))
        #expect(d.description == nil)
    }

    @Test("Kaputte Detailantwort liefert nichts")
    func brokenDetail() {
        #expect(Seerr.detail(from: Data("nope".utf8)) == nil)
    }

    // MARK: Cast and suggestions

    /// Literal JSON, not self-encoded: whether the two tabs of the
    /// page show anything at all hangs on this response.
    private let withAttachment = Data(#"""
    {
      "overview": "Ein Film.",
      "runtime": 112,
      "credits": {
        "cast": [
          {"id": 1, "name": "Simon Baker", "character": "Patrick Jane",
           "profilePath": "/a.jpg"},
          {"id": 2, "name": "Robin Tunney", "character": "", "profilePath": null},
          {"id": 3, "character": "Namenlos"}
        ],
        "crew": [{"id": 9, "name": "Bruno Heller", "job": "Creator"}]
      },
      "recommendations": {
        "results": [
          {"id": 42, "title": "Der Nachbar", "releaseDate": "2011-02-03",
           "posterPath": "/p.jpg", "backdropPath": "/b.jpg"},
          {"id": 43, "title": "Schon da", "mediaInfo": {"status": 5}}
        ]
      }
    }
    """#.utf8)

    @Test("Die Besetzung kommt aus credits.cast, die Crew nicht")
    func cast() throws {
        let d = try #require(Seerr.detail(from: withAttachment))
        #expect(d.cast.map(\.name) == ["Simon Baker", "Robin Tunney"])
        #expect(d.cast.first?.role == "Patrick Jane")
    }

    /// An empty character is no character; otherwise a line that says
    /// nothing but still takes up space would sit under the name.
    @Test("Eine leere Rolle zaehlt als keine")
    func emptyRole() throws {
        let d = try #require(Seerr.detail(from: withAttachment))
        #expect(d.cast.first { $0.name == "Robin Tunney" }?.role == nil)
    }

    @Test("Ohne Bild kommt keine Adresse, nicht eine kaputte")
    func portraitWithoutPath() throws {
        let d = try #require(Seerr.detail(from: withAttachment))
        #expect(d.cast.first?.image()?.absoluteString
                == "https://image.tmdb.org/t/p/w185/a.jpg")
        #expect(d.cast.first { $0.name == "Robin Tunney" }?.image() == nil)
    }

    /// **The bug.** The detail response carries `credits` but no
    /// suggestions, which live under a separate path. So the
    /// cast was there and "Similar" was empty.
    @Test("Die Detailantwort allein bringt keine Vorschlaege")
    func detailWithoutSuggestions() throws {
        let d = try #require(Seerr.detail(from: withAttachment))
        #expect(d.cast.count == 2)
        #expect(d.similarOne.isEmpty)
    }

    private let preHitResponse = Data(#"""
    {
      "page": 1,
      "totalPages": 3,
      "results": [
        {"id": 42, "title": "Der Nachbar", "releaseDate": "2011-02-03",
         "posterPath": "/p.jpg", "backdropPath": "/b.jpg"},
        {"id": 43, "title": "Schon da", "mediaInfo": {"status": 5}}
      ]
    }
    """#.utf8)

    /// **The case that otherwise fails silently.** This response has
    /// no `mediaType`, since the page knows what it is. Without the fallback
    /// nothing would come out of even a full response.
    @Test("Vorschlaege ohne mediaType erben die Art der Seite")
    func suggestionsInheritType() {
        let v = Seerr.suggestions(from: preHitResponse, art: "movie")
        #expect(v.map(\.id) == [42, 43])
        #expect(v.allSatisfy { $0.art == "movie" })
        #expect(v.first?.year == 2011)
        #expect(v.first?.backdrop()?.absoluteString
                == "https://image.tmdb.org/t/p/w780/b.jpg")
        #expect(v.last?.state == .present)
    }

    @Test("Eine kaputte Vorschlagsantwort liefert nichts, wirft aber nicht")
    func brokenSuggestions() {
        #expect(Seerr.suggestions(from: Data("nope".utf8), art: "tv").isEmpty)
    }

    /// The information stays the same, only the suggestions are added; this is how
    /// the client combines the two fetches.
    @Test("Zusammensetzen laesst alles andere unberuehrt")
    func togetherSet() throws {
        let d = try #require(Seerr.detail(from: withAttachment))
        let full = d.with(similarOne: Seerr.suggestions(from: preHitResponse, art: "movie"))
        #expect(full.description == d.description)
        #expect(full.cast == d.cast)
        #expect(full.runtime == 112)
        #expect(full.similarOne.count == 2)
    }

    @Test("Fehlen die credits, bleibt die Besetzung leer")
    func withoutAttachment() throws {
        let d = try #require(Seerr.detail(from: Data(#"{"overview":"x"}"#.utf8)))
        #expect(d.cast.isEmpty)
        #expect(d.similarOne.isEmpty)
    }
}

@Suite("Seerr-Adresse")
struct SeerrAddressTests {

    @Test("Ohne Schema wird geraten — und der zweite Versuch steht daneben")
    func secondAttempt() {
        let a = Seerr.addresses(from: "seerr.beispiel.de")
        #expect(a.map(\.absoluteString) == ["https://seerr.beispiel.de",
                                            "http://seerr.beispiel.de"])
        // An address on the home network guesses the other way round and falls back upward.
        let b = Seerr.addresses(from: "192.168.1.9:5055")
        #expect(b.map(\.absoluteString) == ["http://192.168.1.9:5055",
                                            "https://192.168.1.9:5055"])
    }

    @Test("Wer das Schema selbst tippt, bekommt keinen zweiten Versuch")
    func tapItSchemaApplies() {
        #expect(Seerr.addresses(from: "https://seerr.beispiel.de").count == 1)
        #expect(Seerr.addresses(from: "http://192.168.1.9:5055").count == 1)
    }

    @Test("Der Anhang faellt weg, das Schema bleibt")
    func attachment() {
        #expect(Seerr.addresses(from: "https://seerr.beispiel.de/api/v1")
                    .map(\.absoluteString) == ["https://seerr.beispiel.de"])
    }

    @Test("Leere Eingabe ergibt nichts")
    func empty() {
        #expect(Seerr.addresses(from: "   ").isEmpty)
    }
}

// MARK: - Session in the cookie store

/// **The case:** signing out only discarded the stored credentials,
/// the cookie stayed in the connection's storage. Seerr (express-session) then
/// issues no new session, and the sign-in reported "no session
/// given" although it had succeeded.
@Test func cookieComesAlsoOutCache() throws {
    let address = URL(string: "https://seerr.example.de")!
    let k = URLSessionConfiguration.ephemeral
    let session = URLSession(configuration: k)
    let cookie = HTTPCookie(properties: [
        .domain: "seerr.example.de", .path: "/",
        .name: "connect.sid", .value: "s%3Aabc123",
    ])!
    k.httpCookieStorage?.setCookie(cookie)

    #expect(Seerr.cookieOutCache(for: address, session: session) == "connect.sid=s%3Aabc123")

    Seerr.cookiesForget(for: address, session: session)
    #expect(Seerr.cookieOutCache(for: address, session: session) == nil)
}

// MARK: - Custom headers in front of Seerr (issue #4)

/// A gateway proxy in front of Seerr (Cloudflare Access, Authelia, Pangolin) lets
/// through only whoever brings their headers. **All values here are made up.**
@Suite("Seerr hinter einem Vorposten", .serialized)
struct SeerrPreItemTests {

    /// Accepts every request and answers as `antwort` dictates.
    final class Spy: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var withCut: [URLRequest] = []
        nonisolated(unsafe) static var answer: (status: Int, header: [String: String], shell: String) =
            (200, ["Set-Cookie": "connect.sid=s%3Aneu; Path=/; HttpOnly"], "{}")

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            Self.withCut.append(request)
            let a = Self.answer
            let http = HTTPURLResponse(url: request.url!, statusCode: a.status,
                                       httpVersion: nil, headerFields: a.header)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(a.shell.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func session() -> URLSession {
        let k = URLSessionConfiguration.ephemeral
        k.protocolClasses = [Spy.self]
        return URLSession(configuration: k)
    }

    private let address = URL(string: "https://seerr.vorposten.test")!
    private let headers = [OwnHeader(name: "CF-Access-Client-Id", value: "erfunden.access"),
                          OwnHeader(name: "CF-Access-Client-Secret", value: "auch-erfunden")]

    @Test("Die Anmeldung trägt die eigenen Köpfe, und der Zugang behält sie")
    func signInSendsHeaders() async throws {
        Spy.withCut = []
        Spy.answer = (200, ["Set-Cookie": "connect.sid=s%3Aneu; Path=/; HttpOnly"], "{}")
        let access = try await SeerrClient.signIn(an: address, user: "jane", password: "x",
                                                    headers: headers, session: session())
        let req = try #require(Spy.withCut.first)
        #expect(req.value(forHTTPHeaderField: "CF-Access-Client-Id") == "erfunden.access")
        #expect(req.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "auch-erfunden")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(access.headers == headers)
        #expect(access.cookie == "connect.sid=s%3Aneu")
    }

    @Test("Jeder spätere Aufruf trägt sie auch — und der Keks bleibt der eigene")
    func requestSendsHeaders() async throws {
        Spy.withCut = []
        Spy.answer = (200, [:], #"{"results":[]}"#)
        // `Cookie` as a custom header is blocked: it belongs to the session.
        let access = SeerrAccess(address: address, cookie: "connect.sid=s%3Aalt",
                                 headers: headers + [OwnHeader(name: "Cookie", value: "fremd=1")])
        _ = await SeerrClient(access: access, session: session()).searching("Mentalist")
        let req = try #require(Spy.withCut.first)
        #expect(req.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "auch-erfunden")
        #expect(req.value(forHTTPHeaderField: "Cookie") == "connect.sid=s%3Aalt")
    }

    @Test("Ohne eigene Köpfe geht die Anmeldung hinaus wie immer")
    func withoutHeadersUnchanged() async throws {
        Spy.withCut = []
        Spy.answer = (200, ["Set-Cookie": "connect.sid=s%3Aneu; Path=/"], "{}")
        let access = try await SeerrClient.signIn(an: address, user: "jane", password: "x",
                                                    session: session())
        let req = try #require(Spy.withCut.first)
        #expect(req.value(forHTTPHeaderField: "CF-Access-Client-Id") == nil)
        #expect(access.headers.isEmpty)
    }

    /// The case from the issue: Access redirects, and at the end there is a 200 with
    /// HTML. That used to read "Seerr gave no session".
    @Test("Eine Anmeldeseite davor wird als solche gemeldet")
    func loginPageBecomesDetected() async throws {
        Spy.answer = (200, ["Content-Type": "text/html; charset=utf-8"], "<html>Sign in</html>")
        do {
            _ = try await SeerrClient.signIn(an: address, user: "jane", password: "x",
                                               session: session())
            Issue.record("Die Anmeldung haette scheitern muessen")
        } catch {
            #expect(readableError(error) == OwnHeaders.loginPageText)
        }
    }

    @Test("Ein 404 mit HTML bleibt „kein Seerr unter dieser Adresse“")
    func fourNullFourStays() async throws {
        Spy.answer = (404, ["Content-Type": "text/html"], "<html>Not found</html>")
        do {
            _ = try await SeerrClient.signIn(an: address, user: "jane", password: "x",
                                               session: session())
            Issue.record("Die Anmeldung haette scheitern muessen")
        } catch {
            #expect(readableError(error) != OwnHeaders.loginPageText)
        }
    }

    /// **The costliest bug here would be a silent one:** credentials from before
    /// this field that are no longer readable would disconnect every existing
    /// user from Seerr.
    @Test("Ein gespeicherter Zugang ohne Köpfe bleibt lesbar")
    func oldAccessStaysReadable() throws {
        let alt = Data(#"{"adresse":"https:\/\/seerr.vorposten.test","keks":"connect.sid=s%3Aalt"}"#.utf8)
        let z = try JSONDecoder().decode(SeerrAccess.self, from: alt)
        #expect(z.cookie == "connect.sid=s%3Aalt")
        #expect(z.headers.isEmpty)
        // And without headers it is written back the same way.
        let new = try JSONSerialization.jsonObject(with: JSONEncoder().encode(z)) as? [String: Any]
        #expect(new?["koepfe"] == nil)
    }

    @Test("Köpfe überstehen das Ablegen")
    func headersOverStateStore() throws {
        let z = SeerrAccess(address: address, cookie: "connect.sid=x", headers: headers)
        let back = try JSONDecoder().decode(SeerrAccess.self, from: JSONEncoder().encode(z))
        #expect(back == z)
    }
}
