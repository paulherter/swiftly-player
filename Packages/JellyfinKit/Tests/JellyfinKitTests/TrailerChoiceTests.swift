import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import JellyfinKit

/// **Which trailer a title offers.** Pure rule plus one pass through the client with a
/// realistic `LocalTrailers` answer.
@Suite("Trailer-Auswahl", .serialized)
struct TrailerChoiceTests {

    private func file(_ id: String) -> Item { Item(id: id, name: "Trailer \(id)", type: "Trailer") }
    private func link(_ url: String?) -> MediaURL {
        try! JSONDecoder().decode(MediaURL.self, from: Data(
            (url.map { #"{"Url":"\#($0)","Name":"Trailer"}"# } ?? #"{"Name":"Trailer"}"#).utf8))
    }

    @Test("Dateien zuerst, dann Links, in Serverreihenfolge")
    func order() {
        let c = TrailerChoice.candidates(local: [file("a"), file("b")],
                                         remote: [link("https://youtu.be/x")], canOpenWeb: true)
        #expect(c == [.file(file("a")), .file(file("b")), .web(URL(string: "https://youtu.be/x")!)])
    }

    @Test("Ohne Browser nur Dateien")
    func filesOnly() {
        let c = TrailerChoice.candidates(local: [file("a")], remote: [link("https://youtu.be/x")],
                                         canOpenWeb: false)
        #expect(c == [.file(file("a"))])
        #expect(TrailerChoice.candidates(local: [], remote: [link("https://youtu.be/x")],
                                         canOpenWeb: false).isEmpty)
    }

    @Test("Doppelte fallen weg, Links ohne Adresse oder ohne http auch")
    func cleaning() {
        let c = TrailerChoice.candidates(
            local: [file("a"), file("a")],
            remote: [link(nil), link(""), link("ftp://x.test/t"), link("not a url"),
                     link("https://youtu.be/x"), link(" https://youtu.be/x ")],
            canOpenWeb: true)
        #expect(c == [.file(file("a")), .web(URL(string: "https://youtu.be/x")!)])
    }

    @Test("Regal: Trailer vorn, derselbe Titel nur einmal")
    func shelf() {
        let c = TrailerChoice.candidates(local: [file("a")], remote: [link("https://youtu.be/x")],
                                         canOpenWeb: true)
        #expect(TrailerChoice.files(in: c) == [file("a")])
        #expect(TrailerChoice.shelf(trailers: [file("a")], extras: [file("e"), file("a")])
                == [file("a"), file("e")])
        #expect(TrailerChoice.shelf(trailers: [], extras: [file("e")]) == [file("e")])
    }

    @Test("Kodi-Link auf YouTube wird zur YouTube-Seite")
    func kodiPlugin() {
        #expect(TrailerChoice.webAddress("plugin://plugin.video.youtube/?action=play_video&videoid=dQw4w9WgXcQ")
                == URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        #expect(TrailerChoice.webAddress("plugin://plugin.video.youtube/play/?video_id=abc-_1")
                == URL(string: "https://www.youtube.com/watch?v=abc-_1"))
        #expect(TrailerChoice.webAddress("plugin://plugin.video.youtube/?action=play_video") == nil)
        #expect(TrailerChoice.webAddress("plugin://plugin.video.vimeo/?id=1") == nil)
    }

    // MARK: - Through the client

    final class Spy: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var path: String?
        nonisolated(unsafe) static var query: [String: String] = [:]
        /// What the Jellyfin server sends for `Items/{id}/LocalTrailers`: a bare array.
        /// The second entry has no name, the first carries the kind markers.
        nonisolated(unsafe) static var body = Data("""
        [{"Name":"Heat-trailer","Id":"t1","Type":"Trailer","ExtraType":"Trailer",
          "RunTimeTicks":1500000000,"MediaType":"Video","IsFolder":false,
          "MediaSources":[{"Id":"t1","Container":"mkv","Size":1000,"MediaStreams":[]}]},
         {"Id":"broken"},
         {"Name":"Heat 2","Id":"t2","Type":"Trailer","ExtraType":"Trailer","MediaType":"Video"}]
        """.utf8)

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            Self.path = request.url?.path
            let parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            Self.query = Dictionary(uniqueKeysWithValues:
                (parts?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
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
        await c.setSession(Session(accessToken: "tok", userID: "u1", userName: "Testnutzer",
                                   serverURL: URL(string: "https://tv.example.de")!))
        return c
    }

    @Test("Server-Trailer und Link zusammen: Dateien zuerst, kaputter Eintrag fällt weg")
    func throughClient() async throws {
        let client = await spyClient()
        let title = try JSONDecoder().decode(Item.self, from: Data("""
        {"Id":"m1","Name":"Heat","Type":"Movie","LocalTrailerCount":2,
         "RemoteTrailers":[{"Url":"https://www.youtube.com/watch?v=abc"}]}
        """.utf8))
        let c = await client.trailerCandidates(for: title, canOpenWeb: true)
        #expect(Spy.path == "/Items/m1/LocalTrailers")
        #expect(Spy.query["userId"] == "u1")
        #expect(c.count == 3)
        guard case .file(let first) = c[0], case .file(let second) = c[1],
              case .web(let url) = c[2] else { Issue.record("wrong order: \(c)"); return }
        #expect(first.id == "t1")
        #expect(first.extraType == "Trailer")
        #expect(second.id == "t2")
        #expect(url.host == "www.youtube.com")
    }
}
