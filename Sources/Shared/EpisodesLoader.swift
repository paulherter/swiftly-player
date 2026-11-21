import JellyfinKit
import SwiftUI

/// **What the player's Folgen box shows and how it gets it**, once for every platform (the box itself is drawn per platform:
/// `EpisodesBox` on iPhone, iPad and Mac, `TVFolgenBox` on Apple TV). The loader holds the open season's episodes, fills them
/// from the series store first and from the server after, follows a season choice from the core's season box and writes what
/// it fetched back into the store. The seasons and the open one live in the ``SeasonPicker`` the player's menus share.
@Observable @MainActor
final class EpisodesLoader {
    private(set) var episodes: [Item] = []
    /// The server was silent (seasons or episodes): the view says so only while it has no episodes to show.
    private(set) var disrupted = false

    private let model: AppModel
    private let item: Item
    private let picker: SeasonPicker

    /// **The list is already there on opening.** What the store has (the player preloads it at start) is in place before the
    /// first frame; otherwise the rows would pop in after the box. The view builds this on every re-evaluation of its parent:
    /// a season the viewer already chose must stay (`SeasonPicker.adopt`).
    init(model: AppModel, item: Item, picker: SeasonPicker) {
        self.model = model; self.item = item; self.picker = picker
        guard let series = item.seriesId,
              let remembered = SeriesCache.shared.state(series, with: model),
              !remembered.seasons.isEmpty else { return }
        picker.adopt(seasons: remembered.seasons, rule: SeasonSelectionRule.choose(from: remembered.seasons, state: item))
        episodes = picker.selected.flatMap { remembered.episodes[$0.id] } ?? []
    }

    /// Seasons and the episodes of the running season into the store, called as soon as the player shows an episode.
    static func preload(model: AppModel, item: Item) async {
        guard let seriesKeyID = item.seriesId, let series = Item.preCommonSeries(toward: item) else { return }
        // A failed fetch (`nil`) does not go into the store: the next view would take the empty list for the truth.
        guard let seasons = await model.seasons(series), !seasons.isEmpty else { return }
        SeriesCache.shared.remember(seriesKeyID) { $0.seasons = seasons }
        guard let season = SeasonSelectionRule.choose(from: seasons, state: item) else { return }
        guard let episodes = await model.episodes(series: seriesKeyID, season: season.id) else { return }
        SeriesCache.shared.remember(seriesKeyID) { $0.episodes[season.id] = episodes }
    }

    /// First what the store has, then fresh from the server. A failed fetch keeps what is shown.
    func load() async {
        guard let series = Item.preCommonSeries(toward: item) else { return }
        if let remembered = SeriesCache.shared.state(series.id, with: model), !remembered.seasons.isEmpty {
            picker.seasons = remembered.seasons
            // A season the viewer already chose stays; the rule only picks the first time.
            picker.selected = remembered.seasons.first(where: { $0.id == picker.selected?.id })
                ?? SeasonSelectionRule.choose(from: remembered.seasons, state: item)
            if let id = picker.selected?.id, let list = remembered.episodes[id] { episodes = list }
        }
        // `nil` means disturbed: what the store had stays.
        guard let fresh = await model.seasons(series) else { disrupted = true; return }
        guard !fresh.isEmpty else { return }
        disrupted = false
        picker.seasons = fresh
        if picker.selected == nil || !fresh.contains(where: { $0.id == picker.selected?.id }) {
            picker.selected = SeasonSelectionRule.choose(from: fresh, state: item)
        }
        await loadSeason()
    }

    /// A choice from the core's season box: consumes it and loads that season. `false` when there was nothing to do.
    @discardableResult
    func switchSeason(to id: String?, animation: Animation?) async -> Bool {
        guard picker.takeChoice(id) != nil else { return false }
        await loadSeason(animation: animation)
        return true
    }

    /// The open season's episodes. The list changes with `animation` on a season change (cross-fade); on opening it is
    /// there at once.
    func loadSeason(animation: Animation? = nil) async {
        guard let series = item.seriesId else { return }
        let season = picker.selected?.id
        // Failed means the list stays as it was: emptying it would claim the season has no episodes.
        guard let loaded = await model.episodes(series: series, season: season) else { disrupted = true; return }
        disrupted = false
        // Whoever chose another season in the meantime gets its episodes.
        guard season == picker.selected?.id else { return }
        if let animation { withAnimation(animation) { episodes = loaded } } else { episodes = loaded }
        if let season { SeriesCache.shared.remember(series) { $0.episodes[season] = loaded } }
    }
}
