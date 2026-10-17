import Foundation

/// Reads Jellyfin's timestamps.
///
/// **`.iso8601` is not enough, and that goes unnoticed.** The server sends
/// `2026-09-03T14:10:09.2201736Z`, seven fractional digits. Swift's
/// `dateDecodingStrategy = .iso8601` does not know fractions and throws; if the field
/// is then in a `try?`, the value silently disappears. Verified against the server,
/// on `/Sessions`.
///
/// That is exactly what would have broken the idle check in ``Takeover``: without a
/// date a session counts as fresh, and a crashed app would have been offered for
/// takeover for minutes.
///
/// Hence **two** forms, in this order: with fractions, then without. Both occur;
/// `PremiereDate` for instance has none.
enum TimestampFormat {

    /// The same path for a text that is already there (``UserItemData/lastPlay``).
    static func read(_ text: String) -> Date? {
        let withBreak = ISO8601DateFormatter()
        withBreak.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withBreak.date(from: text) { return d }
        let withoutBreak = ISO8601DateFormatter()
        withoutBreak.formatOptions = [.withInternetDateTime]
        return withoutBreak.date(from: text)
    }

    /// **The formatters are created per call, and that is deliberate.**
    ///
    /// `ISO8601DateFormatter` is not `Sendable`; as a shared static Swift 6 rejects it,
    /// and with `nonisolated(unsafe)` it would be an assurance nobody has checked. Here a
    /// few calls run per query, no loop; the cost is not measurable.
    static func read(from decoder: any Decoder) throws -> Date {
        let text = try decoder.singleValueContainer().decode(String.self)
        if let d = read(text) { return d }
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "Kein lesbarer Zeitstempel: \(text)"))
    }
}
