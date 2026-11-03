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

    /// How much of the ring is drawn, 0...1: a series by episodes, otherwise by progress; a
    /// title that was watched at least once without a progress value is a full ring.
    public var ring: Double {
        if let w = watchedCount, let t = totalCount, t > 0 { return min(max(Double(w) / Double(t), 0), 1) }
        if let p = progressPercent { return min(max(p / 100, 0), 1) }
        return playCount > 0 ? 1 : 0
    }
}

public extension MediaServer {
    /// `nil`: no such plugin (or no answer). Not `[]`, which means "plugin there, nobody yet".
    func watchers(itemID: String) async -> [Watcher]? { nil }
}
