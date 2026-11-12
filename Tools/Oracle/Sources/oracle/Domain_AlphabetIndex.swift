import Foundation
import JellyfinKit

// Case: {"sorting": "name|neueste|bewertung|erscheinung", "items": [{name, sort, premiere, year,
// rating, created}], "slots": n, "height": h, "ys": [..]}. `symbols` is the platform's
// Calendar.current.shortMonthSymbols (locale data): the Rust side reuses it, the logic is compared.
let domainAlphabetIndex = Domain("alphabet_index") { raw in
    let c = try srDict(raw)
    guard let sorting = Sorting(rawValue: srStr(c["sorting"]) ?? "") else { throw OracleError("sorting") }
    let items = (c["items"] as? [[String: Any]] ?? []).map {
        Item(id: "i", name: srStr($0["name"]) ?? "", productionYear: srInt($0["year"]),
             communityRating: srDouble($0["rating"]), premiereDate: srStr($0["premiere"]),
             sortName: srStr($0["sort"]), dateCreated: srStr($0["created"]))
    }
    func entry(_ e: AlphabetIndex.Entry) -> [String: Any] {
        ["letter": e.letter, "first": e.first, "label": e.label, "gap": e.gap]
    }
    let index = AlphabetIndex(items: items, sorting: sorting)
    let keys = items.map { index.key(of: $0) }
    let height = srDouble(c["height"]) ?? 0
    let ys = (c["ys"] as? [Any] ?? []).compactMap(srDouble)
    return [
        "entries": index.entries.map(entry),
        "count": index.count, "monthly": index.monthly, "useful": index.isUseful,
        "keys": keys,
        "letters": items.map { AlphabetIndex.letter(for: $0.name) },
        "name_letters": items.map { AlphabetIndex.letter(name: $0.name, sortName: $0.sortName) },
        "condensed": index.condensed(fitting: srInt(c["slots"]) ?? 0).map(entry),
        "rows": AlphabetIndex.rows(index.entries),
        "at": ys.map { y -> Any in
            AlphabetIndex.entry(at: y, height: height, in: index.entries).map { $0.letter } ?? NSNull()
        },
        "label_first": nsnull(index.label(of: keys.first)),
        "target_last": nsnull(keys.last.flatMap { index.target(for: $0, in: items) }),
        "symbols": Calendar.current.shortMonthSymbols,
    ] as [String: Any]
}
