import Foundation

/// **Who has watched a title** (the Jelly Twiggy plugin, `GET /JellyTwiggy/Items/{id}/Watchers`).
///
/// Only a server with the plugin answers; every other server gives `nil` from
/// ``MediaServer/watchers(itemID:)`` and the feature stays out of sight completely
/// (no section, no setting, no further requests once the answer is known).
public struct Watcher: Sendable, Equatable, Identifiable, Decodable {
    public var id: String { userID }
    public let userID: String
    public let name: String
    public let imageTag: String?
    public let playCount: Int
    public let lastWatched: Date?
    /// 0...100 for a film that was started; `nil` when the plugin gives none.
    public let progressPercent: Double?
    /// Series and seasons: "7 of 10 episodes".
    public let watchedCount: Int?
    public let totalCount: Int?

    enum CodingKeys: String, CodingKey {
        case userID = "UserId", name = "UserName", imageTag = "ImageTag", playCount = "PlayCount"
        case lastWatched = "LastWatched", progressPercent = "ProgressPercent"
        case watchedCount = "WatchedCount", totalCount = "TotalCount"
    }

    public init(userID: String, name: String, imageTag: String?, playCount: Int, lastWatched: Date?,
                progressPercent: Double?, watchedCount: Int?, totalCount: Int?) {
        self.userID = userID
        self.name = name
        self.imageTag = imageTag
        self.playCount = playCount
        self.lastWatched = lastWatched
        self.progressPercent = progressPercent
        self.watchedCount = watchedCount
        self.totalCount = totalCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = try c.decode(String.self, forKey: .userID)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        imageTag = try? c.decodeIfPresent(String.self, forKey: .imageTag)
        playCount = (try? c.decode(Int.self, forKey: .playCount)) ?? 0
        lastWatched = try? c.decodeIfPresent(Date.self, forKey: .lastWatched)
        progressPercent = try? c.decodeIfPresent(Double.self, forKey: .progressPercent)
        watchedCount = try? c.decodeIfPresent(Int.self, forKey: .watchedCount)
        totalCount = try? c.decodeIfPresent(Int.self, forKey: .totalCount)
    }

    /// **How much of the ring is drawn, 0...1.** A series or season by its episodes. A film
    /// watched to the end at least once is a full ring, also while it is being watched again:
    /// the ring says "has seen it", the caption says how often. Only a film nobody finished
    /// shows how far it got.
    public var ring: Double {
        if let w = watchedCount, let t = totalCount, t > 0 { return min(max(Double(w) / Double(t), 0), 1) }
        if playCount > 0 { return 1 }
        if let p = progressPercent { return min(max(p / 100, 0), 1) }
        return 0
    }

    /// **The words beside an avatar, the same on every platform**: "2 × · yesterday".
    ///
    /// How often only from the second time on (once is what the ring already says); for a
    /// series how many episodes, as long as not all; for an unfinished film how far; then
    /// when it was last watched. Parts without data drop out, so the line can be empty.
    public func caption(now: Date = Date(), calendar: Calendar = .current) -> String {
        var parts: [String] = []
        if playCount > 1 { parts.append("\(playCount) ×") }
        if let w = watchedCount, let t = totalCount, t > 0, w < t {
            parts.append(translated("Folgen: \(w) von \(t)"))
        } else if watchedCount == nil, playCount == 0, let p = progressPercent, p > 0, p < 100 {
            parts.append("\(Int(p.rounded())) %")
        }
        if let lastWatched {
            parts.append(Self.day(of: lastWatched, now: now, calendar: calendar))
        }
        return parts.joined(separator: " · ")
    }

    /// Name and caption as one line, for VoiceOver, a tooltip or the TV's focus line.
    public func spoken(now: Date = Date(), calendar: Calendar = .current) -> String {
        let label = caption(now: now, calendar: calendar)
        let shown = name.isEmpty ? "?" : name
        return label.isEmpty ? shown : "\(shown), \(label)"
    }

    /// The letter on an avatar without a picture.
    public var initial: String { name.first.map { String($0).uppercased() } ?? "?" }

    /// **"Today", "yesterday", "3 days ago", then the date.** Counted in calendar days, so a
    /// title watched late last night reads "yesterday" this morning.
    static func day(of date: Date, now: Date, calendar: Calendar) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return translated("heute")
        case 1: return translated("gestern")
        case 2..<7: return translated("vor \(days) Tagen")
        default:
            let f = DateFormatter()
            f.calendar = calendar
            f.dateStyle = .medium
            f.timeStyle = .none
            return f.string(from: date)
        }
    }
}

public extension MediaServer {
    /// `nil`: no such plugin (or no answer). Not `[]`, which means "plugin there, nobody yet".
    func watchers(itemID: String) async -> [Watcher]? { nil }
}
