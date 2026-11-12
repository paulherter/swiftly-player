import Foundation
import JellyfinKit

// Domains episode_card, season_choice, watcher_ring, media_versions, stop_lock
// (EpisodesCard.swift, SeriesState.swift, Watchers.swift, MediaVersions.swift, EpisodesSwitch.swift StopLock).
// Generator: crates/swiftly-hardening/src/inputs/episodes.rs.

private func epData(_ x: Any?) -> Data? {
    guard let x, JSONSerialization.isValidJSONObject(x) else { return nil }
    return try? JSONSerialization.data(withJSONObject: x)
}
private func epDecode<T: Decodable>(_ type: T.Type, _ x: Any?) -> T? {
    epData(x).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
}
private func epNum(_ x: Any?) -> Double { srDouble(x) ?? 0 }
private func epFinite(_ x: Double) -> Any { x.isFinite ? x : "nonfinite" }

// MARK: episode_card

let domainEpisodeCard = Domain("episode_card") { raw in
    let c = try srDict(raw)
    func metrics(_ m: EpisodeCard.Metrics) -> [Double] { [m.width, m.corner, m.ring, m.spacing, m.small, m.title] }
    switch srStr(c["op"]) ?? "" {
    case "constants":
        let consts: [Double] = [
            EpisodeCard.remainingWindow, EpisodeCard.appearOmega, EpisodeCard.appearLag, EpisodeCard.distanceOmega,
            EpisodeCard.zoomOmega, EpisodeCard.detailsOut, EpisodeCard.swap, EpisodeCard.imageFade, EpisodeCard.atMostCovers,
            EpisodeCard.offset, EpisodeCard.startMetric, EpisodeCard.focusMetric, EpisodeCard.clickPress,
            EpisodeCard.clickDuration, EpisodeCard.atMostShare, EpisodeCard.bottomSpacing, EpisodeCard.swipeAway,
            EpisodeCard.resistance,
        ]
        return consts + metrics(EpisodeCard.iPhone) + metrics(EpisodeCard.tv)
    case "spring":
        let s = EpisodeCard.spring(epNum(c["omega"]))
        return [s.stiffness, s.damping]
    case "travel":
        return EpisodeCard.springTravel(epNum(c["t"]), omega: epNum(c["omega"]))
    case "fade_off":
        return EpisodeCard.fadeOff(imageSince: epNum(c["since"]))
    case "yields":
        return EpisodeCard.yields(since: epNum(c["since"]), imageSince: srDouble(c["image"]))
    case "width":
        let m = (srBool(c["tv"]) ?? false) ? EpisodeCard.tv : EpisodeCard.iPhone
        return EpisodeCard.width(m, safeWidth: epNum(c["safe"]), large: srBool(c["large"]) ?? false)
    case "dragged":
        let d = EpisodeCard.dragged(epNum(c["x"]), epNum(c["y"]))
        return [d.x, d.y]
    case "swiped":
        return EpisodeCard.swipedAway(x: epNum(c["x"]), y: epNum(c["y"]), momentumX: epNum(c["mx"]), momentumY: epNum(c["my"]))
    default:
        let card = (c["card"] as? [Any] ?? []).map(epNum)
        let whole = (c["whole"] as? [Any] ?? []).map(epNum)
        let r = EpisodeCard.frameRect(card: (card[0], card[1], card[2], card[3]), whole: (whole[0], whole[1]),
                                      zoom: epNum(c["zoom"]))
        return [r.x, r.y, r.b, r.h]
    }
}

// MARK: season_choice

let domainSeasonChoice = Domain("season_choice") { raw in
    let c = try srDict(raw)
    let list = (c["list"] as? [Any] ?? []).compactMap { epDecode(Item.self, $0) }
    let state = epDecode(Item.self, c["state"])
    let hintID = srStr(c["hintId"])
    let hintNumber = srInt(c["hintNumber"])
    let chosen = SeasonSelectionRule.choose(from: list, hintID: hintID, hintNumber: hintNumber, state: state)
    // Several seasons may share an id: report the position as well.
    var position: Any = NSNull()
    if let s = chosen, let i = list.firstIndex(where: { $0.id == s.id && $0.indexNumber == s.indexNumber && $0.name == s.name }) {
        position = i
    }
    return ["id": nsnull(chosen?.id), "pos": position,
            "needs": SeasonSelectionRule.needsState(hintID: hintID, hintNumber: hintNumber)] as [String: Any]
}

// MARK: watcher_ring

let domainWatcherRing = Domain("watcher_ring") { raw in
    guard let text = raw as? String,
          let w = try? JSONDecoder().decode(Watcher.self, from: Data(text.utf8)) else { return ["ok": false] as [String: Any] }
    return ["ok": true, "user": w.userID, "name": w.name, "tag": nsnull(w.imageTag), "play": w.playCount,
            "pct": w.progressPercent.map(epFinite) ?? NSNull(), "w": nsnull(w.watchedCount), "t": nsnull(w.totalCount),
            "ring": w.ring] as [String: Any]
}

// MARK: media_versions

private func mvList(_ x: Any?) -> [MediaSource]? {
    guard let a = x as? [Any] else { return nil }
    return a.compactMap { epDecode(MediaSource.self, $0) }
}
private func mvOut(_ s: MediaSource) -> [Any] { [nsnull(s.id), nsnull(s.name), nsnull(s.height)] }

let domainMediaVersions = Domain("media_versions") { raw in
    let c = try srDict(raw)
    switch srStr(c["op"]) ?? "" {
    case "choices":
        return MediaVersions.choices(mvList(c["sources"])).map(mvOut)
    case "start":
        switch MediaVersions.start(mvList(c["sources"]), downloaded: srBool(c["downloaded"]) ?? false) {
        case .wait: return ["k": "wait"] as [String: Any]
        case .play: return ["k": "play"] as [String: Any]
        case .choose(let l): return ["k": "choose", "l": l.map(mvOut)] as [String: Any]
        }
    default:
        guard let previous = epDecode(MediaSource.self, c["previous"]) else { return "undecodable" }
        return MediaVersions.matching(previous: previous, in: mvList(c["next"])).map(mvOut) ?? NSNull()
    }
}

// MARK: stop_lock

let domainStopLock = Domain("stop_lock") { raw in
    let lock = StopLock()
    var out: [Any] = []
    for entry in raw as? [Any] ?? [] {
        let c = try srDict(entry)
        let key = StopLock.key(itemID: srStr(c["item"]) ?? "", playSessionID: srStr(c["session"]))
        switch srStr(c["op"]) ?? "" {
        case "started": lock.started(key); out.append(key)
        case "accept": out.append(lock.stopAccept(key))
        case "failed": lock.stopFailed(key); out.append(key)
        default: out.append(lock.progressAllowed(key))
        }
    }
    return out
}
