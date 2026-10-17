import Foundation
import Testing
// On Linux, URLSession is not in Foundation but in a separate
// module. That module does not exist on Apple platforms, so the
// import is conditional and has no effect there.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import JellyfinKit

// .serialized because the tests share the static capture of the spy
// class; run in parallel they overwrite each other.
@Suite("Anmelde-Anfrage", .serialized)
struct AuthRequestTests {

    /// Intercepts the request instead of sending it, so the test can check
    /// what the app actually sends.
    final class Spy: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var captured: URLRequest?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }

        override func startLoading() {
            // After passing through URLSession, httpBody is only readable as a
            // stream, so collect it here.
            var req = request
            if req.httpBody == nil, let stream = req.httpBodyStream {
                stream.open()
                var data = Data()
                let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(buf, maxLength: 4096)
                    if read <= 0 { break }
                    data.append(buf, count: read)
                }
                buf.deallocate(); stream.close()
                req.httpBody = data
            }
            Self.captured = req

            let body = Data(#"{"AccessToken":"tok","ServerId":"s","User":{"Id":"u1","Name":"Testnutzer"}}"#.utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func spyClient() -> JellyfinClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Spy.self]
        return JellyfinClient(baseURL: URL(string: "https://tv.example.de")!,
                              deviceID: "dev-42", deviceName: "iPhone im Wohnzimmer",
                              urlSession: URLSession(configuration: config))
    }

    @Test("Schickt Username und Pw in Jellyfins Schreibweise")
    func bodyUsesServerFieldNames() async throws {
        _ = try await spyClient().authenticate(username: "paul", password: "geheim ✓")
        let req = try #require(Spy.captured)
        let body = try #require(req.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["Username"] == "paul")
        #expect(json["Pw"] == "geheim ✓", "Passwort kam verändert an: \(json["Pw"] ?? "nil")")
        #expect(json.keys.count == 2, "Unerwartete Felder: \(json.keys.sorted())")
    }

    @Test("Setzt den Authorization-Header ohne Token")
    func authorizationHeaderShape() async throws {
        _ = try await spyClient().authenticate(username: "paul", password: "x")
        let header = try #require(Spy.captured?.value(forHTTPHeaderField: "Authorization"))
        #expect(header.hasPrefix("MediaBrowser "))
        // **"Swiftly Player", the name from the store.** Users see it
        // in Jellyfin's device list, not on the home screen, where the app
        // is still called "Swiftly". Sessions used to show "Swiftly 0.1.0":
        // the wrong name and a version that never existed.
        #expect(header.contains(#"Client="Swiftly Player""#))
        #expect(header.contains(#"DeviceId="dev-42""#))
        // The version comes from the bundle. There is none in the test, so it
        // reads "unbekannt"; the test checks that the old fixed "0.1.0"
        // no longer appears anywhere.
        #expect(!header.contains("0.1.0"), "Die feste Fassungsnummer ist zurueck")
        #expect(!header.contains("Token="), "Beim Login darf noch kein Token mitgehen")
    }

    @Test("Trifft den richtigen Endpunkt")
    func endpoint() async throws {
        _ = try await spyClient().authenticate(username: "paul", password: "x")
        #expect(Spy.captured?.url?.path == "/Users/AuthenticateByName")
        #expect(Spy.captured?.httpMethod == "POST")
    }
}

// MARK: - Remote control

@Suite("Fernbefehle")
struct RemoteCommandTests {

    @Test("Jellyfins Namen werden richtig übersetzt")
    func names() {
        #expect(RemoteControl.translate("Pause", target: nil) == .pause)
        #expect(RemoteControl.translate("Unpause", target: nil) == .proceed)
        #expect(RemoteControl.translate("PlayPause", target: nil) == .toggle)
        #expect(RemoteControl.translate("Stop", target: nil) == .stop)
        #expect(RemoteControl.translate("NextTrack", target: nil) == .next)
    }

    @Test("Seek rechnet Ticks in Sekunden um")
    func jump() {
        // Jellyfin counts in steps of 100 nanoseconds.
        #expect(RemoteControl.translate("Seek", target: 12_000_000_000) == .jumpOn(1200))
        // Without a target the command is not executable.
        #expect(RemoteControl.translate("Seek", target: nil) == nil)
    }

    @Test("Unbekanntes wird verworfen statt geraten")
    func unknown() {
        #expect(RemoteControl.translate("Beam", target: nil) == nil)
    }
}

@Suite("Zeile für Neuzugänge")
struct NewAccessTests {

    private func item(type: String, episode: Int? = nil, season: Int? = nil,
                      children: Int? = nil, year: Int? = nil, name: String = "X") -> Item {
        let json = """
        {"Id":"1","Name":"\(name)","Type":"\(type)"
        \(episode.map { ",\"IndexNumber\":\($0)" } ?? "")
        \(season.map { ",\"ParentIndexNumber\":\($0)" } ?? "")
        \(children.map { ",\"ChildCount\":\($0)" } ?? "")
        \(year.map { ",\"ProductionYear\":\($0)" } ?? "")}
        """
        return try! JSONDecoder().decode(Item.self, from: Data(json.utf8))
    }

    // The lines are translated, so the wording depends on the device
    // language. The test therefore checks the statement, not the phrasing:
    // which number appears and which does not. The bug these tests pin
    // down was exactly that: the number of new episodes appeared where
    // the number of seasons was expected.

    @Test("Eine Folge nennt ihre Staffel, nicht ihre Nummer")
    func episode() {
        let row = item(type: "Episode", episode: 4, season: 3).newArrivalsRow
        #expect(row?.contains("3") == true)
        #expect(row?.contains("4") == false)
        // Without a season, at least the episode.
        #expect(item(type: "Episode", episode: 4).newArrivalsRow?.contains("4") == true)
    }

    @Test("Ganze Staffel nennt die Staffelnummer")
    func season() {
        #expect(item(type: "Season", episode: 2).newArrivalsRow?.contains("2") == true)
        // Without a number the name carries the statement, e.g. "Specials",
        // and it comes from the server, so it is not translated.
        #expect(item(type: "Season", name: "Specials").newArrivalsRow == "Specials")
    }

    @Test("Bei einer Serie zählt ChildCount neue Folgen, nicht Staffeln")
    func series() {
        let eight = item(type: "Series", children: 8).newArrivalsRow
        #expect(eight?.contains("8") == true)
        // The bug was that "Staffeln" (seasons) appeared here. The word must
        // not occur in either language.
        #expect(eight?.lowercased().contains("staffel") == false)
        #expect(eight?.lowercased().contains("season") == false)
        // Singular and plural differ.
        #expect(item(type: "Series", children: 1).newArrivalsRow != eight)
        // Without a count the year stays.
        #expect(item(type: "Series", year: 2024).newArrivalsRow == "2024")
    }

    @Test("Filme zeigen das Jahr")
    func film() {
        #expect(item(type: "Movie", year: 2021).newArrivalsRow == "2021")
    }
}

@Suite("Sprachvergleich")
struct LanguageTests {

    @Test("Erkennt die üblichen Schreibweisen")
    func writePoint() {
        #expect(Language.fits("Surround 5.1 - [German]", toward: "Deutsch"))
        #expect(Language.fits("deutsch (AC3)", toward: "Deutsch"))
        #expect(Language.fits("ger", toward: "Deutsch"))
        #expect(Language.fits("full - [English]", toward: "English"))
    }

    @Test("Verwechselt nichts")
    func noWrongHit() {
        #expect(!Language.fits("Surround 5.1 - [English]", toward: "Deutsch"))
        // Without a preference nothing may ever match, otherwise an empty
        // setting would silently pick the first track.
        #expect(!Language.fits("[German]", toward: ""))
    }
}

// MARK: - Addresses in the log

@Suite("Adressgeheimnis")
struct AddressSecretTests {

    @Test("Entfernt das Zugangsmerkmal aus der Stromadresse")
    func blacksOutApiKey() throws {
        let url = try #require(URL(string:
            "https://tv.example.de/Videos/abc/stream?static=true&api_key=GEHEIM123&mediaSourceId=xy"))
        let text = url.withoutSecret
        #expect(!text.contains("GEHEIM123"))
        // The rest must stay readable, otherwise the log is useless.
        #expect(text.contains("static=true"))
        #expect(text.contains("mediaSourceId=xy"))
        #expect(text.contains("/Videos/abc/stream"))
    }

    @Test("Entfernt auch das Quick-Connect-Geheimnis")
    func blacksOutSecret() throws {
        let url = try #require(URL(string:
            "https://tv.example.de/QuickConnect/Connect?secret=ABC"))
        #expect(!url.withoutSecret.contains("ABC"))
    }

    @Test("Adressen ohne Abfrage bleiben unverändert")
    func letsHarmlessInIdle() throws {
        let url = try #require(URL(string: "https://tv.example.de/System/Info/Public"))
        #expect(url.withoutSecret == "https://tv.example.de/System/Info/Public")
    }
}

// MARK: - Source selection

@Suite("Plan waehlt die verlustfreie Quelle")
struct SourcesSelectionTests {

    private func source(_ id: String, direct: Bool, feed: Bool = false) -> MediaSource {
        MediaSource(id: id, name: id, container: "mkv", size: 1,
                    supportsDirectPlay: direct, supportsDirectStream: feed,
                    supportsTranscoding: true, transcodingUrl: "/t.m3u8",
                    mediaStreams: [])
    }

    private func plan(_ sources: [MediaSource]) throws -> PlaybackPlan? {
        try PlaybackPlan.make(
            from: PlaybackInfoResponse(mediaSources: sources, playSessionId: "s"),
            itemID: "abc",
            profile: .vlc(),
            streamURL: { id, source, _ in
                URL(string: "https://x.de/Videos/\(id)/stream?mediaSourceId=\(source ?? "")")!
            },
            serverBase: URL(string: "https://x.de")!)
    }

    /// With several versions of a movie, a common setup in Jellyfin, the
    /// first one used to be taken blindly. If that happened to be the one that
    /// needed conversion, the app converted even though another version
    /// next to it played directly.
    @Test("Nimmt die direkt abspielbare Fassung, nicht die erste")
    func preferredDirectPlay() throws {
        let result = try #require(try plan([
            source("umwandeln", direct: false),
            source("direkt", direct: true),
        ]))
        #expect(result.method == .directPlay)
        #expect(result.mediaSourceID == "direkt")
    }

    @Test("Direct Stream schlaegt Umwandeln")
    func preferredDirectStream() throws {
        let result = try #require(try plan([
            source("umwandeln", direct: false),
            source("umpacken", direct: false, feed: true),
        ]))
        #expect(result.method == .directStream)
        #expect(result.mediaSourceID == "umpacken")
    }

    /// On a tie the server's order stays; it already sorts sensibly
    /// itself.
    @Test("Bei Gleichstand bleibt die erste Quelle")
    func keepsRailsEpisode() throws {
        let result = try #require(try plan([
            source("eins", direct: true),
            source("zwei", direct: true),
        ]))
        #expect(result.mediaSourceID == "eins")
    }

    @Test("Ohne Quelle kein Plan")
    func withoutSource() throws {
        #expect(try plan([]) == nil)
    }
}

// MARK: - Server address

@Suite("Serveradresse")
struct ServerAddressTests {

    /// Most self-hosted Jellyfin servers run in the home network without
    /// a certificate. Typing the address without a scheme used to give
    /// `https://` and an error whose cause was impossible to guess.
    @Test("IP-Adressen bekommen http, nicht https")
    func ipGetsHTTP() throws {
        let url = try #require(AppModelURLNormalizer.normalize("192.168.1.5:8096"))
        #expect(url.scheme == "http")
        #expect(url.host() == "192.168.1.5")
        #expect(url.port == 8096)
    }

    @Test("Namen im Heimnetz bekommen http")
    func localGetsHTTP() throws {
        let url = try #require(AppModelURLNormalizer.normalize("kiste.local:8096"))
        #expect(url.scheme == "http")
    }

    @Test("Oeffentliche Namen bekommen https")
    func publicGetsHTTPS() throws {
        let url = try #require(AppModelURLNormalizer.normalize("jellyfin.example.com"))
        #expect(url.scheme == "https")
    }

    @Test("Ein angegebenes Schema wird nicht angetastet")
    func schemaStays() throws {
        #expect(AppModelURLNormalizer.normalize("http://tv.example.de")?.scheme == "http")
        #expect(AppModelURLNormalizer.normalize("https://192.168.1.5")?.scheme == "https")
    }

    @Test("Ausweichadresse fuer den zweiten Versuch")
    func alternate() throws {
        let url = try #require(AppModelURLNormalizer.normalize("tv.example.de"))
        #expect(AppModelURLNormalizer.reversed(url)?.scheme == "http")
        // Whoever is already on http needs no fallback address.
        let localOnly = try #require(AppModelURLNormalizer.normalize("192.168.1.5"))
        #expect(AppModelURLNormalizer.reversed(localOnly) == nil)
    }

    /// **Tailscale assigns addresses from 100.64.0.0/10, the CGNAT range.**
    ///
    /// A user reached their Jellyfin at `100.110.192.87:8096` and could not
    /// get through. The normalizer was not at fault: every IP literal counts
    /// as home network, so `http://` is prepended, and that is correct.
    /// ATS blocked it: `NSAllowsLocalNetworking` covers RFC1918, `.local`
    /// and `localhost`, but **not** CGNAT, and its mere presence
    /// switched off `NSAllowsArbitraryLoads`. The test pins down the half
    /// that can be checked here; the other half lives in Info.plist.
    @Test("IPv6-Adressen gelten als Heimnetz und bekommen Klammern")
    func ipv6() throws {
        #expect(AppModelURLNormalizer.isHomeNetwork("[fd00::5]:8096"))
        #expect(AppModelURLNormalizer.isHomeNetwork("fd00::5"))
        #expect(AppModelURLNormalizer.isHomeNetwork("fe80::1%en0"))
        #expect(!AppModelURLNormalizer.isHomeNetwork("jellyfin.example.com:8096"))
        let bare = try #require(AppModelURLNormalizer.normalize("fd00::5"))
        #expect(bare.scheme == "http")
        let withPort = try #require(AppModelURLNormalizer.normalize("[fd00::5]:8096"))
        #expect(withPort.scheme == "http")
        #expect(withPort.port == 8096)
    }

    @Test("Ein Anfuehrungszeichen im Geraetenamen bricht den Kopf nicht auf")
    func headerValueMasked() {
        #expect(JellyfinClient.headerValue(#"Pauls "Kiste""#) == "Pauls 'Kiste'")
        #expect(JellyfinClient.headerValue("Zeile\nzwei") == "Zeilezwei")
        #expect(JellyfinClient.headerValue("Wohnzimmer-TV") == "Wohnzimmer-TV")
    }

    @Test func tailscaleAddressGoesOverHTTP() throws {
        #expect(AppModelURLNormalizer.isHomeNetwork("100.110.192.87"))
        let url = try #require(AppModelURLNormalizer.normalize("100.110.192.87:8096"))
        #expect(url.scheme == "http")
        #expect(url.port == 8096)
    }
}

// MARK: - Tracks and languages

@Suite("Spurbeschriftung")
struct TrackTests {

    private func track(_ language: String?, codec: String?, channels: Int?) -> MediaStream {
        MediaStream(codec: codec, type: "Audio", language: language, displayTitle: nil,
                    channels: channels, isDefault: nil, index: 0, height: nil, width: nil)
    }

    /// With zero channels the line used to show "-1.1".
    @Test("Kaputte Kanalzahl erzeugt keinen Unsinn")
    func nullChannels() {
        #expect(!track("ger", codec: "ac3", channels: 0).short.contains("-1"))
        #expect(!track("ger", codec: "ac3", channels: nil).short.contains("-1"))
        #expect(track("ger", codec: "ac3", channels: 2).short.contains("Stereo"))
        #expect(track("ger", codec: "dts", channels: 6).short.contains("5.1"))
        #expect(track("ger", codec: "dts", channels: 8).short.contains("7.1"))
    }

    /// `contains` on the display name made "Slovenian" count as English,
    /// because it contains "en".
    @Test("Sprachabgleich trifft keine Teilwoerter")
    func noPartWords() {
        #expect(Language.fits("English", toward: "English"))
        #expect(Language.fits("eng", toward: "English"))
        #expect(Language.fits("Deutsch (Kommentar)", toward: "Deutsch"))
        #expect(!Language.fits("Slovenian", toward: "English"))
        #expect(!Language.fits("Armenian", toward: "English"))
        #expect(!Language.fits("Italiano", toward: "Deutsch"))
    }
}

// MARK: - Lenient decoding

@Suite("Antworten mit Luecken")
struct InReadTests {

    /// A single entry without a name used to make the **whole** list
    /// fail; the screen stayed empty without any message.
    @Test("Ein kaputter Eintrag kippt nicht die ganze Liste")
    func brokenEntry() throws {
        let json = """
        {"Items":[{"Id":"a","Name":"Guter Film"},{"Id":"b"},{"Id":"c","Name":"Noch einer"}],
         "TotalRecordCount":3}
        """
        let answer = try JSONDecoder().decode(ItemsResponse.self, from: Data(json.utf8))
        #expect(answer.items.count == 2)
        #expect(answer.items.map(\.id) == ["a", "c"])
    }

    /// `TotalRecordCount` is missing on some endpoints. Decoded as
    /// non-optional, the whole response failed.
    @Test("Fehlende Gesamtzahl ist kein Grund zu scheitern")
    func withoutTotalNumber() throws {
        let json = #"{"Items":[{"Id":"a","Name":"Film"}]}"#
        let answer = try JSONDecoder().decode(ItemsResponse.self, from: Data(json.utf8))
        #expect(answer.items.count == 1)
        #expect(answer.totalRecordCount == 1)
    }
}

// MARK: - Frame rate in the stream

/// **A side detail must not prevent playback.**
///
/// `RealFrameRate` is only needed so the TV switches its output early
/// enough. If unwrapping it throws, the whole response fails and the
/// title cannot be played at all, with nothing pointing to the frame
/// rate.
@Suite("Bildrate im Medienstrom")
struct FrameRateTests {
    private func feed(_ content: String) throws -> MediaStream {
        let json = """
        {"Codec":"h264","Type":"Video","Width":1920,"Height":1080,\(content)}
        """
        return try JSONDecoder().decode(MediaStream.self, from: Data(json.utf8))
    }

    @Test("Nimmt die Zahl, wie sie im Datenblatt steht")
    func asNumber() throws {
        #expect(try feed("\"RealFrameRate\":23.976").frameRate == 23.976)
    }

    @Test("Nimmt sie auch als Zeichenkette")
    func asText() throws {
        #expect(try feed("\"RealFrameRate\":\"25\"").frameRate == 25)
    }

    @Test("Unbrauchbares wirft nicht, es fehlt nur")
    func unusable() throws {
        #expect(try feed("\"RealFrameRate\":true").frameRate == nil)
        #expect(try feed("\"RealFrameRate\":null").frameRate == nil)
        #expect(try feed("\"RealFrameRate\":{\"a\":1}").frameRate == nil)
    }

    @Test("Fehlt sie ganz, bleibt der Strom trotzdem lesbar")
    func missing() throws {
        #expect(try feed("\"Index\":0").frameRate == nil)
    }

    @Test("Schwankende Bildrate meldet lieber nichts")
    func fluctuating() throws {
        let strong = try feed("\"RealFrameRate\":30,\"AverageFrameRate\":24")
        #expect(strong.frameRate == nil)
        let lightweight = try feed("\"RealFrameRate\":23.976,\"AverageFrameRate\":24")
        #expect(lightweight.frameRate == 23.976)
    }
}

// MARK: - Profile for remuxing

/// **Remuxing does not mean transcoding.**
///
/// The profile for the server jump may only allow the server to put the
/// same stream into a different container. If it names codecs other than
/// the ones played directly anyway, the server re-encodes the picture,
/// which is exactly what this app exists to avoid.
