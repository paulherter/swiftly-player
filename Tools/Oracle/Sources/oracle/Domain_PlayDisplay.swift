import Foundation
import JellyfinKit

// Display facts of a title that is about to play (`PlayDisplay` in swiftly-vm): the Swift expressions the player
// screens read. The pieces come from the real package (`Item.contextLine`, `episodeCode`, `secondaryLine`,
// `FileDetails`, `MediaStream.short`, `ImageAddress`, `ImageSelection`); only the glue between them is written
// out here, the same lines as in Android/core/swift/.../Core.swift (`playbackPlanResponse`, `fileRow`,
// `dolbyVision`, `defaultAudioCodec`) and Handoff.swift (`cardImage`), and in Sources/iOS/PlayerScreen.swift
// (`titleLine`, `metaText`). Cases: crates/swiftly-hardening/src/inputs/play_display.rs. The text language is the
// process's (English when run as `cargo xtask hardening --regen-oracle` does, whatever the Mac is set to; the Rust test uses "en").

private func pdDecode<T: Decodable>(_ type: T.Type, _ x: Any?) -> T? {
    guard let x, !(x is NSNull),
          let data = try? JSONSerialization.data(withJSONObject: x, options: [.fragmentsAllowed]) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
}

private func pdFileRow(_ source: MediaSource?) -> String? {
    guard let source else { return nil }
    var parts: [String] = []
    if let container = source.container { parts.append(container.uppercased()) }
    if let video = FileDetails.videoTrack(source) { parts.append(FileDetails.video(video, source)) }
    if let audio = FileDetails.audioTracks(source).first { parts.append(audio.short) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

private func pdDolbyVision(_ method: DeliveryMethod, _ source: MediaSource?) -> Int? {
    guard method != .transcode, let track = source.flatMap(FileDetails.videoTrack) else { return nil }
    switch track.videoRangeType {
    case .dolbyVision, .dolbyVisionHDR10, .dolbyVisionHLG, .dolbyVisionSDR, .dolbyVisionEL,
         .dolbyVisionHDR10Plus, .dolbyVisionElHdr10Plus:
        return track.dvProfile ?? 0
    default:
        return nil
    }
}

private func pdAudioCodec(_ source: MediaSource?) -> String? {
    guard let source else { return nil }
    let tracks = FileDetails.audioTracks(source)
    guard let track = tracks.first(where: { $0.isDefault == true }) ?? tracks.first else { return "" }
    return track.codec?.lowercased() ?? ""
}

private func pdCardImage(_ title: Item, addresses a: ImageAddress) -> String? {
    if title.seriesId != nil, let mark = title.imageTags?["Primary"] {
        return a.construct(itemID: title.id, mark: mark, mass: .atMostWide(1280))?.absoluteString
    }
    return ImageSelection.landscape(title, addresses: a, width: 1280)?.url.absoluteString
}

let domainPlayDisplay = Domain("play_display") { raw in
    let c = try srDict(raw)
    guard let item = pdDecode(Item.self, c["item"]) else { throw OracleError("item") }
    let source = pdDecode(MediaSource.self, c["source"])
    let method = DeliveryMethod(rawValue: srStr(c["method"]) ?? "Direct Play") ?? .directPlay
    let next = pdDecode(Item.self, c["next"])
    let a = (srStr(c["base"])).flatMap { URL(string: $0) }.map { ImageAddress(base: $0, token: srStr(c["token"]), kind: .jellyfin) }
    let isEpisode = item.type == "Episode"
    let headerLine = (isEpisode && !(item.seriesName ?? "").isEmpty) ? item.seriesName! : item.name
    let metaText: String? = {
        if isEpisode {
            if item.parentIndexNumber != nil, item.indexNumber != nil {
                // The view says `String(localized: "S\(season) · F\(episode)")`, the app catalog's key; the package
                // has the same key and wording (`episodeCode`).
                return item.episodeCode
            }
            return item.contextLine
        }
        let row = item.secondaryLine
        return row.isEmpty ? nil : row
    }()
    var nextOut: Any = NSNull()
    if let f = next {
        let abbreviation = f.episodeCode ?? f.name
        let image = a?.construct(itemID: f.id, mark: f.imageTags?["Primary"], mass: .atMostHigh(1080))
            ?? a.flatMap { ImageSelection.landscape(f, addresses: $0, width: 1920)?.url }
        nextOut = ["id": f.id, "name": f.name, "abbreviation": abbreviation, "image": nsnull(image?.absoluteString)] as [String: Any]
    }
    let image: String? = {
        let u: URL? = a?.construct(itemID: item.id, mark: item.imageTags?["Primary"], mass: .atMostHigh(600))
        return u?.absoluteString
    }()
    return [
        "context_line": item.contextLine ?? "",
        "file_row": nsnull(pdFileRow(source)),
        "series": nsnull(item.seriesName),
        "abbreviation": nsnull(item.episodeCode),
        "image": nsnull(image),
        "episode": isEpisode,
        "season_id": nsnull(item.seasonId),
        "season_number": nsnull(isEpisode ? item.parentIndexNumber : nil),
        "episode_number": nsnull(isEpisode ? item.indexNumber : nil),
        "header_line": headerLine,
        "secondary_line": nsnull(isEpisode ? nil : (item.secondaryLine.isEmpty ? nil : item.secondaryLine)),
        "meta_line": nsnull(metaText),
        "card_image": nsnull(a.flatMap { pdCardImage(item, addresses: $0) }),
        "dolby_vision": nsnull(pdDolbyVision(method, source)),
        "audio_codec": nsnull(pdAudioCodec(source)),
        "next": nextOut,
    ] as [String: Any]
}
