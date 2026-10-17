import Foundation

/// **The four fetches that make up the home page.**
///
/// A protocol so the loader can be tested without a server. `JellyfinClient` conforms
/// without any change.
public protocol HomePageSource: Sendable {
    func resumeItems(limit: Int) async throws -> [Item]
    func nextUp(limit: Int) async throws -> [Item]
    func lastAdded(in library: String?, fetch: Int, showItem: Int) async -> [Item]?
    func title(genre: String, limit: Int) async -> [Item]?
    /// The account's libraries, or `nil` if the fetch failed.
    func libraries() async -> [Item]?
    /// New additions across all libraries, only of this kind (`Movie`, `Episode`).
    func newArrivals(genre: String, fetch: Int, showItem: Int) async -> [Item]?
    /// The most recently updated **series** themselves (`IncludeItemTypes=Series`);
    /// same query as the series page, independent of library type.
    func newSeries(in library: String?, showItem: Int) async -> [Item]?
    /// The newest titles of **one** library or collection, `nil` if the fetch failed
    /// (also if it no longer exists there).
    func latestTitle(in library: String, collection: Bool, showItem: Int) async -> [Item]?
}

public extension HomePageSource {
    func latestTitle(in library: String, collection: Bool, showItem: Int) async -> [Item]? { nil }
}

extension JellyfinClient: HomePageSource {
    /// The most recently added movies and series of the library (recursive,
    /// without episodes and folders); for a collection, its members.
    public func latestTitle(in library: String, collection: Bool, showItem: Int) async -> [Item]? {
        try? await items(parentID: library, limit: showItem,
                         sortBy: "DateCreated", sortOrder: "Descending",
                         recursive: !collection,
                         includeItemTypes: ["Movie", "Series", "Video"]).items
    }
    public func libraries() async -> [Item]? { try? await userViews() }
    public func lastAdded(in library: String?, fetch: Int, showItem: Int) async -> [Item]? {
        await lastAdded(in: library, fetch: fetch, showItem: showItem, genres: "Movie,Episode")
    }
    public func newArrivals(genre: String, fetch: Int, showItem: Int) async -> [Item]? {
        await lastAdded(in: nil, fetch: fetch, showItem: showItem, genres: genre)
    }
    /// Like the series page: `/Items`, `Series` only, recursive, by the time of the
    /// latest new episode.
    public func newSeries(in library: String?, showItem: Int) async -> [Item]? {
        try? await items(parentID: library, limit: showItem,
                         sortBy: "DateLastContentAdded", sortOrder: "Descending",
                         recursive: true, includeItemTypes: ["Series"]).items
    }
}

/// **What is on the home page, ready before any UI sees it.**
///
/// `nil` means “the fetch failed”, not “empty”. The UI then keeps the old state,
/// except after an account switch; that decision stays with the UI because only it
/// knows the old state.
public struct Home: Sendable {
    public struct GenreRail: Sendable, Identifiable {
        public let name: String
        public let items: [Item]
        public var id: String { name }
    }

    /// A chosen library or collection as a row.
    public struct LibraryRail: Sendable, Identifiable {
        public let id: String
        public let name: String
        public let items: [Item]
    }

    public let continueWatching: [Item]?
    public let nextEpisode: [Item]?
    /// The shared new-additions row, only if not split.
    public let recent: [Item]?
    public let newMovies: [Item]?
    public let newSeries: [Item]?
    public let genreRails: [GenreRail]
    /// Nothing arrived: no continue watching, no next up, no new items.
    public let disrupted: Bool
}

/// **One rule for all platforms.**
///
/// This used to exist twice: in `HomeModel.load` (iOS, tvOS, macOS) and in
/// `homeLoad` of the GTK version, and had already diverged. Linux did not remove
/// titles in “continue watching” from “next up” and knew no “disturbed” state; Apple
/// kept duplicates in genre rows. The more correct variant now applies everywhere.
/// Android gets the same rule through `SwiftlyCore`.
public enum HomeLoader {

    public struct LoadRequest: Sendable {
        public var disconnected: Bool
        public var filmLibrary: String?
        public var seriesLibrary: String?
        /// `nil` if genres are shown as chips on top; then there are no rows.
        public var genres: [String]?
        /// What was last in “continue watching”. If the new fetch fails,
        /// “next up” filters against this state.
        public var untilFromContinueWatching: [Item]

        public init(disconnected: Bool, filmLibrary: String? = nil, seriesLibrary: String? = nil,
                    genres: [String]? = nil, untilFromContinueWatching: [Item] = []) {
            self.disconnected = disconnected
            self.filmLibrary = filmLibrary
            self.seriesLibrary = seriesLibrary
            self.genres = genres
            self.untilFromContinueWatching = untilFromContinueWatching
        }
    }

    /// **The genre rows on their own.** Apple shows the fixed rows immediately and the
    /// genres afterwards; fetching both at once makes the fixed rows wait for the slowest
    /// genre fetch. In the chosen order, empty ones drop out, without duplicates.
    ///
    /// **All genres at once, not one after the other.** Sequentially, the last row took
    /// as many round trips as genres chosen; now all together take as long as the slowest.
    /// The order comes from `names`, not from arrival.
    public static func genreRails(from source: some HomePageSource,
                                      names: [String]) async -> [Home.GenreRail] {
        let fetched = await withTaskGroup(of: (Int, [Item]?).self) { group in
            for (i, name) in names.enumerated() {
                group.addTask { (i, await source.title(genre: name, limit: 24)) }
            }
            var je: [Int: [Item]] = [:]
            for await (i, title) in group { if let title { je[i] = title } }
            return je
        }
        return names.indices.compactMap { i in
            guard let title = fetched[i], !title.isEmpty else { return nil }
            return .init(name: names[i], items: ListRules.withoutDouble(title))
        }
    }

    /// **The chosen libraries as rows, all at once, not one after the other.**
    ///
    /// In the chosen order. A row whose fetch fails (library deleted, not accessible to the
    /// profile) or that is empty drops out silently; the choice itself stays untouched.
    /// Whatever is already in “New movies” and the like changes nothing, since the row shows
    /// its own library.
    public static func libraryRails(from source: some HomePageSource,
                                         choice: [StartLibrary]) async -> [Home.LibraryRail] {
        let choice = StartLibraries.clean(choice)
        let fetched = await withTaskGroup(of: (Int, [Item]?).self) { group in
            for (i, w) in choice.enumerated() {
                group.addTask { (i, await source.latestTitle(in: w.id, collection: w.collection, showItem: 24)) }
            }
            var je: [Int: [Item]] = [:]
            for await (i, title) in group { if let title { je[i] = title } }
            return je
        }
        return choice.indices.compactMap { i in
            guard let title = fetched[i], !title.isEmpty else { return nil }
            return .init(id: choice[i].id, name: choice[i].name,
                         items: ListRules.withoutDouble(title))
        }
    }

    /// **A split new-additions row: the library first, never silently empty.**
    ///
    /// Without `ParentId` the server returns the new additions of **all** libraries, so
    /// “New series” showed the same movies as “New movies”. So the row first asks in the
    /// chosen library, and with no choice in every library of the kind (the first one
    /// with new additions counts, like `AppModel.selectedLibrary(art:)`).
    ///
    /// **If nothing is found there, it falls back to the query without `ParentId`**, in
    /// two steps:
    ///
    /// 1. Only the kind of the row (`Movie` or `Episode`) across all libraries. Before, the
    ///    mixed list (movies and episodes) was fetched and filtered afterwards; after many
    ///    new movies there were no episodes among the first titles, and “New series”
    ///    stayed empty.
    /// 2. If that returns nothing too, exactly the older query: without `ParentId`, movies
    ///    and episodes mixed. This covers libraries where the server does not recognise
    ///    episodes (mixed type); they show what they showed before instead of the row
    ///    disappearing.
    ///
    /// This applies to servers whose libraries have no type or a mixed type, whose library
    /// list is unreadable, or whose chosen library is empty. Previously the row then stayed
    /// empty and vanished from the home page without a hint. Cause and case are written to
    /// the log.
    static func new(from source: some HomePageSource, in library: String?,
                    art: String) async -> [Item]? {
        // **The same in reverse:** in the movie row, episodes and series that the mixed
        // fallback brings along drop out.
        guard art == "tvshows" else {
            let fetched = await newLevels(from: source, in: library, art: art)
            guard art == "movies" else { return fetched }
            return fetched?.filter { !["Episode", "Series", "Season"].contains($0.type ?? "") }
        }
        // **The series row asks for series, not libraries.**
        // If a user's series are not cleanly in libraries of type “tvshows”, the last
        // fallback (mixed, as before) ran and showed movies. The main path is now the series
        // page query; the chosen library only counts as long as it returns something.
        // Whatever is still a movie afterwards drops out.
        if let library, let fetched = await source.newSeries(in: library, showItem: 24), !fetched.isEmpty {
            return fetched
        }
        let seriesList = await source.newSeries(in: nil, showItem: 24)
        if let seriesList, !seriesList.isEmpty {
            LogRing.shared.append("Startseite: Neu tvshows: Serien-Abfrage (Series, DateLastContentAdded), \(seriesList.count) Titel")
            return seriesList
        }
        let rung = seriesList == nil ? "kam nicht durch" : "leer"
        let rest = await newLevels(from: source, in: library, art: art)?.filter { $0.type != "Movie" }
        LogRing.shared.append("Startseite: Neu tvshows: Serien-Abfrage \(rung); Rueckfall ueber Bibliotheken/Folgen ohne Filme: \(rest.map { "\($0.count) Titel" } ?? "kam nicht durch")")
        return rest
    }

    private static func newLevels(from source: some HomePageSource, in library: String?,
                                  art: String) async -> [Item]? {
        let reason: String
        if let library {
            let fetched = await source.lastAdded(in: library, fetch: 200, showItem: 24)
            if let fetched, !fetched.isEmpty { return fetched }
            reason = fetched == nil ? "Abruf der gewaehlten Bibliothek kam nicht durch"
                                  : "gewaehlte Bibliothek ohne Neuzugaenge"
        } else if let all = await source.libraries() {
            let matches = all.filter { $0.collectionType?.lowercased() == art }
            var empty = 0
            for candidate in matches {
                if let fetched = await source.lastAdded(in: candidate.id, fetch: 200, showItem: 24) {
                    if !fetched.isEmpty { return fetched }
                    empty += 1
                }
            }
            if matches.isEmpty {
                let kinds = all.map { $0.collectionType ?? "ohne" }.joined(separator: ",")
                reason = "keine Bibliothek der Art (\(all.count) Bibliotheken: \(kinds))"
            } else {
                reason = "\(matches.count) Bibliothek(en) der Art, \(empty) leer, Rest nicht erreichbar"
            }
        } else {
            reason = "Bibliotheksliste nicht lesbar"
        }
        let genre = art == "movies" ? "Movie" : "Episode"
        let onlyGenre = await source.newArrivals(genre: genre, fetch: 200, showItem: 24)
        if let onlyGenre, !onlyGenre.isEmpty {
            LogRing.shared.append("Startseite: Neu \(art): \(reason); Rueckfall ohne Bibliothek (\(genre)), \(onlyGenre.count) Titel")
            return onlyGenre
        }
        let mixed = await source.lastAdded(in: nil, fetch: 200, showItem: 24)
        let level1 = onlyGenre == nil ? "kam nicht durch" : "leer"
        LogRing.shared.append("Startseite: Neu \(art): \(reason); Rueckfall \(genre) \(level1); gemischt wie 1.0.4: \(mixed.map { "\($0.count) Titel" } ?? "kam nicht durch")")
        return mixed ?? onlyGenre
    }

    public static func load(from source: some HomePageSource, _ wish: LoadRequest) async -> Home {
        async let begun = try? source.resumeItems(limit: 20)
        async let next = try? source.nextUp(limit: 20)
        async let gemeinsam = wish.disconnected ? nil
            : source.lastAdded(in: nil, fetch: 200, showItem: 24)
        async let movies = wish.disconnected
            ? new(from: source, in: wish.filmLibrary, art: "movies") : nil
        async let seriesList = wish.disconnected
            ? new(from: source, in: wish.seriesLibrary, art: "tvshows") : nil

        let a = await begun
        let alreadyPresent = Set((a ?? wish.untilFromContinueWatching).map(\.id))
        let b = await next.map { $0.filter { !alreadyPresent.contains($0.id) } }
        let c = await gemeinsam
        let d = await movies
        let e = await seriesList

        let rails = await genreRails(from: source, names: wish.genres ?? [])

        let newPresent = wish.disconnected ? (d != nil || e != nil) : c != nil
        return Home(
            continueWatching: a.map(ListRules.withoutDouble),
            nextEpisode: b.map(ListRules.withoutDouble),
            recent: c.map(ListRules.withoutDouble),
            newMovies: d.map(ListRules.withoutDouble),
            newSeries: e.map(ListRules.withoutDouble),
            genreRails: rails,
            disrupted: a == nil && b == nil && !newPresent)
    }
}
