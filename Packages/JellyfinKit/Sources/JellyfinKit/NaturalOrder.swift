import Foundation

/// **"By name", in natural order**: digits first, then Latin titles, then titles in
/// other scripts, each group in the order a reader expects.
///
/// Jellyfin cannot sort like this. It may sort by a transliterated name ("vyzhivshii"
/// for "Выживший"), which mixes Cyrillic titles into the Latin ones; a Russian
/// library then reads В, V, З, Z, Ж in turn. So the list is ordered here, from the slim
/// list of all names (``JellyfinClient/items`` with `slim`), and the pages are fetched by
/// ID in this order.
///
/// - **Digits and symbols** compare as numbers: "2+1" before "007" (7) before "12".
/// - **Latin titles** compare by the server's sort name, so "The Adam Project" stays
///   among the A's.
/// - **Other scripts** (Cyrillic, Greek, Arabic, Chinese, …) compare first by their letter
///   in the strip (``AlphabetIndex/order(_:)``), which keeps each script together and the
///   grid in the strip's order; within one letter by the title in the device's language
///   rules (in Russian, "Ё" sorts with "Е", as in a dictionary).
public enum NaturalOrder {

    /// Which block a title belongs to: 0 digits and symbols, 1 Latin, 2 other scripts.
    public static func group(name: String, sortName: String?) -> Int {
        let letter = AlphabetIndex.letter(name: name, sortName: sortName)
        if letter == "#" { return 0 }
        guard let v = letter.unicodeScalars.first?.value else { return 0 }
        return (0x41...0x5A).contains(v) ? 1 : 2
    }

    /// The string a title is compared by within its block, without the quotes or brackets
    /// in front («Старый» Новый год compares as "Старый» Новый год").
    public static func key(name: String, sortName: String?) -> String {
        let key = group(name: name, sortName: sortName) == 1 ? (sortName ?? name) : name
        guard let start = key.firstIndex(where: { $0.isLetter || $0.isNumber }) else { return key }
        return String(key[start...])
    }

    /// `true` when `a` comes before `b`.
    public static func before(_ a: (name: String, sortName: String?),
                              _ b: (name: String, sortName: String?),
                              locale: Locale = .current) -> Bool {
        let ga = group(name: a.name, sortName: a.sortName)
        let gb = group(name: b.name, sortName: b.sortName)
        if ga != gb { return ga < gb }
        if ga == 2 {
            let la = AlphabetIndex.order(AlphabetIndex.letter(name: a.name, sortName: a.sortName))
            let lb = AlphabetIndex.order(AlphabetIndex.letter(name: b.name, sortName: b.sortName))
            if la != lb { return la < lb }
        }
        let result = key(name: a.name, sortName: a.sortName)
            .compare(key(name: b.name, sortName: b.sortName),
                     options: [.numeric, .caseInsensitive, .widthInsensitive],
                     range: nil, locale: locale)
        if result != .orderedSame { return result == .orderedAscending }
        // Same name twice (a remake): the server's order decides, kept by a stable sort.
        return false
    }

    /// The titles in natural order. **Stable**: equal names keep the server's order.
    public static func sorted<T>(_ titles: [T], locale: Locale = .current,
                                 by title: (T) -> (name: String, sortName: String?)) -> [T] {
        titles.enumerated()
            .sorted { lhs, rhs in
                let a = title(lhs.element), b = title(rhs.element)
                if before(a, b, locale: locale) { return true }
                if before(b, a, locale: locale) { return false }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
