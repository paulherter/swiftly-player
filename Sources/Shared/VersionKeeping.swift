import Foundation
import JellyfinKit
import func SwiftlyCore.matchingNextVersion

/// **The version to keep for the next episode, decided by the core** (`matchingNextVersion`, the Rust port of
/// `MediaVersions.matching`): the one named like the one playing (trimmed, case-insensitive), else the one with
/// the same resolution, else `nil` and the server's automatic pick applies.
enum VersionKeeping {
    /// The `Id` of the version to keep, or `nil`.
    static func matching(previous: MediaSource, in next: [MediaSource]?) -> String? {
        let encoder = JSONEncoder()
        guard let previousJSON = try? encoder.encode(previous), let nextJSON = try? encoder.encode(next ?? []),
              let answer = matchingNextVersion(
                previousJson: String(decoding: previousJSON, as: UTF8.self),
                nextJson: String(decoding: nextJSON, as: UTF8.self)),
              let object = try? JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any]
        else { return nil }
        return object["Id"] as? String
    }
}
