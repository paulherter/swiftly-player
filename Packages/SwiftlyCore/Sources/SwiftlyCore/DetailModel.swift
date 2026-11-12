import Observation

/// The `@MainActor @Observable` adapter of `DetailVm` (movie or episode page): hero, actions
/// (Play, toggles, proof row, download field) and the bottom sections arrive as separate parts.
/// What Play does now (`play`) and the work for the host (`takeEffects`) come from the core.
@MainActor
@Observable
public final class DetailModel {
    public private(set) var hero: HeroPart
    public private(set) var actions: ActionsPart
    public private(set) var bottom: BottomPart

    @ObservationIgnored private let vm: DetailVm
    @ObservationIgnored private let seen: UInt64

    public init(vm: DetailVm) {
        self.vm = vm
        self.seen = vm.version()
        self.hero = vm.hero()
        self.actions = vm.actions()
        self.bottom = vm.bottom()
    }

    public func load() { vm.send(intent: .load) }
    public func refresh() { vm.send(intent: .refresh) }
    public func setWatched(_ on: Bool) { vm.send(intent: .setWatched(on: on)) }
    public func setWatchlist(_ on: Bool) { vm.send(intent: .setWatchlist(on: on)) }
    public func retrySimilar() { vm.send(intent: .retrySimilar) }
    public func setDownloaded(_ on: Bool) { vm.send(intent: .downloaded(on: on)) }
    public func setOptions(_ options: DetailOptions) { vm.send(intent: .options(options: options)) }
    public func downloadState(_ state: DownloadState) { vm.send(intent: .downloadState(state: state)) }
    public func downloadPressed() { vm.send(intent: .downloadPressed) }
    public func trailer() { vm.send(intent: .trailer) }
    public func menu(_ kind: MenuKind) { vm.send(intent: .menu(kind: kind)) }
    public func dismissMessage() { vm.send(intent: .dismissMessage) }
    public func switchAccount(_ account: AccountRef?) { vm.send(intent: .accountSwitched(account: account)) }

    /// What a press on Play does now; `pick` is the chosen version.
    public func play(pick: String? = nil) -> PlayAction { vm.play(pick: pick) }
    public func playFromStart(pick: String? = nil) -> PlayAction { vm.playFromStart(pick: pick) }
    public func tileMenu() -> [MenuEntry] { vm.tileMenu() }
    public func moreMenu() -> [MenuEntry] { vm.moreMenu() }
    /// Work for the host (open the download screen, play a trailer ...); empties the queue.
    public func takeEffects() -> [DetailEffect] { vm.takeEffects() }

    /// The title as the server's own JSON (the fresh copy, else the stored one, else the list entry): what the
    /// host's `Item` is decoded from.
    public func itemJSON() -> String? { vm.itemJson() }

    /// The playback plan the page already holds (the server's, or the copy on the device's), if any.
    public func planAnswer() -> PlanOnly? { vm.planAnswer() }

    /// Sends `refresh` and returns when the fresh title has answered (`true`), or after `timeout` / on cancel.
    /// For a press on Play while the versions are not known: reload once, then decide again.
    public func refreshSettled(timeout: Duration = .seconds(10)) async -> Bool {
        vm.send(intent: .refresh)
        return await settle(timeout: timeout) { [self] in
            hero = vm.hero()
            actions = vm.actions()
            bottom = vm.bottom()
            switch vm.play(pick: nil) {
            case .wait, .resolve: return false
            case .choose, .start: return true
            }
        } changed: { [vm] in try await vm.changed(seen: $0).version } version: { [vm] in vm.version() }
    }

    /// Sends `load` and returns when the lower sections have arrived (`true`), or after `timeout` /
    /// when the calling Task is cancelled (`false`). Reads the parts itself; independent of `observe()`.
    public func loadSettled(timeout: Duration = .seconds(30)) async -> Bool {
        vm.send(intent: .load)
        return await settle(timeout: timeout) { [self] in
            hero = vm.hero()
            actions = vm.actions()
            bottom = vm.bottom()
            return bottom.ready
        } changed: { [vm] in try await vm.changed(seen: $0).version } version: { [vm] in vm.version() }
    }

    /// Returns when the calling Task is cancelled.
    public func observe() async {
        let heroBit = partDetailHero()
        let actionsBit = partDetailActions()
        let bottomBit = partDetailBottom()
        let vm = vm
        await observeChanges(from: seen, changed: { try await vm.changed(seen: $0) }) { change in
            if change.parts & heroBit != 0 { hero = vm.hero() }
            if change.parts & actionsBit != 0 { actions = vm.actions() }
            if change.parts & bottomBit != 0 { bottom = vm.bottom() }
        }
    }
}
