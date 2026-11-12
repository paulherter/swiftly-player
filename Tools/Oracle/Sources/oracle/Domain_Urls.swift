import Foundation
import JellyfinKit

// Address rules: server_url, server_relative, address_secret, own_headers_clean, own_headers_table,
// server_discovery. Generators: crates/swiftly-hardening/src/inputs/urls.rs.

func urlParts(_ url: URL?) -> Any {
    guard let url else { return NSNull() }
    return [
        "absolute": url.absoluteString,
        "scheme": nsnull(url.scheme),
        "host": nsnull(url.host()?.lowercased()),
        "port": nsnull(url.port),
    ] as [String: Any]
}

let domainServerURL = Domain("server_url") { raw in
    let c = try srDict(raw)
    let text = srStr(c["raw"]) ?? ""
    let url = AppModelURLNormalizer.normalize(text)
    return [
        "url": urlParts(url),
        "home": AppModelURLNormalizer.isHomeNetwork(text),
        "reversed": nsnull(url.flatMap { AppModelURLNormalizer.reversed($0) }?.absoluteString),
    ] as [String: Any]
}

let domainServerRelative = Domain("server_relative") { raw in
    let c = try srDict(raw)
    guard let base = URL(string: srStr(c["base"]) ?? "") else { return ["base": false] as [String: Any] }
    let r = AppModelURLNormalizer.serverRelative(srStr(c["detail"]) ?? "", base: base)
    return ["base": true, "result": nsnull(r?.absoluteString)] as [String: Any]
}

let domainAddressSecret = Domain("address_secret") { raw in
    let c = try srDict(raw)
    guard let url = URL(string: srStr(c["url"]) ?? "") else { return ["parsed": false] as [String: Any] }
    return ["parsed": true, "log": url.withoutSecret, "key": ImageKey.of(url)] as [String: Any]
}

func ohList(_ x: Any?) -> [OwnHeader] {
    (x as? [[String: Any]] ?? []).map { OwnHeader(name: $0["name"] as? String ?? "", value: $0["value"] as? String ?? "") }
}
func ohJSON(_ list: [OwnHeader]) -> Any { list.map { ["name": $0.name, "value": $0.value] } }

let domainOwnHeadersClean = Domain("own_headers_clean") { raw in
    let c = try srDict(raw)
    let list = ohList(c["headers"])
    return [
        "cleaned": ohJSON(OwnHeaders.cleaned(list)),
        "names": OwnHeaders.names(list),
        "locked": list.map { OwnHeaders.isLocked($0.name) },
        "suits": list.map { OwnHeaders.nameSuits($0.name) },
    ] as [String: Any]
}

let domainOwnHeadersTable = Domain("own_headers_table") { raw in
    let c = try srDict(raw)
    OwnHeaders.load(nil)
    var registered: [Any] = []
    for e in c["entries"] as? [[String: Any]] ?? [] {
        guard let base = URL(string: e["base"] as? String ?? "") else { registered.append(NSNull()); continue }
        OwnHeaders.setDown(ohList(e["headers"]), for: base)
        registered.append(ohJSON(OwnHeaders.registered(for: base)))
    }
    var answers: [Any] = []
    for q in c["queries"] as? [String] ?? [] {
        guard let url = URL(string: q) else { answers.append(NSNull()); continue }
        answers.append(ohJSON(OwnHeaders.of(url)))
    }
    let stored = try JSONSerialization.jsonObject(with: OwnHeaders.store())
    // A round trip through the store must keep the table.
    OwnHeaders.load(OwnHeaders.store())
    let again = try JSONSerialization.jsonObject(with: OwnHeaders.store())
    OwnHeaders.load(nil)
    return ["registered": registered, "answers": answers, "store": stored, "roundtrip": NSDictionary(dictionary: stored as? [String: Any] ?? [:]).isEqual(to: again as? [String: Any] ?? [:])] as [String: Any]
}

func fsServer(_ x: Any?) -> FoundServer {
    let d = x as? [String: Any] ?? [:]
    return FoundServer(id: d["id"] as? String ?? "", name: d["name"] as? String ?? "", address: d["address"] as? String ?? "")
}
func fsStandardCompare(_ a: String, _ b: String, _ locale: Locale) -> ComparisonResult {
    let loose = a.compare(b, options: [.caseInsensitive, .numeric, .widthInsensitive, .diacriticInsensitive], range: nil, locale: locale)
    if loose != .orderedSame { return loose }
    let full = a.compare(b, options: [.numeric], range: nil, locale: locale)
    if full != .orderedSame { return full }
    return a.compare(b, options: [.literal], range: nil, locale: locale)
}
func fsJSON(_ s: FoundServer) -> Any { ["id": s.id, "name": s.name, "address": s.address] }

let domainServerDiscovery = Domain("server_discovery") { raw in
    let c = try srDict(raw)
    switch c["kind"] as? String ?? "" {
    case "read":
        let found = ServerDiscovery.read(Data((c["text"] as? String ?? "").utf8))
        return nsnull(found.map(fsJSON))
    case "short":
        return fsServer(c["server"]).shortAddress
    case "merged":
        let known = (c["known"] as? [Any] ?? []).map(fsServer)
        let new = (c["new"] as? [Any] ?? []).map(fsServer)
        // `ServerDiscovery.merged` sorts with `localizedStandardCompare`, i.e. in the locale of the
        // machine. The case carries the language of the device (de, en, ru): the same order is
        // rebuilt here for that locale (names equal when case, accents and width are ignored, then
        // the full comparison, then the raw one; ids decide the rest) and, where the machine's own
        // language is the one asked for, checked against the real function.
        let loc = Locale(identifier: c["locale"] as? String ?? "en")
        var byID: [String: FoundServer] = [:]
        for server in known + new { byID[server.id] = server }
        let ordered = byID.values.sorted {
            let order = fsStandardCompare($0.name, $1.name, loc)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        let machine = ServerDiscovery.merged(known, new)
        if Locale.current.language.languageCode == loc.language.languageCode, machine != ordered {
            throw OracleError("server_discovery: the rebuilt order differs from ServerDiscovery.merged")
        }
        return ordered.map(fsJSON)
    case "shown":
        let found = (c["found"] as? [Any] ?? []).map(fsServer)
        let except = (c["except"] as? [Any] ?? []).map { $0 as? String }
        return ServerDiscovery.shown(found, except: except).map(fsJSON)
    default: throw OracleError("kind")
    }
}
