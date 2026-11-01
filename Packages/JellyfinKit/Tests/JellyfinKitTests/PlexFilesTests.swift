import Foundation
import Testing
@testable import JellyfinKit

@Suite("Plex: alle Dateien eines Titels sind Fassungen")
struct PlexFilesTests {
    /// Two versions; the first is split over two files.
    private let json = #"""
    {"MediaContainer":{"size":1,"Metadata":[{
      "ratingKey":"9","type":"movie","title":"Geteilt","duration":7200000,
      "Media":[
        {"id":11,"duration":7200000,"container":"mkv","Part":[
          {"id":101,"key":"/library/parts/101/1/file.mkv","duration":3600000,"file":"/m/Geteilt cd1.mkv","size":10,"container":"mkv",
           "Stream":[{"id":1,"streamType":1,"codec":"h264","height":1080}]},
          {"id":102,"key":"/library/parts/102/1/file.mkv","duration":3600000,"size":11,"container":"mkv",
           "Stream":[{"id":2,"streamType":1,"codec":"h264","height":1080}]}]},
        {"id":12,"duration":7200000,"container":"mp4","Part":[
          {"id":103,"key":"/library/parts/103/1/file.mp4","duration":7200000,"file":"/m/Geteilt 720.mp4","size":5,"container":"mp4",
           "Stream":[{"id":3,"streamType":1,"codec":"h264","height":720}]}]},
        {"id":13,"Part":[]}]
    }]}}
    """#

    private func metadata() throws -> PlexMetadata {
        let box = try JSONDecoder().decode(PlexEnvelope<PlexListing>.self, from: Data(json.utf8))
        return try #require(box.container.metadata.first)
    }

    @Test("Jede Datei eine Fassung, das erste Stück behält die alte Kennung")
    func sources() throws {
        let item = PlexMapper().item(try metadata())
        let sources = try #require(item.mediaSources)
        #expect(sources.map(\.id) == ["11", "11-2", "12"])
        #expect(sources[0].name == "Geteilt cd1.mkv")
        #expect(sources[1].name?.isEmpty == false)
        #expect(sources[2].name == "Geteilt 720.mp4")
        #expect(MediaVersions.choices(item.mediaSources).count == 3)
    }

    @Test("Der Plan nimmt die gewählte Datei, ohne Wahl die erste")
    func plan() throws {
        let playback = PlexPlayback(base: URL(string: "http://h:32400")!, token: "T")
        let m = try metadata()
        #expect(try playback.plan(for: m).url.absoluteString.contains("/library/parts/101/"))
        let second = try playback.plan(for: m, mediaSourceID: "11-2")
        #expect(second.url.absoluteString.contains("/library/parts/102/"))
        #expect(second.mediaSourceID == "11-2")
        #expect(second.source?.id == "11-2")
        let other = try playback.plan(for: m, mediaSourceID: "12")
        #expect(other.url.absoluteString.contains("/library/parts/103/"))
        // An unknown id falls back to the first file instead of failing.
        #expect(try playback.plan(for: m, mediaSourceID: "99").mediaSourceID == "11")
        #expect(PlexPlayback.part(of: m, mediaSourceID: "11-2")?.id == 102)
    }

    @Test("Extras und Trailer kommen vom Server, Online-Extras ohne Datei fallen weg")
    func extras() async throws {
        let body = #"""
        {"MediaContainer":{"size":3,"Metadata":[
          {"ratingKey":"50","type":"clip","subtype":"trailer","title":"Trailer","duration":1000,
           "Media":[{"id":5,"Part":[{"id":50,"key":"/library/parts/50/1/file.mp4","container":"mp4"}]}]},
          {"ratingKey":"51","type":"clip","subtype":"behindTheScenes","title":"Making of","duration":2000,
           "Media":[{"id":6,"Part":[{"id":51,"key":"/library/parts/51/1/file.mp4","container":"mp4"}]}]},
          {"ratingKey":"52","type":"clip","subtype":"trailer","title":"Online"}]}}
        """#
        let (host, urlSession) = PlexStub.register { _ in (200, body) }
        let identity = PlexIdentity(clientID: "c", platform: "macOS", device: "Mac", deviceName: "Mac")
        let client = PlexClient(baseURL: URL(string: "http://\(host):32400")!, token: "T",
                                identity: identity, urlSession: urlSession)
        let trailers = try await client.trailer(toward: "9")
        #expect(trailers.map(\.id) == ["50"])
        let extras = try await client.extras(itemID: "9")
        #expect(extras.map(\.id) == ["51"])
        #expect(extras.first?.mediaType == "Video")
        #expect(PlexStub.requests(host).first?.url?.path == "/library/metadata/9/extras")
        let (gone, session) = PlexStub.register { _ in (404, "") }
        let missing = PlexClient(baseURL: URL(string: "http://\(gone):32400")!, token: "T",
                                 identity: identity, urlSession: session)
        #expect(try await missing.extras(itemID: "9").isEmpty)
    }

    @Test("Ein 401 mitten in der Sitzung wird gemeldet, einmal bis es geprüft ist")
    func tokenRejected() async throws {
        let (host, urlSession) = PlexStub.register { _ in (401, "") }
        let identity = PlexIdentity(clientID: "c", platform: "macOS", device: "Mac", deviceName: "Mac")
        let client = PlexClient(baseURL: URL(string: "http://\(host):32400")!, token: "T",
                                identity: identity, urlSession: urlSession)
        let told = PlexCounter()
        await client.onUnauthorized { told.next() }
        await #expect(throws: JellyfinError.notAuthenticated) { _ = try await client.sections() }
        await #expect(throws: JellyfinError.notAuthenticated) { _ = try await client.sections() }
        #expect(told.count == 1)
        await client.unauthorizedHandled()
        await #expect(throws: JellyfinError.notAuthenticated) { _ = try await client.sections() }
        #expect(told.count == 2)
    }

    @Test("Plex bietet keine Tonspur-Auswahl beim Laden: Datei bleibt das Original")
    func downloadAudioHidden() async throws {
        let (host, urlSession) = PlexStub.register { _ in (200, "") }
        let identity = PlexIdentity(clientID: "c", platform: "macOS", device: "Mac", deviceName: "Mac")
        let client = PlexClient(baseURL: URL(string: "http://\(host):32400")!, token: "T",
                                identity: identity, urlSession: urlSession)
        let defaults = try #require(await client.accountDefaults())
        #expect(defaults.downloadQualitySelectable == false)
    }
}
