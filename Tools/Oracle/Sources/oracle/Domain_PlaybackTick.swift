import Foundation
import JellyfinKit

// PlaybackTick.swift: playback_tick. Cases: crates/swiftly-hardening/src/inputs/playback_tick.rs.
// The step clock is `base + t`; `since` is applied against the real clock because TimeAssumption
// reads `Date()` itself (the generator keeps every `since` away from the thresholds).

private func ptDict(_ raw: Any) throws -> [String: Any] {
    guard let c = raw as? [String: Any] else { throw OracleError("bad case") }
    return c
}
private func ptDouble(_ x: Any?) -> Double {
    if let s = x as? String { return s == "nan" ? .nan : (s == "inf" ? .infinity : -.infinity) }
    return (x as? NSNumber)?.doubleValue ?? 0
}
private func ptBool(_ x: Any?) -> Bool { (x as? Bool) ?? false }

/// JSON cannot hold NaN or infinity.
private func ptNum(_ v: Double) -> Any {
    if v.isNaN { return "nan" }
    if v.isInfinite { return v > 0 ? "inf" : "-inf" }
    return v
}

private let ptBase = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func ptState(_ s: PlaybackTick.Snapshot) -> [String: Any] {
    var leap: Any = NSNull()
    if let l = s.leap { leap = ["target": ptNum(l.target), "since_t": l.since.timeIntervalSince(ptBase)] as [String: Any] }
    return ["position": ptNum(s.position), "duration": ptNum(s.duration), "running": s.running,
            "first": s.firstImagePresent, "tracks": s.tracksSet, "start": s.startReported,
            "since_msg": ptNum(s.sinceMessage), "after_change": s.afterChange, "leap": leap]
}

let domainPlaybackTick = Domain("playback_tick") { raw in
    let c = try ptDict(raw)
    let st = try ptDict(c["state"] as Any)
    var s = PlaybackTick.Snapshot(position: ptDouble(st["position"]), duration: ptDouble(st["duration"]),
                                  running: ptBool(st["running"]), firstImagePresent: ptBool(st["first"]),
                                  tracksSet: ptBool(st["tracks"]), startReported: ptBool(st["start"]),
                                  sinceMessage: ptDouble(st["since_msg"]))
    s.afterChange = ptBool(st["after_change"])
    if let l = st["leap"] as? [String: Any] {
        s.leap = PlaybackTick.Jump(target: ptDouble(l["target"]), since: ptBase.addingTimeInterval(ptDouble(l["since_t"])))
    }
    var results: [Any] = []
    for opRaw in (c["ops"] as? [Any]) ?? [] {
        let o = try ptDict(opRaw)
        let now = ptBase.addingTimeInterval(ptDouble(o["t"]))
        switch o["op"] as? String {
        case "tick":
            let m = PlaybackTick.Reading(
                duration: ptDouble(o["duration"]), position: ptDouble(o["position"]), goodPoint: ptDouble(o["good_point"]),
                showsImage: ptBool(o["shows"]), seeksToStart: ptBool(o["seeks"]), running: ptBool(o["running"]),
                hasAudioTracks: ptBool(o["audio"]))
            let job = PlaybackTick.compute(&s, measurement: m, restoring: ptBool(o["restoring"]),
                                           atPush: ptBool(o["at_push"]),
                                           sinceStart: Date().addingTimeInterval(-ptDouble(o["since"])), now: now)
            results.append(["state": ptState(s),
                            "job": ["screen": job.loadingScreenGone, "tracks": job.tracksApply,
                                    "start": job.startReport, "progress": job.progressReport]] as [String: Any])
        case "adopt":
            PlaybackTick.timeAdopt(&s, reported: ptDouble(o["reported"]), atPush: ptBool(o["at_push"]),
                                   sinceStart: Date().addingTimeInterval(-ptDouble(o["since"])), now: now)
            results.append(["state": ptState(s)])
        case "jumped":
            PlaybackTick.jumped(&s, target: ptDouble(o["target"]), now: now)
            results.append(["state": ptState(s)])
        case "target_by":
            results.append(["target": ptNum(PlaybackTick.target(um: ptDouble(o["seconds"]), state: s))])
        case "new_title":
            PlaybackTick.newTitle(&s, startReported: ptBool(o["start_reported"]))
            results.append(["state": ptState(s)])
        default: throw OracleError("bad op")
        }
    }
    return results
}
