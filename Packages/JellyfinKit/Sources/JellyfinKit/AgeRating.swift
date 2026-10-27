import Foundation

/// **The age rating as people write it**: "18+", not "age18+".
///
/// Jellyfin passes on whatever the metadata provider stored. Russian providers
/// store the age limit as `age18` or `age18+`, and the badge showed that word
/// verbatim. In Russian the limit is written as the number with a plus, and
/// so it is for every provider that uses this form.
///
/// Only the `age` form is rewritten. "PG-13", "FSK 12" or "TV-MA" are names of
/// rating systems and stay as the server sends them.
public enum AgeRating {

    public static func text(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        guard raw.lowercased().hasPrefix("age") else { return raw }
        let rest = raw.dropFirst(3).drop { $0 == " " || $0 == "-" || $0 == "_" }
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty else { return raw }
        return digits + "+"
    }
}

extension Item {
    /// ``officialRating`` for the badge, see ``AgeRating``.
    public var ageRating: String? { AgeRating.text(officialRating) }
}
