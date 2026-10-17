import JellyfinKit
import SwiftUI

/// Series belonging to an episode, **prefetched before anyone taps.**
///
/// On the home page "Continue Watching" and "Next Up" are episodes, not series.
/// Tapping one leads via `SeasonTarget` to the series page, which first needs the
/// series itself. Until it arrived, an **empty page** slid in and the finished
/// one appeared abruptly in the middle.
///
/// Measured on the Mac: the empty page stood for 92 to 174 ms, exactly where
/// the time jump was in the recorded trace. The fetch is not slow, it was only
/// hidden while the page change cross-faded. The answer is not to bring back the
/// cross-fade but to not wait at all the second time. That also explains why it
/// shows on the **first** open and not afterwards.
///
/// **Why this file is shared.** It existed twice: as `SeriesCache` in
/// `Sources/tvOS/SeriesView.swift` and as `Seriencache` in
/// `Sources/macOS/Seriencache.swift`, the latter commented as a verbatim copy of
/// the tvOS one. Two copies of the same rule, and iPhone and iPad had none: there
/// the series page still waits for the server on **every** open. This is the
/// kind of drift that "a copied function is a bug" guards against.
///
/// **Only for display, not as truth.** On appearing, the fetch runs anyway and
/// overwrites with fresh values. What is stored here may be stale; it only must
/// not look wrong.
@MainActor
@Observable
final class SeriesCache {
    static let shared = SeriesCache()

    struct Snapshot {
        /// The series itself, for the detour from an episode, which otherwise fetches
        /// it every time. See `SeasonTarget`.
        var series: Item?
        var seasons: [Item] = []
        /// The episode to continue with. Only the TV shows it so far; it lives here
        /// because it belongs to the same state.
        var nextWith: Item?
        /// Per season. The key is the season ID.
        var episodes: [String: [Item]] = [:]
        /// Season the page last showed, and the playback plan of the next episode, so
        /// the second visit shows season picker, episodes and playback-method row
        /// immediately (iPhone/iPad).
        var selectedSeason: String?
        var plan: PlaybackPlan?
    }

    /// Series by their own ID, for `series(fuer:)`.
    private var known: [String: Item] = [:]
    private var states: [String: Snapshot] = [:]
    private var railsEpisode: [String] = []
    /// Is a fetch already running? Without this, a row of eight episodes of the
    /// same series fetches it eight times.
    private var ongoing: Set<String> = []

    func series(for episode: Item, with model: AppModel) -> Item? {
        guard valid(model) else { return nil }
        return episode.seriesId.flatMap { known[$0] }
    }

    func remember(_ series: Item) { known[series.id] = series }

    func state(_ series: String, with model: AppModel) -> Snapshot? {
        guard valid(model) else { return nil }
        return states[series]
    }

    func remember(_ series: String, _ change: (inout Snapshot) -> Void) {
        if states[series] == nil {
            states[series] = Snapshot()
            railsEpisode.append(series)
        }
        change(&states[series]!)
        // Twelve are enough for the way back and keep memory small.
        while railsEpisode.count > 12 { states[railsEpisode.removeFirst()] = nil }
    }

    /// **What is stored here is wrong from now on.**
    ///
    /// The store holds a series' episodes including `userData`, i.e. checkmarks and
    /// progress. It does not expire; it is cleared only on account switch. Marking an
    /// episode as watched changes the state on the server, and what is stored here
    /// does not know.
    ///
    /// That was the reported bug: a whole season checked off episode by episode,
    /// back, in again, and everything unwatched. The server had every checkmark; the
    /// season view just did not write its freshly fetched episodes back, and the
    /// series page is assembled from this store.
    ///
    /// **Discard instead of patch.** Changing the checkmark in the stored `Item`
    /// would mean rebuilding `Item` and `UserItemData` in a place that should not
    /// know about them, and the next field would raise the same question. The store
    /// exists so the way back is not empty, not to hold the truth about watch state.
    func forget(_ series: String) {
        states[series] = nil
        railsEpisode.removeAll { $0 == series }
        known[series] = nil
    }

    /// **After playing, the state is old, the episodes are not.**
    ///
    /// `nextWith` is what the series page's main button names on open, before the
    /// fresh state is there. Anyone who has watched since, e.g. via "Continue
    /// Watching" on the home page without the series page, got the old episode named
    /// and the right one a second later. The button never names a guessed episode,
    /// so drop it; until the fetch the page shows a neutral "Play".
    ///
    /// **The stored episodes too:** with checkmarks and bars they are just as stale
    /// after playing; opening the series after watching from "Continue Watching"
    /// first showed the old state, which jumped a moment later. The season list does
    /// not change and stays.
    func stateForget(_ series: String) {
        states[series]?.nextWith = nil
        states[series]?.episodes = [:]
        states[series]?.plan = nil
        next[series] = nil
    }

    // MARK: Next episode, before the click

    /// **Where a series continues, remembered before anyone taps.**
    ///
    /// Separate from `states`: that holds twelve series with episode lists, this
    /// holds just one episode per series, for every series on the home page. Filled
    /// from "Continue Watching" and "Next Up" (there the tile *is* the episode, as
    /// delivered by the server), from focus on a series or episode tile
    /// (`nextPreload`) and from the series page's own fetch. Discarded after
    /// playing (`stateForget`).
    private var next: [String: Item] = [:]
    private var nextRunning: Set<String> = []

    /// The episode to continue with, if known: fresh stock first, then the state
    /// of the last visited series page.
    func nextEpisode(_ series: String, with model: AppModel) -> Item? {
        guard valid(model) else { return nil }
        return next[series] ?? states[series]?.nextWith
    }

    func nextRemember(_ episode: Item?, for series: String) {
        next[series] = episode
    }

    /// From a home page row: each episode is the one where its series continues.
    func nextRemember(from rail: [Item]) {
        for episode in rail where episode.type == "Episode" {
            if let series = episode.seriesId { next[series] = episode }
        }
    }

    /// Fetches the series state for this tile if missing; called when a tile holds
    /// focus (debounced in `TileStyle`).
    func nextPreload(toward title: Item, with model: AppModel) async {
        let series: String? = switch title.type {
        case "Series": title.id
        case "Episode": title.seriesId
        default: nil
        }
        guard let series, valid(model), next[series] == nil,
              states[series]?.nextWith == nil,
              !nextRunning.contains(series),
              let client = model.client else { return }
        let account = model.accountSwitch
        nextRunning.insert(series)
        defer { nextRunning.remove(series) }
        let episode = await client.stateInSeries(series)
        guard account == model.accountSwitch, let episode else { return }
        next[series] = episode
    }

    /// **The series of a whole row in one request**, for the info line of the
    /// home page on TV.
    ///
    /// There an episode shows the series line (year, runtime, stars, rating).
    /// Fetched one by one under focus it arrived a moment after everything else.
    /// Prefetching on TV had been turned off because it meant **18 single requests**
    /// alongside the first posters, whose result nobody read. Both changed now:
    /// **one** request `Items?Ids=...` per row, only after the rows loaded, with low
    /// priority, and the line reads it.
    func prefetchBundle(_ episodes: [Item], with model: AppModel) async {
        _ = valid(model)
        let opened = Array(Set(episodes.filter { $0.type == "Episode" }.compactMap(\.seriesId))
            .subtracting(known.keys)
            .subtracting(ongoing))
        guard !opened.isEmpty, let client = model.client else { return }
        let account = model.accountSwitch
        ongoing.formUnion(opened)
        defer { ongoing.subtract(opened) }
        guard let answer = try? await client.items(limit: opened.count, ids: opened),
              // A different account in the meantime: its store, not this one.
              account == model.accountSwitch
        else { return }
        for series in answer.items { known[series.id] = series }
    }

    /// Fetches the series for **one** episode, for hovering over a tile.
    ///
    /// **This is the one part that depends on the input method.** On the Mac the
    /// pointer always rests on the tile before clicking; typically a few tenths of a
    /// second, which is enough for the fetch. That removes the empty page on paths
    /// that row prefetching does not cover: search, similar titles, a freshly opened
    /// window. iPhone and TV have no such window; there only prefetching the whole
    /// row helps.
    func prefetch(_ episode: Item, with model: AppModel) {
        guard episode.type == "Episode" else { return }
        prefetch([episode], with: model)
    }

    /// Fetches the series for these episodes if not yet known.
    func prefetch(_ episodes: [Item], with model: AppModel) {
        _ = valid(model)
        let opened = Set(episodes.compactMap(\.seriesId))
            .subtracting(known.keys)
            .subtracting(ongoing)
        guard !opened.isEmpty else { return }
        ongoing.formUnion(opened)
        let account = model.accountSwitch

        for id in opened {
            Task { @MainActor in
                let series = await model.item(id: id)
                // A different account in the meantime: the response carries its
                // predecessor's watch state and does not belong in the new store (`valid` has
                // already cleared `ongoing`).
                if account == model.accountSwitch {
                    if let series { known[id] = series }
                    ongoing.remove(id)
                }
            }
        }
    }

    /// Which account state what is stored here belongs to.
    ///
    /// **The store checks itself instead of every view having to remember to clear
    /// it.** Unlike a `leeren()` that somebody must call, nobody can forget it here:
    /// every access goes through `state(_:)` or `series(fuer:)` anyway.
    ///
    /// **And the damage is not in the titles but in the watch state.** A cached
    /// `Item` carries `userData` with `played` and `playbackPositionTicks`, i.e. the
    /// state of the account that fetched it. Without this check, after a switch a
    /// page would show foreign checkmarks and progress bars from the store, and
    /// "Continue Watching" would resume at a foreign position and report it to the
    /// new account.
    private var forAccount = 0

    /// Does the content still belong to the signed-in account? If not, it is
    /// discarded right here.
    private func valid(_ model: AppModel) -> Bool {
        guard forAccount != model.accountSwitch else { return true }
        forAccount = model.accountSwitch
        known.removeAll()
        states.removeAll()
        next.removeAll()
        nextRunning.removeAll()
        railsEpisode.removeAll()
        ongoing.removeAll()
        return false
    }
}
