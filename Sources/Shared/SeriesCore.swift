import Foundation
import JellyfinKit

#if canImport(SwiftlyCore)
import SwiftlyCore

/// **The series page's data owner: the core's `SeriesVm`.**
///
/// Like `DetailCore` for the movie page: the screens draw what the model's parts say (seasons, episode rows, the
/// head with the main button, cast/extras/similar/watchers) and send intents back; which episode is next, what the
/// button says, which versions exist and what a toggle writes is decided in the core. What stays here is what only
/// the platform can do: the `Item`s the player, the tile menu and the download sheet are handed (decoded from the
/// core's own JSON), the options the core cannot know, and the effects it queues for the host.
@MainActor
@Observable
final class SeriesCore {
    let model: SwiftlyCore.SeriesModel
    /// The list entry the page was opened with.
    @ObservationIgnored let listItem: Item

    @ObservationIgnored private var seriesCache: (key: UInt64, item: Item)?
    @ObservationIgnored private var episodeCache: (key: UInt64, items: [String: Item])?

    /// `nil` when the core cannot serve this session (no account).
    init?(app: AppModel, item: Item, startSeasonID: String?, startSeasonNumber: Int?) {
        guard
            let model = try? app.core.series(
                session: app.session, tile: SwiftlyCore.Tile(standIn: item),
                spec: SwiftlyCore.SeriesSpec(
                    startSeasonId: startSeasonID, startSeasonNumber: startSeasonNumber.map(Int64.init)))
        else { return nil }
        self.model = model
        self.listItem = item
    }

    // MARK: Items

    /// The series as the tile menu and the download sheet take it: the core's fresh copy, else the list entry.
    var item: Item {
        let key = model.button.version
        if let seriesCache, seriesCache.key == key { return seriesCache.item }
        let fresh = decode(model.itemJSON()) ?? listItem
        seriesCache = (key, fresh)
        return fresh
    }

    /// An episode (or season) the page knows, as the player takes it.
    func item(_ id: String) -> Item? { decode(model.itemJSON(id)) }

    /// The rows of the open season as `Item`s, decoded once per change of the list.
    func episodeItems() -> [String: Item] {
        let key = model.episodes.version
        if let episodeCache, episodeCache.key == key { return episodeCache.items }
        var out: [String: Item] = [:]
        for row in model.episodes.rows {
            if let one = item(row.id) { out[row.id] = one }
        }
        episodeCache = (key, out)
        return out
    }

    /// The next episode (the one the main button plays), if the core has found it.
    var next: Item? { model.button.nextEpisode.flatMap { item($0) } }

    /// The plan of the next episode, if the core holds one; saves the request on press.
    func plan(app: AppModel, for id: String) -> PlaybackPlan? {
        guard id == model.button.nextEpisode else { return nil }
        return PlaybackPlan.core(model.planAnswer(), itemID: id, app: app)
    }

    private func decode(_ json: String?) -> Item? {
        json.flatMap { try? JSONDecoder().decode(Item.self, from: Data($0.utf8)) }
    }

    // MARK: Host knowledge

    /// What the core cannot know: settings, rights, devices in reach. Sent again whenever one changes.
    func send(options app: AppModel) {
        model.setOptions(
            SwiftlyCore.SeriesOptions(
                downloadButton: app.downloadButtonShow, canOpenWeb: DetailCore.canOpenWeb,
                maxBitrate: Int64(app.profileBitrate), together: SharedModel.shared.mayCreate,
                playOn: DetailCore.playOnDevices(app), watchersShown: app.watchersShown))
    }

    /// Loads, then keeps the parts current until the calling task is cancelled.
    func run(app: AppModel) async {
        send(options: app)
        model.load()
        await model.observe()
    }
}

extension SwiftlyCore.SeasonRow: @retroactive Identifiable {}

#if !os(tvOS)
extension RustEpisodeLook {
    /// One episode row as the core words it.
    init(row: SwiftlyCore.EpisodeRow) {
        self.init(
            title: "\(row.number.map { "\($0). " } ?? "")\(row.title)",
            secondaryLine: row.remaining ?? row.runtime ?? "",
            image: row.image.flatMap { URL(string: $0.address) },
            progress: row.progress.map { Double($0) }, watched: row.watched)
    }
}
#endif
#endif
