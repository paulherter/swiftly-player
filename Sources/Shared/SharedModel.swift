import Foundation
import JellyfinKit
import Observation
import SwiftUI

/// What the player provides for "Watch together".
///
/// **An object the player updates every tick, not callbacks that capture it.**
/// A closure that captures a SwiftUI view reads its state from back then (see
/// `hubAdopt` in the player). Here the player rewrites surface,
/// title and "ready" every tick, and the group always reads the current state.
@MainActor
final class SharedPlayer: SyncPlayPlayer {
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

/// **Watch together: the SwiftUI mirror (iPhone, iPad, Mac, TV).**
///
/// The flow lives in the package (``SyncPlaySession``), shared with Mac, TV,
/// Android, Linux and Windows. Only what ties to the app is here: the mirror
/// of ``SyncPlayStatus`` for SwiftUI, the sheets, loading a title into the
/// player, and the symbols for the notices.
///
/// **One for the whole app.** The detail page creates the group, the header
/// offers it, the player runs it; on iPhone the player sits in its own UIKit
/// frame, which the environment does not reach.
@MainActor
@Observable
final class SharedModel {

    static let shared = SharedModel()

    // MARK: Read by the UI

    /// The latest state from the package.
    private(set) var status = SyncPlayStatus()

    var rights: SyncPlayRight? { status.rights }
    var mayCreate: Bool { status.mayCreate }
    var mayJoin: Bool { status.mayJoin }
    /// Groups on the server that you are not in.
    var offerings: [SyncPlayGroup] { status.offerings }
    /// The group you are in.
    var group: SyncPlayGroup? { status.group }
    var condition: SyncPlayGroup.Phase? { status.condition }
    /// For the strip "Leave movie night · Rejoin".
    var lastLeave: SyncPlayGroup? { status.lastLeave }
    var works: Bool { status.works }

    /// Shown briefly at the top of the player: who joined, who left, why the movie stopped.
    struct AppEvent: Equatable, Identifiable {
        let id: UUID
        let symbol: String
        let text: String
    }
    var event: AppEvent? {
        status.event.map { AppEvent(id: $0.id, symbol: Self.symbolText($0.art), text: $0.text) }
    }

    private static func symbolText(_ art: SyncPlayEvent.Art) -> String {
        switch art {
        case .present: "person.2.fill"
        case .gone: "person.2"
        case .waitsOnAll: "hourglass"
        case .halted: "pause.fill"
        case .goesNext: "play.fill"
        case .jumped: "arrow.left.and.right"
        case .noAccess, .notPlayable: "exclamationmark.triangle"
        }
    }

    /// The "Watch together" sheet for this title is open.
    var createFor: Item?
    /// The sheet for joining, or the picker with "Continue watching here".
    enum Sheet: Equatable { case join(SyncPlayGroup), pick }
    var sheet: Sheet?

    /// What the player should start; picked up by ``MainView``.
    var wish: PlayRequest?

    /// For a message in the view.
    var error: String?

    /// "with A and B", excluding yourself.
    var withWhom: String {
        guard let group else { return "" }
        let other = group.other(asValue: ich)
        guard !other.isEmpty else { return String(localized: "noch niemand dabei") }
        let list = ListFormatter.localizedString(byJoining: other)
        return String(localized: "mit \(list)")
    }

    // MARK: Internals

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var tick: Task<Void, Never>?
    @ObservationIgnored private var hearOut: Task<Void, Never>?
    @ObservationIgnored private(set) var player: SharedPlayer?

    /// The flow. One for the app's lifetime; at each step it asks for the client
    /// that currently applies.
    @ObservationIgnored private lazy var session: SyncPlaySession = {
        let session = SyncPlaySession(
            client: { @MainActor [weak self] in self?.model?.client },
            ich: { @MainActor [weak self] in self?.ich },
            titleLoad: { @MainActor [weak self] title, since in
                await self?.titleLoad(title, since: since) ?? false
            })
        hearOut = Task { @MainActor [weak self] in
            for await m in session.withPart {
                guard let self else { return }
                switch m {
                case let .status(new): self.status = new
                case let .error(f):
                    // **Not in `model.errorMessage`**: that is shown only by the sign-in, and in
                    // the main view nobody read it. The message appears as a `Hinweisstreifen`
                    // wherever you are.
                    self.error = f.text
                }
            }
        }
        return session
    }()

    private var ich: String? { model?.session?.userName }

    /// What the group is currently watching.
    var queueTitle: String? { status.queueTitle }

    /// Is the player currently running in the group?
    var inPlayer: Bool { group != nil && player != nil }

    // MARK: Start and end

    func start(_ model: AppModel) {
        self.model = model
        let session = self.session
        model.syncPlayPostDirection = { session.accept($0) }
        guard tick == nil else { return }
        tick = Task {
            await session.rightFetch()
            while !Task.isCancelled {
                if !PlayState.playerRuns { await session.offeringsAsk() }
                await Foreground.wait(seconds: TakeoverModel.tickSeconds)
            }
        }
    }

    /// **The account changed** (also sign-out, also first sign-in); called by
    /// `AppModel.client` on every change. The old account's group is left with
    /// its own client, everything else is forgotten, and the new account's
    /// permission is fetched. The query keeps running; it asks for the current
    /// client each time anyway.
    func accountSwitched(alt: JellyfinClient?) {
        createFor = nil
        sheet = nil
        error = nil
        wish = nil
        guard model != nil else { return }
        let session = self.session
        Task {
            await session.finish(oldClient: alt)
            await session.rightFetch()
        }
    }

    /// On sign-out and account switch: leave the group, forget everything.
    func finish() {
        tick?.cancel(); tick = nil
        model?.syncPlayPostDirection = nil
        let session = self.session
        Task { await session.finish() }
    }

    // MARK: Create, join, leave

    /// Open the group and set the title right away. Everyone, including you,
    /// then gets the queue and opens the player paused.
    func create(name: String, title: Item) async {
        await session.create(name: name, title: title.id, accepted: { @MainActor [weak self] in
            self?.createFor = nil
        })
    }

    func join(_ target: SyncPlayGroup) async {
        await session.join(target, accepted: { @MainActor [weak self] in
            self?.sheet = nil
        })
    }

    func againJoin() {
        let session = self.session
        Task { await session.againJoin() }
    }

    /// The group sets a title: switch in the open player, otherwise open the
    /// player. The same title in the open player does not arrive here; the
    /// session jumps there itself.
    private func titleLoad(_ titleID: String, since: Double) async -> Bool {
        guard let model else { return false }
        async let titleFetch = model.item(id: titleID)
        async let planFetch = model.plan(for: titleID)
        guard let title = await titleFetch, let plan = await planFetch else { return false }
        if let player {
            // Until the player reports in at the next tick, the old title counts as
            // not ready, otherwise "ready" would go out before the new one even loads.
            player.isReady = false
            player.switchTitle(title, plan, since)
        } else {
            wish = PlayRequest(item: title, plan: plan, startAt: since)
        }
        return true
    }

    // MARK: From the player

    /// The player is open and belongs to the group.
    func plugIn(_ s: SharedPlayer) {
        player = s
        let session = self.session
        Task { await session.plugIn(s) }
    }

    /// The player closes. **That is leaving**.
    func detach() {
        player = nil
        let session = self.session
        Task { await session.detach() }
    }

    /// Pause and resume go to the server as a request. The button flips only
    /// when the command comes back, then for everyone at the same time.
    func bitToggle(runningCurrently: Bool) {
        let session = self.session
        Task { await session.bitToggle(runningCurrently: runningCurrently) }
    }

    func bitJump(on seconds: Double) {
        let session = self.session
        Task { await session.bitJump(on: seconds) }
    }

    /// Episode choice in the player, in the group: for everyone.
    func bitTitle(_ titleID: String, since seconds: Double = 0) {
        let session = self.session
        Task { await session.bitTitle(titleID, since: seconds) }
    }

    /// Once per player tick: report buffering.
    func playerTick() {
        let session = self.session
        Task { await session.playerTick() }
    }
}

extension SharedModel {
    /// Does this title belong to what the group is watching?
    func belongsGroup(_ titleID: String) -> Bool {
        status.belongsGroup(titleID)
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

    /// "A and B are watching right now".
    static func wer(_ g: SyncPlayGroup) -> String {
        var watched = Set<String>()
        let names = g.participant.filter { watched.insert($0).inserted }
        guard !names.isEmpty else { return String(localized: "Noch niemand dabei") }
        let list = ListFormatter.localizedString(byJoining: names)
        return names.count == 1 ? String(localized: "\(list) schaut gerade")
                                : String(localized: "\(list) schauen gerade")
    }

    static func stateTextOf(_ z: SyncPlayGroup.Phase?) -> LocalizedStringKey? {
        switch z {
        case .running: "Läuft gerade"
        case .halted: "Angehalten"
        case .waits: "Wartet auf alle"
        case .empty, nil: nil
        }
    }
}
