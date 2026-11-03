import Foundation
import JellyfinKit

/// The words under a "Gesehen von" avatar, shared by all four Apple platforms so the
/// label reads the same everywhere: "2 × · gestern".
extension Watcher {
    var caption: String {
        var parts: [String] = []
        if playCount > 1 { parts.append("\(playCount) ×") }
        if let w = watchedCount, let t = totalCount, t > 0, w < t {
            parts.append(String(format: String(localized: "%lld von %lld Folgen"), w, t))
        } else if ring > 0, ring < 1, let p = progressPercent {
            parts.append("\(Int(p.rounded())) %")
        }
        if let lastWatched {
            let f = RelativeDateTimeFormatter()
            f.dateTimeStyle = .named
            f.unitsStyle = .full
            parts.append(f.localizedString(for: lastWatched, relativeTo: Date()))
        }
        return parts.joined(separator: " · ")
    }

    /// For VoiceOver and tooltips: the name, then the caption.
    var spoken: String { caption.isEmpty ? name : "\(name), \(caption)" }

    var initial: String { name.first.map { String($0).uppercased() } ?? "?" }
}
