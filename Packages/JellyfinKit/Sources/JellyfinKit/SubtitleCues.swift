import Foundation

/// One line of text that is shown from `start` to `end` (seconds).
public struct SubtitleCue: Sendable, Equatable {
    public let start: Double
    public let end: Double
    public let text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start; self.end = end; self.text = text
    }
}

/// **A subtitle file read into cues, so the app can draw the text itself.**
///
/// AVPlayer cannot show a server's SRT next to an HLS stream it copies; the player view draws
/// the text with the saved ``SubtitleLook``. Reads SRT and WebVTT, the two formats the server
/// hands out as text. Markup (`<i>`, `{\an8}`, ASS overrides) is dropped, the look decides.
public struct SubtitleCues: Sendable, Equatable {
    public let cues: [SubtitleCue]

    /// Sorted by start; the order the file has is kept for equal starts.
    public init(cues: [SubtitleCue]) {
        self.cues = cues.enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
    }

    public var isEmpty: Bool { cues.isEmpty }

    /// The text to show at `seconds`: every cue that covers it, one under the other.
    /// `nil` when none does.
    public func text(at seconds: Double) -> String? {
        // Last cue that starts at or before `seconds`.
        var low = 0, high = cues.count
        while low < high {
            let middle = (low + high) / 2
            if cues[middle].start <= seconds { low = middle + 1 } else { high = middle }
        }
        // Overlapping cues are rare and short; looking back a few entries is enough.
        var found: [String] = []
        var position = low - 1
        var looked = 0
        while position >= 0, looked < 8 {
            if cues[position].end > seconds { found.append(cues[position].text) }
            position -= 1
            looked += 1
        }
        return found.isEmpty ? nil : found.reversed().joined(separator: "\n")
    }

    // MARK: - Reading

    public static func parse(_ raw: String) -> SubtitleCues {
        var text = raw
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let arrow = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[arrow].components(separatedBy: "-->")
            guard parts.count == 2, let start = seconds(parts[0]),
                  // WebVTT puts cue settings after the end time ("... line:90%").
                  let end = seconds(parts[1].trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: .whitespaces).first ?? "")
            else { continue }
            let body = lines[(arrow + 1)...].map(clean).filter { !$0.isEmpty }.joined(separator: "\n")
            guard !body.isEmpty, end > start else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: body))
        }
        return SubtitleCues(cues: cues)
    }

    /// `00:01:02,500`, `00:01:02.500`, `01:02.500`.
    static func seconds(_ raw: String) -> Double? {
        let parts = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    private static func clean(_ line: String) -> String {
        var result = line
        for (pattern, replacement) in [("<[^>]*>", ""), ("\\{[^}]*\\}", ""), ("\\\\[Nn]", "\n")] {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        for (entity, character) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
