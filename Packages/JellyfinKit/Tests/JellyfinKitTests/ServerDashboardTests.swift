import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import JellyfinKit

/// **The administrator's server page**: what is read from the server and what the cards say.
@Suite("Serverübersicht", .serialized)
struct ServerDashboardTests {

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { try TimestampFormat.read(from: $0) }
        return d
    }

    private func stream(_ json: String) throws -> ServerStream {
        try #require(try ServerStream.playing(Data("[\(json)]".utf8), decoder: decoder).first)
    }

    // MARK: Account

    @Test("Administrator kommt aus der Policy, fehlt sie, ist es keiner")
    func administrator() throws {
        let admin = try decoder.decode(AccountPreGift.self, from: Data(#"{"Policy":{"IsAdministrator":true}}"#.utf8))
        #expect(admin.isAdministrator == true)
        let none = try decoder.decode(AccountPreGift.self, from: Data(#"{"Configuration":{}}"#.utf8))
        #expect(none.isAdministrator == nil)
    }

    @Test("Nur Jellyfin bietet die Serverübersicht an")
    func capability() {
        #expect(ServerKind.jellyfin.capabilities.contains(.administration))
        #expect(!ServerKind.emby.capabilities.contains(.administration))
        #expect(!ServerKind.plex.capabilities.contains(.administration))
    }

    // MARK: Counts

    @Test("Auflösungen vom Plugin: Filme und Folgen zusammen, HD ist 720p und 1080p")
    func pluginResolutions() {
        let r = ResolutionCounts.plugin([
            "Movie": ["4K": 10, "1080p": 20, "720p": 5, "SD": 3, "HDR": 8, "DV": 2],
            "Episode": ["4K": 1, "1080p": 100, "720p": 50, "SD": 7, "HDR": 0, "DV": 0],
            "MusicVideo": ["4K": 99, "SD": 99],
        ])
        #expect(r == ResolutionCounts(uhd: 11, hd: 175, sd: 10))
    }

    @Test("Auflösungen aus Jellyfins Filtern: IsHd enthält 4K")
    func filterResolutions() {
        #expect(ResolutionCounts.filters(uhd: 4, hdOrBetter: 30, sd: 6) == ResolutionCounts(uhd: 4, hd: 26, sd: 6))
        #expect(ResolutionCounts.filters(uhd: 5, hdOrBetter: 3, sd: 0).hd == 0)
    }

    // MARK: Disks

    @Test("Ordner auf einem Laufwerk sind ein Laufwerk, unlesbare fehlen")
    func disks() throws {
        let json = """
        {"ProgramDataFolder":{"Path":"/config","FreeSpace":50,"UsedSpace":50,"DeviceId":"/"},
         "CacheFolder":{"Path":"/cache","FreeSpace":50,"UsedSpace":50,"DeviceId":"/"},
         "TranscodingTempFolder":{"Path":"/tmp/t","FreeSpace":-1,"UsedSpace":-1},
         "Libraries":[
           {"Id":"1","Name":"Filme","Folders":[{"Path":"/media/movies","FreeSpace":50,"UsedSpace":950,"DeviceId":"/media"}]},
           {"Id":"2","Name":"Serien","Folders":[{"Path":"/media/tv","FreeSpace":50,"UsedSpace":950,"DeviceId":"/media"},
                                                {"Path":"/usb/tv","FreeSpace":10,"UsedSpace":10}]}]}
        """
        let list = ServerDisk.disks(try decoder.decode(SystemStorage.self, from: Data(json.utf8)))
        #expect(list.map(\.id) == ["/media", "/usb/tv", "/"])
        #expect(list[0].uses == ["Filme", "Serien"] && list[0].total == 1000 && list[0].freeShare == 0.05)
        // The free share only, as "5%": no sizes, no mount point.
        #expect(list[0].freeText == "5%" && list[2].freeText == "50%")
        #expect(list[0].nearlyFull && !list[2].nearlyFull)
        #expect(list[2].uses == ["Jellyfin"])
    }

    // MARK: Tasks and logs

    @Test("Nur laufende Aufgaben, die weiteste zuerst")
    func tasks() throws {
        let json = #"[{"Id":"a","Name":"Scan","State":"Running","CurrentProgressPercentage":12.4},"#
            + #"{"Id":"b","Name":"Idle","State":"Idle"},{"Id":"c","Name":"Trickplay","State":"Running","CurrentProgressPercentage":80}]"#
        let running = ServerTask.running(try decoder.decode([ServerTask].self, from: Data(json.utf8)))
        #expect(running.map(\.id) == ["c", "a"])
        #expect(running[1].progressText == "12 %")
    }

    @Test("Vom Protokoll das Ende, ab einem Zeilenanfang")
    func logTail() {
        let text = "erste\nzweite\ndritte\n"
        #expect(ServerLogFile.tail(Data(text.utf8), limit: 100) == text)
        #expect(ServerLogFile.tail(Data(text.utf8), limit: 10) == "dritte\n")
    }

    // MARK: Streams

    private let film = """
    {"Id":"s1","UserId":"u","UserName":"Andrey","Client":"Jellyfin Web","DeviceName":"Safari",
     "RemoteEndPoint":"172.30.212.2",
     "NowPlayingItem":{"Id":"m","Name":"Tenzing","Type":"Movie","ProductionYear":2026,"RunTimeTicks":75330000000,
       "ImageTags":{"Primary":"t"},
       "MediaStreams":[{"Type":"Video","Codec":"hevc","Width":3840,"Height":1600,"VideoRangeType":"DOVIWithHDR10","BitRate":25000000,"Index":0},
                       {"Type":"Audio","Codec":"ac3","Channels":6,"BitRate":640000,"Index":1},
                       {"Type":"Audio","Codec":"aac","Channels":2,"Index":2}]},
     "PlayState":{"PositionTicks":0,"IsPaused":true,"PlayMethod":"Transcode","AudioStreamIndex":1},
     "TranscodingInfo":{"IsVideoDirect":true,"IsAudioDirect":true,"Bitrate":26400000,"Framerate":241,
       "HardwareAccelerationType":"qsv","TranscodeReasons":["ContainerNotSupported"]}}
    """

    @Test("Die Abzeichen beschreiben die Datei, die Bitrate steht bei der Art der Wiedergabe")
    func badges() throws {
        let s = try stream(film)
        #expect(s.badges.map(\.kind) == [.resolution, .range, .video, .audio])
        #expect(s.badges.map(\.text) == ["4K", "DV", "HEVC", "AC-3 5.1"])
        #expect(s.deliveryLine.hasSuffix(" · 26 Mb/s"))
        #expect(s.title == "Tenzing" && s.titleAddition == "2026" && s.subtitle == nil)
        #expect(s.deviceLine == "Safari · Jellyfin Web · 172.30.212.2")
        #expect(s.posterID == "m" && s.posterTag == "t")
    }

    @Test("Nur ein neuer Container ist Direct Stream, echte Umwandlung ist Transcode")
    func remux() throws {
        #expect(try stream(film).delivery == .directStream)
        let json = film.replacingOccurrences(of: #""IsVideoDirect":true"#, with: #""IsVideoDirect":false"#)
        #expect(try stream(json).delivery == .transcode)
    }

    @Test("Direct Play zeigt die Bitrate der Spuren")
    func directPlay() throws {
        let json = film.replacingOccurrences(of: #""PlayMethod":"Transcode""#, with: #""PlayMethod":"DirectPlay""#)
            .replacingOccurrences(of: #""Bitrate":26400000,"#, with: "")
        let s = try stream(json)
        #expect(s.delivery == .directPlay)
        #expect(s.deliveryLine.hasSuffix(" · 26 Mb/s"))
    }

    @Test("Kurze Bitrate: ganze Mb/s ab zehn, eine Stelle darunter, kb/s unter einem")
    func shortRate() {
        #expect(ServerStream.shortRate(26_400_000) == "26 Mb/s")
        #expect(ServerStream.shortRate(4_540_000) == "4.5 Mb/s")
        #expect(ServerStream.shortRate(320_000) == "320 kb/s")
        #expect(ServerStream.shortRate(nil) == nil && ServerStream.shortRate(0) == nil)
    }

    @Test("Eine Folge zeigt die Serie, Staffel und Folge, und das Serienplakat")
    func episode() throws {
        let json = """
        {"Id":"s2","UserName":"Anna","NowPlayingItem":{"Id":"e","Name":"Pilot","Type":"Episode","SeriesName":"Lost",
          "SeriesId":"ser","SeriesPrimaryImageTag":"st","ParentIndexNumber":1,"IndexNumber":3,"RunTimeTicks":26000000000},
         "PlayState":{"PositionTicks":12000000000,"PlayMethod":"DirectPlay"}}
        """
        let s = try stream(json)
        #expect(s.title == "Lost" && s.subtitle == "Pilot")
        #expect(s.titleAddition?.contains("1") == true && s.titleAddition?.contains("3") == true)
        #expect(s.posterID == "ser" && s.posterTag == "st")
        #expect(s.timeLine == "20:00 / 43:20" && !s.paused)
        #expect(abs(s.share - 12.0 / 26.0) < 0.0001)
        #expect(s.id == "s2/e")
    }

    @Test("Sitzungen ohne Wiedergabe fallen weg, eine kaputte nimmt die anderen nicht mit")
    func onlyPlaying() throws {
        let json = #"[{"Id":"idle","UserName":"X"},{"Id":"bad","NowPlayingItem":{"Name":"no id"}},"#
            + #"{"Id":"ok","NowPlayingItem":{"Id":"i","Name":"Song","Type":"Audio","AlbumArtist":"Band","AlbumId":"al","AlbumPrimaryImageTag":"at"}}]"#
        let list = try ServerStream.playing(Data(json.utf8), decoder: decoder)
        #expect(list.map(\.sessionID) == ["ok"])
        #expect(list[0].titleAddition == "Band" && list[0].squarePoster && list[0].posterID == "al")
        #expect(list[0].timeLine == "0:00")
    }

    @Test("Uhrzeit mit Stunden nur, wenn das Ganze so lang ist")
    func clock() {
        #expect(ServerStream.clock(0, long: true) == "0:00:00")
        #expect(ServerStream.clock(7533, long: true) == "2:05:33")
        #expect(ServerStream.clock(65, long: false) == "1:05")
    }

    @Test("Auflösung nach Breite zuerst, Dynamik nur wenn nicht SDR")
    func resolutionAndRange() {
        #expect(ServerStream.resolution(width: 3840, height: 1600) == "4K")
        #expect(ServerStream.resolution(width: 1920, height: 800) == "1080p")
        #expect(ServerStream.resolution(width: 720, height: 576) == "SD")
        #expect(ServerStream.resolution(width: nil, height: nil) == nil)
        #expect(ServerStream.range("DOVIWithHDR10") == "DV" && ServerStream.range("HDR10Plus") == "HDR10+")
        #expect(ServerStream.range("SDR") == nil && ServerStream.range("DOVIInvalid") == nil)
    }

    // MARK: Requests

    final class Stub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var answers: [String: (Int, String)] = [:]
        nonisolated(unsafe) static var paths: [String] = []
        /// "METHOD /path" and the JSON body, in order.
        nonisolated(unsafe) static var calls: [(String, String)] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            let path = request.url?.path ?? ""
            Self.paths.append(path)
            Self.calls.append(("\(request.httpMethod ?? "") \(path)", Self.body(of: request)))
            let (status, body) = Self.answers[path] ?? (404, "")
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}

        /// `URLSession` hands the body to a protocol as a stream.
        static func body(of request: URLRequest) -> String {
            if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
            guard let stream = request.httpBodyStream else { return "" }
            stream.open(); defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    private func client() async -> JellyfinClient {
        Stub.paths = []
        Stub.calls = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        let c = JellyfinClient(baseURL: URL(string: "https://tv.example.de")!, deviceID: "d", deviceName: "P",
                               urlSession: URLSession(configuration: config))
        await c.setSession(Session(accessToken: "t", userID: "u1", userName: "T",
                                   serverURL: URL(string: "https://tv.example.de")!))
        return c
    }

    @Test("Ohne Plugin: Auflösungen aus den Filtern, keine Last, und danach wird nicht mehr gefragt")
    func withoutPlugin() async throws {
        Stub.answers = [
            "/System/Info": (200, #"{"ServerName":"lysnet","Version":"10.11.2"}"#),
            "/Items/Counts": (200, #"{"MovieCount":3,"SeriesCount":2,"EpisodeCount":40}"#),
            "/Items": (200, #"{"Items":[],"TotalRecordCount":5}"#),
            "/Sessions": (200, "[]"),
            "/ScheduledTasks": (200, "[]"),
        ]
        let c = await client()
        let once = try await c.dashboardOnce()
        #expect(once.system.name == "lysnet" && once.counts.episodes == 40)
        // Every filter answers 5 here: 4K 5, HD-or-better 5 → HD 0, SD 5.
        #expect(once.resolutions == ResolutionCounts(uhd: 5, hd: 0, sd: 5))
        let live = await c.dashboardLive()
        #expect(live.load == nil && live.disks.isEmpty && live.streams.isEmpty)
        Stub.paths = []
        _ = await c.dashboardLive()
        #expect(!Stub.paths.contains("/JellyTwiggy/SystemMetrics"))
    }

    @Test("Mit Plugin: Last und Auflösungen von dort")
    func withPlugin() async throws {
        Stub.answers = [
            "/System/Info": (200, #"{"ServerName":"lysnet","Version":"10.11.2"}"#),
            "/Items/Counts": (200, #"{"MovieCount":3}"#),
            "/JellyTwiggy/LibraryResolutions": (200, #"{"Movie":{"4K":2,"1080p":1,"SD":0,"HDR":1,"DV":1}}"#),
            "/JellyTwiggy/SystemMetrics": (200, #"{"CpuPercent":12.5,"MemoryPercent":40,"MemoryUsedBytes":4000000000,"MemoryTotalBytes":10000000000}"#),
        ]
        let c = await client()
        let once = try await c.dashboardOnce()
        #expect(once.resolutions == ResolutionCounts(uhd: 2, hd: 1, sd: 0))
        #expect(!Stub.paths.contains("/Items"))
        let live = await c.dashboardLive()
        #expect(live.load?.cpuPercent == 12.5 && live.load?.memoryPercent == 40)
        #expect(ServerLoad.percent(12.5) == "13%" && ServerLoad.percent(140) == "100%")
    }

    @Test("Eine Aufgabe anhalten ist DELETE auf die laufende Aufgabe")
    func stopTask() async throws {
        Stub.answers = ["/ScheduledTasks/Running/scan": (204, "")]
        let c = await client()
        try await c.stopTask(id: "scan")
        #expect(Stub.calls.map(\.0) == ["DELETE /ScheduledTasks/Running/scan"])
    }

    @Test("Wiedergabe anhalten: erst Stop, dann die Nachricht als Dialog ohne Zeitlimit")
    func stopPlayback() async throws {
        Stub.answers = ["/Sessions/s1/Playing/Stop": (204, ""), "/Sessions/s1/Message": (204, "")]
        let c = await client()
        try await c.stopPlayback(sessionID: "s1", message: "  Server wird gewartet.  ")
        #expect(Stub.calls.map(\.0) == ["POST /Sessions/s1/Playing/Stop", "POST /Sessions/s1/Message"])
        let body = try JSONSerialization.jsonObject(with: Data(Stub.calls[1].1.utf8)) as? [String: String]
        #expect(body?["Text"] == "Server wird gewartet." && body?["Header"]?.isEmpty == false)
        #expect(body?["TimeoutMs"] == nil)
    }

    @Test("Ohne Text keine Nachricht; scheitert sie, bleibt der Stop gültig")
    func stopWithoutMessage() async throws {
        Stub.answers = ["/Sessions/s1/Playing/Stop": (204, "")]
        let c = await client()
        try await c.stopPlayback(sessionID: "s1", message: " ")
        #expect(Stub.calls.map(\.0) == ["POST /Sessions/s1/Playing/Stop"])
        Stub.calls = []
        // The message route answers 404 here: no error, the stop went through.
        try await c.stopPlayback(sessionID: "s1", message: "Hallo")
        #expect(Stub.calls.count == 2)
    }

    @Test("Scheitert der Stop, geht keine Nachricht raus")
    func stopFails() async {
        Stub.answers = [:]
        let c = await client()
        await #expect(throws: JellyfinError.self) { try await c.stopPlayback(sessionID: "s1", message: "Hallo") }
        #expect(Stub.calls.count == 1)
    }
}
