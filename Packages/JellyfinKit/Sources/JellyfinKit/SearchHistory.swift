import Foundation

/// **What was searched for last: the last eight, most recent first.**
///
/// It started as two functions in the iPhone search. Since the TV shows the same
/// list, the rule lives here: a copied function would be the start of two
/// versions that drift apart.
///
/// Stored is a string with one term per line, because `@AppStorage` takes no
/// arrays. The key is the same on all devices; nothing is shared though, each
/// device remembers what was searched on it.
public enum SearchHistory {
    public static let key = "letzteSuchen"
    public static let atMost = 8

    /// **The history belongs to the account, not the device:** whoever switches
    /// profile does not see the searches of the previous one (shared iPad).
    /// Without an account, the shared key from before.
    public static func key(account: String?) -> String {
        guard let account, !account.isEmpty else { return key }
        return "\(key).\(account)"
    }

    public static func list(_ raw: String) -> [String] {
        raw.split(separator: "\n").map(String.init)
    }

    /// Records a term and returns the new state.
    ///
    /// Nothing under two characters; searching only starts at two. The same term in
    /// a different spelling replaces the old one and moves to the front instead of
    /// appearing twice.
    public static func remember(_ word: String, in raw: String) -> String {
        let clean = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 2 else { return raw }
        var new = list(raw).filter { $0.caseInsensitiveCompare(clean) != .orderedSame }
        new.insert(clean, at: 0)
        return new.prefix(atMost).joined(separator: "\n")
    }
}

/// **Where the history lives on Apple devices:** one `UserDefaults` string per account.
///
/// The iPhone and the TV both had this as private helpers of their search view. An account that has
/// no history of its own yet starts from the shared one from before the history belonged to the
/// account. Android keeps the same string in its own store and only uses the rules above.
public enum SearchHistoryStore {
    public static func load(account: String?, store: UserDefaults = .standard) -> String {
        let key = SearchHistory.key(account: account)
        if key != SearchHistory.key, store.object(forKey: key) == nil {
            store.set(store.string(forKey: SearchHistory.key) ?? "", forKey: key)
        }
        return store.string(forKey: key) ?? ""
    }

    public static func save(_ raw: String, account: String?, store: UserDefaults = .standard) {
        store.set(raw, forKey: SearchHistory.key(account: account))
    }
}
