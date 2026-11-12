import Foundation

/// **The letter strip beside an A–Z grid**: which letters exist, and where each one
/// starts.
///
/// Built from the names of the whole list (``JellyfinClient/items`` with `slim`), in the
/// server's order. The strip shows only letters that titles actually start with (no "В"
/// without a title on "В"), in alphabetical order: "#", Latin, Cyrillic, then other
/// scripts, as Plex does.
///
/// **The letter does not always follow the grid's order.** Jellyfin may sort by a
/// transliterated name ("vyzhivshii" for "Выживший"), so Cyrillic titles sit among the
/// Latin ones. The strip still shows "В" for them, because that is what the reader sees;
/// a jump goes to the first title with that letter, and the highlighted letter moves
/// with the titles as the grid scrolls.
public struct AlphabetIndex: Sendable, Equatable {

    public struct Entry: Sendable, Equatable, Hashable, Identifiable {
        /// **The key**: what a title is matched against and what a jump asks for. For
        /// "By name" the letter itself ("#", "A", "Ё", "流"); for the other orders see
        /// ``AlphabetIndex/key(of:sorting:)``.
        public let letter: String
        /// Position of the first title with this key in the server's list.
        public let first: Int
        /// **What the strip shows.** The letter, or "26" for a year, "7" for a rating.
        public let label: String
        /// **A dot before this entry**: the next step among years and ratings. It marks the
        /// step, it is not a target of its own.
        public let gap: Bool
        public var id: String { letter }

        public init(letter: String, first: Int, label: String? = nil, gap: Bool = false) {
            self.letter = letter
            self.first = first
            self.label = label ?? letter
            self.gap = gap
        }
    }

    /// In the strip's order. A key appears once, with its first title.
    public let entries: [Entry]
    /// How many titles the list holds.
    public let count: Int
    /// The order the list is sorted in; it decides what a key is.
    public let sorting: Sorting
    /// **"Zuletzt" by month**: set when every title was added in one year (or none is
    /// dated more than one year apart), so years alone would give no index. Keys are
    /// then "2026-10" and labels "Okt 26".
    public let monthly: Bool

    /// - Parameter titles: Name and the server's sort name of every title, in list order.
    public init(titles: [(name: String, sortName: String?)]) {
        var firstAt: [String: Int] = [:]
        for (i, title) in titles.enumerated() {
            let letter = Self.letter(name: title.name, sortName: title.sortName)
            if firstAt[letter] == nil { firstAt[letter] = i }
        }
        entries = firstAt.map { Entry(letter: $0.key, first: $0.value) }
            .sorted { Self.order($0.letter) < Self.order($1.letter) }
        count = titles.count
        sorting = .name
        monthly = false
    }

    /// **The strip for any order**, from the whole list in the server's order.
    ///
    /// "By name" gives the letters as above. The others keep the list's own order (newest
    /// year, highest rating first), because there the strip is a scale and not an alphabet:
    /// - "Jahr": the premiere year in two digits, "26 25 24".
    /// - "Bewertung": the whole part of the community rating, "9 8 7".
    /// - "Zuletzt": the year the title was added, in two digits. Years, not quarters: a
    ///   quarter rarely adds enough titles to be worth a jump of its own.
    ///
    /// Titles without the value share "—".
    public init(items: [Item], sorting: Sorting) {
        guard sorting != .name else {
            self.init(titles: items.map { ($0.name, $0.sortName) })
            return
        }
        // "Zuletzt": months instead of years when the years alone are no scale.
        let monthly = sorting == .latest
            && Set(items.compactMap { Self.year(of: $0.dateCreated) }).count <= 1
        var keys: [String] = []
        var firstAt: [String: Int] = [:]
        for (i, item) in items.enumerated() {
            let key = Self.key(of: item, sorting: sorting, monthly: monthly)
            if firstAt[key] == nil { firstAt[key] = i; keys.append(key) }
        }
        var built: [Entry] = []
        for key in keys {
            // Years and ratings are a scale: a dot between every two steps.
            built.append(Entry(letter: key, first: firstAt[key]!,
                               label: Self.label(for: key, sorting: sorting, monthly: monthly),
                               gap: !built.isEmpty))
        }
        self.init(entries: built, count: items.count, sorting: sorting, monthly: monthly)
    }

    /// A strip that is already built (the Rust core hands out entries, count, order and month flag).
    public init(entries: [Entry], count: Int, sorting: Sorting, monthly: Bool) {
        self.entries = entries
        self.count = count
        self.sorting = sorting
        self.monthly = monthly
    }

    // MARK: Keys of the other orders

    /// What a title is matched by in this index.
    public func key(of item: Item) -> String {
        Self.key(of: item, sorting: sorting, monthly: monthly)
    }

    /// **The key of a title for an order**: the letter, the year ("2025"), the rating
    /// ("r7") or the year added ("2025"); "—" when the title lacks the value.
    public static func key(of item: Item, sorting: Sorting, monthly: Bool = false) -> String {
        switch sorting {
        case .name:
            return letter(name: item.name, sortName: item.sortName)
        case .erscheinung:
            guard let year = year(of: item.premiereDate) ?? item.productionYear else { return "—" }
            return String(year)
        case .rating:
            guard let rating = item.communityRating, rating.isFinite else { return "—" }
            return "r\(min(10, max(0, Int(rating))))"
        case .latest:
            guard let year = year(of: item.dateCreated) else { return "—" }
            if monthly, let month = month(of: item.dateCreated) {
                return String(year) + (month < 10 ? "-0\(month)" : "-\(month)")
            }
            return String(year)
        }
    }

    /// The year of an ISO 8601 date ("2009-12-31T00:00:00.0000000Z").
    private static func year(of date: String?) -> Int? {
        guard let date, date.count >= 4, let year = Int(date.prefix(4)), year > 0 else { return nil }
        return year
    }

    /// The month (1 to 12) of an ISO 8601 date.
    private static func month(of date: String?) -> Int? {
        guard let date, date.count >= 7 else { return nil }
        let part = date.dropFirst(5).prefix(2)
        guard let month = Int(part), (1...12).contains(month) else { return nil }
        return month
    }

    private static func twoDigits(_ year: Int) -> String {
        let rest = year % 100
        return rest < 10 ? "0\(rest)" : String(rest)
    }

    private static func label(for key: String, sorting: Sorting, monthly: Bool) -> String {
        guard key != "—" else { return key }
        if monthly, sorting == .latest, key.count == 7, let year = Int(key.prefix(4)),
           let month = Int(key.suffix(2)) {
            let names = Calendar.current.shortMonthSymbols
            let name = names.indices.contains(month - 1) ? names[month - 1] : ""
            return name.trimmingCharacters(in: CharacterSet(charactersIn: ".")) + " " + twoDigits(year)
        }
        switch sorting {
        case .name:        return key
        case .erscheinung, .latest: return Int(key).map(twoDigits) ?? key
        case .rating:      return String(key.dropFirst())
        }
    }

    /// Fewer than two letters is no index: nothing to jump between.
    public var isUseful: Bool { entries.count > 1 }

    /// **The letter of a title.** From the sort name while the title is Latin, so "The
    /// Adam Project" stands under "A" where the grid puts it; from the title itself when
    /// it is written in another script, because the server may have transliterated the
    /// sort name ("vyzhivshii") and the reader expects "В".
    public static func letter(name: String, sortName: String?) -> String {
        let shown = letter(for: name)
        if shown == "#" || isLatin(shown) { return letter(for: sortName ?? name) }
        return shown
    }

    /// **The letter of one string.** Digits share "#", and so does a name without letters
    /// or digits; punctuation in front is skipped. Latin
    /// letters lose their accents ("É" under "E", as in every Latin index); other scripts
    /// keep theirs, since there they are letters of their own ("Й" is not "И"). Only "Ё"
    /// joins "Е": Russian sorts them together (``NaturalOrder``), and a letter of its own
    /// would jump back and forth inside the "Е" titles.
    public static func letter(for name: String) -> String {
        // **Leading quotes and brackets are not the title**: «Старый» Новый год stands
        // under "С", "(500) Days of Summer" under "#".
        guard let first = name.first(where: { $0.isLetter || $0.isNumber }),
              first.isLetter else { return "#" }
        let upper = String(first).uppercased()
        // Latin accents and Arabic hamza or vowel marks belong to the letter, not beside it:
        // "É" stands under "E", "أ" and "إ" under "ا".
        if let scalar = upper.unicodeScalars.first,
           (0x00C0...0x024F).contains(scalar.value) || (0x0600...0x06FF).contains(scalar.value) {
            // The base letter is the first scalar of the canonical decomposition: "É" is
            // "E" + accent, "أ" is "ا" + hamza.
            if let base = upper.decomposedStringWithCanonicalMapping.unicodeScalars.first {
                return String(Character(base))
            }
        }
        if upper == "Ё" { return "Е" }
        // "ß" becomes "SS"; the strip wants one character.
        return String(upper.prefix(1))
    }

    private static func isLatin(_ letter: String) -> Bool {
        guard let v = letter.unicodeScalars.first?.value else { return false }
        return (0x41...0x5A).contains(v)
    }

    /// **Alphabetical, across scripts**: "#", then by code point, which keeps each
    /// script's letters together and in order (Latin, Cyrillic, Arabic, Han by radical and
    /// stroke as Unicode orders it), the same order ``NaturalOrder`` sorts the grid by.
    static func order(_ letter: String) -> UInt32 {
        guard letter != "#", let v = letter.unicodeScalars.first?.value else { return 0 }
        return v
    }

    /// **Where to scroll for a letter, among the titles loaded so far**: the first loaded
    /// title with exactly this letter. `nil` means it is not loaded yet: load more and ask
    /// again.
    ///
    /// Not the server position: the grid drops duplicates and filters some titles itself,
    /// so its positions drift from the server's. The letters of the loaded titles do not.
    public func target(for letter: String,
                       inLoaded loaded: [(name: String, sortName: String?)]) -> Int? {
        loaded.firstIndex { Self.letter(name: $0.name, sortName: $0.sortName) == letter }
    }

    /// The same for any order, by the loaded titles' keys.
    public func target(for key: String, in loaded: [Item]) -> Int? {
        loaded.firstIndex { self.key(of: $0) == key }
    }

    /// What the strip shows for a key ("25" for "2025"), for VoiceOver and the like.
    public func label(of key: String?) -> String? {
        guard let key else { return nil }
        return entries.first { $0.letter == key }?.label ?? key
    }

    /// **How long a tapped entry is held** at most, should the grid never get there.
    public static let holdSeconds = 5

    /// **How much height a dot takes**, as a share of an entry's row.
    public static let gapShare = 0.5

    /// The strip's height in rows: one per entry, half a row per dot.
    public static func rows(_ shown: [Entry]) -> Double {
        Double(shown.count) + Double(shown.filter(\.gap).count) * gapShare
    }

    /// **The entry under a point of the strip**, `y` from 0 to `height`. A dot belongs to
    /// the entry after it, the group it opens.
    public static func entry(at y: Double, height: Double, in shown: [Entry]) -> Entry? {
        guard !shown.isEmpty, height > 0 else { return nil }
        let row = height / rows(shown)
        var bottom = 0.0
        for entry in shown {
            bottom += (entry.gap ? gapShare * row : 0) + row
            if y < bottom { return entry }
        }
        return shown.last
    }

    /// **The strip when it does not fit.** Keeps the first and the last letter and spreads
    /// the rest evenly, as the section index on iOS does. Every kept letter still jumps to
    /// itself.
    public func condensed(fitting slots: Int) -> [Entry] {
        // Dots take height too (``rows(_:)``).
        guard slots >= 2, Self.rows(entries) > Double(slots) else { return entries }
        if sorting != .name { return thinned(fitting: slots) }
        let last = entries.count - 1
        var picked: [Entry] = []
        var taken = Set<Int>()
        for k in 0..<slots {
            let i = Int((Double(k) * Double(last) / Double(slots - 1)).rounded())
            if taken.insert(i).inserted { picked.append(entries[i]) }
        }
        return picked
    }

    /// **A scale thinned from the top down**: the newest years (or highest ratings)
    /// one after another, further down ever sparser, the last one always. That is
    /// where people look: last year's films are sought far more often than 1987's. Each kept
    /// entry still jumps to itself; the dots between them count for height.
    private func thinned(fitting slots: Int) -> [Entry] {
        // An entry and the dot before it take 1 + `gapShare` rows; the first has no dot.
        let fits = max(2, Int((Double(slots) + Self.gapShare) / (1 + Self.gapShare)))
        guard entries.count > fits else { return entries }
        let last = entries.count - 1
        var picked: [Int] = []
        for k in 0..<fits {
            // Squared, so the steps grow towards the end of the list.
            let share = Double(k) / Double(fits - 1)
            var i = Int((share * share * Double(last)).rounded())
            if let before = picked.last { i = max(i, before + 1) }
            // Leave room for the ones still to come, the last entry above all.
            i = min(i, last - (fits - 1 - k))
            picked.append(i)
        }
        return picked.enumerated().map { k, i in
            let e = entries[i]
            // The first shown entry stands at the top: no dot above it.
            return k == 0 ? Entry(letter: e.letter, first: e.first, label: e.label) : e
        }
    }
}
