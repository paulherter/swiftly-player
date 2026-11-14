import Foundation
import JellyfinKit
import Observation
import SwiftlyCore
#if canImport(UIKit)
import UIKit
#endif

/// Polls whether something is playing on another device.
///
/// **Why a holder of its own and not a `.task` in the view.** The question comes
/// up on all four platforms, the badge looks the same everywhere, and the rule
/// behind it lives in ``Takeover`` in the package. What is here is only the
/// polling on a timer, which does not belong in a view that would start over on
/// every redraw.
///
/// Like ``HomeModel`` and ``LibraryModel``.
@MainActor
@Observable
final class TakeoverModel {

    /// Everything that can be taken over, most recent activity first.
    private(set) var offerings: [RemoteSession] = []
    /// The core's polling and hand-over flow (nil while not polling).
    private var flow: SwiftlyCore.HandoffFlowModel?
    /// The last sessions answer, decoded, by id: the core names sessions by id only.
    private var answered: [String: RemoteSession] = [:]
    private var lastAnswer: [RemoteSession] = []
    /// The session being taken over (its id is looked up in the fresh answer).
    private var adopting: RemoteSession?
    #if DEBUG
    private var liveTapped = false
    #endif

    /// The first of them, for when there is only one.
    var offering: RemoteSession? { offerings.first }

    /// More than one? Then the UI asks instead of guessing.
    var multiplePresent: Bool { offerings.count > 1 }

    /// What went wrong, for a message in the view.
    var error: String?

    /// **Someone tapped the badge.**
    ///
    /// The badge lives in ``Kopfziele`` and thus on every root page, but playback
    /// hangs on **one** place, ``MainView``. A flag here is the short path in
    /// between: the view sets it, whoever holds the player clears it. Passing a
    /// closure through the environment would be the same path with more parts.
    var tapped = false

    /// Is a handover running? Disables the button so a second press does not start
    /// two playbacks.
    private(set) var takesOver = false

    private var tick: Task<Void, Never>?

    /// **Five seconds.**
    ///
    /// This used to be ten, on the grounds that the other side's progress report
    /// arrives at the same rate, so asking faster learns nothing new. **That is true
    /// for the place, but not for the case that matters.**
    ///
    /// What is searched for is not a new second count but a session that **did not
    /// exist before**. It registers with the server immediately when someone presses
    /// play over there, not at ten-second intervals. So the whole wait came from
    /// here alone, and it was rightly reported as sluggish.
    ///
    /// It stays a poll that runs while someone is on the home page; hence five and
    /// not one. Two requests per ten seconds are nothing for a home server, ten would
    /// be a kind of diligence that helps nobody.
    ///
    /// **The right way is a second path, not a replacement of this one.** Jellyfin
    /// pushes session changes over the control channel if you subscribe with
    /// `SessionsStart`, and then the offer would appear immediately. The timer then
    /// becomes the **fallback**: while the connection stands, what it reports counts;
    /// if it does not, the timer keeps asking.
    ///
    /// Otherwise a sluggish display is swapped for one that simply freezes on a
    /// dropped connection, and **nobody notices because nothing fails.**
    ///
    /// Rebuilding on that can only be verified once the control channel is not
    /// silent: before, a missing message could not be told from "nothing new".
    static let tickSeconds: Double = 5

    /// If the app is not in front (background, Mac: window inactive or minimized),
    /// the timer rests (`Foreground.wait`) and asks once immediately on return.
    ///
    /// **The rules live in the core** (`HandoffFlowModel`, one state machine: when to ask,
    /// what an answer offers, hint, stop, wait for the exact position). This type only does
    /// the network and the timer and feeds the results back.
    func start(_ model: AppModel) {
        guard tick == nil else { return }
        flow = model.session.flatMap { AppCore.shared.account($0) }
            .map { AppCore.shared.raw.handoffFlow(account: $0) }
        guard let flow else { return }
        _ = try? flow.step(event: .start)
        tick = Task { [weak self] in
            while !Task.isCancelled {
                await self?.inTimesAsk(model)
                await Foreground.wait(seconds: Self.tickSeconds)
            }
        }
    }

    func finish() {
        tick?.cancel()
        tick = nil
        _ = try? flow?.step(event: .finish)
        flow = nil
        offerings = []
    }

    /// What one run of the flow collected for its caller.
    private struct Run {
        var plan: PlaybackPlan?
        var played: (id: String, since: Double)?
        var failed = false
        var clock = ContinuousClock.now
    }

    private func inTimesAsk(_ model: AppModel) async {
        // Whoever is watching does not ask: the core decides (`tick`).
        var run = Run()
        await pump(.tick(playerRuns: PlayState.playerRuns,
                         signedIn: model.remoteServer != nil && model.session != nil),
                   model: model, run: &run)
    }

    /// Feeds an event to the flow, performs what it asks for and feeds the results back, until
    /// nothing is left to do.
    private func pump(_ first: HandoffEvent, model: AppModel, run: inout Run) async {
        guard let flow else { return }
        var pending = [first]
        while !pending.isEmpty {
            let event = pending.removeFirst()
            guard let effects = try? flow.step(event: event) else { continue }
            for effect in effects {
                if let next = await perform(effect, model: model, run: &run) { pending.append(next) }
            }
        }
    }

    private func time(_ was: String, _ run: Run) {
        let d = ContinuousClock.now - run.clock
        let ms = Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
        AppLog.writeOut("[Uebergabe] +\(ms) ms \(was)")
    }

    private func perform(_ effect: HandoffEffect, model: AppModel, run: inout Run) async -> HandoffEvent? {
        switch effect {
        case .ask:
            guard let client = model.remoteServer else { return .askFailed(error: "kein Server") }
            do {
                let (data, list) = try await client.remoteSessionAnswer()
                answered = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                lastAnswer = list
                return .answered(sessionsJson: data, now: Date().timeIntervalSince1970)
            } catch {
                return .askFailed(error: "\(error)")
            }
        case .reportCapabilities:
            try? await model.remoteServer?.reportCapabilities()
        case .offer(let ids):
            offerings = ids.compactMap { answered[$0] }
            #if DEBUG
            // Live runs (`-SwiftlyLiveTakeover`): tap the badge once, as soon as something is offered.
            if !offerings.isEmpty, !liveTapped, ProcessInfo.processInfo.arguments.contains("-SwiftlyLiveTakeover") {
                liveTapped = true
                tapped = true
            }
            #endif
        case .publishSessions:
            if let user = model.session?.userID { PlayOutputs.shared.take(lastAnswer, user: user) }
        case .preload:
            cardImagePreload(model)
        case .log(let line):
            AppLog.writeOut(line)
        case .prepare(let itemId):
            guard let client = model.remoteServer else { return .prepared(plan: false, savedBefore: nil, freshPoint: nil) }
            // Plan, saved position and fresh sessions at the same time.
            async let planFetch = model.plan(for: itemId)
            async let savedFetch = model.item(id: itemId)
            async let sessionsFetch = try? client.remoteSession()
            run.plan = await planFetch
            time("Plan da", run)
            let before = await savedFetch?.userData?.playbackPositionTicks
            let id = adopting?.id
            let fresh = await sessionsFetch?.first { $0.id == id }?.state?.spot
            return .prepared(plan: run.plan != nil, savedBefore: before, freshPoint: fresh)
        case .sendHint(let id):
            do {
                try await model.remoteServer?.handoffHint(an: id, device: Self.ownName)
                time("Hinweis gesendet", run)
                return .hintDone(error: nil)
            } catch {
                return .hintDone(error: "\(error)")
            }
        case .sendStop(let id):
            do {
                try await model.remoteServer?.foreignCommand(.finish, an: id)
                time("Stopp angenommen", run)
                return .stopAccepted
            } catch {
                return .stopFailed(text: readableError(error))
            }
        case .readPosition(let itemId):
            // In steps of 100 ms instead of 250: every oversleeping step delayed the start.
            try? await Task.sleep(for: .milliseconds(100))
            return .position(ticks: await model.item(id: itemId)?.userData?.playbackPositionTicks)
        case .play(let itemId, let since, let unreported, let point):
            time(unreported ? "Stelle nicht gemeldet" : "Stelle gemeldet", run)
            AppLog.writeOut("[Uebernahme] Sitzung \(Int(point)) s → ab \(Int(since)) s")
            run.played = (itemId, since)
        case .noPlan:
            let wo = model.serverName ?? String(localized: "dem Server")
            errorShow(String(localized: "Die Wiedergabe hat nicht geklappt. Von \(wo) kamen keine Daten zum Abspielen."),
                      model: model)
            run.failed = true
        case .showError(let text):
            errorShow(text, model: model)
            run.failed = true
        }
        return nil
    }

    /// Takes over one session: title, position and plan, or `nil` with a message.
    ///
    /// **First check that something starts here, then end it over there.** The other way round
    /// the TV stopped, and if the plan then failed, nothing played anywhere, with no message.
    /// **First the notice, then the stop**, so the sender shows where playback continues. Then
    /// the sender's exact stop position is waited for briefly (`Takeover.startPoint` in the
    /// core). The order is the flow's, see `handoff_flow.rs`.
    func adopt(_ session: RemoteSession,
                     model: AppModel) async -> (item: Item, since: Double, plan: PlaybackPlan)? {
        guard let title = session.running, model.remoteServer != nil, !takesOver, flow != nil else { return nil }
        takesOver = true
        defer { takesOver = false; adopting = nil }
        adopting = session
        answered[session.id] = session
        var run = Run()
        time("Tipp auf \(session.deviceName ?? "?")", run)
        await pump(.adopt(sessionId: session.id), model: model, run: &run)
        guard let played = run.played, let plan = run.plan, !run.failed else { return nil }
        return (title, played.since, plan)
    }

    /// What this device is called in the notice to the sender (shown in their log).
    /// Product names, not translated.
    static var ownName: String {
        #if os(tvOS)
        "Apple TV"
        #elseif os(macOS)
        "Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }

    /// **The card's image**: for episodes the episode image (it shows *where* you
    /// are), otherwise the title's landscape image.
    static func cardImageURL(_ title: Item, model: AppModel) -> URL? {
        if title.seriesId != nil, title.imageTags?["Primary"] != nil {
            return model.episodeImageURL(for: title)
        }
        return model.landscapeImageURL(for: title, width: 1280)
    }

    /// Fetches the offers' images ahead of time so the card does not wait on the
    /// network when tapped.
    private func cardImagePreload(_ model: AppModel) {
        for s in offerings.prefix(2) {
            guard let title = s.running, let url = Self.cardImageURL(title, model: model) else { continue }
            Task { _ = await ImageCache.shared.load(url, border: 1280) }
        }
    }

    /// `error` used to land nowhere; the views do not read it. They display
    /// `errorMessage`.
    private func errorShow(_ text: String, model: AppModel) {
        error = text
        model.errorMessage = text
    }

    /// The same, but directly as a finished ``PlayRequest``.
    ///
    /// **Why this lives here and not in the views.** These six lines stood
    /// character-identical in `Sources/tvOS/MainView.swift` and
    /// `Sources/Shared/HomeView.swift`, from porting the handover from one platform
    /// to the other. Byte-identical copies are exactly what to avoid.
    func wish(for session: RemoteSession, model: AppModel) async -> PlayRequest? {
        guard let (title, since, plan) = await adopt(session, model: model) else { return nil }
        return PlayRequest(item: title, plan: plan, startAt: since)
    }
}

/// **"Übergeben an": the running title from the player to a TV running Swiftly.**
///
/// An action in the player, not a mode: "play" always plays on this device. A
/// remembered output would send every tap to a TV with nothing on the screen in
/// front of the viewer saying so.
///
/// One for the whole app, like ``TileRequest``. **The list comes from
/// ``TakeoverModel``'s poll**, not from a timer of its own. The player stops that
/// poll, so it asks once when it opens (``refresh(_:)``).
///
/// **A TV hands over too**, to another TV: from the living room to the bedroom.
@MainActor
@Observable
final class PlayOutputs {
    static let shared = PlayOutputs()

    /// Devices a film can be handed to right now, see ``PlayTargets``.
    private(set) var targets: [RemoteSession] = []

    private init() {}

    /// From the takeover poll.
    func take(_ sessions: [RemoteSession], user: String) {
        let fresh = PlayTargets.targets(from: sessions, ownDevicesIdentifier: AppModel.deviceID,
                                        ownUserIdentifier: user)
        // Only on a change: every assignment redraws each page that reads the list.
        guard fresh.map(\.id) != targets.map(\.id) else { return }
        AppLog.writeOut("[Abspielen auf] \(fresh.count) Ziele: "
            + fresh.map { PlayTargets.name(of: $0) }.joined(separator: ", "))
        targets = fresh
    }

    /// One question outside the poll, for the player, which stops the poll.
    func refresh(_ model: AppModel) async {
        guard let client = model.remoteServer, let user = model.session?.userID,
              let sessions = try? await client.remoteSession() else { return }
        take(sessions, user: user)
    }

    /// **The current session of the chosen device**, from a fresh list: the one in
    /// the menu may be five seconds old, and the TV may have restarted since.
    ///
    /// `nil` with a message when it is gone or the question failed. Nothing plays
    /// here instead: a film starting on the phone while the viewer looks at the TV
    /// is not what was asked for.
    private func current(_ output: PlayOutput, model: AppModel) async -> RemoteSession? {
        guard let client = model.remoteServer, let user = model.session?.userID else { return nil }
        let sessions: [RemoteSession]
        do {
            sessions = try await client.remoteSession()
        } catch {
            // Not "gone": the server did not answer.
            AppLog.writeOut("[Abspielen auf] Abfrage fehlgeschlagen: \(error)")
            Self.say(readableError(error))
            return nil
        }
        take(sessions, user: user)
        if let session = PlayTargets.session(for: output, in: targets) { return session }
        AppLog.writeOut("[Abspielen auf] \(output.name) nicht mehr da")
        Self.say(String(localized: "„\(output.name)“ ist nicht mehr erreichbar."))
        return nil
    }

    /// **Hands the running title over from the player**: same position, same
    /// version, the tracks that are playing. Only IDs, position and track indices
    /// go out: the TV fetches its own plan with its own profile (``PlayOrder``).
    ///
    /// - Returns: whether the TV took it; only then does the player close.
    func handOver(_ item: Item, plan: PlaybackPlan, at seconds: Double, tracks: TrackIndices,
                  to output: PlayOutput, model: AppModel) async -> Bool {
        let order = PlayOrder(itemID: item.id, start: seconds, mediaSourceID: plan.mediaSourceID,
                              tracks: tracks)
        return await send(order, to: output, model: model)
    }

    /// **Starts a title on the chosen device straight from a detail page or a tile
    /// menu**, without opening the player here. Only the ID and the resume position go
    /// out (nothing at all for a title not begun); version and tracks are left to the
    /// TV, which fetches its own plan (``PlayOrder``).
    func play(_ item: Item, to output: PlayOutput, model: AppModel) async {
        let order = PlayOrder(itemIDs: [item.id], start: item.resumeFrom ?? 0)
        _ = await send(order, to: output, model: model)
    }

    /// The one path to the TV for both ways: fresh session, order, log, message.
    private func send(_ order: PlayOrder, to output: PlayOutput, model: AppModel) async -> Bool {
        guard let client = model.remoteServer,
              let session = await current(output, model: model) else { return false }
        let name = PlayTargets.name(of: session)
        do {
            try await client.playOn(session: session.id, order: order)
        } catch {
            AppLog.writeOut("[Abspielen auf] an \(name) fehlgeschlagen: \(error)")
            Self.say(readableError(error))
            return false
        }
        AppLog.writeOut("[Abspielen auf] \(order.itemID ?? "?") ab \(Int(order.start)) s an \(name)"
            + " · Ton \(order.audioIndex.map(String.init) ?? "—")"
            + " · Untertitel \(order.subtitleIndex.map(String.init) ?? "—")")
        Self.say(String(localized: "Spielt auf „\(name)“"))
        return true
    }

    /// The short strip at the bottom: ``TileRequest`` on iPhone and iPad,
    /// ``TileMessage`` on the Mac.
    static func say(_ text: String) {
        #if os(macOS)
        TileMessage.shared.text = text
        #else
        TileRequest.shared.message = text
        #endif
    }
}

/// How a foreign session is named and pictured.
///
/// **Shared, not per platform.** TV, phone and Mac show the same badge; a second
/// version would drift apart within a week. Exactly the case to avoid.
extension RemoteSession {
    /// "Game of Thrones · S1 E5" or just the movie title.
    ///
    /// Server data, so `String` and not `LocalizedStringKey`: otherwise a movie
    /// title would be looked up as a translation key.
    /// **Now in the package** (``Fremdsitzung/titelzeile``). It used to hang here and
    /// was unreachable for the Linux version, which therefore had its own, shorter
    /// composition.

    /// The symbol for the device. **Which device** it is is decided by
    /// ``Fremdsitzung/geraeteart`` in the package; the mapping must not drift apart.
    /// Which *symbol* stands for it remains the platform's business: SF Symbols here,
    /// Adwaita on Linux.
    var devicesCharacter: String {
        switch devicesKind {
        case .phone:   "iphone"
        case .tablet:    "ipad"
        case .computer:   "laptopcomputer"
        case .tv: "tv"
        case .unknown: "play.tv"
        }
    }
}

