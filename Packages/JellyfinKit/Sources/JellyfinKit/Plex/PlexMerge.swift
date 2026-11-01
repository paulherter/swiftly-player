import Foundation

/// **Several libraries as one list.** A server can hold more than one library of a kind
/// ("Serien", "Kids"). Each answers its own sorted run; gluing the runs together puts the
/// whole first library before the second, so months-old Kids titles came first in "newest".
/// The runs are merged by the field they were sorted by instead.
enum PlexMerge {

    /// Newest first across the runs, once per title.
    static func newest(_ runs: [[PlexMetadata]], limit: Int) -> [PlexMetadata] {
        var seen = Set<String>()
        let all = merged(runs, sort: "addedAt:desc").filter { seen.insert($0.ratingKey).inserted }
        return Array(all.prefix(limit))
    }

    /// **Which part of each library's sorted run a page needs.** `totals` are the library
    /// sizes (from a `size=0` request each). An item at place `p` of its run sits at merged
    /// place `p ... p + (items of the other libraries)`, so everything with
    /// `p + others < start` is certainly before the page and need not be fetched; and
    /// nothing at `p >= start + size` can be on it. Items left out are all before `start`,
    /// so the merge of the parts is the full merge minus a prefix of known length
    /// (`skipped`). Libraries with nothing to fetch get an empty range.
    static func window(totals: [Int], start: Int, size: Int) -> (ranges: [Range<Int>], skipped: Int) {
        let all = totals.reduce(0, +)
        var skipped = 0
        let ranges = totals.map { total -> Range<Int> in
            let from = min(total, max(0, start - (all - total)))
            let to = max(from, min(total, start + size))
            skipped += from
            return from..<to
        }
        return (ranges, skipped)
    }

    /// The page `start ..< start + size` of the merged list, from runs that hold only the
    /// parts ``window(totals:start:size:)`` named.
    static func page(_ runs: [[PlexMetadata]], skipped: Int, sort: String?,
                     start: Int, size: Int) -> [PlexMetadata] {
        Array(merged(runs, sort: sort).dropFirst(max(0, start - skipped)).prefix(size))
    }

    /// The runs, each sorted by `sort` (a Plex expression such as `year:desc,titleSort:asc`),
    /// merged into one sorted list. Ties keep the order of the runs. Without a known order
    /// (`random`, none) the runs stay one after the other.
    static func merged(_ runs: [[PlexMetadata]], sort: String?) -> [PlexMetadata] {
        let keys = parse(sort)
        guard !keys.isEmpty else { return runs.flatMap { $0 } }
        var positions = [Int](repeating: 0, count: runs.count)
        var out: [PlexMetadata] = []
        out.reserveCapacity(runs.reduce(0) { $0 + $1.count })
        while true {
            var best: Int?
            for (spot, run) in runs.enumerated() where positions[spot] < run.count {
                if let current = best {
                    if before(run[positions[spot]], runs[current][positions[current]], keys) { best = spot }
                } else {
                    best = spot
                }
            }
            guard let best else { return out }
            out.append(runs[best][positions[best]])
            positions[best] += 1
        }
    }

    private struct Key {
        let field: String
        let descending: Bool
    }

    private static func parse(_ sort: String?) -> [Key] {
        guard let sort, !sort.isEmpty else { return [] }
        var keys: [Key] = []
        for part in sort.split(separator: ",") {
            let pieces = part.split(separator: ":", maxSplits: 1).map(String.init)
            guard let field = pieces.first, field != "random" else { return [] }
            keys.append(Key(field: field, descending: pieces.last?.hasPrefix("desc") == true))
        }
        return keys
    }

    private enum Value: Comparable {
        case number(Double)
        case text(String)
    }

    private static func value(_ m: PlexMetadata, _ field: String) -> Value? {
        switch field {
        case "addedAt": m.addedAt.map { .number(Double($0)) }
        case "year": m.year.map { .number(Double($0)) }
        case "audienceRating": m.audienceRating.map { .number($0) }
        case "rating": m.rating.map { .number($0) }
        case "lastViewedAt": m.lastViewedAt.map { .number(Double($0)) }
        case "originallyAvailableAt": m.originallyAvailableAt.map { .text($0) }
        // `titleSort` is what the server sorted by; the title is its stand-in.
        default: .text((m.titleSort.flatMap { $0.isEmpty ? nil : $0 } ?? m.title).lowercased())
        }
    }

    /// `a` comes strictly before `b`. A missing value goes last in either direction.
    private static func before(_ a: PlexMetadata, _ b: PlexMetadata, _ keys: [Key]) -> Bool {
        for key in keys {
            let x = value(a, key.field), y = value(b, key.field)
            switch (x, y) {
            case (nil, nil): continue
            case (nil, _): return false
            case (_, nil): return true
            case let (x?, y?):
                if x == y { continue }
                return key.descending ? x > y : x < y
            }
        }
        return false
    }
}
