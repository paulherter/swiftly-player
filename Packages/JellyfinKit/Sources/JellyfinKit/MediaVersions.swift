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
