import Foundation
import JellyfinKit

/// **Keeps the synced settings equal across devices** through the Jellyfin account's
/// display preferences: the GTK counterpart of `Sources/Shared/SettingsSyncRun.swift`.
/// The rules (keys, encoding, who wins) are in the package (``SettingsSync``); this class
/// only watches the settings file and talks to the server.
///
/// - Starts at every sign-in and when the window comes to the front, never in the way:
///   everything runs in a task of its own, and a failure (offline, old server, no right) is
///   logged quietly and forgotten.
/// - A local change is noticed when ``Choices/secure()`` saved a different set of synced
///   values; two seconds later the run fetches, compares and writes.
/// - **Only what exists here.** Keys of other devices that this app has no setting for
///   (and Seerr, which Linux does not sync) are never written or removed:
///   ``SettingsSync/fields(for:changed:)`` leaves out what is not given, and the server
///   copy is sent back as received.
///
/// Touched only on GTK's main thread.
final class SettingsSyncRun: @unchecked Sendable {

    weak var app: App?
    private var client: (any MediaServer)?
    private var accountKey: String?
    private var lastSnapshot: [String: String] = [:]
    private var applying = false
    private var running = false
    private var again = false
    private var generation = 0
    private var lastRun = Date.distantPast

    init(app: App) { self.app = app }

    /// The switch in the settings. **On by default.**
    var on: Bool {
        get { app?.selection.syncOn ?? true }
        set {
            guard let app else { return }
            app.selection.syncOn = newValue
            app.selection.secure()
            if newValue { request(after: nil) }
        }
    }

    // MARK: Binding

    /// Every sign-in and account switch.
    func bind(client: (any MediaServer)?, account: String?) {
        Choices.saved = { [weak self] in
            guard let me = self else { return }
            onMainThread { me.saved() }
        }
        self.client = client
        self.accountKey = account
        generation += 1
        lastSnapshot = snapshot()
        if client != nil { request(after: nil) }
    }

    /// The window came to the front.
    func front() {
        guard client != nil, Date().timeIntervalSince(lastRun) > 60 else { return }
        request(after: nil)
    }

    // MARK: Local changes

    /// From ``Choices/secure()``.
    func saved() {
        guard !applying, let app else { return }
        let now = snapshot()
        guard now != lastSnapshot else { return }
        lastSnapshot = now
        let remoteSeen = app.selection.syncRemote.map { Date(timeIntervalSince1970: $0 / 1000) }
        let stamp = SettingsSync.changeTime(now: Date(), lastKnownRemote: remoteSeen)
        app.selection.syncTime = stamp.timeIntervalSince1970 * 1000
        // Written straight to disk; the hook is not called again because the snapshot is equal.
        app.selection.secure()
        if on { request(after: 2) }
    }

    // MARK: Reading the device

    /// Every synced setting this app has, by its synced name. A "next episode" that was
    /// never chosen is left out (it follows the account), and so is a start-row order that
    /// is still the default.
    private func values() -> [String: SettingsSync.Value] {
        guard let s = app?.selection else { return [:] }
        var v: [String: SettingsSync.Value] = [
            "tonSprache": .text(s.audioLanguage),
            "utSprache": .text(s.subtitleLanguage),
            "utAuto": .bool(s.subtitleAutomatic),
            "introAbspannAuto": .bool(s.skipAutomatic),
            "endzeitImPlayer": .bool(s.endTimeInPlayer),
            "vorSek": .int(s.forwardSeconds),
            "zurueckSek": .int(s.backSeconds),
            "titelAlsLogo": .bool(s.titleAsLogo),
            "fortschritt": .bool(s.progressOnTiles),
            "merklisteAn": .bool(s.watchlistShown),
            "alphabetAn": .bool(s.alphabetShown),
            "neuGetrennt": .bool(s.newArrivalsDisconnected),
            "startAus": .list(s.startOut),
            "genreChips": .bool(s.genreChips),
            "startGenres": .list(s.startGenres),
        ]
        v["utAussehen"] = .json(s.subtitleLook.encoded())
        if let chosen = s.nextAutomaticSelected { v["naechsteAuto"] = .bool(chosen) }
        if !s.startRails.isEmpty { v["startReihen"] = .list(s.startRails) }
        if !s.startLibraries.isEmpty, let data = StartLibraries.data(s.startLibraries) { v["startBibliotheken"] = .json(data) }
        return v
    }

    private func snapshot() -> [String: String] { values().mapValues(\.encoded) }

    private var localChanged: Date? {
        app?.selection.syncTime.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    // MARK: Talking to the server

    private func request(after delay: Double?) {
        guard on, client != nil else { return }
        let token = generation
        Task.detached { [self] in
            if let delay { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            onMainThread {
                guard token == self.generation else { return }
                self.drain()
            }
        }
    }

    /// One run at a time; a request that arrives during a run asks for one more.
    private func drain() {
        if running { again = true; return }
        guard on, let client, let account = accountKey else { return }
        running = true
        again = false
        let started = app?.selection.syncTime
        let localChanged = self.localChanged
        let current = values()
        let token = generation
        let other = app?.selection.syncAccount != account
        lastRun = Date()
        Task.detached { [self] in
            let outcome = await Self.run(client: client, localChanged: localChanged,
                                         otherAccount: other, current: current)
            onMainThread {
                self.running = false
                if token == self.generation { self.finish(outcome, account: account, started: started) }
                if self.again { self.again = false; self.request(after: nil) }
            }
        }
    }

    private enum Outcome: Sendable {
        case applied(values: [String: SettingsSync.Value], changed: Date)
        case pushed(stamp: Date)
        case nothing(remote: Date?)
        case skipped
    }

    /// The network part: fetch, decide, write. No state of ours is touched here.
    private static func run(client: any MediaServer, localChanged: Date?, otherAccount: Bool,
                            current: [String: SettingsSync.Value]) async -> Outcome {
        do {
            guard let server = client as? any DisplayPreferencesServer else { return .skipped }
            let copy = try await server.displayPreferences()
            let remote = SettingsSync.remote(from: copy.customPrefs)
            let decision = SettingsSync.decide(remote: remote, localChanged: localChanged,
                                               otherAccount: otherAccount)
            switch decision {
            case .apply:
                guard let changed = remote.changed else { return .nothing(remote: nil) }
                return .applied(values: remote.values, changed: changed)
            case .push:
                guard !current.isEmpty else { return .nothing(remote: remote.changed) }
                let stamp = localChanged ?? SettingsSync.changeTime(now: Date(),
                                                                    lastKnownRemote: remote.changed)
                try await server.saveDisplayPreferences(
                    copy, setting: SettingsSync.fields(for: current, changed: stamp))
                return .pushed(stamp: stamp)
            case .nothing:
                return .nothing(remote: remote.changed)
            }
        } catch {
            AppLog.writeOut("[Abgleich] übersprungen: \(error.localizedDescription)")
            return .skipped
        }
    }

    /// Back on the main thread, with the state read again.
    private func finish(_ outcome: Outcome, account: String, started: Double?) {
        guard let app else { return }
        switch outcome {
        case .applied(let values, let changed):
            // Changed here while the answer was on its way: that change must not be overwritten.
            if app.selection.syncTime != started { request(after: nil); return }
            apply(values, changed: changed)
            app.selection.syncAccount = account
            app.selection.syncRemote = changed.timeIntervalSince1970 * 1000
            app.selection.secure()
            AppLog.writeOut("[Abgleich] Einstellungen vom Server übernommen")
        case .pushed(let stamp):
            app.selection.syncTime = stamp.timeIntervalSince1970 * 1000
            app.selection.syncRemote = stamp.timeIntervalSince1970 * 1000
            app.selection.syncAccount = account
            app.selection.secure()
            AppLog.writeOut("[Abgleich] Einstellungen zum Server geschrieben")
        case .nothing(let remote):
            app.selection.syncAccount = account
            if let remote { app.selection.syncRemote = remote.timeIntervalSince1970 * 1000 }
            app.selection.secure()
        case .skipped:
            break
        }
    }

    // MARK: Taking values over

    /// Takes values from the server into the settings. Only what the server sent and this
    /// app knows; everything else stays as it is.
    private func apply(_ values: [String: SettingsSync.Value], changed: Date) {
        guard let app else { return }
        applying = true
        defer { applying = false }
        var s = app.selection
        // In the order of the list: the language comes before "automatic".
        for entry in SettingsSync.entries {
            guard let value = values[entry.name] else { continue }
            switch (entry.name, value) {
            case ("tonSprache", .text(let t)): s.audioLanguage = t
            case ("utSprache", .text(let t)): s.subtitleLanguage = t
            case ("utAuto", .bool(let b)): s.subtitleAutomatic = b
            case ("utAussehen", .json(let d)): s.subtitleLook = SubtitleLook.read(d)
            case ("naechsteAuto", .bool(let b)): s.nextAutomaticSelected = b
            case ("introAbspannAuto", .bool(let b)): s.skipAutomatic = b
            case ("endzeitImPlayer", .bool(let b)): s.endTimeInPlayer = b
            case ("vorSek", .int(let i)): s.forwardSeconds = i
            case ("zurueckSek", .int(let i)): s.backSeconds = i
            case ("titelAlsLogo", .bool(let b)): s.titleAsLogo = b
            case ("fortschritt", .bool(let b)): s.progressOnTiles = b
            case ("merklisteAn", .bool(let b)): s.watchlistShown = b
            case ("alphabetAn", .bool(let b)): s.alphabetShown = b
            case ("neuGetrennt", .bool(let b)): s.newArrivalsDisconnected = b
            case ("startReihen", .list(let l)): s.startRails = StartRailsEpisode.applicable(stored: l).map(\.rawValue)
            case ("startAus", .list(let l)): s.startOut = l
            case ("genreChips", .bool(let b)): s.genreChips = b
            case ("startGenres", .list(let l)): s.startGenres = l
            case ("startBibliotheken", .json(let d)): s.startLibraries = StartLibraries.read(d)
            default: break
            }
        }
        s.syncTime = changed.timeIntervalSince1970 * 1000
        app.selection = s
        s.secure()
        // What was just written is not a change of the user's.
        lastSnapshot = snapshot()
        // The home rows and tiles read these when they are built.
        app.homeLoad()
    }
}
