import Foundation
import JellyfinKit
import Observation
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
    /// The last reason written, so the same message does not repeat in the log
    /// every ten seconds.
    private var lastReason: String?

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
    /// the timer rests (`Vordergrund.wait`) and asks once immediately on return.
    func start(_ model: AppModel) {
        guard tick == nil else { return }
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
        offerings = []
    }

    private func inTimesAsk(_ model: AppModel) async {
        // **Whoever is watching does not ask.**
        //
        // In the player the picture matters, and the server would have one more request
        // every five seconds to answer. This used to hang on the home page
        // (`.task(id: play == nil)`) and so only applied to playbacks started
        // there. Here it applies to every one.
        guard !PlayState.playerRuns else { return }
        // `model.session` instead of `client.currentSession()`: the client is an actor,
        // and the session already lives on the main actor here.
        guard let client = model.client,
              let user = model.session?.userID else { offerings = []; return }
        let sessions: [RemoteSession]
        do {
            sessions = try await client.remoteSession()
        } catch {
            // **Quiet outwardly, loud in the log.** It asks every ten seconds; an error
            // message on the home page would be noise. But the difference between "nothing
            // is playing" and "the question did not arrive" has to be recorded somewhere,
            // otherwise the next person searches for it from scratch.
            AppLog.writeOut("[Uebernahme] Abfrage fehlgeschlagen: \(error)")
            offerings = []
            return
        }
        if PlayTargets.mustReport(sessions, ownDevicesIdentifier: AppModel.deviceID) {
            AppLog.writeOut("[Abspielen auf] eigene Sitzung fehlt, Fähigkeiten neu gemeldet")
            try? await client.reportCapabilities()
        }
        offerings = Takeover.offerings(from: sessions,
                                       ownDevicesIdentifier: AppModel.deviceID,
                                       ownUserIdentifier: user)
        // **The same answer feeds "Übergeben an"**: a second timer asking the same
        // question for the player's list would double the requests for nothing.
        PlayOutputs.shared.take(sessions, user: user)
        // **Why nothing is offered must be readable.** Five reasons look the same from
        // outside: the badge is simply missing. In release builds this drops out.
        if offerings.isEmpty {
            let grounds = sessions.map { s in
                let wer = s.deviceName ?? s.program ?? "?"
                let why = Takeover.whyNot(s, ownDevicesIdentifier: AppModel.deviceID,
                                                  ownUserIdentifier: user) ?? "taugt"
                return "\(wer): \(why)"
            }
            let row = "[Uebernahme] \(sessions.count) Sitzungen, kein Angebot"
                + (grounds.isEmpty ? "" : " — " + grounds.joined(separator: " · "))
            // **Only on change.** It asks every ten seconds and the answer is almost always
            // the same: "1 sessions, no offer, Mac: ourselves". The line used to appear
            // dozens of times at one-second pace and drowned everything else in the log.
            // Repeating a message that often makes it unreadable.
            if row != lastReason {
                lastReason = row
                AppLog.writeOut(row)
            }
        } else {
            lastReason = nil
            cardImagePreload(model)
        }
    }

    /// Stop the other device and continue here.
    ///
    /// **End it over there first, then start here, and do not swallow the error.**
    /// If it keeps running there while the same starts here, two audio tracks fill
    /// the room and nobody knows why. So if it fails, nothing is started here.
    ///
    /// **End, not pause.** Paused, the connection to the server stays open, the
    /// session remains in the overview, and on the other device the player still
    /// covers everything; it would have to be closed by hand.
    ///
    /// **First check that something starts here, then end it over there.** The other
    /// way round the TV stopped, and if the plan then failed, nothing played
    /// anywhere, with no message.
    ///
    /// **The position after ending:** the session query lags up to ten seconds
    /// behind. The other device reports its exact position when ending; that is
    /// waited for briefly (`Takeover.startPoint`).
    ///
    /// - Returns: title, position and plan, or `nil` with a message.
    /// - Parameter sitzung: which one to take over. With several, the UI asked; with
    ///   one it is simply that one.
    func adopt(_ session: RemoteSession,
                     model: AppModel) async -> (item: Item, since: Double, plan: PlaybackPlan)? {
        guard let title = session.running,
              let client = model.client, !takesOver else { return nil }
        takesOver = true
        defer { takesOver = false }
        // **Each step with its time since the tap.** The card floats until the first
        // frame is up; how long that takes and what it depends on is in the log.
        let clock = ContinuousClock.now
        func time(_ was: String) {
            let d = ContinuousClock.now - clock
            let ms = Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
            AppLog.writeOut("[Uebergabe] +\(ms) ms \(was)")
        }
        time("Tipp auf \(session.deviceName ?? "?")")

        async let planFetch = model.plan(for: title.id)
        async let savedFetch = model.item(id: title.id)
        async let sessionsFetch = try? client.remoteSession()
        guard let plan = await planFetch else {
            let wo = model.serverName ?? String(localized: "dem Server")
            errorShow(String(localized: "Die Wiedergabe hat nicht geklappt. Von \(wo) kamen keine Daten zum Abspielen."),
                         model: model)
            return nil
        }
        time("Plan da")
        let before = await savedFetch?.userData?.playbackPositionTicks
        // The freshest position the session knows; the one from the badge may be a
        // query old.
        let freshValue = await sessionsFetch?.first { $0.id == session.id }?.state?.spot
        let sessionPoint = freshValue ?? session.state?.spot ?? 0

        // **First the notice, then the stop.** Only this way does the sender know its
        // stop is a handover: then its picture leaves as a card and it shows where
        // playback continues. If the notice fails it simply closes as with a stop from
        // the dashboard; the handover itself does not depend on it.
        if Takeover.takesHint(session) {
            do {
                try await client.handoffHint(an: session.id, device: Self.ownName)
                time("Hinweis gesendet")
            } catch {
                AppLog.writeOut("[Uebergabe] Hinweis nicht gesendet: \(error)")
            }
        }
        do {
            try await client.foreignCommand(.finish, an: session.id)
        } catch {
            errorShow(readableError(error), model: model)
            return nil
        }
        time("Stopp angenommen")

        // Wait for the other device's stop, at most one and a half seconds. If nothing
        // comes, the session position applies. In steps of 100 ms instead of 250: every
        // oversleeping step delayed the start.
        var afterwards: Int64?
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(100))
            let now = await model.item(id: title.id)?.userData?.playbackPositionTicks
            if now != before { afterwards = now; break }
        }
        let since = Takeover.startPoint(session: sessionPoint, savedBefore: before,
                                        savedAfterwards: afterwards)
        time(afterwards == nil ? "Stelle nicht gemeldet" : "Stelle gemeldet")
        AppLog.writeOut("[Uebernahme] Sitzung \(Int(sessionPoint)) s, nach Stopp "
            + "\(afterwards.map { String(Int(Double($0) / 10_000_000)) } ?? "—") s → ab \(Int(since)) s")
        // So the badge does not linger for another tick.
        offerings = []
        return (title, since, plan)
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
        if fresh.map(\.id) != targets.map(\.id) {
            AppLog.writeOut("[Abspielen auf] \(fresh.count) Ziele: "
                + fresh.map { PlayTargets.name(of: $0) }.joined(separator: ", "))
        }
        targets = fresh
    }

    /// One question outside the poll, for the player, which stops the poll.
    func refresh(_ model: AppModel) async {
        guard let client = model.client, let user = model.session?.userID,
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
        guard let client = model.client, let user = model.session?.userID else { return nil }
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
        guard let client = model.client,
              let session = await current(output, model: model) else { return false }
        let order = PlayOrder(itemID: item.id, start: seconds, mediaSourceID: plan.mediaSourceID,
                              tracks: tracks)
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

