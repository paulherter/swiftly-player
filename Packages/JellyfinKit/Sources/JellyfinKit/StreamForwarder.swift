import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#endif

/// **The forwarder in front of the player, for servers behind a gateway.**
///
/// Cloudflare Access, Authelia, Authentik or Pangolin only let through requests that
/// carry certain headers (``OwnHeaders``). API, images and downloads go through
/// `URLSession` and carry them. **VLC cannot:** libVLC only sets user agent, referrer
/// and cookies through options, no arbitrary headers, so the stream never got past
/// the gateway (issue #4).
///
/// So the app fetches the stream itself: a small HTTP service on
/// `127.0.0.1:<random port>` accepts VLC's request, fetches the same URL from the
/// server with the headers, and passes on status, the headers VLC needs for seeking,
/// and the body, **streamed**.
///
/// - **Only if headers are configured.** Otherwise ``address(fuer:)`` returns the URL
///   unchanged and VLC talks directly to the server as usual. For almost everyone
///   nothing changes.
/// - **Only on 127.0.0.1**, and every server gets a random token (128 bit) as the first
///   path component. Another app on the device can reach the port but does not know
///   the token and gets 404.
/// - **One connection, one thread.** VLC opens its own connections for seeking and
///   subtitles; each runs on its own, blocking, and ends with `Connection: close`.
/// - **Range passes through 1:1**, `Content-Range` and `Content-Length` come back
///   unchanged. When fetching in pieces (below), the forwarder derives them from the
///   total length to match what VLC asked.
/// - **No buffering of whole files.** If VLC does not read (pause), on Apple the
///   forwarder pauses the request to the server once 8 MiB are waiting. If the backlog
///   grows past 64 MiB it aborts; VLC resumes with `:http-reconnect` and a Range at
///   exactly that point. On Linux and Windows (swift-corelibs) `suspend()` stops
///   nothing and `cancel()` only takes effect once much more has been loaded (hundreds
///   of MB over loopback under load). There it fetches in pieces of 16 MiB instead,
///   each with its own Range, the next only once VLC has taken the previous one. Only
///   if the server does not serve Range does the upper limit remain.
/// - **Abort:** if VLC closes the connection, the next send fails and the request to
///   the server is cancelled.
/// - **HLS:** relative segment URLs go through the forwarder by themselves. Absolute
///   and root-relative ones (`/…`) are rewritten in playlists.
///
/// **The same code on Apple, Linux and Windows**: only BSD sockets and `URLSession`,
/// no further dependency. Network.framework exists only on Apple, and SwiftNIO would be
/// a heavy dependency in the Android core for a service with a handful of connections.
/// Android itself no longer uses it: there a forwarder reads over OkHttp in blocking
/// mode, so pause and abort take effect immediately
/// (`Android/phone/…/StreamForwarder.kt`).
public final class StreamForwarder: @unchecked Sendable {

    /// The one for the app. Tests build their own.
    public static let gemeinsam = StreamForwarder()

    /// Where the forwarder reports what it does: **never values, never queries**, only
    /// method, path and status. The app attaches its log here.
    public nonisolated(unsafe) static var log: (@Sendable (String) -> Void)?

    private let barrier = NSLock()
    private var listener: Plug.Handle?
    private var port: UInt16 = 0
    /// Token → origin (`https://host[:port]`), and back.
    private var originMark: [String: String] = [:]
    private var markOrigin: [String: String] = [:]
    private let session: URLSession
    private let distributor = Splitter()

    init() {
        let k = URLSessionConfiguration.default
        k.urlCache = nil
        k.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Idle time, not total duration: a film runs for hours.
        k.timeoutIntervalForRequest = 60
        k.httpMaximumConnectionsPerHost = 16
        // **Serial, and it stays that way.** The suspicion was that subtitles wait for the
        // video here. They do not: the callbacks of the `Splitter` only put a piece into the
        // connection's buffer and return; sending happens on each connection's own thread.
        // A concurrent queue, by contrast, may let `URLSession` deliver the pieces of one task
        // in any order, and Apple explicitly requires a serial one for the delegate. In the
        // video that would mean swapped bytes.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: k, delegate: distributor, delegateQueue: queue)
    }

    // MARK: Address

    /// The address VLC should get.
    ///
    /// Unchanged if no headers are configured for the server, if it is not `http(s)`
    /// (downloads exist as files) or if the forwarder cannot listen; playback then fails
    /// at the gateway as before instead of not starting at all.
    public func address(for url: URL) -> URL {
        guard !OwnHeaders.of(url).isEmpty,
              let k = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let schema = k.scheme?.lowercased(), schema == "http" || schema == "https",
              let computer = k.percentEncodedHost, !computer.isEmpty
        else { return url }
        let provenance = "\(schema)://\(computer)" + (k.port.map { ":\($0)" } ?? "")

        barrier.lock()
        defer { barrier.unlock() }
        guard let port = listenLocked() else { return url }
        let mark: String
        if let m = markOrigin[provenance] {
            mark = m
        } else {
            mark = Self.newMark()
            markOrigin[provenance] = mark
            originMark[mark] = provenance
        }
        let path = k.percentEncodedPath.isEmpty ? "/" : k.percentEncodedPath
        let query = k.percentEncodedQuery.map { "?" + $0 } ?? ""
        return URL(string: "http://127.0.0.1:\(port)/\(mark)\(path)\(query)") ?? url
    }

    /// The port currently listened on, 0 while not.
    var currentPort: UInt16 {
        barrier.lock(); defer { barrier.unlock() }
        return listener == nil ? 0 : port
    }

    /// From VLC's request path the address at the server, `nil` for a wrong token.
    func target(for requestPath: String) -> (url: URL, mark: String)? {
        guard requestPath.hasPrefix("/") else { return nil }
        let without = requestPath.dropFirst()
        let end = without.firstIndex(where: { $0 == "/" || $0 == "?" }) ?? without.endIndex
        let mark = String(without[..<end])
        var rest = String(without[end...])
        if !rest.hasPrefix("/") { rest = "/" + rest }
        barrier.lock()
        let provenance = originMark[mark]
        barrier.unlock()
        guard let provenance, let url = URL(string: provenance + rest) else { return nil }
        return (url, mark)
    }

    private static func newMark() -> String {
        var random = SystemRandomNumberGenerator()
        return (0..<16).map { _ in
            let b = UInt8.random(in: 0...255, using: &random)
            return String(b, radix: 16).count == 1 ? "0" + String(b, radix: 16) : String(b, radix: 16)
        }.joined()
    }

    // MARK: Listening

    /// Starts the listener if it is not running. **The caller holds the lock.**
    ///
    /// After a restart, the same port first: iOS takes the listening socket away from a
    /// suspended app, and VLC may still hold a URL with the old port.
    private func listenLocked() -> UInt16? {
        if listener != nil { return port }
        guard let (grip, new) = Plug.eavesdrop(preferred: port) else {
            Self.log?("[Weiterleiter] Lauschen gescheitert")
            return nil
        }
        listener = grip
        port = new
        Self.log?("[Weiterleiter] lauscht auf 127.0.0.1:\(new)")
        let t = Thread { [weak self] in self?.accept(grip) }
        t.name = "Stromweiterleiter"
        t.start()
        return new
    }

    private func accept(_ grip: Plug.Handle) {
        while true {
            guard let connection = Plug.acceptConnection(grip) else {
                if Plug.anotherTime() { continue }
                barrier.lock()
                if listener == grip { listener = nil }
                barrier.unlock()
                Plug.close(grip)
                Self.log?("[Weiterleiter] Lauscher beendet")
                return
            }
            let t = Thread { [weak self] in
                self?.operate(connection)
                Plug.close(connection)
            }
            t.name = "Stromweiterleiter.Verbindung"
            t.start()
        }
    }

    // MARK: One connection

    /// Waiting bytes at which the request to the server is paused.
    static let haltOff = 8 << 20
    /// … and at which it resumes.
    static let nextOff = 2 << 20
    /// Hard limit: above it, abort; VLC resumes with a Range.
    static let upperLimit = 64 << 20
    /// Playlists are small; anything bigger is not one.
    static let listsLimit = 4 << 20

    private func operate(_ v: Plug.Handle) {
        Plug.readDeadline(v, seconds: 30)
        guard let petition = RequestHeader.read(v) else { return }
        guard petition.procedure == "GET" || petition.procedure == "HEAD" else {
            Plug.dispatch(v, Self.header(405, ["Allow": "GET, HEAD"], length: 0)); return
        }
        guard let (url, mark) = target(for: petition.target) else {
            Self.log?("[Weiterleiter] fremde Marke abgewiesen")
            Plug.dispatch(v, Self.header(404, [:], length: 0)); return
        }

        var r = URLRequest(url: url)
        r.httpMethod = petition.procedure
        // Passed through unchanged what matters for seeking. Everything else (cookies,
        // Icy-MetaData) stays out.
        for name in ["Range", "If-Range", "User-Agent", "Accept"] {
            if let w = petition.headers[name.lowercased()] { r.setValue(w, forHTTPHeaderField: name) }
        }
        // Otherwise URLSession unpacks it and Content-Length no longer matches.
        r.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        OwnHeaders.apply(on: &r)

        // Where `suspend()` does not pause (swift-corelibs), fetching is done in pieces:
        // each request to the server carries a bounded Range, and the next piece only comes
        // once VLC has taken the previous one. If VLC does not read, no request is open at
        // the server any more, without depending on `cancel()`, which takes effect late there.
        let erbeten = Line.haltActs || petition.procedure != "GET"
            || url.pathExtension.lowercased() == "m3u8"
            ? nil : Self.sectionRead(petition.headers["range"])
        if let e = erbeten {
            r.setValue("bytes=\(e.from)-\(Self.pieceEnd(since: e.from, until: e.until))",
                       forHTTPHeaderField: "Range")
        }

        let conduit = Line()
        let task = start(r, conduit)
        defer { task.cancel() }

        let path = url.path
        guard let answer = conduit.waitResponse() else {
            Self.log?("[Weiterleiter] \(petition.procedure) \(path) → keine Antwort vom Server")
            Plug.dispatch(v, Self.header(502, [:], length: 0)); return
        }
        let section = petition.headers["range"].map { " \($0)" } ?? ""
        Self.log?("[Weiterleiter] \(petition.procedure) \(path)\(section) → \(answer.statusCode)")

        var fields: [String: String] = [:]
        for name in ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges",
                     "Last-Modified", "ETag"] {
            if let w = answer.value(forHTTPHeaderField: name) { fields[name] = w }
        }
        if answer.value(forHTTPHeaderField: "Content-Encoding") != nil {
            fields["Content-Length"] = nil
        }
        var status = answer.statusCode

        // In pieces only if the server served the Range exactly like that. Otherwise (200
        // without Range, total length unknown) it runs as before in one go, with the upper
        // limit as the last stop.
        var proceed: (since: Int, until: Int)?
        if let e = erbeten, status == 206,
           let part = Self.contentSectionRead(answer.value(forHTTPHeaderField: "Content-Range")),
           part.from == e.from {
            let until = min(e.until ?? part.total - 1, part.total - 1)
            if petition.headers["range"] == nil {
                status = 200
                fields["Content-Range"] = nil
                fields["Content-Length"] = String(part.total)
            } else {
                fields["Content-Range"] = "bytes \(e.from)-\(until)/\(part.total)"
                fields["Content-Length"] = String(until - e.from + 1)
            }
            if part.until < until { proceed = (part.until + 1, until) }
        }

        if petition.procedure == "HEAD" {
            Plug.dispatch(v, Self.header(status, fields, length: nil)); return
        }

        let type = (fields["Content-Type"] ?? "").lowercased()
        if type.contains("mpegurl") || url.pathExtension.lowercased() == "m3u8" {
            guard let raw = conduit.everything(until: Self.listsLimit) else {
                Plug.dispatch(v, Self.header(502, [:], length: 0)); return
            }
            let text = String(decoding: raw, as: UTF8.self)
            let new = Data(listWrite(text, mark: mark).utf8)
            fields["Content-Length"] = nil
            Plug.dispatch(v, Self.header(status, fields, length: new.count))
            Plug.dispatch(v, new)
            return
        }

        guard Plug.dispatch(v, Self.header(status, fields, length: nil)) else { return }
        var sent = 0
        guard nextGive(conduit, an: v, path: path, sent: &sent) else { return }

        // The further pieces. If the file changes in between, the server answers If-Range
        // with 200; the connection then ends, and VLC resumes with `:http-reconnect`.
        if r.value(forHTTPHeaderField: "If-Range") == nil {
            if let eTag = fields["ETag"], !eTag.hasPrefix("W/") {
                r.setValue(eTag, forHTTPHeaderField: "If-Range")
            } else if let date = fields["Last-Modified"] {
                r.setValue(date, forHTTPHeaderField: "If-Range")
            }
        }
        while let w = proceed {
            let since = w.since, until = w.until
            let end = Self.pieceEnd(since: since, until: until)
            r.setValue("bytes=\(since)-\(end)", forHTTPHeaderField: "Range")
            let l = Line()
            let a = start(r, l)
            defer { a.cancel() }
            guard let quickReply = l.waitResponse(), quickReply.statusCode == 206,
                  let part = Self.contentSectionRead(quickReply.value(forHTTPHeaderField: "Content-Range")),
                  part.from == since, part.until >= since else {
                Self.log?("[Weiterleiter] \(path) Stück ab \(since) nicht bedient")
                return
            }
            guard nextGive(l, an: v, path: path, sent: &sent) else { return }
            proceed = part.until < until ? (part.until + 1, until) : nil
        }
    }

    /// Piece size where throttling is only possible this way.
    static let piece = 16 << 20

    private func start(_ r: URLRequest, _ conduit: Line) -> URLSessionTask {
        let task = session.dataTask(with: r)
        conduit.task = task
        distributor.register(conduit, for: task)
        task.resume()
        return task
    }

    /// Everything from the line to VLC; `false` if VLC no longer reads.
    private func nextGive(_ conduit: Line, an v: Plug.Handle, path: String,
                             sent: inout Int) -> Bool {
        while let piece = conduit.nextItem() {
            guard Plug.dispatch(v, piece) else {
                Self.log?("[Weiterleiter] \(path) abgebrochen nach \(sent) Bytes")
                return false
            }
            sent += piece.count
        }
        return true
    }

    /// Last byte of the piece from `from`, at most up to `until`.
    static func pieceEnd(since from: Int, until: Int?) -> Int {
        let end = from + piece - 1
        return until.map { min($0, end) } ?? end
    }

    /// `Range` from VLC: without the header everything from 0, otherwise `bytes=N-` or
    /// `bytes=N-E`. Suffix and multiple ranges: `nil`, handled in one go.
    static func sectionRead(_ w: String?) -> (from: Int, until: Int?)? {
        guard let w else { return (0, nil) }
        let t = w.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("bytes="), !t.contains(",") else { return nil }
        let z = t.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard z.count == 2, let from = Int(z[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        let behind = z[1].trimmingCharacters(in: .whitespaces)
        if behind.isEmpty { return (from, nil) }
        guard let until = Int(behind), until >= from else { return nil }
        return (from, until)
    }

    /// `Content-Range: bytes A-B/T` with known total length.
    static func contentSectionRead(_ w: String?) -> (from: Int, until: Int, total: Int)? {
        guard let w, w.hasPrefix("bytes ") else { return nil }
        let z = w.dropFirst(6).split(separator: "/")
        guard z.count == 2, let total = Int(z[1]) else { return nil }
        let b = z[0].split(separator: "-")
        guard b.count == 2, let from = Int(b[0]), let until = Int(b[1]),
              from <= until, until < total else { return nil }
        return (from, until, total)
    }

    // MARK: Playlists

    /// Redirect absolute addresses and root-relative paths in an HLS playlist to the
    /// forwarder. Relative ones stay as they are; VLC resolves them against the playlist's
    /// address, which already points here.
    func listWrite(_ text: String, mark: String) -> String {
        func bend(_ a: String) -> String {
            if a.hasPrefix("/") && !a.hasPrefix("//") { return "/\(mark)\(a)" }
            let small = a.lowercased()
            if small.hasPrefix("http://") || small.hasPrefix("https://"), let u = URL(string: a) {
                return address(for: u).absoluteString
            }
            return a
        }
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false).map { raw -> String in
            var row = String(raw)
            let cr = row.hasSuffix("\r")
            if cr { row.removeLast() }
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                // stays
            } else if trimmed.hasPrefix("#") {
                // URI="…" in EXT-X-MAP, EXT-X-MEDIA, EXT-X-KEY …
                if let a = row.range(of: "URI=\""),
                   let e = row[a.upperBound...].firstIndex(of: "\"") {
                    let alt = String(row[a.upperBound..<e])
                    row.replaceSubrange(a.upperBound..<e, with: bend(alt))
                }
            } else {
                row = bend(trimmed)
            }
            return cr ? row + "\r" : row
        }
        return rows.joined(separator: "\n")
    }

    // MARK: Response head

    static func header(_ status: Int, _ fields: [String: String], length: Int?) -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 206: reason = "Partial Content"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 502: reason = "Bad Gateway"
        default: reason = "Status"
        }
        var s = "HTTP/1.1 \(status) \(reason)\r\n"
        for (n, w) in fields.sorted(by: { $0.key < $1.key }) { s += "\(n): \(w)\r\n" }
        if let length { s += "Content-Length: \(length)\r\n" }
        s += "Connection: close\r\n\r\n"
        return Data(s.utf8)
    }
}

// MARK: - Reading the request

struct RequestHeader {
    let procedure: String
    let target: String
    /// Names in lower case.
    let headers: [String: String]

    /// Read up to the blank line. More than 64 KiB of head is not a VLC request.
    static func read(_ v: Plug.Handle) -> RequestHeader? {
        var buffer = [UInt8]()
        let end: [UInt8] = [13, 10, 13, 10]
        var piece = [UInt8](repeating: 0, count: 4096)
        while buffer.count < 65536 {
            let n = Plug.read(v, &piece)
            guard n > 0 else { return nil }
            buffer.append(contentsOf: piece[0..<n])
            if buffer.count >= 4, let _ = buffer.indices.dropLast(3).first(where: {
                buffer[$0] == end[0] && buffer[$0 + 1] == end[1]
                    && buffer[$0 + 2] == end[2] && buffer[$0 + 3] == end[3]
            }) { return dismantle(String(decoding: buffer, as: UTF8.self)) }
        }
        return nil
    }

    static func dismantle(_ text: String) -> RequestHeader? {
        let rows = text.components(separatedBy: "\r\n")
        let first = rows.first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for z in rows.dropFirst() {
            guard let d = z.firstIndex(of: ":") else { continue }
            let n = z[..<d].trimmingCharacters(in: .whitespaces).lowercased()
            headers[n] = z[z.index(after: d)...].trimmingCharacters(in: .whitespaces)
        }
        return RequestHeader(procedure: String(first[0]), target: String(first[1]), headers: headers)
    }
}

// MARK: - Between URLSession and a connection's thread

/// What comes from the server waits here until the thread sends it to VLC.
final class Line: @unchecked Sendable {
    /// **Pausing only on Apple.** In swift-corelibs-foundation (Android, Linux, Windows)
    /// `suspend()` does not stop the transfer: measured on Android, it paused at 8 MiB and
    /// data kept arriving, and a task cancelled afterwards never reported its end. There
    /// the forwarder fetches in pieces (``Stromweiterleiter/stueck``); the upper limit
    /// remains for servers that do not serve Range.
    #if canImport(Darwin)
    static let haltActs = true
    #else
    static let haltActs = false
    #endif

    private let requirement = NSCondition()
    private var answer: HTTPURLResponse?
    private var pieces: [Data] = []
    private var waiting = 0
    private var done = false
    private var halted = false
    weak var task: URLSessionTask?

    func responsePresent(_ a: URLResponse) {
        requirement.lock()
        answer = a as? HTTPURLResponse
        if answer == nil { done = true }
        requirement.broadcast(); requirement.unlock()
    }

    func data(_ d: Data) {
        requirement.lock()
        // After the abort, URLSession still delivers what was already queued; that is no
        // longer sent, so it is not held either.
        guard !done else { requirement.unlock(); return }
        pieces.append(d)
        waiting += d.count
        if waiting > StreamForwarder.upperLimit {
            done = true
            task?.cancel()
        } else if Self.haltActs && !halted && waiting > StreamForwarder.haltOff {
            halted = true
            task?.suspend()
        }
        requirement.broadcast(); requirement.unlock()
    }

    func end() {
        requirement.lock()
        done = true
        requirement.broadcast(); requirement.unlock()
    }

    func waitResponse() -> HTTPURLResponse? {
        requirement.lock(); defer { requirement.unlock() }
        while answer == nil && !done { requirement.wait() }
        return answer
    }

    /// The next piece, `nil` at the end.
    func nextItem() -> Data? {
        requirement.lock(); defer { requirement.unlock() }
        while pieces.isEmpty && !done { requirement.wait() }
        guard !pieces.isEmpty else { return nil }
        let d = pieces.count == 1 ? pieces[0] : pieces.reduce(into: Data()) { $0.append($1) }
        pieces.removeAll(keepingCapacity: true)
        waiting = 0
        if halted && waiting < StreamForwarder.nextOff {
            halted = false
            task?.resume()
        }
        return d
    }

    /// The whole body, only for playlists.
    func everything(until limit: Int) -> Data? {
        var d = Data()
        while let s = nextItem() {
            d.append(s)
            if d.count > limit { return nil }
        }
        return d
    }
}

/// The session's single delegate; assigns each callback to its line.
final class Splitter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let barrier = NSLock()
    private var conduits: [Int: Line] = [:]

    func register(_ l: Line, for a: URLSessionTask) {
        barrier.lock(); conduits[a.taskIdentifier] = l; barrier.unlock()
    }

    private func conduit(_ a: URLSessionTask) -> Line? {
        barrier.lock(); defer { barrier.unlock() }
        return conduits[a.taskIdentifier]
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        conduit(dataTask)?.responsePresent(response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        conduit(dataTask)?.data(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        barrier.lock()
        let l = conduits.removeValue(forKey: task.taskIdentifier)
        barrier.unlock()
        l?.end()
    }
}

// MARK: - Sockets, per platform

/// The little BSD sockets surface the forwarder needs. Winsock is named almost the
/// same but takes different types.
enum Plug {
    #if os(Windows)
    typealias Handle = SOCKET
    private static let winsock: Void = {
        var d = WSADATA()
        _ = WSAStartup(0x0202, &d)
    }()
    #else
    typealias Handle = Int32
    #endif

    /// Bind to 127.0.0.1, preferably to `preferred`, otherwise to a free port.
    static func eavesdrop(preferred: UInt16) -> (Handle, UInt16)? {
        if preferred != 0, let g = eavesdrop(port: preferred) { return g }
        return eavesdrop(port: 0)
    }

    private static func eavesdrop(port: UInt16) -> (Handle, UInt16)? {
        #if os(Windows)
        _ = winsock
        let g = socket(AF_INET, SOCK_STREAM, 0)
        guard g != INVALID_SOCKET else { return nil }
        #else
        #if canImport(Glibc) && !os(Android)
        let g = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let g = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard g >= 0 else { return nil }
        var one: Int32 = 1
        _ = setsockopt(g, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var a = sockaddr_in()
        #if canImport(Darwin)
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        #if os(Windows)
        a.sin_family = ADDRESS_FAMILY(AF_INET)
        #else
        a.sin_family = sa_family_t(AF_INET)
        #endif
        a.sin_port = port.bigEndian
        _ = inet_pton(AF_INET, "127.0.0.1", &a.sin_addr)

        let size = MemoryLayout<sockaddr_in>.size
        let bound = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if os(Windows)
                bind(g, $0, Int32(size)) == 0
                #else
                bind(g, $0, socklen_t(size)) == 0
                #endif
            }
        }
        guard bound, listen(g, 16) == 0 else { close(g); return nil }

        var b = sockaddr_in()
        #if os(Windows)
        var l = Int32(size)
        #else
        var l = socklen_t(size)
        #endif
        _ = withUnsafeMutablePointer(to: &b) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(g, $0, &l) }
        }
        return (g, UInt16(bigEndian: b.sin_port))
    }

    /// Connect to 127.0.0.1, only for the tests that play VLC.
    static func linkUp(port: UInt16) -> Handle? {
        #if os(Windows)
        _ = winsock
        let g = socket(AF_INET, SOCK_STREAM, 0)
        guard g != INVALID_SOCKET else { return nil }
        #elseif canImport(Glibc) && !os(Android)
        let g = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard g >= 0 else { return nil }
        #else
        let g = socket(AF_INET, SOCK_STREAM, 0)
        guard g >= 0 else { return nil }
        #endif
        var a = sockaddr_in()
        #if canImport(Darwin)
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        var one: Int32 = 1
        _ = setsockopt(g, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        #if os(Windows)
        a.sin_family = ADDRESS_FAMILY(AF_INET)
        #else
        a.sin_family = sa_family_t(AF_INET)
        #endif
        a.sin_port = port.bigEndian
        _ = inet_pton(AF_INET, "127.0.0.1", &a.sin_addr)
        let size = MemoryLayout<sockaddr_in>.size
        let ok = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if os(Windows)
                connect(g, $0, Int32(size)) == 0
                #else
                connect(g, $0, socklen_t(size)) == 0
                #endif
            }
        }
        guard ok else { close(g); return nil }
        return g
    }

    static func acceptConnection(_ g: Handle) -> Handle? {
        let v = accept(g, nil, nil)
        #if os(Windows)
        guard v != INVALID_SOCKET else { return nil }
        #else
        guard v >= 0 else { return nil }
        #if canImport(Darwin)
        var one: Int32 = 1
        _ = setsockopt(v, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        #endif
        return v
    }

    /// An interrupted `accept` is not an end.
    static func anotherTime() -> Bool {
        #if os(Windows)
        return false
        #else
        return errno == EINTR || errno == ECONNABORTED
        #endif
    }

    static func readDeadline(_ g: Handle, seconds: Int) {
        #if os(Windows)
        var ms = DWORD(seconds * 1000)
        _ = withUnsafePointer(to: &ms) {
            $0.withMemoryRebound(to: CChar.self, capacity: 4) {
                setsockopt(g, SOL_SOCKET, SO_RCVTIMEO, $0, Int32(MemoryLayout<DWORD>.size))
            }
        }
        #else
        var t = timeval()
        t.tv_sec = .init(seconds)
        #if os(Android) && arch(arm)
        // 32-bit Android (many TVs): `SO_RCVTIMEO` is a macro with `sizeof` there that Swift
        // does not import. time_t is 32 bit here, so the old value applies.
        let option = SO_RCVTIMEO_OLD
        #else
        let option = SO_RCVTIMEO
        #endif
        _ = setsockopt(g, SOL_SOCKET, option, &t, socklen_t(MemoryLayout<timeval>.size))
        #endif
    }

    static func read(_ g: Handle, _ buffer: inout [UInt8]) -> Int {
        let count = buffer.count
        return buffer.withUnsafeMutableBytes { p in
            #if os(Windows)
            Int(recv(g, p.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(count), 0))
            #else
            recv(g, p.baseAddress, count, 0)
            #endif
        }
    }

    /// Send everything. `false` as soon as the other side is gone.
    @discardableResult
    static func dispatch(_ g: Handle, _ data: Data) -> Bool {
        data.withUnsafeBytes { p -> Bool in
            guard let base = p.baseAddress else { return true }
            var since = 0
            while since < p.count {
                #if os(Windows)
                let n = Int(send(g, base.advanced(by: since).assumingMemoryBound(to: CChar.self),
                                 Int32(p.count - since), 0))
                #elseif canImport(Darwin)
                let n = send(g, base.advanced(by: since), p.count - since, 0)
                #else
                let n = send(g, base.advanced(by: since), p.count - since, Int32(MSG_NOSIGNAL))
                #endif
                if n <= 0 {
                    #if !os(Windows)
                    if n < 0 && errno == EINTR { continue }
                    #endif
                    return false
                }
                since += n
            }
            return true
        }
    }

    static func close(_ g: Handle) {
        #if os(Windows)
        _ = closesocket(g)
        #else
        _ = closeRawDescriptor(g)
        #endif
    }
}

#if !os(Windows)
/// The C `close`, out of reach of `Plug.close`, which would call itself.
private func closeRawDescriptor(_ g: Int32) -> Int32 { close(g) }
#endif
