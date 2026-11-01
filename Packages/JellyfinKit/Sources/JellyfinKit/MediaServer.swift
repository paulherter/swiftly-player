import Foundation

/// Which kind of media server an account belongs to.
///
/// **The raw values are stored** (`Session.kind`, the bundle names), so they never change.
public enum ServerKind: String, Codable, Sendable, CaseIterable {
    case jellyfin
    case emby
    case plex

    /// The prefix of ``Session/accountKey`` for this kind. Jellyfin has none: its keys
    /// were written before there was a second kind and must stay byte-identical.
    public var accountKeyPrefix: String {
        self == .jellyfin ? "" : rawValue + ":"
    }

    /// Where the bundle of this kind is kept (keychain entry on Apple, file name or
    /// vault entry elsewhere). `konten` stays the Jellyfin bundle.
    public var bundleStorageKey: String {
        self == .jellyfin ? "konten" : "konten." + rawValue
    }

    /// What a server of this kind can do, as far as the app has a backend for it. The
    /// client reports the same set (`MediaServer.capabilities`); the table exists so that a
    /// screen can ask before a client is connected, e.g. while offline.
    public var capabilities: Set<ServerCapability> {
        switch self {
        case .jellyfin: ServerCapability.allCases.asSet
        case .emby: ServerKind.embyCapabilities
        case .plex: PlexFeatures.capabilities
        }
    }
}

private extension Array where Element: Hashable {
    var asSet: Set<Element> { Set(self) }
}

/// What a server may offer beyond the common core. The user interface asks
/// (`AppModel.can(_:)`) and shows only what the server can do.
public enum ServerCapability: String, Sendable, CaseIterable {
    case quickConnect
    case publicUsers
    case syncPlay
    /// Reports this device to the server and takes remote commands.
    case remoteControl
    /// Sends playback to another device of the account.
    case playOnOtherDevice
    /// Display preferences kept on the server (``SettingsSync``).
    case settingsSync
    case trickplay
    case introSegments
    case chapters
    case collections
    case playlists
    case favorites
    case markWatched
    case similar
    case extras
    case genres
    case seerr
    case downloads
}

/// **What the user interface needs from a media server.**
///
/// The signatures are those `JellyfinClient` already had, so the call sites did not
/// change. Only what the interface calls and what Emby and Plex can also answer is in
/// here. Jellyfin-only parts (Quick Connect, SyncPlay, remote control, display
/// preferences) sit in the helper protocols below; the interface reaches them with
/// `as?` and checks ``capabilities`` first.
///
/// **Defaults live in the extension at the end, and every conformer implements the
/// requirements itself.** The extension has the same signatures as the requirements so
/// that a call on `any MediaServer` can leave out parameters; a conformer that does not
/// implement one would call itself.
public protocol MediaServer: AnyObject, Sendable, HomePageSource {
    var kind: ServerKind { get }
    var capabilities: Set<ServerCapability> { get }
    var baseURL: URL { get }

    // MARK: Account and connection
    func currentSession() async -> Session?
    /// A second client for the same device on the same server, without an account (adding
    /// another account must not touch the signed-in client).
    func signedOutCopy() -> any MediaServer
    func publicSystemInfo() async throws -> PublicSystemInfo
    func checkReachability() async throws -> PublicSystemInfo
    func authenticate(username: String, password: String) async throws -> Session
    func signOff() async
    func sessionAppliesStill() async -> Bool
    func accountDefaults() async -> AccountPreGift?

    // MARK: Libraries and lists
    func userViews(hidden: Bool) async throws -> [Item]
    func items(parentID: String?, limit: Int, startIndex: Int, sortBy: String, sortOrder: String,
               filters: [String], isWatched: Bool?, recursive: Bool, includeItemTypes: [String],
               ids: [String], personIDs: [String], genres: [String],
               slim: Bool) async throws -> ItemsResponse
    func search(_ term: String, limit: Int) async throws -> [Item]
    func genres() async throws -> [String]
    func resumeItems(limit: Int) async throws -> [Item]
    func nextUp(limit: Int) async throws -> [Item]
    func lastAdded(in library: String?, fetch: Int, showItem: Int, genres: String) async -> [Item]?
    func playlistEntries(_ playlist: String, lean: Bool) async throws -> [Item]
    func playlistDirectory() async throws -> PlaylistDirectory
    func collectionDirectory(viewList: [Item]) async throws -> CollectionDirectory
    func libraryShares(views: [Item]) async -> [String: LibraryShare]
    func titleFilter(_ source: ShelfSource, filters: [String], isWatched: Bool?) async throws -> TitleFilter
    func naturalList(parentID: String?, sortOrder: String, filters: [String], isWatched: Bool?,
                     recursive: Bool, includeItemTypes: [String]) async throws -> [Item]
    func naturalPage(_ list: [Item], since: Int, count: Int) async throws -> ItemsResponse
    func rememberedItems(types: [String], sortBy: String, sortOrder: String, startIndex: Int,
                         limit: Int, libraries: [Item]?) async throws -> ItemsResponse
    func title(person id: String, limit: Int) async -> [Item]?
    func title(genre: String, limit: Int) async -> [Item]?
    func titleWithNumber(person id: String, limit: Int, startIndex: Int) async -> (items: [Item], total: Int)?
    func titleWithNumber(genre: String, limit: Int, startIndex: Int) async -> (items: [Item], total: Int)?

    // MARK: Details
    func item(id: String) async throws -> Item
    func similar(itemID: String, toward preStatus: Item?, limit: Int) async throws -> [Item]
    func extras(itemID: String) async throws -> [Item]
    func trailer(toward itemID: String) async throws -> [Item]
    func seasons(seriesID: String) async throws -> [Item]
    func episodes(seriesID: String, seasonID: String?) async throws -> [Item]
    func nextEpisodeSeries(seriesID: String) async throws -> Item?
    func episodePost(itemID: String, seriesID: String) async throws -> Item?
    func stateInSeries(_ seriesID: String) async -> Item?
    func stateInSeriesChecked(_ seriesID: String) async throws -> Item?
    func metadataRefresh(_ itemID: String) async throws
    func setWatchlist(itemID: String, an: Bool) async throws
    func setWatched(itemID: String, an: Bool) async throws
    func pointBackSet(itemID: String) async throws
    #if DEBUG
    /// The server's user data of one title as it came, and putting it back (offline
    /// reconciliation of downloads).
    func userDataRaw(itemID: String) async throws -> Data
    func userDataBackPut(itemID: String, raw: Data) async throws
    #endif

    // MARK: Images
    func imageURL(for item: Item, maxHeight: Int) async -> URL?

    // MARK: Playback
    func playbackPlan(for itemID: String, profile: DeviceProfile, audioStreamIndex: Int?,
                      subtitleStreamIndex: Int?, mediaSourceID: String?) async throws -> PlaybackPlan?
    func airplayPlan(for itemID: String, source: MediaSource) async throws -> AirPlayInfo
    /// The copy-only address for the AVPlayer engine, `nil` if this server has none
    /// (then VLC plays). See ``JellyfinClient/avPlayerPlan(for:source:audioIndex:av1:)``.
    func avPlayerPlan(for itemID: String, source: MediaSource, audioIndex: Int?,
                      av1: Bool) async throws -> PlaybackPlan?
    func downloadURL(itemID: String, mediaSourceID: String?, quality: DownloadQuality,
                     audioStreamIndex: Int?) async throws -> URL
    func sections(for itemID: String) async -> [Segment]
    func segmentsToStore(for itemID: String) async -> [Segment]?
    func trickplay(itemID: String, mediaSourceID: String?, target: Int) async -> Trickplay?
    func trickplaySheet(itemID: String, mediaSourceID: String?, width: Int, sheet: Int) async -> Data?
    func chapter(itemID: String, mediaSourceID: String?) async -> [Chapter]

    // MARK: Reports
    func reportStart(itemID: String, plan: PlaybackPlan, ticks: Int64, tracks: TrackIndices) async throws
    func reportProgress(itemID: String, plan: PlaybackPlan, positionTicks: Int64, paused: Bool,
                        tracks: TrackIndices) async throws
    func reportStopped(itemID: String, plan: PlaybackPlan, positionTicks: Int64) async throws
    func reportLater(_ opened: [PendingReport], log: @Sendable (String) -> Void) async -> [String]
}

// Parameter defaults for calls on `any MediaServer`; the same ones `JellyfinClient` has.
public extension MediaServer {
    func userViews(hidden: Bool = false) async throws -> [Item] {
        try await userViews(hidden: hidden)
    }
    func items(parentID: String? = nil, limit: Int = 100, startIndex: Int = 0,
               sortBy: String = "SortName", sortOrder: String = "Ascending",
               filters: [String] = [], isWatched: Bool? = nil, recursive: Bool = false,
               includeItemTypes: [String] = [], ids: [String] = [], personIDs: [String] = [],
               genres: [String] = [], slim: Bool = false) async throws -> ItemsResponse {
        try await items(parentID: parentID, limit: limit, startIndex: startIndex, sortBy: sortBy,
                        sortOrder: sortOrder, filters: filters, isWatched: isWatched,
                        recursive: recursive, includeItemTypes: includeItemTypes, ids: ids,
                        personIDs: personIDs, genres: genres, slim: slim)
    }
    func search(_ term: String, limit: Int = 40) async throws -> [Item] {
        try await search(term, limit: limit)
    }
    func resumeItems(limit: Int = 20) async throws -> [Item] { try await resumeItems(limit: limit) }
    func nextUp(limit: Int = 20) async throws -> [Item] { try await nextUp(limit: limit) }
    func lastAdded(in library: String? = nil, fetch: Int = 200, showItem: Int = 24,
                   genres: String = "Movie,Episode") async -> [Item]? {
        await lastAdded(in: library, fetch: fetch, showItem: showItem, genres: genres)
    }
    func playlistEntries(_ playlist: String, lean: Bool = false) async throws -> [Item] {
        try await playlistEntries(playlist, lean: lean)
    }
    func collectionDirectory(viewList: [Item] = []) async throws -> CollectionDirectory {
        try await collectionDirectory(viewList: viewList)
    }
    func titleFilter(_ source: ShelfSource, filters: [String] = [],
                     isWatched: Bool? = nil) async throws -> TitleFilter {
        try await titleFilter(source, filters: filters, isWatched: isWatched)
    }
    func rememberedItems(types: [String], sortBy: String, sortOrder: String, startIndex: Int,
                         limit: Int, libraries: [Item]? = nil) async throws -> ItemsResponse {
        try await rememberedItems(types: types, sortBy: sortBy, sortOrder: sortOrder,
                                  startIndex: startIndex, limit: limit, libraries: libraries)
    }
    func title(person id: String, limit: Int = 60) async -> [Item]? { await title(person: id, limit: limit) }
    func title(genre: String, limit: Int = 24) async -> [Item]? { await title(genre: genre, limit: limit) }
    func titleWithNumber(person id: String, limit: Int = 60,
                         startIndex: Int = 0) async -> (items: [Item], total: Int)? {
        await titleWithNumber(person: id, limit: limit, startIndex: startIndex)
    }
    func titleWithNumber(genre: String, limit: Int = 24,
                         startIndex: Int = 0) async -> (items: [Item], total: Int)? {
        await titleWithNumber(genre: genre, limit: limit, startIndex: startIndex)
    }
    func similar(itemID: String, toward preStatus: Item? = nil, limit: Int = 12) async throws -> [Item] {
        try await similar(itemID: itemID, toward: preStatus, limit: limit)
    }
    func episodes(seriesID: String, seasonID: String? = nil) async throws -> [Item] {
        try await episodes(seriesID: seriesID, seasonID: seasonID)
    }
    func imageURL(for item: Item, maxHeight: Int = 480) async -> URL? {
        await imageURL(for: item, maxHeight: maxHeight)
    }
    func playbackPlan(for itemID: String, profile: DeviceProfile = .vlc(), audioStreamIndex: Int? = nil,
                      subtitleStreamIndex: Int? = nil, mediaSourceID: String? = nil) async throws -> PlaybackPlan? {
        try await playbackPlan(for: itemID, profile: profile, audioStreamIndex: audioStreamIndex,
                               subtitleStreamIndex: subtitleStreamIndex, mediaSourceID: mediaSourceID)
    }
    func downloadURL(itemID: String, mediaSourceID: String?, quality: DownloadQuality,
                     audioStreamIndex: Int? = nil) async throws -> URL {
        try await downloadURL(itemID: itemID, mediaSourceID: mediaSourceID, quality: quality,
                              audioStreamIndex: audioStreamIndex)
    }
    func trickplay(itemID: String, mediaSourceID: String?, target: Int = 320) async -> Trickplay? {
        await trickplay(itemID: itemID, mediaSourceID: mediaSourceID, target: target)
    }
    func reportStart(itemID: String, plan: PlaybackPlan, ticks: Int64 = 0,
                     tracks: TrackIndices = .init()) async throws {
        try await reportStart(itemID: itemID, plan: plan, ticks: ticks, tracks: tracks)
    }
    func reportProgress(itemID: String, plan: PlaybackPlan, positionTicks: Int64, paused: Bool,
                        tracks: TrackIndices = .init()) async throws {
        try await reportProgress(itemID: itemID, plan: plan, positionTicks: positionTicks,
                                 paused: paused, tracks: tracks)
    }
    func reportLater(_ opened: [PendingReport],
                     log: @Sendable (String) -> Void = { _ in }) async -> [String] {
        await reportLater(opened, log: log)
    }
}

// MARK: - Only Jellyfin (reached with `as?`, after `capabilities` said yes)

/// Quick Connect and the public user list (`.quickConnect`, `.publicUsers`).
public protocol QuickSignIn: MediaServer {
    func publicUser() async throws -> [PublicUser]
    func userImage(_ user: PublicUser, border: Int) async -> URL?
    func quickConnectStart() async throws -> LoginCode
    func quickConnectAskAgain(_ code: LoginCode) async -> QuickConnectState
    func signInWithQuickConnect(_ code: LoginCode) async throws -> Session
    func quickConnectShare(code: String) async throws
}

public extension QuickSignIn {
    func userImage(_ user: PublicUser, border: Int = 180) async -> URL? {
        await userImage(user, border: border)
    }
}

/// Sessions of the account on the server: this device as a remote, handing playback over
/// (`.remoteControl`, `.playOnOtherDevice`).
public protocol RemoteSessionServer: MediaServer {
    func reportCapabilities() async throws
    func remoteControl() async throws -> RemoteControl
    func remoteSession() async throws -> [RemoteSession]
    func handoffHint(an session: String, device: String) async throws
    func foreignCommand(_ command: ForeignCommand, an session: String) async throws
    func playOn(session: String, order: PlayOrder) async throws
}

/// Display preferences kept on the server (`.settingsSync`).
public protocol DisplayPreferencesServer: MediaServer {
    func displayPreferences(id: String, client: String) async throws -> DisplayPreferencesCopy
    func saveDisplayPreferences(_ copy: DisplayPreferencesCopy, setting fields: [String: String],
                                id: String, client: String) async throws
}

public extension DisplayPreferencesServer {
    func displayPreferences(id: String = SettingsSync.displayID,
                            client: String = SettingsSync.clientName) async throws -> DisplayPreferencesCopy {
        try await displayPreferences(id: id, client: client)
    }
    func saveDisplayPreferences(_ copy: DisplayPreferencesCopy, setting fields: [String: String],
                                id: String = SettingsSync.displayID,
                                client: String = SettingsSync.clientName) async throws {
        try await saveDisplayPreferences(copy, setting: fields, id: id, client: client)
    }
}
