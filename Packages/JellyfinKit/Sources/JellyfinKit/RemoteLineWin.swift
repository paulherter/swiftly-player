#if os(Windows)
import Foundation
import WinSDK
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private typealias Handle = UnsafeMutableRawPointer

/// winhttp.dll loaded by hand: the Windows module of the toolchain does not expose its header,
/// and this way no import library is needed either.
private struct WinHttpApi {
    typealias Ptr = UnsafeRawPointer?
    let open: @convention(c) (Ptr, UInt32, Ptr, Ptr, UInt32) -> Handle?
    let connect: @convention(c) (Handle, Ptr, UInt16, UInt32) -> Handle?
    let openRequest: @convention(c) (Handle, Ptr, Ptr, Ptr, Ptr, Ptr, UInt32) -> Handle?
    let setOption: @convention(c) (Handle, UInt32, Ptr, UInt32) -> Int32
    let addHeaders: @convention(c) (Handle, Ptr, UInt32, UInt32) -> Int32
    let sendRequest: @convention(c) (Handle, Ptr, UInt32, Ptr, UInt32, UInt32, UInt) -> Int32
    let receiveResponse: @convention(c) (Handle, Ptr) -> Int32
    let completeUpgrade: @convention(c) (Handle, UInt) -> Handle?
    let wsSend: @convention(c) (Handle, UInt32, Ptr, UInt32) -> UInt32
    let wsReceive: @convention(c) (Handle, UnsafeMutableRawPointer?, UInt32, UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>) -> UInt32
    let wsClose: @convention(c) (Handle, UInt16, Ptr, UInt32) -> UInt32
    let wsQueryClose: @convention(c) (Handle, UnsafeMutablePointer<UInt16>, UnsafeMutableRawPointer?, UInt32, UnsafeMutablePointer<UInt32>) -> UInt32
    let closeHandle: @convention(c) (Handle) -> Int32
    let setTimeouts: @convention(c) (Handle, Int32, Int32, Int32, Int32) -> Int32

    static let loaded: WinHttpApi? = {
        guard let dll = LoadLibraryW(Array("winhttp.dll".utf16 + [0])) else { return nil }
        func f<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = GetProcAddress(dll, name) else { return nil }
            return unsafeBitCast(p, to: type)
        }
        guard let a = f("WinHttpOpen", (@convention(c) (Ptr, UInt32, Ptr, Ptr, UInt32) -> Handle?).self),
              let b = f("WinHttpConnect", (@convention(c) (Handle, Ptr, UInt16, UInt32) -> Handle?).self),
              let c = f("WinHttpOpenRequest", (@convention(c) (Handle, Ptr, Ptr, Ptr, Ptr, Ptr, UInt32) -> Handle?).self),
              let d = f("WinHttpSetOption", (@convention(c) (Handle, UInt32, Ptr, UInt32) -> Int32).self),
              let e = f("WinHttpAddRequestHeaders", (@convention(c) (Handle, Ptr, UInt32, UInt32) -> Int32).self),
              let g = f("WinHttpSendRequest", (@convention(c) (Handle, Ptr, UInt32, Ptr, UInt32, UInt32, UInt) -> Int32).self),
              let h = f("WinHttpReceiveResponse", (@convention(c) (Handle, Ptr) -> Int32).self),
              let i = f("WinHttpWebSocketCompleteUpgrade", (@convention(c) (Handle, UInt) -> Handle?).self),
              let j = f("WinHttpWebSocketSend", (@convention(c) (Handle, UInt32, Ptr, UInt32) -> UInt32).self),
              let k = f("WinHttpWebSocketReceive", (@convention(c) (Handle, UnsafeMutableRawPointer?, UInt32, UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>) -> UInt32).self),
              let l = f("WinHttpWebSocketShutdown", (@convention(c) (Handle, UInt16, Ptr, UInt32) -> UInt32).self),
              let m = f("WinHttpWebSocketQueryCloseStatus", (@convention(c) (Handle, UnsafeMutablePointer<UInt16>, UnsafeMutableRawPointer?, UInt32, UnsafeMutablePointer<UInt32>) -> UInt32).self),
              let n = f("WinHttpCloseHandle", (@convention(c) (Handle) -> Int32).self),
              let o = f("WinHttpSetTimeouts", (@convention(c) (Handle, Int32, Int32, Int32, Int32) -> Int32).self)
        else { return nil }
        return WinHttpApi(open: a, connect: b, openRequest: c, setOption: d, addHeaders: e, sendRequest: g,
                          receiveResponse: h, completeUpgrade: i, wsSend: j, wsReceive: k, wsClose: l,
                          wsQueryClose: m, closeHandle: n, setTimeouts: o)
    }()
}

/// **The remote control line on Windows, through WinHTTP's own WebSocket support.**
///
/// There is no loadable libcurl on Windows (it is linked statically into Foundation), so
/// ``CurlLine`` never comes up and the `URLSession` line used to be the fallback. That one
/// keeps the libdispatch socket source firing while idle: measured on the home screen with
/// nothing playing, about 45 to 80 percent of one core against 0.3 percent with the channel
/// off. WinHTTP blocks in the kernel instead. Like ``CurlLine`` one thread reads; sending
/// works from any thread under a lock. WinHTTP answers ping itself and ignores a pong.
final class WinHttpLine: RemoteLink, @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible {
        let text: String
        var description: String { text }
    }

    private let api: WinHttpApi
    private let petition: URLRequest
    private let barrier = NSLock()
    private let sendBarrier = NSLock()
    private var session: Handle?
    private var connection: Handle?
    private var socket: Handle?
    private var ended = false
    private var closeCode: Int?
    private var closeReason: String?
    private var lastError: String?

    private let output: AsyncThrowingStream<String?, Error>.Continuation
    private var reader: AsyncThrowingStream<String?, Error>.AsyncIterator

    init?(petition: URLRequest) {
        guard let api = WinHttpApi.loaded, let url = petition.url, url.host != nil else { return nil }
        self.api = api
        self.petition = petition
        let (feed, output) = AsyncThrowingStream.makeStream(of: String?.self)
        self.output = output
        reader = feed.makeAsyncIterator()
    }

    func buildUp() {
        let thread = Thread { [self] in read() }
        thread.name = "Fernleitung"
        thread.start()
    }

    func receive() async throws -> String? {
        guard let next = try await reader.next() else { throw Failure(text: "Leitung geschlossen") }
        return next
    }

    func dispatch(_ text: String) async throws {
        try sendSync(Array(text.utf8))
    }

    private func sendSync(_ bytes: [UInt8]) throws {
        sendBarrier.lock(); defer { sendBarrier.unlock() }
        barrier.lock()
        let h = socket
        let shut = ended
        barrier.unlock()
        guard let h, !shut else { throw Failure(text: "keine Leitung") }
        let rc = bytes.withUnsafeBytes { api.wsSend(h, 2, $0.baseAddress, UInt32($0.count)) }
        if rc != 0 { throw Failure(text: "WinHTTP \(rc)") }
    }

    func close() {
        barrier.lock()
        let was = ended
        ended = true
        let h = socket
        socket = nil
        barrier.unlock()
        if !was, let h {
            // Best effort goodbye with 1001 (going away). Shutdown only sends the close frame and
            // never waits for the server's answer (Close would block with infinite timeouts).
            // Closing the handle then wakes the reader.
            _ = api.wsClose(h, 1001, nil, 0)
            _ = api.closeHandle(h)
        }
        output.finish(throwing: Failure(text: "Leitung geschlossen"))
    }

    var teardownDetails: [String] {
        barrier.lock(); defer { barrier.unlock() }
        var t = ["Leitung: WinHTTP"]
        if let c = closeCode {
            var s = "Schliesscode \(c)"
            if let g = closeReason, !g.isEmpty { s += " (\(g))" }
            t.append(s)
        }
        if let e = lastError { t.append(e) }
        return t
    }

    // MARK: Read thread

    private func wide(_ s: String) -> [UInt16] { Array(s.utf16) + [0] }

    private func failure(_ text: String) {
        barrier.lock()
        lastError = text
        let was = ended
        barrier.unlock()
        if !was { output.finish(throwing: Failure(text: text)) }
    }

    private func read() {
        guard linkUp() else { cleanUp(); return }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var part = Data()
        while true {
            barrier.lock()
            let h = socket
            let shut = ended
            barrier.unlock()
            guard let h, !shut else { break }
            var n: UInt32 = 0
            var type: UInt32 = 0
            let rc = buffer.withUnsafeMutableBytes {
                api.wsReceive(h, $0.baseAddress, UInt32($0.count), &n, &type)
            }
            if rc != 0 {
                barrier.lock(); let was = ended; barrier.unlock()
                if !was { failure("WinHTTP \(rc)") }
                break
            }
            switch type {
            case 4:     // close
                var status: UInt16 = 0
                var reason = [UInt8](repeating: 0, count: 124)
                var len: UInt32 = 0
                if api.wsQueryClose(h, &status, &reason, UInt32(reason.count), &len) == 0 {
                    barrier.lock()
                    closeCode = Int(status)
                    closeReason = String(decoding: reason[0..<Int(min(len, 123))], as: UTF8.self)
                    barrier.unlock()
                }
                failure("von der Gegenstelle geschlossen")
                cleanUp()
                return
            case 2, 3:  // UTF-8 message / fragment
                part.append(buffer, count: Int(n))
                if type == 2 {
                    output.yield(String(decoding: part, as: UTF8.self))
                    part.removeAll(keepingCapacity: true)
                }
            default:
                // Binary data still counts as a sign of life.
                if type == 0 { output.yield(nil) }
            }
        }
        cleanUp()
    }

    private func setupFailed(_ what: String) {
        let code = GetLastError()
        // 12002 timeout, 12007 name not resolved, 12029 cannot connect: plain network trouble.
        let network = [12002, 12007, 12029, 12030, 12152].contains(Int(code))
        let text = "\(what): WinHTTP \(code)"
        barrier.lock(); lastError = text; let was = ended; barrier.unlock()
        if !was { output.finish(throwing: LineSetupFailed(code: network ? 7 : 1, text: text)) }
    }

    private func linkUp() -> Bool {
        guard let url = petition.url, let host = url.host else { return false }
        let secure = ["wss", "https"].contains((url.scheme ?? "").lowercased())
        let port = UInt16(url.port ?? (secure ? 443 : 80))
        // Keep the percent-encoding: a decoded path breaks on spaces.
        let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        var path = encodedPath.isEmpty ? "/" : encodedPath
        if let q = url.query { path += "?" + q }

        let agent = wide("Swiftly")
        guard let s = agent.withUnsafeBufferPointer({ api.open($0.baseAddress, 4, nil, nil, 0) }) else {
            setupFailed("WinHttpOpen"); return false
        }
        barrier.lock(); session = s; let shut = ended; barrier.unlock()
        if shut { return false }
        // 15 s to connect and handshake, like the curl line.
        _ = api.setTimeouts(s, 15_000, 15_000, 15_000, 15_000)
        let hostW = wide(host)
        guard let c = hostW.withUnsafeBufferPointer({ api.connect(s, $0.baseAddress, port, 0) }) else {
            setupFailed("WinHttpConnect"); return false
        }
        barrier.lock(); connection = c; barrier.unlock()

        let flags: UInt32 = secure ? 0x0080_0000 : 0
        let verb = wide("GET"), target = wide(path)
        guard let r = verb.withUnsafeBufferPointer({ v in
            target.withUnsafeBufferPointer { t in
                api.openRequest(c, v.baseAddress, t.baseAddress, nil, nil, nil, flags)
            }
        }) else { setupFailed("WinHttpOpenRequest"); return false }
        defer { _ = api.closeHandle(r) }

        if api.setOption(r, 114, nil, 0) == 0 { setupFailed("Upgrade"); return false }
        var headers = ""
        for (name, value) in petition.allHTTPHeaderFields ?? [:] { headers += "\(name): \(value)\r\n" }
        if !headers.isEmpty {
            let w = wide(headers)
            let ok = w.withUnsafeBufferPointer { api.addHeaders(r, $0.baseAddress, UInt32.max, 0x2000_0000 | 0x8000_0000) }
            if ok == 0 { setupFailed("Headers"); return false }
        }
        if api.sendRequest(r, nil, 0, nil, 0, 0, 0) == 0 { setupFailed("SendRequest"); return false }
        if api.receiveResponse(r, nil) == 0 { setupFailed("ReceiveResponse"); return false }
        guard let ws = api.completeUpgrade(r, 0) else { setupFailed("CompleteUpgrade"); return false }
        // No timeouts on the open socket: the reader blocks until something arrives.
        _ = api.setTimeouts(ws, 0, 0, 0, 0)
        barrier.lock(); socket = ws; let was = ended; barrier.unlock()
        if was {
            _ = api.closeHandle(ws)
            barrier.lock(); socket = nil; barrier.unlock()
            return false
        }
        return true
    }

    private func cleanUp() {
        barrier.lock()
        let ws = socket, c = connection, s = session
        socket = nil; connection = nil; session = nil
        barrier.unlock()
        if let ws { _ = api.closeHandle(ws) }
        if let c { _ = api.closeHandle(c) }
        if let s { _ = api.closeHandle(s) }
    }
}
#endif
