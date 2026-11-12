import Foundation
import Network
import Synchronization

/// A tiny Jellyfin on 127.0.0.1 for the tests: answers the calls of the home page from the JSON
/// fixtures of `crates/swiftly-vm/tests/fixtures` (the Rust tests use the same files), can hold
/// every answer back and records what was asked. No real server is ever contacted.
final class FixtureServer: Sendable {
    struct Seen: Sendable {
        let target: String
        let authorization: String
    }

    private struct State {
        var seen: [Seen] = []
        var hold = false
        var emptyLists = false
        var groups = "[]"
        var parked: [@Sendable () -> Void] = []
    }

    private let state = Mutex(State())
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fixture-server")
    private let fixtures: URL

    private init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        // .../Packages/SwiftlyCore/Tests/SwiftlyCoreTests/FixtureServer.swift -> repository root
        var root = URL(filePath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        fixtures = root.appending(path: "crates/swiftly-vm/tests/fixtures")
    }

    /// Starts listening; returns when the port is known.
    static func start(hold: Bool = false) async throws -> FixtureServer {
        let server = try FixtureServer()
        server.state.withLock { $0.hold = hold }
        server.listener.newConnectionHandler = { [server] connection in server.accept(connection) }
        let resumed = Mutex(false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            server.listener.stateUpdateHandler = { newState in
                let first = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                guard first else { return }
                switch newState {
                case .ready: continuation.resume()
                case .failed(let error): continuation.resume(throwing: error)
                default: resumed.withLock { $0 = false }
                }
            }
            server.listener.start(queue: server.queue)
        }
        return server
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var address: String { "http://127.0.0.1:\(port)" }
    var seen: [Seen] { state.withLock { $0.seen } }

    /// The body of `GET /SyncPlay/List`.
    func answerGroups(_ json: String) { state.withLock { $0.groups = json } }

    func stop() { listener.cancel() }

    /// Plain item lists (no search, no ids) come back empty: a person or playlist without titles.
    func answerEmptyLists() { state.withLock { $0.emptyLists = true } }

    /// Answers wait until `release()`.
    func hold() { state.withLock { $0.hold = true } }

    func release() {
        let parked = state.withLock { state -> [@Sendable () -> Void] in
            state.hold = false
            defer { state.parked = [] }
            return state.parked
        }
        for send in parked { send() }
    }

    // MARK: connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                respond(connection, head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if error == nil && !isComplete {
                read(connection, buffer: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let authorization =
            lines.first { $0.lowercased().hasPrefix("authorization:") }
            .map { String($0.dropFirst("authorization:".count)).trimmingCharacters(in: .whitespaces) } ?? ""
        let body = answer(target: target, authorization: authorization)
        let reply = Data(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                .utf8) + body
        let send: @Sendable () -> Void = {
            connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
        }
        let now = state.withLock { state -> Bool in
            state.seen.append(Seen(target: target, authorization: authorization))
            if state.hold { state.parked.append(send) }
            return !state.hold
        }
        if now { send() }
    }

    // MARK: the scripted server (the same routes as the Rust test transport)

    private func load(_ name: String) -> [[String: Any]] {
        let data = (try? Data(contentsOf: fixtures.appending(path: "\(name).json"))) ?? Data("{}".utf8)
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["Items"] as? [[String: Any]] ?? []
    }

    private func list(_ items: [[String: Any]]) -> Data {
        let object: [String: Any] = ["Items": items, "TotalRecordCount": items.count]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    private func seasons() -> [[String: Any]] {
        (1...2).map { ["Id": "se\($0)", "Name": "Staffel \($0)", "Type": "Season", "IndexNumber": $0] }
    }

    private func episode(season: Int, number: Int) -> [String: Any] {
        [
            "Id": "s1-\(season)-\(number)", "Name": "Folge \(number)", "Type": "Episode",
            "IndexNumber": number, "ParentIndexNumber": season, "SeasonId": "se\(season)",
            "SeriesId": "s1", "RunTimeTicks": 27_000_000_000,
            "UserData": ["Played": number == 1],
        ]
    }

    private func answer(target: String, authorization: String) -> Data {
        let components = URLComponents(string: "http://x" + target)
        let path = components?.path ?? ""
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let second = authorization.contains("TOKEN-B")
        let catalog = load(second ? "catalog_b" : "catalog")
        func pick(_ ids: [String]) -> [[String: Any]] {
            ids.compactMap { id in catalog.first { ($0["Id"] as? String) == id } }
        }
        if path == "/System/Info/Public" {
            return Data(#"{"ServerName":"Testserver","Version":"10.10.0","Id":"srv1"}"#.utf8)
        }
        if path == "/Users/AuthenticateByName" {
            return Data(
                #"{"AccessToken":"TOKEN-A","ServerId":"srv1","User":{"Id":"user-a","Name":"Anna"}}"#.utf8)
        }
        if path == "/SyncPlay/List" { return Data(state.withLock { $0.groups }.utf8) }
        if path.hasSuffix("/UserViews") { return list(load("views")) }
        if path.hasSuffix("/UserItems/Resume") { return list(pick(second ? ["x1"] : ["r1", "e1"])) }
        if path.hasSuffix("/Shows/NextUp") { return list(pick(second ? [] : ["e1", "e2"])) }
        if path.hasSuffix("/Similar") { return list(pick(["m2", "m3"])) }
        if path.hasSuffix("/SpecialFeatures") { return Data("[]".utf8) }
        if path.hasSuffix("/Seasons") { return list(seasons()) }
        if path.hasSuffix("/Episodes") {
            let season = query["seasonId"] == "se2" ? 2 : 1
            return list((1...3).map { episode(season: season, number: $0) })
        }
        if path.hasSuffix("/Items"), let term = query["searchTerm"] {
            let hits = catalog.filter { item in
                let type = item["Type"] as? String
                return (type == "Movie" || type == "Series")
                    && (item["Name"] as? String)?.localizedCaseInsensitiveContains(term) == true
            }
            return list(hits)
        }
        // One title by id (`/Users/<user>/Items/<id>`): the catalog entry, completed like a full fetch.
        if let range = path.range(of: "/Items/"), !path[range.upperBound...].contains("/") {
            let id = String(path[range.upperBound...])
            guard var item = catalog.first(where: { ($0["Id"] as? String) == id }) else { return Data("{}".utf8) }
            item["Overview"] = "Eine Geschichte."
            item["Genres"] = ["Drama"]
            if (item["Type"] as? String) != "Series" {
                item["MediaSources"] = [["Id": "src-\(id)", "Name": "Hauptfassung"]]
            }
            return (try? JSONSerialization.data(withJSONObject: item)) ?? Data("{}".utf8)
        }
        if path.hasSuffix("/Items") {
            if state.withLock({ $0.emptyLists }), query["Ids"] == nil, query["Genres"] == nil { return list([]) }
            if let ids = query["Ids"] { return list(pick(ids.split(separator: ",").map(String.init))) }
            if let genre = query["Genres"] {
                // A genre row: 24 generated titles.
                return list(
                    (0..<24).map { n in
                        [
                            "Id": "\(genre)-\(n)", "Name": "\(genre) \(n)", "Type": "Movie",
                            "ProductionYear": 2000 + n, "ImageTags": ["Primary": "p-\(genre)-\(n)"],
                            "UserData": ["Played": false],
                        ]
                    })
            }
            return list(pick(second ? ["x2"] : ["m1", "m2", "m3"]))
        }
        return Data("{}".utf8)
    }
}
