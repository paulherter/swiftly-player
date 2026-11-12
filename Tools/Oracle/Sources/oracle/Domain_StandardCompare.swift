import Foundation

// Case: {"a": "...", "b": "..."}. Result: -1, 0 or 1 from the real `String.localizedStandardCompare`.
// The function reads the language of the process, so there is one domain per language and each must be run in a
// process of that language: `oracle <dir> standard_compare_ru -AppleLanguages "(ru)" -AppleLocale ru_RU`.
// Generator: crates/swiftly-hardening/src/inputs/standard_compare.rs.
func standardCompareDomain(_ language: String) -> Domain {
    Domain("standard_compare_\(language)") { raw in
        guard Locale.current.language.languageCode?.identifier == language else {
            throw OracleError("standard_compare_\(language): the process language is \(Locale.current.identifier), start with -AppleLanguages \"(\(language))\"")
        }
        guard let c = raw as? [String: Any], let a = c["a"] as? String, let b = c["b"] as? String else { throw OracleError("standard_compare: bad case") }
        return a.localizedStandardCompare(b).rawValue
    }
}
let domainStandardCompareDe = standardCompareDomain("de")
let domainStandardCompareEn = standardCompareDomain("en")
let domainStandardCompareRu = standardCompareDomain("ru")
