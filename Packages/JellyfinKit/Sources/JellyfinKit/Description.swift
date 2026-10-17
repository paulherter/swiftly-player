import Foundation

/// **Server descriptions, made readable.**
///
/// Jellyfin passes the text through as stored, and for series from some sources
/// it contains markup: `<br>`, `<p>`, `<i>`, plus `&amp;` and `&#39;`. The UI
/// used to show that literally.
///
/// What matters for running text, line breaks and paragraphs, is converted;
/// the rest is dropped. Emphasis is lost; an italic line is decoration in a
/// description, a line break is not.
///
/// **Here and not in the view**, because six platform versions show the same
/// text. Cleaning per UI would be the same function six times.
public enum Description {

    public static func readable(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\r\n", with: "\n")

        // Line breaks and paragraphs first, while the tags are still there.
        s = s.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)</(p|div|h[1-6])\s*>"#, with: "\n\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)<li[^<>]*>"#, with: "\n• ", options: .regularExpression)

        // All other tags. Only what looks like one: a letter directly after "<" or
        // "</". "5 < 6 and 7 > 3" stays.
        s = s.replacingOccurrences(of: #"</?[A-Za-z][^<>]*>"#, with: "", options: .regularExpression)

        s = characterResolve(s)

        // **Non-breaking spaces become normal ones.** In a description everything
        // should be allowed to wrap; a paragraph whose words are tied by such
        // characters is a single word for line breaking, wider than the screen, and
        // the whole page could be dragged sideways.
        for symbolText in ["\u{00A0}", "\u{202F}", "\u{2007}"] {
            s = s.replacingOccurrences(of: symbolText, with: " ")
        }

        // Trailing whitespace removed, at most one blank line in a row.
        s = s.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `&amp;` last: otherwise `&amp;lt;` would become `&lt;` and then `<`,
    /// decoded twice where once was meant.
    private static func characterResolve(_ text: String) -> String {
        var s = text
        for (mark, symbolText) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                                 ("&apos;", "'"), ("&#39;", "'"), ("&nbsp;", " ")] {
            s = s.replacingOccurrences(of: mark, with: symbolText)
        }
        s = numberCharacterResolve(s)
        return s.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// `&#8211;` and `&#x2013;`: some sources only provide dashes and quotation
    /// marks this way.
    private static func numberCharacterResolve(_ text: String) -> String {
        guard let muster = try? NSRegularExpression(pattern: #"&#(x?)([0-9A-Fa-f]{1,6});"#) else { return text }
        let ns = text as NSString
        var result = ""
        var recent = 0
        for hit in muster.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: recent, length: hit.range.location - recent))
            let hex = ns.substring(with: hit.range(at: 1)) == "x"
            let digits = ns.substring(with: hit.range(at: 2))
            if let value = UInt32(digits, radix: hex ? 16 : 10), let symbolText = Unicode.Scalar(value) {
                result += String(Character(symbolText))
            } else {
                result += ns.substring(with: hit.range)
            }
            recent = hit.range.location + hit.range.length
        }
        result += ns.substring(from: recent)
        return result
    }
}

extension Item {
    /// The description as it should appear on screen, `nil` if nothing is left
    /// after cleaning.
    public var description: String? {
        guard let overview else { return nil }
        let text = Description.readable(overview)
        return text.isEmpty ? nil : text
    }
}

extension Item {
    /// The day from `PremiereDate`; for a person, the birthday.
    ///
    /// **Only the day, without time.** Jellyfin adds midnight UTC; read as an
    /// instant, it would be the previous day west of Greenwich.
    public var daysDate: DateComponents? {
        guard let raw = premiereDate, raw.count >= 10 else { return nil }
        let parts = raw.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return DateComponents(year: parts[0], month: parts[1], day: parts[2])
    }

    /// The ID at TMDB, through which Seerr finds a person.
    public var tmdbId: Int? { providerIds?["Tmdb"].flatMap { Int($0) } }
}
