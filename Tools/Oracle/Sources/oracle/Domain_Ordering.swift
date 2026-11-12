import Foundation
import JellyfinKit

// Domains start_rails, start_libraries, search_history, library_genre, library_filter, list_rules,
// title_filter, section_logic (StartRails, StartLibraries, SearchHistory, LibraryGenre, Library.swift,
// RailsEpisode.swift ListRules, SectionOffering.swift TitleFilter, Sections.swift SectionLogic).
// Generator: crates/swiftly-hardening/src/inputs/ordering.rs.

private func orStrings(_ x: Any?) -> [String] { (x as? [Any] ?? []).compactMap { $0 as? String } }

private func orItem(_ x: Any?) -> Item? {
    guard let x, JSONSerialization.isValidJSONObject(x),
          let data = try? JSONSerialization.data(withJSONObject: x) else { return nil }
    return try? JSONDecoder().decode(Item.self, from: data)
}
private func orItems(_ x: Any?) -> [Item] { (x as? [Any] ?? []).compactMap(orItem) }
private func orIds(_ items: [Item]) -> [String] { items.map(\.id) }

// MARK: start_rails

let domainStartRails = Domain("start_rails") { raw in
    let c = try srDict(raw)
    let stored = orStrings(c["stored"])
    let disc = srBool(c["disc"]) ?? false
    switch srStr(c["op"]) ?? "" {
    case "applicable":
        return StartRailsEpisode.applicable(stored: stored).map(\.rawValue)
    case "visible":
        return StartRailsEpisode.visible(stored: stored, from: Set(orStrings(c["hidden"])), disconnected: disc).map(\.rawValue)
    case "shifted":
        guard let rail = StartRail(rawValue: srStr(c["rail"]) ?? "") else { return NSNull() }
        return StartRailsEpisode.shifted(rail, um: srInt(c["step"]) ?? 0, stored: stored, disconnected: disc)
    default:
        guard let rail = StartRail(rawValue: srStr(c["rail"]) ?? "") else { return NSNull() }
        let jump: Any = rail.libraryJump.map { [$0.art, $0.sorting.rawValue] as [Any] } ?? NSNull()
        return ["fits": rail.fits(disconnected: disc), "list": rail.listsName, "symbol": rail.symbolText,
                "title": rail.railsTitle, "jump": jump] as [String: Any]
    }
}

// MARK: start_libraries

let domainStartLibraries = Domain("start_libraries") { raw in
    let c = try srDict(raw)
    switch srStr(c["op"]) ?? "" {
    case "read":
        let data = srStr(c["text"]).map { Data($0.utf8) }
        return StartLibraries.read(data).map { [$0.id, $0.name, $0.collection] as [Any] }
    case "data":
        let choice = (c["choice"] as? [[String: Any]] ?? []).map {
            StartLibrary(id: srStr($0["id"]) ?? "", name: srStr($0["name"]) ?? "", collection: srBool($0["collection"]) ?? false)
        }
        return nsnull(StartLibraries.data(choice).flatMap { String(data: $0, encoding: .utf8) })
    case "selectable":
        guard let item = orItem(c["item"]) else { return ["decoded": false] as [String: Any] }
        return ["decoded": true, "selectable": StartLibraries.selectable(item)] as [String: Any]
    default:
        let selected = (c["selected"] as? [[String: Any]] ?? []).map {
            StartLibrary(id: srStr($0["id"]) ?? "", name: "", collection: false)
        }
        return orIds(StartLibraries.pick(libraries: orItems(c["libraries"]), collections: orItems(c["collections"]), selected: selected))
    }
}

// MARK: search_history

let domainSearchHistory = Domain("search_history") { raw in
    let c = try srDict(raw)
    switch srStr(c["op"]) ?? "" {
    case "key": return SearchHistory.key(account: srStr(c["account"]))
    case "list": return SearchHistory.list(srStr(c["raw"]) ?? "")
    default: return SearchHistory.remember(srStr(c["word"]) ?? "", in: srStr(c["raw"]) ?? "")
    }
}

// MARK: library_genre

let domainLibraryGenre = Domain("library_genre") { raw in
    let c = try srDict(raw)
    let art = srStr(c["art"])
    return ["types": LibraryGenre.types(toward: art), "recursive": LibraryGenre.recursive(toward: art)] as [String: Any]
}

// MARK: library_filter

let domainLibraryFilter = Domain("library_filter") { raw in
    let c = try srDict(raw)
    let filters = orStrings(c["filters"]).compactMap(LibraryFilter.init(rawValue:))
    switch srStr(c["op"]) ?? "" {
    case "sorting":
        guard let s = Sorting(rawValue: srStr(c["raw"]) ?? "") else { return NSNull() }
        return ["field": s.inputField, "bearing": s.bearing] as [String: Any]
    case "filter":
        guard let f = LibraryFilter(rawValue: srStr(c["raw"]) ?? "") else { return NSNull() }
        return ["jf": f.jellyfinFilter, "watched": nsnull(f.isWatched)] as [String: Any]
    case "offered":
        return LibraryFilter.offered(filters, watchlist: srBool(c["watchlist"]) ?? true).map(\.rawValue)
    case "kept":
        guard let f = LibraryFilter(rawValue: srStr(c["raw"]) ?? "") else { return NSNull() }
        return f.kept(in: filters).rawValue
    case "remember":
        guard let g = RememberGenre(rawValue: srStr(c["raw"]) ?? "") else { return NSNull() }
        return ["art": nsnull(g.art), "types": g.types] as [String: Any]
    default:
        return RememberGenre.toward(art: srStr(c["art"])).rawValue
    }
}

// MARK: list_rules

let domainListRules = Domain("list_rules") { raw in
    let c = try srDict(raw)
    let items = orItems(c["items"])
    switch srStr(c["op"]) ?? "" {
    case "double": return orIds(ListRules.withoutDouble(items))
    case "title": return orIds(ListRules.jeTitleInTimes(items, showItem: srInt(c["show"]) ?? 0))
    case "append": return orIds(ListRules.append(orItems(c["more"]), an: items))
    case "refresh":
        return orIds(ListRules.refresh(orItems(c["more"]), in: items, totalBefore: srInt(c["before"]) ?? 0, totalNow: srInt(c["now"]) ?? 0))
    case "rails": return orIds(ListRules.inRailsEpisode(items, how: orItems(c["more"])))
    case "post": return ListRules.postLoadSection(srStr(c["id"]) ?? "", in: items, columns: srInt(c["columns"]) ?? 1)
    default: return ListRules.stillMorePresent(loaded: srInt(c["loaded"]) ?? 0, total: srInt(c["total"]) ?? 0)
    }
}

// MARK: title_filter

let domainTitleFilter = Domain("title_filter") { raw in
    let c = try srDict(raw)
    let libs = (c["libs"] as? [[String: Any]] ?? []).map { (library: srStr($0["id"]) ?? "", identifiers: orItems($0["items"])) }
    var filter = TitleFilter(je: libs)
    let front = srInt(c["front_after"])
    var pages: [[String]] = []
    for (n, page) in (c["pages"] as? [Any] ?? []).enumerated() {
        pages.append(orIds(filter.seven(orItems(page))))
        if front == n { filter.fromFront() }
    }
    return ["total": filter.total, "pages": pages] as [String: Any]
}

// MARK: section_logic

private func slSegments(_ x: Any?) -> [Segment] {
    (x as? [[String: Any]] ?? []).map {
        Segment(art: Segment.Art(rawValue: srStr($0["art"]) ?? "Unknown") ?? .unknown,
                from: srDouble($0["from"]) ?? 0, until: srDouble($0["until"]) ?? 0)
    }
}

private func slOffering(_ o: ButtonOffering) -> [Any] {
    switch o {
    case .nobody: ["nobody"]
    case let .skip(to, art): ["skip", to, art.rawValue]
    case .nextEpisode: ["next"]
    }
}

let domainSectionLogic = Domain("section_logic") { raw in
    let c = try srDict(raw)
    let position = srDouble(c["position"]) ?? 0, duration = srDouble(c["duration"]) ?? 0
    let sections = slSegments(c["sections"])
    let next = srBool(c["next"]) ?? false
    let window = srDouble(c["window"])
    switch srStr(c["op"]) ?? "" {
    case "automatic":
        guard let a = SectionLogic.automatic(position: position, duration: duration, sections: sections, hasNextEpisode: next)
        else { return NSNull() }
        return [a.segment.art.rawValue, a.segment.from, a.segment.until, slOffering(a.offering)] as [Any]
    case "card":
        return SectionLogic.cardDue(position: position, duration: duration, sections: sections, hasNextEpisode: next, remainingWindow: window)
    case "countdown":
        return SectionLogic.countdown(position: position, duration: duration)
    case "countdown2":
        return SectionLogic.countdown(position: position, duration: duration, sections: sections, remainingWindow: window)
    default:
        return slOffering(SectionLogic.offering(position: position, duration: duration, sections: sections, hasNextEpisode: next))
    }
}
