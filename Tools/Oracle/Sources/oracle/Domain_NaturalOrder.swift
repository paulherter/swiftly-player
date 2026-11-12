import Foundation
import JellyfinKit

// Case: {"locale": "ru", "titles": [{"name": "...", "sort": "..."|null}]}
// Result: {"group": [..], "key": [..], "sorted": [indexes in natural order]}
let domainNaturalOrder = Domain("natural_order") { raw in
    guard let c = raw as? [String: Any], let locale = c["locale"] as? String,
          let titles = c["titles"] as? [[String: Any]] else { throw OracleError("natural_order: bad case") }
    let list = titles.map { (name: $0["name"] as? String ?? "", sort: $0["sort"] as? String) }
    let loc = Locale(identifier: locale)
    let groups = list.map { NaturalOrder.group(name: $0.name, sortName: $0.sort) }
    let keys = list.map { NaturalOrder.key(name: $0.name, sortName: $0.sort) }
    let order = NaturalOrder.sorted(Array(list.indices), locale: loc) { (name: list[$0].name, sortName: list[$0].sort) }
    return ["group": groups, "key": keys, "sorted": order] as [String: Any]
}
