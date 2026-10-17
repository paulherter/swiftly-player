import Foundation

/// **One work, one entry, even if it lives in two libraries.**
///
/// If the same file is in two libraries (e.g. a test or extra library next to the real one,
/// hardlinked), Jellyfin lists two entries with different IDs. The server shares the watch
/// state between them via provider IDs, so both also appear under "Continue Watching".
///
/// Applies to lists **across libraries**: Continue Watching, Next Up, Recently Added,
/// search, watchlist, "All Movies"/"All Series". **Not** within a library page, where what
/// the server returns stays.
///
/// **Same means sharing a provider ID** (TMDb, IMDb, TVDb):
/// - Movie with movie, series with series: by their own IDs.
/// - Episode with episode: same series (by the series' IDs), same season, same episode
///   number.
/// - **Without IDs nothing is merged.** Name and year are no proof; different movies with
///   the same name exist.
///
/// **One** shared ID is enough: if one copy carries TMDb and IMDb and the other only IMDb,
/// they are still the same.
///
/// **Which entry stays** (``rang(_:herkunft:libraries:)``):
/// 1. one from a movie or series library before one from a mixed, home-video or folder
///    library,
/// 2. then the one from the library that comes first in the account's order,
/// 3. then the one with watch state (started, watched, recently played),
/// 4. then the earlier one in the list.
///
/// **The position in the list belongs to the first occurrence**: the winner moves to the
/// place of the copy that came first, so the server's sort order is kept.
public enum Items {

    /// The providers, in order of precedence.
    static let provider = ["Tmdb", "Imdb", "Tvdb"]

    /// Provider IDs of a series, by series ID. An episode does not carry its series' IDs,
    /// only its series ID, and that ID is exactly what differs between libraries.
    public typealias SeriesNumber = [String: [String: String]]

    /// What identifies an entry as a work. Empty: never merge.
    ///
    /// - Parameter folgenJeSerie: An episode counts as its series, for "Recently Added",
    ///   where a series appears once with its newest episode.
    static func traits(_ item: Item, seriesList: SeriesNumber,
                         episodesPerSeries: Bool = false) -> [String] {
        func serialNumbers(_ ids: [String: String]?, _ prefix: String) -> [String] {
            provider.compactMap { a in
                guard let nr = ids?[a]?.trimmingCharacters(in: .whitespaces), !nr.isEmpty
                else { return nil }
                return "\(prefix):\(a.lowercased()):\(nr.lowercased())"
            }
        }
        switch item.type {
        case "Movie":
            return serialNumbers(item.providerIds, "film")
        case "Series":
            return serialNumbers(item.providerIds, "serie")
        case "Episode":
            guard let series = item.seriesId else { return [] }
            if episodesPerSeries { return serialNumbers(seriesList[series], "serie") }
            guard let season = item.parentIndexNumber, let episode = item.indexNumber else { return [] }
            return serialNumbers(seriesList[series], "folge:\(season):\(episode)")
        default:
            return []
        }
    }

    /// **Which entries are the same work**: per group the positions in the list, ascending.
    /// Entries without a duplicate form a group of their own. Groups are ordered by their
    /// first entry.
    public static func groups(_ items: [Item], seriesList: SeriesNumber = [:],
                               episodesPerSeries: Bool = false) -> [[Int]] {
        var parent = Array(items.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        var firstOne: [String: Int] = [:]
        for (i, item) in items.enumerated() {
            for m in traits(item, seriesList: seriesList, episodesPerSeries: episodesPerSeries) {
                if let j = firstOne[m] {
                    let a = root(i), b = root(j)
                    if a != b { parent[max(a, b)] = min(a, b) }
                } else {
                    firstOne[m] = i
                }
            }
        }
        var je: [Int: [Int]] = [:]
        var episode: [Int] = []
        for i in items.indices {
            let w = root(i)
            if je[w] == nil { episode.append(w) }
            je[w, default: []].append(i)
        }
        return episode.map { je[$0]! }
    }

    /// Whether there is anything to merge in the list at all.
    public static func hasDouble(_ items: [Item], seriesList: SeriesNumber = [:],
                                   episodesPerSeries: Bool = false) -> Bool {
        groups(items, seriesList: seriesList, episodesPerSeries: episodesPerSeries).contains { $0.count > 1 }
    }

    /// **Rank of an entry by its library**; smaller is better.
    ///
    /// Unknown origin (a hidden library, or the query failed) goes last.
    static func rank(_ item: Item, origin: [String: String], libraries: [Item]) -> (Int, Int) {
        guard let from = origin[item.id],
              let spot = libraries.firstIndex(where: { $0.id == from })
        else { return (2, Int.max) }
        let art = libraries[spot].collectionType?.lowercased()
        return (art == "movies" || art == "tvshows" ? 0 : 1, spot)
    }

    static func hasStatus(_ item: Item) -> Bool {
        guard let d = item.userData else { return false }
        return (d.playbackPositionTicks ?? 0) > 0 || d.played == true || d.lastPlayedDate != nil
    }

    /// **One entry per work**, at the position of its first occurrence.
    ///
    /// - Parameters:
    ///   - herkunft: Entry ID to its library ID. Only needed for entries that have a
    ///     duplicate.
    ///   - bibliotheken: The account's libraries (`UserViews`), in order.
    ///   - serien: Provider IDs of the series, for episodes.
    public static func merge(_ items: [Item],
                                      origin: [String: String] = [:],
                                      libraries: [Item] = [],
                                      seriesList: SeriesNumber = [:],
                                      episodesPerSeries: Bool = false) -> [Item] {
        groups(items, seriesList: seriesList, episodesPerSeries: episodesPerSeries).map { group in
            let sieger = group.min { a, b in
                let ra = rank(items[a], origin: origin, libraries: libraries)
                let rb = rank(items[b], origin: origin, libraries: libraries)
                if ra != rb { return ra < rb }
                let sa = hasStatus(items[a]), sb = hasStatus(items[b])
                if sa != sb { return sa }
                return a < b
            }!
            return items[sieger]
        }
    }

    /// The entries whose origin matters: all that have a duplicate.
    static func withDouble(_ items: [Item], seriesList: SeriesNumber, episodesPerSeries: Bool) -> [Item] {
        groups(items, seriesList: seriesList, episodesPerSeries: episodesPerSeries)
            .filter { $0.count > 1 }.flatMap { $0.map { items[$0] } }
    }

    /// **Whether episodes with different series IDs could be the same series**, in which
    /// case it is worth fetching the series' IDs. Pre-check by series name; the IDs decide.
    static func seriesSuspicion(_ items: [Item]) -> Set<String> {
        var je: [String: Set<String>] = [:]
        for i in items where i.type == "Episode" {
            guard let id = i.seriesId, let name = i.seriesName else { continue }
            let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                          locale: nil).trimmingCharacters(in: .whitespaces)
            je[key, default: []].insert(id)
        }
        return je.values.filter { $0.count > 1 }.reduce(into: Set()) { $0.formUnion($1) }
    }
}

public extension JellyfinClient {

    /// **One entry per work, with what the rule needs from the server.** See ``Items``.
    ///
    /// Without duplicates this costs no request. With duplicates: once the IDs of the
    /// series involved (episodes only), the account's libraries, and per duplicate its
    /// library. If any of these fails, entries are merged anyway and the earlier one stays.
    func jeItemInTimes(_ items: [Item], episodesPerSeries: Bool = false) async -> [Item] {
        await jeItemInTimes(items, episodesPerSeries: episodesPerSeries, libraries: nil)
    }

    /// As above, but with the account's libraries if the caller already has them
    /// (`model.views`), which saves a round trip per call. With `nil` the function fetches
    /// them itself, only if there are duplicates. If episodes suggest a series match, the
    /// series-ID query and the library query run concurrently.
    func jeItemInTimes(_ items: [Item], episodesPerSeries: Bool = false,
                      libraries available: [Item]?) async -> [Item] {
        let suspicion = Items.seriesSuspicion(items)
        var seriesList: Items.SeriesNumber = [:]
        var libraries = available
        if !suspicion.isEmpty {
            async let fetched = try? identifiers(ids: Array(suspicion))
            let needsViews = libraries == nil
            async let viewList: [Item]? = needsViews ? try? userViews() : nil
            for s in (await fetched) ?? [] { seriesList[s.id] = s.providerIds ?? [:] }
            if needsViews { libraries = await viewList }
        }
        let twice = Items.withDouble(items, seriesList: seriesList, episodesPerSeries: episodesPerSeries)
        guard !twice.isEmpty else { return items }
        if libraries == nil { libraries = (try? await userViews()) ?? [] }
        let viewRef = libraries ?? []
        let origin = await origin(from: twice.map(\.id), under: Set(viewRef.map(\.id)))
        return Items.merge(items, origin: origin, libraries: viewRef,
                                    seriesList: seriesList, episodesPerSeries: episodesPerSeries)
    }

    /// Which library an entry comes from, via its ancestors. The server translates the
    /// library folder into the account's view, the same ID as in `UserViews`.
    func origin(from ids: [String], under libraries: Set<String>) async -> [String: String] {
        guard !libraries.isEmpty else { return [:] }
        return await withTaskGroup(of: (String, String?).self) { group in
            for id in Set(ids) {
                group.addTask {
                    let ancestors = (try? await self.preTravel(from: id)) ?? []
                    return (id, ancestors.first { libraries.contains($0.id) }?.id)
                }
            }
            var je: [String: String] = [:]
            for await (id, from) in group { if let from { je[id] = from } }
            return je
        }
    }

    /// **The watchlist, one entry per work, and still paged.**
    ///
    /// Pages count **works**, not server entries: building `startIndex` from the number of
    /// loaded tiles yields the next page without gaps. For that the whole watchlist is
    /// fetched first in slim form (ID, kind, IDs, same sort order), which decides what
    /// stays; the page itself is then fetched in full by ID.
    func rememberedItems(types: [String], sortBy: String, sortOrder: String,
                       startIndex: Int, limit: Int) async throws -> ItemsResponse {
        try await rememberedItems(types: types, sortBy: sortBy, sortOrder: sortOrder,
                                startIndex: startIndex, limit: limit, libraries: nil)
    }

    /// As above, with the account's already known libraries (saves `UserViews` on every
    /// page once duplicates exist).
    func rememberedItems(types: [String], sortBy: String, sortOrder: String,
                       startIndex: Int, limit: Int,
                       libraries: [Item]?) async throws -> ItemsResponse {
        let all = try await rememberedIds(types: types, sortBy: sortBy, sortOrder: sortOrder)
        let mediaWorks = await jeItemInTimes(all, libraries: libraries)
        let page = Array(mediaWorks.dropFirst(startIndex).prefix(limit))
        guard !page.isEmpty else { return ItemsResponse(items: [], totalRecordCount: mediaWorks.count) }
        let full = try await items(limit: page.count, ids: page.map(\.id))
        return ItemsResponse(items: ListRules.inRailsEpisode(full.items, how: page),
                             totalRecordCount: mediaWorks.count)
    }
}
