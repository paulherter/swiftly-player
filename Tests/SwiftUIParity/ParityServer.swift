import AppKit
import Foundation
import Network

/// A tiny Jellyfin-shaped HTTP server on the loopback interface, only for the parity renders: the title, series, person and
/// playlist pages are owned by the Rust core, which loads over the network, so "loaded" needs something to load from. The
/// server hands out the fixture JSON the test registered (`items`), empty lists for everything else, and generated
/// pictures for every `/Images/` address. Every request path is logged to `requests.log` in the output folder.
final class ParityServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var routes: [(String, String)] = []
    /// Answers every request with a dropped connection: the offline state.
    var offline = false
    private var pictures: [String: Data] = [:]
    private var log: [String] = []
    private let queue = DispatchQueue(label: "parity.server")
    private let picture: @Sendable (String, Bool) -> Data
    private(set) var port: UInt16 = 0

    /// `picture(id, portrait)` returns PNG bytes.
    init(picture: @escaping @Sendable (String, Bool) -> Data) throws {
        listener = try NWListener(using: .tcp, on: .any)
        self.picture = picture
    }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [self] conn in handle(conn) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    func stop() { listener.cancel() }
    var url: URL { URL(string: "http://127.0.0.1:\(port)")! }

    /// Adds a route: requests whose address contains `part` get `json` (routes are tried in the order added).
    func route(_ part: String, _ json: String) { lock.lock(); routes.append((part, json)); lock.unlock() }
    func clearRoutes() { lock.lock(); routes = []; lock.unlock() }
    static func list(_ rows: [String]) -> String { #"{"Items":[\#(rows.joined(separator: ","))],"TotalRecordCount":\#(rows.count)}"# }
    func writeLog(to url: URL) {
        lock.lock(); let text = log.joined(separator: "\n"); lock.unlock()
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, _, _ in
            guard let data, let head = String(data: data, encoding: .utf8) else { return conn.cancel() }
            let line = head.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            let parts = line.split(separator: " ")
            let target = parts.count > 1 ? String(parts[1]) : "/"
            // Offline: everything but pictures (the Rust page keeps the pictures it already holds) drops the connection.
            if offline, !target.contains("/Images/") { return conn.cancel() }
            let (type, body) = answer(target)
            var out = Data("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            out.append(body)
            conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    private func answer(_ target: String) -> (String, Data) {
        let path = URLComponents(string: "http://x" + target)?.path ?? target
        lock.lock(); log.append(target); lock.unlock()
        let segs = path.split(separator: "/").map(String.init)
        if let at = segs.firstIndex(of: "Images"), at >= 1 {
            let id = segs[at - 1]
            let portrait = segs.last == "Primary" && !id.hasPrefix("e") && !id.hasPrefix("se")
            let key = id + (portrait ? "p" : "l")
            lock.lock(); let cached = pictures[key]; lock.unlock()
            let data = cached ?? picture(id, portrait)
            lock.lock(); pictures[key] = data; lock.unlock()
            return ("image/png", data)
        }
        // Like the Rust demo's scripted transport: the first route whose text is in the address answers.
        lock.lock(); let hit = routes.first { target.contains($0.0) }?.1; lock.unlock()
        if let hit { return ("application/json", Data(hit.utf8)) }
        return ("application/json", Data(#"{"Items":[],"TotalRecordCount":0}"#.utf8))
    }
}
