import Foundation
import JellyfinKit

// Domains description, counter, title_marks, search_keys
// (Description.swift, Counter.swift, TitleMarksMetric.swift, SearchKeys.swift).
// Generators: crates/swiftly-hardening/src/inputs/{description,counter,title_marks,search_keys}.rs.
// Rust: swiftly_rules::{description,counter,title_marks,search_keys}; the key rows are swiftly_vm.

// MARK: description

let domainDescription = Domain("description") { raw in
    let c = try srDict(raw)
    switch srStr(c["op"]) ?? "" {
    case "readable":
        return ["s": Description.readable(srStr(c["text"]) ?? "")]
    default:
        var json: [String: Any] = ["Id": "x", "Name": "n"]
        if let o = c["overview"] as? String { json["Overview"] = o }
        if let p = c["premiere"] as? String { json["PremiereDate"] = p }
        if let t = c["tmdb"] as? String { json["ProviderIds"] = ["Tmdb": t] }
        let data = try JSONSerialization.data(withJSONObject: json)
        let item = try JSONDecoder().decode(Item.self, from: data)
        let days: Any
        if let d = item.daysDate, let y = d.year, let m = d.month, let dd = d.day { days = [y, m, dd] } else { days = NSNull() }
        return ["d": nsnull(item.description), "days": days, "tmdb": nsnull(item.tmdbId)] as [String: Any]
    }
}

// MARK: counter

private func counterRaw(_ x: Any?) -> Counter.RawValues {
    let r = (x as? [String: Any]) ?? [:]
    func u(_ k: String) -> UInt64 { UInt64(max(0, srInt64(r[k]) ?? 0)) }
    return Counter.RawValues(hasRead: u("hasRead"), unpacked: u("unpacked"), shown: u("shown"),
                             discarded: u("discarded"), tooLate: u("tooLate"), videoBlocks: u("videoBlocks"),
                             audioBlocks: u("audioBlocks"), audioPlay: u("audioPlay"), audioLost: u("audioLost"),
                             beschaedigt: u("damaged"), jumps: u("jumps"))
}

let domainCounter = Domain("counter") { raw in
    let c = try srDict(raw)
    let steps = (c["steps"] as? [Any]) ?? []
    let bps = ((c["bps"] as? [Any]) ?? []).map { srDouble($0) ?? 0 }
    var time = srDouble(c["t0"]) ?? 0
    var before: Counter? = nil
    var out: [Any] = []
    for s in steps {
        let st = (s as? [String: Any]) ?? [:]
        time += srDouble(st["dt"]) ?? 0
        if srBool(st["reset"]) == true { before = nil }
        let counter = Counter(counterRaw(st["raw"]), spot: srDouble(st["spot"]) ?? 0,
                              running: srBool(st["running"]) ?? false, before: before,
                              now: Date(timeIntervalSinceReferenceDate: time))
        guard let counter else { out.append(NSNull()); continue }
        before = counter
        out.append([
            "input": nsnull(counter.input), "demuxer": nsnull(counter.demuxer),
            "shows": nsnull(counter.showsProSecond), "decoded": nsnull(counter.decodedProSecond),
            "run": nsnull(counter.runShare), "pre": Int64(counter.preAdviceBytes),
            "reserve": bps.map { nsnull(counter.reserveSeconds(bytesJeSecond: $0)) },
        ] as [String: Any])
    }
    return out
}

// MARK: title_marks

let domainTitleMarks = Domain("title_marks") { raw in
    let c = try srDict(raw)
    func d(_ k: String) -> Double { srDouble(c[k]) ?? 0 }
    switch srStr(c["op"]) ?? "" {
    case "measure":
        let px = ((c["rgba"] as? [Any]) ?? []).map { UInt8(max(0, min(255, srInt($0) ?? 0))) }
        guard let m = TitleMarksMetric.measure(rgba: px, width: srInt(c["w"]) ?? 0, height: srInt(c["h"]) ?? 0) else { return NSNull() }
        return [m.x, m.y, m.width, m.height, m.density, m.luminance, m.pagesRatio]
    case "factor":
        return TitleMarksMetric.densityFactor(d("density"))
    case "dark":
        return TitleMarksMetric.isDark(luminance: d("l"))
    default:
        let s = TitleMarksMetric.size(pagesRatio: d("ratio"), density: d("density"), row: d("row"),
                                      maxWidth: d("maxWidth"), maxHeight: srDouble(c["maxHeight"]))
        return [s.width, s.height]
    }
}

// MARK: search_keys

private func skKeys(_ rows: [[SearchKeys.Key]]) -> [Any] {
    rows.map { row in row.map { ["character": $0.character, "kind": $0.kind.rawValue, "span": $0.span] as [String: Any] } }
}

let domainSearchKeys = Domain("search_keys") { raw in
    let c = try srDict(raw)
    let term = srStr(c["term"]) ?? ""
    switch srStr(c["op"]) ?? "" {
    case "rows": return skKeys(SearchKeys.rows(speech: srBool(c["speech"]) ?? false))
    case "typed": return SearchKeys.typed(srStr(c["c"]) ?? "", into: term)
    case "space_fits": return SearchKeys.spaceFits(term)
    case "with_space": return SearchKeys.withSpace(term)
    case "delete": return SearchKeys.withoutLast(term)
    case "hardware": return SearchKeys.hardware(srStr(c["text"]) ?? "", into: term)
    case "titles":
        return SearchGroups.showsTitles(series: srInt(c["s"]) ?? 0, films: srInt(c["f"]) ?? 0, requests: srInt(c["r"]) ?? 0)
    default:
        return SearchScreen.state(term: term, historyCount: srInt(c["history"]) ?? 0, hasHits: srBool(c["hits"]) ?? false,
                                  answered: srBool(c["answered"]) ?? false, disrupted: srBool(c["disrupted"]) ?? false,
                                  waited: srBool(c["waited"]) ?? false).rawValue
    }
}
