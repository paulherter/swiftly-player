import Foundation

/// The one combined order of the Home rows (fixed rows, libraries and collections in the SAME list),
/// decided by the core (`homeRowOrder`, `homeRowOrderMoved`). The host stores the list per server under
/// `startReihenfolge` (device only, not synced) and hands it to `HomeModel`.
public enum HomeRowOrder {
    /// The id of a library or collection row.
    public static func libraryId(_ id: String) -> String { "library:" + id }

    /// The library id of a row id, or `nil` for a fixed row.
    public static func library(of row: String) -> String? {
        row.hasPrefix("library:") ? String(row.dropFirst("library:".count)) : nil
    }

    /// The effective list: `stored` healed against the rows that exist. Without a stored list the user's
    /// earlier order of the fixed rows (`fallbackFixed`, raw values) comes first, then the libraries.
    public static func effective(
        stored: [String], fallbackFixed: [String], disconnected: Bool, libraries: [HomeLibraryChoice]
    ) -> [String] {
        homeRowOrder(stored: stored.isEmpty ? fallbackFixed : stored, disconnected: disconnected, libraries: libraries)
    }

    /// A SwiftUI `onMove` (`source`, `destination` = insertion index in the list before the move) applied to
    /// one row. Several rows at once are moved one after the other.
    public static func moved(_ list: [String], from source: IndexSet, to destination: Int) -> [String] {
        var out = list
        var target = destination
        for index in source.sorted() {
            let to = index < target ? target - 1 : target
            out = homeRowOrderMoved(list: out, from: UInt32(index), to: UInt32(to))
            if index >= target { target += 1 }
        }
        return out
    }

    /// A drop on a row: `row` takes the place of `target` (the rows between shift by one).
    public static func moved(_ list: [String], row: String, onto target: String) -> [String] {
        guard row != target, let from = list.firstIndex(of: row), let to = list.firstIndex(of: target) else { return list }
        return moved(list, from: IndexSet(integer: from), to: from < to ? to + 1 : to)
    }

    /// Move Up / Move Down (`delta` -1 / +1) among the rows in `visible` (rows hidden right now keep their
    /// place): `row` swaps with its visible neighbour. At the ends nothing changes.
    public static func moved(_ list: [String], row: String, by delta: Int, among visible: [String]) -> [String] {
        guard let at = visible.firstIndex(of: row), visible.indices.contains(at + delta) else { return list }
        return moved(list, row: row, onto: visible[at + delta])
    }
}
