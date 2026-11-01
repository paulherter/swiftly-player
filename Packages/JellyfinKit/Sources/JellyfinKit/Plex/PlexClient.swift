import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What `/identity` says about a server. Needs no sign-in, so it also answers "is this
/// the server I mean" before a token is spent.
public struct PlexServerInfo: Sendable, Equatable {
    public let machineIdentifier: String
    public let version: String?
    /// Whether an account owns the server yet (`claimed`).
    public let claimed: Bool
}

/// A page of a list, already mapped.
public struct PlexPage: Sendable, Equatable {
    public let items: [Item]
    /// How many entries the whole list has (`totalSize`).
    public let total: Int
    public let start: Int
}

/// A title with everything the detail page and the player need.
public struct PlexDetail: Sendable, Equatable {
    public let item: Item
    public let metadata: PlexMetadata
    public let segments: [Segment]
    public let chapters: [Chapter]
}

/// The address and token a client is using right now. Read from outside the actor (image
/// and file addresses are built without a hop), changed only by ``PlexClient``.
final class PlexRoute: @unchecked Sendable {
    private let lock = NSLock()
    private var current: (base: URL, token: String)

    init(base: URL, token: String) { current = (base, token) }

    var base: URL { lock.lock(); defer { lock.unlock() }; return current.base }
    var token: String { lock.lock(); defer { lock.unlock() }; return current.token }
    var playback: PlexPlayback {
        lock.lock(); defer { lock.unlock() }
        return PlexPlayback(base: current.base, token: current.token)
    }
    func set(base: URL, token: String) {
        lock.lock(); defer { lock.unlock() }
        current = (base, token)
    }
    func clearToken() {
        lock.lock(); defer { lock.unlock() }
        current.token = ""
    }
}

/// What asking plex.tv again found: the address to use and the token for it.
public struct PlexResolvedRoute: Sendable, Equatable {
    public let connection: PlexChosenConnection
    public let token: String

    public init(connection: PlexChosenConnection, token: String) {
        self.connection = connection; self.token = token
    }
}

/// **A Plex Media Server, as the app talks to it.**
///
/// Bound to the ``MediaServer`` protocol in `PlexClient+MediaServer.swift`; `PLEX-KERN.md`
/// lists which method answers which requirement. Everything that comes out is already an
/// ``Item``, ``PlaybackPlan``, ``Segment`` or ``Chapter``.
///
/// **The address can change under the client.** A Plex server is reachable by several
/// addresses and which one works depends on where the device is. When a request does not
/// get through (no route, timeout, certificate, gateway error) and the client knows the
/// account (``PlexSessionDetails``), it asks plex.tv for the addresses again, takes the
/// best one that answers (``PlexConnector``), and repeats the request once. Calls that run
/// at the same time share one such search. The app is told through
/// ``onSessionChange(_:)`` so it can keep the new address.
public actor PlexClient {

    public typealias Resolver = @Sendable (PlexSessionDetails) async throws -> PlexResolvedRoute

    public nonisolated let identity: PlexIdentity
    public nonisolated let capabilities = PlexFeatures.capabilities
    /// One value per client, so the server can tell this play session from another one
    /// of the same account.
    public nonisolated let sessionID = UUID().uuidString
    /// The address in use. Changes when the client switches (see above).
    public nonisolated var baseURL: URL { route.base }
    /// The token in use. Read together with ``baseURL`` for image and file addresses, so
    /// they follow the client when it moves to another address.
    public nonisolated var accessToken: String { route.token }

    nonisolated let route: PlexRoute
    let session: URLSession
    private nonisolated var playback: PlexPlayback { route.playback }
    let mapper = PlexMapper()
    var machineKey: String { details?.machineIdentifier ?? route.base.absoluteString }

    // The account, if the client was built from a session.
    private var user: (id: String, name: String)?
    private(set) var details: PlexSessionDetails?
    private let resolver: Resolver?
    private var switching: Task<Void, any Error>?
    /// Whether the address in use has answered since the client was built (or was just
    /// chosen by a probe). A stored address is not trusted until then.
    private var routeConfirmed = false
    private var routeObserver: (@Sendable (Session) -> Void)?
    private var unauthorizedObserver: (@Sendable () -> Void)?
    /// Set once the observer has been told, so a check that itself gets a `401` does not
    /// call it again.
    private var unauthorizedTold = false
    /// The last preview file, so scrubbing does not fetch it for every picture.
    var previewCache: (key: String, bif: PlexBIF?)?
    /// The kind (`collection`, `show`, …) the server named for an id, so paging through a
    /// collection or a series does not look it up again for every page.
    var parentKinds: [String: String] = [:]

    /// A client for an address and a token, without an account to fall back on.
    public init(baseURL: URL, token: String, identity: PlexIdentity,
                urlSession: URLSession = .localNetworkCapable) {
        self.route = PlexRoute(base: baseURL, token: token)
        self.identity = identity
        self.session = urlSession
        self.resolver = nil
    }

    /// A client for a stored account. `resolver` asks plex.tv for the addresses of the
    /// server again; the default does that with the real network.
    public init(session stored: Session, identity: PlexIdentity,
                urlSession: URLSession = .localNetworkCapable, resolver: Resolver? = nil) {
        self.route = PlexRoute(base: stored.serverURL, token: stored.accessToken)
        self.identity = identity
        self.session = urlSession
        self.user = (stored.userID, stored.userName)
        self.details = stored.plex
        self.resolver = stored.plex == nil ? nil
            : resolver ?? Self.standardResolver(identity: identity, urlSession: urlSession)
    }

    // MARK: - Account

    /// The account as a session, with the address in use now. `nil` for a client
    /// built from an address alone.
    public func currentSession() -> Session? {
        guard let user else { return nil }
        return Session(accessToken: route.token, userID: user.id, userName: user.name,
                       serverURL: route.base, kind: .plex, plex: details)
    }

    /// Called with the new session whenever the client moves to another address.
    public func onSessionChange(_ handler: (@Sendable (Session) -> Void)?) {
        routeObserver = handler
    }

    /// Called when the server answers `401` to a request: the token may have run out in
    /// the middle of the session. Once, until ``unauthorizedHandled()``.
    public func onUnauthorized(_ handler: (@Sendable () -> Void)?) {
        unauthorizedObserver = handler
    }

    /// The `401` was looked into and the token still works (it was about one title):
    /// the next one may be reported again.
    public func unauthorizedHandled() { unauthorizedTold = false }

    /// Forgets the account on this client. The plex.tv token stays valid (it belongs to the
    /// user's other devices too); the app deletes its copy.
    public func forgetAccount() {
        user = nil
        details = nil
        route.clearToken()
    }

    /// Asks plex.tv for the server's addresses and uses the best one that answers.
    /// For a change of network, where the old address still answers but a better one
    /// (home network instead of relay) now exists.
    ///
    /// - Returns: whether the address changed.
    @discardableResult
    public func chooseBestConnection() async throws -> Bool {
        let before = route.base
        try await moveToBestConnection(failed: nil)
        return route.base != before
    }

    /// The default for ``Resolver``: plex.tv's resource list, then the probe of every
    /// address with the machine check.
    public static func standardResolver(identity: PlexIdentity,
                                        urlSession: URLSession = .localNetworkCapable) -> Resolver {
        { details in
            let service = PlexAccountService(identity: identity, urlSession: urlSession)
            let servers = try await service.servers(token: details.accountToken)
            guard let server = servers.first(where: { $0.machineIdentifier == details.machineIdentifier })
            else { throw PlexError.noServer }
            let token = server.accessToken ?? details.accountToken
            // The probes get their own session: one that waits for connectivity would
            // ignore their short timeouts (see `PlexConnector.probeSession`).
            let connector = PlexConnector(identity: identity, token: token,
                                          machineIdentifier: server.machineIdentifier)
            let chosen = try await connector.choose(from: server)
            return PlexResolvedRoute(connection: chosen, token: token)
        }
    }

    /// Only a request that did not arrive justifies another address. `401`, `404` and
    /// the like say something about the account or the title, not about the way.
    static func isRouteProblem(_ error: any Error) -> Bool {
        switch error as? JellyfinError {
        case .network, .certificate, .transport: true
        case .http(let status, _): [502, 503, 504, 521, 522, 523, 524].contains(status)
        default: false
        }
    }

    private func moveToBestConnection(failed: URL?) async throws {
        // Someone else already moved: nothing to search, the caller just repeats.
        if let failed, route.base != failed { return }
        if let running = switching { return try await running.value }
        guard let details, let resolver else { throw PlexError.serverUnreachable }
        let task = Task { [weak self] in
            let resolved = try await resolver(details)
            await self?.adopt(resolved)
        }
        switching = task
        defer { switching = nil }
        try await task.value
    }

    private func adopt(_ resolved: PlexResolvedRoute) {
        route.set(base: resolved.connection.uri, token: resolved.token)
        routeConfirmed = true
        details = details?.moved(to: resolved.connection)
        previewCache = nil
        parentKinds = [:]
        if let stored = currentSession() { routeObserver?(stored) }
    }

    // MARK: - Transport

    func request(_ method: String, _ path: String, _ query: [(String, String)] = [],
                         start: Int? = nil, size: Int? = nil) throws -> URLRequest {
        let playback = self.playback
        guard let url = playback.url(path: path, query: query) else {
            throw JellyfinError.invalidServerURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        for (name, value) in identity.headers(token: playback.token.isEmpty ? nil : playback.token,
                                              sessionID: sessionID) {
            req.setValue(value, forHTTPHeaderField: name)
        }
        if let start { req.setValue(String(start), forHTTPHeaderField: "X-Plex-Container-Start") }
        if let size { req.setValue(String(size), forHTTPHeaderField: "X-Plex-Container-Size") }
        return req
    }

    /// Sends what `build` makes. If it does not get through, looks for another address
    /// and builds the request again (the address is part of it).
    func fetch(_ build: () throws -> URLRequest) async throws -> Data {
        let used = route.base
        do {
            if !routeConfirmed, details != nil, resolver != nil {
                return try await fetchUnconfirmed(build, used: used)
            }
            return try await fetchOnce(try build())
        } catch where details != nil && Self.isRouteProblem(error) {
            try await moveToBestConnection(failed: used)
            return try await fetchOnce(try build())
        }
    }

    /// **How long a stored address may stay silent before the others are tried.** The address
    /// a stored account comes back with is the one from the last launch; on another network
    /// it hangs until the session gives up (about 20 s measured). After this the addresses
    /// are looked up alongside, and the first request moves over if that finds another one.
    static let silenceLimit: Duration = .seconds(4)

    /// The first request on a stored address nobody has proven yet.
    private func fetchUnconfirmed(_ build: () throws -> URLRequest, used: URL) async throws -> Data {
        let request = try build()
        enum Outcome { case data(Data), moved, none }
        let outcome: Outcome = try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask { .data(try await self.fetchOnce(request)) }
            group.addTask {
                try? await Task.sleep(for: Self.silenceLimit)
                guard !Task.isCancelled else { return .none }
                try? await self.moveToBestConnection(failed: used)
                return self.route.base != used ? .moved : .none
            }
            defer { group.cancelAll() }
            while let next = try await group.next() {
                switch next {
                case .data, .moved: return next
                case .none: continue
                }
            }
            throw JellyfinError.transport("Keine Antwort.")
        }
        switch outcome {
        case .data(let data):
            routeConfirmed = true
            return data
        case .moved, .none:
            return try await fetchOnce(try build())
        }
    }

    func fetchOnce(_ req: URLRequest) async throws -> Data {
        do {
            return try await PlexTransport.fetch(req, session: session)
        } catch JellyfinError.http(let status, _) where status == 401 {
            if !unauthorizedTold, let unauthorizedObserver {
                unauthorizedTold = true
                unauthorizedObserver()
            }
            throw JellyfinError.notAuthenticated
        }
    }

    func listing(_ path: String, _ query: [(String, String)] = [],
                         start: Int? = nil, size: Int? = nil) async throws -> PlexListing {
        let data = try await fetch { try self.request("GET", path, query, start: start, size: size) }
        do {
            return try JSONDecoder().decode(PlexEnvelope<PlexListing>.self, from: data).container
        } catch {
            throw JellyfinError.decoding(String(describing: error))
        }
    }

    func command(_ method: String, _ path: String, _ query: [(String, String)]) async throws {
        _ = try await fetch { try self.request(method, path, query) }
    }

    func items(of listing: PlexListing) -> [Item] {
        listing.metadata.map(mapper.item)
    }

    // MARK: - Server

    /// `GET /identity`. ← `publicSystemInfo`, `checkReachability`
    public func info() async throws -> PlexServerInfo {
        let answer = try await listing("/identity")
        guard let machine = answer.machineIdentifier else {
            throw JellyfinError.decoding("identity")
        }
        return PlexServerInfo(machineIdentifier: machine, version: answer.version,
                              claimed: answer.claimed ?? false)
    }

    /// Whether the token still works. `401` means no; anything else that fails is an
    /// error, not a sign-out. ← `sessionAppliesStill`
    public func tokenWorks() async throws -> Bool {
        do {
            _ = try await listing("/library/sections")
            return true
        } catch JellyfinError.notAuthenticated {
            return false
        }
    }

    // MARK: - Libraries and lists

    /// `GET /library/sections`.
    public func sections() async throws -> [PlexSection] {
        try await listing("/library/sections").directories
    }

    /// The libraries the app can show (films and series), as home-page views.
    /// ← `userViews`
    public func views() async throws -> [Item] {
        try await sections().filter { ["movie", "show"].contains($0.type) }.map(mapper.view)
    }

    /// A page of a library. ← `items`
    ///
    /// - Parameters:
    ///   - type: ``Item/type`` (`Movie`, `Series`, `Season`, `Episode`) to list; `nil` is
    ///     the library's own kind (films in a film library, series in a series library).
    ///   - genreID: the `id` of a ``PlexTag``/genre entry, see ``genres(section:)``.
    public func list(section: String, type: String? = nil, sort: Sorting = .name,
                     filter: LibraryFilter = .all, genreID: String? = nil,
                     start: Int = 0, size: Int = 50) async throws -> PlexPage {
        var query: [(String, String)] = [("sort", Self.sortValue(sort))]
        if let type, let number = PlexMapper.plexTypeNumber(forItemType: type) {
            query.append(("type", String(number)))
        }
        switch filter {
        case .begun: query.append(("inProgress", "1"))
        case .unwatched: query.append(("unwatched", "1"))
        // A favourite is a rating of 9 or more (hearts are written as 10).
        case .watchlist: query.append(("userRating>>", "9"))
        case .all: break
        }
        if let genreID { query.append(("genre", genreID)) }
        let answer = try await listing("/library/sections/\(section)/all", query,
                                       start: start, size: size)
        return PlexPage(items: items(of: answer), total: answer.totalSize ?? answer.size,
                        start: answer.offset ?? start)
    }

    /// Plex's sort expression for one of the app's sortings.
    public static func sortValue(_ sorting: Sorting) -> String {
        switch sorting {
        case .name: "titleSort:asc"
        case .latest: "addedAt:desc"
        case .rating: "audienceRating:desc"
        case .erscheinung: "originallyAvailableAt:desc"
        }
    }

    /// `GET /library/sections/{id}/genre`. ← `genres`
    public func genres(section: String) async throws -> [PlexSection] {
        try await listing("/library/sections/\(section)/genre").directories
    }

    // MARK: - Shelves

    /// "Continue watching": started films and episodes, newest first.
    /// ← `resumeItems`
    public func continueWatching(limit: Int = 20) async throws -> [Item] {
        let answer = try await listing("/hubs/continueWatching/items", [], start: 0, size: limit)
        return items(of: answer)
    }

    /// The next unwatched episode of every series being watched. ← `nextUp`
    public func onDeck(limit: Int = 20) async throws -> [Item] {
        items(of: try await listing("/library/onDeck", [], start: 0, size: limit))
    }

    /// Newly added films and episodes, optionally of one library. ← `lastAdded`
    public func recentlyAdded(section: String? = nil, limit: Int = 24) async throws -> [Item] {
        let path = section.map { "/library/sections/\($0)/recentlyAdded" } ?? "/library/recentlyAdded"
        return items(of: try await listing(path, [], start: 0, size: limit))
    }

    /// All shelves the server composes for a library (or the home page), unmapped.
    public func hubs(section: String? = nil) async throws -> [PlexHub] {
        try await listing(section.map { "/hubs/sections/\($0)" } ?? "/hubs").hubs
    }

    /// `GET /hubs/search`: films, series and episodes whose name matches. ← `search`
    public func search(_ term: String, limit: Int = 40) async throws -> [Item] {
        let clean = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        let answer = try await listing("/hubs/search",
                                       [("query", clean), ("limit", String(limit))])
        var seen = Set<String>()
        return answer.hubs.flatMap(\.items)
            .filter { ["movie", "show", "episode"].contains($0.type) && seen.insert($0.ratingKey).inserted }
            .map(mapper.item)
    }

    // MARK: - Details

    /// `GET /library/metadata/{id}` with markers and chapters. ← `item`
    public func detail(_ ratingKey: String) async throws -> PlexDetail {
        let answer = try await listing("/library/metadata/\(ratingKey)",
                                       [("includeChapters", "1"), ("includeMarkers", "1")])
        guard let metadata = answer.metadata.first else { throw JellyfinError.noPlayableSource }
        return PlexDetail(item: mapper.item(metadata), metadata: metadata,
                          segments: mapper.segments(metadata.markers, duration: metadata.duration),
                          chapters: mapper.chapters(metadata.chapters))
    }

    public func item(_ ratingKey: String) async throws -> Item { try await detail(ratingKey).item }

    /// Children: a series' seasons, a season's episodes.
    public func children(_ ratingKey: String) async throws -> [Item] {
        items(of: try await listing("/library/metadata/\(ratingKey)/children"))
    }

    /// ← `seasons`
    public func seasons(seriesID: String) async throws -> [Item] { try await children(seriesID) }

    /// One season's episodes, or all of the series. ← `episodes`
    public func episodes(seriesID: String, seasonID: String? = nil) async throws -> [Item] {
        if let seasonID { return try await children(seasonID) }
        return items(of: try await listing("/library/metadata/\(seriesID)/allLeaves"))
    }

    /// Titles like this one. ← `similar`
    public func similar(_ ratingKey: String, limit: Int = 12) async throws -> [Item] {
        items(of: try await listing("/library/metadata/\(ratingKey)/similar",
                                    [("count", String(limit))], start: 0, size: limit))
    }

    /// `GET /library/metadata/{id}/extras`: trailers and extras. Only those with a file of
    /// their own count: an online extra has nothing to play from this server.
    func clips(_ ratingKey: String) async throws -> [PlexMetadata] {
        let answer: PlexListing
        do { answer = try await listing("/library/metadata/\(ratingKey)/extras") }
        catch JellyfinError.http(404, _) { return [] }   // a title the server does not know
        return answer.metadata.filter { $0.media.contains { !$0.parts.isEmpty } }
    }

    /// The collections of a library. ← `collectionDirectory`
    public func collections(section: String) async throws -> [Item] {
        items(of: try await listing("/library/sections/\(section)/collections"))
    }

    public func collectionItems(_ ratingKey: String) async throws -> [Item] {
        items(of: try await listing("/library/collections/\(ratingKey)/children"))
    }

    /// Video playlists. ← `playlistDirectory`
    public func playlists() async throws -> [Item] {
        items(of: try await listing("/playlists", [("playlistType", "video")]))
    }

    /// ← `playlistEntries`
    public func playlistItems(_ ratingKey: String) async throws -> [Item] {
        items(of: try await listing("/playlists/\(ratingKey)/items"))
    }

    /// Everything a person or genre filter finds in one library. ← `titleWithNumber`
    public func titles(section: String, filter: String, value: String, start: Int = 0,
                       size: Int = 60) async throws -> PlexPage {
        let answer = try await listing("/library/sections/\(section)/all", [(filter, value)],
                                       start: start, size: size)
        return PlexPage(items: items(of: answer), total: answer.totalSize ?? answer.size,
                        start: start)
    }

    // MARK: - State

    /// ← `setWatched`
    public func setWatched(_ ratingKey: String, _ watched: Bool) async throws {
        try await command("PUT", watched ? "/:/scrobble" : "/:/unscrobble",
                          [("key", ratingKey), ("identifier", "com.plexapp.plugins.library")])
    }

    /// A favourite is a rating of 10; taking it away removes the rating. ← `setWatchlist`
    public func setFavorite(_ ratingKey: String, _ favorite: Bool) async throws {
        try await command("PUT", "/:/rate",
                          [("key", ratingKey), ("identifier", "com.plexapp.plugins.library"),
                           ("rating", favorite ? "10" : "-1")])
    }

    /// Tells the server which tracks the user chose, so they are the default next time.
    public func chooseTracks(partID: Int, audioStreamID: Int?, subtitleStreamID: Int?) async throws {
        var query: [(String, String)] = [("allParts", "1")]
        if let audioStreamID { query.append(("audioStreamID", String(audioStreamID))) }
        // 0 switches subtitles off.
        query.append(("subtitleStreamID", String(subtitleStreamID ?? 0)))
        try await command("PUT", "/library/parts/\(partID)", query)
    }

    // MARK: - Images

    /// ← `imageURL`
    public nonisolated func imageURL(path: String, maxHeight: Int? = nil,
                                     maxWidth: Int? = nil) -> URL? {
        playback.imageURL(path: path, maxHeight: maxHeight, maxWidth: maxWidth)
    }

    public nonisolated func imageURL(for item: Item, kind: ImageKind = .poster,
                                     maxHeight: Int? = nil, maxWidth: Int? = nil) -> URL? {
        let path: String?
        switch kind {
        case .poster: path = item.imageTags?["Primary"]
        case .background: path = item.backdropImageTags?.first ?? item.parentBackdropImageTags?.first
        case .logo: path = item.imageTags?["Logo"]
        case .preview: path = item.imageTags?["Thumb"] ?? item.imageTags?["Primary"]
        }
        return path.flatMap { imageURL(path: $0, maxHeight: maxHeight, maxWidth: maxWidth) }
    }

    // MARK: - Playback

    /// Direct play, always. No server call besides the detail. ← `playbackPlan`
    public func plan(for ratingKey: String, mediaSourceID: String? = nil,
                     audioStreamID: Int? = nil, subtitleStreamID: Int? = nil) async throws
        -> PlaybackPlan {
        let detail = try await detail(ratingKey)
        return try playback.plan(for: detail.metadata, mediaSourceID: mediaSourceID,
                                 audioStreamID: audioStreamID, subtitleStreamID: subtitleStreamID,
                                 sessionID: sessionID)
    }

    /// The original file for a download. ← `downloadURL`
    public func downloadURL(_ ratingKey: String, mediaSourceID: String? = nil) async throws -> URL {
        let metadata = try await detail(ratingKey).metadata
        guard let part = PlexPlayback.part(of: metadata, mediaSourceID: mediaSourceID),
              let address = playback.fileURL(partKey: part.key, download: true) else {
            throw PlexError.noFile
        }
        return address
    }

    /// An external subtitle with the token attached. Embedded tracks have none.
    public nonisolated func subtitleURL(_ stream: PlexStream) -> URL? { playback.subtitleURL(stream) }

    /// The address of a subtitle of a mapped stream (`MediaStream.deliveryUrl` holds the
    /// bare path).
    public nonisolated func subtitleURL(path: String) -> URL? {
        playback.url(path: path, withToken: true)
    }

    /// Skip buttons. ← `sections`
    public func segments(_ ratingKey: String) async throws -> [Segment] {
        try await detail(ratingKey).segments
    }

    /// ← `chapter`
    public func chapters(_ ratingKey: String) async throws -> [Chapter] {
        try await detail(ratingKey).chapters
    }

    /// The preview pictures of a title, or `nil` if the server made none (`404`).
    /// ← `trickplay`, `trickplaySheet`
    public func previews(_ ratingKey: String, mediaSourceID: String? = nil) async throws -> PlexBIF? {
        let metadata = try await detail(ratingKey).metadata
        guard let part = PlexPlayback.part(of: metadata, mediaSourceID: mediaSourceID),
              part.indexes != nil,
              let address = playback.previewIndexURL(partID: part.id) else { return nil }
        let key = "\(machineKey)/\(part.id)"
        if let cached = previewCache, cached.key == key { return cached.bif }
        let token = route.token
        var req = URLRequest(url: address)
        for (name, value) in identity.headers(token: token.isEmpty ? nil : token) {
            req.setValue(value, forHTTPHeaderField: name)
        }
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        do {
            let bif = PlexBIF(data: try await fetchOnce(req))
            previewCache = (key, bif)
            return bif
        } catch JellyfinError.http(let status, _) where status == 404 {
            previewCache = (key, nil)
            return nil
        }
    }

    // MARK: - Reports

    /// `POST /:/timeline`. Send on every change of state and about every ten seconds in
    /// between; the server marks a title watched itself when it is played to the end.
    /// ← `reportStart`, `reportProgress`, `reportStopped`
    public func reportTimeline(_ ratingKey: String, state: PlexPlayback.State, positionTicks: Int64,
                               durationMilliseconds: Int?) async throws {
        try await command("POST", "/:/timeline", PlexPlayback.timelineQuery(
            ratingKey: ratingKey, state: state, positionTicks: positionTicks,
            durationMilliseconds: durationMilliseconds))
    }
}

