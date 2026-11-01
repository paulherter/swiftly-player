import Foundation

/// **The on-screen keyboard of the TV search: what is on it and what a press does to the term.**
///
/// The remote has no keyboard, and the system one is a full screen that hides the results. So the TV
/// search draws its own grid next to the results (`TVSearchKeyboard`, `TvSearchKeyboard`). The
/// layout and the rules for what a press does live here, once, so both TVs type the same way.
///
/// Alphabetical, not QWERTZ: with a directional pad you look for a letter, you do not touch-type.
/// The umlauts fill the fifth row exactly (26 + 4 = 30).
public enum SearchKeys {
    public static let columns = 6

    /// One cell of the grid. `span` is how many columns it covers.
    public struct Key: Equatable, Hashable, Sendable {
        public enum Kind: String, Sendable { case letter, space, delete, speak }
        public let kind: Kind
        /// The character a letter key types, in capitals as shown on the key. Empty for the others.
        public let character: String
        public let span: Int
        public var id: String { kind == .letter ? character : kind.rawValue }
    }

    private static let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÜß1234567890-").map(String.init)

    /// The rows from top to bottom. Without speech input the delete key takes all six columns.
    public static func rows(speech: Bool) -> [[Key]] {
        var rows: [[Key]] = []
        var i = 0
        while i + columns <= 30 {
            rows.append(letters[i..<i + columns].map { Key(kind: .letter, character: $0, span: 1) })
            i += columns
        }
        // "1 2 3 4 5 6" and then "7 8 9 0 - space"
        rows.append(letters[30..<36].map { Key(kind: .letter, character: $0, span: 1) })
        rows.append(letters[36..<41].map { Key(kind: .letter, character: $0, span: 1) }
                    + [Key(kind: .space, character: "", span: 1)])
        rows.append(speech
            ? [Key(kind: .delete, character: "", span: 3), Key(kind: .speak, character: "", span: 3)]
            : [Key(kind: .delete, character: "", span: columns)])
        return rows
    }

    /// Where a letter starts a word: at the very beginning, after a space, after a hyphen.
    private static func startsWord(_ term: String) -> Bool {
        guard let last = term.last else { return true }
        return last == " " || last == "-"
    }

    /// What typing this key adds. Capital at the start of a word, otherwise lower case: "Tatort
    /// Münster", not "TATORT MÜNSTER". The search ignores case anyway, but the history reads like a
    /// title. The sharp s stays lower case (its capital form is two letters).
    public static func typed(_ character: String, into term: String) -> String {
        let one = character.lowercased()
        let capital = character.uppercased()
        let add = startsWord(term) && capital.count == 1 ? capital : one
        return term + add
    }

    /// A space makes sense after a character that is not a space already.
    public static func spaceFits(_ term: String) -> Bool {
        guard let last = term.last else { return false }
        return last != " "
    }

    public static func withSpace(_ term: String) -> String {
        spaceFits(term) ? term + " " : term
    }

    public static func withoutLast(_ term: String) -> String {
        String(term.dropLast())
    }

    /// Text from a hardware keyboard: letters, digits and the hyphen are taken like the keys, a space
    /// like the space key. Anything else is ignored.
    public static func hardware(_ text: String, into term: String) -> String {
        var result = term
        for ch in text {
            if ch == " " { result = withSpace(result) }
            else if ch.isLetter || ch.isNumber || ch == "-" { result = typed(String(ch), into: result) }
        }
        return result
    }
}

/// **How the hits are cut into blocks.** The server delivers movies and series only (`search`, limit 40).
public enum SearchGroups {
    public struct Split<T> {
        public var series: [T]
        public var films: [T]
    }

    public static func split<T>(_ items: [T], type: (T) -> String?) -> Split<T> {
        Split(series: items.filter { type($0) == "Series" }, films: items.filter { type($0) == "Movie" })
    }

    /// **Block titles only when more than one block stands there.** A single block under its own title
    /// announces nothing; the same rule as on the iPhone ("no heading that announces an empty block").
    public static func showsTitles(series: Int, films: Int, requests: Int) -> Bool {
        [series, films, requests].filter { $0 > 0 }.count > 1
    }
}

/// **What the right side of the TV search shows.** One function, so both TVs agree and it is tested.
public enum SearchScreen: String, Sendable {
    /// Nothing typed yet and there are earlier searches.
    case history
    /// Nothing typed yet, first visit.
    case start
    /// Waiting for the first answer, long enough to show the placeholder.
    case loading
    /// Waiting for the first answer, short enough to show nothing yet (no flicker).
    case blank
    case hits
    case nothing
    case disrupted

    /// - `hasHits`: there is something on screen, from the server or from Seerr. Old hits stay until the
    ///   next answer is in, so this is true between two letters.
    /// - `answered`: an answer has arrived since the page was cleared.
    /// - `waited`: the answer takes longer than 300 ms.
    public static func state(term: String, historyCount: Int, hasHits: Bool, answered: Bool,
                             disrupted: Bool, waited: Bool) -> SearchScreen {
        guard DisplayRules.searchTermFits(term) else { return historyCount > 0 ? .history : .start }
        if disrupted { return .disrupted }
        if hasHits { return .hits }
        if answered { return .nothing }
        return waited ? .loading : .blank
    }
}
