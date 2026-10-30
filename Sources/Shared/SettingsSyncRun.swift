import Foundation
import JellyfinKit
import Observation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// **Keeps the synced settings equal across devices** through the Jellyfin account's
/// display preferences. The rules (keys, encoding, who wins) are in the package
/// (`SettingsSync`); this class only watches the device and talks to the server.
///
/// - Starts on every account change (launch, sign-in, switch) and when the app
///   comes to the front, never in the way: everything runs in a task of its own and
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
    @ObservationIgnored private var client: JellyfinClient?
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
                guard let self, Date().timeIntervalSince(self.lastRun) > 60 else { return }
                self.request(after: nil)
            }
        })
    }

    /// From `AppModel.client`'s `didSet`: every sign-in, switch, restore and sign-out.
    func bind(client: JellyfinClient?, session: Session?) {
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
        self.client = session == nil ? nil : client
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
        "seerrSyncZeit|" + SeerrModel.serverForm(session.serverURL)
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

    /// The fields to write for Seerr, or nothing; takes the server's connection over when
    /// it is newer. Only while the Seerr model is on this session's server.
    private func seerrRun(_ prefs: [String: String], session: Session, leaving: Bool) -> [String: String] {
        guard let seerr = model?.seerr, seerr.server == SeerrModel.serverForm(session.serverURL) else { return [:] }
        let store = UserDefaults.standard
        let key = seerrTimeKey(session)
        let mine = (store.object(forKey: key) as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        switch SettingsSync.seerrStep(remote: prefs, localChanged: mine, hasLocal: seerr.access != nil) {
        case .adopt(let access, let changed):
            guard !leaving else { return [:] }
            seerr.adopt(access)
            store.set(changed.timeIntervalSince1970 * 1000, forKey: key)
            AppLog.writeOut("[Abgleich] Seerr vom Server übernommen")
            return [:]
        case .push:
            let stamp = mine ?? Date()
            store.set(stamp.timeIntervalSince1970 * 1000, forKey: key)
            return SettingsSync.seerrFields(seerr.access, changed: stamp)
        case .nothing:
            return [:]
        }
    }

    // MARK: Reading the device

    private func values(for session: Session?) -> [String: SettingsSync.Value] {
        let store = UserDefaults.standard
        let suffix = session.map { "|" + $0.serverURL.absoluteString } ?? ""
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
    }

    /// What the leaving account still had to send, read before the switch.
    private struct Pending { let values: [String: SettingsSync.Value]; let changed: Date? }

    /// `pending`: the account is already being left; then only its pending change goes out,
    /// nothing is taken in and no local stamp is touched (they belong to the new account).
    private func runOnce(client: JellyfinClient, session: Session, leaving pending: Pending? = nil) async {
        let leaving = pending != nil
        let localChanged = pending.map(\.changed) ?? self.localChanged
        lastRun = Date()
        let store = UserDefaults.standard
        let started = store.object(forKey: Self.timeKey) as? Double
        do {
            let copy = try await client.displayPreferences()
            guard leaving || client === self.client else { return }
            let remote = SettingsSync.remote(from: copy.customPrefs)
            if let seen = remote.changed, !leaving {
                store.set(seen.timeIntervalSince1970 * 1000, forKey: Self.remoteKey)
            }
            let account = session.accountKey
            let other = store.string(forKey: Self.accountKey) != account
            var decision = SettingsSync.decide(remote: remote, localChanged: localChanged, otherAccount: other)
            // Changed here while the answer was on its way: that change must not be overwritten.
            if decision == .apply, (store.object(forKey: Self.timeKey) as? Double) != started {
                decision = .push
            }
            // Seerr first, so its fields go out in the same write: two writes from the
            // same copy would undo each other.
            let seerrFields = seerrRun(copy.customPrefs, session: session, leaving: leaving)
            if decision != .push, !seerrFields.isEmpty {
                try await client.saveDisplayPreferences(copy, setting: seerrFields)
                AppLog.writeOut("[Abgleich] Seerr zum Server geschrieben")
                guard leaving || client === self.client else { return }
            }
            if leaving, decision != .push { return }
            switch decision {
            case .apply:
                guard let changed = remote.changed else { break }
                apply(remote.values, changed: changed)
                store.set(account, forKey: Self.accountKey)
                AppLog.writeOut("[Abgleich] Einstellungen vom Server übernommen")
            case .push:
                let current = pending?.values ?? values(for: session)
                guard !current.isEmpty else {
                    if !seerrFields.isEmpty {
                        try await client.saveDisplayPreferences(copy, setting: seerrFields)
                    }
                    if !leaving { store.set(account, forKey: Self.accountKey) }
                    break
                }
                let remoteSeen = store.object(forKey: Self.remoteKey) as? Double
                let stamp = localChanged ?? SettingsSync.changeTime(
                    now: Date(), lastKnownRemote: remoteSeen.map { Date(timeIntervalSince1970: $0 / 1000) })
                try await client.saveDisplayPreferences(
                    copy, setting: SettingsSync.fields(for: current, changed: stamp)
                        .merging(seerrFields) { _, seerr in seerr })
                guard !leaving else {
                    AppLog.writeOut("[Abgleich] Einstellungen des alten Kontos geschrieben")
                    return
                }
                store.set(stamp.timeIntervalSince1970 * 1000, forKey: Self.timeKey)
                store.set(stamp.timeIntervalSince1970 * 1000, forKey: Self.remoteKey)
                store.set(account, forKey: Self.accountKey)
                AppLog.writeOut("[Abgleich] Einstellungen zum Server geschrieben")
            case .nothing:
                store.set(account, forKey: Self.accountKey)
            }
        } catch {
            // Offline, an old server or no right: nothing to tell anyone. The next run
            // (account change, front, next change) tries again.
            AppLog.writeOut("[Abgleich] übersprungen: \(error.localizedDescription)")
        }
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
