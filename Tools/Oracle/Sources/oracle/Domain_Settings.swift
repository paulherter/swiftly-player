import Foundation
import JellyfinKit

// Domain settings_sync (SettingsSync.swift): value coding, entries, server side, who wins.
// Generator: crates/swiftly-hardening/src/inputs/settings.rs.

private func ssKind(_ s: String?) -> SettingsSync.Kind {
    switch s ?? "" {
    case "bool": return .bool
    case "int": return .int
    case "list": return .list
    case "json": return .json
    default: return .text
    }
}
private func ssKindName(_ k: SettingsSync.Kind) -> String {
    switch k {
    case .bool: return "bool"
    case .int: return "int"
    case .text: return "text"
    case .list: return "list"
    case .json: return "json"
    }
}
private func ssKindOf(_ v: SettingsSync.Value) -> String {
    switch v {
    case .bool: return "bool"
    case .int: return "int"
    case .text: return "text"
    case .list: return "list"
    case .json: return "json"
    }
}
private func ssValue(_ v: SettingsSync.Value) -> [String] { [ssKindOf(v), v.encoded] }
private func ssPrefs(_ x: Any?) -> [String: String] {
    (x as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
}
private func ssMillis(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }
private func ssDate(_ x: Any?) -> Date? { srInt64(x).map { Date(timeIntervalSince1970: Double($0) / 1000) } }

let domainSettingsSync = Domain("settings_sync") { raw in
    let c = try srDict(raw)
    switch srStr(c["op"]) ?? "" {
    case "decode":
        return SettingsSync.Value.decode(srStr(c["text"]) ?? "", as: ssKind(srStr(c["kind"]))).map(ssValue) ?? NSNull()
    case "entry":
        guard let e = SettingsSync.entry(forDeviceKey: srStr(c["key"]) ?? "") else { return NSNull() }
        return [e.name, ssKindName(e.kind), e.perServer] as [Any]
    case "remote":
        let r = SettingsSync.remote(from: ssPrefs(c["prefs"]))
        return ["present": r.present, "changed": nsnull(r.changed.map(ssMillis)),
                "values": r.values.mapValues(ssValue)] as [String: Any]
    case "fields":
        var values: [String: SettingsSync.Value] = [:]
        for (name, v) in c["values"] as? [String: Any] ?? [:] {
            guard let d = v as? [String: Any] else { continue }
            switch srStr(d["k"]) ?? "" {
            case "bool": values[name] = .bool(srBool(d["v"]) ?? false)
            case "int": values[name] = .int(srInt(d["v"]) ?? 0)
            case "list": values[name] = .list((d["v"] as? [Any] ?? []).compactMap { $0 as? String })
            case "json": values[name] = .json(Data((srStr(d["v"]) ?? "").utf8))
            default: values[name] = .text(srStr(d["v"]) ?? "")
            }
        }
        return SettingsSync.fields(for: values, changed: ssDate(c["changed"]) ?? Date(timeIntervalSince1970: 0))
    case "decide":
        let r = SettingsSync.remote(from: ssPrefs(c["prefs"]))
        switch SettingsSync.decide(remote: r, localChanged: ssDate(c["local"]), otherAccount: srBool(c["other"]) ?? false) {
        case .apply: return "apply"
        case .push: return "push"
        case .nothing: return "nothing"
        }
    case "change_time":
        return ssMillis(SettingsSync.changeTime(now: ssDate(c["now"]) ?? Date(timeIntervalSince1970: 0), lastKnownRemote: ssDate(c["last"])))
    default:
        let present = ssPrefs(c["present"])
        let got = SettingsSync.collect(serverSuffix: srStr(c["suffix"]) ?? "") { key, kind in
            present[key].flatMap { SettingsSync.Value.decode($0, as: kind) }
        }
        return got.mapValues(ssValue)
    }
}
