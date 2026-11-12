import Foundation
import JellyfinKit

// Group C, playback: delay, buffer_level, time_assumption, fade_times, pause_prebuffer.
// Cases: crates/swiftly-hardening/src/inputs/playback_c.rs. Dates are built from reference-date
// seconds so Rust can pass the same plain numbers.

private func pcDict(_ raw: Any) throws -> [String: Any] {
    guard let c = raw as? [String: Any] else { throw OracleError("bad case") }
    return c
}
private func pcInt(_ x: Any?) -> Int { (x as? NSNumber).map { Int($0.int64Value) } ?? 0 }
private func pcDouble(_ x: Any?) -> Double? {
    if let s = x as? String { return s == "nan" ? .nan : (s == "inf" ? .infinity : -.infinity) }
    return (x as? NSNumber)?.doubleValue
}
private func pcDate(_ x: Any?) -> Date? { pcDouble(x).map { Date(timeIntervalSinceReferenceDate: $0) } }

let domainDelay = Domain("delay") { raw in
    let c = try pcDict(raw)
    switch c["op"] as? String {
    case "ms": return Delay(milliseconds: pcInt(c["v"])).milliseconds
    case "us": return Delay(microseconds: pcInt(c["v"])).milliseconds
    case "shift":
        return Delay(milliseconds: pcInt(c["ms"])).shifted(pcInt(c["bearing"]), steps: pcInt(c["steps"])).milliseconds
    case "steps": return Delay.steps(onRepetition: pcInt(c["n"]))
    case "text":
        return Delay(milliseconds: pcInt(c["ms"])).text(locale: Locale(identifier: (c["locale"] as? String) ?? "en"))
    case "title":
        return Delay.forNewTitle(Delay(milliseconds: pcInt(c["ms"])),
                                 oldTitle: (c["old_title"] as? String) ?? "", oldSeries: c["old_series"] as? String,
                                 newTitle: (c["new_title"] as? String) ?? "", addedSeries: c["new_series"] as? String).milliseconds
    case "soft": return Delay(milliseconds: pcInt(c["ms"])).softOff(fromMicroseconds: pcInt(c["read"]))
    case "hold":
        var counter = Delay.HoldCounter()
        return ((c["times"] as? [Any]) ?? []).map { counter.press(now: pcDate($0) ?? Date()) }
    default: throw OracleError("bad op")
    }
}

let domainBufferLevel = Domain("buffer_level") { raw in
    let c = try pcDict(raw)
    guard let level = BufferLevel(rawValue: (c["raw"] as? String) ?? "") else { return NSNull() }
    return [
        "prefetch": level.prefetchKiB,
        "lead": nsnull(level.networkLeadMilliseconds),
        "approx": nsnull(level.approxSeconds(bitsPerSecond: pcInt(c["bps"]))),
    ] as [String: Any]
}

let domainTimeAssumption = Domain("time_assumption") { raw in
    let c = try pcDict(raw)
    let since = pcDouble(c["since"]) ?? 0
    // `Date()` is read inside the rule, so the start is "since" seconds before now.
    let start = Date().addingTimeInterval(-since)
    switch c["op"] as? String {
    case "position":
        return nsnull(TimeAssumption.position(
            reported: pcDouble(c["reported"]) ?? 0, untilFrom: pcDouble(c["until_from"]) ?? 0,
            sinceStart: start, afterChange: (c["after_change"] as? Bool) ?? false))
    case "present":
        return TimeAssumption.imagePresent(
            showsImage: (c["shows"] as? Bool) ?? false, seeksToStart: (c["seeks"] as? Bool) ?? false, sinceStart: start)
    case "belongs":
        return TimeAssumption.imageBelongsMedium(
            videoOutput: (c["video"] as? Bool) ?? false,
            shownImages: (c["shown"] as? NSNumber)?.uint64Value ?? 0, afterChange: (c["after_change"] as? Bool) ?? false)
    default: throw OracleError("bad op")
    }
}

let domainFadeTimes = Domain("fade_times") { raw in
    let c = try pcDict(raw)
    let t = pcDouble(c["t"]) ?? 0
    switch c["op"] as? String {
    case "in": return FadeTimes.easeIn(t)
    case "out": return FadeTimes.easeOut(t)
    case "inout": return FadeTimes.easeInOut(t)
    case "pages":
        let p = FadeTimes.pagesSwitch(t)
        return [p.alt, p.new]
    case "bezier":
        return FadeTimes.bezier(t, pcDouble(c["x1"]) ?? 0, pcDouble(c["y1"]) ?? 0, pcDouble(c["x2"]) ?? 0, pcDouble(c["y2"]) ?? 0)
    default: throw OracleError("bad op")
    }
}

let domainPausePrebuffer = Domain("pause_prebuffer") { raw in
    let c = try pcDict(raw)
    switch c["op"] as? String {
    case "jump":
        return nsnull(PauseJumpBack.target(
            position: pcDouble(c["position"]) ?? 0, pausedSince: pcDate(c["paused"]),
            now: pcDate(c["now"]) ?? Date(), inGroup: (c["group"] as? Bool) ?? false))
    case "now":
        return Prebuffer.now(
            position: pcDouble(c["position"]) ?? 0, duration: pcDouble(c["duration"]) ?? 0,
            creditsFrom: pcDouble(c["credits"]), networkFavorable: (c["favorable"] as? Bool) ?? false)
    case "fresh":
        return Prebuffer.freshValue(prepared: pcDate(c["prepared"]) ?? Date(), now: pcDate(c["now"]) ?? Date())
    case "load":
        guard let url = URL(string: (c["url"] as? String) ?? ""),
              let method = DeliveryMethod(rawValue: (c["method"] as? String) ?? "") else { return false }
        return Prebuffer.startLoad(address: url, method: method)
    default: throw OracleError("bad op")
    }
}
