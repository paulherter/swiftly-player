import Foundation

/// Rules for lists that go into a view.
///
/// **Why this lives in the package and not in the view.** A list with a duplicate ID is not
/// cosmetic: `ForEach` matches rows by ID, and with two equal IDs a tap lands on the wrong
/// row (on "Recently Added", tapping one series opened the one after next).
///
/// The library and the watchlist built this rule themselves because the server can add
/// items between two pages. The home page did not have it: each row comes from a single
/// fetch, assuming one fetch returns nothing twice. A server with a messed-up library does
/// exactly that.
public enum ListRules {

    /// Each ID exactly once, in the order of first occurrence.
    ///
    /// The order is the point: the server returned it sorted, and the later copy is the
    /// straggler, not the original.
    public static func withoutDouble(_ items: [Item]) -> [Item] {
        var watched = Set<String>()
        return items.filter { watched.insert($0.id).inserted }
    }

    /// **One title, one row, even if it lives in two libraries.**
    ///
    /// For "Recently Added". A series appears once with its newest episode, a movie on its
    /// own; the order of the response is kept.
    ///
    /// **The ID is not enough.** If the same movie or series is in two libraries (e.g. a
    /// kids library next to the main one, hardlinks to the same files), Jellyfin creates
    /// two entries with **different** IDs, and for episodes different `SeriesId`s too.
    /// `Items/Latest` returned the same pairs, so it was not caused by the choice of
    /// endpoint. Merging by `seriesId ?? id` left both in place.
    ///
    /// So merge by what makes up the title:
    /// - **Movie:** TMDb, else IMDb ID, else name and year.
    /// - **Episode:** the series name. An episode does not carry its series' provider IDs,
    ///   only its name and ID, and the ID is exactly what differs between libraries. Two
    ///   different series with the same name would merge; in a row of recent additions that
    ///   is the smaller error.
    /// - **Everything else:** the ID.
    public static func jeTitleInTimes(_ items: [Item], showItem: Int) -> [Item] {
        var watched = Set<String>()
        var result: [Item] = []
        for entryRecord in items where result.count < showItem {
            guard watched.insert(titleKey(entryRecord)).inserted else { continue }
            result.append(entryRecord)
        }
        return result
    }

    /// The first episode per series ID; all movies stay, in list order.
    static func jeSeriesInTimes(_ items: [Item]) -> [Item] {
        var watched = Set<String>()
        return items.filter { i in
            guard i.type == "Episode", let series = i.seriesId else { return true }
            return watched.insert(series).inserted
        }
    }

    /// **The full entries in the order of the slim ones.**
    ///
    /// A fetch by `Ids` sorts by its own rule, not by the list. Anything the server dropped
    /// in between is omitted.
    public static func inRailsEpisode(_ full: [Item], how preStatus: [Item]) -> [Item] {
        let je = Dictionary(full.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return preStatus.compactMap { je[$0.id] }
    }

    static func titleKey(_ item: Item) -> String {
        func folded(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .trimmingCharacters(in: .whitespaces)
        }
        switch item.type {
        case "Movie":
            if let tmdb = item.providerIds?["Tmdb"], !tmdb.isEmpty { return "film:tmdb:\(tmdb)" }
            if let imdb = item.providerIds?["Imdb"], !imdb.isEmpty { return "film:imdb:\(imdb)" }
            return "film:\(folded(item.name)):\(item.productionYear.map(String.init) ?? "")"
        case "Series":
            // **For "All Series".** The same series in two series libraries has two IDs but
            // the same provider IDs. Without an ID, the name; the same key as for their
            // episodes.
            for provider in ["Tmdb", "Tvdb", "Imdb"] {
                if let nr = item.providerIds?[provider], !nr.isEmpty {
                    return "serie:\(provider.lowercased()):\(nr)"
                }
            }
            return "serie:\(folded(item.name))"
        case "Episode":
            if let series = item.seriesName, !series.isEmpty { return "serie:\(folded(series))" }
            return "serie:id:\(item.seriesId ?? item.id)"
        default:
            return "id:\(item.id)"
        }
    }

    /// The same rule for appending: what is already there is not added again.
    public static func append(_ newOne: [Item], an bestehende: [Item]) -> [Item] {
        var watched = Set(bestehende.map(\.id))
        return bestehende + newOne.filter { watched.insert($0.id).inserted }
    }

    // MARK: Loading more

    /// Whether there is more beyond what is already there.
    public static func stillMorePresent(loaded: Int, total: Int) -> Bool {
        loaded < total
    }

    /// **From which entry loading more starts: the third-to-last row.**
    ///
    /// The next page should be there before anyone reaches the bottom. Two rows would be
    /// too late when dragging fast, four loads too early and fetches pages nobody looks at.
    ///
    /// `nil` means there is nothing the trigger could attach to.
    ///
    /// **Why this lives here and not in the view.** The rule was duplicated word for word
    /// in `LibraryModel` and `WatchlistModel`. Two copies of the same number drift
    /// apart as soon as someone touches one.
    ///
    /// **Every tile of the last three rows triggers, not exactly one.** Loading used to
    /// hang on the `onAppear` of a single tile. If its trigger fired into the void (the
    /// list had just been cut back to the first page on returning from a detail page, or
    /// loading failed), it did not appear again in the `LazyVGrid` while it stayed on
    /// screen. On Apple TV a large library stopped after about fifty titles until one
    /// scrolled far up and down again. `loadsPost` absorbs repeated triggers.
    public static func postLoadSection(_ id: String, in items: [Item], columns: Int) -> Bool {
        items.suffix(max(1, 3 * columns)).contains { $0.id == id }
    }

    /// **The first page is reloaded; further pages stay.**
    ///
    /// A view reloads whenever it appears, including on returning from a detail page. If
    /// the first page replaced everything, only sixty titles would be left: someone at the
    /// hundredth would lose their title, focus would jump elsewhere, and the load-more
    /// trigger would already be on screen.
    ///
    /// If the total count changed, something was added or removed and everything behind
    /// would shift, so replace after all.
    public static func refresh(_ first: [Item], in bestehende: [Item],
                                   totalBefore: Int, totalNow: Int) -> [Item] {
        guard totalBefore == totalNow, bestehende.count > first.count
        else { return withoutDouble(first) }
        return append(Array(bestehende.dropFirst(first.count)), an: withoutDouble(first))
    }
}

public extension JellyfinClient {

    /// **What was added most recently, one row per series.**
    ///
    /// **Not Jellyfin's own grouping.** `GroupItems=true` on `Items/Latest` merges, but
    /// returns so few entries that the row looks almost empty: of twenty requested titles
    /// four remained, without the season. So fetch **ungrouped and generously**, then merge
    /// ourselves: a series appears once with its newest episode, a movie on its own.
    ///
    /// The fetch uses ``newlyJoined(parentID:limit:)``, not `Items/Latest`, which hid
    /// watched items. The reasons are documented there.
    ///
    /// **Two hundred fetched, twenty-four shown**: the surplus covers the case where a
    /// single series fills half the response. Because watched items are now part of the
    /// supply, a much-watched series eats it up. Measured on a test library (283 episodes):
    /// supply 60 gives 9 rows, 120 gives 13, **200 gives 16**, 300 gives 18. The old way
    /// gave 16. Two hundred holds that level, three hundred only costs bytes.
    ///
    /// **Two requests instead of one, and that is faster.** The supply is fetched slim (ID,
    /// name, series, provider IDs); only the twenty-four that stay are fetched in full with
    /// description, images and state. Before, all two hundred carried their description:
    /// **457 KB** for one row, uncompressed, for 16 tiles.
    func lastAdded(in library: String? = nil,
                             fetch: Int = 200, showItem: Int = 24,
                             genres: String = "Movie,Episode") async -> [Item]? {
        guard let raw = try? await newlyJoined(parentID: library, limit: fetch,
                                                   slim: true, genres: genres)
        else { return nil }
        // **Across all libraries: first one per work** (``Items``), so that of two copies
        // the one from the real library stays, not the one scanned last.
        let preOff = library == nil
            ? await jeItemInTimes(ListRules.jeSeriesInTimes(raw), episodesPerSeries: true)
            : raw
        let selected = ListRules.jeTitleInTimes(preOff, showItem: showItem)
        guard !selected.isEmpty else { return [] }
        guard let full = try? await items(limit: selected.count, ids: selected.map(\.id))
        else { return nil }
        return ListRules.inRailsEpisode(full.items, how: selected)
    }
}
