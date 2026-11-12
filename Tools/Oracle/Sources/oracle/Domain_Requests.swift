import Foundation
@testable import JellyfinKit

// requests_http: every outgoing HTTP request of the Jellyfin / Emby client (`JellyfinClient`), recorded from the
// REAL Swift client over a URLProtocol stub: method, percent-encoded path, query in order (decoded pairs) and raw,
// headers, body (parsed JSON or raw text). Also the addresses the client builds without a request.
// Cases: crates/swiftly-hardening/src/inputs/requests.rs, tests/oracle_requests.rs.

private func rqDict(_ raw: Any) throws -> [String: Any] {
    guard let d = raw as? [String: Any] else { throw OracleError("case is not an object") }
    return d
}

private func rqSync<T>(_ work: @escaping @Sendable () async -> T) -> T {
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var out: T?
    Task.detached {
        out = await work()
        sem.signal()
    }
    sem.wait()
    return out!
}

final class RqStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var seen: [Any] = []

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
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let pairs: [Any] = (comps?.queryItems ?? []).map { [$0.name, $0.value ?? ""] as [Any] }
        var headers: [String: String] = [:]
        // Headers the URL loading system adds to every request on its own (the Rust transport adds its own).
        let system: Set<String> = ["accept-language", "accept-encoding", "user-agent", "content-length", "connection", "host", "cookie"]
        for (k, v) in request.allHTTPHeaderFields ?? [:] where !system.contains(k.lowercased()) { headers[k.lowercased()] = v }
        var body: Any = NSNull()
        if let d = bodyData {
            body = (try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]))
                ?? String(data: d, encoding: .utf8) ?? NSNull()
        }
        RqStub.seen.append([
            "method": request.httpMethod ?? "",
            "path": comps?.percentEncodedPath ?? "",
            "query": pairs,
            "raw_query": comps?.percentEncodedQuery ?? "",
            "headers": headers,
            "body": body,
        ] as [String: Any])
        let response = HTTPURLResponse(url: url, statusCode: RqStub.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: RqStub.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func rqS(_ a: [String: Any], _ k: String) -> String? { srStr(a[k]) }
private func rqI(_ a: [String: Any], _ k: String) -> Int? { srInt(a[k]) }
private func rqList(_ a: [String: Any], _ k: String) -> [String] { (a[k] as? [Any])?.compactMap { srStr($0) } ?? [] }

private func rqItem(_ a: [String: Any]) throws -> Item {
    var o: [String: Any] = ["Id": rqS(a, "id") ?? "", "Name": "n"]
    if let t = rqS(a, "primary") { o["ImageTags"] = ["Primary": t] }
    if let t = rqS(a, "backdrop") { o["BackdropImageTags"] = [t] }
    return try JSONDecoder().decode(Item.self, from: JSONSerialization.data(withJSONObject: o))
}

private func rqPlan(_ a: [String: Any]) -> PlaybackPlan {
    let method: DeliveryMethod = switch rqS(a, "method") ?? "" {
    case "direct_stream": .directStream
    case "transcode": .transcode
    default: .directPlay
    }
    return PlaybackPlan(url: URL(string: "http://x.test/v")!, method: method, mediaSourceID: rqS(a, "source"),
                        playSessionID: rqS(a, "play"), container: nil, reasons: [], source: nil)
}

private func rqProfile(_ a: [String: Any]) -> DeviceProfile {
    let max = rqI(a, "max_bitrate") ?? 1_000_000_000
    return rqS(a, "profile") == "airplay" ? .airplay(maxBitrate: max, av1: srBool(a["av1"]) == true) : .vlc(maxBitrate: max)
}

private func rqQuality(_ a: [String: Any]) -> DownloadQuality {
    DownloadQuality(rawValue: rqS(a, "quality") ?? "original") ?? .original
}


let domainRequestsHttp = Domain("requests_http") { raw in
    let c = try rqDict(raw)
    let a = (c["a"] as? [String: Any]) ?? [:]
    RqStub.seen = []
    RqStub.status = srInt(c["status"]) ?? 200
    RqStub.body = Data((srStr(c["body"]) ?? "{\"Items\":[],\"TotalRecordCount\":0}").utf8)
    guard let base = URL(string: srStr(c["base"]) ?? "http://example.test:8096") else { throw OracleError("bad base") }
    let kind: ServerKind = (srStr(c["kind"]) ?? "") == "emby" ? .emby : .jellyfin
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RqStub.self]
    let session = srBool(c["no_session"]) == true ? nil
        : Session(accessToken: srStr(c["tok"]) ?? "tok", userID: srStr(c["uid"]) ?? "uid", userName: "nm", serverURL: base, kind: kind)
    let client = JellyfinClient(baseURL: base, deviceID: srStr(c["dev"]) ?? "dev", deviceName: srStr(c["dname"]) ?? "dn",
                                clientVersion: srStr(c["ver"]) ?? "1.0", program: srStr(c["prog"]) ?? "Swiftly Player",
                                session: session, urlSession: URLSession(configuration: config), kind: kind)
    let op = srStr(c["op"]) ?? ""
    let id = rqS(a, "id") ?? ""
    let urls: Any = rqSync {
        if let perm = srStr(c["perm"]) {
            RqStub.body = Data("{\"Policy\":{\"EnableContentDownloading\":\(perm == "allowed")}}".utf8)
            _ = await client.accountDefaults()
            RqStub.body = Data((srStr(c["body"]) ?? "{\"Items\":[],\"TotalRecordCount\":0}").utf8)
            RqStub.seen = []
        }
        func url(_ f: () async throws -> URL?) async -> Any {
            do { return nsnull(try await f()?.absoluteString) } catch { return "err" }
        }
        switch op {
        case "system_info": _ = try? await client.publicSystemInfo()
        case "reachability": _ = try? await client.checkReachability()
        case "authenticate": _ = try? await client.authenticate(username: rqS(a, "user") ?? "", password: rqS(a, "pw") ?? "")
        case "sign_off": await client.signOff()
        case "still": _ = await client.sessionAppliesStill()
        case "views": _ = try? await client.userViews(hidden: srBool(a["hidden"]) == true)
        case "items":
            _ = try? await client.items(
                parentID: rqS(a, "parent"), limit: rqI(a, "limit") ?? 100, startIndex: rqI(a, "start") ?? 0,
                sortBy: rqS(a, "sort_by") ?? "SortName", sortOrder: rqS(a, "sort_order") ?? "Ascending",
                filters: rqList(a, "filters"), isWatched: srBool(a["watched"]), recursive: srBool(a["recursive"]) == true,
                includeItemTypes: rqList(a, "types"), ids: rqList(a, "ids"), personIDs: rqList(a, "people"),
                genres: rqList(a, "genres"), slim: srBool(a["slim"]) == true)
        case "count": _ = try? await client.count(parentID: id, types: rqList(a, "types"))
        case "title_ids":
            _ = try? await client.titleIds(parentID: id, types: rqList(a, "types"), filters: rqList(a, "filters"),
                                           isWatched: srBool(a["watched"]))
        case "identifiers": _ = try? await client.identifiers(ids: rqList(a, "ids"))
        case "ancestors": _ = try? await client.preTravel(from: id)
        case "remembered":
            _ = try? await client.rememberedIds(types: rqList(a, "types"), sortBy: rqS(a, "sort_by") ?? "SortName",
                                                sortOrder: rqS(a, "sort_order") ?? "Ascending")
        case "collection": _ = try? await client.collectionMembers(id)
        case "playlist": _ = try? await client.playlistEntries(id, lean: srBool(a["lean"]) == true)
        case "playback_info":
            _ = try? await client.playbackInfo(itemID: id, profile: rqProfile(a), maxStreamingBitrate: rqI(a, "override"),
                                               audioStreamIndex: rqI(a, "audio"), subtitleStreamIndex: rqI(a, "subtitle"),
                                               mediaSourceID: rqS(a, "source"))
        case "item": _ = try? await client.item(id: id)
        case "genres": _ = try? await client.genres()
        case "similar": _ = try? await client.similar(itemID: id, limit: rqI(a, "limit") ?? 12)
        case "extras": _ = try? await client.extras(itemID: id)
        case "trailers": _ = try? await client.trailer(toward: id)
        case "search": _ = try? await client.search(rqS(a, "term") ?? "", limit: rqI(a, "limit") ?? 40)
        case "user_record": _ = try? await client.userRecord(itemID: id)
        case "last_play":
            try? await client.lastPlaySet(itemID: id, moment: Date(timeIntervalSince1970: Double(rqI(a, "ms") ?? 0) / 1000))
        case "point_back": try? await client.pointBackSet(itemID: id)
        case "user_data_raw": _ = try? await client.userDataRaw(itemID: id)
        case "user_data_put": try? await client.userDataBackPut(itemID: id, raw: Data((rqS(a, "raw") ?? "").utf8))
        case "watchlist": try? await client.setWatchlist(itemID: id, an: srBool(a["on"]) == true)
        case "watched": try? await client.setWatched(itemID: id, an: srBool(a["on"]) == true)
        case "watchers": _ = await client.watchers(itemID: id)
        case "seasons": _ = try? await client.seasons(seriesID: id)
        case "episodes": _ = try? await client.episodes(seriesID: id, seasonID: rqS(a, "season"))
        case "first_episode": _ = try? await client.firstEpisode(seriesID: id)
        case "refresh": try? await client.metadataRefresh(id)
        case "next_series": _ = try? await client.nextEpisodeSeries(seriesID: id)
        case "episode_post": _ = try? await client.episodePost(itemID: id, seriesID: rqS(a, "series") ?? "")
        case "resume": _ = try? await client.resumeItems(limit: rqI(a, "limit") ?? 20)
        case "next_up": _ = try? await client.nextUp(limit: rqI(a, "limit") ?? 20)
        case "newly":
            _ = try? await client.newlyJoined(parentID: rqS(a, "parent"), limit: rqI(a, "limit") ?? 20,
                                              slim: srBool(a["slim"]) == true, genres: rqS(a, "types") ?? "Movie,Episode")
        case "sessions": _ = try? await client.remoteSession()
        case "foreign":
            let cmd: ForeignCommand = switch rqS(a, "cmd") ?? "" { case "Unpause": .proceed; case "Stop": .finish; default: .halt }
            try? await client.foreignCommand(cmd, an: id)
        case "hint": try? await client.handoffHint(an: id, device: rqS(a, "device") ?? "")
        case "capabilities": try? await client.reportCapabilities()
        case "account_defaults": _ = await client.accountDefaults()
        case "sections": _ = await client.sections(for: id)
        case "trickplay": _ = await client.trickplay(itemID: id, mediaSourceID: rqS(a, "source"))
        case "chapters": _ = await client.chapter(itemID: id, mediaSourceID: rqS(a, "source"))
        case "report_start":
            try? await client.reportStart(itemID: id, plan: rqPlan(a), ticks: Int64(rqI(a, "ticks") ?? 0),
                                          tracks: .init(audio: rqI(a, "audio"), subtitle: rqI(a, "subtitle")))
        case "report_progress":
            try? await client.reportProgress(itemID: id, plan: rqPlan(a), positionTicks: Int64(rqI(a, "ticks") ?? 0),
                                             paused: srBool(a["paused"]) == true,
                                             tracks: .init(audio: rqI(a, "audio"), subtitle: rqI(a, "subtitle")))
        case "report_stopped":
            try? await client.reportStopped(itemID: id, plan: rqPlan(a), positionTicks: Int64(rqI(a, "ticks") ?? 0))
        case "stop_encoding": await client.stopEncoding(playSessionID: rqS(a, "play") ?? "")
        case "qc_start": _ = try? await client.quickConnectStart()
        case "qc_released": _ = try? await client.quickConnectReleased(LoginCode(code: rqS(a, "code") ?? "", confidential: rqS(a, "secret") ?? ""))
        case "qc_enabled": _ = await client.quickConnectAddBar()
        case "qc_share": try? await client.quickConnectShare(code: rqS(a, "code") ?? "")
        case "qc_public": _ = try? await client.publicUser()
        case "qc_signin": _ = try? await client.signInWithQuickConnect(LoginCode(code: rqS(a, "code") ?? "", confidential: rqS(a, "secret") ?? ""))
        // Addresses without a request.
        case "u_stream": return [await url { try await client.streamURL(itemID: id, mediaSourceID: rqS(a, "source"), playSessionID: rqS(a, "play")) }]
        case "u_download":
            return [await url { try await client.downloadURL(itemID: id, mediaSourceID: rqS(a, "source")) }]
        case "u_download_q":
            return [await url { try await client.downloadURL(itemID: id, mediaSourceID: rqS(a, "source"), quality: rqQuality(a),
                                                 audioStreamIndex: rqI(a, "audio")) }]
        case "u_image": return [await url { await client.imageURL(for: try rqItem(a), maxHeight: rqI(a, "size") ?? 480) }]
        case "u_backdrop": return [await url { await client.backdropURL(for: try rqItem(a), maxWidth: rqI(a, "size") ?? 1200) }]
        case "u_trickplay":
            return [await url { await client.trickplayURL(itemID: id, mediaSourceID: rqS(a, "source"), width: rqI(a, "width") ?? 320, sheet: rqI(a, "sheet") ?? 0) }]
        case "u_user_image":
            let u = PublicUser(id: id, name: "n", imageMark: rqS(a, "mark"))
            return [await url { await client.userImage(u, border: rqI(a, "border") ?? 180) }]
        default: return ["bad op"] as [Any]
        }
        return [] as [Any]
    }
    return ["urls": urls, "seen": RqStub.seen] as [String: Any]
}
