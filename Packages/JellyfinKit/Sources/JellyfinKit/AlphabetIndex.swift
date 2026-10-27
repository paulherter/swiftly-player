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
        /// What the strip shows: "#", "A", "Ё", "流".
        public let letter: String
        /// Position of the first title with this letter in the server's list.
        public let first: Int
        public var id: String { letter }
    }

    /// In alphabetical order. A letter appears once, with its first title.
    public let entries: [Entry]
    /// How many titles the list holds.
    public let count: Int

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

    /// **The strip when it does not fit.** Keeps the first and the last letter and spreads
    /// the rest evenly, as the section index on iOS does. Every kept letter still jumps to
    /// itself.
    public func condensed(fitting slots: Int) -> [Entry] {
        guard slots >= 2, entries.count > slots else { return entries }
        let last = entries.count - 1
        var picked: [Entry] = []
        var taken = Set<Int>()
        for k in 0..<slots {
            let i = Int((Double(k) * Double(last) / Double(slots - 1)).rounded())
            if taken.insert(i).inserted { picked.append(entries[i]) }
        }
        return picked
    }
}
