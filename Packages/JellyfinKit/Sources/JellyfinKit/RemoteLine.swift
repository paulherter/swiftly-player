import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif
#if os(Windows)
import WinSDK
#endif

/// **The line under the remote control**: a WebSocket, however it is built. Apple
/// uses ``URLSessionLine``; Linux, Windows and Android use ``CurlLine`` where
/// possible.
///
/// Android has a second reason: there `URLSessionWebSocketTask` keeps the libdispatch
/// socket source firing while the channel is idle. Measured on the home screen with
/// nothing playing: about 12,000 manager-thread wakeups per second plus five worker
/// threads at about 3,000 each, all in `_MultiHandle.readAndWriteAvailableData` →
/// `curl_multi_socket_action`, with only ~1 KB/s on the wire. A battery drain that
/// never stops while the app is in front.
///
/// Why two: `URLSessionWebSocketTask` in swift-corelibs-foundation (libcurl underneath)
/// treats an **unsolicited pong frame** as a protocol error and closes with 1002 /
/// `-1005`. ASP.NET Core (Jellyfin) sends exactly such a frame every
/// `KeepAliveInterval`, default 120 seconds. RFC 6455 explicitly allows it (section
/// 5.5.3). Reproduced with a mock server: the connection drops at the moment the pong
/// arrives.
protocol RemoteLink: AnyObject, Sendable {
    /// Open the connection (non-blocking).
    func buildUp()
    /// The next text message. `nil` if something else arrived that still counts as a
    /// sign of life from the peer.
    func receive() async throws -> String?
    func dispatch(_ text: String) async throws
    func close()
    /// Details about the disconnect for the log (HTTP status, close code …).
    var teardownDetails: [String] { get }
}

/// The line was not available on this system; the remote control then
/// falls back to `URLSession`.
struct LineNotSupported: Error {}

/// libcurl could not set the line up (handshake, certificates, TLS …) before it ever
/// opened. ``RemoteControl`` counts these and falls back to `URLSession` after a few in a
/// row, so a curl that cannot reach this server does not leave the remote control dead.
struct LineSetupFailed: Error, CustomStringConvertible {
    let code: Int32
    let text: String
    var description: String { text }

    /// Plain network trouble (proxy/host not resolved, no connection, timeout): the same
    /// would happen on `URLSession`, so it is no reason to switch lines.
    static func blamesLine(code: Int32) -> Bool {
        ![5, 6, 7, 28, 52, 55, 56].contains(code)
    }
}

// MARK: - URLSession

final class URLSessionLine: RemoteLink, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(petition: URLRequest, session: URLSession) {
        task = session.webSocketTask(with: petition)
    }

    func buildUp() { task.resume() }

    func receive() async throws -> String? {
        if case let .string(text) = try await task.receive() { return text }
        return nil
    }

    func dispatch(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func close() { task.cancel(with: .goingAway, reason: nil) }

    var teardownDetails: [String] {
        var parts: [String] = []
        if let http = task.response as? HTTPURLResponse {
            parts.append("HTTP \(http.statusCode)")
        }
        if task.closeCode != .invalid {
            var sentence = "Schliesscode \(task.closeCode.rawValue)"
            if let reason = task.closeReason,
               let text = String(data: reason, encoding: .utf8), !text.isEmpty {
                sentence += " (\(text))"
            }
            parts.append(sentence)
        }
        return parts
    }
}

// MARK: - libcurl (Linux, Windows, Android)

#if os(Linux) || os(Windows) || os(Android)

/// What is needed from libcurl, loaded at runtime: the build needs neither header
/// nor library, and a curl without WebSocket (before 7.86 or compiled without
/// support) only shows up at load time.
struct CurlFunction: @unchecked Sendable {
    typealias Pointer = UnsafeMutableRawPointer
    /// `struct curl_ws_frame { int age; int flags; curl_off_t offset;
    /// curl_off_t bytesleft; size_t len; }`, read via offsets, because a Swift struct
    /// cannot appear in a C prototype.
    static let offsetFlags = 4
    static let offsetRemaining = 16

    let setUp: @convention(c) () -> Pointer?
    let cleanUp: @convention(c) (Pointer?) -> Void
    let optionPointer: @convention(c) (Pointer?, Int32, UnsafeRawPointer?) -> Int32
    let optionNumber: @convention(c) (Pointer?, Int32, Int) -> Int32
    let execute: @convention(c) (Pointer?) -> Int32
    let infoSocket: @convention(c) (Pointer?, Int32, UnsafeMutablePointer<Int32>?) -> Int32
    let listAppend: @convention(c) (Pointer?, UnsafePointer<CChar>?) -> Pointer?
    let listShare: @convention(c) (Pointer?) -> Void
    let wsReceive: @convention(c) (Pointer?, UnsafeMutableRawPointer?, Int, UnsafeMutablePointer<Int>?,
                                     UnsafeMutablePointer<UnsafeRawPointer?>?) -> Int32
    let wsSend: @convention(c) (Pointer?, UnsafeRawPointer?, Int, UnsafeMutablePointer<Int>?,
                                  Int64, UInt32) -> Int32
    let errorString: @convention(c) (Int32) -> UnsafePointer<CChar>?

    /// Loaded once, for the whole program. `nil`: not available.
    static let loaded: CurlFunction? = load()

    private static func load() -> CurlFunction? {
        #if os(Windows)
        var moduleRef: HMODULE?
        for name in ["libcurl.dll", "libcurl-x64.dll", "libcurl-4.dll"] {
            moduleRef = LoadLibraryA(name)
            if moduleRef != nil { break }
        }
        guard let moduleRef else { return nil }
        func symbol(_ name: String) -> UnsafeMutableRawPointer? {
            guard let p = GetProcAddress(moduleRef, name) else { return nil }
            return unsafeBitCast(p, to: UnsafeMutableRawPointer.self)
        }
        #else
        var moduleRef: UnsafeMutableRawPointer?
        // Android has no system libcurl; the one inside FoundationNetworking exports
        // the symbols needed here and is already loaded.
        for name in ["libcurl.so.4", "libcurl.so", "libcurl-gnutls.so.4", "libFoundationNetworking.so"] {
            moduleRef = dlopen(name, RTLD_NOW)
            if moduleRef != nil { break }
        }
        guard let moduleRef else { return nil }
        func symbol(_ name: String) -> UnsafeMutableRawPointer? { dlsym(moduleRef, name) }
        #endif

        guard let a = symbol("curl_easy_init"), let b = symbol("curl_easy_cleanup"),
              let c = symbol("curl_easy_setopt"), let d = symbol("curl_easy_perform"),
              let e = symbol("curl_easy_getinfo"), let g = symbol("curl_slist_append"),
              let h = symbol("curl_slist_free_all"), let i = symbol("curl_ws_recv"),
              let j = symbol("curl_ws_send"), let k = symbol("curl_easy_strerror")
        else { return nil }
        // `curl_easy_setopt` and `curl_easy_getinfo` are variadic; with exactly one
        // argument after the name, calling through a fixed prototype works the same on
        // x86-64 and arm64 (Linux and Windows).
        return CurlFunction(
            setUp: unsafeBitCast(a, to: (@convention(c) () -> Pointer?).self),
            cleanUp: unsafeBitCast(b, to: (@convention(c) (Pointer?) -> Void).self),
            optionPointer: unsafeBitCast(c, to: (@convention(c) (Pointer?, Int32, UnsafeRawPointer?) -> Int32).self),
            optionNumber: unsafeBitCast(c, to: (@convention(c) (Pointer?, Int32, Int) -> Int32).self),
            execute: unsafeBitCast(d, to: (@convention(c) (Pointer?) -> Int32).self),
            infoSocket: unsafeBitCast(e, to: (@convention(c) (Pointer?, Int32, UnsafeMutablePointer<Int32>?) -> Int32).self),
            listAppend: unsafeBitCast(g, to: (@convention(c) (Pointer?, UnsafePointer<CChar>?) -> Pointer?).self),
            listShare: unsafeBitCast(h, to: (@convention(c) (Pointer?) -> Void).self),
            wsReceive: unsafeBitCast(i, to: (@convention(c) (Pointer?, UnsafeMutableRawPointer?, Int, UnsafeMutablePointer<Int>?, UnsafeMutablePointer<UnsafeRawPointer?>?) -> Int32).self),
            wsSend: unsafeBitCast(j, to: (@convention(c) (Pointer?, UnsafeRawPointer?, Int, UnsafeMutablePointer<Int>?, Int64, UInt32) -> Int32).self),
            errorString: unsafeBitCast(k, to: (@convention(c) (Int32) -> UnsafePointer<CChar>?).self))
    }
}

/// **A WebSocket over libcurl's own WS interface**
/// (`CONNECT_ONLY=2`, `curl_ws_recv`/`curl_ws_send`). The library handles pong and ping
/// frames itself, so an unsolicited pong does not end the channel.
///
/// One dedicated thread reads; sending works from any thread, both under a lock,
/// because a curl handle is not thread-safe.
final class CurlLine: RemoteLink, @unchecked Sendable {

    private enum Opt {
        static let url: Int32 = 10002
        static let httpheader: Int32 = 10023
        static let connectTimeout: Int32 = 78
        static let noSignal: Int32 = 99
        static let connectOnly: Int32 = 141
        static let caInfo: Int32 = 10065
        static let caPath: Int32 = 10097
    }
    private static let infoActiveSocket: Int32 = 0x500000 + 44
    private static let again: Int32 = 81
    private enum Flag {
        static let text: Int32 = 1, binary: Int32 = 2, cont: Int32 = 4
        static let close: Int32 = 8, ping: Int32 = 16, pong: Int32 = 64
    }

    struct Failure: Error, CustomStringConvertible {
        let text: String
        var description: String { text }
    }

    private let f: CurlFunction
    private let petition: URLRequest
    private let barrier = NSLock()
    private var handle: CurlFunction.Pointer?
    private var headerList: CurlFunction.Pointer?
    private var opened = false
    private var ended = false
    private var closeCode: Int?
    private var closeReason: String?
    private var lastError: String?
    /// Read once on the caller's thread: the read thread must not touch the process
    /// environment while the host app changes it (`setenv` is not thread-safe).
    private let trustBundle: String

    private let feed: AsyncThrowingStream<String?, Error>
    private let output: AsyncThrowingStream<String?, Error>.Continuation
    private var reader: AsyncThrowingStream<String?, Error>.AsyncIterator

    init?(petition: URLRequest) {
        guard let f = CurlFunction.loaded, petition.url != nil else { return nil }
        self.f = f
        self.petition = petition
        self.trustBundle = ProcessInfo.processInfo.environment["URLSessionCertificateAuthorityInfoFile"] ?? ""
        (feed, output) = AsyncThrowingStream.makeStream(of: String?.self)
        reader = feed.makeAsyncIterator()
    }

    func buildUp() {
        let thread = Thread { [self] in read() }
        thread.name = "Fernleitung"
        thread.start()
    }

    func receive() async throws -> String? {
        guard let postDirection = try await reader.next() else {
            throw Failure(text: "Leitung geschlossen")
        }
        return postDirection
    }

    func dispatch(_ text: String) async throws {
        try sendSync(Array(text.utf8), flags: UInt32(Flag.text))
    }

    private func sendSync(_ bytes: [UInt8], flags: UInt32) throws {
        var offset = 0
        var attempts = 0
        while offset < bytes.count || bytes.isEmpty {
            barrier.lock()
            guard opened, !ended, let h = handle else {
                barrier.unlock()
                throw Failure(text: "keine Leitung")
            }
            var sent = 0
            let rc = bytes.withUnsafeBytes { raw in
                f.wsSend(h, raw.baseAddress.map { $0 + offset }, bytes.count - offset, &sent, 0, flags)
            }
            barrier.unlock()
            if rc == Self.again {
                attempts += 1
                if attempts > 200 { throw Failure(text: "Senden blockiert") }
                Thread.sleep(forTimeInterval: 0.005)
                continue
            }
            if rc != 0 { throw Failure(text: "curl \(rc): \(message(rc))") }
            offset += sent
            if bytes.isEmpty { return }
        }
    }

    func close() {
        barrier.lock()
        let was = ended
        ended = true
        if !was, opened, let h = handle {
            // Best effort: say goodbye properly with 1001 (“going away”).
            let code: [UInt8] = [0x03, 0xE9]
            var sent = 0
            _ = code.withUnsafeBytes { f.wsSend(h, $0.baseAddress, 2, &sent, 0, UInt32(Flag.close)) }
        }
        barrier.unlock()
        output.finish(throwing: Failure(text: "Leitung geschlossen"))
    }

    var teardownDetails: [String] {
        barrier.lock(); defer { barrier.unlock() }
        var t: [String] = ["Leitung: libcurl"]
        if let c = closeCode {
            var s = "Schliesscode \(c)"
            if let g = closeReason, !g.isEmpty { s += " (\(g))" }
            t.append(s)
        }
        if let e = lastError { t.append(e) }
        return t
    }

    private func message(_ rc: Int32) -> String {
        f.errorString(rc).map { String(cString: $0) } ?? "?"
    }

    // MARK: Read thread

    private func read() {
        guard linkUp() else { cleanUp(); return }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var part = Data()
        var textStart = false
        while true {
            barrier.lock()
            if ended { barrier.unlock(); break }
            guard let h = handle else { barrier.unlock(); break }
            var n = 0
            var frameRect: UnsafeRawPointer?
            let rc = f.wsReceive(h, &buffer, buffer.count, &n, &frameRect)
            let flags = frameRect?.load(fromByteOffset: CurlFunction.offsetFlags, as: Int32.self) ?? 0
            let rest = frameRect?.load(fromByteOffset: CurlFunction.offsetRemaining, as: Int64.self) ?? 0
            barrier.unlock()

            if rc == Self.again { wait(); continue }
            if rc != 0 {
                failure("curl \(rc): \(message(rc))")
                break
            }
            if flags & Flag.close != 0 {
                barrier.lock()
                if n >= 2 { closeCode = Int(buffer[0]) << 8 | Int(buffer[1]) }
                if n > 2 { closeReason = String(decoding: buffer[2..<n], as: UTF8.self) }
                barrier.unlock()
                failure("von der Gegenstelle geschlossen")
                break
            }
            // libcurl answers ping itself; a pong is not an error.
            if flags & (Flag.ping | Flag.pong) != 0 { continue }
            if flags & Flag.text != 0 { textStart = true; part.removeAll(keepingCapacity: true) }
            if textStart || flags & (Flag.binary | Flag.cont) != 0 { part.append(buffer, count: n) }
            if rest == 0 && flags & Flag.cont == 0 {
                if textStart { output.yield(String(decoding: part, as: UTF8.self)) }
                else { output.yield(nil) }
                textStart = false
                part.removeAll(keepingCapacity: true)
            }
        }
        cleanUp()
    }

    private func failure(_ text: String) {
        barrier.lock()
        lastError = text
        let was = ended
        barrier.unlock()
        if !was { output.finish(throwing: Failure(text: text)) }
    }

    /// Until data arrives or a quarter second is up, without the lock.
    private func wait() {
        #if os(Linux) || os(Android)
        var s: Int32 = -1
        barrier.lock()
        if let h = handle { _ = f.infoSocket(h, Self.infoActiveSocket, &s) }
        barrier.unlock()
        if s >= 0 {
            var p = pollfd(fd: s, events: Int16(POLLIN), revents: 0)
            _ = poll(&p, 1, 250)
            return
        }
        #endif
        Thread.sleep(forTimeInterval: 0.025)
    }

    private func linkUp() -> Bool {
        guard let h = f.setUp() else { failure("curl_easy_init"); return false }
        var list: CurlFunction.Pointer?
        for (name, value) in petition.allHTTPHeaderFields ?? [:] {
            list = "\(name): \(value)".withCString { f.listAppend(list, $0) }
        }
        let url = petition.url!.absoluteString
        _ = url.withCString { f.optionPointer(h, Opt.url, $0) }
        if list != nil { _ = f.optionPointer(h, Opt.httpheader, UnsafeRawPointer(list)) }
        _ = f.optionNumber(h, Opt.connectOnly, 2)
        _ = f.optionNumber(h, Opt.connectTimeout, 15)
        _ = f.optionNumber(h, Opt.noSignal, 1)
        // The same trust store Foundation's own handles get: the bundle from
        // `URLSessionCertificateAuthorityInfoFile` (user CAs on Android), otherwise on
        // Android the system directory. A bare handle has neither, and every
        // handshake fails with curl 60.
        let bundle = trustBundle
        if !bundle.isEmpty {
            _ = bundle.withCString { f.optionPointer(h, Opt.caInfo, $0) }
        }
        #if os(Android)
        if bundle.isEmpty,
           let folder = ["/apex/com.android.conscrypt/cacerts", "/system/etc/security/cacerts"]
               .first(where: { FileManager.default.fileExists(atPath: $0) }) {
            _ = folder.withCString { f.optionPointer(h, Opt.caPath, $0) }
        }
        #endif

        barrier.lock()
        handle = h
        headerList = list
        let alreadyShut = ended
        barrier.unlock()
        if alreadyShut { return false }

        let rc = f.execute(h)      // Handshake; blocks for up to 15 s
        if rc != 0 {
            // 1 = protocol unknown, 4 = not built in: this curl cannot do WS.
            if rc == 1 || rc == 4 || rc == 48 {
                output.finish(throwing: LineNotSupported())
            } else {
                let text = "curl \(rc): \(message(rc))"
                barrier.lock(); lastError = text; let was = ended; barrier.unlock()
                if !was { output.finish(throwing: LineSetupFailed(code: rc, text: text)) }
            }
            return false
        }
        barrier.lock(); opened = true; barrier.unlock()
        return true
    }

    private func cleanUp() {
        barrier.lock()
        opened = false
        ended = true
        let h = handle, list = headerList
        handle = nil; headerList = nil
        barrier.unlock()
        if let h { f.cleanUp(h) }
        if let list { f.listShare(list) }
    }
}

#endif
