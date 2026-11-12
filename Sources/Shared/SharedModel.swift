import Foundation
import JellyfinKit
import Observation
import SwiftlyCore
import SwiftUI

/// What the player provides for "Watch together".
///
/// **An object the player updates every tick, not callbacks that capture it.**
/// A closure that captures a SwiftUI view reads its state from back then (see
/// `hubAdopt` in the player). Here the player rewrites surface,
/// title and "ready" every tick, and the group always reads the current state.
@MainActor
final class SharedPlayer {
    weak var area: VLCPlayerView?
    /// Which title is currently playing.
    var titleID = ""
    /// Is the picture steady, and no title change in progress?
    var isReady = false
    /// Makes the timeline and button follow immediately after a seek.
    var jumpShow: (Double) -> Void = { _ in }
    /// The group is watching something else: switch inside the open player.
    var switchTitle: (Item, PlaybackPlan, Double) -> Void = { _, _, _ in }

    func title() -> String { titleID }
    func ready() -> Bool { isReady }
    func spot() -> Double { area?.positionSeconds ?? 0 }
    func proceed() { area?.resume() }
    func halt() { area?.pause() }
    func jump(_ target: Double) {
        area?.seek(toSeconds: target)
        jumpShow(target)
    }
}

/// A group on offer (the core's row: name, who is watching, the phase in words).
typealias SharedGroup = SwiftlyCore.SyncPlayGroupRow

/// **Watch together: the SwiftUI mirror (iPhone, iPad, Mac, TV).**
///
/// The flow lives in the Rust core (`SyncPlayModel`, behind ``SyncPlayController``): rights, groups, the
/// clock, who is ready, what the player must do. Swift only mirrors the core's page for SwiftUI, reads its
/// phase through the one state machine (``TogetherState``), feeds it the control-channel messages
/// (`RemoteController`, `URLSessionWebSocketLink`), and does what the core asks of the player and of the
/// sheets. Linux, Windows and Android-Swift still run JellyfinKit's `SyncPlaySession`.
///
/// **One for the whole app.** The detail page creates the group, the header offers it, the player runs it;
/// on iPhone the player sits in its own UIKit frame, which the environment does not reach.
@MainActor
@Observable
final class SharedModel {

    static let shared = SharedModel()

    // MARK: Read by the UI

    /// The core's controller for the current account (`nil`: no SyncPlay here).
    private(set) var controller: SyncPlayController?
    /// Where the group stands, read from the core's page (one machine, see ``TogetherState``).
    private(set) var together = TogetherState.off

    private var page: SyncPlayPage? { controller?.page }

    var mayCreate: Bool { page?.mayCreate ?? false }
    var mayJoin: Bool { page?.mayJoin ?? false }
    /// Groups on the server that you are not in.
    var offerings: [SharedGroup] { page?.groups ?? [] }
    /// The group you are in.
    var group: SyncPlayCurrent? { page?.current }
    /// For the strip "Leave movie night · Rejoin": the name of the group you left last.
    var lastLeave: String? { page?.lastLeave }
    /// Everyone in the group as the server names them.
    var participants: [String] { page?.detail.group?.participants ?? [] }
    var works: Bool { page?.works ?? false }
    /// What the group is currently watching.
    var queueTitle: String? { page?.queueTitle }

    /// Shown briefly at the top of the player: who joined, who left, why the movie stopped.
    struct AppEvent: Equatable, Identifiable {
        let id: UInt64
        let symbol: String
        let text: String
    }
    var event: AppEvent? {
        guard let page, let id = page.detail.noticeId, let kind = page.detail.noticeKind,
            let text = page.notice
        else { return nil }
        return AppEvent(id: id, symbol: Self.symbol(kind), text: text)
    }

    private static func symbol(_ kind: String) -> String {
        switch kind {
        case "dabei": "person.2.fill"
        case "gegangen": "person.2"
        case "wartet": "hourglass"
        case "angehalten": "pause.fill"
        case "weiter": "play.fill"
        case "gesprungen": "arrow.left.and.right"
        default: "exclamationmark.triangle"
        }
    }

    /// The "Watch together" sheet for this title is open.
    var createFor: Item?
    /// The sheet for joining, or the picker with "Continue watching here".
    enum Sheet: Equatable { case join(SharedGroup), pick }
    var sheet: Sheet?

    /// What the player should start; picked up by ``MainView``.
    var wish: PlayRequest?

    /// For a message in the view (the core's latest error; the view clears it).
    var error: String?

    /// "with A and B", excluding yourself.
    var withWhom: String { group?.withWhom ?? "" }

    /// Is the player currently running in the group?
    var inPlayer: Bool {
        if case .watching = together { return true }
        return false
    }

    /// Does this title belong to what the group is watching?
    func belongsGroup(_ titleID: String) -> Bool { together.inGroup && queueTitle == titleID }

    // MARK: Internals

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var tick: Task<Void, Never>?
    @ObservationIgnored private var pumps: [Task<Void, Never>] = []
    @ObservationIgnored private var remote: RemoteController?
    @ObservationIgnored private var seenAccepted: UInt64 = 0
    @ObservationIgnored private var seenErrors: UInt64 = 0
    @ObservationIgnored private(set) var player: SharedPlayer?

    // MARK: Start and end

    func start(_ model: AppModel) {
        self.model = model
        connect()
        guard tick == nil else { return }
        tick = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if !PlayState.playerRuns { self?.controller?.offeringsAsk() }
                await Foreground.wait(seconds: TakeoverModel.tickSeconds)
            }
        }
    }

    /// Builds the core's model and the control channel for the current account (Jellyfin with SyncPlay only).
    private func connect() {
        disconnect()
        guard let model, let session = model.session, model.client?.capabilities.contains(.syncPlay) == true,
            let account = CoreAccount(session)
        else {
            together = TogetherState.reduce(together, .unavailable)
            return
        }
        let host = ClosureSyncPlayHost(
            step: { [weak self] step in Task { @MainActor in self?.apply(step) } },
            loadTitle: { [weak self] title, since in
                Task { @MainActor in await self?.titleLoad(title, since: since) }
            })
        let core = AppCore.shared.raw
        guard let syncPlay = try? core.syncPlayModel(
            account: account, locale: AppCore.language, selfName: session.userName, host: host)
        else {
            together = TogetherState.reduce(together, .unavailable)
            return
        }
        let controller = SyncPlayController(model: syncPlay)
        self.controller = controller
        seenAccepted = controller.page.detail.accepted
        seenErrors = controller.page.detail.errorCount
        together = TogetherState.reduce(.off, .page(controller.page))
        pumps.append(Task { @MainActor in await controller.observe() })
        if let remote = try? RemoteController(core: core, account: account) {
            self.remote = remote
            remote.start()
            pumps.append(RemoteController.bind(remote, syncPlay: controller))
        }
        watch()
        controller.refresh()
    }

    private func disconnect() {
        pumps.forEach { $0.cancel() }
        pumps = []
        remote?.stop()
        remote = nil
        controller = nil
    }

    /// Re-arms itself: one reaction per page change of the core.
    private func watch() {
        guard let controller else { return }
        withObservationTracking {
            _ = controller.page
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.controller === controller else { return }
                self.pageChanged(controller.page)
                self.watch()
            }
        }
    }

    /// What the page's counters mean for the sheets and the strip.
    private func pageChanged(_ page: SyncPlayPage) {
        together = TogetherState.reduce(together, .page(page))
        if page.detail.accepted != seenAccepted {
            seenAccepted = page.detail.accepted
            createFor = nil
            sheet = nil
        }
        if page.detail.errorCount != seenErrors {
            seenErrors = page.detail.errorCount
            // **Not in `model.errorMessage`**: that is shown only by the sign-in. The message appears
            // as a `Hinweisstreifen` wherever you are.
            error = page.error
        }
    }

    /// **The account changed** (also sign-out, also first sign-in); called by `AppModel.client` on every
    /// change. The old account's model leaves its group (it keeps its own account), then the new account's
    /// model is built.
    func accountSwitched(alt: (any MediaServer)?) {
        createFor = nil
        sheet = nil
        error = nil
        wish = nil
        guard model != nil else { return }
        controller?.finish()
        Task { @MainActor in self.connect() }
    }

    /// On sign-out: leave the group, forget everything.
    func finish() {
        tick?.cancel(); tick = nil
        controller?.finish()
        disconnect()
        together = TogetherState.reduce(together, .unavailable)
    }

    // MARK: Create, join, leave

    /// Open the group and set the title right away. Everyone, including you,
    /// then gets the queue and opens the player paused.
    func create(name: String, title: Item) async {
        controller?.create(name: name, titleId: title.id)
    }

    func join(_ target: SharedGroup) async {
        controller?.join(target.id)
    }

    func againJoin() { controller?.rejoin() }

    /// The core moves the player.
    private func apply(_ step: SyncPlayStep) {
        guard let player else { return }
        switch step {
        case .proceed: player.proceed()
        case .halt: player.halt()
        case .jump(let seconds): player.jump(seconds)
        }
    }

    /// The group sets a title: switch in the open player, otherwise open the
    /// player. The same title in the open player does not arrive here; the
    /// core jumps there itself.
    private func titleLoad(_ titleID: String, since: Double) async {
        guard let model else { controller?.titleLoadFailed(); return }
        async let titleFetch = model.item(id: titleID)
        async let planFetch = model.plan(for: titleID)
        guard let title = await titleFetch, let plan = await planFetch else {
            controller?.titleLoadFailed()
            return
        }
        if let player {
            // Until the player reports in at the next tick, the old title counts as
            // not ready, otherwise "ready" would go out before the new one even loads.
            player.isReady = false
            player.switchTitle(title, plan, since)
        } else {
            wish = PlayRequest(item: title, plan: plan, startAt: since)
        }
    }

    // MARK: From the player

    private func snapshot(_ s: SharedPlayer) -> SwiftlyCore.SyncPlayPlayer {
        SwiftlyCore.SyncPlayPlayer(title: s.titleID, ready: s.isReady, spot: s.spot())
    }

    /// The player is open and belongs to the group.
    func plugIn(_ s: SharedPlayer) {
        player = s
        controller?.playerAttached(snapshot(s))
        together = TogetherState.reduce(together, .playerAttached)
    }

    /// The player closes. **That is leaving**.
    func detach() {
        player = nil
        controller?.playerDetached()
        together = TogetherState.reduce(together, .playerDetached)
    }

    /// Pause and resume go to the server as a request. The button flips only
    /// when the command comes back, then for everyone at the same time.
    func bitToggle(runningCurrently: Bool) { controller?.requestToggle(runningNow: runningCurrently) }

    func bitJump(on seconds: Double) { controller?.requestJump(seconds) }

    /// Episode choice in the player, in the group: for everyone.
    func bitTitle(_ titleID: String, since seconds: Double = 0) {
        controller?.requestTitle(titleID, since: seconds)
    }

    /// Once per player tick: the picture state, then the buffering report.
    func playerTick() {
        guard let player, let controller else { return }
        controller.playerUpdate(snapshot(player))
        controller.playerTick()
    }
}

// MARK: - What the sheets say

/// **Once for all platforms.** The sheets look different on phone, Mac and TV;
/// what they say is the same. It first lived in the iOS views and would have
/// been written a second time for TV.
extension SharedModel {
    /// For an episode, the series with season and episode; otherwise the sheet
    /// does not say which episode the group will watch.
    static func titleLine(_ title: Item) -> String {
        guard title.type == "Episode", let series = title.seriesName, !series.isEmpty else {
            return title.name
        }
        if let season = title.parentIndexNumber, let episode = title.indexNumber {
            return "\(series) · " + String(localized: "Staffel \(season) · Folge \(episode)")
        }
        return "\(series) · \(title.name)"
    }
}
