import Foundation

/// One line of the home page list: a fixed row or a chosen library or collection.
public enum StartEntry: Hashable, Sendable, Identifiable {
    case rail(StartRail)
    /// ``StartLibrary/id``.
    case library(String)

    public var id: String { stored }

    /// **How it is stored**: a fixed row by its raw value (the same strings as `startReihen`),
    /// a library with a prefix, so the two can never collide.
    public var stored: String {
        switch self {
        case .rail(let r): r.rawValue
        case .library(let id): StartOrder.libraryPrefix + id
        }
    }

    public init?(stored: String) {
        if stored.hasPrefix(StartOrder.libraryPrefix) {
            let id = String(stored.dropFirst(StartOrder.libraryPrefix.count))
            guard !id.isEmpty else { return nil }
            self = .library(id)
        } else if let rail = StartRail(rawValue: stored) {
            self = .rail(rail)
        } else {
            return nil
        }
    }
}

/// **Fixed rows and chosen libraries in one order.**
///
/// Before, the libraries and collections always came after the fixed rows: someone who
/// wanted "Anime" above "Neu hinzugefügt" could not have it. Now they share one list.
///
/// **The stored order is a pattern of places, not a third copy of the lists.** Which rows
/// exist and in which order stays in `startReihen` (``StartRailsEpisode``), which libraries
/// in `startBibliotheken` (``StartLibraries``): other platforms, older versions and the
/// settings sync keep reading those two. The pattern only says where a row stands and
/// where a library does; the slots are filled from the two lists in their order. So the
/// three can never disagree, whichever of them changed last: a library removed elsewhere
/// leaves its slot, a library added comes at the end, a reordered row list just fills
/// the row slots in its new order.
public enum StartOrder {
    static let libraryPrefix = "bibliothek:"

    /// The effective list: the stored pattern, its slots filled from `rails` and
    /// `libraries`, then what the pattern does not place yet (rows first, as before).
    /// Without a pattern this is the old page: all rows, then all libraries.
    public static func applicable(stored: [String], rails: [StartRail],
                                  libraries: [StartLibrary]) -> [StartEntry] {
        let railSet = Set(rails)
        let libraryIDs = Set(libraries.map(\.id))
        var seen = Set<StartEntry>()
        // Which slots the pattern keeps: only entries that still exist, each once.
        let pattern = stored.compactMap(StartEntry.init(stored:)).filter { entry in
            switch entry {
            case .rail(let r): railSet.contains(r) && seen.insert(entry).inserted
            case .library(let id): libraryIDs.contains(id) && seen.insert(entry).inserted
            }
        }
        var nextRail = rails.makeIterator()
        var nextLibrary = libraries.lazy.map(\.id).makeIterator()
        var result: [StartEntry] = pattern.map { entry in
            switch entry {
            case .rail: .rail(nextRail.next()!)
            case .library: .library(nextLibrary.next()!)
            }
        }
        while let r = nextRail.next() { result.append(.rail(r)) }
        while let id = nextLibrary.next() { result.append(.library(id)) }
        return result
    }

    /// **What the settings list shows**: every library, and the fixed rows that exist with
    /// the current "Neuzugänge getrennt" (``StartRail/fits(disconnected:)``).
    public static func listed(_ order: [StartEntry], disconnected: Bool) -> [StartEntry] {
        order.filter { entry in
            guard case .rail(let rail) = entry else { return true }
            return rail.fits(disconnected: disconnected)
        }
    }

    /// **What the home page shows**: the listed entries without the switched-off rows.
    public static func shown(_ order: [StartEntry], out: Set<StartRail>, disconnected: Bool) -> [StartEntry] {
        listed(order, disconnected: disconnected).filter { entry in
            guard case .rail(let rail) = entry else { return true }
            return !out.contains(rail)
        }
    }

    /// **One step up or down in the listed order**, for the arrows on TV and in the GTK
    /// list, where nothing is dragged. `nil` at either end.
    public static func shifted(_ entry: StartEntry, by step: Int, in listed: [StartEntry]) -> [StartEntry]? {
        guard let from = listed.firstIndex(of: entry) else { return nil }
        let to = from + step
        guard listed.indices.contains(to) else { return nil }
        var moved = listed
        moved.swapAt(from, to)
        return moved
    }

    /// **After a move in the settings**: the new order split back into the two lists and
    /// the pattern. `hidden` are rows the list did not show (the pair or the combined row
    /// of "Neuzugänge getrennt"); they keep their place at the end, as the old row list
    /// did.
    public static func split(_ order: [StartEntry], hidden: [StartRail] = [],
                             libraries: [StartLibrary])
        -> (stored: [String], rails: [StartRail], libraries: [StartLibrary]) {
        let byID = Dictionary(libraries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let shownRails = order.compactMap { if case .rail(let r) = $0 { r } else { nil } }
        let rails = StartRailsEpisode.clean(shownRails + hidden)
        let chosen = order.compactMap { if case .library(let id) = $0 { byID[id] } else { nil } }
        // A library the order did not mention stays, at the end.
        let rest = libraries.filter { l in !chosen.contains { $0.id == l.id } }
        let all = chosen + rest
        let stored = (order + hidden.map(StartEntry.rail)
                      + rest.map { .library($0.id) }).map(\.stored)
        return (stored, rails, all)
    }
}
