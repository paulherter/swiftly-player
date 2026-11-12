import Foundation
@testable import JellyfinKit

// Group C, text: plural_category, version_compare, timestamp. Cases: crates/swiftly-hardening/src/inputs/text_c.rs.
// PluralCategory and TimestampFormat are internal; the oracle is a debug build, so @testable works.

func tcDict(_ raw: Any) throws -> [String: Any] {
    guard let c = raw as? [String: Any] else { throw OracleError("bad case") }
    return c
}
func tcInt(_ x: Any?) -> Int? { (x as? NSNumber).map { $0.int64Value }.map { Int($0) } }
func tcDouble(_ x: Any?) -> Double? {
    if let s = x as? String { return s == "nan" ? .nan : (s == "inf" ? .infinity : -.infinity) }
    return (x as? NSNumber)?.doubleValue
}

let domainPluralCategory = Domain("plural_category") { raw in
    let c = try tcDict(raw)
    return PluralCategory.of(tcInt(c["n"]) ?? 0, language: (c["lang"] as? String) ?? "")
}

let domainVersionCompare = Domain("version_compare") { raw in
    let c = try tcDict(raw)
    let newer = VersionComparison.newer(
        there: (c["there"] as? String) ?? "", here: (c["here"] as? String) ?? "",
        buildThere: tcInt(c["build_there"]), buildHere: tcInt(c["build_here"]) ?? 0)
    let build = VersionComparison.buildNumber(fromText: (c["text"] as? String) ?? "")
    return ["newer": newer, "build": nsnull(build)] as [String: Any]
}

let domainTimestamp = Domain("timestamp") { raw in
    let c = try tcDict(raw)
    return nsnull(TimestampFormat.read((c["text"] as? String) ?? "")?.timeIntervalSince1970)
}
