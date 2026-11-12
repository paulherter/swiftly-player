import Foundation
import JellyfinKit

#if canImport(SwiftlyCore)
import SwiftlyCore
import os
#endif

/// What a tile shows when the Rust core feeds the home page: the texts and the picture address
/// come ready from the core, the view adds nothing of its own.
struct RustTileLook: Sendable, Equatable {
    let title: String
    let subtitle: String?
    /// The line of a "Continue watching" tile with the time left ("S2 · E5 · 12 min left"); `nil` elsewhere.
    var remaining: String? = nil
    let image: URL?
}

#if canImport(SwiftlyCore)
/// The bridge between the app and `SwiftlyCore`'s `HomeModel` (`AppModel.coreServes`).
///
/// It owns the core, one `HomeModel` per account and row choice, and turns the core's tiles into
/// what `HomeView` takes: `Item` stand-ins (enough to route a tap, play and open the series page,
/// all of which fetch the full title themselves) plus a ``RustTileLook`` per tile. The Swift view
/// code stays as it is; only the data source and the three tile expressions differ.
@MainActor
final class RustHomeFeed {
    /// One core per process: the runtime, the HTTP client and the stores are shared.
    /// Created in one place, `AppCore`.
    static var core: SwiftlyCore.Core { AppCore.shared.raw }

    private var current: (account: AccountRef, prefs: HomePrefs, model: SwiftlyCore.HomeModel)?

    /// The model that serves the page now, if any.
    var currentModel: SwiftlyCore.HomeModel? { current?.model }

    /// The view model for this account and these rows; a new one when either changed.
    func model(for account: AccountRef, prefs: HomePrefs) throws -> SwiftlyCore.HomeModel {
        if let current, current.account == account, current.prefs == prefs { return current.model }
        let model = SwiftlyCore.HomeModel(
            vm: try Self.core.homeVmWith(account: account, locale: AppCore.language, prefs: prefs))
        current = (account, prefs, model)
        return model
    }

    /// Every rail with all of its tiles (the core hands out a window first, the rest on request).
    static func rails(of model: SwiftlyCore.HomeModel) -> [(rail: SwiftlyCore.Rail, tiles: [SwiftlyCore.Tile])] {
        model.rails.rails.map { rail in
            var tiles = rail.tiles
            let rest = rail.ids.count - tiles.count
            if rest > 0 { tiles += model.tiles(rail: rail.id, from: tiles.count, count: rest) }
            return (rail, tiles)
        }
    }
}

/// The core for the Library grid and Search screens (`AppModel.coreServes`): one search model per
/// account, a library model per list that the grid keeps. Anything that goes wrong returns `nil` and the
/// screen takes its old Swift path.
@MainActor
final class RustScreens {
    private var search: (account: AccountRef, model: SwiftlyCore.SearchModel)?

    static var language: String { AppCore.language }

    /// Why the last core search found nothing to show; `.unreachable` unless the core named another reason.
    private(set) var searchTrouble = Trouble.unreachable

    /// The search result as `Item` stand-ins (movies, series), or `nil` when the core cannot answer
    /// (no Jellyfin/Emby session, error, cancelled): the caller then asks the old way.
    func hits(_ term: String, session: Session?, looks: inout [String: RustTileLook]) async -> [Item]? {
        guard let session, let account = AccountRef(session) else { return nil }
        let model: SwiftlyCore.SearchModel
        if let search, search.account == account {
            model = search.model
        } else {
            guard let vm = try? RustHomeFeed.core.searchVm(account: account, locale: Self.language) else { return nil }
            model = SwiftlyCore.SearchModel(vm: vm)
            search = (account, model)
        }
        searchTrouble = .unreachable
        guard let status = await model.search(term) else { return nil }
        switch status {
        case .done, .empty:
            let tiles = model.results.groups.flatMap(\.tiles)
            for tile in tiles { looks[tile.id] = RustTileLook(tile) }
            return tiles.map(Item.init(rust:))
        default:
            searchTrouble = Trouble(model.loadState)
            return nil
        }
    }

    /// A grid for this list; the library page keeps it between loads.
    func shelf(for session: Session?, source: JellyfinKit.ShelfSource) -> RustShelf? {
        guard let session, let account = AccountRef(session) else { return nil }
        let spec = SwiftlyCore.LibrarySpec(
            source: SwiftlyCore.ShelfSource(
                parent: source.parent, onlyOut: source.onlyOut, art: source.art, collection: source.collection),
            genre: nil, rememberName: nil)
        guard let vm = try? RustHomeFeed.core.libraryVm(account: account, locale: Self.language, spec: spec) else {
            return nil
        }
        return RustShelf(SwiftlyCore.LibraryModel(vm: vm))
    }
}

/// The core's grid of one list, turned into what the library page holds.
@MainActor
final class RustShelf {
    struct Page {
        var items: [Item] = []
        var looks: [String: RustTileLook] = [:]
        var total = 0
        var more = false
        var moreFailed = false
        var offline = false
        var trouble = Trouble.unreachable
        var signedOut = false
    }

    private let core: SwiftlyCore.LibraryModel

    init(_ core: SwiftlyCore.LibraryModel) { self.core = core }

    /// First page (or a refresh) in this order and filter; returns when the core has settled.
    func load(sorting: JellyfinKit.Sorting, filter: JellyfinKit.LibraryFilter) async -> Page {
        await core.loadSettled(sorting: sorting.rust, filter: filter.rust)
        return page()
    }

    /// The letter strip of the list on screen, over the whole list (fetched once by the core).
    func alphabet() async -> AlphabetIndex {
        let part = await core.alphabetSettled()
        let sorting: JellyfinKit.Sorting =
            switch part.sorting {
            case .name: .name
            case .latest: .latest
            case .rating: .rating
            case .erscheinung: .erscheinung
            }
        return AlphabetIndex(
            entries: part.entries.map {
                .init(letter: $0.key, first: Int($0.first), label: $0.label, gap: $0.gap)
            },
            count: Int(part.count), sorting: sorting, monthly: part.monthly)
    }

    /// The strip key of a loaded title, as the core computes it from the full title.
    func key(of id: String) -> String? { core.keyOf(id) }

    /// The id of the first loaded title under a strip key; `nil` while it is not loaded.
    func jumpTargetID(_ key: String) -> String? { core.jumpTargetID(key) }

    /// The next page.
    func more() async -> Page {
        await core.loadMoreSettled()
        return page()
    }

    private func page() -> Page {
        let status = core.status
        var page = Page()
        for tile in core.grid.tiles { page.looks[tile.id] = RustTileLook(tile) }
        page.items = core.grid.tiles.map(Item.init(rust:))
        page.total = Int(core.grid.total)
        page.more = status.moreAvailable
        page.moreFailed = status.loadMoreFailed
        page.offline = status.status == .offline
        page.trouble = page.offline ? Trouble(core.loadState) : .unreachable
        page.signedOut = status.status == .signedOut
        return page
    }
}

extension AppModel {
    /// The poster of a title on a grid or row: where the core feeds the page, its own picture address for
    /// the tile (the stand-in `Item` has no image marks); else the Swift one.
    func portraitURL(_ item: Item, maxHeight: Int = 600) -> URL? {
        if coreServes, let url = rustLooks[item.id]?.image { return url }
        return imageURL(for: item, maxHeight: maxHeight, portrait: true)
    }

    /// Search through the core; `nil` means: ask the old way.
    func searchRust(_ term: String) async -> [Item]? {
        var looks: [String: RustTileLook] = [:]
        guard let items = await rustScreens.hits(term, session: session, looks: &looks) else { return nil }
        rustLooks.merge(looks) { _, new in new }
        return items
    }
}

extension JellyfinKit.Sorting {
    var rust: SwiftlyCore.Sorting {
        switch self {
        case .name: .name
        case .latest: .latest
        case .rating: .rating
        case .erscheinung: .erscheinung
        }
    }
}

extension JellyfinKit.LibraryFilter {
    var rust: SwiftlyCore.LibraryFilter {
        switch self {
        case .all: .all
        case .begun: .begun
        case .watchlist: .watchlist
        case .unwatched: .unwatched
        }
    }
}

extension SwiftlyCore.AccountRef {
    /// The account the app is signed in with. A Plex account is the address in use and the server token
    /// (`PlexClient(session:)` reads the same two fields); the core builds its Plex client from them.
    @MainActor init?(_ session: Session) {
        let kind: SwiftlyCore.ServerKind
        switch session.kind {
        case .jellyfin: kind = .jellyfin
        case .emby: kind = .emby
        case .plex: kind = .plex
        }
        self.init(
            baseUrl: session.serverURL.absoluteString, userId: session.userID,
            token: session.accessToken, serverKind: kind, deviceId: AppModel.deviceID)
    }
}

extension Item {
    /// A stand-in made of what a tile knows. Routing, the series page and playback fetch the rest.
    init(rust tile: SwiftlyCore.Tile) {
        let facts = tile.facts
        var watched = false
        var favorite = false
        var unplayed: Int?
        for badge in tile.badges {
            switch badge {
            case .watched: watched = true
            case .favorite: favorite = true
            case .unplayed(let count): unplayed = Int(count)
            case .seasons: break // the Apple tiles work out the seasons mark themselves
            }
        }
        let data: UserItemData? =
            (watched || favorite || unplayed != nil || tile.progress != nil)
            ? UserItemData(
                played: watched, isFavorite: favorite,
                playedPercentage: tile.progress.map { Double($0) * 100 }, unplayedItemCount: unplayed)
            : nil
        self.init(
            id: tile.id, name: facts.name, type: facts.kind, productionYear: facts.year.map(Int.init),
            seriesName: facts.kind == "Episode" ? tile.title : nil,
            indexNumber: facts.episodeNumber.map(Int.init),
            parentIndexNumber: facts.seasonNumber.map(Int.init), seriesId: facts.seriesId,
            seasonId: facts.seasonId, childCount: facts.childCount.map(Int.init), userData: data)
    }
}

extension Item {
    /// The stand-in with the single facts of the TV header from the core's tile details: description, year,
    /// runtime, stars, age rating and where playback resumes (the remaining time reads from that). Nothing else changes.
    func withHeaderFacts(_ d: SwiftlyCore.TileDetails?) -> Item {
        guard let d else { return self }
        let data = UserItemData(
            playbackPositionTicks: d.resumeSeconds.map { Int64($0 * 10_000_000) },
            played: userData?.played, isFavorite: userData?.isFavorite,
            playedPercentage: userData?.playedPercentage, unplayedItemCount: userData?.unplayedItemCount)
        return Item(
            id: id, name: name, type: type, productionYear: d.year.map(Int.init) ?? productionYear,
            overview: d.overview, runTimeTicks: d.runtimeSeconds.map { Int64($0 * 10_000_000) },
            seriesName: seriesName, indexNumber: indexNumber, parentIndexNumber: parentIndexNumber,
            seriesId: seriesId, seasonId: seasonId, officialRating: d.officialRating,
            communityRating: d.communityRating, childCount: childCount, userData: data)
    }
}

extension RustTileLook {
    init(_ tile: SwiftlyCore.Tile) {
        // "Continue watching" carries its whole second line in `remaining` ("S1 · F3 · noch 34 Min."), which is
        // what the old tile showed; every other rail has none and shows `subtitle`.
        self.init(
            title: tile.title, subtitle: tile.remaining ?? tile.subtitle, remaining: tile.remaining,
            image: tile.image.flatMap { URL(string: $0.address) })
    }
}

#endif
