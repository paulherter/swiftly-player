import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import JellyfinKit

/// The forwarder in front of VLC (issue #4) against a gateway proxy in the test.
///
/// The proxy here lets through only whoever brings `X-PreItem: offen`,
/// otherwise 403, like Cloudflare Access with a service token. Each test
/// builds its own on its own port; the table of headers is
/// shared, and the port keeps the entries apart.
///
/// **One after the other, and blocking only on their own threads.** The raw
/// sockets block; if they ran in parallel on the cooperative pool,
/// it would fill up and `URLSession` in the forwarder could no longer get
/// a slot (measured: all connections hung in `waitResponse`).
extension SharedHeaderPanel {
@Suite("Stromweiterleiter", .serialized)
struct StreamNextLeaderTests {

    /// 1 MiB, every byte derivable from its position.
    static let file = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })

    @Test("Ohne eingetragene Header bleibt die Adresse, wie sie ist")
    func withoutHeaders() throws {
        let w = StreamForwarder()
        let u = try #require(URL(string: "https://ohne-koepfe.test/Videos/1/stream.mkv?static=true"))
        #expect(w.address(for: u) == u)
        #expect(w.currentPort == 0)
    }

    @Test("Header gehen mit, der Vorposten lässt durch; direkt nicht")
    func headersGoWith() throws {
        let entries = try PreItem()
        let w = StreamForwarder()
        let direct = entries.url("/Videos/1/stream.mkv?static=true&api_key=geheim")
        #expect(raw(port: entries.port, path: "/Videos/1/stream.mkv").status == 403)

        let redirected = w.address(for: direct)
        #expect(redirected.host == "127.0.0.1")
        #expect(redirected.port.map(UInt16.init) == w.currentPort)
        #expect(redirected.path.hasSuffix("/Videos/1/stream.mkv"))
        #expect(redirected.query == "static=true&api_key=geheim")

        let a = raw(url: redirected)
        #expect(a.status == 200)
        #expect(a.fields["content-length"] == "\(Self.file.count)")
        // Compared as a boolean, not as `Data`: if the comparison fails,
        // Swift Testing would otherwise compute the difference of two MiB
        // byte by byte, quadratically. Under load the whole test run hung
        // on it for minutes instead of turning red.
        #expect(a.body.count == Self.file.count)
        #expect(a.body.elementsEqual(Self.file))
        #expect(entries.lastQuery == "static=true&api_key=geheim")
    }

    @Test("Range geht 1:1 durch, auch auf mehreren Verbindungen gleichzeitig")
    func section() throws {
        let entries = try PreItem()
        let w = StreamForwarder()
        let u = w.address(for: entries.url("/Videos/1/stream.mkv"))
        let done = DispatchSemaphore(value: 0)
        for i in 0..<6 {
            Thread {
                let from = i * 100_000 + 17, until = from + 4_999
                let a = raw(url: u, range: "bytes=\(from)-\(until)")
                #expect(a.status == 206)
                #expect(a.fields["content-range"] == "bytes \(from)-\(until)/\(Self.file.count)")
                #expect(a.fields["accept-ranges"] == "bytes")
                #expect(a.body.elementsEqual(Self.file.subdata(in: from..<(until + 1))),
                        "\(a.body.count) Byte statt \(until + 1 - from)")
                done.signal()
            }.start()
        }
        for _ in 0..<6 { done.wait() }
    }

    @Test("Falsche Marke: 404, der Server sieht nichts")
    func wrongMark() throws {
        let entries = try PreItem()
        let w = StreamForwarder()
        let u = w.address(for: entries.url("/Videos/1/stream.mkv"))
        let mark = u.pathComponents[1]
        let wrong = String(mark.reversed())
        let a = raw(port: w.currentPort, path: "/\(wrong)/Videos/1/stream.mkv")
        #expect(a.status == 404)
        #expect(raw(port: w.currentPort, path: "/Videos/1/stream.mkv").status == 404)
        #expect(entries.askFor == 0)
    }

    @Test("Schließt VLC die Verbindung, bricht die Anfrage beim Server ab")
    func abort() async throws {
        let entries = try PreItem()
        let w = StreamForwarder()
        let u = w.address(for: entries.url("/endlos"))
        let v = try #require(Plug.linkUp(port: UInt16(u.port ?? 0)))
        Plug.dispatch(v, Data("GET \(u.path) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8))
        var buffer = [UInt8](repeating: 0, count: 65536)
        var hasRead = 0
        while hasRead < 200_000 {
            let n = Plug.read(v, &buffer)
            if n <= 0 { break }
            hasRead += n
        }
        #expect(hasRead >= 200_000)
        Plug.close(v)
        // The proxy notices when its send fails.
        for _ in 0..<100 where !entries.endlessCancelled {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(entries.endlessCancelled)
    }

    @Test("Liest VLC nicht (Pause), puffert der Weiterleiter nicht die ganze Datei")
    func againstPress() async throws {
        let entries = try PreItem()
        let w = StreamForwarder()
        let u = w.address(for: entries.url("/endlos"))
        let v = try #require(Plug.linkUp(port: UInt16(u.port ?? 0)))
        defer { Plug.close(v) }
        Plug.dispatch(v, Data("GET \(u.path) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8))
        var buffer = [UInt8](repeating: 0, count: 65536)
        #expect(Plug.read(v, &buffer) > 0)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let a = entries.endlessSent
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let b = entries.endlessSent
        // Stands still. Usually suspending keeps the server at a good 8 MiB plus
        // socket buffer; over loopback, though, URLSession sometimes delivers tens of
        // megabytes more after `suspend()` (measured: 72 MB sent).
        // Then the upper limit applies and the request ends; VLC starts again
        // via Range. On Linux and Windows the forwarder fetches in
        // chunks; at most two of them are outstanding at the server.
        // Either way the whole file is not buffered.
        #expect(b - a < 1 << 20)
        #expect(b < StreamForwarder.upperLimit + (16 << 20))
    }

    @Test("Über mehrere Stücke hinweg kommt jedes Byte an seiner Stelle an")
    func pieceLimits() throws {
        let entries = try PreItem()
        let w = StreamForwarder()
        let u = w.address(for: entries.url("/endlos"))
        let since = StreamForwarder.piece - 1000
        let v = try #require(Plug.linkUp(port: UInt16(u.port ?? 0)))
        defer { Plug.close(v) }
        Plug.dispatch(v, Data("GET \(u.path) HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=\(since)-\r\n\r\n".utf8))
        let total = 100_000 * 16384
        let should = 2 * StreamForwarder.piece + 5000
        var receive = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while receive.count < should + 4096 {
            let n = Plug.read(v, &buffer)
            if n <= 0 { break }
            receive.append(contentsOf: buffer[0..<n])
        }
        let separator = receive.range(of: Data([13, 10, 13, 10]))
        let headerEnd = try #require(separator).lowerBound
        let header = String(decoding: receive[..<headerEnd], as: UTF8.self)
        #expect(header.hasPrefix("HTTP/1.1 206"))
        #expect(header.contains("Content-Range: bytes \(since)-\(total - 1)/\(total)"))
        #expect(header.contains("Content-Length: \(total - since)"))
        let body = Data(receive[(headerEnd + 4)...])
        #expect(body.count >= should)
        // Compare against the pattern in windows; byte by byte is too slow
        // in a debug build.
        var wrong: Int?
        var spot = 0
        while spot < should, wrong == nil {
            let o = (since + spot) % endlessPeriod
            let n = min(endlessPeriod, should - spot)
            if body[spot..<(spot + n)] != endlessMuster[o..<(o + n)] { wrong = spot }
            spot += n
        }
        #expect(wrong == nil)
    }

    @Test("Range-Köpfe lesen")
    func areas() {
        #expect(StreamForwarder.sectionRead(nil)! == (0, nil))
        #expect(StreamForwarder.sectionRead("bytes=100-")! == (100, nil))
        #expect(StreamForwarder.sectionRead("bytes=100-199")! == (100, 199))
        #expect(StreamForwarder.sectionRead("bytes=-500") == nil)
        #expect(StreamForwarder.sectionRead("bytes=0-1,5-9") == nil)
        #expect(StreamForwarder.contentSectionRead("bytes 0-99/1000")! == (0, 99, 1000))
        #expect(StreamForwarder.contentSectionRead("bytes 0-99/*") == nil)
        #expect(StreamForwarder.pieceEnd(since: 10, until: 20) == 20)
        #expect(StreamForwarder.pieceEnd(since: 10, until: nil) == 10 + StreamForwarder.piece - 1)
    }

    @Test("HLS: relative Adressen bleiben, absolute und wurzelbezogene laufen über den Weiterleiter")
    func list() throws {
        let entries = try PreItem()
        let w = StreamForwarder()
        let u = w.address(for: entries.url("/Videos/1/master.m3u8?api_key=geheim"))
        let mark = u.pathComponents[1]
        let a = raw(url: u)
        #expect(a.status == 200)
        let text = String(decoding: a.body, as: UTF8.self)
        let rows = text.components(separatedBy: "\n")
        #expect(rows.contains("main.m3u8?api_key=geheim"))
        #expect(rows.contains("/\(mark)/Videos/1/hls/0.ts"))
        #expect(rows.contains("http://127.0.0.1:\(w.currentPort)/\(mark)/Videos/1/hls/1.ts"))
        #expect(rows.contains("https://fremd.test/werbung.ts"))
        #expect(text.contains("URI=\"/\(mark)/Videos/1/init.mp4\""))
        #expect(a.fields["content-length"] == "\(a.body.count)")
    }

    @Test("Anfragekopf: Verfahren, Ziel, Namen klein")
    func requestHeader() throws {
        let k = try #require(RequestHeader.dismantle("GET /a/b?c=d HTTP/1.1\r\nRange: bytes=0-\r\nUser-Agent: VLC\r\n\r\n"))
        #expect(k.procedure == "GET")
        #expect(k.target == "/a/b?c=d")
        #expect(k.headers["range"] == "bytes=0-")
        #expect(k.headers["user-agent"] == "VLC")
    }
}
}

// MARK: - Tooling

private struct RawResponse {
    var status = 0
    var fields: [String: String] = [:]
    var body = Data()
}

/// Content of `/endlos`: the period is a prime, not a multiple of a
/// chunk size, so a shifted chunk shows up.
let endlessPeriod = 65521
let endlessMuster = Data((0..<(2 * endlessPeriod)).map { UInt8(truncatingIfNeeded: ($0 % endlessPeriod) &* 31 &+ 7 &+ ($0 % endlessPeriod) >> 8) })
func endlessByte(_ i: Int) -> UInt8 { endlessMuster[i % endlessPeriod] }

private func raw(url: URL, range: String? = nil) -> RawResponse {
    var path = url.path
    if let q = url.query { path += "?" + q }
    return raw(port: UInt16(url.port ?? 0), path: path, range: range)
}

/// A request the way VLC makes it, over a raw socket.
private func raw(port: UInt16, path: String, range: String? = nil) -> RawResponse {
    guard let v = Plug.linkUp(port: port) else { return RawResponse() }
    defer { Plug.close(v) }
    var header = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nUser-Agent: VLC/4.0.0\r\n"
    if let range { header += "Range: \(range)\r\n" }
    Plug.dispatch(v, Data((header + "\r\n").utf8))
    var everything = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = Plug.read(v, &buffer)
        if n <= 0 { break }
        everything.append(contentsOf: buffer[0..<n])
    }
    guard let separator = everything.range(of: Data("\r\n\r\n".utf8)) else { return RawResponse() }
    let headerText = String(decoding: everything[..<separator.lowerBound], as: UTF8.self)
    var a = RawResponse()
    let rows = headerText.components(separatedBy: "\r\n")
    a.status = Int(rows.first?.split(separator: " ").dropFirst().first ?? "") ?? 0
    for z in rows.dropFirst() {
        guard let d = z.firstIndex(of: ":") else { continue }
        a.fields[z[..<d].lowercased()] = z[z.index(after: d)...].trimmingCharacters(in: .whitespaces)
    }
    a.body = Data(everything[separator.upperBound...])
    return a
}

/// A server behind a gateway proxy: without `X-PreItem: offen` it answers 403.
private final class PreItem: @unchecked Sendable {
    let port: UInt16
    private let grip: Plug.Handle
    private let barrier = NSLock()
    private var _request = 0
    private var _lastQuery: String?
    private var _endlessCancelled = false
    private var _endlessSent = 0

    var askFor: Int { barrier.lock(); defer { barrier.unlock() }; return _request }
    var lastQuery: String? { barrier.lock(); defer { barrier.unlock() }; return _lastQuery }
    var endlessCancelled: Bool { barrier.lock(); defer { barrier.unlock() }; return _endlessCancelled }
    var endlessSent: Int { barrier.lock(); defer { barrier.unlock() }; return _endlessSent }

    struct Failure: Error {}

    init() throws {
        guard let (g, p) = Plug.eavesdrop(preferred: 0) else { throw Failure() }
        grip = g
        port = p
        OwnHeaders.setDown([OwnHeader(name: "X-Vorposten", value: "offen")], for: url("/"))
        let t = Thread { [self] in
            while let v = Plug.acceptConnection(grip) {
                Thread { self.operate(v); Plug.close(v) }.start()
            }
        }
        t.start()
    }

    deinit {
        OwnHeaders.setDown([], for: url("/"))
        Plug.close(grip)
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    private func operate(_ v: Plug.Handle) {
        guard let a = RequestHeader.read(v) else { return }
        guard a.headers["x-vorposten"] == "offen" else {
            Plug.dispatch(v, Data("HTTP/1.1 403 Forbidden\r\nContent-Type: text/html\r\nContent-Length: 5\r\nConnection: close\r\n\r\nnein!".utf8))
            return
        }
        let parts = a.target.split(separator: "?", maxSplits: 1)
        let path = String(parts.first ?? "")
        barrier.lock()
        _request += 1
        _lastQuery = parts.count > 1 ? String(parts[1]) : nil
        barrier.unlock()

        switch path {
        case "/endlos":
            // A very large file, every byte derivable from its position.
            // Range is served as Jellyfin does; without it the file comes in one piece.
            let total = 100_000 * 16384
            var from = 0, until = total - 1
            if let r = a.headers["range"], r.hasPrefix("bytes=") {
                let z = r.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
                from = Int(z[0]) ?? 0
                if z.count > 1, let b = Int(z[1]) { until = min(b, total - 1) }
                Plug.dispatch(v, Data("HTTP/1.1 206 Partial Content\r\nContent-Type: video/x-matroska\r\nAccept-Ranges: bytes\r\nETag: \"endlos\"\r\nContent-Range: bytes \(from)-\(until)/\(total)\r\nContent-Length: \(until - from + 1)\r\nConnection: close\r\n\r\n".utf8))
            } else {
                Plug.dispatch(v, Data("HTTP/1.1 200 OK\r\nContent-Type: video/x-matroska\r\nAccept-Ranges: bytes\r\nETag: \"endlos\"\r\nContent-Length: \(total)\r\nConnection: close\r\n\r\n".utf8))
            }
            var spot = from
            while spot <= until {
                let n = min(16384, until - spot + 1)
                let o = spot % endlessPeriod
                let piece = endlessMuster.subdata(in: o..<(o + n))
                guard Plug.dispatch(v, piece) else { break }
                spot += n
                barrier.lock(); _endlessSent += n; barrier.unlock()
            }
            barrier.lock(); _endlessCancelled = true; barrier.unlock()
        case "/Videos/1/master.m3u8":
            let list = """
            #EXTM3U
            #EXT-X-MAP:URI="/Videos/1/init.mp4"
            main.m3u8?api_key=geheim
            /Videos/1/hls/0.ts
            \(url("/Videos/1/hls/1.ts").absoluteString)
            https://fremd.test/werbung.ts
            """
            let d = Data(list.utf8)
            Plug.dispatch(v, Data("HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(d.count)\r\nConnection: close\r\n\r\n".utf8))
            Plug.dispatch(v, d)
        default:
            let file = SharedHeaderPanel.StreamNextLeaderTests.file
            var from = 0, until = file.count - 1, status = "200 OK", section = ""
            if let r = a.headers["range"], r.hasPrefix("bytes=") {
                let z = r.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
                from = Int(z[0]) ?? 0
                if z.count > 1, let b = Int(z[1]) { until = min(b, file.count - 1) }
                status = "206 Partial Content"
                section = "Content-Range: bytes \(from)-\(until)/\(file.count)\r\n"
            }
            Plug.dispatch(v, Data("HTTP/1.1 \(status)\r\nContent-Type: video/x-matroska\r\nAccept-Ranges: bytes\r\n\(section)Content-Length: \(until - from + 1)\r\nConnection: close\r\n\r\n".utf8))
            Plug.dispatch(v, file.subdata(in: from..<(until + 1)))
        }
    }
}
