import Foundation

/// Offline playback the server has not seen yet, merged into the unsent-stops store (`pending.reports`).
///
/// The core decides what is unreported (`DownloadsModel.unreportedProgressJson`, called after a
/// `ServerFollow`) and how a report is stored (`legacyPendingReportRecord`: one per title and account,
/// the newer wins). The host only carries the JSON; sending stays with `pendingSubmit`.
public enum PendingProgress {

    /// The store after every entry of `unreportedJson` went through the core's record rule.
    /// `nil` when there is nothing to add (the store stays as it is).
    public static func merged(unreportedJson: String, into store: Data?) -> Data? {
        guard let raw = unreportedJson.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: raw) as? [Any], !list.isEmpty
        else { return nil }
        var text = store.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        for entry in list {
            guard let one = try? JSONSerialization.data(withJSONObject: entry),
                  let message = String(data: one, encoding: .utf8) else { continue }
            text = legacyPendingReportRecord(store: text, message: message)
        }
        return text.data(using: .utf8)
    }
}
