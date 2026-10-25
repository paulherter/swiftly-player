import Foundation

/// **Which plural form a whole number takes**, for the platforms that read the
/// `stringsdict` by hand (Linux, Windows, the Android core; see `TextCatalog.swift`).
///
/// Apple picks the form itself. Without this table every other platform knew only
/// `n == 1` versus the rest, which is right for German and English and wrong for
/// Russian: "2 сезона" and "5 сезонов" are different forms, and "21 сезон" is the
/// singular again.
///
/// The rules are CLDR's for integers. A language missing here gets the German and
/// English rule, so adding a language without its rule costs grammar, not text.
enum PluralCategory {

    static func of(_ number: Int, language: String) -> String {
        let n = abs(number)
        switch String(language.prefix(2)) {
        // East Slavic: one = ends in 1 but not 11, few = ends in 2–4 but not 12–14.
        case "ru", "uk", "be":
            let last = n % 10, lastTwo = n % 100
            if last == 1 && lastTwo != 11 { return "one" }
            if (2...4).contains(last) && !(12...14).contains(lastTwo) { return "few" }
            return "many"
        default:
            return n == 1 ? "one" : "other"
        }
    }
}
