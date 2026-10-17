import Foundation

/// How a title is labelled, **once, for all five platforms.**
///
/// It first lived in the view files, then in `Sources/Shared/TitleDetails.swift`. That
/// was right as long as all platforms were SwiftUI; the Linux version cannot reach
/// `Sources/Shared` and would have had to copy. That is exactly how the line once
/// drifted apart: on tvOS series showed “0 Min.” because the check `seconds > 0`
/// was missing there.
///
/// **What is here is translated**, via ``translated(_:)`` with the package bundle.
/// Linux has no text catalogs; there the German wording comes out, because it is also
/// the key. That is a deliberate fallback, not an oversight.

/// “2 Std. 8 Min.” or “94 Min.”
public func runtime(_ seconds: Double) -> String {
    let m = Int(capped: seconds / 60)
    return m >= 60 ? translated("\(m / 60) Std. \(m % 60) Min.")
                   : translated("\(m) Min.")
}

/// “1:23 h” or “42 min”, for the resume button.
///
/// Without translation: “h” and “min” are the same in both languages.
public func timeText(_ seconds: Double) -> String {
    let total = Int(capped: seconds)
    let (h, m) = (total / 3600, (total % 3600) / 60)
    return h > 0 ? "\(h):\(String(format: "%02d", m)) h" : "\(m) min"
}

/// “7,8” instead of “7.8”: Jellyfin delivers a dot, German writes a comma.
public func comma(_ value: Double) -> String {
    String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
}

extension Item {

    /// Year, runtime and genre in one line.
    ///
    /// Series have no runtime of their own; the server delivers 0 there, and without the
    /// check “0 Min.” would appear in the line.
    public var secondaryLine: String {
        var parts: [String] = []
        if let year = productionYear { parts.append(String(year)) }
        if let seconds = runtimeSeconds, seconds > 0 { parts.append(runtime(seconds)) }
        if let genres, !genres.isEmpty {
            parts.append(genres.prefix(2).joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    /// The second from which playback resumes, or nothing.
    ///
    /// The rule itself lives in ``ResumePoint``, with both limits and tests. It once
    /// stood here half-done: under a minute from the start, but with no limit at the end;
    /// a finished episode thereby returned its own end as the resume point and jumped on
    /// when opened.
    public var resumeFrom: Double? {
        ResumePoint.since(position: userData?.playbackPositionTicks.map { Double($0) / 10_000_000 },
                          runtime: runTimeTicks.map { Double($0) / 10_000_000 })
    }
}

public extension Item {

    /// The line under a search hit: “Furious · S1 E4 · 52 Min.”
    ///
    /// **Lived in `Sources/Shared` and was unreachable for Linux.** There only the year
    /// stood under a search hit; the same information, halved. Exactly the kind of drift
    /// nobody reports, because both sides look plausible on their own.
    ///
    /// During the first move it turned out that the kind “Film” was appended as a **plain
    /// string** while “Serie” and “Folge” next to it were translated. In English it said
    /// “Film” instead of “Movie”.
    var hitInfo: String {
        var parts: [String] = []
        switch type {
        case "Movie":   parts.append(translated("Film"))
        case "Series":  parts.append(translated("Serie"))
        case "Episode": parts.append(seriesName ?? translated("Folge"))
        default: break
        }
        if let abbreviation = episodeCode { parts.append(abbreviation) }
        if let year = productionYear, type != "Episode" { parts.append(String(year)) }
        if let count = childCount, type == "Series" {
            parts.append(translated("\(count) Staffeln"))
        }
        if let s = runtimeSeconds, type != "Series" { parts.append(runtime(s)) }
        return parts.joined(separator: " · ")
    }

    /// “12 minutes left”, or `nil` if nothing worth mentioning is missing.
    ///
    /// Once existed twice and was **not** the same: once “Noch 12 Minuten”, once “Noch 12
    /// min”. Worse, the second version was a plain string and never went through
    /// translation.
    var remainingTimeText: String? {
        guard let total = runtimeSeconds, total > 0, let since = resumeFrom else { return nil }
        return translated("Noch \(Int(capped: (total - since) / 60)) Minuten")
    }

    /// **The line under a continue-watching tile**: “S2 · F5 · noch 12 Min.” for an
    /// episode, “2019 · noch 1 Std. 4 Min.” for a film (the year from `contextLine`), or
    /// `nil` if there is no state (then the usual line stays).
    ///
    /// Answers the question one has before tapping: how much is left. The picture stays
    /// free; the information sits where the abbreviation stood anyway.
    var continueWatchingRow: String? {
        guard let total = runtimeSeconds, total > 0, let since = resumeFrom else { return nil }
        let (hours, minutes) = RemainingTime.parts(seconds: total - since)
        let rest: String
        if hours == 0 {
            rest = translated("noch \(minutes) Min.")
        } else if minutes == 0 {
            rest = translated("noch \(hours) Std.")
        } else {
            rest = translated("noch \(hours) Std. \(minutes) Min.")
        }
        guard type == "Episode", let season = parentIndexNumber, let episode = indexNumber else {
            if type == "Movie", let year = contextLine { return year + " · " + rest }
            return rest
        }
        return translated("S\(season) · F\(episode)") + " · " + rest
    }

    /// Label of the main button on a series page.
    ///
    /// **Used to exist three times.** iOS and tvOS each had it on their own: the same four
    /// cases, character for character.
    ///
    /// `episode` is the next episode to play, `loads` whether the season is still being
    /// fetched. Without an episode and without loading there is nothing to play.
    static func seriesButton(episode: Item?, loads: Bool) -> String {
        // **Two separate calls, no question mark in the argument.** Nothing can be extracted
        // from a computed key; the text would stay in the source language.
        guard let episode else {
            return loads ? translated("Lädt…") : translated("Keine Folgen")
        }
        let abbreviation = episode.episodeCode ?? episode.name
        let begun = (episode.userData?.playbackPositionTicks ?? 0) > 0
        return begun ? translated("Fortsetzen \(abbreviation)")
                          : translated("Abspielen \(abbreviation)")
    }
}


/// **Remaining time in hours and minutes**, rounded for display.
///
/// Rounded up to the minute: an episode with 40 seconds left has “1 min left”, not
/// “0 min left”, since zero would mean “done”, and that is not true.
public enum RemainingTime {
    public static func parts(seconds: Double) -> (hours: Int, minutes: Int) {
        guard seconds.isFinite, seconds > 0 else { return (0, 1) }
        let whole = max(Int(capped: (seconds / 60).rounded(.up)), 1)
        return (whole / 60, whole % 60)
    }
}
