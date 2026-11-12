import Foundation
import JellyfinKit

// Group G, playback profile and plan: device_profile, bitrates_limit, play_time, trailer_choice,
// playback_plan. Cases: crates/swiftly-hardening/src/inputs/playback_g.rs.

private func pgDict(_ raw: Any) throws -> [String: Any] {
    guard let c = raw as? [String: Any] else { throw OracleError("bad case") }
    return c
}
private func pgJSON(_ x: Any?) throws -> Data { try JSONSerialization.data(withJSONObject: x ?? NSNull(), options: [.fragmentsAllowed]) }
private func pgProfile(_ c: [String: Any]) -> DeviceProfile {
    let max = (c["max"] as? NSNumber).map { Int($0.int64Value) } ?? 1_000_000_000
    if (c["kind"] as? String) == "airplay" { return DeviceProfile.airplay(maxBitrate: max, av1: (c["av1"] as? Bool) ?? false) }
    return DeviceProfile.vlc(maxBitrate: max)
}

let domainDeviceProfile = Domain("device_profile") { raw in
    let c = try pgDict(raw)
    let data = try JSONEncoder().encode(pgProfile(c))
    return try JSONSerialization.jsonObject(with: data)
}

let domainDownloadRight = Domain("download_right") { raw in
    let c = try pgDict(raw)
    let server: Bool? = c["server"] as? Bool
    let rights = DownloadPermission.fromServer(server)
    return [
        "rights": rights.rawValue, "may_load": rights.mayLoad,
        "offer": DownloadPermission.offer(rights: rights, functionOn: (c["on"] as? Bool) ?? false),
    ] as [String: Any]
}

let domainBitratesLimit = Domain("bitrates_limit") { raw in
    let c = try pgDict(raw)
    let mb = (c["megabit"] as? NSNumber).map { Int($0.int64Value) } ?? 0
    return BitratesLimit.of(alwaysDirectPlay: (c["direct"] as? Bool) ?? false, megabit: mb)
}

let domainPlayTime = Domain("play_time") { raw in
    let c = try pgDict(raw)
    var v: Double
    if let s = c["v"] as? String { v = s == "nan" ? .nan : (s == "inf" ? .infinity : -.infinity) }
    else { v = (c["v"] as? NSNumber)?.doubleValue ?? 0 }
    return PlayTime.text(v)
}

let domainTrailerChoice = Domain("trailer_choice") { raw in
    let c = try pgDict(raw)
    switch c["op"] as? String {
    case "web":
        return nsnull(TrailerChoice.webAddress(c["text"] as? String)?.absoluteString)
    default:
        let local = try JSONDecoder().decode([Item].self, from: try pgJSON(c["local"]))
        let remote: [MediaURL]? = (c["remote"] is NSNull || c["remote"] == nil) ? nil
            : try JSONDecoder().decode([MediaURL].self, from: try pgJSON(c["remote"]))
        let list = TrailerChoice.candidates(local: local, remote: remote, canOpenWeb: (c["web"] as? Bool) ?? true)
        return list.map { cand -> String in
            switch cand {
            case .file(let item): return "file:" + item.id
            case .web(let url): return "web:" + url.absoluteString
            }
        }
    }
}

let domainPlaybackPlan = Domain("playback_plan") { raw in
    let c = try pgDict(raw)
    let response = try JSONDecoder().decode(PlaybackInfoResponse.self, from: try pgJSON(c["response"]))
    let profile = pgProfile(c)
    let base = URL(string: (c["base"] as? String) ?? "https://h.example.de")!
    let itemID = (c["item"] as? String) ?? ""
    if (c["op"] as? String) == "diagnose" {
        guard let source = response.mediaSources.first else { return NSNull() }
        return PlaybackPlan.diagnose(source: source, profile: profile).map { [$0.kind.rawValue, $0.codec, nsnull($0.detail)] as [Any] }
    }
    do {
        let plan = try PlaybackPlan.make(from: response, itemID: itemID, profile: profile,
            streamURL: { item, source, session in URL(string: "https://s.example/\(item)/\(source ?? "-")/\(session ?? "-")")! },
            serverBase: base, preferredSourceID: c["preferred"] as? String)
        guard let plan else { return ["none": true] as [String: Any] }
        return [
            "url": plan.url.absoluteString, "method": plan.method.rawValue,
            "source_id": nsnull(plan.mediaSourceID), "session": nsnull(plan.playSessionID),
            "container": nsnull(plan.container), "item": nsnull(plan.itemID),
            "reasons": plan.reasons.map { [$0.kind.rawValue, $0.codec, nsnull($0.detail)] as [Any] },
        ] as [String: Any]
    } catch JellyfinError.playbackRejected(let reason) {
        return ["rejected": reason] as [String: Any]
    } catch JellyfinError.invalidServerURL {
        return ["invalid_url": true] as [String: Any]
    }
}
