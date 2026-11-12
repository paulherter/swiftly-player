import Foundation
@testable import JellyfinKit

// SyncPlay.swift: syncplay_read, syncplay_misc, syncplay_clock, syncplay_buffer, syncplay_time.
// Cases: crates/swiftly-hardening/src/inputs/syncplay.rs. Times in the clock/buffer domains are small
// dyadic numbers read as seconds since the reference date, so the arithmetic equals the Rust f64 one.

private func spMs(_ d: Date?) -> Any {
    guard let d else { return NSNull() }
    return String(Int64((d.timeIntervalSince1970 * 1000).rounded()))
}

private func spGroup(_ g: SyncPlayGroup) -> [String: Any] {
    ["id": g.id, "name": g.name, "condition": nsnull(g.condition?.rawValue),
     "participant": g.participant, "state": spMs(g.state)]
}

private func spRender(_ d: SyncPlayPostDirection?) -> Any {
    guard let d else { return NSNull() }
    switch d {
    case let .command(c):
        return ["k": "command", "group": c.group, "entry": nsnull(c.entryRecord), "art": c.art.rawValue,
                "moment": spMs(c.moment), "spot": nsnull(c.spot), "emitted": spMs(c.emitted)] as [String: Any]
    case let .joined(g): return ["k": "joined", "group": spGroup(g)] as [String: Any]
    case .leave: return ["k": "leave"]
    case .notInGroup: return ["k": "not_in_group"]
    case .doesNotExist: return ["k": "does_not_exist"]
    case .noAccess: return ["k": "no_access"]
    case let .someoneJoined(n): return ["k": "joined_user", "name": n]
    case let .someoneLeft(n): return ["k": "left_user", "name": n]
    case let .condition(p, reason): return ["k": "condition", "phase": p.rawValue, "reason": nsnull(reason)] as [String: Any]
    case let .queue(q):
        return ["k": "queue", "reason": q.reason, "state": spMs(q.state),
                "entries": q.entries.map { [$0.title, $0.entryRecord] }, "index": q.index,
                "start": q.startPoint, "running": q.running] as [String: Any]
    case .connectionLost: return ["k": "lost"]
    case .connectionAgain: return ["k": "again"]
    }
}

let domainSyncPlayRead = Domain("syncplay_read") { raw in
    let c = try srDict(raw)
    let text = srStr(c["text"]) ?? ""
    if srStr(c["kind"]) == "list" {
        guard let data = text.data(using: .utf8),
              let list = try? JSONDecoder().decode([SyncPlayGroup].self, from: data) else { return NSNull() }
        return list.map { spGroup($0) }
    }
    return spRender(SyncPlayPostDirection.read(text))
}

let domainSyncPlayMisc = Domain("syncplay_misc") { raw in
    let c = try srDict(raw)
    switch srStr(c["op"]) ?? "" {
    case "consts":
        return [SyncPlay.jumpLimit, SyncPlay.driftLimit, SyncPlay.ticksJeSecond,
                Double(TimeReconcile.keep), BufferGuard.deadline]
    case "other":
        let g = SyncPlayGroup(id: "g", name: "n", participant: (c["participant"] as? [String]) ?? [])
        return g.other(asValue: srStr(c["me"]))
    case "status":
        var s = SyncPlayStatus()
        s.rights = srStr(c["rights"]).flatMap(SyncPlayRight.init(rawValue:))
        s.group = srBool(c["in_group"]) == true ? SyncPlayGroup(id: "g", name: "") : nil
        s.queueTitle = srStr(c["queue_title"])
        return [s.mayCreate, s.mayJoin, s.belongsGroup(srStr(c["title"]) ?? "")]
    case "queue":
        let n = srInt(c["entries"]) ?? 0
        let q = SyncPlayQueue(reason: srStr(c["reason"]) ?? "", state: nil,
                              entries: (0..<n).map { .init(title: "t\($0)", entryRecord: "e\($0)") },
                              index: srInt(c["index"]) ?? 0, startPoint: 0, running: false)
        return [nsnull(q.current?.title), q.switchesTitle]
    case "phase": return nsnull(SyncPlayGroup.Phase(rawValue: srStr(c["raw"]) ?? "")?.rawValue)
    case "art": return nsnull(SyncPlayCommand.Art(rawValue: srStr(c["raw"]) ?? "")?.rawValue)
    case "seconds": return SyncPlay.seconds(srInt64(c["ticks"]) ?? 0)
    case "ticks": return SyncPlay.ticks(srDouble(c["seconds"]) ?? 0)
    case "pause": return TimeReconcile.pause(toMeasurements: srInt(c["count"]) ?? 0)
    default: throw OracleError("bad op")
    }
}

private func spDate(_ x: Any?) -> Date { Date(timeIntervalSinceReferenceDate: srDouble(x) ?? 0) }

private func spCommand(_ x: Any?) -> SyncPlayCommand? {
    guard let c = x as? [String: Any], let art = SyncPlayCommand.Art(rawValue: srStr(c["art"]) ?? "") else { return nil }
    return SyncPlayCommand(group: "g", entryRecord: srStr(c["entry"]), art: art,
                           moment: spDate(c["moment"]), spot: srDouble(c["spot"]), emitted: nil)
}

private func spStep(_ s: SyncPlayExecution.Step) -> String {
    switch s {
    case .proceed: return "proceed"
    case .pause: return "pause"
    case .jump: return "jump"
    case .stop: return "stop"
    }
}

let domainSyncPlayClock = Domain("syncplay_clock") { raw in
    let c = try srDict(raw)
    var rec = TimeReconcile()
    for r in (c["readings"] as? [[String: Any]]) ?? [] {
        rec.record(.init(sent: spDate(r["sent"]), serverReceive: spDate(r["server_receive"]),
                         serverSent: spDate(r["server_sent"]), receive: spDate(r["receive"])))
    }
    let now = spDate(c["now"])
    let localPoint = srDouble(c["local_point"]) ?? 0
    let best: Any = rec.best.map { b in
        [b.sent, b.serverReceive, b.serverSent, b.receive].map { $0.timeIntervalSinceReferenceDate }
    } ?? NSNull()
    var out: [String: Any] = [
        "count": rec.measurements.count, "ready": rec.ready, "offset": rec.offset,
        "ping": rec.pingMilliseconds, "best": best,
        "local_only": rec.localOnly(spDate(c["server_time"])).timeIntervalSinceReferenceDate,
        "server": rec.server(spDate(c["local_time"])).timeIntervalSinceReferenceDate,
        "ready_point": SyncPlayExecution.readyPoint(target: srDouble(c["target"]) ?? 0,
                                                    actualValue: srDouble(c["actual"]) ?? 0),
    ]
    if let cmd = spCommand(c["command"]) {
        let x = SyncPlayExecution.of(cmd, now: now, reconcile: rec, localPoint: localPoint)
        out["exec"] = [spStep(x.step), nsnull(x.spot), x.wait] as [Any]
        out["estimated"] = SyncPlayExecution.estimatedPoint(
            spot: srDouble(c["target"]) ?? 0, validFrom: cmd.moment, now: now, reconcile: rec)
    }
    out["bring"] = nsnull(SyncPlayExecution.bringUpToDate(
        lastOne: spCommand(c["last"]), entryRecord: srStr(c["entry"]), now: now,
        reconcile: rec, localPoint: localPoint))
    return out
}

let domainSyncPlayBuffer = Domain("syncplay_buffer") { raw in
    let c = try srDict(raw)
    var guardian = BufferGuard()
    var out: [Any] = []
    for t in (c["ticks"] as? [[String: Any]]) ?? [] {
        if srBool(t["reset"]) == true { guardian.reset() }
        let m = guardian.tick(spot: srDouble(t["spot"]) ?? 0, shouldRun: srBool(t["run"]) ?? false,
                              now: spDate(t["now"]))
        let name: Any = m.map { $0 == .buffers ? "buffers" : "ready" } ?? NSNull()
        out.append([name, guardian.buffers] as [Any])
    }
    return out
}

let domainSyncPlayTime = Domain("syncplay_time") { raw in
    let c = try srDict(raw)
    return SyncPlay.timeText(Date(timeIntervalSince1970: srDouble(c["t"]) ?? 0))
}
