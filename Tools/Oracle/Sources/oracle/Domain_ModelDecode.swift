import Foundation
import JellyfinKit

// Domain "model_decode": the wire models of Models.swift decoded with the plain JSONDecoder, then
// re-encoded, plus the derived properties that do not depend on the locale. Cases are
// {"kind": item|items|source|stream|playback|user_data|person, "json": "<raw text>"}.
// Result: {"ok": false} when the decode throws, else {"ok": true, "v": <re-encoded>, "d": {derived}}.
// The generator lives in crates/swiftly-hardening/src/inputs/model_decode.rs.

private func mdReencode<T: Encodable>(_ value: T) throws -> Any {
    let data = try JSONEncoder().encode(value)
    return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
}

private func mdKindName(_ k: ItemKind) -> String {
    switch k {
    case .movie: "movie"
    case .series: "series"
    case .season: "season"
    case .episode: "episode"
    case .collection: "collection"
    case .playlist: "playlist"
    case .folder: "folder"
    case .other: "other"
    }
}

private func mdItemDerived(_ item: Item) -> [String: Any] {
    [
        "direction": item.direction,
        "actors": item.actors.map(\.id),
        "container": item.isContainer,
        "share": nsnull(item.watchedShare),
        "watched": item.isWatched,
        "seconds": nsnull(item.runtimeSeconds),
        "kind": mdKindName(item.kind),
        "lastPlay": nsnull(item.userData?.lastPlay?.timeIntervalSince1970),
        "series": nsnull(Item.preCommonSeries(toward: item).map { "\($0.id)|\($0.name)" }),
    ]
}

private func mdStreamDerived(_ s: MediaStream) -> [String: Any] {
    [
        "frame": nsnull(s.frameRate),
        "real": nsnull(s.realFrameRate),
        "average": nsnull(s.averageFrameRate),
        "dv": nsnull(s.dvProfile),
        "dvc": nsnull(s.dvBlSignalCompatibilityId),
        "range": nsnull(s.videoRangeType?.rawValue),
    ]
}

private func mdSourceDerived(_ s: MediaSource) -> [String: Any] {
    [
        "seconds": nsnull(s.runtimeSeconds),
        "height": nsnull(s.height),
        "wire": s.deliveryMethod.wireName,
        "raw": s.deliveryMethod.rawValue,
        "lossless": s.deliveryMethod.isLossless,
        "streams": (s.mediaStreams ?? []).map(mdStreamDerived),
    ]
}

let domainModelDecode = Domain("model_decode") { raw in
    let c = try srDict(raw)
    guard let kind = srStr(c["kind"]), let text = srStr(c["json"]) else { throw OracleError("bad case") }
    let data = Data(text.utf8)
    let dec = JSONDecoder()
    do {
        switch kind {
        case "item":
            let v = try dec.decode(Item.self, from: data)
            return ["ok": true, "v": try mdReencode(v), "d": mdItemDerived(v)] as [String: Any]
        case "items":
            let v = try dec.decode(ItemsResponse.self, from: data)
            return ["ok": true, "v": try mdReencode(v),
                    "d": ["items": v.items.map(mdItemDerived), "total": v.totalRecordCount] as [String: Any]] as [String: Any]
        case "source":
            let v = try dec.decode(MediaSource.self, from: data)
            return ["ok": true, "v": try mdReencode(v), "d": mdSourceDerived(v)] as [String: Any]
        case "stream":
            let v = try dec.decode(MediaStream.self, from: data)
            return ["ok": true, "v": try mdReencode(v), "d": mdStreamDerived(v)] as [String: Any]
        case "playback":
            let v = try dec.decode(PlaybackInfoResponse.self, from: data)
            return ["ok": true, "v": try mdReencode(v),
                    "d": ["sources": v.mediaSources.map(mdSourceDerived)] as [String: Any]] as [String: Any]
        case "user_data":
            let v = try dec.decode(UserItemData.self, from: data)
            return ["ok": true, "v": try mdReencode(v),
                    "d": ["lastPlay": nsnull(v.lastPlay?.timeIntervalSince1970)] as [String: Any]] as [String: Any]
        case "person":
            let v = try dec.decode(Person.self, from: data)
            return ["ok": true, "v": try mdReencode(v), "d": ["cast": v.isCast] as [String: Any]] as [String: Any]
        default:
            throw OracleError("kind \(kind)")
        }
    } catch is OracleError {
        throw OracleError("bad case")
    } catch {
        return ["ok": false] as [String: Any]
    }
}
