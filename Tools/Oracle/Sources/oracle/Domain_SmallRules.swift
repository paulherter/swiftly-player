import Foundation
import JellyfinKit

// Small pure rules: age_rating, whole_number, resume_point, download_quality, display_rules,
// episode_end, chapter_bar. Cases/results are described next to the Rust generators
// (crates/swiftly-hardening/src/inputs/small_rules.rs).

func srDouble(_ x: Any?) -> Double? {
    guard let n = x as? NSNumber else { return nil }
    return n.doubleValue
}
func srInt(_ x: Any?) -> Int? {
    guard let n = x as? NSNumber else { return nil }
    return n.intValue
}
func srInt64(_ x: Any?) -> Int64? {
    guard let n = x as? NSNumber else { return nil }
    return n.int64Value
}
func srBool(_ x: Any?) -> Bool? {
    guard let n = x as? NSNumber else { return nil }
    return n.boolValue
}
func srStr(_ x: Any?) -> String? { x as? String }
func srDict(_ raw: Any) throws -> [String: Any] {
    guard let c = raw as? [String: Any] else { throw OracleError("bad case") }
    return c
}

let domainAgeRating = Domain("age_rating") { raw in
    let c = try srDict(raw)
    return nsnull(AgeRating.text(srStr(c["raw"])))
}

let domainWholeNumber = Domain("whole_number") { raw in
    let c = try srDict(raw)
    let v: Double
    if let s = c["value"] as? String {
        v = s == "nan" ? .nan : (s == "inf" ? .infinity : -.infinity)
    } else { v = srDouble(c["value"]) ?? 0 }
    return Int(capped: v)
}

let domainResumePoint = Domain("resume_point") { raw in
    let c = try srDict(raw)
    return nsnull(ResumePoint.since(position: srDouble(c["position"]), runtime: srDouble(c["runtime"])))
}

let domainDownloadQuality = Domain("download_quality") { raw in
    let c = try srDict(raw)
    guard let q = DownloadQuality(rawValue: c["quality"] as? String ?? "") else { throw OracleError("quality") }
    let bytes = srInt64(c["bytes"]) ?? 0
    let ticks = srInt64(c["ticks"])
    let files: [(bytes: Int64, runtimeTicks: Int64?)] = (c["files"] as? [[Any]] ?? []).map {
        (bytes: srInt64($0[0]) ?? 0, runtimeTicks: srInt64($0[1]))
    }
    let selectable = DownloadQuality.selectable(videoConvert: srBool(c["video"]), audioConvert: srBool(c["audio"]))
    let source = srInt(c["source"])
    let en = Locale(identifier: "en_US")
    let out: [String: Any] = [
        "height": nsnull(q.height), "width": nsnull(q.width),
        "image_bitrate": nsnull(q.imageBitrate), "audio_bitrate": nsnull(q.audioBitrate),
        "audio_channels": nsnull(q.audioChannels), "total": nsnull(q.totalBitrate),
        "is_original": q.isOriginal,
        "selectable": selectable,
        "offered": DownloadQuality.offered(selectable: selectable, sourceBitrateOf: source).map(\.rawValue),
        "offered_all": DownloadQuality.offered(selectable: true, sourceBitrateOf: source).map(\.rawValue),
        "bitrate": nsnull(DownloadQuality.bitrate(bytes: bytes, runtimeTicks: ticks)),
        "source_bitrate": nsnull(DownloadQuality.sourceBitrateOf(files)),
        "estimated": q.estimatedBytes(original: srInt64(c["original"]) ?? 0, runtimeTicks: ticks),
        "addition": q.isOriginal ? NSNull() : q.addition(locale: en),
    ]
    return out
}

let domainDisplayRules = Domain("display_rules") { raw in
    let c = try srDict(raw)
    let mark = DisplayRules.tileMark(art: srStr(c["art"]), seasons: srInt(c["seasons"]),
                                     watched: srBool(c["watched"]), openEpisodes: srInt(c["open"]))
    var markJson: Any = NSNull()
    switch mark {
    case .watched?: markJson = ["watched"]
    case .opened(let n)?: markJson = ["opened", n]
    case .seasons(let n)?: markJson = ["seasons", n]
    case nil: break
    }
    let item = Item(id: "i", name: "n", type: srStr(c["type"]), seriesId: srStr(c["series_id"]))
    return [
        "runtime_show": DisplayRules.runtimeShow(seconds: srDouble(c["seconds"])),
        "fits": DisplayRules.searchTermFits(srStr(c["term"]) ?? ""),
        "mark": markJson,
        "character": item.tileCharacter,
    ] as [String: Any]
}

let domainEpisodeEnd = Domain("episode_end") { raw in
    let c = try srDict(raw)
    let p = srDouble(c["position"]) ?? 0, d = srDouble(c["duration"]) ?? 0
    return [
        "button": EpisodeEnd.buttonShow(position: p, duration: d),
        "at_end": EpisodeEnd.atEnd(position: p, duration: d),
        "advance": EpisodeEnd.advance(position: p, duration: d, sinceOpen: srDouble(c["since"]) ?? 0,
                                      cardCounts: srBool(c["card"]) ?? false),
    ] as [String: Any]
}

let domainChapterBar = Domain("chapter_bar") { raw in
    let c = try srDict(raw)
    let chapters = (c["chapters"] as? [[String: Any]] ?? []).map {
        Chapter(name: srStr($0["name"]) ?? "", from: srDouble($0["from"]) ?? 0)
    }
    let duration = srDouble(c["duration"]) ?? 0, width = srDouble(c["width"]) ?? 0
    let usable = ChapterBar.usable(chapters)
    let limits = ChapterBar.limits(usable, duration: duration)
    let pieces = ChapterBar.pieces(limits: limits, duration: duration, width: width,
                                   minWidth: srDouble(c["min_width"]) ?? 0)
    let gap = srDouble(c["gap"]) ?? 0
    let shares = (c["shares"] as? [Any] ?? []).compactMap(srDouble)
    let spots = (c["spots"] as? [Any] ?? []).compactMap(srDouble)
    return [
        "usable": usable.map { ["name": $0.name, "from": $0.from] as [String: Any] },
        "limits": limits,
        "pieces": pieces.map { ["from": $0.from, "until": $0.until] },
        "snap": ChapterBar.snapCuts(pieces, duration: duration, width: width),
        "frames": pieces.map { let r = $0.frameRect(width: width, gap: gap); return [r.x, r.width] },
        "piece_at": shares.map { nsnull(ChapterBar.piece(at: $0, in: pieces)) },
        "chapter_at": spots.map { s -> Any in
            guard let ch = ChapterBar.chapter(at: s, in: usable) else { return NSNull() }
            return ["name": ch.name, "from": ch.from] as [String: Any]
        },
    ] as [String: Any]
}

// Sweep of code points: which ones the search-term trim removes (`<c>a` fits or not).
let domainTermTrim = Domain("term_trim") { raw in
    let c = try srDict(raw)
    return DisplayRules.searchTermFits(srStr(c["term"]) ?? "")
}
