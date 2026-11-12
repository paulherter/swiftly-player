import Observation

/// The `@MainActor @Observable` adapter of `SeriesVm`: seasons, episodes, the head with the main
/// button, and cast/extras/similar are separate parts.
@MainActor
@Observable
public final class SeriesModel {
    public private(set) var seasons: SeasonsPart
    public private(set) var episodes: EpisodesPart
    public private(set) var button: SeriesButtonPart
    public private(set) var more: MorePart

    @ObservationIgnored private let vm: SeriesVm
    @ObservationIgnored private let seen: UInt64

    public init(vm: SeriesVm) {
        self.vm = vm
        self.seen = vm.version()
        self.seasons = vm.seasons()
        self.episodes = vm.episodes()
        self.button = vm.button()
        self.more = vm.more()
    }

    public func load() { vm.send(intent: .load) }
    public func refresh() { vm.send(intent: .refresh) }
    public func selectSeason(_ id: String) { vm.send(intent: .selectSeason(id: id)) }
    public func moreEpisodes() { vm.send(intent: .moreEpisodes) }
    public func retryEpisodes() { vm.send(intent: .retryEpisodes) }
    public func setEpisodeWatched(_ id: String, _ on: Bool) { vm.send(intent: .setEpisodeWatched(id: id, on: on)) }
    public func markSeasonWatched() { vm.send(intent: .markSeasonWatched) }
    public func setWatched(_ on: Bool) { vm.send(intent: .setWatched(on: on)) }
    public func setWatchlist(_ on: Bool) { vm.send(intent: .setWatchlist(on: on)) }
    public func dismissMessage() { vm.send(intent: .dismissMessage) }
    public func switchAccount(_ account: AccountRef?) { vm.send(intent: .accountSwitched(account: account)) }
    public func setOptions(_ options: SeriesOptions) { vm.send(intent: .options(options: options)) }
    public func trailer() { vm.send(intent: .trailer) }
    public func menu(_ kind: MenuKind) { vm.send(intent: .menu(kind: kind)) }

    /// The entries of the More panel.
    public func moreMenu() -> [MenuEntry] { vm.moreMenu() }
    /// Work for the host (play, open a trailer, a menu entry only the host can run ...); empties the queue.
    public func takeEffects() -> [SeriesEffect] { vm.takeEffects() }
    /// The series (`nil`) or an episode/season on screen as the server's own JSON: what the host's `Item` is
    /// decoded from.
    public func itemJSON(_ id: String? = nil) -> String? { vm.itemJson(id: id) }
    /// The playback plan of the next episode, if the core holds one; saves the request on press.
    public func planAnswer() -> PlanOnly? { vm.planAnswer() }

    /// What the main button does.
    public func playNext(pick: String? = nil) -> PlayAction { vm.playNext(pick: pick) }
    /// What a tap on an episode does.
    public func playEpisode(_ id: String, pick: String? = nil) -> PlayAction { vm.playEpisode(id: id, pick: pick) }

    /// Sends `load` and returns when seasons, the main button, the first episodes and the extra rows have
    /// settled (`true`), or after `timeout` / on cancel (`false`). Independent of `observe()`.
    public func loadSettled(timeout: Duration = .seconds(30)) async -> Bool {
        vm.send(intent: .load)
        return await settle(timeout: timeout) { [self] in readAll() } changed: { [vm] in
            try await vm.changed(seen: $0).version
        } version: { [vm] in vm.version() }
    }

    /// Picks a season and returns when its episodes have settled.
    public func selectSeasonSettled(_ id: String, timeout: Duration = .seconds(30)) async -> Bool {
        vm.send(intent: .selectSeason(id: id))
        return await settle(timeout: timeout) { [self] in readAll() } changed: { [vm] in
            try await vm.changed(seen: $0).version
        } version: { [vm] in vm.version() }
    }

    private func readAll() -> Bool {
        seasons = vm.seasons()
        episodes = vm.episodes()
        button = vm.button()
        more = vm.more()
        return button.labelReady && episodes.status != .loading && !more.similarLoads
    }

    /// Returns when the calling Task is cancelled.
    public func observe() async {
        let seasonsBit = partSeriesSeasons()
        let episodesBit = partSeriesEpisodes()
        let buttonBit = partSeriesButton()
        let moreBit = partSeriesMore()
        let vm = vm
        await observeChanges(from: seen, changed: { try await vm.changed(seen: $0) }) { change in
            if change.parts & seasonsBit != 0 { seasons = vm.seasons() }
            if change.parts & episodesBit != 0 { episodes = vm.episodes() }
            if change.parts & buttonBit != 0 { button = vm.button() }
            if change.parts & moreBit != 0 { more = vm.more() }
        }
    }
}
