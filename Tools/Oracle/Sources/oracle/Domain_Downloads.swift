import Foundation
import JellyfinKit

// DownloadAudio.swift (choices only; the labels depend on locale and catalog) and Downloads.swift
// (DownloadRules, DownloadItem methods, PathPart): download_audio, download_rules.
// Cases: crates/swiftly-hardening/src/inputs/downloads.rs.

private func dlDict(_ raw: Any) throws -> [String: Any] {
    guard let c = raw as? [String: Any] else { throw OracleError("bad case") }
    return c
}
private func dlData(_ x: Any?) throws -> Data {
    try JSONSerialization.data(withJSONObject: x ?? NSNull(), options: [.fragmentsAllowed])
}
private func dlInt(_ x: Any?) -> Int64 { (x as? NSNumber)?.int64Value ?? 0 }
private func dlBool(_ x: Any?) -> Bool { (x as? Bool) ?? false }
private func dlOptBool(_ x: Any?) -> Bool? { x is NSNull ? nil : x as? Bool }

private func dlChoice(_ x: Any?) -> DownloadAudioChoice {
    let c = (x as? [String: Any]) ?? [:]
    switch c["k"] as? String {
    case "track": return .track(Int(dlInt(c["i"])))
    case "language": return .language((c["key"] as? String) ?? "")
    default: return .all
    }
}
private func dlChoiceJSON(_ c: DownloadAudioChoice) -> Any {
    switch c {
    case .all: return ["k": "all"]
    case let .track(i): return ["k": "track", "i": i] as [String: Any]
    case let .language(k): return ["k": "language", "key": k] as [String: Any]
    }
}

let domainDownloadAudio = Domain("download_audio") { raw in
    let c = try dlDict(raw)
    let dec = JSONDecoder()
    let streams = try dec.decode([MediaStream].self, from: try dlData(c["streams"]))
    let selection = try dec.decode([[MediaStream]].self, from: try dlData(c["selection"]))
    let choice = dlChoice(c["choice"])
    let pref = (c["pref"] as? String) ?? ""
    let options = c["mode"] as? String == "track"
        ? DownloadAudio.trackOptions(streams: streams)
        : DownloadAudio.languageOptions([streams])
    let index = Int(dlInt(c["index"]))
    return [
        "offered": DownloadAudio.offered(streams: streams),
        "offered_sel": DownloadAudio.offered(selection: selection),
        "track_options": DownloadAudio.trackOptions(streams: streams).map { dlChoiceJSON($0.choice) },
        "language_options": DownloadAudio.languageOptions(selection).map { dlChoiceJSON($0.choice) },
        "preselected": dlChoiceJSON(DownloadAudio.preselected(options: options, streams: streams, preferredLanguage: pref)),
        "index": nsnull(DownloadAudio.index(for: choice, streams: streams)),
        "language_key": nsnull(DownloadAudio.languageKey(of: index, streams: streams)),
    ] as [String: Any]
}

// MediaServerFactory.swift (headless part): kind -> capabilities of the table and of the client.
let domainServerFactory = Domain("server_factory") { raw in
    let c = try dlDict(raw)
    guard let kind = ServerKind(rawValue: (c["kind"] as? String) ?? ""),
          let url = URL(string: (c["url"] as? String) ?? "") else { throw OracleError("bad kind or url") }
    let client = MediaServerFactory.make(kind: kind, baseURL: url, deviceID: "d", deviceName: "n")
    return [
        "made": client != nil,
        "kind": nsnull(client?.kind.rawValue),
        "table": kind.capabilities.map(\.rawValue).sorted(),
        "client": nsnull(client.map { $0.capabilities.map(\.rawValue).sorted() }),
        "bundle_key": kind.bundleStorageKey,
        "prefix": kind.accountKeyPrefix,
    ] as [String: Any]
}

private func dlItem(_ x: Any?) throws -> DownloadItem {
    try JSONDecoder().decode(DownloadItem.self, from: try dlData(x))
}
private func dlItems(_ x: Any?) throws -> [DownloadItem] {
    try ((x as? [Any]) ?? []).map { try dlItem($0) }
}
private func dlItemJSON(_ i: DownloadItem) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(i))
}
private func dlIds(_ l: [DownloadItem]) -> [String] { l.map(\.id) }
private func dlRef(_ d: Date) -> Double { d.timeIntervalSinceReferenceDate }

let domainDownloadRules = Domain("download_rules") { raw in
    let c = try dlDict(raw)
    switch c["op"] as? String {
    case "next_one":
        return nsnull(DownloadRules.nextOne(from: try dlItems(c["items"]), wLAN: dlBool(c["wlan"]),
                                            onlyOverWLAN: dlBool(c["only"]))?.id)
    case "network":
        switch DownloadRules.networkVerdict(wLAN: dlOptBool(c["wlan"]), onlyOverWLAN: dlBool(c["only"])) {
        case .load: return "load"
        case .putBack: return "put_back"
        case .waitFor: return "wait_for"
        }
    case "slot":
        let s = DownloadRules.slot(for: dlInt(c["bytes"]), free: dlInt(c["free"]), available: try dlItems(c["items"]))
        return ["suffices": s.suffices, "free_after": s.freeAfter, "dispensable": dlIds(s.dispensable),
                "bytes": s.dispensableBytes, "cleanup": s.sufficesToCleanUp] as [String: Any]
    case "foot":
        switch DownloadRules.footSpace(for: dlInt(c["bytes"]), free: dlInt(c["free"])) {
        case let .free(v): return ["k": "free", "v": v] as [String: Any]
        case let .few(v): return ["k": "few", "v": v] as [String: Any]
        }
    case "dispensable":
        return dlIds(DownloadRules.dispensable(from: try dlItems(c["items"])))
    case "grouped":
        return DownloadRules.grouped(try dlItems(c["items"])).map { g -> Any in
            var m: [String: Any] = ["id": g.id, "title": g.title, "bytes": g.bytes, "created": dlRef(g.created)]
            switch g {
            case let .single(i): m["k"] = "single"; m["items"] = [i.id]
            case let .series(_, _, eps): m["k"] = "series"; m["items"] = dlIds(eps)
            }
            return m
        }
    case "progress_show":
        return DownloadRules.progressShow(loaded: dlInt(c["loaded"]), total: dlInt(c["total"]),
                                          before: c["before"] is NSNull ? nil : dlInt(c["before"]),
                                          elapsed: c["elapsed"] is NSNull ? nil : (c["elapsed"] as? NSNumber)?.doubleValue)
    case "progress":
        let r = DownloadRules.progress(loaded: dlInt(c["loaded"]), from: dlInt(c["total"]),
                                       locale: Locale(identifier: (c["locale"] as? String) ?? "en_US"))
        return [r.loaded, r.total]
    case "next_episode":
        return nsnull(DownloadRules.nextEpisode(from: try dlItems(c["items"]))?.id)
    case "episode_post":
        return nsnull(DownloadRules.episodePost((c["id"] as? String) ?? "", from: try dlItems(c["items"]))?.id)
    case "reached_end":
        return DownloadRules.reachedEnd(ticks: dlInt(c["ticks"]), runtimeTicks: c["runtime"] is NSNull ? nil : dlInt(c["runtime"]))
    case "successor":
        let item = try dlItem(c["item"])
        return ["has": DownloadRules.hasSuccessor(item),
                "replaced": nsnull(DownloadRules.replacedOne(by: item, in: try dlItems(c["items"])))] as [String: Any]
    case "follow":
        let ws = c["watch"] is NSNull ? nil : try JSONDecoder().decode(UserItemData.self, from: try dlData(c["watch"]))
        return try dlItemJSON(DownloadRules.follow(try dlItem(c["item"]), watchState: ws))
    case "following":
        let eps = try JSONDecoder().decode([Item].self, from: try dlData(c["episodes"]))
        return nsnull(DownloadRules.followingEpisode(after: try dlItem(c["item"]), in: eps)?.id)
    case "allocation":
        let a = DownloadRules.allocation(try dlItems(c["items"]))
        return [a.count, a.bytes]
    case "item":
        let i = try dlItem(c["item"])
        var inQ: [String: Any] = [:]
        for q in DownloadQuality.allCases { inQ[q.rawValue] = try dlItemJSON(i.inQuality(q)) }
        let moment = Date(timeIntervalSinceReferenceDate: (c["moment"] as? NSNumber)?.doubleValue ?? 0)
        return [
            "share": nsnull(i.share), "converted": i.converted, "streamed": i.streamed, "guete": i.guete.rawValue,
            "resume": i.resumeFrom, "file": i.fileName, "in_quality": inQ,
            "post": try dlItemJSON(i.postPlayback(ticks: dlInt(c["ticks"]), moment: moment)),
            "as_item": [i.asItem.id, i.asItem.name, nsnull(i.asItem.type), nsnull(i.asItem.runTimeTicks),
                        nsnull(i.asItem.seriesName), nsnull(i.asItem.indexNumber), nsnull(i.asItem.parentIndexNumber),
                        nsnull(i.asItem.seriesId)],
        ] as [String: Any]
    case "path":
        let t = (c["text"] as? String) ?? ""
        return ["safe": PathPart.safe(t), "is_id": PathPart.isId(t), "suffix": nsnull(PathPart.suffix(t)),
                "suffix_none": nsnull(PathPart.suffix(nil)),
                "image": DownloadItem.imageName(account: (c["other"] as? String) ?? "", identifier: t)] as [String: Any]
    default: throw OracleError("bad op")
    }
}
