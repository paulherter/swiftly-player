import Foundation
import JellyfinKit
import Observation
import SwiftlyCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// **Keeps the synced settings equal across devices** through the Jellyfin account's
/// display preferences. The rules (keys, encoding, who wins) are in the package
/// (`SettingsSync`); this class only watches the device and talks to the server.
///
/// - Starts on every account change (launch, sign-in, switch), when the app
///   comes to the front, every 20 seconds while it is in front, before a title starts, never in the way: everything runs in a task of its own and
///   a failure (offline, old server, no right) is logged quietly and forgotten.
/// - A local change is noticed in `UserDefaults` itself, so the three settings the views
///   keep with `@AppStorage` are covered like the ones in `AppModel`.
/// - After a change it waits two seconds, then fetches, compares and writes.
@MainActor
@Observable
final class SettingsSyncRun {

    private static let onKey = "einstellungenSync"
    private static let timeKey = "einstellungenSyncZeit"
    private static let accountKey = "einstellungenSyncKonto"
    private static let remoteKey = "einstellungenSyncServer"

    /// The switch in the settings. **On by default.**
    var on: Bool {
        didSet {
            UserDefaults.standard.set(on, forKey: Self.onKey)
            if on { request(after: nil) }
        }
    }

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var client: (any DisplayPreferencesServer)?
    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var lastSnapshot: [String: String] = [:]
    @ObservationIgnored private var applying = false
    @ObservationIgnored private var waiting: Task<Void, Never>?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var again = false
    @ObservationIgnored private var lastRun = Date.distantPast
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        on = UserDefaults.standard.object(forKey: Self.onKey) as? Bool ?? true
    }

    /// Once, at the end of `AppModel.init`.
    func attach(_ model: AppModel) {
        self.model = model
        model.seerr.changed = { [weak self] in self?.seerrChanged() }
        lastSnapshot = snapshot()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.defaultsChanged() }
        })
        #if canImport(UIKit)
        let front = UIApplication.didBecomeActiveNotification
        #else
        let front = NSApplication.didBecomeActiveNotification
        #endif
        observers.append(center.addObserver(forName: front, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Date().timeIntervalSince(self.lastRun) > Self.frontGap else { return }
                self.request(after: nil)
            }
        })
        // A change made on another device (the subtitle look, the languages) reaches a running app within a
        // minute, not only at launch or when the window comes to the front.
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollEvery))
                guard let self else { return }
                self.pollOnce()
            }
        }
    }

    /// The window coming to the front fetches when the last fetch is older than this (seconds).
    nonisolated static let frontGap: TimeInterval = 10
    /// While the app is in front a fetch runs this often (seconds), and a title that starts fetches when the
    /// last one is older than ``startGap``.
    nonisolated static let pollEvery: Double = 20
    nonisolated static let startGap: TimeInterval = 10
    @ObservationIgnored private var poll: Task<Void, Never>?

    private func pollOnce() {
        #if canImport(UIKit)
        guard UIApplication.shared.applicationState == .active else { return }
        #else
        guard NSApplication.shared.isActive else { return }
        #endif
        guard on, client != nil, !running, waiting == nil,
              Date().timeIntervalSince(lastRun) > Self.pollEvery - 5 else { return }
        request(after: nil)
    }

    /// From `AppModel.client`'s `didSet`: every sign-in, switch, restore and sign-out.
    func bind(client: (any MediaServer)?, session: Session?) {
        // A change that is still waiting belongs to the account that is leaving; it goes
        // out now instead of being lost or sent under the new name.
        if waiting != nil, on, let old = self.client, let oldSession = self.session {
            waiting?.cancel()
            waiting = nil
            // Read now: the defaults are shared, and the new account's run may apply its
            // values before this one's answer is back.
            let pending = Pending(values: values(for: oldSession), changed: localChanged)
            Task { await self.runOnce(client: old, session: oldSession, leaving: pending) }
        }
        self.client = session == nil || client?.capabilities.contains(.settingsSync) != true ? nil : client as? any DisplayPreferencesServer
        self.session = session
        // The per-server entry has another device key now; that is no change by the user.
        lastSnapshot = snapshot()
        if self.client != nil { request(after: nil) }
    }

    // MARK: Local changes

    private func defaultsChanged() {
        guard !applying, model != nil else { return }
        let now = snapshot()
        guard now != lastSnapshot else { return }
        lastSnapshot = now
        let store = UserDefaults.standard
        let remoteSeen = store.object(forKey: Self.remoteKey) as? Double
        let stamp = SettingsSync.changeTime(now: Date(),
                                            lastKnownRemote: remoteSeen.map { Date(timeIntervalSince1970: $0 / 1000) })
        store.set(stamp.timeIntervalSince1970 * 1000, forKey: Self.timeKey)
        if on { request(after: .seconds(2)) }
    }

    // MARK: Seerr

    /// When the Seerr connection last changed here, per server; see `SettingsSync.seerrStep`.
    private func seerrTimeKey(_ session: Session) -> String {
        "seerrSyncZeit|" + session.serverIdentity
    }

    private func seerrChanged() {
        guard let session else { return }
        let store = UserDefaults.standard
        let remoteSeen = store.object(forKey: Self.remoteKey) as? Double
        let stamp = SettingsSync.changeTime(now: Date(),
                                            lastKnownRemote: remoteSeen.map { Date(timeIntervalSince1970: $0 / 1000) })
        store.set(stamp.timeIntervalSince1970 * 1000, forKey: seerrTimeKey(session))
        if on { request(after: .seconds(1)) }
    }

    /// The Seerr connection of this session's server as the core takes it (JSON, `nil` = none), and
    /// when it last changed here. Only while the Seerr model is on this server; otherwise neither,
    /// so the run can neither push nor take a connection for the wrong server.
    private func seerrState(session: Session) -> (json: String?, changed: Double?, onServer: Bool) {
        guard let seerr = model?.seerr, seerr.server == session.serverIdentity else { return (nil, nil, false) }
        let json = seerr.access.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        let ms = UserDefaults.standard.object(forKey: seerrTimeKey(session)) as? Double
        return (json, ms.map { $0 / 1000 }, true)
    }

    /// What the core says about Seerr: take the server's connection over, or remember the time of the push.
    private func seerrDone(_ outcome: SeerrSyncOutcome, session: Session, onServer: Bool, leaving: Bool) {
        guard onServer, let seerr = model?.seerr else { return }
        let key = seerrTimeKey(session)
        let store = UserDefaults.standard
        switch outcome {
        case .adopt(let json, let changed):
            guard !leaving else { return }
            seerr.adopt(json.isEmpty ? nil : try? JSONDecoder().decode(SeerrAccess.self, from: Data(json.utf8)))
            store.set(changed * 1000, forKey: key)
            AppLog.writeOut("[Abgleich] Seerr vom Server übernommen")
        case .pushed(let changed):
            store.set(changed * 1000, forKey: key)
            AppLog.writeOut("[Abgleich] Seerr zum Server geschrieben")
        case .nothing:
            break
        }
    }

    // MARK: Reading the device

    private func values(for session: Session?) -> [String: SettingsSync.Value] {
        let store = UserDefaults.standard
        let suffix = session?.serverSuffix ?? ""
        return SettingsSync.collect(serverSuffix: suffix) { key, kind in
            switch kind {
            case .bool: return (store.object(forKey: key) as? Bool).map { .bool($0) }
            case .int: return (store.object(forKey: key) as? Int).map { .int($0) }
            case .text: return store.string(forKey: key).map { .text($0) }
            case .list: return store.stringArray(forKey: key).map { .list($0) }
            case .json: return store.data(forKey: key).map { .json($0) }
            }
        }
    }

    private func snapshot() -> [String: String] { values(for: session).mapValues(\.encoded) }

    private var localChanged: Date? {
        (UserDefaults.standard.object(forKey: Self.timeKey) as? Double)
            .map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    // MARK: Talking to the server

    private func request(after delay: Duration?) {
        guard on, client != nil else { return }
        waiting?.cancel()
        waiting = Task { [weak self] in
            if let delay {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await self?.drain()
        }
    }

    /// One run at a time; a request that arrives during a run asks for one more.
    private func drain() async {
        waiting = nil
        if running { again = true; return }
        running = true
        repeat {
            again = false
            guard on, let client, let session else { break }
            await runOnce(client: client, session: session)
        } while again
        running = false
        let done = idleWaiters.values
        idleWaiters = [:]
        for waiter in done { waiter.resume() }
    }

    @ObservationIgnored private var idleWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// **Before a title starts:** if a run is under way (the launch's or the account's first one), wait for its end
    /// so the saved subtitle look, language and the rest are the ones of the other devices when the player reads
    /// them. At most `timeout`: a slow or silent server never holds a title back. Nothing under way: returns at once.
    func settled(timeout: Duration = .seconds(2)) async {
        guard on, client != nil else { return }
        // Nothing under way and the last fetch is not fresh: fetch now, so a look or language changed on another
        // device a minute ago is the one this title starts with (it used to arrive at the next launch).
        if !running, waiting == nil, Date().timeIntervalSince(lastRun) > Self.startGap { request(after: nil) }
        guard running || waiting != nil else { return }
        let id = UUID()
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            idleWaiters[id] = waiter
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.idleWaiters.removeValue(forKey: id)?.resume()
            }
        }
    }

    /// What the leaving account still had to send, read before the switch.
    private struct Pending { let values: [String: SettingsSync.Value]; let changed: Date? }

    /// `pending`: the account is already being left; then only its pending change goes out,
    /// nothing is taken in and no local stamp is touched (they belong to the new account).
    ///
    /// The run itself (fetch, decide, write, Seerr in the same write) is the core's
    /// `SettingsSyncModel.runWithSeerr`; this only reads the device before and keeps the stamps after.
    private func runOnce(client: any DisplayPreferencesServer, session: Session, leaving pending: Pending? = nil) async {
        let leaving = pending != nil
        let localChanged = pending.map(\.changed) ?? self.localChanged
        lastRun = Date()
        #if DEBUG
        LiveRun.note(["kind": "sync-run", "what": "start", "leaving": leaving])
        #endif
        let store = UserDefaults.standard
        let started = store.object(forKey: Self.timeKey) as? Double
        guard let account = AppCore.shared.account(session),
              let core = try? AppCore.shared.raw.settingsSyncModel(account: account, locale: AppCore.language)
        else { return }
        let current = pending?.values ?? values(for: session)
        let seerr = seerrState(session: session)
        let accountKey = session.accountKey
        let other = store.string(forKey: Self.accountKey) != accountKey
        let round: SettingsSyncRound
        do {
            round = try await core.runWithSeerr(
                local: current.map { SyncSetting(name: $0.key, value: $0.value.encoded) },
                localChanged: localChanged.map(\.timeIntervalSince1970),
                remoteSeen: (store.object(forKey: Self.remoteKey) as? Double).map { $0 / 1000 },
                otherAccount: other, now: Date().timeIntervalSince1970,
                seerr: seerr.json, seerrChanged: seerr.changed)
        } catch {
            AppLog.writeOut("[Abgleich] übersprungen: \(error.localizedDescription)")
            return
        }
        guard leaving || client === self.client else { return }
        if !leaving, round.remoteChanged > 0 { store.set(round.remoteChanged * 1000, forKey: Self.remoteKey) }
        seerrDone(round.seerr, session: session, onServer: seerr.onServer, leaving: leaving)
        #if DEBUG
        LiveRun.note(["kind": "sync-run", "what": "answer", "result": "\(round.settings)".prefix(24).description])
        #endif
        switch round.settings {
        case .unreachable:
            // Offline, an old server or no right: nothing to tell anyone. The next run
            // (account change, front, next change) tries again.
            AppLog.writeOut("[Abgleich] übersprungen: Server antwortet nicht")
        case .apply(let remote, let changed):
            guard !leaving else { return }
            // Changed here while the answer was on its way: that change must not be overwritten. The run
            // starts again; the device is newer then and goes out.
            if (store.object(forKey: Self.timeKey) as? Double) != started { again = true; return }
            apply(Self.values(of: remote), changed: Date(timeIntervalSince1970: changed))
            store.set(accountKey, forKey: Self.accountKey)
            AppLog.writeOut("[Abgleich] Einstellungen vom Server übernommen")
        case .pushed(let changed):
            guard !leaving else {
                AppLog.writeOut("[Abgleich] Einstellungen des alten Kontos geschrieben")
                return
            }
            store.set(changed * 1000, forKey: Self.timeKey)
            store.set(changed * 1000, forKey: Self.remoteKey)
            store.set(accountKey, forKey: Self.accountKey)
            AppLog.writeOut("[Abgleich] Einstellungen zum Server geschrieben")
        case .nothing:
            if !leaving { store.set(accountKey, forKey: Self.accountKey) }
        }
    }

    /// The core's text values back to typed ones; what does not fit its kind is dropped.
    nonisolated static func values(of settings: [SyncSetting]) -> [String: SettingsSync.Value] {
        var out: [String: SettingsSync.Value] = [:]
        for s in settings {
            guard let entry = SettingsSync.entries.first(where: { $0.name == s.name }),
                  let value = SettingsSync.Value.decode(s.value, as: entry.kind) else { continue }
            out[s.name] = value
        }
        return out
    }

    private func apply(_ values: [String: SettingsSync.Value], changed: Date) {
        applying = true
        model?.applySynced(values)
        applying = false
        let store = UserDefaults.standard
        store.set(changed.timeIntervalSince1970 * 1000, forKey: Self.timeKey)
        // What the model just wrote is not a change of the user's.
        lastSnapshot = snapshot()
    }
}

extension AppModel {
    /// Takes values from the server into the model and the stored settings. Only what
    /// the server sent; everything else stays as it is.
    func applySynced(_ values: [String: SettingsSync.Value]) {
        let store = UserDefaults.standard
        // In the order of the list: the language comes before "automatic", which it
        // would otherwise switch on by itself.
        for entry in SettingsSync.entries {
            guard let value = values[entry.name] else { continue }
            switch (entry.name, value) {
            case ("tonSprache", .text(let s)): audioLanguage = s
            case ("utSprache", .text(let s)): subtitleLanguage = s
            case ("utAuto", .bool(let b)): subtitleAutomatic = b
            case ("utAussehen", .json(let d)): subtitleLook = SubtitleLook.read(d)
            case ("naechsteAuto", .bool(let b)): nextAutomatic = b
            case ("vorSek", .int(let i)): forwardSeconds = i
            case ("zurueckSek", .int(let i)): backSeconds = i
            case ("fortschritt", .bool(let b)): progressOnTiles = b
            case ("merklisteAn", .bool(let b)): watchlistShown = b
            case ("alphabetAn", .bool(let b)): alphabetShown = b
            case ("neuGetrennt", .bool(let b)): newAccessDisconnected = b
            case ("genreChips", .bool(let b)): genreChips = b
            case ("startReihen", .list(let l)): startRails = StartRailsEpisode.applicable(stored: l)
            case ("startAus", .list(let l)): startOut = Set(l.compactMap(StartRail.init(rawValue:)))
            case ("startGenres", .list(let l)): startGenres = l
            case ("startBibliotheken", .json(let d)): startLibraries = StartLibraries.read(d)
            // The ones the views keep with `@AppStorage` (intro skip, remaining time as
            // end time, title as logo): the stored value is the setting.
            case (let name, .bool(let b)): store.set(b, forKey: name)
            case (let name, .int(let i)): store.set(i, forKey: name)
            case (let name, .text(let s)): store.set(s, forKey: name)
            default: break
            }
        }
    }
}
