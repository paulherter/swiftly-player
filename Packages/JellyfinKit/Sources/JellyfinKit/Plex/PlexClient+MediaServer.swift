import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// **`PlexClient` as a ``MediaServer``.**
///
/// The app asks the protocol, never the class. Where Plex has no counterpart the method
/// gives the neutral answer (an empty list, `nil`, no change) or throws
/// ``PlexError/unsupported``; the capability is missing from ``PlexFeatures`` then, so the
/// app does not offer it. `QuickSignIn`, `RemoteSessionServer` and `DisplayPreferencesServer`
/// are not adopted at all: for the app `as?` is `nil`, which hides those screens.
///
/// `PLEX-KERN.md` has the table of which method answers which requirement.
extension PlexClient: MediaServer {

    public nonisolated var kind: ServerKind { .plex }

    // MARK: - Account and connection

    /// What ``MediaServerFactory`` calls: the device facts become Plex's headers, the
    /// session (if any) the account.
    static func make(session: Session?, baseURL: URL, deviceID: String, deviceName: String,
                     clientVersion: String, program: String, urlSession: URLSession) -> PlexClient {
        #if os(iOS)
        let platform = "iOS"
        #elseif os(tvOS)
        let platform = "tvOS"
        #elseif os(macOS)
        let platform = "macOS"
        #elseif os(Windows)
        let platform = "Windows"
        #elseif os(Android)
        let platform = "Android"
        #else
        let platform = "Linux"
        #endif
        let identity = PlexIdentity(clientID: deviceID, product: program, version: clientVersion,
                                    platform: platform, device: platform, deviceName: deviceName)
        if let session { return PlexClient(session: session, identity: identity, urlSession: urlSession) }
        return PlexClient(baseURL: baseURL, token: "", identity: identity, urlSession: urlSession)
    }

    /// A client for the same server without an account: adding another account must not
    /// touch the signed-in one.
    public nonisolated func signedOutCopy() -> any MediaServer {
        PlexClient(baseURL: route.base, token: "", identity: identity, urlSession: session)
    }

    public func publicSystemInfo() async throws -> PublicSystemInfo {
        let found = try await info()
        return PublicSystemInfo(serverName: details?.serverName, version: found.version,
                                id: found.machineIdentifier)
    }

    public func checkReachability() async throws -> PublicSystemInfo {
        try await publicSystemInfo()
    }

    /// Plex has no sign-in with a name and password at the server; the account signs in at
    /// plex.tv (``PlexAccountService``).
    public func authenticate(username: String, password: String) async throws -> Session {
        throw PlexError.unsupported
    }

    public func signOff() async { forgetAccount() }

    /// `false` only for `401`; a network error means "unknown", and signing someone out for
    /// that would be wrong.
    public func sessionAppliesStill() async -> Bool {
        (try? await tokenWorks()) ?? true
    }

    /// Plex has no transcoding for us, so no download quality to offer; downloads are the
    /// original file.
    public func accountDefaults() async -> AccountPreGift? {
        AccountPreGift(nextEpisodeAutomatic: nil, downloadsAllowed: nil,
                       convertAllowed: false, audioConvertAllowed: false)
    }

    // MARK: - Libraries and lists

    public func userViews(hidden: Bool = false) async throws -> [Item] { try await views() }

    /// A page of titles.
    ///
    /// `parentID` is a library (a number from `/library/sections`) or a collection; without
    /// it, all film and series libraries one after the other. Jellyfin's words
    /// (`SortName`, `IsFavorite` …) are turned into Plex's here, so the callers stay the same.
    public func items(parentID: String? = nil, limit: Int = 100, startIndex: Int = 0,
                      sortBy: String = "SortName", sortOrder: String = "Ascending",
                      filters: [String] = [], isWatched: Bool? = nil, recursive: Bool = false,
                      includeItemTypes: [String] = [], ids: [String] = [], personIDs: [String] = [],
                      genres: [String] = [], slim: Bool = false) async throws -> ItemsResponse {
        if !ids.isEmpty { return try await itemsByID(ids) }

        var query: [(String, String)] = [("sort", Self.sortExpression(sortBy, sortOrder))]
        if filters.contains("IsResumable") { query.append(("inProgress", "1")) }
        if filters.contains("IsFavorite") { query.append(("userRating>>", "9")) }
        if let isWatched { query.append(("unwatched", isWatched ? "0" : "1")) }
        if !personIDs.isEmpty { query.append(("actor", personIDs.joined(separator: ","))) }

        if let parentID {
            switch try await parent(parentID, recursive: recursive) {
            case .section(let section):
                return try await page(of: [section], types: includeItemTypes, query: query,
                                      genres: genres, start: startIndex, size: limit)
            case .children(let id):
                let all = try await children(id)
                return Self.slice(all, start: startIndex, size: limit, types: includeItemTypes)
            case .collection(let id):
                let all = try await collectionItems(id)
                return Self.slice(all, start: startIndex, size: limit, types: includeItemTypes)
            }
        }
        let all = try await sections().filter { ["movie", "show"].contains($0.type) }
        return try await page(of: all, types: includeItemTypes, query: query, genres: genres,
                              start: startIndex, size: limit)
    }

    public func genres() async throws -> [String] {
        var names = Set<String>()
        for section in try await sections() where ["movie", "show"].contains(section.type) {
            names.formUnion(try await genres(section: section.key).map(\.title))
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public func resumeItems(limit: Int = 20) async throws -> [Item] {
        try await continueWatching(limit: limit)
    }

    public func nextUp(limit: Int = 20) async throws -> [Item] {
        try await onDeck(limit: limit)
    }

    /// New additions, newest first. Each kind is asked for separately and the answers are
    /// woven together: one question for "films and episodes" would bring seasons instead of
    /// episodes.
    public func lastAdded(in library: String? = nil, fetch: Int = 200, showItem: Int = 24,
                          genres: String = "Movie,Episode") async -> [Item]? {
        let kinds = genres.split(separator: ",").map(String.init)
        // Asked per library: measured, the unscoped list ignores `type` (and the home hub
        // answers nothing for episodes), so it would bring seasons instead of episodes.
        guard let all = try? await sections() else { return nil }
        var rows: [[PlexMetadata]] = []
        for kind in kinds {
            guard let number = PlexMapper.plexTypeNumber(forItemType: kind) else { continue }
            let wanted = kind == "Movie" ? "movie" : "show"
            for section in all where section.type == wanted && (library == nil || section.key == library) {
                guard let answer = try? await listing(
                    "/library/sections/\(section.key)/recentlyAdded", [("type", String(number))],
                    start: 0, size: min(fetch, showItem * 2))
                else { return nil }
                rows.append(answer.metadata.filter { PlexMapper.itemType($0.type) == kind })
            }
        }
        return PlexMerge.newest(rows, limit: showItem).map(mapper.item)
    }

    public func lastAdded(in library: String?, fetch: Int, showItem: Int) async -> [Item]? {
        await lastAdded(in: library, fetch: fetch, showItem: showItem, genres: "Movie,Episode")
    }

    public nonisolated var mergesLibraries: Bool { true }

    public func newArrivals(genre: String, fetch: Int, showItem: Int) async -> [Item]? {
        await lastAdded(in: nil, fetch: fetch, showItem: showItem, genres: genre)
    }

    /// The series themselves, newest first, like the series page.
    public func newSeries(in library: String?, showItem: Int) async -> [Item]? {
        await newest(in: library, shows: true, size: showItem)
    }

    public func latestTitle(in library: String, collection: Bool, showItem: Int) async -> [Item]? {
        if collection { return try? await collectionItems(library).prefix(showItem).map { $0 } }
        return await newest(in: library, shows: nil, size: showItem)
    }

    public func libraries() async -> [Item]? { try? await views() }

    public func playlistEntries(_ playlist: String, lean: Bool = false) async throws -> [Item] {
        try await playlistItems(playlist).filter(VideoPlaylist.isVideoEntry)
    }

    public func playlistDirectory() async throws -> PlaylistDirectory {
        let found = try await playlists().filter(VideoPlaylist.isVideo)
        var members: [String: [Item]] = [:]
        try await withThrowingTaskGroup(of: (String, [Item]).self) { group in
            for list in found {
                group.addTask { (list.id, try await self.playlistEntries(list.id)) }
            }
            for try await (id, entries) in group { members[id] = entries }
        }
        return PlaylistDirectory(found.map { VideoPlaylist(item: $0, members: members[$0.id] ?? []) })
    }

    public func collectionDirectory(viewList: [Item] = []) async throws -> CollectionDirectory {
        let known = try await sections().filter { ["movie", "show"].contains($0.type) }
        let wanted = viewList.isEmpty ? known : known.filter { s in viewList.contains { $0.id == s.key } }
        var found: [Item] = []
        for section in wanted { found += try await collections(section: section.key) }
        var members: [String: [Item]] = [:]
        try await withThrowingTaskGroup(of: (String, [Item]).self) { group in
            for collection in found {
                group.addTask { (collection.id, try await self.collectionItems(collection.id)) }
            }
            for try await (id, entries) in group { members[id] = entries }
        }
        return CollectionDirectory(found.map { ItemCollection(item: $0, members: members[$0.id] ?? []) })
    }

    /// A Plex library holds one kind (films or series), never both.
    public func libraryShares(views: [Item]) async -> [String: LibraryShare] { [:] }

    /// "All" across libraries: the ids of every chosen library, in the account's order, so
    /// each work stays once (``TitleFilter``).
    public func titleFilter(_ source: ShelfSource, filters: [String] = [],
                            isWatched: Bool? = nil) async throws -> TitleFilter {
        let types = source.types
        var libraries: [(library: String, identifiers: [Item])] = []
        for id in source.onlyOut {
            let all = try await items(parentID: id, limit: 100_000, filters: filters,
                                      isWatched: isWatched, recursive: true,
                                      includeItemTypes: types, slim: true).items
            libraries.append((id, all))
        }
        return TitleFilter(je: libraries)
    }

    public func naturalList(parentID: String?, sortOrder: String, filters: [String],
                            isWatched: Bool?, recursive: Bool,
                            includeItemTypes: [String]) async throws -> [Item] {
        let answer = try await items(parentID: parentID, limit: 100_000, sortBy: Sorting.name.inputField,
                                     sortOrder: sortOrder, filters: filters, isWatched: isWatched,
                                     recursive: recursive, includeItemTypes: includeItemTypes,
                                     slim: true)
        return NaturalOrder.sorted(answer.items) { ($0.name, $0.sortName) }
    }

    public func naturalPage(_ list: [Item], since: Int, count: Int) async throws -> ItemsResponse {
        let slice = Array(list.dropFirst(since).prefix(count))
        guard !slice.isEmpty else { return ItemsResponse(items: [], totalRecordCount: list.count) }
        let fetched = try await itemsByID(slice.map(\.id)).items
        let byID = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ItemsResponse(items: slice.compactMap { byID[$0.id] }, totalRecordCount: list.count)
    }

    /// The watchlist: what is rated as a favourite, once per work, paged.
    public func rememberedItems(types: [String], sortBy: String, sortOrder: String, startIndex: Int,
                                limit: Int, libraries: [Item]? = nil) async throws -> ItemsResponse {
        try await items(limit: limit, startIndex: startIndex, sortBy: sortBy, sortOrder: sortOrder,
                        filters: ["IsFavorite"], recursive: true, includeItemTypes: types)
    }

    public func title(person id: String, limit: Int = 60) async -> [Item]? {
        await titleWithNumber(person: id, limit: limit, startIndex: 0)?.items
    }

    public func title(genre: String, limit: Int = 24) async -> [Item]? {
        await titleWithNumber(genre: genre, limit: limit, startIndex: 0)?.items
    }

    public func titleWithNumber(person id: String, limit: Int = 60,
                                startIndex: Int = 0) async -> (items: [Item], total: Int)? {
        guard let answer = try? await items(limit: limit, startIndex: startIndex,
                                            sortBy: "ProductionYear,SortName", sortOrder: "Descending",
                                            recursive: true, includeItemTypes: ["Movie", "Series"],
                                            personIDs: [id])
        else { return nil }
        return (answer.items, answer.totalRecordCount)
    }

    public func titleWithNumber(genre: String, limit: Int = 24,
                                startIndex: Int = 0) async -> (items: [Item], total: Int)? {
        guard let answer = try? await items(limit: limit, startIndex: startIndex,
                                            sortBy: "DateCreated", sortOrder: "Descending",
                                            recursive: true, includeItemTypes: ["Movie", "Series"],
                                            genres: [genre])
        else { return nil }
        return (answer.items, answer.totalRecordCount)
    }

    // MARK: - Details

    public func item(id: String) async throws -> Item { try await item(id) }

    public func similar(itemID: String, toward preStatus: Item? = nil,
                        limit: Int = 12) async throws -> [Item] {
        try await similar(itemID, limit: limit).filter { $0.id != itemID }
    }

    /// Extras the server keeps as files (featurettes, scenes); trailers are kept apart.
    public func extras(itemID: String) async throws -> [Item] {
        try await clips(itemID).filter { $0.subtype != "trailer" }.map { mapper.item($0) }
    }

    /// Trailers that exist as a file on the server, like Jellyfin's local trailers.
    public func trailer(toward itemID: String) async throws -> [Item] {
        try await clips(itemID).filter { $0.subtype == "trailer" }.map { mapper.item($0) }
    }

    /// The episode to watch next: the one after the last watched; `nil` if nothing in the
    /// series was watched yet or it is finished (as on Jellyfin).
    public func nextEpisodeSeries(seriesID: String) async throws -> Item? {
        let all = try await episodes(seriesID: seriesID, seasonID: nil)
        guard let last = all.lastIndex(where: { $0.userData?.played == true }),
              all.indices.contains(last + 1) else { return nil }
        return all[last + 1]
    }

    public func episodePost(itemID: String, seriesID: String) async throws -> Item? {
        let all = try await episodes(seriesID: seriesID, seasonID: nil)
        guard let now = all.firstIndex(where: { $0.id == itemID }),
              all.indices.contains(now + 1) else { return nil }
        return all[now + 1]
    }

    public func stateInSeries(_ seriesID: String) async -> Item? {
        try? await stateInSeriesChecked(seriesID)
    }

    public func stateInSeriesChecked(_ seriesID: String) async throws -> Item? {
        if let next = try await nextEpisodeSeries(seriesID: seriesID) { return next }
        return try await episodes(seriesID: seriesID, seasonID: nil).first
    }

    public func metadataRefresh(_ itemID: String) async throws {
        try await command("PUT", "/library/metadata/\(itemID)/refresh", [])
    }

    public func setWatchlist(itemID: String, an: Bool) async throws {
        try await setFavorite(itemID, an)
    }

    public func setWatched(itemID: String, an: Bool) async throws {
        try await setWatched(itemID, an)
    }

    /// Takes the title out of "Continue watching". The watched mark stays as it was.
    public func pointBackSet(itemID: String) async throws {
        try await command("PUT", "/actions/removeFromContinueWatching", [("ratingKey", itemID)])
    }

    /// Offline reconciliation reads the server's own user data as Jellyfin writes it; Plex
    /// has no such document.
    #if DEBUG
    public func userDataRaw(itemID: String) async throws -> Data { throw PlexError.unsupported }
    public func userDataBackPut(itemID: String, raw: Data) async throws { throw PlexError.unsupported }
    #endif

    // MARK: - Images

    public func imageURL(for item: Item, maxHeight: Int = 480) async -> URL? {
        imageURL(for: item, kind: .poster, maxHeight: maxHeight, maxWidth: nil)
    }

    // MARK: - Playback

    public func playbackPlan(for itemID: String, profile: DeviceProfile = .vlc(),
                             audioStreamIndex: Int? = nil, subtitleStreamIndex: Int? = nil,
                             mediaSourceID: String? = nil) async throws -> PlaybackPlan? {
        try await plan(for: itemID, mediaSourceID: mediaSourceID,
                       audioStreamID: audioStreamIndex, subtitleStreamID: subtitleStreamIndex)
    }

    public func airplayPlan(for itemID: String, source: MediaSource) async throws -> AirPlayInfo {
        let suitability = AirPlaySuitability.check(source: source)
        guard suitability.fitting else { return .goesNot(suitability) }
        return .goes(try await plan(for: itemID, mediaSourceID: source.id))
    }

    /// **Plex has no remux here.** AVPlayer can open the original file only if the container
    /// is one it knows; Matroska stays with VLC.
    public func avPlayerPlan(for itemID: String, source: MediaSource, audioIndex: Int?,
                             av1: Bool) async throws -> PlaybackPlan? {
        let containers: Set<String> = ["mp4", "m4v", "mov"]
        let own = Set((source.container ?? "").lowercased().split(separator: ",").map(String.init))
        guard !own.isEmpty, own.isSubset(of: containers) else { return nil }
        return try await plan(for: itemID, mediaSourceID: source.id)
    }

    /// The original file; Plex has no quality levels here.
    public func downloadURL(itemID: String, mediaSourceID: String?, quality: DownloadQuality,
                            audioStreamIndex: Int? = nil) async throws -> URL {
        try await downloadURL(itemID, mediaSourceID: mediaSourceID)
    }

    public func sections(for itemID: String) async -> [Segment] {
        (try? await segments(itemID)) ?? []
    }

    public func segmentsToStore(for itemID: String) async -> [Segment]? {
        try? await segments(itemID)
    }

    /// Plex's preview pictures are single images, not tile sheets: the "grid" is 1 by 1
    /// and a "sheet" is the picture with that number.
    public func trickplay(itemID: String, mediaSourceID: String?, target: Int = 320) async -> Trickplay? {
        guard let bif = try? await previews(itemID, mediaSourceID: mediaSourceID),
              let size = bif.pictureSize, bif.interval > 0 else { return nil }
        return Trickplay(width: size.width, height: size.height, tilesWide: 1, tilesUp: 1,
                         count: bif.frames.count, interval: bif.interval)
    }

    public func trickplaySheet(itemID: String, mediaSourceID: String?, width: Int,
                               sheet: Int) async -> Data? {
        guard let bif = try? await previews(itemID, mediaSourceID: mediaSourceID) else { return nil }
        return bif.image(at: sheet)
    }

    public func chapter(itemID: String, mediaSourceID: String?) async -> [Chapter] {
        (try? await chapters(itemID)) ?? []
    }

    // MARK: - Reports

    public func reportStart(itemID: String, plan: PlaybackPlan, ticks: Int64 = 0,
                            tracks: TrackIndices = .init()) async throws {
        try await reportTimeline(itemID, state: .playing, positionTicks: ticks,
                                 durationMilliseconds: Self.milliseconds(of: plan))
    }

    public func reportProgress(itemID: String, plan: PlaybackPlan, positionTicks: Int64,
                               paused: Bool, tracks: TrackIndices = .init()) async throws {
        try await reportTimeline(itemID, state: paused ? .paused : .playing,
                                 positionTicks: positionTicks,
                                 durationMilliseconds: Self.milliseconds(of: plan))
    }

    public func reportStopped(itemID: String, plan: PlaybackPlan, positionTicks: Int64) async throws {
        try await reportTimeline(itemID, state: .stopped, positionTicks: positionTicks,
                                 durationMilliseconds: Self.milliseconds(of: plan))
    }

    /// Positions made offline. A title that is gone is settled; a position older than the
    /// server's own last play is dropped (the newer state wins). Stops at the first error.
    public func reportLater(_ opened: [PendingReport],
                            log: @Sendable (String) -> Void = { _ in }) async -> [String] {
        var completed: [String] = []
        for report in opened {
            do {
                let detail = try await detail(report.itemID)
                let last = detail.item.userData?.lastPlayedDate.flatMap {
                    ISO8601DateFormatter().date(from: $0)
                }
                if PostReportRules.dispatch(report, serverLast: last) {
                    try await reportTimeline(report.itemID, state: .stopped,
                                             positionTicks: report.ticks,
                                             durationMilliseconds: detail.metadata.duration)
                }
                log("[Melden] Nachmeldung \(report.itemID) \(report.ticks / 10_000_000) s")
                completed.append(report.id)
            } catch JellyfinError.http(status: 404, _) {
                completed.append(report.id)
            } catch {
                log("[Melden] Nachmeldung \(report.itemID) gescheitert, bleibt liegen")
                break
            }
        }
        return completed
    }
}

// MARK: - Helpers

extension PlexClient {

    enum Parent {
        case section(PlexSection)
        case collection(String)
        case children(String)
    }

    /// What an id from the app names. Library numbers and `ratingKey`s are both small
    /// numbers, so a collection page (which never asks recursively) is checked on the server
    /// when the number is also a library's.
    func parent(_ id: String, recursive: Bool) async throws -> Parent {
        let known = try await sections()
        let section = known.first { $0.key == id }
        if let section, recursive { return .section(section) }
        var kind = parentKinds[id]
        if kind == nil {
            // A failed look-up is not remembered; an answer is.
            if let found = try? await listing("/library/metadata/\(id)").metadata.first {
                kind = found.type ?? ""
                parentKinds[id] = kind
            }
        }
        switch kind {
        case "collection": return .collection(id)
        case "show", "season": return .children(id)
        default:
            if let section { return .section(section) }
            return .collection(id)
        }
    }

    /// One page across the libraries, **merged by the sort field**: Kids (old) and Serien
    /// (new) are one list in the order asked for, not two lists glued together. Each library
    /// answers its own sorted run; only the part of each run that can reach
    /// `start ..< start + size` is fetched (``PlexMerge/window(totals:start:size:)``).
    func page(of sections: [PlexSection], types: [String], query: [(String, String)],
              genres: [String], start: Int, size: Int) async throws -> ItemsResponse {
        var planned: [(path: String, query: [(String, String)])] = []
        for section in sections {
            guard let q = try await sectionQuery(section, types: types, query: query, genres: genres)
            else { continue }
            planned.append(("/library/sections/\(section.key)/all", q))
        }
        guard !planned.isEmpty else { return ItemsResponse(items: [], totalRecordCount: 0) }

        if planned.count == 1 {
            let answer = try await listing(planned[0].path, planned[0].query, start: start, size: size)
            return ItemsResponse(items: items(of: answer), totalRecordCount: answer.totalSize ?? answer.size)
        }
        // Count every library first (no items), then fetch only the part of each sorted run
        // that can reach the page (``PlexMerge/window(totals:start:size:)``).
        let totals = try await withThrowingTaskGroup(of: (Int, Int).self) { group in
            for (spot, plan) in planned.enumerated() {
                group.addTask {
                    let answer = try await self.listing(plan.path, plan.query, start: 0, size: 0)
                    return (spot, answer.totalSize ?? answer.size)
                }
            }
            var result = [Int](repeating: 0, count: planned.count)
            for try await (spot, count) in group { result[spot] = count }
            return result
        }
        let (ranges, skipped) = PlexMerge.window(totals: totals, start: start, size: size)
        let runs = try await withThrowingTaskGroup(of: (Int, [PlexMetadata]).self) { group in
            for (spot, plan) in planned.enumerated() where !ranges[spot].isEmpty {
                let range = ranges[spot]
                group.addTask {
                    (spot, try await self.listing(plan.path, plan.query,
                                                  start: range.lowerBound, size: range.count).metadata)
                }
            }
            var result = [[PlexMetadata]](repeating: [], count: planned.count)
            for try await (spot, run) in group { result[spot] = run }
            return result
        }
        let order = query.first { $0.0 == "sort" }?.1
        let page = PlexMerge.page(runs, skipped: skipped, sort: order, start: start, size: size)
        return ItemsResponse(items: page.map(mapper.item), totalRecordCount: totals.reduce(0, +))
    }

    /// The query for one library, or `nil` if nothing asked for can be in it (films in a
    /// series library, a genre it does not have).
    func sectionQuery(_ section: PlexSection, types: [String], query: [(String, String)],
                      genres: [String]) async throws -> [(String, String)]? {
        var q = query
        let own = section.type == "movie" ? ["Movie"] : ["Series", "Season", "Episode"]
        if !types.isEmpty {
            let fitting = types.filter { own.contains($0) }
            if fitting.isEmpty, types.contains(where: { PlexMapper.plexTypeNumber(forItemType: $0) != nil }) {
                return nil
            }
            // One asked-for kind is a type filter; several (or none we know) mean the
            // library's own kind.
            if fitting.count == 1, let number = PlexMapper.plexTypeNumber(forItemType: fitting[0]) {
                q.append(("type", String(number)))
            }
        }
        if !genres.isEmpty {
            let offered = try await self.genres(section: section.key)
            let keys = genres.compactMap { name in
                offered.first { $0.title.caseInsensitiveCompare(name) == .orderedSame }?.key
            }
            guard !keys.isEmpty else { return nil }
            q.append(("genre", keys.joined(separator: ",")))
        }
        return q
    }

    /// Titles by id, in batches (the address holds the ids).
    func itemsByID(_ ids: [String]) async throws -> ItemsResponse {
        var all: [Item] = []
        for start in stride(from: 0, to: ids.count, by: 100) {
            let batch = ids[start..<min(start + 100, ids.count)].joined(separator: ",")
            all += items(of: try await listing("/library/metadata/\(batch)"))
        }
        return ItemsResponse(items: all, totalRecordCount: all.count)
    }

    /// The newest titles of one library or of all of one kind.
    func newest(in library: String?, shows: Bool?, size: Int) async -> [Item]? {
        guard let all = try? await sections() else { return nil }
        let chosen = all.filter {
            if let library { return $0.key == library }
            guard let shows else { return ["movie", "show"].contains($0.type) }
            return $0.type == (shows ? "show" : "movie")
        }
        // All libraries at once; `rows` keeps the library order, so the result does not
        // depend on which answer comes first.
        let rows: [[PlexMetadata]]? = await withTaskGroup(of: (Int, [PlexMetadata]?).self) { group in
            for (spot, section) in chosen.enumerated() {
                group.addTask {
                    let answer = try? await self.listing("/library/sections/\(section.key)/all",
                                                         [("sort", "addedAt:desc")], start: 0, size: size)
                    return (spot, answer?.metadata)
                }
            }
            var result = [[PlexMetadata]](repeating: [], count: chosen.count)
            var failed = false
            for await (spot, run) in group {
                if let run { result[spot] = run } else { failed = true }
            }
            return failed ? nil : result
        }
        guard let rows else { return nil }
        return PlexMerge.newest(rows, limit: size).map(mapper.item)
    }

    static func slice(_ all: [Item], start: Int, size: Int, types: [String]) -> ItemsResponse {
        let kept = types.isEmpty ? all : all.filter { $0.type.map(types.contains) ?? false || $0.type == "Video" }
        return ItemsResponse(items: Array(kept.dropFirst(start).prefix(size)), totalRecordCount: kept.count)
    }

    /// Jellyfin's `SortBy`/`SortOrder` as a Plex `sort`: `year:desc,titleSort:desc`.
    static func sortExpression(_ sortBy: String, _ sortOrder: String) -> String {
        let direction = sortOrder.lowercased().hasPrefix("desc") ? "desc" : "asc"
        return sortBy.split(separator: ",").map { field -> String in
            let name: String
            switch field {
            case "DateCreated", "DateLastContentAdded": name = "addedAt"
            case "CommunityRating": name = "audienceRating"
            case "PremiereDate": name = "originallyAvailableAt"
            case "ProductionYear": name = "year"
            case "Random": return "random"
            default: name = "titleSort"
            }
            return name + ":" + direction
        }.joined(separator: ",")
    }

    static func milliseconds(of plan: PlaybackPlan) -> Int? {
        plan.source?.runTimeTicks.map { Int($0 / 10_000) }
    }
}
