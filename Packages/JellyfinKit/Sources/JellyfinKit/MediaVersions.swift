import Foundation

/// **Several versions of one title.** Jellyfin lists 4K next to 1080p or the
/// theatrical cut next to the extended one as separate sources of the same item.
/// The play button offers the choice only when there is one to make.
public enum MediaVersions {

    /// The sources worth choosing between: more than one, each with an id.
    /// Fewer than two means no choice, so the play button starts right away.
    public static func choices(_ sources: [MediaSource]?) -> [MediaSource] {
        let usable = (sources ?? []).filter { $0.id != nil }
        return usable.count > 1 ? usable : []
    }

    /// **What a start does about versions.** The key point is `nil`: list
    /// entries leave `MediaSources` out on purpose, so `nil` means "not loaded
    /// yet" and not "only one version". Reading it as "no choice" started the
    /// default version before the full title had arrived.
    ///
    /// - sources: the title's `mediaSources`; `nil` while it is a list entry.
    /// - downloaded: a copy is on the device; that file plays, nothing to choose.
    public static func start(_ sources: [MediaSource]?, downloaded: Bool) -> VersionStart {
        if downloaded { return .play }
        guard let sources else { return .wait }
        let offered = choices(sources)
        return offered.isEmpty ? .play : .choose(offered)
    }

    /// **The version to keep for the next episode.** The one with the same name,
    /// otherwise the one with the same resolution; `nil` if neither exists, and
    /// the automatic pick applies as before.
    public static func matching(previous: MediaSource, in next: [MediaSource]?) -> MediaSource? {
        let usable = (next ?? []).filter { $0.id != nil }
        guard usable.count > 1 else { return nil }
        if let name = previous.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
           let same = usable.first(where: {
               $0.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                   .caseInsensitiveCompare(name) == .orderedSame
           }) {
            return same
        }
        if let height = previous.height, height > 0 {
            return usable.first { $0.height == height }
        }
        return nil
    }
}

/// The answer of ``MediaVersions/start(_:downloaded:)``.
public enum VersionStart: Equatable, Sendable {
    /// `MediaSources` not loaded yet: the play button waits.
    case wait
    /// One version, or the copy on the device: start it.
    case play
    /// Several versions: ask "Fassung wählen".
    case choose([MediaSource])
}

public extension MediaSource {

    /// The name the server gives this version; without one a plain placeholder.
    var versionName: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? translated("Fassung") : trimmed
    }

    /// What tells two versions apart at a glance: "2160p · HEVC · 18,6 GB".
    var versionDetail: String {
        var parts: [String] = []
        if let height, height > 0 { parts.append("\(height)p") }
        if let codec = videoCodec, !codec.isEmpty { parts.append(codec.uppercased()) }
        if let size, size > 0 { parts.append(DownloadRules.size(size)) }
        return parts.joined(separator: " · ")
    }
}
