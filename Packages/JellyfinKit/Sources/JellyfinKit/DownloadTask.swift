import Foundation

/// **Which task a callback refers to.**
///
/// A background session reports progress, completion and errors for a *task*,
/// but the app tracks *titles*. As long as only one task ran per title, the
/// title's id was enough. That no longer holds once someone pauses and
/// resumes right away: the old task reports its cancellation only when the new
/// one is already running, and would then set the title to "paused" or "error"
/// although it was downloading.
///
/// Therefore every task carries a **generation**: a number that increments on
/// every start, pause and removal of the title. A callback counts only if its
/// generation is still the current one.
public enum DownloadTask {

    public struct Parts: Equatable, Sendable {
        public let id: String
        /// `0` for a task from a version without generations.
        public let generation: Int
        public let file: String

        public init(id: String, generation: Int, file: String) {
            self.id = id; self.generation = generation; self.file = file
        }
    }

    static let separator = "\u{1F}"

    /// What goes into `taskDescription`: id, generation, file name.
    public static func description(id: String, generation: Int, file: String) -> String {
        [id, String(generation), file].joined(separator: separator)
    }

    /// Back into the parts. The old form `id␟file` gets generation 0.
    public static func dismantle(_ text: String?) -> Parts? {
        let pieces = (text ?? "").components(separatedBy: separator)
        switch pieces.count {
        case 2 where !pieces[0].isEmpty:
            return Parts(id: pieces[0], generation: 0, file: pieces[1])
        case 3... where !pieces[0].isEmpty:
            guard let g = Int(pieces[1]) else {
                // No number field: so it was the old form, and the file name
                // itself contained the separator.
                return Parts(id: pieces[0], generation: 0,
                             file: pieces.dropFirst().joined(separator: separator))
            }
            return Parts(id: pieces[0], generation: g,
                         file: pieces.dropFirst(2).joined(separator: separator))
        default:
            return nil
        }
    }

    /// Whether a callback counts.
    ///
    /// If the app does not know a generation for the title yet (freshly started,
    /// the task kept running in the system), it counts: otherwise a download that
    /// finished in the background would be lost.
    public static func applies(reported: Int, current: Int?) -> Bool {
        guard let current else { return true }
        return reported == current
    }
}
