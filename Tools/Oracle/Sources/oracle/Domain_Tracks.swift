import Foundation
import JellyfinKit

// Track selection and mapping: language_rules, original_audio, color_selection, track_rule,
// track_mapping. Cases are described next to the Rust generators
// (crates/swiftly-hardening/src/inputs/tracks.rs). Streams are the server's JSON, decoded with the
// real `MediaStream` decoder.

func trStreams(_ x: Any?) throws -> [MediaStream] {
    guard let arr = x as? [Any] else { return [] }
    let data = try JSONSerialization.data(withJSONObject: arr)
    return try JSONDecoder().decode([MediaStream].self, from: data)
}

func trStream(_ x: Any?) throws -> MediaStream? {
    guard let dict = x as? [String: Any] else { return nil }
    let data = try JSONSerialization.data(withJSONObject: dict)
    return try JSONDecoder().decode(MediaStream.self, from: data)
}

func trImprint(_ x: Any?) throws -> TrackImprint? {
    guard let dict = x as? [String: Any] else { return nil }
    let data = try JSONSerialization.data(withJSONObject: dict)
    return try JSONDecoder().decode(TrackImprint.self, from: data)
}

func trJSON<T: Encodable>(_ value: T?) throws -> Any {
    guard let value else { return NSNull() }
    let data = try JSONEncoder().encode(value)
    return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
}

func trChoice(_ x: Any?) throws -> TrackMemory.Choice? {
    guard let d = x as? [String: Any], let kind = d["kind"] as? String else { return nil }
    switch kind {
    case "off": return .off
    case "track":
        guard let imprint = try trImprint(d["imprint"]) else { throw OracleError("imprint") }
        return .track(imprint)
    case "name": return .name(d["name"] as? String ?? "")
    default: throw OracleError("choice kind")
    }
}

func trPlayerTracks(_ x: Any?) -> [PlayerTrack] {
    (x as? [[String: Any]] ?? []).map {
        PlayerTrack(identifier: $0["identifier"] as? String ?? "", name: $0["name"] as? String ?? "",
                    language: srStr($0["language"]), codec: srStr($0["codec"]), channels: srInt($0["channels"]))
    }
}

func trSubtitle(_ s: TrackRule.Subtitle) -> Any {
    switch s {
    case .off: return "off"
    case .feed(let i): return i
    }
}

let domainLanguageRules = Domain("language_rules") { raw in
    let c = try srDict(raw)
    let text = srStr(c["text"]) ?? ""
    let toward = srStr(c["toward"]) ?? ""
    return [
        "detected": nsnull(Language.detected(in: text)),
        "fits": Language.fits(text, toward: toward),
        "forced": Language.soundsForced(text),
    ] as [String: Any]
}

/// `TrackLabel.language` in the interface language of the call (`Locale(identifier:)`): the names the system
/// gives to ISO 639-1/639-2 codes and written-out languages (cases: `inputs/tracks.rs`, `track_language`).
let domainTrackLanguage = Domain("track_language") { raw in
    let c = try srDict(raw)
    let locale = Locale(identifier: srStr(c["locale"]) ?? "en")
    return nsnull(TrackLabel.language(srStr(c["raw"]), locale: locale))
}

let domainOriginalAudio = Domain("original_audio") { raw in
    let c = try srDict(raw)
    let stream = try trStream(c["stream"])
    return OriginalAudio.isOriginal(language: srStr(c["language"]), stream: stream,
                                    originalLanguage: srStr(c["original"]))
}

let domainColorSelection = Domain("color_selection") { raw in
    let c = try srDict(raw)
    let a = srDouble(c["a"]) ?? 0, b = srDouble(c["b"]) ?? 0, d = srDouble(c["c"]) ?? 0
    switch c["op"] as? String ?? "" {
    case "oklab":
        let r = ColorSelection.oklab(a, b, d)
        return [r.L, r.a, r.b]
    case "lab_to_srgb":
        guard let r = ColorSelection.srgb(L: a, a: b, b: d) else { return NSNull() }
        return [r.r, r.g, r.b]
    case "lch_to_srgb":
        let r = ColorSelection.srgb(L: a, C: b, h: d)
        return [r.r, r.g, r.b]
    default: throw OracleError("op")
    }
}

let domainTrackRule = Domain("track_rule") { raw in
    let c = try srDict(raw)
    let streams = try trStreams(c["streams"])
    let rememberedAudio = try trImprint(c["remembered_audio"])
    let rememberedSub = try trChoice(c["remembered_sub"])
    let prefAudio = srStr(c["pref_audio"]) ?? ""
    let prefSub = srStr(c["pref_sub"]) ?? ""
    let audio = TrackRule.audio(streams: streams, remembered: rememberedAudio, preferredLanguage: prefAudio,
                                serverPreGift: srInt(c["server_audio"]), ordered: srInt(c["ordered_audio"]))
    let subtitle = TrackRule.subtitle(streams: streams, remembered: rememberedSub,
                                      serverPreGift: srInt(c["server_sub"]),
                                      automatic: srBool(c["automatic"]) ?? false,
                                      audioIndex: srInt(c["audio_index"]),
                                      tonwunsch: srStr(c["tonwunsch"]) ?? "",
                                      preferredLanguage: prefSub, ordered: srInt(c["ordered_sub"]))
    let start = TrackRule.startIndices(streams: streams, rememberedAudio: rememberedAudio,
                                       rememberedSubtitle: rememberedSub,
                                       serverAudio: srInt(c["server_audio"]),
                                       serverSubtitle: srInt(c["server_sub"]),
                                       automatic: srBool(c["automatic"]) ?? false,
                                       audioLanguage: prefAudio, subtitleLanguage: prefSub)
    var imprint: Any = NSNull()
    if let k = srInt(c["imprint_of"]), streams.indices.contains(k) {
        imprint = try trJSON(TrackImprint(feed: streams[k], in: streams, name: srStr(c["imprint_name"])))
    }
    return [
        "audio": nsnull(audio),
        "subtitle": trSubtitle(subtitle),
        "start": [nsnull(start.audio), nsnull(start.subtitle)],
        "imprint": imprint,
    ] as [String: Any]
}

let domainTrackMapping = Domain("track_mapping") { raw in
    let c = try srDict(raw)
    let streams = try trStreams(c["streams"])
    let audio = trPlayerTracks(c["audio"])
    let subtitle = trPlayerTracks(c["subtitle"])
    let files: [SubtitleFile] = (c["files"] as? [[String: Any]] ?? []).map {
        let index = srInt($0["index"]) ?? 0
        return SubtitleFile(index: index, address: URL(string: "https://host/s/\(index)")!,
                            attribute: srStr($0["attribute"]))
    }
    let mapping = TrackMapping.compose(audio: audio, subtitle: subtitle, streams: streams, files: files)
    let replaced = TrackMapping.replacedPositions(subtitle: subtitle, streams: streams, files: files).sorted()
    let startSub: TrackRule.Subtitle = srInt(c["start_sub"]).map { .feed($0) } ?? .off
    let start = TrackMapping.startPositions(streams: streams, audio: srInt(c["start_audio"]),
                                            subtitle: startSub, files: files)
    let firstAudio = srInt(c["start_audio"]).flatMap { mapping.audioPositionValue(index: $0) }
    let firstSub = srInt(c["start_sub"]).flatMap { mapping.subtitlePosition(index: $0) }
    let additionIds: [Any] = (audio + subtitle).map { nsnull($0.additionId) }
    return [
        "audio": mapping.audio.map { nsnull($0) },
        "subtitle": mapping.subtitle.map { nsnull($0) },
        "replaced": replaced,
        "start": [nsnull(start.audio), nsnull(start.subtitle)],
        "positions": [nsnull(firstAudio), nsnull(firstSub)],
        "addition_ids": additionIds,
        "imprint": try trJSON(subtitle.first.map { TrackImprint(track: $0) }),
    ] as [String: Any]
}
