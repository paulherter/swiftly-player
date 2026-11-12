import Foundation
@testable import JellyfinKit

// requests_plex: the REAL Swift PlexClient / PlexAccountService / PlexConnector / PlexPlayback over a URLProtocol
// stub (canned answers by path, every outgoing request recorded in full) and the URL builders.
// Cases: crates/swiftly-hardening/src/inputs/requests_plex.rs, test: tests/oracle_requests_plex.rs.
// Only the recorded requests and built URLs are compared, never decoded results.

private func pxDict(_ raw: Any) throws -> [String: Any] {
    guard let d = raw as? [String: Any] else { throw OracleError("case is not an object") }
    return d
}

private func pxSync<T>(_ work: @escaping @Sendable () async -> T) -> T {
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var out: T?
    Task.detached {
        out = await work()
        sem.signal()
    }
    sem.wait()
    return out!
}

// MARK: - Recording (the same hand-written URL split and header rules exist in tests/oracle_requests_plex.rs)

private func pxDecode(_ s: Substring) -> String {
    let u = Array(s.utf8)
    var bytes: [UInt8] = []
    var i = 0
    func hex(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x41...0x46: return b - 0x41 + 10
        case 0x61...0x66: return b - 0x61 + 10
        default: return nil
        }
    }
    while i < u.count {
        if u[i] == 0x25, i + 2 < u.count, let a = hex(u[i + 1]), let b = hex(u[i + 2]) {
            bytes.append(a * 16 + b)
            i += 3
        } else {
            bytes.append(u[i])
            i += 1
        }
    }
    return String(decoding: bytes, as: UTF8.self)
}

private func pxSplit(_ url: String) -> [String: Any] {
    var rest = Substring(url)
    var fragment: Any = NSNull()
    if let h = rest.firstIndex(of: "#") {
        fragment = String(rest[rest.index(after: h)...])
        rest = rest[..<h]
    }
    var rawQuery: Any = NSNull()
    var pairs: [[String]] = []
    if let q = rest.firstIndex(of: "?") {
        let rq = rest[rest.index(after: q)...]
        rawQuery = String(rq)
        rest = rest[..<q]
        for part in rq.split(separator: "&", omittingEmptySubsequences: false) {
            if let e = part.firstIndex(of: "=") {
                pairs.append([pxDecode(part[..<e]), pxDecode(part[part.index(after: e)...])])
            } else {
                pairs.append([pxDecode(part), ""])
            }
        }
    }
    var origin = ""
    var path = String(rest)
    if let r = rest.range(of: "://") {
        let after = rest[r.upperBound...]
        if let slash = after.firstIndex(of: "/") {
            origin = String(rest[..<slash])
            path = String(after[slash...])
        } else {
            origin = String(rest)
            path = ""
        }
    }
    return ["url": url, "origin": origin, "path": path, "rawQuery": rawQuery, "query": pairs, "fragment": fragment]
}

private let pxSkipHeaders: Set<String> = ["accept-encoding", "accept-language", "user-agent", "connection", "host",
                                           "content-length", "cookie", "cache-control", "pragma"]

private func pxRecord(_ request: URLRequest, body: Data?, sid: String) -> [String: Any] {
    var rec = pxSplit(request.url?.absoluteString ?? "")
    rec["method"] = request.httpMethod ?? "GET"
    var headers: [[String]] = []
    for (k, v) in request.allHTTPHeaderFields ?? [:] where !pxSkipHeaders.contains(k.lowercased()) {
        headers.append([k.lowercased(), v == sid ? "<SID>" : v])
    }
    headers.sort { ($0[0], $0[1]) < ($1[0], $1[1]) }
    rec["headers"] = headers
    rec["timeout"] = request.timeoutInterval == 60 ? NSNull() : request.timeoutInterval as Any
    rec["body"] = body.flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
        ?? body.flatMap { String(data: $0, encoding: .utf8) } ?? NSNull()
    return rec
}

final class PxStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: (Int, Data)] = [:]
    nonisolated(unsafe) static var fallback: (Int, Data) = (200, Data())
    nonisolated(unsafe) static var netCode: Int?
    nonisolated(unsafe) static var seen: [[String: Any]] = []
    nonisolated(unsafe) static var sid = ""
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var bodyData = request.httpBody
        if bodyData == nil, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            var all = Data()
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                all.append(contentsOf: buf[0..<n])
            }
            stream.close()
            bodyData = all
        }
        let url = request.url!
        PxStub.lock.lock()
        PxStub.seen.append(pxRecord(request, body: bodyData, sid: PxStub.sid))
        let net = PxStub.netCode
        let path = (pxSplit(url.absoluteString)["path"] as? String) ?? ""
        let (status, body) = PxStub.routes[path] ?? PxStub.fallback
        PxStub.lock.unlock()
        if let code = net {
            client?.urlProtocol(self, didFailWithError: URLError(URLError.Code(rawValue: code)))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func pxJSON(_ x: Any?) -> Data? {
    guard let x, !(x is NSNull) else { return nil }
    return try? JSONSerialization.data(withJSONObject: x, options: [.fragmentsAllowed])
}

private func pxStrings(_ x: Any?) -> [String] { (x as? [Any])?.compactMap { $0 as? String } ?? [] }

private func pxPairs(_ x: Any?) -> [(String, String)] {
    ((x as? [Any]) ?? []).compactMap { p in
        guard let a = p as? [Any], a.count == 2, let k = a[0] as? String, let v = a[1] as? String else { return nil }
        return (k, v)
    }
}

private func pxSorting(_ s: String?) -> Sorting {
    switch s ?? "" {
    case "latest": .latest
    case "rating": .rating
    case "erscheinung": .erscheinung
    default: .name
    }
}

private func pxFilter(_ s: String?) -> LibraryFilter {
    switch s ?? "" {
    case "begun": .begun
    case "unwatched": .unwatched
    case "watchlist": .watchlist
    default: .all
    }
}

private func pxKind(_ s: String?) -> ImageKind {
    switch s ?? "" {
    case "background": .background
    case "logo": .logo
    case "preview": .preview
    default: .poster
    }
}

private func pxState(_ s: String?) -> PlexPlayback.State {
    switch s ?? "" {
    case "paused": .paused
    case "buffering": .buffering
    case "stopped": .stopped
    default: .playing
    }
}

let domainRequestsPlex = Domain("requests_plex") { raw in
    let c = try pxDict(raw)
    let reply = (c["reply"] as? [String: Any]) ?? [:]
    func answer(_ x: Any?) -> (Int, Data) {
        let d = (x as? [String: Any]) ?? [:]
        return (srInt(d["status"]) ?? 200, Data((srStr(d["body"]) ?? "").utf8))
    }
    PxStub.seen = []
    PxStub.netCode = srInt(reply["net"])
    PxStub.fallback = answer(reply["default"])
    PxStub.routes = [:]
    for (path, value) in (reply["routes"] as? [String: Any]) ?? [:] { PxStub.routes[path] = answer(value) }

    guard let base = URL(string: srStr(c["base"]) ?? "http://plex.test:32400") else { return ["bad_base"] as [Any] }
    let ident = (c["ident"] as? [String: Any]) ?? [:]
    let identity = PlexIdentity(clientID: srStr(ident["client"]) ?? "cid", product: srStr(ident["product"]) ?? "Swiftly Player",
                                version: srStr(ident["version"]) ?? "1.0", platform: srStr(ident["platform"]) ?? "iOS",
                                platformVersion: srStr(ident["platform_version"]), device: srStr(ident["device"]) ?? "iOS",
                                deviceName: srStr(ident["device_name"]) ?? "dn")
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [PxStub.self]
    let urlSession = URLSession(configuration: config)
    let client = PlexClient(baseURL: base, token: srStr(c["token"]) ?? "", identity: identity, urlSession: urlSession)
    PxStub.sid = client.sessionID
    let tv = srStr(c["tv"]) ?? "http://tv.test"
    let clients = srStr(c["clients"]) ?? "http://clients.test"
    let apps = srStr(c["app"]) ?? "http://app.test"
    let accounts = PlexAccountService(identity: identity, urlSession: urlSession, tvBase: URL(string: tv)!,
                                      clientsBase: URL(string: clients)!, appBase: URL(string: apps)!)

    let op = srStr(c["op"]) ?? ""
    let id = srStr(c["id"]) ?? ""
    let limit = srInt(c["limit"]) ?? 20
    let start = srInt(c["start"]) ?? 0
    let size = srInt(c["size"]) ?? 50
    let on = srBool(c["on"]) ?? false
    let optMaxH = srInt(c["h"])
    let optMaxW = srInt(c["w"])
    let itemJSON = pxJSON(c["item"]).flatMap { try? JSONDecoder().decode(Item.self, from: $0) }
    let tr = srStr(c["token2"]) ?? "tok2"

    let result: Any = pxSync {
        switch op {
        // Server
        case "info": _ = try? await client.info()
        case "token_works": _ = try? await client.tokenWorks()
        case "sections": _ = try? await client.sections()
        case "views": _ = try? await client.views()
        case "list":
            _ = try? await client.list(section: id, type: srStr(c["type"]), sort: pxSorting(srStr(c["sort"])),
                                       filter: pxFilter(srStr(c["filter"])), genreID: srStr(c["genre"]),
                                       start: start, size: size)
        case "genres_section": _ = try? await client.genres(section: id)
        case "continue": _ = try? await client.continueWatching(limit: limit)
        case "on_deck": _ = try? await client.onDeck(limit: limit)
        case "recent": _ = try? await client.recentlyAdded(section: srStr(c["section"]), limit: limit)
        case "hubs": _ = try? await client.hubs(section: srStr(c["section"]))
        case "search": _ = try? await client.search(srStr(c["term"]) ?? "", limit: limit)
        case "detail": _ = try? await client.detail(id)
        case "item": _ = try? await client.item(id)
        case "children": _ = try? await client.children(id)
        case "episodes": _ = try? await client.episodes(seriesID: id, seasonID: srStr(c["season"]))
        case "similar": _ = try? await client.similar(id, limit: limit)
        case "collections": _ = try? await client.collections(section: id)
        case "collection_items": _ = try? await client.collectionItems(id)
        case "playlists": _ = try? await client.playlists()
        case "playlist_items": _ = try? await client.playlistItems(id)
        case "titles":
            _ = try? await client.titles(section: id, filter: srStr(c["filter"]) ?? "", value: srStr(c["value"]) ?? "",
                                         start: start, size: size)
        case "watched": try? await client.setWatched(id, on)
        case "favorite": try? await client.setFavorite(id, on)
        case "tracks":
            try? await client.chooseTracks(partID: srInt(c["part"]) ?? 0, audioStreamID: srInt(c["audio"]),
                                           subtitleStreamID: srInt(c["sub"]))
        case "plan":
            if let p = try? await client.plan(for: id, mediaSourceID: srStr(c["source"]), audioStreamID: srInt(c["audio"]),
                                              subtitleStreamID: srInt(c["sub"])) {
                return ["plan", p.url.absoluteString] as [Any]
            }
            return ["plan", NSNull()] as [Any]
        case "download":
            return ["download", nsnull(try? await client.downloadURL(id, mediaSourceID: srStr(c["source"])).absoluteString)] as [Any]
        case "previews": _ = try? await client.previews(id, mediaSourceID: srStr(c["source"]))
        case "segments": _ = try? await client.segments(id)
        case "timeline":
            try? await client.reportTimeline(id, state: pxState(srStr(c["state"])), positionTicks: Int64(srInt(c["ticks"]) ?? 0),
                                             durationMilliseconds: srInt(c["duration"]))
        case "report":
            // The MediaServer reports with a plan from the detail (its length becomes `duration`).
            guard let plan = try? await client.plan(for: id) else { return ["no_plan"] as [Any] }
            let ticks = Int64(srInt(c["ticks"]) ?? 0)
            switch srStr(c["kind"]) ?? "" {
            case "start": try? await client.reportStart(itemID: id, plan: plan, ticks: ticks)
            case "progress": try? await client.reportProgress(itemID: id, plan: plan, positionTicks: ticks, paused: false)
            case "paused": try? await client.reportProgress(itemID: id, plan: plan, positionTicks: ticks, paused: true)
            default: try? await client.reportStopped(itemID: id, plan: plan, positionTicks: ticks)
            }
        // URL builders
        case "image_path":
            return ["url", nsnull(client.imageURL(path: srStr(c["path"]) ?? "", maxHeight: optMaxH, maxWidth: optMaxW)?.absoluteString)] as [Any]
        case "image_item":
            guard let item = itemJSON else { return ["no_item"] as [Any] }
            return ["url", nsnull(client.imageURL(for: item, kind: pxKind(srStr(c["kind"])), maxHeight: optMaxH, maxWidth: optMaxW)?.absoluteString)] as [Any]
        case "image_server":
            guard let item = itemJSON else { return ["no_item"] as [Any] }
            return ["url", nsnull(await client.imageURL(for: item, maxHeight: optMaxH ?? 480)?.absoluteString)] as [Any]
        case "sub_stream":
            guard let d = pxJSON(c["stream"]), let stream = try? JSONDecoder().decode(PlexStream.self, from: d) else { return ["no_stream"] as [Any] }
            return ["url", nsnull(client.subtitleURL(stream)?.absoluteString)] as [Any]
        case "sub_path": return ["url", nsnull(client.subtitleURL(path: srStr(c["path"]) ?? "")?.absoluteString)] as [Any]
        case "playback_url":
            let pb = PlexPlayback(base: base, token: srStr(c["token"]) ?? "")
            switch srStr(c["fn"]) ?? "" {
            case "url": return ["url", nsnull(pb.url(path: srStr(c["path"]) ?? "", query: pxPairs(c["query"]), withToken: srBool(c["with_token"]) ?? false)?.absoluteString)] as [Any]
            case "file": return ["url", nsnull(pb.fileURL(partKey: srStr(c["path"]) ?? "", download: srBool(c["download"]) ?? false)?.absoluteString)] as [Any]
            default: return ["url", nsnull(pb.previewIndexURL(partID: srInt(c["part"]) ?? 0)?.absoluteString)] as [Any]
            }
        // MediaServer layer
        case "items":
            _ = try? await client.items(parentID: srStr(c["parent"]), limit: limit, startIndex: start,
                                        sortBy: srStr(c["sort_by"]) ?? "SortName", sortOrder: srStr(c["sort_order"]) ?? "Ascending",
                                        filters: pxStrings(c["filters"]), isWatched: srBool(c["watched"]),
                                        recursive: srBool(c["recursive"]) ?? false, includeItemTypes: pxStrings(c["types"]),
                                        ids: pxStrings(c["ids"]), personIDs: pxStrings(c["persons"]),
                                        genres: pxStrings(c["genres"]), slim: false)
        case "genres_all": _ = try? await client.genres()
        case "last_added":
            _ = await client.lastAdded(in: srStr(c["library"]), fetch: srInt(c["fetch"]) ?? 200, showItem: srInt(c["show"]) ?? 24,
                                       genres: srStr(c["genres"]) ?? "Movie,Episode")
        case "new_arrivals": _ = await client.newArrivals(genre: srStr(c["genres"]) ?? "Movie", fetch: srInt(c["fetch"]) ?? 200, showItem: srInt(c["show"]) ?? 24)
        case "new_series": _ = await client.newSeries(in: srStr(c["library"]), showItem: srInt(c["show"]) ?? 24)
        case "latest_title": _ = await client.latestTitle(in: id, collection: srBool(c["collection"]) ?? false, showItem: srInt(c["show"]) ?? 24)
        case "playlist_dir": _ = try? await client.playlistDirectory()
        case "playlist_entries": _ = try? await client.playlistEntries(id)
        case "collection_dir": _ = try? await client.collectionDirectory()
        case "remembered":
            _ = try? await client.rememberedItems(types: pxStrings(c["types"]), sortBy: srStr(c["sort_by"]) ?? "SortName",
                                                  sortOrder: srStr(c["sort_order"]) ?? "Ascending", startIndex: start, limit: limit)
        case "title_person": _ = await client.titleWithNumber(person: id, limit: limit, startIndex: start)
        case "title_genre": _ = await client.titleWithNumber(genre: id, limit: limit, startIndex: start)
        case "next_episode": _ = try? await client.nextEpisodeSeries(seriesID: id)
        case "episode_post": _ = try? await client.episodePost(itemID: srStr(c["item_id"]) ?? "", seriesID: id)
        case "state_in_series": _ = await client.stateInSeries(id)
        case "refresh": try? await client.metadataRefresh(id)
        case "watchlist": try? await client.setWatchlist(itemID: id, an: on)
        case "watched_ms": try? await client.setWatched(itemID: id, an: on)
        case "point_back": try? await client.pointBackSet(itemID: id)
        case "trickplay": _ = await client.trickplay(itemID: id, mediaSourceID: srStr(c["source"]))
        case "sheet": _ = await client.trickplaySheet(itemID: id, mediaSourceID: srStr(c["source"]), width: 320, sheet: srInt(c["sheet"]) ?? 0)
        case "chapter": _ = await client.chapter(itemID: id, mediaSourceID: nil)
        case "extras": _ = try? await client.extras(itemID: id)
        case "trailer": _ = try? await client.trailer(toward: id)
        case "similar_ms": _ = try? await client.similar(itemID: id, limit: limit)
        case "public_info": _ = try? await client.publicSystemInfo()
        case "applies": _ = await client.sessionAppliesStill()
        case "signoff_sections":
            await client.signOff()
            _ = try? await client.sections()
        // plex.tv
        case "pin_start": _ = try? await accounts.startPin(strong: srBool(c["strong"]) ?? true)
        case "pin_check":
            _ = try? await accounts.checkPin(PlexPin(id: srInt(c["pin_id"]) ?? 0, code: srStr(c["code"]) ?? ""))
        case "auth_url":
            let pin = PlexPin(id: 1, code: srStr(c["code"]) ?? "")
            return ["url", nsnull(accounts.authURL(for: pin, forwardURL: srStr(c["forward"]).flatMap { URL(string: $0) })?.absoluteString)] as [Any]
        case "link_page": return ["url", accounts.linkPage.absoluteString] as [Any]
        case "validate": _ = try? await accounts.validate(token: tr)
        case "servers": _ = try? await accounts.servers(token: tr)
        case "home_users": _ = try? await accounts.homeUsers(token: tr)
        case "switch_user":
            let user = try? JSONDecoder().decode(PlexHomeUser.self, from: Data("{\"id\":\"1\",\"uuid\":\(pxQuote(srStr(c["uuid"]) ?? ""))}".utf8))
            if let user { _ = try? await accounts.switchUser(user, pin: srStr(c["pin"]), token: tr) }
        case "probe":
            _ = await PlexConnector.identityMatches(base: base, identity: identity, token: srStr(c["token"]) ?? "",
                                                    machineIdentifier: srStr(c["machine"]) ?? "m",
                                                    timeout: Double(srInt(c["timeout"]) ?? 3), session: urlSession)
        default: return ["bad op"] as [Any]
        }
        return NSNull()
    }
    var seen = PxStub.seen
    if srBool(c["sorted"]) == true {
        func key(_ r: [String: Any]) -> [UInt8] { Array(((r["method"] as? String ?? "") + " " + (r["url"] as? String ?? "")).utf8) }
        seen.sort { key($0).lexicographicallyPrecedes(key($1)) }
    }
    return ["result": result, "seen": seen] as [String: Any]
}

private func pxQuote(_ s: String) -> String {
    let d = try? JSONSerialization.data(withJSONObject: [s], options: [])
    let t = d.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
    return String(t.dropFirst().dropLast())
}
