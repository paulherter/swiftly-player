import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import JellyfinKit

/// **The facade Android sees.**
///
/// Holds what `AppModel` holds on Apple: the client and the session. Kotlin holds only UI
/// state. Answers cross the bridge as JSON, fully assembled, so no rule is implemented a
/// second time in Kotlin.
///
/// **A class with a lock, not an actor:** jextract wraps classes, and calls arrive from
/// coroutines on arbitrary threads.
public final class Kern: @unchecked Sendable {
    private let devicesIdentifier: String
    private let program: String
    private let devicesName: String
    private let version: String
    private let barrier = NSLock()
    private var _client: JellyfinClient?
    private var _addresses: ImageAddress?
    private var _session: Session?
    private var _playback: Playback?
    /// The chapters of the current version (``Kapitelleiste/brauchbar(_:)``). Empty until
    /// ``chapterLoad()`` returns, and reset on every title change.
    private var _chapter: [Chapter] = []
    /// The episode switch of the open player. New for each open; `close` is final.
    private var _episodesSwitch = EpisodeSwitch()
    /// The run state last reported to the server. VLC's report goes out once per change.
    private var _reportedPaused = false
    /// The client of a server being added (`AppModel.onboarding`). The running session stays
    /// untouched; if adding fails, nothing has changed.
    private var _onboarding: JellyfinClient?
    /// Which address check currently applies (see ``Pruefstand`` in the package). A new check
    /// invalidates the previous one; its late answer no longer sets a client.
    private var _checkState = CheckState()
    /// The running Quick Connect flow. The secret part never leaves Swift.
    private var _quickConnect: LoginCode?
    /// The running wait for approval: the code it applies to, and how to cancel it.
    private var _quickConnectWait: (code: String, task: @Sendable () -> Void)?
    private var _quickConnectRemaining = 0
    /// The counter state of the tech badge, reset per title.
    private var _counter: Counter?
    /// Seerr is a bonus: without access there is no client, and nothing on the pages hints at it.
    private var _seerr: SeerrClient?
    /// The socket Jellyfin uses to send commands. Without it there are no buttons in the dashboard.
    private var _remote: RemoteControl?
    private let remoteStore = CommandStore()
    /// **Watch together:** the session from the package, one for the lifetime of the app
    /// (`SharedModel` on Apple). Created on first access (``gemeinsam``).
    private var _shared: SyncPlaySession?
    /// The cleanup after the last set. The next one waits for it, like `sharedChain` on Linux.
    private var _sharedChain: Task<Void, Never>?
    private let sharedPanel = StatusPanel()
    /// The group sets a title and no player is attached: Kotlin opens one.
    private let sharedRequest = WaitCompartment()
    private var _sharedPlayer: CorePlayer?
    private var _sharedMark = 0
    private var _sharedTickRuns = false
    private var _sharedStatus = SyncPlayStatus()
    private var _sharedError: String?
    private var _sharedErrorNumber = 0
    private var _sharedAccepted = 0
    /// **No next episode inside a group.** Otherwise everyone would advance on their own and the
    /// group would drift apart (iOS `lookUp`). Applies while a player is attached.
    private var _withoutNext = false
    private var _alwaysDirectPlay = true
    private var _megabit = 0
    /// **The current account's downloads as Kotlin holds them.** Used for "Next episode", the
    /// sections and the watch state without a server. Kotlin passes them in after every change
    /// (`downloadsKnown`); the list itself stays in Kotlin.
    private var _downloads: [DownloadItem] = []
    private var _downloadFolder = ""
    /// The downloads' network observer reports no network at all. Then nothing is asked first.
    private var _withoutNetwork = false
    /// What accumulated at each stop. Kotlin collects it (`stoppsProcess`).
    private var _stopps: [StopRemember] = []
    /// Never two catch-up passes at once; otherwise the same position would be sent twice.
    private var _reportLaterRuns = false
    /// **The next episode, prepared in the last minutes** (`Prebuffer`, like `EpisodePreparation`
    /// on iOS): plan, sections and the episode after it, with the time. ``episodeSwitch(id:position:)``
    /// takes it instead of asking.
    private var _prepared: (w: Playback, moment: Date)?
    /// Which episode was already started. Once per episode, even if it fails.
    private var _preparation: String?
    /// A counter per row of the track layer (`audio`, `subtitle`) for press-and-hold.
    private var _holdCounter: [String: Delay.HoldCounter] = [:]
    /// **Seconds actually watched**, for "Support Swiftly" (`WatchTimeCounter` in the package). Fed by
    /// ``playbackTick``, stored by Kotlin through ``supportWatchTake(usage:force:)`` (`Support.swift`).
    let watch = WatchBox()

    /// What is reported to the server as the limit (`AppModel.profileBitrate`; computed in the package).
    private var profileBitrate: Int {
        barrier.lock(); defer { barrier.unlock() }
        return BitratesLimit.of(alwaysDirectPlay: _alwaysDirectPlay, megabit: _megabit)
    }

    /// From the settings, at start and on every change.
    public func playbackSelection(alwaysDirectPlay: Bool, megabit: Int) {
        barrier.lock(); _alwaysDirectPlay = alwaysDirectPlay; _megabit = megabit; barrier.unlock()
    }

    /// The running playback, what `PlayerScreen` holds on iOS: plan, sections, next episode and
    /// the state of the tick. Kotlin holds only picture and fingers.
    private struct Playback: Sendable {
        let item: Item
        let plan: PlaybackPlan
        var sections: [Segment]
        var next: Item?
        var state = PlaybackTick.Snapshot()
        let start = Date()
        /// "Skip intro" / "Next episode" over the picture. New per episode, because every switch sets
        /// a new `Playback` (so `OfferingLayer.newEpisode` is not needed).
        var layer: OfferingLayer = {
            // **The card waits while the controls are open**: it goes away, the countdown pauses, and
            // it returns when they close.
            var e = OfferingLayer()
            e.cardWaitsControls = true
            return e
        }()
        /// Since when VLC has been paused, for ``Pausenruecksprung`` (``resumeTarget(position:inGroup:)``).
        var pausedSince: Date?
        /// External subtitles of the plan (Kotlin sets the token), the running tracks as Jellyfin
        /// index for the reports, and a chosen file whose track VLC does not report yet. New per
        /// episode, as on Apple at every `play(url:)`.
        var files: [SubtitleFile] = []
        var tracks = TrackIndices()
        var currentSubtitle: Int?
        /// The stored image of a download for the media controls; otherwise the one from the server.
        var image: String?
    }

    /// A stop, for the download's watch state and the pending catch-up report of the same title.
    private struct StopRemember: Sendable {
        let itemID: String
        let account: String
        let ticks: Int64
        let moment: Date
        let sent: Bool
    }

    public init(devicesIdentifier: String, devicesName: String, version: String, program: String) {
        self.devicesIdentifier = devicesIdentifier
        self.program = program
        self.devicesName = devicesName
        self.version = version
        messages = Self.reportRail(rows: logRows, probe: reportProbe)
        // The package's own lines (remote control, SyncPlay …), as on Apple
        // (`AppModel`: `TrackSupport.write`). Without this they were lost on Android.
        let rows = logRows
        TrackSupport.write = { row in rows.write(row); LogRing.shared.append(row) }
    }

    private var client: JellyfinClient? {
        get { barrier.lock(); defer { barrier.unlock() }; return _client }
    }
    private var addresses: ImageAddress? {
        get { barrier.lock(); defer { barrier.unlock() }; return _addresses }
    }
    private func checkBegin(_ address: String) -> CheckMark {
        barrier.lock(); defer { barrier.unlock() }
        return _checkState.begin(address)
    }

    private func checkApplies(_ mark: CheckMark) -> Bool {
        barrier.lock(); defer { barrier.unlock() }
        return _checkState.applies(mark)
    }

    @discardableResult
    private func checkComplete(_ mark: CheckMark) -> Bool {
        barrier.lock(); defer { barrier.unlock() }
        return _checkState.complete(mark)
    }

    private func setDown(_ c: JellyfinClient?, _ a: ImageAddress?, _ s: Session? = nil) {
        barrier.lock(); defer { barrier.unlock() }
        let alt = _client
        _client = c; _addresses = a; _session = s
        // **Every client change ends "Watch together"** (switch, sign-out, sign-in): leave with the
        // old account's client, then fetch the new one's right (`AppModel`).
        // **In sequence**, not one free task per set: sign-out sets twice in quick succession
        // (`signOff`, then `sessionSet` for the next account). If the first `finish` ran after
        // the second `rightFetch`, the next account would lose its SyncPlay right; the other way
        // round, the `Leave` would go out in the next account's name.
        if let gemeinsam = _shared, alt !== c {
            let before = _sharedChain
            _sharedChain = Task {
                await before?.value
                await gemeinsam.finish(oldClient: alt)
                if c != nil { await gemeinsam.rightFetch() }
            }
        }
    }

    /// The profile picture of the signed-in account; same URL as `AppModel.userImageURL()`
    /// on Apple. `nil` without a session.
    public func userImage(border: Int) -> String? {
        barrier.lock(); defer { barrier.unlock() }
        guard let s = _session, let a = _addresses else { return nil }
        return a.user(s.userID, border: border)?.absoluteString
    }

    private func newClient(_ url: URL, _ session: Session? = nil) -> JellyfinClient {
        JellyfinClient(baseURL: url, deviceID: devicesIdentifier, deviceName: devicesName,
                       clientVersion: version, program: program, session: session)
    }

    // MARK: Custom headers (issue #4)

    /// **Before the first request**, at start, from the vault. The table applies to every request
    /// to this server that goes through the core (API, tile sheets, control channel). For images
    /// and downloads Kotlin asks ``ownHeadersFields(address:)``. Like `AppModel.ownHeadersLoad`.
    public static func ownHeadersLoad(panel: String) {
        OwnHeaders.load(panel.isEmpty ? nil : Data(panel.utf8))
    }

    /// The whole table to store in the vault; `"{}"` if nothing is set.
    public static func ownHeadersStore() -> String {
        String(decoding: OwnHeaders.store(), as: UTF8.self)
    }

    /// What is set for exactly this base address, for "Advanced". JSON `[{"name","wert"}]`.
    public static func ownHeadersRegistered(address: String) -> String {
        guard let url = URL(string: address) else { return "[]" }
        return encoded(OwnHeaders.registered(for: url))
    }

    /// Set (not store; Kotlin does that with ``ownHeadersStore()``). Empty removes the server.
    public static func ownHeadersSet(address: String, headers: String) {
        guard let url = URL(string: address) else { return }
        OwnHeaders.setDown(headersRead(headers), for: url)
    }

    /// The headers for a request to this address, as a JSON object: `{}` without an entry or for
    /// any other host. For Coil (OkHttp) and the downloads.
    public static func ownHeadersFields(address: String) -> String {
        guard let url = URL(string: address) else { return "{}" }
        let fields = OwnHeaders.fields(for: url)
        return fields.isEmpty ? "{}" : encoded(fields)
    }

    /// Through the same gate as when sending, for "Save", which only appears on a change.
    public static func ownHeadersCleaned(headers: String) -> String {
        encoded(OwnHeaders.cleaned(headersRead(headers)))
    }

    /// Does Swiftly set this header itself? Then the row says so instead of silently doing nothing.
    public static func headerLocked(name: String) -> Bool { OwnHeaders.isLocked(name) }

    /// Names only, for the log. **Never the values.**
    public static func ownHeadersNames(address: String) -> String {
        guard let url = URL(string: address) else { return "keine" }
        return OwnHeaders.names(OwnHeaders.registered(for: url))
    }

    private static func headersRead(_ json: String) -> [OwnHeader] {
        (try? JSONDecoder().decode([OwnHeader].self, from: Data(json.utf8))) ?? []
    }

    /// Like `AppModel.connectWith`: set the "Advanced" headers **before the first request**. If
    /// the server does not answer, the previous state comes back, so nothing is left behind for
    /// an address where nothing answers. Storing happens only after the answer (Kotlin,
    /// ``ownHeadersStore()``).
    private static func withHeaders<T>(_ headers: [OwnHeader], for url: URL,
                                      _ perform: () async throws -> T) async throws -> T {
        let new = OwnHeaders.cleaned(headers)
        guard !new.isEmpty else { return try await perform() }
        let before = OwnHeaders.registered(for: url)
        OwnHeaders.setDown(new, for: url)
        do { return try await perform() } catch {
            OwnHeaders.setDown(before, for: url)
            throw error
        }
    }

    // MARK: Language

    /// **Call before the first text**, at app start. `folder` holds the package's `.lproj`
    /// folders (unpacked from the assets), `language` is the device language. See `PackageLanguage`
    /// in the package.
    public static func packageLanguageSet(folder: String, language: String) {
        #if os(Android)
        PackageLanguage.folder = folder
        PackageLanguage.language = language
        #endif
    }

    // MARK: Connect and sign in

    /// Like `AppModel.connect(to:)`: normalize the address, and retry once with `http` if `https`
    /// gets no answer. Answer: `{"name","version","adresse"}`.
    /// `headers` (JSON `[{"name","wert"}]`) come from "Advanced". Empty for almost everyone, and
    /// then what is already set for this address stays.
    public func linkUp(address: String, headers: String) async throws -> String {
        return try await throwReadable { () async throws -> String in
            guard let url = AppModelURLNormalizer.normalize(address) else { throw CoreError.address(address) }
            var candidates = [url]
            if let different = AppModelURLNormalizer.reversed(url) { candidates.append(different) }
            var lastOne: Error = CoreError.address(address)
            let ownOnes = Self.headersRead(headers)
            let mark = checkBegin(address)
            for candidate in candidates {
                let c = newClient(candidate)
                do {
                    let info = try await Self.withHeaders(ownOnes, for: candidate) { try await c.checkReachability() }
                    // Superseded: a newer check is running; this one sets nothing.
                    guard checkComplete(mark) else { throw CancellationError() }
                    setDown(c, ImageAddress(base: candidate, token: nil))
                    return try json(ServerResponse(name: info.serverName ?? candidate.host() ?? "",
                                                  version: info.version ?? "",
                                                  address: candidate.absoluteString))
                } catch {
                    lastOne = error
                    if !AddressCheck.fallbackPaysOff(to: error) { break }
                }
            }
            checkComplete(mark)
            throw lastOne
        }
    }

    /// Answer: the session as JSON. Kotlin stores it encrypted and passes it back to
    /// ``sessionSet(json:)`` at the next start.
    public func signIn(user: String, password: String) async throws -> String {
        return try await throwReadable { () async throws -> String in
            guard let c = client else { throw CoreError.notConnected }
            let s = try await c.authenticate(username: user, password: password)
            let new = newClient(s.serverURL, s)
            setDown(new, ImageAddress(base: s.serverURL, token: s.accessToken), s)
            return try json(s)
        }
    }

    /// Like `AppModel` after restoring: is the token still valid? `false` **only** for 401/403
    /// (`sessionAppliesStill`). Without a network it means "unknown", and nobody is signed out.
    public func sessionApplies() async -> Bool {
        guard let c = client else { return true }
        return await c.sessionAppliesStill()
    }

    public func sessionSet(json text: String) throws {
        let s = try JSONDecoder().decode(Session.self, from: Data(text.utf8))
        setDown(newClient(s.serverURL, s), ImageAddress(base: s.serverURL, token: s.accessToken), s)
    }

    // MARK: Quick Connect and additional servers

    private func loginClient(_ newServer: Bool) -> JellyfinClient? {
        barrier.lock(); defer { barrier.unlock() }
        return newServer ? _onboarding : _client
    }

    /// Checks another server without touching the running session. Answer as ``verbinden(address:)``.
    public func onboardingConnect(address: String, headers: String) async throws -> String {
        return try await throwReadable { () async throws -> String in
            guard let url = AppModelURLNormalizer.normalize(address) else { throw CoreError.address(address) }
            var candidates = [url]
            if let different = AppModelURLNormalizer.reversed(url) { candidates.append(different) }
            var lastOne: Error = CoreError.address(address)
            let ownOnes = Self.headersRead(headers)
            let mark = checkBegin(address)
            defer { checkComplete(mark) }
            for candidate in candidates {
                let c = newClient(candidate)
                do {
                    let info = try await Self.withHeaders(ownOnes, for: candidate) { try await c.checkReachability() }
                    guard checkApplies(mark) else { throw CancellationError() }
                    barrier.lock(); _onboarding = c; barrier.unlock()
                    return try json(ServerResponse(name: info.serverName ?? candidate.host() ?? "", version: info.version ?? "",
                                                  address: candidate.absoluteString))
                } catch {
                    lastOne = error
                    if !AddressCheck.fallbackPaysOff(to: error) { break }
                }
            }
            throw lastOne
        }
    }

    public func onboardingCancel() {
        barrier.lock(); _onboarding = nil; _quickConnect = nil; barrier.unlock()
    }

    /// Signs in at the server being added. The session comes back; it becomes active only via `sessionSet`.
    public func onboardingSignIn(user: String, password: String) async throws -> String {
        return try await throwReadable { () async throws -> String in
            guard let c = loginClient(true) else { throw CoreError.notConnected }
            return try json(try await c.authenticate(username: user, password: password))
        }
    }

    /// Fetches a code, at the connected or the added server. Answer: the code.
    public func quickConnectStart(newServer: Bool) async throws -> String {
        return try await throwReadable { () async throws -> String in
            guard let c = loginClient(newServer) else { throw CoreError.notConnected }
            do {
                let preGait = try await c.quickConnectStart()
                barrier.lock(); _quickConnect = preGait; barrier.unlock()
                return preGait.code
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // swift-java turns the error into `String(describing:)`, so a network error reads
                // `Error Domain=NSURLErrorDomain ...`. Kotlin shows the message, so it must be readable here.
                throw CoreText(coreErrorText(error))
            }
        }
    }

    /// **Waits for approval: `QuickConnectWait` from the package, no longer in Kotlin.** The
    /// deadline runs on the clock, polling is periodic and immediate on return to the app; a
    /// network error does not end the wait. The remaining time is in ``quickConnectRest()``.
    ///
    /// Answer: `released` (then ``quickConnectSignIn(newServer:)``), empty if cancelled,
    /// otherwise the sentence for the user (`QuickConnectDeadline.endText`).
    public func quickConnectWait(newServer: Bool) async -> String {
        barrier.lock(); let preGait = _quickConnect; barrier.unlock()
        guard let c = loginClient(newServer), let preGait else {
            return QuickConnectDeadline.endText(last: .expired)
        }
        let task = Task { [self] () -> String in
            for await event in c.quickConnectWait(preGait) {
                switch event {
                case let .rest(seconds):
                    barrier.lock(); _quickConnectRemaining = seconds; barrier.unlock()
                case .released:
                    return "freigegeben"
                case let .end(last):
                    barrier.lock(); _quickConnectRemaining = 0; barrier.unlock()
                    return QuickConnectDeadline.endText(last: last)
                }
            }
            return ""
        }
        barrier.lock()
        _quickConnectRemaining = QuickConnectDeadline.seconds
        _quickConnectWait?.task()
        _quickConnectWait = (preGait.code, { task.cancel() })
        barrier.unlock()
        return await task.value
    }

    /// Seconds until the deadline, for display. Set by ``quickConnectWait(newServer:)``.
    public func quickConnectRest() -> Int {
        barrier.lock(); defer { barrier.unlock() }
        return _quickConnectRemaining
    }

    /// The page is closed: stop polling, or a late approval would sign you in unexpectedly.
    /// Only if the wait for `code` is still running; a new code has its own poll.
    public func quickConnectWaitEnd(code: String) {
        barrier.lock(); defer { barrier.unlock() }
        guard let w = _quickConnectWait, w.code == code else { return }
        w.task()
        _quickConnectWait = nil
    }

    /// The approved code becomes the session. On the connected server it applies immediately, as after ``anmelden(user:password:)``.
    public func quickConnectSignIn(newServer: Bool) async throws -> String {
        return try await throwReadable { () async throws -> String in
            barrier.lock(); let preGait = _quickConnect; barrier.unlock()
            guard let c = loginClient(newServer), let preGait else { throw CoreError.notConnected }
            let s: Session
            do { s = try await c.signInWithQuickConnect(preGait) } catch { throw CoreText(coreErrorText(error)) }
            barrier.lock(); _quickConnect = nil; barrier.unlock()
            if !newServer { setDown(newClient(s.serverURL, s), ImageAddress(base: s.serverURL, token: s.accessToken), s) }
            return try json(s)
        }
    }

    /// `[seconds, tick]` from `QuickConnectDeadline`, one source for all platforms.
    public static func quickConnectDeadline() -> String {
        encoded([QuickConnectDeadline.seconds, QuickConnectDeadline.tick])
    }

    // MARK: Accounts (the rules live in `AccountBundle`)

    private static func readBundle(_ raw: String) -> AccountBundle? {
        try? JSONDecoder().decode(AccountBundle.self, from: Data(raw.utf8))
    }
    private static func sessionRead(_ raw: String) -> Session? {
        try? JSONDecoder().decode(Session.self, from: Data(raw.utf8))
    }

    /// Adds a session to the bundle: the same account is replaced, a new one is added and becomes active.
    public static func bundleRecord(session: String, bundle: String) -> String {
        guard let s = sessionRead(session) else { return bundle }
        return encoded(AccountBundle.record(s, in: readBundle(bundle)).bundle)
    }

    public static func bundleSwitch(bundle: String, identifier: String) -> String {
        guard var b = readBundle(bundle) else { return bundle }
        b.switchTo(toward: identifier)
        return encoded(b)
    }

    /// Without the account; empty if it was the last one.
    public static func bundleRemoved(bundle: String, identifier: String) -> String {
        guard let new = readBundle(bundle)?.removed(identifier) else { return "" }
        return encoded(new)
    }

    /// The current session as JSON; empty if the bundle is not readable.
    public static func bundleActive(bundle: String) -> String {
        readBundle(bundle).map { encoded($0.activeOne) } ?? ""
    }

    public static func bundleActiveId(bundle: String) -> String {
        readBundle(bundle)?.activeOne.accountKey ?? ""
    }

    /// Migration: the old single session as a bundle.
    public static func bundleFromSession(session: String) -> String {
        sessionRead(session).map { encoded(AccountBundle($0)) } ?? ""
    }

    /// For the account cards: per server its accounts, the active one marked, with picture.
    public static func bundleOverview(bundle: String) -> String {
        guard let b = readBundle(bundle) else { return "[]" }
        let active = b.activeOne.accountKey
        return encoded(b.server.map { url in
            let accounts = b.accounts(on: url)
            return ServerCardsResponse(
                address: url.absoluteString, host: url.host() ?? url.absoluteString,
                active: accounts.contains { $0.accountKey == active },
                accounts: accounts.map { s in
                    AccountResponse(identifier: s.accountKey, name: s.userName, active: s.accountKey == active,
                                 image: ImageAddress(base: s.serverURL, token: s.accessToken).user(s.userID, border: 120)?.absoluteString)
                })
        })
    }

    // MARK: Home

    /// Finished rows in the configured order. `stored`/`aus` are the names from the settings
    /// (like `startRails`/`startOut` on Apple).
    public func home(disconnected: Bool, stored: [String], from: [String],
                           filmLibrary: String, seriesLibrary: String,
                           genres: [String], asChips: Bool, libraries: String) async throws -> String {
        return try await throwReadable { () async throws -> String in
            guard let c = client, let a = addresses else { throw CoreError.notConnected }
            // The chosen libraries and collections (`StartLibraries`, tolerant reader), fetched
            // together with the fixed rows.
            let choice = StartLibraries.read(Data(libraries.utf8))
            async let libraryState: [Home.LibraryRail] = choice.isEmpty ? [] :
                HomeLoader.libraryRails(from: c, choice: choice)
            // Without a remembered choice the loader looks for the library of its kind itself and
            // otherwise falls back to the query without a library (`HomeLoader.new`), as on
            // Linux and Apple.
            let movies = filmLibrary.isEmpty ? nil : filmLibrary
            let seriesList = seriesLibrary.isEmpty ? nil : seriesLibrary
            let state = await HomeLoader.load(from: c, .init(
                disconnected: disconnected, filmLibrary: movies, seriesLibrary: seriesList,
                genres: asChips ? nil : genres))
            // **The badge only on the rows tvOS shows it on.** `HomeView.Streifen` (continue watching,
            // next episode) does not have it; only the row builder in `TitleRails.swift` (`Rail`)
            // does, for new additions, new movies/series and the genre rows. Otherwise Kotlin would
            // have to reimplement this exception itself.
            let content: [StartRail: (landscape: Bool, new: Bool, mark: Bool, items: [Item])] = [
                .continueWatching: (true, false, false, state.continueWatching ?? []),
                .nextEpisode: (false, false, false, state.nextEpisode ?? []),
                .newArrivals: (false, true, true, state.recent ?? []),
                .newMovies: (false, true, true, state.newMovies ?? []),
                .newSeries: (false, true, true, state.newSeries ?? []),
            ]
            var rails: [RailsResponse] = StartRailsEpisode
                .visible(stored: stored, from: Set(from), disconnected: disconnected)
                .compactMap { r in
                    guard let (landscape, new, mark, items) = content[r], !items.isEmpty else { return nil }
                    return RailsResponse(titleKey: r.railsTitle, name: nil, landscape: landscape,
                                         tiles: items.map { tile($0, newAccess: new, withMark: mark, a) })
                }
            // Between the fixed rows and the genre rows, in the order of the choice.
            let je = Dictionary((await libraryState).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            rails += choice.compactMap { w in
                guard let r = je[w.id] else { return nil }
                return RailsResponse(titleKey: nil, name: w.name, landscape: false,
                                     tiles: r.items.map { tile($0, newAccess: false, withMark: true, a) },
                                     library: w.id, collection: w.collection)
            }
            rails += state.genreRails.map {
                RailsResponse(titleKey: nil, name: $0.name, landscape: false,
                              tiles: $0.items.map { tile($0, newAccess: false, withMark: true, a) })
            }
            return try json(HomeResponse(rails: rails, disrupted: state.disrupted))
        }
    }

    /// The same lines as `HomeView.Tile` on iPhone: `newArrivalsRow` in the new-additions
    /// rows, otherwise `episodeCode`, both from the package. The badge comes from the same
    /// `DisplayRules.tileMark` as `gridTile(_:_:)`.
    ///
    /// **`detailsRow`/`remainingTime`/`watched` for the home header zone**: the same data as
    /// `HeaderInfo.detailsRow`/`RemainingTimeMark` on tvOS. They come ready in every tile, so
    /// Kotlin does not need a second request on every focus change (the facade speaks in
    /// finished answers).
    private func tile(_ i: Item, newAccess: Bool, withMark: Bool, _ a: ImageAddress) -> TileResponse {
        let (mark, figure): (String?, Int) = withMark ? {
            switch DisplayRules.tileMark(art: i.type, seasons: i.childCount,
                                             watched: i.userData?.played,
                                             openEpisodes: i.userData?.unplayedItemCount) {
            case .watched?: return ("gesehen", 0)
            case .opened(let n)?: return ("offen", n)
            case .seasons(let n)?: return ("staffeln", n)
            case .none: return (nil, 0)
            }
        }() : (nil, 0)
        var details: [String] = []
        if i.type == "Episode", let abbreviation = i.episodeCode { details.append(abbreviation) }
        if let year = i.productionYear { details.append(String(year)) }
        if let seconds = i.runtimeSeconds, seconds > 0 { details.append(runtime(seconds)) }
        return TileResponse(
            id: i.id, name: i.seriesName ?? i.name, type: i.type ?? "",
            subline: newAccess ? i.newArrivalsRow : i.episodeCode,
            poster: ImageSelection.portrait(i, addresses: a)?.absoluteString,
            landscape: ImageSelection.landscape(i, addresses: a)?.url.absoluteString,
            progress: i.watchedShare, mark: mark, markCount: figure,
            detailsRow: details.isEmpty ? nil : details.joined(separator: " · "),
            remainingTime: i.remainingTimeText, continueWatchingRow: i.continueWatchingRow, watched: i.isWatched,
            episodeName: i.type == "Episode" ? i.name : nil,
            // **Android TV only** (`TvContinueWatchingShelf.kt`, Watch Next row): the progress display
            // there wants real milliseconds, not just the fraction; otherwise the system launcher shows
            // an invented remaining time. tvOS does not need this: its Top Shelf (`ShelfProvider.swift`)
            // only knows `playbackProgress`, a fraction.
            runtimeSeconds: i.runtimeSeconds, positionSeconds: i.resumeFrom,
            // **Android TV header zone only.** `HeaderInfo` on tvOS shows rating and certification on
            // the home page just as on the detail page (it reads straight from the `Item`), and the
            // description was not in the answer at all.
            rating: i.communityRating, sharing: i.officialRating, description: i.description,
            backdrop: Kern.backdrop(i, episode: nil, addresses: a))
    }

    // MARK: Library

    /// The server name for the line under the title; empty if it names none.
    public func serverName() async throws -> String {
        return try await throwReadable { () async throws -> String in
            guard let c = client else { throw CoreError.notConnected }
            return try await c.publicSystemInfo().serverName ?? ""
        }
    }

    /// One page of a library; the same query as `AppModel.items(in:art:sorting:filter:since:)`.
    /// `sorting`/`filter` are the `rawValue`s from the package; unknown values fall back to the default.
    public func libraryPage(library: String, art: String, sorting: String, filter: String,
                                since: Int, count: Int) async throws -> String {
        return try await throwReadable { () async throws -> String in
            guard let c = client, let a = addresses else { throw CoreError.notConnected }
            let s = Sorting(rawValue: sorting) ?? .name
            let f = LibraryFilter(rawValue: filter) ?? .all
            let answer = try await c.items(parentID: library, limit: count, startIndex: since,
                                            sortBy: s.inputField, sortOrder: s.bearing,
                                            filters: f.jellyfinFilter, isWatched: f.isWatched,
                                            recursive: LibraryGenre.recursive(toward: art),
                                            includeItemTypes: LibraryGenre.types(toward: art))
            return try json(GridPagesResponse(title: answer.items.map { gridTile($0, a) },
                                                total: answer.totalRecordCount))
        }
    }

    // MARK: Title

    /// Everything for the title page in one go (`ItemDetailView.task`): title and playback plan
    /// in parallel. Similar items and extras come separately (``titleField(id:)``) so the page
    /// does not wait for them.
    public func title(id: String) async throws -> String {
        return try await throwReadable { () async throws -> String in
            guard let c = client, let a = addresses else { throw CoreError.notConnected }
            let limit = profileBitrate
            async let freshValue = c.item(id: id)
            async let planned = try? c.playbackPlan(for: id, profile: .vlc(maxBitrate: limit))
            let i = try await freshValue
            let p = await planned
            let file = p?.source.map { q -> FileResponse in
                let tracks = FileDetails.subtitleTracks(q)
                return FileResponse(
                    container: FileDetails.container(q),
                    video: FileDetails.videoTrack(q).map { FileDetails.video($0, q) },
                    audio: Array((q.mediaStreams ?? []).filter { $0.type == "Audio" }.prefix(2).map(\.short)),
                    subtitle: FileDetails.subtitle(tracks), hasSubtitle: !tracks.isEmpty)
            }
            func peopleImage(_ person: Person) -> String? {
                let u: URL? = a.construct(itemID: person.id, mark: person.primaryImageTag, mass: .atMostHigh(220))
                return u?.absoluteString
            }
            let since = i.resumeFrom
            // **Year and runtime without genre.** The TV does not show the genre in this line
            // (`DetailHeader.detailsRow` on tvOS), unlike `secondaryLine` for the phone. Same parts as
            // there, minus the third.
            let yearRuntime = [i.productionYear.map { String($0) },
                                i.runtimeSeconds.flatMap { $0 > 0 ? runtime($0) : nil }]
                .compactMap { $0 }.joined(separator: " · ")
            return try json(TitleResponse(
                id: i.id, name: i.name, type: i.type ?? "", secondaryLine: i.secondaryLine,
                yearRuntime: yearRuntime,
                headerImage: ImageSelection.headerWithFallback(i, episode: nil, addresses: a)?.absoluteString,
                logo: ImageSelection.logo(i, addresses: a)?.absoluteString,
                rating: i.communityRating, sharing: i.officialRating,
                planPresent: p != nil, lossless: p?.isLossless ?? false, method: p.map { $0.method.rawValue },
                resumeFrom: since, resumeText: since.map { timeText($0) },
                remainingTime: i.remainingTimeText, progress: i.userData?.playedPercentage.map { $0 / 100 },
                description: i.description, direction: i.direction,
                actors: Array(i.actors.prefix(12)).map {
                    PersonResponse(id: $0.id, name: $0.name, role: $0.role, image: peopleImage($0))
                },
                remembered: i.userData?.isFavorite ?? false, watched: i.userData?.played ?? false,
                trailer: i.remoteTrailers?.first?.url.map { "\($0)" }, file: file,
                backdrop: Kern.backdrop(i, episode: nil, addresses: a)))
        }
    }

    // MARK: Series

    /// The series page (`SeriesDetailView.load()` with `SeasonTarget`). If `id` is an **episode**,
    /// it is fetched fresh (a tile can carry a stale `seasonId`), its series is loaded and its
    /// season preselected.
    ///
    /// Preselection via `SeasonSelectionRule.choose` as on Apple: the episode's season, the episode's
    /// number, the watch state's season, the watch state's number, first. **The number counts**:
    /// the server sometimes omits `SeasonId`, and an ID-only comparison silently fell back to
    /// the first season.
    public func series(id: String) async throws -> String {
        return try await throwReadable { () async throws -> String in
            guard let c = client, let a = addresses else { throw CoreError.notConnected }
            let firstOne = try await c.item(id: id)
            var hintID: String?
            var hintNumber: Int?
            let series: Item
            if firstOne.type == "Episode", let seriesIdentifier = firstOne.seriesId {
                hintID = firstOne.seasonId
                hintNumber = firstOne.parentIndexNumber
                series = try await c.item(id: seriesIdentifier)
            } else {
                series = firstOne
            }
            async let opened = c.stateInSeries(series.id)
            async let fetched = try? c.seasons(seriesID: series.id)
            let state = await opened
            let seasons = await fetched ?? []
            // From the package: first the hint (ID, then number), then the watch state. A separate chain
            // here checked the watch state's ID before the hint's number; an episode without `SeasonId`
            // then showed the running season instead of its own.
            let selected = SeasonSelectionRule.choose(from: seasons, hintID: hintID,
                                                   hintNumber: hintNumber, state: state)
            // **The plan arrives separately** (`plan(id:)`), as on iOS after the watch state:
            // `PlaybackInfo` takes seconds for files the server has not probed yet, and the whole page
            // waited for it. That made some series appear instantly and others not.
            // The cast of the episode that plays next; otherwise the series' cast.
            let folks = (state?.actors.isEmpty == false ? state?.actors : nil) ?? series.actors
            return try json(SeriesResponse(
                id: series.id, name: series.name,
                year: series.productionYear.map { String($0) },
                // A season with its name; otherwise the number. `childCount` only while the list is missing.
                seasonRow: seasons.count == 1 ? seasons.first?.name : nil,
                seasonCount: seasons.count == 1 ? nil : (seasons.isEmpty ? series.childCount : seasons.count),
                genres: series.genres.flatMap { $0.isEmpty ? nil : $0.prefix(2).joined(separator: ", ") },
                // `state` is the next or first episode, the same one iOS looks for as the substitute.
                headerImage: ImageSelection.headerWithFallback(series, episode: state, addresses: a)?.absoluteString,
                logo: ImageSelection.logo(series, addresses: a)?.absoluteString,
                rating: series.communityRating, sharing: series.officialRating, description: series.description,
                remembered: series.userData?.isFavorite ?? false, watched: series.userData?.played ?? false,
                trailer: series.remoteTrailers?.first?.url.map { "\($0)" },
                planPresent: false, lossless: false, method: nil,
                state: state.map { f in
                    StateResponse(id: f.id, resume: (f.userData?.playbackPositionTicks ?? 0) > 0,
                                 remainingTime: f.remainingTimeText, progress: f.userData?.playedPercentage.map { $0 / 100 },
                                 season: f.parentIndexNumber, episode: f.indexNumber, since: f.resumeFrom)
                },
                buttonText: Item.seriesButton(episode: state, loads: false),
                seasons: seasons.map { SeasonResponse(id: $0.id, name: $0.name) },
                selected: selected?.id,
                actors: folks.map { p in
                    let u: URL? = a.construct(itemID: p.id, mark: p.primaryImageTag, mass: .atMostHigh(220))
                    return PersonResponse(id: p.id, name: p.name, role: p.role, image: u?.absoluteString)
                },
                backdrop: Kern.backdrop(series, episode: state, addresses: a)))
        }
    }

    /// **The backdrop for Android TV: one URL for home, movie and series page.**
    ///
    /// Mirrors `HomeView.backdropsURL` and `DetailView`/`SeriesView` on tvOS, which use
    /// `landscapeImageURL(for:width: 1600) ?? headerImageURL(for:)` on **every** one of the three pages.
    /// Previously home read `landscape` (600 wide, for the tile) and the detail page `headerImage`
    /// (1200 wide, different chain): two URLs for the same picture, pixelated on home, no image
    /// cache hit on opening, and `TvImageReason` computed its own, sometimes different tint for the
    /// second URL. 1600 fits the backdrop on a 1080p TV (590 dp = 1180 px).
    static func backdrop(_ item: Item, episode: Item?, addresses a: ImageAddress) -> String? {
        (ImageSelection.landscape(item, addresses: a, width: 1600)?.url
            ?? ImageSelection.headerWithFallback(item, episode: episode, addresses: a))?.absoluteString
    }

    /// The episodes of a season, rows like `EpisodesRow`: "3. Name", remaining time or runtime,
    /// the bar only while unwatched.
    public func episodes(series: String, season: String) async throws -> String {
        return try await throwReadable { () async throws -> String in
            guard let c = client else { throw CoreError.notConnected }
            let list = try await c.episodes(seriesID: series, seasonID: season.isEmpty ? nil : season)
            var rows: [EpisodesResponse] = []
            for f in list {
                let watched = f.userData?.played ?? false
                let time: String? = DisplayRules.runtimeShow(seconds: f.runtimeSeconds)
                    ? (f.remainingTimeText ?? "\(Int(capped: (f.runtimeSeconds ?? 0) / 60)) min") : nil
                let image = await c.imageURL(for: f, maxHeight: 220)
                rows.append(EpisodesResponse(
                    id: f.id, title: f.indexNumber.map { "\($0). \(f.name)" } ?? f.name, subline: time,
                    image: image?.absoluteString,
                    progress: watched ? nil : f.userData?.playedPercentage.map { $0 / 100 }, watched: watched,
                    since: f.resumeFrom,
                    // **Raw parts for the TV.** The tile there carries the catalog format "F2 · Title"
                    // (`EpisodesStrip.headerLine` on tvOS), the phone keeps "2. Title". Hence extra fields
                    // here instead of changing `title`/`subline`, which would alter both platforms.
                    name: f.name, number: f.indexNumber,
                    runtimeMin: (f.runtimeSeconds ?? 0) > 0 ? Int(capped: (f.runtimeSeconds ?? 0) / 60) : nil,
                    remainingTime: f.remainingTimeText))
            }
            return try json(rows)
        }
    }

    /// The episodes of the running season, from inside the player (`Folgenblatt` on tvOS). Series
    /// and season come from the loaded title itself, so Kotlin does not need to carry its own
    /// IDs. Empty without running playback or for a movie (no `seriesId`).
    public func playbackEpisodes() async throws -> String {
        return try await throwReadable { () async throws -> String in
            barrier.lock(); let item = _playback?.item; barrier.unlock()
            guard let item, let series = item.seriesId else { return "[]" }
            return try await episodes(series: series, season: item.seasonId ?? "")
        }
    }

    /// Only the playback plan, for the file line, delivered later. Empty if there is none.
    public func plan(id: String) async -> String {
        guard let c = client else { return "{}" }
        let planned = (try? await c.playbackPlan(for: id, profile: .vlc(maxBitrate: profileBitrate))) ?? nil
        guard let p = planned else { return "{}" }
        return Self.encoded(PlanResponse(lossless: p.isLossless, method: p.method.rawValue))
    }

    /// **Trickplay preview while seeking**, mirrors `TrickplayImages`/`Trickplay` (package).
    /// Unlike there, Kotlin fetches the tile sheets itself via Coil (plain images); here only
    /// the computation lives: whether any exist, their grid, and a sheet's URL. Empty without
    /// running playback or without trickplay on the server.
    public func trickplayDetail() async -> String {
        guard let c = client, let w = lockRead({ _playback }),
              let t = await c.trickplay(itemID: w.item.id, mediaSourceID: w.plan.mediaSourceID)
        else { return "{}" }
        return Self.encoded(TrickplayReply(width: t.width, height: t.height, tilesWide: t.tilesWide,
                                             tilesUp: t.tilesUp, count: t.count, interval: t.interval))
    }

    /// The URL of a tile sheet; empty without running playback.
    public func trickplayAddress(width: Int, sheet: Int) async -> String {
        guard let c = client, let w = lockRead({ _playback }) else { return "" }
        return await c.trickplayURL(itemID: w.item.id, mediaSourceID: w.plan.mediaSourceID,
                                    width: width, sheet: sheet)?.absoluteString ?? ""
    }

    /// **Chapters of the current version**, mirrors `AppModel.chapter(fuer:source:)`. Fetches
    /// them from the server and keeps them for ``chapterBar(dauer:width:mindestbreite:)`` and
    /// ``chapterName(at:)``; returns their count. 0 without chapters, without a server or
    /// without running playback, in which case the bar is a single piece. Once per title (and version).
    public func chapterLoad() async -> Int {
        barrier.lock(); _chapter = []; let w = _playback; barrier.unlock()
        guard let c = client, let w else { return 0 }
        let found = await c.chapter(itemID: w.item.id, mediaSourceID: w.plan.mediaSourceID)
        barrier.lock(); defer { barrier.unlock() }
        // Another title in the meantime: the chapters no longer belong to it.
        guard let now = _playback, now.item.id == w.item.id,
              now.plan.mediaSourceID == w.plan.mediaSourceID else { return 0 }
        _chapter = found
        return found.count
    }

    /// **The pieces of the timeline** (`ChapterBar.pieces`) and the cuts the slider snaps to
    /// (`snapCuts`, in seconds), as JSON `{"stuecke":[[from,until,x,width],...],"fang":[...]}`:
    /// `from`/`until` as fraction 0...1, `x`/`width` the frame on the bar (`Piece.rahmen`, the gap
    /// split in halves with the neighbors). `width`, `minWidth` and `gap` in dp. Without
    /// chapters one piece across the full width and no snap.
    public func chapterBar(duration: Double, width: Double, minWidth: Double, gap: Double) -> String {
        let chapter = lockRead { _chapter }
        let pieces = ChapterBar.pieces(limits: ChapterBar.limits(chapter, duration: duration),
                                            duration: duration, width: width, minWidth: minWidth)
        return Self.encoded(ChapterBarsResponse(
            pieces: pieces.map { s in
                let r = s.frameRect(width: width, gap: gap)
                return [s.from, s.until, r.x, r.width]
            },
            snap: ChapterBar.snapCuts(pieces, duration: duration, width: width)))
    }

    /// The name of the chapter at a position (`ChapterBar.chapter(at:in:)`), empty without
    /// chapters. From the server, untranslated.
    public func chapterName(at spot: Double) -> String {
        ChapterBar.chapter(at: spot, in: lockRead { _chapter })?.name ?? ""
    }

    /// The piece of the bar containing a fraction (`ChapterBar.piece(at:in:)`), `-1` without
    /// a fraction. The same pieces as ``chapterBar(dauer:width:mindestbreite:)``.
    public func chapterPiece(at share: Double, duration: Double, width: Double, minWidth: Double) -> Int {
        let chapter = lockRead { _chapter }
        let pieces = ChapterBar.pieces(limits: ChapterBar.limits(chapter, duration: duration),
                                            duration: duration, width: width, minWidth: minWidth)
        return ChapterBar.piece(at: share, in: pieces) ?? -1
    }

    // MARK: Account and server

    /// Name and version of the server, for profile and settings.
    public func serverInfo() async throws -> String {
        return try await throwReadable { () async throws -> String in
            guard let c = client else { throw CoreError.notConnected }
            let info = try await c.publicSystemInfo()
            return try json(ServerResponse(name: info.serverName ?? "", version: info.version ?? "", address: ""))
        }
    }

    /// Signs out at the server and forgets the session. Kotlin clears the storage.
    public func signOff() async {
        if let c = client { await c.signOff() }
        setDown(nil, nil, nil)
    }

    /// Approves another device's code (`QuickConnectView`). Empty means done.
    /// "Who is watching?": the public users, without sign-in. If the server turned the list off,
    /// it is empty; then people type.
    public func publicUser(newServer: Bool) async -> String {
        barrier.lock(); let c = newServer ? _onboarding : _client; barrier.unlock()
        guard let c, let list = try? await c.publicUser() else { return "[]" }
        var answer: [AccountResponse] = []
        for b in list {
            let image = await c.userImage(b, border: 180)
            answer.append(AccountResponse(identifier: b.id, name: b.name, active: false, image: image?.absoluteString))
        }
        return Self.encoded(answer)
    }

    public func quickConnectShare(code: String) async -> String {
        await handleRequest { try await $0.quickConnectShare(code: code) }
    }

    /// The server's genres, for "Add genre".
    public func genres() async throws -> String {
        return try await throwReadable { () async throws -> String in
            guard let c = client else { throw CoreError.notConnected }
            return try json(try await c.genres())
        }
    }

    // MARK: Settings (the values live in the package)

    public static func bitrateLevels() -> String {
        encoded(Bitrate.levels.map { SelectionResponse(value: String($0.value), text: Bitrate.text($0.value)) })
    }

    public static func span() -> String { encoded(Span.levels.map(\.value)) }

    /// With an empty label "As the file" (audio), otherwise that label as first entry (subtitles: "Off").
    public static func languages(from: String) -> String {
        encoded((from.isEmpty ? LanguageSelection.all : LanguageSelection.all(from: from)).map { SelectionResponse(value: $0.value, text: $0.name) })
    }

    public static func bufferLevels() -> String {
        encoded(BufferLevel.allCases.map { BufferResponse(value: $0.rawValue, text: $0.name, network: $0.networkLeadMilliseconds) })
    }


    /// The home rows in the current order, only those matching the new-additions setting.
    /// `text` is the German list name; Kotlin translates it.
    public static func startRails(stored: [String], disconnected: Bool) -> String {
        encoded(StartRailsEpisode.applicable(stored: stored).filter { $0.fits(disconnected: disconnected) }
            .map { SelectionResponse(value: $0.rawValue, text: $0.listsName) })
    }

    public static func startRailShifted(was: String, um: Int, stored: [String], disconnected: Bool) -> String {
        guard let rail = StartRail(rawValue: was) else { return encoded(stored) }
        return encoded(StartRailsEpisode.shifted(rail, um: um, stored: stored, disconnected: disconnected))
    }

    /// With sorted keys, so the same bundle is always the same string.
    private static func encoded<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    // MARK: Home rows from libraries

    /// What is offered as its own home row (`AppModel.startSelection`): the account's libraries and
    /// collections, minus what is already chosen (`selected` = stored choice as JSON).
    /// Answer: `[{"id","name","sammlung"}]`.
    public func startSelection(selected: String) async throws -> String {
        return try await throwReadable { () async throws -> String in
            guard let c = client else { throw CoreError.notConnected }
            let viewList = try await viewList(c)
            await offeringLoad()
            let collections = directory(c)?.all.map(\.item) ?? []
            let free = StartLibraries.pick(
                libraries: viewList.filter { StartLibraries.selectable($0) },
                collections: collections,
                selected: StartLibraries.read(Data(selected.utf8)))
            return try json(free.map { StartLibrary($0) })
        }
    }

    // MARK: Genre

    /// The titles of a genre (`GenreView`): up to 200, newest first, movies and series.
    public func genre(name: String) async throws -> String {
        return try await throwReadable { () async throws -> String in
            guard let c = client, let a = addresses else { throw CoreError.notConnected }
            guard let title = await c.title(genre: name, limit: 200) else { throw URLError(.cannotLoadFromNetwork) }
            return try json(title.map { gridTile($0, a) })
        }
    }

    // MARK: Watchlist

    /// One page of the watchlist (`AppModel.remembered`): favorites across all libraries
    /// (recursive, **always with types**; without them empty virtual folders came back as titles),
    /// the same tiles as the library. `genre` is `Merkgattung.art`, empty means both.
    public func watchlist(genre: String, sorting: String, since: Int, count: Int) async throws -> String {
        return try await throwReadable { () async throws -> String in
            guard let c = client, let a = addresses else { throw CoreError.notConnected }
            let art = RememberGenre.toward(art: genre.isEmpty ? nil : genre)
            let s = Sorting(rawValue: sorting) ?? .latest
            // Once per work (`JellyfinClient.rememberedItems`), counted in works.
            let answer = try await c.rememberedItems(types: art.types, sortBy: s.inputField, sortOrder: s.bearing,
                                                    startIndex: since, limit: count)
            let title = since == 0 ? ListRules.withoutDouble(answer.items) : answer.items
            return try json(GridPagesResponse(title: title.map { gridTile($0, a) }, total: answer.totalRecordCount))
        }
    }

    /// "Movies & Series", "Movies", "Series"; `value` is the kind, empty for both.
    public static func savedGenres() -> String {
        encoded(RememberGenre.allCases.map { SelectionResponse(value: $0.art ?? "", text: $0.label) })
    }

    // MARK: Search

    /// `SearchView.searching` without Seerr: `JellyfinClient.search` (movies and series only), without
    /// duplicate IDs, the line under the poster from `hitInfo`. Empty below the minimum length.
    public func search(term: String) async throws -> String {
        return try await throwReadable { () async throws -> String in
            guard let c = client, let a = addresses else { throw CoreError.notConnected }
            let clean = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard DisplayRules.searchTermFits(clean) else { return "[]" }
            let hit = ListRules.withoutDouble(try await c.search(clean))
            return try json(hit.map { i in
                let k = gridTile(i, a)
                return GridTileResponse(id: k.id, title: k.title, type: k.type, subline: i.hitInfo,
                                           poster: k.poster, progress: k.progress, mark: k.mark, markCount: k.markCount)
            })
        }
    }

    /// From when to search; the same rule on all platforms.
    public static func searchTermFits(term: String) -> Bool { DisplayRules.searchTermFits(term) }

    /// The history is stored as one string; rules (eight, no duplicates, newest first) are in the package.
    public static func searchHistoryKey() -> String { SearchHistory.key }
    /// The history belongs to the account (`SearchHistory.key(account:)`); without an account, the old shared key.
    public static func searchHistoryKeyAccount(account: String) -> String { SearchHistory.key(account: account) }
    public static func searchHistoryRemember(word: String, raw: String) -> String { SearchHistory.remember(word, in: raw) }
    public static func searchHistoryList(raw: String) -> String {
        (try? JSONEncoder().encode(SearchHistory.list(raw))).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    // MARK: Playback

    /// Opens a title for playback: `AppModel.plan(for:)`, the sections and the next episode in
    /// one go. **Capabilities are reported again before every start**; after a server restart
    /// the handover otherwise broke silently.
    ///
    /// Every opened player gets its own `EpisodeSwitch`; its `geschlossen` is final.
    public func playbackOpen(id: String) async throws -> String {
        return try await throwReadable { () async throws -> String in
            let w = try await playbackFetch(id: id)
            barrier.lock(); _playback = w; _episodesSwitch = EpisodeSwitch(); _chapter = []
            _prepared = nil; _preparation = nil; barrier.unlock()
            return try playbackPlanResponse(w)
        }
    }

    /// Fetch only, set nothing, so an episode switch can leave the old playback in place until
    /// the new one is safely there.
    private func playbackFetch(id: String) async throws -> Playback {
        // **If the episode is on this device, no server is needed** (`AppModel.plan(for:)`).
        // Otherwise "Next episode" on a plane ran into the server timeout even though the file is there.
        if let w = lockRead({ slab(id: id) }) { return w }
        guard let c = client else { throw CoreError.notConnected }
        // Capabilities go with the start report (`reportRail`); here they used to wait before the plan.
        let item = try await c.item(id: id)
        let limit = profileBitrate
        async let planned = c.playbackPlan(for: id, profile: .vlc(maxBitrate: limit))
        async let parts = sections(for: id, c)
        async let afterThat = nextEpisode(to: item, c)
        guard let plan = try await planned else { throw URLError(.resourceUnavailable) }
        let next = await afterThat
        var w = Playback(item: item, plan: plan, sections: await parts,
                           next: lockRead({ _withoutNext }) ? nil : next)
        // External subtitles (`AppModel.subtitleFiles`). None for local files.
        if let s = lockRead({ _session }), !plan.url.isFileURL {
            w.files = SubtitleFile.from(streams: plan.source?.mediaStreams ?? [], server: s.serverURL,
                                            key: s.accessToken)
        }
        return w
    }

    private func playbackPlanResponse(_ w: Playback) throws -> String {
        let a = addresses
        let item = w.item, plan = w.plan
        let isEpisode = item.type == "Episode"
        // **`headerLine`/`seasonNr`/`episodeNr`/`secondaryLine` for the player header**, mirrors
        // `titleLine`/`metaText` in `Sources/iOS/PlayerScreen.swift`. Translation happens in Kotlin
        // (`translated(...)`); only the raw values cross over, as everywhere in this facade.
        let headerLine = (isEpisode && !(item.seriesName ?? "").isEmpty) ? item.seriesName! : item.name
        return try json(PlayPlanResponse(
            url: plan.url.absoluteString, lossless: plan.isLossless, method: plan.method.rawValue,
            title: item.name,
            // **`item.contextLine` from the package, no own line.** Composing it here (series name
            // first, separator "·") drifted apart quickly: tvOS shows "S20 • the accent rule • Name"
            // (`PlayerScreen.footer`, `item.contextLine`).
            subtitle: item.contextLine ?? "",
            next: w.next != nil,
            fileRow: fileRow(plan),
            // For the media controls: for an episode its still, since it shows where you are; otherwise the poster.
            series: item.seriesName, abbreviation: item.episodeCode,
            image: w.image ?? { () -> String? in
                let u: URL? = a?.construct(itemID: item.id, mark: item.imageTags?["Primary"], mass: .atMostHigh(600))
                return u?.absoluteString
            }(),
            itemId: item.id, episode: isEpisode, seriesIdentifier: item.seriesId, seasonIdentifier: item.seasonId,
            headerLine: headerLine, seasonNr: isEpisode ? item.parentIndexNumber : nil,
            episodeNr: isEpisode ? item.indexNumber : nil,
            secondaryLine: isEpisode ? nil : (item.secondaryLine.isEmpty ? nil : item.secondaryLine),
            marks: w.sections.flatMap { [$0.from, $0.until] },
            softwareDecoder: plan.softwareDecoder,
            nextEpisode: w.next.map { f in
                // Like `EpisodeCardsView.abbreviation`/`cardImage` on iOS: "S6 • E11", otherwise the name;
                // the episode's still, otherwise a landscape image. From `episodeCode` in the package, no
                // longer hand-built (it was a hard-coded "F", also in English).
                let abbreviation = f.episodeCode ?? f.name
                let image = a?.construct(itemID: f.id, mark: f.imageTags?["Primary"], mass: .atMostHigh(1080))
                    ?? a.flatMap { ImageSelection.landscape(f, addresses: $0, width: 1920)?.url }
                return EpisodesCardsResponse(id: f.id, name: f.name, abbreviation: abbreviation, image: image?.absoluteString)
            },
            cardImage: a.flatMap { Self.cardImage(item, addresses: $0) },
            dolbyVision: Self.dolbyVision(plan),
            audioCodec: Self.defaultAudioCodec(plan)))
    }

    /// The Dolby Vision profile of the video track when the stream brings the file untouched, otherwise `nil`.
    /// Invalid Dolby Vision data does not count: every player shows that as the base layer.
    private static func dolbyVision(_ plan: PlaybackPlan) -> Int? {
        guard plan.method != .transcode, let track = plan.source.flatMap(FileDetails.videoTrack) else { return nil }
        switch track.videoRangeType {
        case .dolbyVision, .dolbyVisionHDR10, .dolbyVisionHLG, .dolbyVisionSDR, .dolbyVisionEL,
             .dolbyVisionHDR10Plus, .dolbyVisionElHdr10Plus:
            return track.dvProfile ?? 0
        default:
            return nil
        }
    }

    /// The codec of the audio track the server marks as default (otherwise the first), lower case
    /// (`eac3`, `truehd` …). `""` for a file without sound, `nil` if the file is not known (from disk).
    /// The Kotlin side needs it to decide whether ExoPlayer can play the sound without a decoder extension.
    private static func defaultAudioCodec(_ plan: PlaybackPlan) -> String? {
        guard let source = plan.source else { return nil }
        let tracks = FileDetails.audioTracks(source)
        guard let track = tracks.first(where: { $0.isDefault == true }) ?? tracks.first else { return "" }
        return track.codec?.lowercased() ?? ""
    }
    /// "MKV · 1080p · H.264 · German · AAC · Stereo"; mirrors `fileRow` in
    /// `Sources/tvOS/Wiedergabeblatt.swift`. Built once here so Kotlin does not need to assemble
    /// it from `FileDetails`.
    private func fileRow(_ plan: PlaybackPlan) -> String? {
        guard let source = plan.source else { return nil }
        var parts: [String] = []
        if let container = source.container { parts.append(container.uppercased()) }
        if let video = FileDetails.videoTrack(source) { parts.append(FileDetails.video(video, source)) }
        if let audio = FileDetails.audioTracks(source).first { parts.append(audio.short) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// **The start position before VLC reports it.** Otherwise the timeline sat at 0:00 and then
    /// jumped to the right place; on iOS it is there from the start (`position = startAt`).
    /// `TimeAssumption` holds it until VLC confirms: no jump back right after opening.
    public func playbackPoint(since: Double) {
        barrier.lock(); _playback?.state.position = since; barrier.unlock()
    }

    /// **"Next episode": online as before, offline the next downloaded one**
    /// (`DownloadRules.episodePost`, like `AppModel.episodePost`).
    private func nextEpisode(to item: Item, _ c: JellyfinClient?) async -> Item? {
        guard item.type == "Episode" else { return nil }
        let (list, withoutNetwork) = lockRead { (_downloads, _withoutNetwork) }
        return await DownloadRules.episodePost(item, from: list, withoutNetwork: withoutNetwork) {
            guard let c, let series = item.seriesId else { return nil }
            return try await c.episodePost(itemID: item.id, seriesID: series)
        }
    }

    /// The sections, with those stored at download time first (`DownloadRules.sections`, like
    /// `AppModel.sections(fuer:)`).
    private func sections(for id: String, _ c: JellyfinClient?) async -> [Segment] {
        let stored = lockRead { _downloads.first { $0.id == id }?.sections }
        return await DownloadRules.sections(stored: stored) { await c?.sections(for: id) ?? [] }
    }

    /// Under the lock: the finished, stored file of this title as a playback, otherwise `nil`.
    private func slab(id: String) -> Playback? {
        guard !_downloadFolder.isEmpty,
              let p = _downloads.first(where: { $0.id == id && $0.state == .done }) else { return nil }
        let folder = URL(fileURLWithPath: _downloadFolder)
        let file = folder.appendingPathComponent(p.fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        // Kotlin stores the image under account and ID (`DownloadManager.imageFile`).
        let image = folder.appendingPathComponent(DownloadItem.imageName(account: p.account, identifier: p.id))
        return Self.slab(p, file: file, from: _downloads,
                           image: FileManager.default.fileExists(atPath: image.path) ? image.absoluteString : nil)
    }

    /// **What is known without a server**: the stored sections and the next downloaded episode.
    /// What the server adds comes after the start (`playbackLookUp`); no timeout waits here.
    private static func slab(_ p: DownloadItem, file: URL, from list: [DownloadItem], image: String?) -> Playback {
        let plan = PlaybackPlan.fromSlab(file, container: p.container, mediaSourceID: p.source,
                                              videoCodec: p.videoCodec)
        var w = Playback(item: p.asItem, plan: plan, sections: p.sections ?? [],
                           next: DownloadRules.episodePost(p.id, from: list)?.asItem)
        w.image = image
        return w
    }

    /// **Next episode and sections after the start**, mirrors `lookUp(fuer:)` in
    /// `Sources/iOS/PlayerScreen.swift`, for playback from disk (from the server both already
    /// came with the plan). A result arriving too late for its title is discarded by
    /// `EpisodeSwitch.lookUp`. Answer: the new playback plan, empty if nothing changed.
    public func playbackLookUp() async -> String {
        barrier.lock(); let w = _playback; let change = _episodesSwitch; let c = _client; barrier.unlock()
        guard let w, w.plan.url.isFileURL else { return "" }
        let title = w.item, key = Self.key(w)
        var changed = false
        func setDown(_ perform: (inout Playback) -> Bool) {
            barrier.lock(); defer { barrier.unlock() }
            guard var now = _playback, Self.key(now) == key else { return }
            if perform(&now) { _playback = now; changed = true }
        }
        await change.lookUp(fetch: { [self] in await nextEpisode(to: title, c) },
                                   adopt: { new in setDown { w in
                                       guard w.next?.id != new?.id else { return false }
                                       w.next = new; return true } })
        await change.lookUp(fetch: { [self] in await sections(for: title.id, c) },
                                   adopt: { new in setDown { w in
                                       guard w.sections != new else { return false }
                                       w.sections = new; return true } })
        guard changed, let now = lockRead({ _playback }), Self.key(now) == key
        else { return "" }
        log("Nachgeschlagen \(title.id): naechste \(now.next?.id ?? "keine"), Abschnitte \(now.sections.count)")
        return (try? playbackPlanResponse(now)) ?? ""
    }

    /// A tick every 500 ms (`PlaybackTick.compute`, as on iOS). Start and progress go to the
    /// server from here; what the UI should do comes back.
    ///
    /// **No jump latch and no setting:** the target of a seek is held by the state itself
    /// (`jumpReported` -> `PlaybackTick.jumped`) until VLC is there; whether playback
    /// advances at the end is decided by the card alone (`OfferingLayer.nextAtEnd`).
    public func playbackTick(duration: Double, position: Double, showsImage: Bool, running: Bool,
                               hasAudioTracks: Bool, atPush: Bool) -> String {
        barrier.lock()
        // During an episode switch the tick is silent: no report for the old episode after its stop,
        // no offer button, no second advance.
        guard _episodesSwitch.messagesAllowed else { barrier.unlock(); return "{}" }
        guard var w = _playback, _client != nil else { barrier.unlock(); return "{}" }
        let measurement = PlaybackTick.Reading(duration: duration, position: position, goodPoint: position,
                                             showsImage: showsImage, seeksToStart: false, running: running,
                                             hasAudioTracks: hasAudioTracks)
        let job = PlaybackTick.compute(&w.state, measurement: measurement, restoring: false,
                                             atPush: atPush, sinceStart: w.start)
        let spot = w.state.position
        // Counts only while the picture runs, not while loading, paused or scrubbing.
        watch.progress(isPlaying: running && showsImage && !atPush)
        // **The overlay** (countdown) pauses while stopped, while scrubbing and before the first
        // frame. `tickLength` is the interval at which Kotlin asks.
        let countdownReady = Self.offeringCatchUp(&w, running: running && showsImage && !atPush,
                                                     elapsed: PlaybackTick.tickLength / .seconds(1),
                                                     atEnd: EpisodeEnd.atEnd(position: spot, duration: w.state.duration)
                                                         && !atPush)
        _playback = w
        barrier.unlock()

        // Queued, not awaited: the tick returns immediately even if the server hangs.
        if job.startReport {
            startReport(w, seconds: spot)
        } else if job.progressReport {
            progressReport(w, seconds: spot, paused: !w.state.running)
        }

        if countdownReady { log("Angebot: Countdown abgelaufen") }
        // Advances by itself at the end, only with a card, not if it was dismissed.
        let proceed = w.next != nil
            && (countdownReady || (w.layer.nextAtEnd
                && EpisodeEnd.advance(position: spot, duration: w.state.duration,
                                             sinceOpen: Date().timeIntervalSince(w.start),
                                             // If the card is counting, advancing belongs to it (otherwise: seek to the end, and the end
                                             // of the file switched immediately).
                                             cardCounts: w.layer.cardCounts)))
        let status = Self.offeringStatus(w)
        return (try? json(TickResponse(loadingScreenGone: job.loadingScreenGone, tracksApply: job.tracksApply,
                                      position: spot, offering: status.art, to: status.to,
                                      offeringText: status.text, overlay: status.overlay,
                                      countdown: status.share, countdownRest: w.layer.countdownRest,
                                      countdownLength: w.layer.countdownLength,
                                      advance: proceed))) ?? "{}"
    }

    /// Adjust offer and overlay to the state's position: on the tick, and with `elapsed: 0`
    /// right after a seek. `true` if the countdown has now run out.
    private static func offeringCatchUp(_ w: inout Playback, running: Bool, elapsed: Double,
                                          atEnd: Bool = false) -> Bool {
        let spot = w.state.position, duration = w.state.duration
        let offering = SectionLogic.offering(position: spot, duration: duration,
                                              sections: w.sections, hasNextEpisode: w.next != nil)
        // **Without an outro section the last 30 s** (`EpisodeCard.remainingWindow`, as on iPhone and
        // TV); then the countdown runs to the end of the file.
        let due = SectionLogic.cardDue(position: spot, duration: duration,
                                                   sections: w.sections, hasNextEpisode: w.next != nil,
                                                   remainingWindow: EpisodeCard.remainingWindow)
        return w.layer.tick(offering: offering, cardDue: due, running: running, elapsed: elapsed,
                            countdown: SectionLogic.countdown(position: spot, duration: duration,
                                                                 sections: w.sections,
                                                                 remainingWindow: EpisodeCard.remainingWindow),
                            // At the end of the file the countdown keeps counting although nothing plays.
                            atEnd: atEnd)
    }

    private static func offeringStatus(_ w: Playback)
        -> (art: String, to: Double?, text: String, overlay: String, share: Double) {
        let offering = SectionLogic.offering(position: w.state.position, duration: w.state.duration,
                                              sections: w.sections, hasNextEpisode: w.next != nil)
        var art = "keiner"
        var to: Double?
        switch offering {
        case .nobody: break
        case let .skip(target, _): art = "ueberspringen"; to = target
        case .nextEpisode: art = "naechste"
        }
        var overlay = "nichts"
        var share = 0.0
        switch w.layer.display {
        case .nothing: break
        case .button: overlay = "knopf"
        case let .card(a): overlay = "karte"; share = a
        }
        return (art, to, offering.label, overlay, share)
    }

    /// **Only the time, between two ticks** (`PlaybackTick.timeAdopt`): Kotlin asks every
    /// 250 ms, the full tick stays at 500 ms. VLC's time, after a seek the target until VLC is
    /// there. `-1` if nothing plays or a switch is in progress; the display then stays as it is.
    public func displayTime(position: Double, atPush: Bool) -> Double {
        barrier.lock(); defer { barrier.unlock() }
        guard _episodesSwitch.messagesAllowed, var w = _playback else { return -1 }
        PlaybackTick.timeAdopt(&w.state, reported: position, atPush: atPush, sinceStart: w.start)
        _playback = w
        return w.state.position
    }

    /// **The controls open or close** (`OfferingLayer.controls`): opening cancels the "Next
    /// episode" card. A skip button stays `Angebotsebene.knopfdauer` (6 s of runtime) without the
    /// controls; after that it appears and disappears with them. Kotlin calls this with the
    /// desired visibility, immediately on change, and gets the overlay back (`nothing`, `button`,
    /// `card`); otherwise the button would linger or be missing until the next tick.
    public func controlsChanged(opened: Bool) -> String {
        barrier.lock(); defer { barrier.unlock() }
        guard var w = _playback else { return "nichts" }
        w.layer.controls(opened: opened)
        _playback = w
        return Self.offeringStatus(w).overlay
    }

    /// **Back, or a direction key on the TV:** the overlay goes away and a running countdown is
    /// cancelled (so the end of the file does not advance either). `true` if something was
    /// closed; then Back must not leave the player.
    public func offeringClose() -> Bool {
        barrier.lock(); defer { barrier.unlock() }
        guard var w = _playback else { return false }
        let toward = w.layer.close()
        _playback = w
        if toward { log("Angebot: geschlossen") }
        return toward
    }

    /// The button was pressed: the overlay goes away, Kotlin executes.
    public func offeringPressed() {
        barrier.lock(); _playback?.layer.pressed(); barrier.unlock()
    }

    /// "Next episode automatically": the own choice before the account's `EnableNextEpisodeAutoPlay`
    /// before "on" (`Weiterschalten.gilt`). Both as `"1"`, `"0"` or empty (never chosen / unknown).
    public static func nextAutomaticApplies(choice: String, account: String) -> Bool {
        func read(_ t: String) -> Bool? { t.isEmpty ? nil : t == "1" }
        return Advance.applies(ownSelection: read(choice), account: read(account))
    }

    // MARK: Playback rules from the package, for phone and TV
    //
    // Mirrors iOS. Kotlin holds only picture, fingers and focus; when something applies is
    // decided here or in the package.

    /// **A bit back after a long pause** (`PauseJumpBack`, iOS `VLCPlayerView.resume`):
    /// Kotlin asks before resuming when the viewer wants it and sets the position while stopped,
    /// then plays, so the first frame is already the earlier one. `-1`: do not go back. Since
    /// when it is paused, the core knows from ``runStateReported(running:position:)``.
    public func resumeTarget(position: Double, inGroup: Bool) -> Double {
        barrier.lock()
        let since = _playback?.pausedSince
        _playback?.pausedSince = nil
        barrier.unlock()
        guard let z = PauseJumpBack.target(position: position, pausedSince: since, now: Date(),
                                             inGroup: inGroup) else { return -1 }
        log("Fortsetzen nach \(Int(capped: Date().timeIntervalSince(since ?? Date()))) s Pause — vorher auf \(Int(capped: z)) s")
        return z
    }

    /// **Whether the next episode is prepared now** (`Prebuffer.now`, iOS `EpisodePreparation`):
    /// from three minutes before the end or from the outro, only on a cheap network, once per
    /// episode, not in a group, not for an episode on the device.
    public func prebufferDue(position: Double, duration: Double, networkFavorable: Bool) -> Bool {
        lockRead {
            guard let w = _playback, let n = w.next, !_withoutNext, _preparation != n.id,
                  _episodesSwitch.messagesAllowed, slab(id: n.id) == nil else { return false }
            return Prebuffer.now(position: position, duration: duration,
                                   creditsFrom: w.sections.first { $0.art == .credits }?.from,
                                   networkFavorable: networkFavorable)
        }
    }

    /// **Prepare the next episode**: fetch the plan (with sections and the episode after it) and
    /// request the start of the file once (`Prebuffer.startRequest`). ``episodeSwitch(id:position:)``
    /// takes the plan while it is fresh. Once per episode, even if it fails.
    public func episodePrepare() async {
        let n: Item? = lockRead {
            guard let n = _playback?.next, _preparation != n.id else { return nil }
            _preparation = n.id
            _prepared = nil
            return n
        }
        guard let n else { return }
        let beginning = Date()
        func ms() -> Int { Int(capped: Date().timeIntervalSince(beginning) * 1000) }
        guard let w = try? await playbackFetch(id: n.id) else {
            log("Vorpuffer: Plan fuer \(n.id) nicht geholt")
            return
        }
        let applies: Bool = lockRead {
            guard _playback?.next?.id == n.id, _preparation == n.id else { return false }
            _prepared = (w, Date())
            return true
        }
        guard applies else { return }
        log("Vorpuffer: Plan bereit nach \(ms()) ms · \(w.plan.method.rawValue)")
        guard Prebuffer.startLoad(address: w.plan.url, method: w.plan.method) else { return }
        do {
            let bytes = try await Prebuffer.startRequest(w.plan.url)
            log("Vorpuffer: Anfang vorgeladen \(bytes / 1024) KB nach \(ms()) ms")
        } catch {
            log("Vorpuffer: Anfang nicht geladen (\(type(of: error)))")
        }
    }

    /// **The slider snaps to the notches** (`NotchesSnap`): the notch in seconds, `-1` if none is
    /// near enough. `width` in dp, like the snap width.
    public static func notch(value: Double, until: Double, marks: [Double], width: Double) -> Double {
        NotchesSnap.notch(value: value, until: until, marks: marks, width: width) ?? -1
    }

    /// **The episode card:** times, springs and dimensions from `EpisodeCard`, as JSON, for phone
    /// (`iPhone` dimensions) or TV. Springs as natural frequency w, critically damped: in Compose
    /// `spring(dampingRatio = 1f, stiffness = w^2)`.
    public static func episodeCard(tv: Bool) -> String {
        let m = tv ? EpisodeCard.tv : EpisodeCard.iPhone
        return encoded(EpisodesCardsMetrics(
            width: m.width, corner: m.corner, ring: m.ring, spacing: m.spacing, small: m.small, title: m.title,
            appearOmega: EpisodeCard.appearOmega, appearLag: EpisodeCard.appearLag,
            distanceOmega: EpisodeCard.distanceOmega, zoomOmega: EpisodeCard.zoomOmega,
            detailsOut: EpisodeCard.detailsOut, swap: EpisodeCard.swap, imageFade: EpisodeCard.imageFade,
            offset: EpisodeCard.offset, startMetric: EpisodeCard.startMetric, focusMetric: EpisodeCard.focusMetric,
            clickPress: EpisodeCard.clickPress, clickDuration: EpisodeCard.clickDuration,
            bottomSpacing: EpisodeCard.bottomSpacing))
    }
    /// The card width for a safe width (dp); narrower on small devices.
    public static func episodeCardWidth(safeWidth: Double, large: Bool, tv: Bool) -> Double {
        EpisodeCard.width(tv ? EpisodeCard.tv : EpisodeCard.iPhone,
                           safeWidth: safeWidth, large: large)
    }
    /// The offset while dragging, one axis: forward (right, down) free, backward stiff.
    public static func episodeCardDragged(_ distance: Double) -> Double { EpisodeCard.dragged(distance, 0).x }
    /// Whether a swipe pushes the card away (distance and velocity in dp).
    public static func episodeCardSwipedAway(x: Double, y: Double, momentumX: Double, momentumY: Double) -> Bool {
        EpisodeCard.swipedAway(x: x, y: y, momentumX: momentumX, momentumY: momentumY)
    }
    /// When the preview image starts to fade out, from the start (s); `EpisodeCard.fadeOff`.
    public static func episodeCardFadeFrom(imageSince: Double) -> Double { EpisodeCard.fadeOff(imageSince: imageSince) }

    /// **The image color** (`AvComputation`): up to five tones from the points of an image
    /// (RGBA, four bytes each, at most 48 points per side).
    public static func imageTones(rgba: [UInt8]) -> [Double] { AvComputation.tones(rgba: rgba) }
    /// The grid of a page as ARGB points, `columns` x `rows`; see `AvComputation.points`.
    /// Without falloff (`runOut` 0) the base of a whole page, as on the TV.
    public static func imageTonePoints(tones: [Double], columns: Int, rows: Int, height: Double,
                                     colorHeight: Double, since: Double, runOut: Double) -> [Int32] {
        AvComputation.points(tones, columns: columns, rows: rows, height: height,
                               colorHeight: colorHeight, since: since, runOut: runOut)
    }
    /// **Title as logo** (`TitleMarksMetric`): crop without the transparent margin. `rgba` is
    /// 8-bit, **premultiplied**. Answer: x, y, width, height, density, luminance; empty if nothing covers.
    public static func titleMarkMeasure(rgba: [UInt8], width: Int, height: Int) -> [Double] {
        guard let m = TitleMarksMetric.measure(rgba: rgba, width: width, height: height) else { return [] }
        return [Double(m.x), Double(m.y), Double(m.width), Double(m.height), m.density, m.luminance]
    }
    /// Width and height of the logo in the same units as `row` (a title line) and `maxWidth`.
    public static func titleMarkSize(pagesRatio: Double, density: Double, row: Double,
                                         maxWidth: Double) -> [Double] {
        let g = TitleMarksMetric.size(pagesRatio: pagesRatio, density: density,
                                        row: row, maxWidth: maxWidth)
        return [g.width, g.height]
    }
    /// Mostly dark: the logo is then shown as a white silhouette.
    public static func titleMarkDark(luminance: Double) -> Bool { TitleMarksMetric.isDark(luminance: luminance) }
    /// The color at a point of the surface as ARGB, for the season list in the page tone.
    public static func imageToneColor(tones: [Double], x: Double, y: Double) -> Int32 {
        let c = AvComputation.color(tones, x: x, y: y)
        func k(_ w: Double) -> UInt32 { UInt32(max(0, min(255, (w * 255).rounded()))) }
        return Int32(bitPattern: 0xFF00_0000 | (k(c.r) << 16) | (k(c.g) << 8) | k(c.b))
    }

    /// **The profile picture's flight on account switch** (`AccountSwitchCurve`): the path as
    /// sample points, 120 per second until rest (`lane`: x, y, size per point, in dp), plus the
    /// times (switch, swap, landing, ring end) and the ring (`ring`: size, coverage per point,
    /// 120 per second over 0.8 s).
    public static func accountSwitchCurve(fromX: Double, fromY: Double, size: Double, toX: Double, toY: Double,
                                         targetSize: Double) -> String {
        let k = AccountSwitchCurve(fromX: fromX, fromY: fromY, size: size, toX: toX, toY: toY,
                                  targetSize: targetSize)
        let steps = max(2, Int(k.swap * 120))
        var lane: [Double] = []
        lane.reserveCapacity((steps + 1) * 3)
        for i in 0 ... steps {
            let b = k.status(k.swap * Double(i) / Double(steps))
            lane += [b.x, b.y, b.s]
        }
        var ring: [Double] = []
        for i in 0 ... 96 {
            let r = AccountSwitchCurve.ring(0.8 * Double(i) / 96)
            ring += [r.mass, r.coverage]
        }
        return encoded(AccountSwitchResponse(swap: k.swap, landing: k.landing, paintEnd: k.paintEnd,
                                           change: k.change, grow: AccountSwitchCurve.grow,
                                           targetSize: k.target, lane: lane, ring: ring))
    }

    /// **Remove from "Continue watching"**: position to null, watched state stays (`pointBackSet`).
    public func fromContinueWatchingTake(id: String) async -> String {
        await handleRequest { try await $0.pointBackSet(itemID: id) }
    }

    /// What the current account dictates, **from one request**:
    /// `"<next>|<download>|<convert>|<quality>"`. The fourth field is `"1"`/`"0"`: whether a
    /// smaller quality can be chosen when downloading (`DownloadQuality.waehlbar`, picture and
    /// audio right). The others are `EnableNextEpisodeAutoPlay`, `EnableContentDownloading` and
    /// `EnableVideoPlaybackTranscoding`, each `"1"`, `"0"` or empty if the server says nothing.
    /// Never throws; without an answer it returns `"||"`, and then the own choice or "on" stays,
    /// and the right stays `unknown`, i.e. allowed.
    public func accountDefaults() async -> String {
        func text(_ value: Bool?) -> String { value.map { $0 ? "1" : "0" } ?? "" }
        guard let c = client, let v = await c.accountDefaults() else { return "|||1" }
        log("Konto: Naechste Folge automatisch \(text(v.nextEpisodeAutomatic)), Downloads \(v.downloadPermission.rawValue)")
        return "\(text(v.nextEpisodeAutomatic))|\(text(v.downloadsAllowed))|\(text(v.convertAllowed))|\(v.downloadQualitySelectable ? "1" : "0")"
    }

    /// **Whether a download button appears:** the switch and the account's right. The decision
    /// lives in the package (`DownloadPermission.offer`) so Kotlin keeps no second list.
    /// `rights` is `"1"`, `"0"` or empty, as ``accountDefaults()`` returns it.
    public static func downloadButtonShow(rights: String, functionOn: Bool) -> Bool {
        DownloadPermission.offer(rights: .fromServer(rights.isEmpty ? nil : rights == "1"),
                               functionOn: functionOn)
    }

    /// **VLC paused or resumed: report immediately**, like `AppModel.runStateReported`. Kotlin
    /// calls this from libVLC's `Playing`/`Paused`, not from the button press, where the previous
    /// state would still be set. Once per change; nothing before the start, after the stop and
    /// during an episode switch.
    public func runStateReported(running: Bool, position: Double) {
        // The pause for the rewind-on-resume, also before the start and without a report.
        barrier.lock()
        if running { _playback?.pausedSince = nil }
        else if _playback?.pausedSince == nil { _playback?.pausedSince = Date() }
        barrier.unlock()
        guard let w = reportable(), lockRead({ _reportedPaused }) == running else { return }
        log("sofort: \(running ? "weiter" : "Pause") bei \(Int(capped: position)) s")
        progressReport(w, seconds: position, paused: !running)
    }

    /// **Seeked: report immediately**, with the target position (`AppModel.jumpReported`). Every
    /// seek path in Kotlin goes through `PlayItem.springe`, including "Seek to" from the dashboard.
    ///
    /// **And display immediately:** the state holds the target until VLC is there, and the offer
    /// follows it in the same call. The same shape as from the tick comes back, without the jobs.
    public func jumpReported(target: Double) -> String {
        barrier.lock()
        guard var w = _playback else { barrier.unlock(); return "{}" }
        PlaybackTick.jumped(&w.state, target: target)
        // A seek into the outro or to the end: the card's countdown restarts.
        w.layer.jumped()
        _ = Self.offeringCatchUp(&w, running: false, elapsed: 0)
        _playback = w
        barrier.unlock()
        if let m = reportable() {
            progressReport(m, seconds: max(0, w.state.position), paused: lockRead { _reportedPaused })
        }
        let status = Self.offeringStatus(w)
        return (try? json(TickResponse(loadingScreenGone: false, tracksApply: false,
                                      position: w.state.position, offering: status.art, to: status.to,
                                      offeringText: status.text, overlay: status.overlay,
                                      countdown: status.share, countdownRest: w.layer.countdownRest,
                                      countdownLength: w.layer.countdownLength,
                                      advance: false))) ?? "{}"
    }

    /// **The activity goes to the background:** report the state now, not at the next tick. The
    /// playback service keeps the process alive; nothing is awaited.
    public func backgroundReport(position: Double, paused: Bool) {
        guard let w = reportable() else { return }
        log("Hintergrund: \(Int(capped: position)) s pausiert \(paused)")
        progressReport(w, seconds: position, paused: paused)
    }

    // MARK: Reports via the queue

    /// What a report needs. The client is captured when queued: if the account changes
    /// afterwards, the report still belongs to whoever watched.
    private struct ReportContent: Sendable {
        let client: JellyfinClient?
        let item: Item
        let plan: PlaybackPlan
        let seconds: Double
        let tracks: TrackIndices
    }

    private enum ReportError: Error { case noServer }

    /// Set by Kotlin only in the debug build (`PlayItem`, file `meldungen-haengen`): every
    /// report hangs for 60 s, like `messages:hanging` on Linux, simulating a server that does not answer.
    private final class ReportProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var _hanging = false
        var hanging: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _hanging }
            set { lock.lock(); _hanging = newValue; lock.unlock() }
        }
    }
    private let reportProbe = ReportProbe()

    /// Debug build only; Kotlin never calls it otherwise.
    public func messagesHanging(_ an: Bool) {
        guard reportProbe.hanging != an else { return }
        reportProbe.hanging = an
        log("Probe: Meldungen haengen \(an)")
    }

    /// **Dispatched, not awaited:** `ReportQueue` from the package: one queue for start,
    /// progress and stop, progress coalesced, 6 s deadline, and the per-PlaySession stop lock is
    /// inside. Here only what is sent is defined.
    private let messages: ReportQueue<ReportContent>

    private static func reportRail(rows: LogRows, probe: ReportProbe) -> ReportQueue<ReportContent> {
        ReportQueue<ReportContent> { message in
            let content = message.payload
            if probe.hanging { try await Task.sleep(nanoseconds: 60_000_000_000) }
            guard let client = content.client else { throw ReportError.noServer }
            let item = content.item, plan = content.plan
            let ticks = JellyfinClient.ticks(fromSeconds: content.seconds)
            switch message.art {
            case .start:
                // **Capabilities before every start**, in the same report and deadline: after a server
                // restart the handover otherwise broke silently. If it fails, the start goes out anyway,
                // unless the deadline cancelled it.
                do { try await client.reportCapabilities() } catch {
                    try Task.checkCancellation()
                    rows.write("Faehigkeiten nicht gemeldet")
                }
                try await client.reportStart(itemID: item.id, plan: plan, ticks: ticks, tracks: content.tracks)
                rows.write("Start \(Int(capped: content.seconds)) s \(item.id) session \(plan.playSessionID ?? "nil")"
                    + " Spuren \(trackText(content.tracks))")
            case let .progress(paused):
                try await client.reportProgress(itemID: item.id, plan: plan, positionTicks: ticks, paused: paused,
                                                tracks: content.tracks)
                rows.write("Progress \(Int(capped: content.seconds)) s pausiert \(paused) \(item.id)"
                    + " Spuren \(trackText(content.tracks))")
            case .stop:
                try await client.reportStopped(itemID: item.id, plan: plan, positionTicks: ticks)
            }
        }
    }

    private static func key(_ w: Playback) -> String {
        StopLock.key(itemID: w.item.id, playSessionID: w.plan.playSessionID)
    }

    private func message(_ art: ReportQueue<ReportContent>.Art, _ w: Playback,
                         seconds: Double) -> ReportQueue<ReportContent>.Message {
        .init(art: art, key: Self.key(w),
              payload: ReportContent(client: client, item: w.item, plan: w.plan, seconds: seconds, tracks: w.tracks))
    }

    private static func trackText(_ s: TrackIndices) -> String {
        "\(s.audio.map(String.init) ?? "—")/\(s.subtitle.map(String.init) ?? "—")"
    }

    private func lockRead<T>(_ read: () -> T) -> T {
        barrier.lock(); defer { barrier.unlock() }
        return read()
    }

    /// The running playback, when reporting out of turn is allowed.
    private func reportable() -> Playback? {
        lockRead {
            guard let w = _playback, _episodesSwitch.messagesAllowed, w.state.startReported else { return nil }
            return w
        }
    }

    /// Returns immediately. The queue releases the stop lock when enqueuing.
    private func startReport(_ w: Playback, seconds: Double) {
        barrier.lock(); _reportedPaused = false; barrier.unlock()
        messages.report(message(.start, w, seconds: seconds))
    }

    /// Returns immediately; discarded after this session's stop.
    private func progressReport(_ w: Playback, seconds: Double, paused: Bool) {
        guard messages.report(message(.progress(paused: paused), w, seconds: seconds)) else {
            log("Fortschritt nach Stopp verworfen \(w.item.id)")
            return
        }
        barrier.lock(); _reportedPaused = paused; barrier.unlock()
    }

    /// **Awaited**, because the pages reload afterwards; the queue sends it behind a start that
    /// is still running. Empty means: reported or already reported. Otherwise the catch-up report as JSON.
    private func stopReport(_ w: Playback, spot: Double) async -> String {
        let s = lockRead { _session }
        let ticks = JellyfinClient.ticks(fromSeconds: spot)
        let moment = Date()
        let result = await messages.reportAndWait(message(.stop, w, seconds: spot))
        // **With and without network:** the download knows its state itself, and a report that did
        // go through clears the pending one of the same title (`PostReportRules.ueberholt`).
        if let account = s?.userID {
            let remark = StopRemember(itemID: w.item.id, account: account, ticks: ticks, moment: moment,
                                       sent: result == .sent)
            barrier.lock(); _stopps.append(remark); barrier.unlock()
        }
        switch result {
        case .sent:
            log("Stopped \(Int(capped: spot)) s \(w.item.id) session \(w.plan.playSessionID ?? "nil")")
            return ""
        case .discarded:
            log("Stopped doppelt verworfen \(w.item.id) session \(w.plan.playSessionID ?? "nil")")
            return ""
        case .failed, .timeOverStep:
            log("Stopped \(result) → Nachmeldung \(w.item.id)")
            guard let account = s?.userID else { return "" }
            return Self.encoded(PendingReport(itemID: w.item.id, account: account, ticks: ticks))
        }
    }

    /// Report lines for logcat, with their own lock so the queue can write without knowing the core.
    private final class LogRows: @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [String] = []
        func write(_ row: String) {
            lock.lock(); defer { lock.unlock() }
            rows.append(row)
            if rows.count > 50 { rows.removeFirst(rows.count - 50) }
        }
        func pickUp() -> [String] {
            lock.lock(); defer { lock.unlock() }
            let all = rows; rows = []
            return all
        }
    }
    private let logRows = LogRows()

    private func log(_ row: String) {
        logRows.write(row)
        LogRing.shared.append(row)
    }

    // MARK: Share log (mirrors `LogRing` / `LogFile`)

    /// One line into the memory the user shares their log from. Redaction happens on entry, so
    /// an access token is never in plain text in memory either.
    public static func logAppend(text: String) {
        LogRing.shared.append(text)
    }

    /// The lines of the last `seconds`, oldest first, with time, separated by newlines.
    public static func logExcerpt(seconds: Double) -> String {
        LogRing.shared.excerpt(seconds: seconds).joined(separator: "\n")
    }

    /// Access tokens from free text, for lines that did not go through the memory (VLC).
    public static func logRedact(text: String) -> String {
        LogRedaction.text(text)
    }

    /// The report lines since the last pickup; Kotlin writes them to logcat under "Swiftly".
    /// Swift itself cannot reach `liblog`.
    public func logFetch() -> String {
        logRows.pickUp().joined(separator: "\n")
    }

    /// Stopped. Must also come on close, otherwise the session hangs in the dashboard. Whether
    /// the title counts as watched, the server decides from the reported position.
    /// Empty means: reported. Otherwise the catch-up report as JSON; **this is where the data
    /// downloads need originates**: where someone stopped on a plane. Kotlin stores it.
    ///
    /// **Via `EpisodeSwitch.close`:** if a switch is running, it applies nothing any more;
    /// if the start of the new episode is under way, the stop goes after it. What is reported is
    /// what runs when stopping; if that was already the new episode, with its own position.
    /// A second call for the same player does nothing.
    public func playbackEnd(position: Double) async -> String {
        await withCheckedContinuation { (done: CheckedContinuation<String, Never>) in
            barrier.lock()
            watch.stopped()
            let change = _episodesSwitch
            let presentTimes = _playback.map(Self.key)
            let opened = change.phase != .closed
            if opened {
                change.close { [self] in
                    barrier.lock(); let w = _playback; _playback = nil; barrier.unlock()
                    guard let w else { done.resume(returning: ""); return }
                    let spot = Self.key(w) == presentTimes ? position : w.state.position
                    done.resume(returning: await stopReport(w, spot: spot))
                }
            }
            barrier.unlock()
            if !opened { done.resume(returning: "") }
        }
    }

    /// Switch to another episode (`EpisodeSwitch.ausfuehren` from the package, as on iOS, tvOS
    /// and macOS). `id` empty: the queued next episode; otherwise a freely chosen one (`Folgenblatt`).
    ///
    /// Stop of the old and plan of the new run side by side; **the old playback stays until the
    /// plan is there**. If that fails, it keeps running and the tick reports it again.
    /// A second trigger during the switch comes back as `locked`.
    ///
    /// Answer: `result` (`switched`, `locked`, `cancelled`, `failed`), for
    /// `switched` the `playbackPlan`, for `failed` the readable `error`, and a `pendingReport`
    /// if the old episode's stop did not arrive.
    /// **Quality switched: same title, replanned, at the same position.** Mirrors the quality
    /// choice in the player on iOS/tvOS/macOS (`PlayerScreen.qualitySelection`). Unlike
    /// ``episodeSwitch(id:position:)`` it stays with the **running** title; only the plan is
    /// new, because `playbackSelection` set the bitrate limit beforehand. The position is the
    /// resume position, not zero. Answer as there.
    public func qualitySwitch(position: Double) async -> String {
        // A prepared plan of the next episode carries the old choice.
        barrier.lock(); let change = _episodesSwitch; let alt = _playback
        _prepared = nil; _preparation = nil; barrier.unlock()
        guard let alt else { return Self.encoded(SwitchResponse(result: "gescheitert")) }
        let store = SwitchStore()
        let result = await change.execute(EpisodeSwitch.Steps<Playback>(
            stopNow: { [self] in store.setDown(pendingReport: await stopReport(alt, spot: position)) },
            planOut: { [self] in
                do { return try await playbackFetch(id: alt.item.id) } catch {
                    store.setDown(error: coreErrorText(error))
                    return nil
                }
            },
            apply: { [self] new in
                var new = new
                PlaybackTick.newTitle(&new.state, startReported: true)
                if position > 0 { PlaybackTick.jumped(&new.state, target: position) }
                barrier.lock(); _playback = new; barrier.unlock()
                store.setDown(playbackPlan: try? playbackPlanResponse(new))
            },
            start: { [self] new in startReport(new, seconds: position) },
            failed: { [self] in
                barrier.lock()
                if let w = _playback, Self.key(w) == Self.key(alt) { _playback?.state.startReported = false }
                barrier.unlock()
            }))
        log("Qualität \(result) → \(alt.item.id) bei \(Int(capped: position)) s")
        var answer = SwitchResponse(result: "\(result)")
        answer.pendingReport = store.pendingReport
        switch result {
        case .switched:
            answer.playbackPlan = store.playbackPlan
        case .failed:
            answer.error = store.error ?? coreErrorText(URLError(.resourceUnavailable))
        case .locked, .cancelled: break
        }
        return Self.encoded(answer)
    }

    public func episodeSwitch(id: String, position: Double) async -> String {
        barrier.lock(); let change = _episodesSwitch; let alt = _playback; barrier.unlock()
        guard let alt else { return Self.encoded(SwitchResponse(result: "gescheitert")) }
        guard let target = id.isEmpty ? alt.next?.id : id else {
            return Self.encoded(SwitchResponse(result: "gescheitert"))
        }
        // Already fetched in the last minutes (`Prebuffer`)? Then the switch does not wait for the
        // server again, like `EpisodePreparation.take` on iOS. Once taken, it is used up.
        let prepared: Playback? = lockRead {
            defer { _prepared = nil }
            guard let v = _prepared, v.w.item.id == target, Prebuffer.freshValue(prepared: v.moment, now: Date())
            else { return nil }
            return v.w
        }
        log("Wechsel Beginn → \(target) · Plan vorbereitet: \(prepared != nil ? "ja" : "nein")")
        let store = SwitchStore()
        let result = await change.execute(EpisodeSwitch.Steps<Playback>(
            stopNow: { [self] in store.setDown(pendingReport: await stopReport(alt, spot: position)) },
            planOut: { [self] in
                if let prepared {
                    // Set up fresh so start and tick count from now, not from the preparation.
                    var n = Playback(item: prepared.item, plan: prepared.plan,
                                       sections: prepared.sections, next: prepared.next)
                    n.files = prepared.files
                    n.image = prepared.image
                    return n
                }
                do { return try await playbackFetch(id: target) } catch {
                    store.setDown(error: coreErrorText(error))
                    return nil
                }
            },
            apply: { [self] new in
                var new = new
                PlaybackTick.newTitle(&new.state, startReported: true)
                barrier.lock(); _playback = new; barrier.unlock()
                store.setDown(playbackPlan: try? playbackPlanResponse(new))
            },
            start: { [self] new in startReport(new, seconds: 0) },
            failed: { [self] in
                // The old episode keeps playing, but the server already knows it as ended.
                barrier.lock()
                if let w = _playback, Self.key(w) == Self.key(alt) { _playback?.state.startReported = false }
                barrier.unlock()
            }))
        log("Wechsel \(result) → \(target)")
        var answer = SwitchResponse(result: "\(result)")
        answer.pendingReport = store.pendingReport
        switch result {
        case .switched:
            answer.playbackPlan = store.playbackPlan
        case .failed:
            answer.error = store.error ?? coreErrorText(URLError(.resourceUnavailable))
        case .locked, .cancelled: break
        }
        return Self.encoded(answer)
    }
    // MARK: Tracks
    //
    // Mirrors `VLCPlayerView` in `Sources/Shared/VLCPlayer.swift`. Decided by `TrackRule` /
    // `TrackMapping` in the package; Kotlin passes the tracks from libVLC in as JSON (`id`,
    // `identifier`, `name`, `language`, `fourcc`, `channels`) and gets VLC track IDs back.
    //
    // **The memory lives in Kotlin** (SharedPreferences, keys `tonJeTitel`/`utJeTitel`), in the
    // same format as `TrackMemory`. The package stores it in `UserDefaults`, which is not
    // available on Android. Kotlin passes the storage in and stores what comes out here.

    /// The external subtitles of the running episode: `[{index, address}]`. Kotlin computes the
    /// MD5 of the URL (``subtitleAttributeSet(index:attribute:)``) and attaches it as a slave.
    public func subtitleFiles() -> String {
        Self.encoded(lockRead { _playback?.files ?? [] }.map {
            SubtitleFileResponse(index: $0.index, address: $0.address.absoluteString)
        })
    }

    public func subtitleAttributeSet(index: Int, attribute: String) {
        barrier.lock(); defer { barrier.unlock() }
        guard let i = _playback?.files.firstIndex(where: { $0.index == index }),
              let file = _playback?.files[i] else { return }
        _playback?.files[i] = SubtitleFile(index: index, address: file.address, attribute: attribute)
    }

    /// Audio and subtitles per `TrackRule`, once VLC knows the tracks. `audioNow`: the running
    /// audio track (VLC id) in case nothing can be assigned. Answer: `audio` (VLC id; missing:
    /// leave the file), `subtitle` (VLC id, -1: off).
    public func tracksSelect(audio: String, subtitle: String, audioNow: Int, tonwunsch: String,
                              subtitlePreference: String, automatic: Bool,
                              audioMemory: String, subtitleMemory: String) -> String {
        let audioTracks = Self.tracks(audio), subTracks = Self.tracks(subtitle)
        guard let w = lockRead({ _playback }) else { return "{}" }
        let source = w.plan.source
        let streams = source?.mediaStreams ?? []
        let z = TrackMapping.compose(audio: audioTracks.map(\.track), subtitle: subTracks.map(\.track),
                                     streams: streams, files: w.files)
        let title = TrackMemory.title(for: w.item)
        var rememberedAudio: TrackImprint?
        if case .track(let imprint)? = Self.readMemory(audioMemory, title) { rememberedAudio = imprint }

        var audioIndex = TrackRule.audio(streams: streams, remembered: rememberedAudio, preferredLanguage: tonwunsch,
                                     serverPreGift: source?.defaultAudioStreamIndex)
        var audioId: Int?
        if let searched = audioIndex, let position = z.audioPositionValue(index: searched) {
            audioId = audioTracks[position].id
        } else {
            // Not assignable: the old way via the name, otherwise the file.
            if !tonwunsch.isEmpty, let hit = audioTracks.first(where: { Language.fits($0.name, toward: tonwunsch) }) {
                audioId = hit.id
            }
            let ongoing = audioId ?? audioNow
            audioIndex = audioTracks.firstIndex { $0.id == ongoing }.flatMap { z.audio[$0] }
        }

        let choice = TrackRule.subtitle(streams: streams, remembered: Self.readMemory(subtitleMemory, title),
                                        serverPreGift: source?.defaultSubtitleStreamIndex, automatic: automatic,
                                        audioIndex: audioIndex, tonwunsch: tonwunsch, preferredLanguage: subtitlePreference)
        var utId = -1
        var opened: Int?
        var utIndex = -1
        if case .feed(let index) = choice {
            utIndex = index
            if let position = z.subtitlePosition(index: index) {
                utId = subTracks[position].id
            } else if w.files.contains(where: { $0.index == index }) {
                // The file is not attached yet or not read yet.
                opened = index
                log("Spuren: Untertiteldatei \(index) noch nicht da, wartet")
            } else {
                log("Spuren: Untertitel \(index) nicht zuzuordnen, bleibt aus")
            }
        }
        barrier.lock()
        if let now = _playback, Self.key(now) == Self.key(w) {
            _playback?.tracks = TrackIndices(audio: audioIndex, subtitle: utIndex)
            _playback?.currentSubtitle = opened
        }
        barrier.unlock()
        log("Spuren: Ton \(audioIndex.map(String.init) ?? "Datei") · Untertitel \(choice)"
            + " · Vorgaben \(source?.defaultAudioStreamIndex.map(String.init) ?? "—")/"
            + "\(source?.defaultSubtitleStreamIndex.map(String.init) ?? "—")"
            + " · Zuordnung Ton \(z.audio) Untertitel \(z.subtitle)"
            + " · Kennungen \(subTracks.map(\.identifier))")
        return Self.encoded(TrackSelectionResponse(audio: audioId, subtitle: utId))
    }

    /// VLC reports a new subtitle track, maybe the chosen file. VLC id or -1.
    public func openSubtitle(subtitle: String) -> Int {
        guard let w = lockRead({ _playback }), let index = w.currentSubtitle else { return -1 }
        let subTracks = Self.tracks(subtitle)
        let z = TrackMapping.compose(audio: [], subtitle: subTracks.map(\.track),
                                     streams: w.plan.source?.mediaStreams ?? [], files: w.files)
        guard let position = z.subtitlePosition(index: index) else { return -1 }
        barrier.lock()
        let applies = _playback?.currentSubtitle == index && _playback.map(Self.key) == Self.key(w)
        if applies { _playback?.currentSubtitle = nil; _playback?.tracks.subtitle = index }
        barrier.unlock()
        guard applies else { return -1 }
        log("Spuren: Untertiteldatei \(index) nachgereicht")
        return subTracks[position].id
    }

    /// Audio track by hand: applies to the whole series. Returns the new storage.
    public func audioFromHand(audio: String, id: Int, memory: String) -> String {
        let tracks = Self.tracks(audio)
        guard let w = lockRead({ _playback }), let position = tracks.firstIndex(where: { $0.id == id })
        else { return memory }
        let streams = w.plan.source?.mediaStreams ?? []
        let z = TrackMapping.compose(audio: tracks.map(\.track), subtitle: [], streams: streams, files: [])
        let index = z.audio[position]
        let imprint = index.flatMap { i in streams.first { $0.type == "Audio" && $0.index == i } }
            .map { TrackImprint(feed: $0, in: streams, name: tracks[position].name) }
            ?? TrackImprint(track: tracks[position].track)
        barrier.lock()
        if _playback.map(Self.key) == Self.key(w) { _playback?.tracks.audio = index }
        barrier.unlock()
        log("Spuren: Ton von Hand \(index.map(String.init) ?? "?")")
        return Self.writeMemory(memory, TrackMemory.title(for: w.item), .track(imprint))
    }

    /// Subtitles by hand, `id` -1 means off; also applies to the whole series.
    public func subtitleFromHand(subtitle: String, id: Int, memory: String) -> String {
        guard let w = lockRead({ _playback }) else { return memory }
        let title = TrackMemory.title(for: w.item)
        let tracks = Self.tracks(subtitle)
        guard id >= 0, let position = tracks.firstIndex(where: { $0.id == id }) else {
            barrier.lock()
            if _playback.map(Self.key) == Self.key(w) {
                _playback?.currentSubtitle = nil; _playback?.tracks.subtitle = -1
            }
            barrier.unlock()
            log("Spuren: Untertitel von Hand aus")
            return Self.writeMemory(memory, title, .off)
        }
        let streams = w.plan.source?.mediaStreams ?? []
        let z = TrackMapping.compose(audio: [], subtitle: tracks.map(\.track), streams: streams, files: w.files)
        let index = z.subtitle[position]
        let imprint = index.flatMap { i in streams.first { $0.type == "Subtitle" && $0.index == i } }
            .map { TrackImprint(feed: $0, in: streams, name: tracks[position].name) }
            ?? TrackImprint(track: tracks[position].track)
        barrier.lock()
        if _playback.map(Self.key) == Self.key(w) {
            _playback?.currentSubtitle = nil; _playback?.tracks.subtitle = index
        }
        barrier.unlock()
        log("Spuren: Untertitel von Hand \(index.map(String.init) ?? "?")")
        return Self.writeMemory(memory, title, .track(imprint))
    }

    /// Readable names for the track lists. Audio: "German · AAC · 5.1", from the track itself,
    /// or from the assigned stream if the codec is missing there. Subtitles: language, with the
    /// format added for equal names or a file; Kotlin appends `forced`/`hearingImpaired`/`file`
    /// translated. libVLC 3 otherwise names tracks "Track 1 - [English]".
    public func trackNames(audio: String, subtitle: String) -> String {
        let audioTracks = Self.tracks(audio), subTracks = Self.tracks(subtitle)
        let w = lockRead { _playback }
        let streams = w?.plan.source?.mediaStreams ?? []
        let z = TrackMapping.compose(audio: audioTracks.map(\.track), subtitle: subTracks.map(\.track),
                                     streams: streams, files: w?.files ?? [])
        let audioNames = audioTracks.enumerated().map { position, typedInput -> TrackName in
            let track = typedInput.track
            let feed = z.audio[position].flatMap { i in streams.first { $0.type == "Audio" && $0.index == i } }
            let own = TechDetails.audioTrackName(language: track.language, codec: track.codec, channels: track.channels)
            let fromServer = feed.flatMap {
                TechDetails.audioTrackName(language: $0.language, codec: TechDetails.codecNameValue($0.codec), channels: $0.channels)
            }
            let text = track.codec == nil ? (fromServer ?? own) : (own ?? fromServer)
            return TrackName(id: typedInput.id, text: text ?? typedInput.name, forced: false, file: false)
        }
        let utStreams = subTracks.indices.map { position in
            z.subtitle[position].flatMap { i in streams.first { $0.type == "Subtitle" && $0.index == i } }
        }
        let subNames = subTracks.enumerated().map { position, typedInput -> TrackName in
            guard let feed = utStreams[position] else {
                let language = typedInput.track.language.flatMap { TechDetails.language($0) }
                return TrackName(id: typedInput.id, text: language ?? typedInput.name, forced: false,
                                file: typedInput.track.additionId != nil)
            }
            let language = feed.languageName ?? typedInput.name
            let double = utStreams.filter { ($0?.languageName ?? "") == (feed.languageName ?? "") }.count > 1
            let parts = [language, double || feed.isExternal == true ? TechDetails.codecNameValue(feed.codec) : nil]
            return TrackName(id: typedInput.id, text: parts.compactMap { $0 }.joined(separator: " · "),
                            forced: feed.isForced == true, file: feed.isExternal == true,
                            hearingImpaired: feed.isHearingImpaired == true)
        }
        return Self.encoded(TrackNamesResponse(audio: audioNames, subtitle: subNames))
    }

    private static func tracks(_ json: String) -> [TrackInput] {
        (try? JSONDecoder().decode([TrackInput].self, from: Data(json.utf8))) ?? []
    }

    /// The same format as `TrackMemory`: per title empty (off), a `TrackImprint` as JSON, or
    /// an old track name.
    private static func readMemory(_ store: String, _ title: String) -> TrackMemory.Choice? {
        guard let all = try? JSONDecoder().decode([String: String].self, from: Data(store.utf8)),
              let raw = all[title] else { return nil }
        if raw.isEmpty { return .off }
        if raw.hasPrefix("{"), let imprint = try? JSONDecoder().decode(TrackImprint.self, from: Data(raw.utf8)) {
            return .track(imprint)
        }
        return .name(raw)
    }

    private static func writeMemory(_ store: String, _ title: String, _ choice: TrackMemory.Choice) -> String {
        var all = (try? JSONDecoder().decode([String: String].self, from: Data(store.utf8))) ?? [:]
        switch choice {
        case .off: all[title] = ""
        case .name(let name): all[title] = name
        case .track(let imprint):
            all[title] = (try? JSONEncoder().encode(imprint)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        return encoded(all)
    }

    // MARK: Tech badge

    /// The fixed lines of the tech badge, once per title: delivery, reason, picture, video,
    /// audio, subtitles, file, demand. `art` is `good`, `cautionary` or empty; `key` the label
    /// for the catalog. Values are formatted by `TechDetails`, as on iOS.
    /// **The fixed lines of the tech badge**, mirrors `TechBadge` (Sources/Shared): only what
    /// a viewer wants to know. Header, reason, picture, audio, subtitles and file are core lines
    /// (`kern`) that always show; the frame rate only in measuring mode. `key` is the
    /// quiet name before the value (Kotlin translates it).
    public func techFixed(measure: Bool) -> String {
        barrier.lock(); let w = _playback; _counter = nil; barrier.unlock()
        guard let w else { return "[]" }
        let plan = w.plan
        var rows = [TechRow(text: TechDetails.delivery(plan.method),
                                   art: TechDetails.weight(plan.method) == .good ? "gut" : "warnend",
                                   key: nil, header: true)]
        // The reason directly under the word: whoever reads "Transcoded" wants to know why.
        if plan.method == .transcode, let reason = plan.reasons.first {
            rows.append(TechRow(text: reason.text, art: "warnend"))
        }
        if let q = plan.source {
            let video = FileDetails.videoTrack(q)
            let audio = FileDetails.audioTracks(q).first
            let subtitle = FileDetails.subtitleTracks(q).first
            func parts(_ values: [String?]) -> String? {
                let present = values.compactMap { $0 }
                return present.isEmpty ? nil : present.joined(separator: " · ")
            }
            // Codec, resolution and HDR type in one line; the frame rate only when measuring.
            if let image = parts([TechDetails.codecNameValue(video?.codec),
                                 TechDetails.imageRow(width: video?.width, height: video?.height, depth: nil, reach: nil),
                                 TechDetails.dynamics(video),
                                 measure ? TechDetails.frameRate(video?.frameRate).map { "\($0) fps" } : nil]) {
                rows.append(TechRow(text: image, art: "", key: "Bild"))
            }
            if let t = parts([TechDetails.codecNameValue(audio?.codec), TechDetails.channelWord(audio?.channels), TechDetails.language(audio?.language)]),
               TechDetails.codecNameValue(audio?.codec) != nil {
                rows.append(TechRow(text: t, art: "", key: "Ton"))
            }
            if let u = parts([TechDetails.codecNameValue(subtitle?.codec), TechDetails.language(subtitle?.language)]),
               TechDetails.codecNameValue(subtitle?.codec) != nil {
                rows.append(TechRow(text: u, art: "", key: "Untertitel"))
            }
            // Container and size, followed by the average bitrate the file needs; no separate line any more.
            if let c = FileDetails.container(q) {
                var text = c
                if let size = q.size, size > 0, let duration = w.item.runtimeSeconds, duration > 1,
                   let rate = TechDetails.bitrate(Double(size) * 8 / duration) {
                    text += " · Ø \(rate)"
                }
                rows.append(TechRow(text: text, art: "", key: "Datei"))
            }
        }
        return (try? json(rows)) ?? "[]"
    }

    /// A measurement point from VLC's counters; `Counter` computes rates, run and reserve over
    /// its window. libVLC does not count "late" on Android; it goes in as 0 and is not shown.
    public func techTick(hasRead: Int64, unpacked: Int64, shown: Int64, discarded: Int64, videoBlocks: Int64,
                            audioBlocks: Int64, audioPlay: Int64, audioLost: Int64, beschaedigt: Int64, jumps: Int64,
                            spot: Double, running: Bool) -> String {
        func u(_ x: Int64) -> UInt64 { UInt64(max(0, x)) }
        let raw = Counter.RawValues(hasRead: u(hasRead), unpacked: u(unpacked), shown: u(shown), discarded: u(discarded),
                                     tooLate: 0, videoBlocks: u(videoBlocks), audioBlocks: u(audioBlocks), audioPlay: u(audioPlay),
                                     audioLost: u(audioLost), beschaedigt: u(beschaedigt), jumps: u(jumps))
        barrier.lock(); let before = _counter; let w = _playback; barrier.unlock()
        guard let mediaWork = Counter(raw, spot: spot, running: running, before: before) else { return "{}" }
        barrier.lock(); _counter = mediaWork; barrier.unlock()
        let source = w?.plan.source
        let should = source.flatMap { FileDetails.videoTrack($0)?.frameRate }
        var jeSecond: Double?
        if let size = source?.size, let duration = w?.item.runtimeSeconds, duration > 0 { jeSecond = Double(size) / duration }
        return (try? json(TechResponse(
            input: TechDetails.bitrate(mediaWork.input), demuxer: TechDetails.bitrate(mediaWork.demuxer),
            shows: mediaWork.showsProSecond, shown: raw.shown, should: should, run: mediaWork.runShare,
            decoded: mediaWork.decodedProSecond,
            reserveSeconds: jeSecond.flatMap { $0 > 0 ? Double(mediaWork.preAdviceBytes) / $0 : nil },
            reserveKiB: mediaWork.preAdviceBytes / 1024, discarded: raw.discarded, audioLost: raw.audioLost,
            beschaedigt: raw.beschaedigt, jumps: raw.jumps))) ?? "{}"
    }

    /// `RatingQuestion.countsAsReady`: from 90 %, and only for more than a minute.
    public static func ratingCounts(position: Double, duration: Double) -> Bool {
        RatingQuestion.countsAsReady(position: position, duration: duration)
    }

    /// `RatingQuestion.faellig`: from the third finished title, once per version.
    public static func ratingDue(done: Int, lastAsked: String, version: String) -> Bool {
        RatingQuestion.due(done: done, lastAsked: lastAsked.isEmpty ? nil : lastAsked, version: version)
    }

    /// `Community.kickoff`: after a title watched to the end, "bewertung", "discord" or "".
    /// `lastAsked` empty means: never asked.
    public static func communityTrigger(done: Int, lastAsked: String, version: String,
                                           discordShown: Bool, ratingPossible: Bool) -> String {
        Community.kickoff(done: done, ratingLast: lastAsked.isEmpty ? nil : lastAsked,
                             version: version, discordShown: discordShown,
                             ratingPossible: ratingPossible)?.rawValue ?? ""
    }

    /// The URLs from `Community`: "discord", "discordKurz", "play", "fehlerKurz", otherwise
    /// the GitHub issue with version and platform.
    public static func communityAddress(art: String, version: String, platform: String) -> String {
        switch art {
        case "discord": Community.discord.absoluteString
        case "discordKurz": Community.discordShort
        case "play": Community.playStore.absoluteString
        case "fehlerKurz": Community.errorShort
        default: Community.errorReport(version: version, platform: platform).absoluteString
        }
    }

    /// `Refresh.dueReturn`: reload if the last state is older than 30 s.
    /// `lastMs` in milliseconds since 1970, 0 means never loaded.
    public static func refreshDue(lastMs: Int64) -> Bool {
        Refresh.dueReturn(recent: lastMs > 0 ? Date(timeIntervalSince1970: Double(lastMs) / 1000) : nil)
    }

    // MARK: Stream watchdog

    /// **If the stream stalls, it is rebuilt.** The thresholds live in `StreamWatch` in the
    /// package, as on iOS/tvOS (`VLCPlayer.checkStandstill`) and Linux (`Spieler.streamCheck`).
    /// Kotlin only measures the times. `networkChangeForward` < 0 means no change. Answer: `notYet`,
    /// `jumpRunning`, `bufferGrows` or `newConnect`.
    public static func streamWatchRat(standstillSince: Double, networkChangeForward: Double, jumpOpen: Bool,
                                     lastJumpForward: Double, bufferGrewPre: Double) -> String {
        switch StreamWatch.rat(standstillSince: standstillSince,
                              networkChangeForward: networkChangeForward < 0 ? nil : networkChangeForward,
                              jumpOpen: jumpOpen, lastJumpForward: lastJumpForward,
                              bufferGrewPre: bufferGrewPre) {
        case .notYet: return "nochNicht"
        case .jumpRunning: return "sprungLaeuft"
        case .bufferGrows: return "pufferWaechst"
        case .newConnect: return "neuVerbinden"
        }
    }

    /// Are the frames standing while the clock runs? `before` < 0: no reference value yet, so no.
    public static func streamWatchImagesState(before: Int, now: Int) -> Bool {
        StreamWatch.imagesState(before: before < 0 ? nil : UInt64(before), now: UInt64(max(now, 0))) == true
    }

    /// How long a network change counts as fresh: a drop at the end of a film without a length counts only then.
    public static func streamWatchNetworkChangeDeadline() -> Double { StreamWatch.networkSwitchDeadline }

    // MARK: First frame (mirrors `VLCPlayer.firstFrameCheck` on Apple, rule `FirstFrame` in the package)

    /// Advice for a stream that has never shown a frame. `bisher` is ``Erstbild/Stufe`` as a number.
    /// Answer: `nothing`, `wait`, `outputNew`, `softwareDecoder` or `giveUp`.
    public static func firstFrameRat(hasVideoTrack: Bool, excluded: Bool, shown: Int, runtime: Double,
                                   untilFrom: Int) -> String {
        let rung = FirstFrame.Level(rawValue: untilFrom) ?? .no
        switch FirstFrame.rat(hasVideoTrack: hasVideoTrack, excluded: excluded,
                            shown: UInt64(max(shown, 0)), runtime: runtime, untilFrom: rung) {
        case .nothing: return "nichts"
        case .wait: return "warten"
        case .outputNew: return "ausgabeNeu"
        case .softwareDecoder: return "softwareDekoder"
        case .giveUp: return "aufgeben"
        }
    }

    /// The stage after advice from ``firstFrameRat(hasVideoTrack:excluded:shown:runtime:bisher:)``.
    public static func firstFrameNext(rat: String, untilFrom: Int) -> Int {
        let rung = FirstFrame.Level(rawValue: untilFrom) ?? .no
        let r: FirstFrame.Rat = switch rat {
        case "ausgabeNeu": .outputNew
        case "softwareDekoder": .softwareDecoder
        case "aufgeben": .giveUp
        default: .nothing
        }
        return FirstFrame.next(to: r, untilFrom: rung).rawValue
    }

    /// Elapsed film time between two looks; `before` < 0: no previous value yet.
    public static func firstFrameGrowth(before: Double, now: Double) -> Double {
        FirstFrame.growth(before: before < 0 ? nil : before, now: now)
    }

    /// The hint for the tech badge; empty as long as nothing intervened.
    public static func firstFrameHint(rung: Int) -> String {
        FirstFrame.hint(FirstFrame.Level(rawValue: rung) ?? .no) ?? ""
    }

    /// The `codec` option for the software decoder.
    public static func firstFrameSoftwareOption() -> String { FirstFrame.softwareOption }

    /// Codec of the video track according to the server, empty without a video track; then the first-frame rule does not apply.
    public func firstFrameVideoCodec() -> String {
        barrier.lock(); let w = _playback; barrier.unlock()
        guard let q = w?.plan.source, let v = FileDetails.videoTrack(q) else { return "" }
        return v.codec ?? "?"
    }

    // MARK: Delay (mirrors `Delay` in the package, `VLCPlayer.delayCatchUp` on Apple)
    //
    // The value travels as milliseconds (always a multiple of the step); every rule (step,
    // limit, rounding, display, keeping across episode switches, re-applying) lives in the package.

    /// Display and limits: `{milliseconds, text, isNull, atStart, atEnd}`. `language` is the
    /// device language (`de-DE`); the decimal separator comes from it, not from `Locale.current`.
    public static func delayState(milliseconds: Int, language: String) -> String {
        let v = Delay(milliseconds: milliseconds)
        return encoded(DelayResponse(milliseconds: v.milliseconds,
                                            text: v.text(locale: Locale(identifier: language)),
                                            isNull: v.isNull, atStart: v.atStart, atEnd: v.atEnd))
    }

    /// Earlier (-1) or later (+1), by `schritte` steps (from ``delayPress(row:)``).
    public static func delayShifted(milliseconds: Int, bearing: Int, steps: Int) -> Int {
        Delay(milliseconds: milliseconds).shifted(bearing, steps: steps).milliseconds
    }

    /// A press on - or + in `row`: how many steps it counts (`Haltezaehler`: held is faster).
    public func delayPress(row: String) -> Int {
        barrier.lock(); defer { barrier.unlock() }
        var counter = _holdCounter[row] ?? Delay.HoldCounter()
        let steps = counter.press()
        _holdCounter[row] = counter
        return steps
    }

    /// On switching to another title: the same title or the same series keeps it, otherwise null.
    /// An empty series means none.
    public static func delayForNewTitle(milliseconds: Int, oldTitle: String, oldSeries: String,
                                                  newTitle: String, addedSeries: String) -> Int {
        Delay.forNewTitle(Delay(milliseconds: milliseconds),
                                    oldTitle: oldTitle, oldSeries: oldSeries.isEmpty ? nil : oldSeries,
                                    newTitle: newTitle, addedSeries: addedSeries.isEmpty ? nil : addedSeries).milliseconds
    }

    /// For libVLC (`setSpuDelay`/`setAudioDelay`).
    public static func delayMicroseconds(milliseconds: Int) -> Int {
        Delay(milliseconds: milliseconds).microseconds
    }

    /// Does libVLC read something other than intended? Then re-apply.
    public static func delaySoftFrom(milliseconds: Int, readMicroseconds: Int) -> Bool {
        Delay(milliseconds: milliseconds).softOff(fromMicroseconds: readMicroseconds)
    }

    // MARK: Remote control

    /// **Report capabilities and listen** (`AppModel.remoteControlStart`). Both are needed:
    /// without the report the dashboard buttons stay grey, without the socket the commands never
    /// arrive. Without both, `Sessions?controllableByUserId` does not return this session, and no
    /// other device offers "Continue here".
    public func remoteControlStart() async {
        barrier.lock(); let c = _client; let already = _remote != nil; barrier.unlock()
        guard let c, !already else { return }
        try? await c.reportCapabilities()
        guard let controls = try? await c.remoteControl() else { return }
        barrier.lock()
        if _remote != nil { barrier.unlock(); return }
        _remote = controls
        barrier.unlock()
        let store = remoteStore
        // Watch together hangs on the same channel; before `start`, so nothing is lost.
        let session = gemeinsam
        await controls.syncPlayHear { session.accept($0) }
        // The handover hint comes before the stop (`AppModel.handoffTarget` on Apple).
        await controls.handoffHear { store.hintStore($0) }
        await controls.start { command in store.stash(command) }
        await session.rightFetch()
    }

    /// On sign-out and account switch: forget first, so a new start does not hang on the old one.
    public func remoteControlEnd() async {
        barrier.lock(); let alt = _remote; _remote = nil; barrier.unlock()
        await alt?.syncPlayHear(nil)
        await alt?.handoffHear(nil)
        await alt?.finish()
        _ = remoteStore.pickUp()
        // `setzen` already makes the group leave with the old account's client; an open request belongs to it as well.
        sharedRequest.wipe()
    }

    /// What has arrived since the last pickup; the player collects it on its tick.
    public func remoteCommands() -> String {
        Self.encoded(remoteStore.pickUp())
    }

    // MARK: Watch together (mirrors `SharedModel` in Sources/Shared, flow in `SyncPlaySession`)

    /// The session, created on first access. It asks for the currently valid client at every
    /// step; its messages land as JSON in ``sharedPanel``.
    private var gemeinsam: SyncPlaySession {
        barrier.lock(); defer { barrier.unlock() }
        if let s = _shared { return s }
        let s = SyncPlaySession(
            client: { [weak self] in self?.client },
            ich: { [weak self] in self?.lockRead { self?._session?.userName } },
            titleLoad: { [weak self] title, since in await self?.sharedTitleLoad(title, since: since) ?? false })
        _shared = s
        Task { [weak self] in
            for await m in s.withPart { self?.sharedMessage(m) }
        }
        return s
    }

    private func sharedMessage(_ m: SyncPlayMessage) {
        barrier.lock()
        switch m {
        case let .status(new): _sharedStatus = new
        case let .error(f): _sharedError = f.text; _sharedErrorNumber += 1
        }
        barrier.unlock()
        sharedPublic()
    }

    private func sharedPublic() {
        barrier.lock()
        let answer = SharedResponse(_sharedStatus, ich: _session?.userName, error: _sharedError,
                                       errorNumber: _sharedErrorNumber, accepted: _sharedAccepted)
        barrier.unlock()
        sharedPanel.setDown(Self.encoded(answer))
    }

    /// The server accepted create or join: the sheet may close while the control channel is still being awaited.
    private func sharedAccepted() {
        barrier.lock(); _sharedAccepted += 1; barrier.unlock()
        sharedPublic()
    }

    /// **The group sets a title** (`SharedModel.titleLoad`): if a player is attached, it
    /// switches there (`load` step); otherwise the core stores a request and Kotlin opens the
    /// player. `false` if the title does not exist for this account.
    private func sharedTitleLoad(_ title: String, since: Double) async -> Bool {
        guard let c = client, (try? await c.item(id: title)) != nil else { return false }
        barrier.lock(); let player = _sharedPlayer; barrier.unlock()
        if let player {
            player.load(title, since: since)
        } else {
            sharedRequest.put(Self.encoded(SharedRequest(title: title, since: since)))
        }
        return true
    }

    /// **The state, as soon as it is newer than `to`:** immediately if it already is, otherwise
    /// at the next change. `{"stand": n, "lage": {...}}`, the state like ``SharedResponse``.
    public func syncPlayStatus(to: Int) async -> String {
        _ = gemeinsam
        return await sharedPanel.fetch(to: to)
    }

    /// **Waits until the group wants to open a player:** `{"titel": ..., "ab": ...}`. Empty if the
    /// request was discarded (sign-out) or a second call replaced this one.
    public func syncPlayRequest() async -> String {
        await sharedRequest.fetch()
    }

    /// Ask for groups once, on the tick of "Continue here", not while the player runs.
    public func syncPlayOfferingsAsk() async {
        await gemeinsam.offeringsAsk()
    }

    /// Open a group and set the title right away. An empty name becomes "Filmabend" (in the package).
    public func syncPlayCreate(name: String, title: String) async -> Bool {
        await gemeinsam.create(name: name, title: title, accepted: { [weak self] in self?.sharedAccepted() })
    }

    /// Join a group from ``SharedResponse/angebote``.
    public func syncPlayJoin(group: String) async -> Bool {
        let s = gemeinsam
        guard let g = await s.status.offerings.first(where: { $0.id == group }) else { return false }
        return await s.join(g, accepted: { [weak self] in self?.sharedAccepted() })
    }

    /// "Rejoin" in the strip after leaving.
    public func syncPlayAgainJoin() async {
        await gemeinsam.againJoin()
    }

    /// **The player is open.** If the title belongs to what the group is watching, it is attached,
    /// and the answer is a mark (> 0) with which Kotlin assigns tick, steps and detach.
    /// `0`: not in the group; the player then plays alone.
    public func syncPlayConnect(title: String) async -> Int {
        let s = gemeinsam
        guard await s.status.belongsGroup(title) else { return 0 }
        barrier.lock()
        _sharedMark += 1
        let player = CorePlayer(title: title, mark: _sharedMark)
        let alt = _sharedPlayer
        _sharedPlayer = player
        _withoutNext = true
        _playback?.next = nil
        barrier.unlock()
        alt?.steps.wipe()
        await s.plugIn(player)
        return player.mark
    }

    /// **The player closes; that is leaving.**
    public func syncPlayDetach(mark: Int) {
        barrier.lock()
        guard let player = _sharedPlayer, player.mark == mark, let s = _shared else { barrier.unlock(); return }
        _sharedPlayer = nil
        _withoutNext = false
        barrier.unlock()
        player.steps.wipe()
        Task { await s.detach() }
    }

    /// **The player's state, on the display tick**, and the tick for the session (reporting buffering).
    public func syncPlayTick(mark: Int, title: String, ready: Bool, spot: Double, running: Bool) {
        barrier.lock()
        guard let player = _sharedPlayer, player.mark == mark, let s = _shared else { barrier.unlock(); return }
        let trigger = !_sharedTickRuns
        if trigger { _sharedTickRuns = true }
        barrier.unlock()
        player.tick(title: title, ready: ready, spot: spot, running: running)
        guard trigger else { return }
        Task { [weak self] in
            await s.playerTick()
            self?.barrier.lock(); self?._sharedTickRuns = false; self?.barrier.unlock()
        }
    }

    /// **The next step for the player:** `{"art": "weiter"|"anhalten"|"springen"|"laden",
    /// "wert": seconds, "titel": ...}`. Returns as soon as the session gives one; empty if the
    /// player is detached.
    public func syncPlayStep(mark: Int) async -> String {
        barrier.lock(); let player = _sharedPlayer; barrier.unlock()
        guard let player, player.mark == mark else { return "" }
        return await player.steps.fetch()
    }

    /// Pause and resume as a request to the server. The button only flips when the command arrives.
    public func syncPlayPleaseToggle(runningCurrently: Bool) {
        let s = gemeinsam
        Task { await s.bitToggle(runningCurrently: runningCurrently) }
    }

    /// **A different episode, for everyone:** the episode choice in the player resets the queue
    /// in the group instead of switching alone (`SyncPlaySession.bitTitle`).
    public func syncPlayPleaseTitle(title: String) {
        let s = gemeinsam
        Task { await s.bitTitle(title) }
    }

    public func syncPlayPleaseJump(on seconds: Double) {
        let s = gemeinsam
        Task { await s.bitJump(on: max(0, seconds)) }
    }

    // MARK: Continue here

    /// What runs on another device of the same account and can be taken over. The rule
    /// (`Takeover.offerings`: not us, same account, accepts commands, moved in the last 90 s)
    /// lives in the package. **An error is not an error here:** there is simply no offer.
    public func takeoverOfferings() async -> String {
        barrier.lock(); let c = _client; let s = _session; let a = _addresses; barrier.unlock()
        guard let c, let s, let all = try? await c.remoteSession() else { return "[]" }
        let offerings = Takeover.offerings(from: all, ownDevicesIdentifier: devicesIdentifier, ownUserIdentifier: s.userID)
        return Self.encoded(offerings.compactMap { f -> OfferingReply? in
            guard let title = f.running, !title.id.isEmpty else { return nil }
            let art: String
            switch f.devicesKind {
            case .phone: art = "telefon"
            case .tablet: art = "tablet"
            case .computer: art = "rechner"
            case .tv: art = "fernseher"
            case .unknown: art = "unbekannt"
            }
            let spot = f.state?.spot ?? 0
            return OfferingReply(id: f.id, itemID: title.id, device: f.deviceName, art: art,
                                  titleLine: f.titleLine, spot: spot, pointText: timeText(spot),
                                  image: a.flatMap { Self.cardImage(title, addresses: $0) }, name: title.name,
                                  series: title.seriesName, seasonNr: title.parentIndexNumber, episodeNr: title.indexNumber)
        })
    }

    /// **Take over as on Apple** (`TakeoverModel.adopt`): first the hint to the giver
    /// (only to Swiftly, `Takeover.takesHint`), then the stop, then up to 1.5 s in 100 ms
    /// steps for the position the giver reports on ending (`Takeover.startPoint`).
    /// `ownName`: how this device is named in the hint ("Android", "Android TV"); the giver
    /// then picks the direction of flight (`HandoffCard.departurePostTop`).
    /// Answer `{"grund": "", "ab": seconds}`; a non-empty reason means: do not start here.
    public func handedOver(session: String, itemID: String, spot: Double, ownName: String) async -> String {
        guard let c = client else { return Self.encoded(HandoffResponse(reason: "nichtVerbunden", since: spot)) }
        let clock = Date()
        func time(_ was: String) { log("[Uebergabe] +\(Int(Date().timeIntervalSince(clock) * 1000)) ms \(was)") }
        time("Tipp")
        async let savedFetch = try? c.item(id: itemID)
        async let sessionsFetch = try? c.remoteSession()
        let before = await savedFetch?.userData?.playbackPositionTicks
        let freshValue = await sessionsFetch?.first { $0.id == session }
        let sessionPoint = freshValue?.state?.spot ?? spot
        if let freshValue, Takeover.takesHint(freshValue) {
            do { try await c.handoffHint(an: session, device: ownName); time("Hinweis gesendet") }
            catch { log("[Uebergabe] Hinweis nicht gesendet: \(error)") }
        }
        do { try await c.foreignCommand(.finish, an: session) }
        catch { return Self.encoded(HandoffResponse(reason: coreErrorText(error), since: spot)) }
        time("Stopp angenommen")
        var afterwards: Int64?
        for _ in 0 ..< 15 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let now = (try? await c.item(id: itemID))?.userData?.playbackPositionTicks
            if now != before { afterwards = now; break }
        }
        let since = Takeover.startPoint(session: sessionPoint, savedBefore: before, savedAfterwards: afterwards)
        time(afterwards == nil ? "Stelle nicht gemeldet" : "Stelle gemeldet")
        log("[Uebernahme] Sitzung \(Int(sessionPoint)) s, nach Stopp "
            + "\(afterwards.map { String(Int(Double($0) / 10_000_000)) } ?? "—") s → ab \(Int(since)) s")
        return Self.encoded(HandoffResponse(reason: "", since: since))
    }

    /// **Who is taking over right now**, if the last hint is fresh (`Takeover.isHandoff`), and
    /// only once: it applies to exactly this stop (`AppModel.handoffTargetTake`). Empty: an ordinary stop.
    public func handoffTargetTake() -> String {
        remoteStore.takeHint() ?? ""
    }

    // MARK: Handover card (times, springs and dimensions from `HandoffCard` in the package)

    /// Dimensions, positions and times for a screen of `width` x `height` dp. `tv`: the
    /// TV's dimensions, computed in tvOS points and halved (Android TV computes in halves).
    public static func handoffStates(width: Double, height: Double, tv: Bool) -> String {
        encoded(HandoffPath.situations(width: width, height: height, tv: tv))
    }

    /// Where the giver's card flies: up to the larger device (`HandoffCard.departurePostTop`).
    public static func handoffToTop(from: String, to: String) -> Bool {
        HandoffCard.departurePostTop(from: from, to: to)
    }

    /// **The path as sample points**, 120 per second (`HandoffPath.compute`). Input and answer JSON, in dp.
    public static func handoffLane(typedInput: String) -> String {
        guard let e = try? JSONDecoder().decode(HandoffPath.Input.self, from: Data(typedInput.utf8)) else { return "{}" }
        return encoded(HandoffPath.compute(e))
    }

    /// Stop the device. **Empty means: stopped**; only then does Android start here. If it keeps
    /// playing there, two audio tracks would be in the room.
    public func adopt(session: String) async -> String {
        guard let c = client else { return "nichtVerbunden" }
        do { try await c.foreignCommand(.finish, an: session); return "" }
        catch { return coreErrorText(error) }
    }

    // MARK: Downloads

    /// Item for a download, with the images that go to disk too. **The same source the player
    /// would take:** the title's first one, otherwise the one from the playback plan.
    public func downloadItem(ids: [String]) async -> String {
        barrier.lock(); let c = _client; let a = _addresses; let s = _session; barrier.unlock()
        guard let c, let a, let account = s?.userID else { return "[]" }
        let limit = profileBitrate
        var fetched: [String: (Item, MediaSource?)] = [:]
        await withTaskGroup(of: (String, Item, MediaSource?)?.self) { group in
            for id in ids {
                group.addTask {
                    guard let i = try? await c.item(id: id) else { return nil }
                    if let q = i.mediaSources?.first { return (id, i, q) }
                    let plan = (try? await c.playbackPlan(for: id, profile: .vlc(maxBitrate: limit))) ?? nil
                    return (id, i, plan?.source)
                }
            }
            for await r in group { if let r { fetched[r.0] = (r.1, r.2) } }
        }
        var answer: [DownloadResponse] = []
        for id in ids {
            guard let (i, q) = fetched[id] else { continue }
            let episode = i.type == "Episode"
            let entries = DownloadItem(
                id: i.id, account: account, art: episode ? .episode : .film, title: i.name,
                series: episode ? i.seriesName : nil, seriesIdentifier: episode ? i.seriesId : nil,
                season: episode ? i.parentIndexNumber : nil, episode: episode ? i.indexNumber : nil,
                runtimeTicks: i.runTimeTicks, container: q?.container, source: q?.id, bytes: q?.size ?? 0,
                watchState: i.userData, videoCodec: q?.videoCodec)
            let image: URL? = episode ? await c.imageURL(for: i, maxHeight: 220)
                                   : a.construct(itemID: i.id, mark: i.imageTags?["Primary"], mass: .atMostHigh(600))
            let seriesImage: URL? = episode ? i.seriesId.flatMap { a.construct(itemID: $0, mark: nil, mass: .atMostHigh(600)) } : nil
            answer.append(DownloadResponse(entries: entries, image: image?.absoluteString, seriesImage: seriesImage?.absoluteString))
        }
        return Self.encoded(answer)
    }

    /// The same URL as for streaming, without a session; otherwise the device would show as
    /// "playing now" on the server. Not `/Items/{id}/Download`: that needs its own right.
    /// `quality` is the raw value of `DownloadQuality` (`"original"`, `"hd720"` ...); empty
    /// or unknown counts as original. Converted, it is `/Videos/{id}/stream.mkv` with `static=false`.
    public func downloadAddress(id: String, source: String, quality: String) async throws -> String {
        return try await throwReadable { () async throws -> String in
            guard let c = client else { throw CoreError.notConnected }
            return try await c.downloadURL(itemID: id, mediaSourceID: source.isEmpty ? nil : source,
                                           quality: DownloadQuality(rawValue: quality) ?? .original).absoluteString
        }
    }

    // MARK: Quality when downloading (all from `DownloadQuality`, so Kotlin computes nothing)

    private struct QualityResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case id
        case row = "zeile"
        case badge = "plakette"
    }
 let id, row, badge: String }

    /// The steps for a choice, original first. `dateien` is JSON `[[bytes, ticks], ...]`; the
    /// highest source bitrate decides which steps make it smaller.
    public static func downloadQualities(selectable: Bool, files: String) -> String {
        let pairs = (try? JSONDecoder().decode([[Int64]].self, from: Data(files.utf8))) ?? []
        let source = DownloadQuality.sourceBitrateOf(pairs.compactMap {
            $0.count == 2 ? (bytes: $0[0], runtimeTicks: $0[1] > 0 ? $0[1] : nil) : nil
        })
        return encoded(DownloadQuality.offered(selectable: selectable, sourceBitrateOf: source).map {
            QualityResponse(id: $0.rawValue, row: $0.name + " · " + $0.addition(), badge: $0.badge())
        })
    }

    /// Estimated size at a step; for the original, `bytes` itself.
    public static func downloadEstimated(quality: String, bytes: Int64, ticks: Int64) -> Int64 {
        (DownloadQuality(rawValue: quality) ?? .original)
            .estimatedBytes(original: bytes, runtimeTicks: ticks > 0 ? ticks : nil)
    }

    /// What the badge shows: "Direct Play · Original quality" or "720p · 4 Mbit/s".
    public static func downloadBadge(quality: String) -> String {
        (DownloadQuality(rawValue: quality) ?? .original).badge()
    }

    /// "720p" for the download list; empty for the original.
    public static func downloadQualityName(quality: String) -> String {
        guard let q = DownloadQuality(rawValue: quality), !q.isOriginal else { return "" }
        return q.name
    }

    /// The items (JSON list, as `downloadItem` returns them) in another quality: Matroska and
    /// estimated size (`DownloadItem.inQuality`).
    public static func downloadInQuality(list: String, quality: String) -> String {
        let q = DownloadQuality(rawValue: quality) ?? .original
        return encoded(itemRead(list).map { $0.inQuality(q) })
    }

    /// The step all episodes of a group carry; otherwise empty (`DownloadQuality.gemeinsam`).
    public static func downloadShared(list: String) -> String {
        DownloadQuality.gemeinsam(itemRead(list))?.name ?? ""
    }

    private static func itemRead(_ raw: String) -> [DownloadItem] {
        (try? JSONDecoder().decode([DownloadItem].self, from: Data(raw.utf8))) ?? []
    }

    public static func downloadNext(list: String, wLAN: Bool, onlyOverWLAN: Bool) -> String {
        DownloadRules.nextOne(from: itemRead(list), wLAN: wLAN, onlyOverWLAN: onlyOverWLAN)?.id ?? ""
    }

    public static func downloadMayLoad(wLAN: Bool, onlyOverWLAN: Bool) -> Bool {
        DownloadRules.mayLoad(wLAN: wLAN, onlyOverWLAN: onlyOverWLAN)
    }

    /// **The sentence for an HTTP status the download received.**
    ///
    /// On Android the download itself runs in Kotlin because it must pause and resume; the words
    /// still come from here. Otherwise Kotlin would hold a second sentence list next to
    /// `readableError`, and the download page showed a literal "HTTP 404" in every language.
    public static func downloadErrorText(status: Int) -> String {
        readableError(JellyfinError.http(status: status, body: nil))
    }

    public static func downloadSpace(bytes: Int64, free: Int64, list: String) -> String {
        let p = DownloadRules.slot(for: bytes, free: free, available: itemRead(list))
        return encoded(SpaceResponse(suffices: p.suffices, freeAfter: p.freeAfter, dispensable: p.dispensable.map(\.id),
                                    dispensableBytes: p.dispensableBytes, sufficesToCleanUp: p.sufficesToCleanUp))
    }

    /// A series is one row.
    public static func downloadGroups(list: String) -> String {
        encoded(DownloadRules.grouped(itemRead(list)).map { g -> DownloadGroupsResponse in
            switch g {
            case let .single(p): DownloadGroupsResponse(id: g.id, title: g.title, bytes: g.bytes, seriesIdentifier: nil, episodes: [p.id])
            case let .series(sid, _, f): DownloadGroupsResponse(id: g.id, title: g.title, bytes: g.bytes, seriesIdentifier: sid, episodes: f.map(\.id))
            }
        })
    }

    public static func downloadSize(bytes: Int64) -> String { DownloadRules.size(bytes) }

    /// Catch up watch state and "still on the server". **Without an answer everything stays as it
    /// was:** on the road no server answers, and otherwise every title would read "no longer on the
    /// server". A newer state from here stays (`Downloadregeln.nachziehen`, like `Downloadverwaltung.nachziehen`).
    public func downloadsCatchUp(list: String) async -> String {
        guard let c = client else { return list }
        var entries = Self.itemRead(list)
        guard !entries.isEmpty else { return list }
        let ids = entries.map(\.id)
        var available: Set<String> = []
        var watchState: [String: UserItemData] = [:]
        for since in stride(from: 0, to: ids.count, by: 100) {
            let piece = Array(ids[since ..< min(since + 100, ids.count)])
            guard let answer = try? await c.items(limit: piece.count, ids: piece) else { return list }
            for t in answer.items {
                available.insert(t.id)
                watchState[t.id] = t.userData
            }
        }
        for i in entries.indices {
            entries[i].stillOnTheServer = available.contains(entries[i].id)
            if available.contains(entries[i].id) { entries[i] = DownloadRules.follow(entries[i], watchState: watchState[entries[i].id]) }
        }
        return Self.encoded(entries)
    }

    /// **The current account's downloads and the network state**, after every list change and
    /// every network change. `folder` is the folder the files are in.
    public func downloadsKnown(list: String, folder: String, withoutNetwork: Bool) {
        let entries = Self.itemRead(list)
        barrier.lock(); _downloads = entries; _downloadFolder = folder; _withoutNetwork = withoutNetwork; barrier.unlock()
    }

    /// **Intro and outro to store**, after downloading and for older downloads on next contact
    /// (`DownloadManager.sectionsFetch`). Empty means: no answer, try again later; otherwise
    /// the sections as JSON, in the form `DownloadItem.sections` carries them.
    public func downloadSections(id: String) async -> String {
        guard let c = client, let parts = await c.segmentsToStore(for: id) else { return "" }
        log("Abschnitte fuer \(id): \(parts.count)")
        return Self.encoded(parts)
    }

    /// Where the download list starts playing, in seconds (`DownloadItem.resumeFrom`); 0 means from the start.
    public static func downloadResumeFrom(entries: String) -> Double {
        (try? JSONDecoder().decode(DownloadItem.self, from: Data(entries.utf8)))?.resumeFrom ?? 0
    }

    /// **What the stops since the last pickup mean**, mirrors `AppModel.reportStopped`: every stop
    /// of a download records position, watched state and time on the item
    /// (`DownloadItem.postPlayback`), and one that arrived clears the pending catch-up
    /// report of the same title (`PostReportRules.ueberholt`). Answer: `store` (the new catch-up
    /// reports) and `entries` (only the changed ones).
    public func stoppsProcess(store: String, list: String) -> String {
        barrier.lock(); let stopps = _stopps; _stopps = []; barrier.unlock()
        var messages = Self.pendingReportsRead(store)
        var entries = Self.itemRead(list)
        var changed: Set<String> = []
        for s in stopps {
            if s.sent { messages = PostReportRules.overFetches(itemID: s.itemID, account: s.account, in: messages) }
            if let i = entries.firstIndex(where: { $0.id == s.itemID && $0.account == s.account }) {
                entries[i] = entries[i].postPlayback(ticks: s.ticks, moment: s.moment)
                changed.insert(entries[i].id)
            }
        }
        return Self.encoded(StopResponse(store: Self.encoded(messages), entries: entries.filter { changed.contains($0.id) }))
    }

    /// Playback from disk, **before any server**, so no timeout waits on a plane. `image` is the
    /// stored file for the media controls. Sections and next episode are there immediately as far
    /// as they are known without a server; `playbackLookUp` brings the rest.
    public func playbackFromTheSlab(entries: String, path: String, image: String) throws -> String {
        let p = try JSONDecoder().decode(DownloadItem.self, from: Data(entries.utf8))
        barrier.lock()
        let w = Self.slab(p, file: URL(fileURLWithPath: path), from: _downloads, image: image.isEmpty ? nil : image)
        _playback = w; _episodesSwitch = EpisodeSwitch()
        barrier.unlock()
        return try playbackPlanResponse(w)
    }

    // MARK: Catch-up reports

    private static func pendingReportsRead(_ raw: String) -> [PendingReport] {
        (try? JSONDecoder().decode([PendingReport].self, from: Data(raw.utf8))) ?? []
    }

    /// One per title and account; the newer wins.
    public static func pendingReportRecord(store: String, message: String) -> String {
        guard let m = try? JSONDecoder().decode(PendingReport.self, from: Data(message.utf8)) else { return store }
        return encoded(PostReportRules.record(m, in: pendingReportsRead(store)))
    }

    /// After a successful connection, before catching up the downloads. **The package decides
    /// what applies** (`JellyfinClient.reportLater`): oldest first, a newer state on the server
    /// wins, on the first error the rest stays. **Never twice at once**, mirrors
    /// `AppModel.pendingSubmit`. Answer: the finished IDs as JSON; Kotlin removes them
    /// from the storage as it is **then** (`pendingDone`), since a new one may have
    /// arrived while waiting.
    public func pendingSubmit(store: String) async -> String {
        barrier.lock()
        let c = _client, s = _session, free = !_reportLaterRuns
        if free, c != nil, s != nil { _reportLaterRuns = true }
        barrier.unlock()
        guard free, let c, let account = s?.userID else { return "[]" }
        defer { barrier.lock(); _reportLaterRuns = false; barrier.unlock() }
        let opened = PostReportRules.due(Self.pendingReportsRead(store), account: account)
        guard !opened.isEmpty else { return "[]" }
        let rows = logRows
        let completed = await c.reportLater(opened) { row in
            rows.write(row)
            LogRing.shared.append(row)
        }
        return Self.encoded(completed)
    }

    /// Remove the finished catch-up reports from the storage (`PostReportRules.completed`).
    public static func pendingDone(store: String, completed: String) -> String {
        let ids = (try? JSONDecoder().decode([String].self, from: Data(completed.utf8))) ?? []
        guard !ids.isEmpty else { return store }
        return encoded(PostReportRules.completed(ids, in: pendingReportsRead(store)))
    }

    // MARK: Seerr

    private var seerr: SeerrClient? { barrier.lock(); defer { barrier.unlock() }; return _seerr }

    /// Sets the remembered access; Kotlin stores it encrypted per Jellyfin server.
    public func seerrSet(access: String) {
        let z = try? JSONDecoder().decode(SeerrAccess.self, from: Data(access.utf8))
        barrier.lock(); _seerr = z.map { SeerrClient(access: $0) }; barrier.unlock()
    }

    /// The connection's cookie goes too, not only the remembered access: a still-valid session
    /// in memory keeps Seerr from issuing a new one on the next sign-in (`Seerr.cookiesForget`).
    public func seerrDisconnect() {
        barrier.lock()
        let address = _seerr?.address
        _seerr = nil
        barrier.unlock()
        if let address { Seerr.cookiesForget(for: address) }
    }

    /// Connects with Jellyfin's own name and password. **A second scheme only if it was guessed**
    /// (`Seerr.addresses`), and only after a network error, never after a wrong password.
    /// Answer: the access as JSON; the password is stored nowhere. `headers` from "Advanced", for
    /// an outpost in front of Seerr; they end up in the access (`SeerrAccess`), so in the vault.
    public func seerrConnect(address: String, user: String, password: String, headers: String) async throws -> String {
        return try await throwReadable { () async throws -> String in
            let addresses = Seerr.addresses(from: address)
            guard !addresses.isEmpty else { throw CoreError.address(address) }
            var lastOne: Error = CoreError.address(address)
            for url in addresses {
                do {
                    let access = try await SeerrClient.signIn(an: url, user: user, password: password,
                                                                    headers: Self.headersRead(headers))
                    barrier.lock(); _seerr = SeerrClient(access: access); barrier.unlock()
                    return try json(access)
                } catch let error as URLError {
                    lastOne = error
                }
            }
            throw lastOne
        }
    }

    public func seerrApplies() async -> Bool {
        guard let s = seerr else { return false }
        return await s.applies()
    }

    /// Only what the own server does not have yet; the rest is in the upper block.
    public func seerrSearch(term: String) async -> String {
        guard let s = seerr, DisplayRules.searchTermFits(term) else { return "[]" }
        return Self.encoded((await s.searching(term)).filter { !$0.state.alreadyPresent }.map(Self.seerrTile))
    }

    public func seerrFilmography(tmdb: Int) async -> String {
        guard let s = seerr else { return "[]" }
        return Self.encoded((await s.filmography(person: tmdb)).filter { !$0.state.alreadyPresent }.map(Self.seerrTile))
    }

    /// Details and suggestions: Seerr fetches both side by side; if suggestions are missing, the rest still shows.
    public func seerrDetail(art: String, id: Int) async -> String {
        guard let s = seerr, let d = await s.detail(art: art, id: id) else { return "{}" }
        return Self.encoded(SeerrDetailResponse(
            description: d.description, genres: d.genres, runtime: d.runtime, rating: d.rating,
            seasons: d.seasons.map { SeerrSeasonResponse(number: $0.number, episodes: $0.episodes, state: $0.state.rawValue, requestable: $0.state.requestable) },
            cast: d.cast.map { PersonResponse(id: String($0.id), name: $0.name, role: $0.role, image: $0.image()?.absoluteString) },
            similarOne: d.similarOne.map(Self.seerrTile),
            state: d.state?.rawValue, requestable: d.state?.requestable))
    }

    /// Empty means done. `seasons` as "1,2": meaningless for a movie, never empty for a series.
    public func seerrRequest(art: String, id: Int, seasons: String) async -> String {
        guard let s = seerr else { return "nichtAngemeldet" }
        let serialNumbers = seasons.split(separator: ",").compactMap { Int($0) }
        if art == "tv", serialNumbers.isEmpty { return "" }
        do { try await s.askFor(art: art, id: id, seasons: art == "tv" ? serialNumbers : nil); return "" }
        catch { return coreErrorText(error) }
    }

    private static func seerrTile(_ t: SeerrHit) -> SeerrTileResponse {
        SeerrTileResponse(id: t.id, art: t.art, title: t.title, year: t.year, poster: t.poster()?.absoluteString,
                           backdrop: t.backdrop()?.absoluteString, state: t.state.rawValue, requestable: t.state.requestable)
    }

    // MARK: Person

    /// The person page (`PersonView.load()` without Seerr): the information about the person,
    /// their titles on the server (`JellyfinClient.title(person:)`, the rule is in the package)
    /// and the landscape images for the rotating banner.
    public func person(id: String) async throws -> String {
        return try await throwReadable { () async throws -> String in
            guard let c = client, let a = addresses else { throw CoreError.notConnected }
            async let ownOnes = c.title(person: id)
            let inquiry = try? await c.item(id: id)
            // **`nil` means disturbed, `[]` means "nothing on this server".** `JellyfinClient.title(person:)`
            // returns both separately, and the core folded them into one case here because the call
            // still returned `[Item]` before the change. The difference goes to the UI as `disrupted`, so
            // the person page does not say "no titles" when nobody answered.
            let fetched = await ownOnes
            let title = fetched ?? []
            // **Only what is really landscape** (`landscapeImageReal`): a cropped poster does not belong in
            // the rotation. If there is none, any header image is used.
            var banner = title.compactMap { ImageSelection.header($0, addresses: a)?.absoluteString }
            // **The same fallback as on the series page**, with the same episode as the last resort
            // (`AppModel.headerImageFallbackSearch`); otherwise a different image lands here than the one you
            // came from. A series without its own backdrop has its next episode's backdrop on the series
            // page; without this fallback it would be the poster here.
            if banner.isEmpty, let firstOne = title.first {
                var episode: Item?
                if firstOne.type == "Series" {
                    if let next = try? await c.nextEpisodeSeries(seriesID: firstOne.id) { episode = next }
                    if episode == nil { episode = (try? await c.episodes(seriesID: firstOne.id))?.first }
                }
                if let url = ImageSelection.headerWithFallback(firstOne, episode: episode, addresses: a) {
                    banner = [url.absoluteString]
                }
            }
            let image: URL? = a.construct(itemID: id, mark: inquiry?.imageTags?["Primary"], mass: .atMostHigh(300))
            let born = inquiry?.daysDate.flatMap { k -> String? in
                guard let year = k.year, let month = k.month, let tag = k.day else { return nil }
                return String(format: "%04d-%02d-%02d", year, month, tag)
            }
            return try json(PeoplePagesResponse(
                description: inquiry?.description, born: born,
                place: inquiry?.productionLocations?.first { !$0.isEmpty },
                image: image?.absoluteString, banner: banner,
                title: title.map { gridTile($0, a) }, tmdb: inquiry?.tmdbId,
                disrupted: fetched == nil))
        }
    }

    /// Similar titles and extras: `AppModel.similar(_:)` and `extras(_:)`. Errors give empty rows.
    public func titleField(id: String) async throws -> String {
        return try await throwReadable { () async throws -> String in
            guard let c = client, let a = addresses else { throw CoreError.notConnected }
            // The title itself goes along: its title key holds it and its hardlink duplicates out of the
            // row (`AppModel.similar`).
            let own = try? await c.item(id: id)
            async let alike = try? c.similar(itemID: id, toward: own)
            async let addition = try? c.extras(itemID: id)
            let ae = await alike ?? []
            let ex = await addition ?? []
            return try json(FieldResponse(
                similar: ae.map { gridTile($0, a) },
                extras: ex.map { e in
                    ExtraResponse(id: e.id, name: e.name, image: ImageSelection.landscape(e, addresses: a)?.url.absoluteString,
                                 runtime: DisplayRules.runtimeShow(seconds: e.runtimeSeconds)
                                     ? e.runtimeSeconds.map { runtime($0) } : nil)
                }))
        }
    }

    /// The first trailer that exists as its own file on the server. On tvOS it is first among the
    /// movie page's extras (`DetailView.task`: `model.trailer(toward:)`, `extras.insert(vorschau, at: 0)`).
    /// An empty JSON object if there is none or not connected; Kotlin then skips it.
    public func localTrailer(id: String) async -> String {
        guard let c = client, let a = addresses else { return "{}" }
        guard let t = (try? await c.trailer(toward: id))?.first else { return "{}" }
        return Self.encoded(ExtraResponse(
            id: t.id, name: t.name, image: ImageSelection.landscape(t, addresses: a)?.url.absoluteString,
            runtime: DisplayRules.runtimeShow(seconds: t.runtimeSeconds)
                ? t.runtimeSeconds.map { runtime($0) } : nil))
    }

    /// The episode after `episode` in the same series, for "Play next episode" in the More sheet
    /// of the series page (`TitleAction.forSeries`, `model.episodePost`). Empty if none follows.
    public func episodeAfter(episode: String, series: String) async -> String {
        guard let c = client else { return "" }
        guard let next = try? await c.episodePost(itemID: episode, seriesID: series) else { return "" }
        return next.id
    }

    /// Empty means done. Otherwise the reason: `nichtAngemeldet` as an identifier, the wording is in the app catalog.
    public func remember(id: String, an: Bool) async -> String {
        await handleRequest { try await $0.setWatchlist(itemID: id, an: an) }
    }

    public func watched(id: String, an: Bool) async -> String {
        await handleRequest { try await $0.setWatched(itemID: id, an: an) }
    }

    public func metadataRefresh(id: String) async -> String {
        await handleRequest { try await $0.metadataRefresh(id) }
    }

    private func handleRequest(_ perform: (JellyfinClient) async throws -> Void) async -> String {
        guard let c = client else { return "nichtAngemeldet" }
        do { try await perform(c); return "" } catch { return coreErrorText(error) }
    }

    /// The labels for sort and filter, in the order of `allCases`.
    public static func labels() -> String {
        let all = LabelResponse(
            sorting: Sorting.allCases.map { .init(value: $0.rawValue, text: $0.label) },
            filter: LibraryFilter.allCases.map { .init(value: $0.rawValue, text: $0.label) })
        return (try? JSONEncoder().encode(all)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// The same lines as `PosterTile`: for an episode series and number, otherwise title and year.
    /// The badge comes from `DisplayRules.tileMark`; Kotlin only inserts the wording.
    private func gridTile(_ i: Item, _ a: ImageAddress) -> GridTileResponse {
        let episode = i.type == "Episode"
        let (mark, figure): (String?, Int) = switch DisplayRules.tileMark(
            art: i.type, seasons: i.childCount, watched: i.userData?.played,
            openEpisodes: i.userData?.unplayedItemCount) {
        case .watched?: ("gesehen", 0)
        case .opened(let n)?: ("offen", n)
        case .seasons(let n)?: ("staffeln", n)
        case .none: (nil, 0)
        }
        return GridTileResponse(
            id: i.id, title: episode ? (i.seriesName ?? i.name) : i.name, type: i.type ?? "",
            subline: episode ? i.episodeCode : i.productionYear.map(String.init),
            poster: ImageSelection.portrait(i, addresses: a)?.absoluteString,
            progress: i.userData?.playedPercentage.map { $0 / 100 },
            mark: mark, markCount: figure)
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    // MARK: Download selection and progress

    private struct LoadSelectionEpisode: Encodable {
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case watched = "gesehen"
        case bytes
        case ticks
    }
 let id, name: String; let watched: Bool; let bytes: Int64; let ticks: Int64 }
    private struct FootSpaceResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case suffices = "reicht"
        case bytes
    }
 let suffices: Bool; let bytes: Int64 }
    private struct NextEpisodeResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case id
        case buttonText = "knopftext"
    }
 let id, buttonText: String }

    /// The episodes of a season for `Ladeauswahl`: name, watched, and the size of the first
    /// source (`mediaSources.first.size`), as the iOS sheet reads it. Throws on a failed call:
    /// **disturbed is not empty.**
    public func loadSelectionEpisodes(series: String, season: String) async throws -> String {
        return try await throwReadable { () async throws -> String in
            guard let c = client else { throw CoreError.notConnected }
            let list = try await c.episodes(seriesID: series, seasonID: season.isEmpty ? nil : season)
            return try json(list.map {
                LoadSelectionEpisode(id: $0.id, name: $0.name, watched: $0.userData?.played ?? false,
                                 bytes: $0.mediaSources?.first?.size ?? 0, ticks: $0.runTimeTicks ?? 0)
            })
        }
    }

    /// The footer of the download selection (`DownloadRules.footSpace`): `suffices` with what is
    /// left afterwards, otherwise with what is missing (reserve included).
    public static func downloadFooterSpace(bytes: Int64, free: Int64) -> String {
        switch DownloadRules.footSpace(for: bytes, free: free) {
        case .free(let rest): encoded(FootSpaceResponse(suffices: true, bytes: rest))
        case .few(let missing): encoded(FootSpaceResponse(suffices: false, bytes: missing))
        }
    }

    /// "0,84" and "2,31 GB" from `DownloadRules.progress`, as a JSON list of two texts. The
    /// sentence "%@ of %@" is in the app catalog.
    public static func downloadProgress(loaded: Int64, total: Int64) -> String {
        let f = DownloadRules.progress(loaded: loaded, from: total)
        return encoded([f.loaded, f.total])
    }

    /// `DownloadRules.progressShow`: at most once per second. `before` and `elapsed`
    /// negative means nothing reported yet.
    public static func downloadProgressShow(loaded: Int64, total: Int64, before: Int64, elapsed: Double) -> Bool {
        DownloadRules.progressShow(loaded: loaded, total: total,
                                         before: before < 0 ? nil : before,
                                         elapsed: elapsed < 0 ? nil : elapsed)
    }

    /// **One `ProgressEstimator` per download, held here.** The manager reports, the row asks
    /// for the value on every frame; number, bar and ring read the same one.
    private static let estimatorLock = NSLock()
    private static var estimator: [String: ProgressEstimator] = [:]

    public static func downloadEstimatorReport(id: String, loaded: Int64, total: Int64) {
        estimatorLock.lock(); defer { estimatorLock.unlock() }
        estimator[id, default: ProgressEstimator()].report(loaded, total: total, um: Date())
    }

    /// No more bytes arrive: paused, waiting, error, no network. The number stands.
    public static func downloadEstimatorHalt(id: String) {
        estimatorLock.lock(); defer { estimatorLock.unlock() }
        estimator[id]?.halt()
    }

    /// The estimated state now; without a report, `loaded`.
    public static func downloadEstimatorValue(id: String, loaded: Int64) -> Int64 {
        estimatorLock.lock(); defer { estimatorLock.unlock() }
        guard var s = estimator[id] else { return loaded }
        let value = s.value(um: Date())
        estimator[id] = s
        return value
    }

    public static func downloadEstimatorForget(id: String) {
        estimatorLock.lock(); defer { estimatorLock.unlock() }
        estimator[id] = nil
    }

    /// The series' play button in the downloads (`DownloadRules.nextEpisode`), labeled as on
    /// the series page (`Item.seriesButton`). `{}` without a finished episode.
    public static func downloadNextEpisode(list: String) -> String {
        guard let p = DownloadRules.nextEpisode(from: itemRead(list)) else { return "{}" }
        return encoded(NextEpisodeResponse(id: p.id, buttonText: Item.seriesButton(episode: p.asItem, loads: false)))
    }

    /// A series' header image in `width` pixels (`AppModel.headerImageURL(for:width:)`), for the
    /// image that goes to the device with the first download. Empty without server or image.
    public func downloadHeaderImage(series: String, width: Int) async -> String {
        guard let c = client, let a = addresses, let item = try? await c.item(id: series) else { return "" }
        return ImageSelection.header(item, addresses: a, width: width)?.absoluteString ?? ""
    }

    // MARK: Section offer and collections

    private struct OfferingEntry: Encodable {
    enum CodingKeys: String, CodingKey {
        case value = "wert"
        case name
        case category = "rubrik"
    }
 let value: String; let name: String?; let category: Bool }
    private struct OfferingResponse: Encodable {
        enum CodingKeys: String, CodingKey {
            case isMenu = "istMenue"
            case hasInventory = "hatBestand"
            case choice = "wahl"
            case identifier = "kennung"
            case entries = "eintraege"
        }
        let isMenu, hasInventory: Bool
        let choice, identifier: String
        let entries: [OfferingEntry]
    }
    private struct SectionPagesResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case title = "titel"
        case total = "gesamt"
        case filtered = "gesiebt"
        case evenMore = "nochMehr"
    }
        let title: [GridTileResponse]; let total: Int; let filtered, evenMore: Bool
    }
    private struct CollectionEntry: Encodable {
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case poster = "plakat"
        case count = "anzahl"
    }
 let id, name: String; let poster: String?; let count: Int }
    private struct CollectionRailsResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case art
        case title = "titel"
    }
 let id, name, art: String; let title: [GridTileResponse] }

    /// The account's libraries (`AppModel.views`), per client, so nothing of the previous account
    /// is left after an account switch.
    private var _views: (for: ObjectIdentifier, list: [Item])?
    /// Shares of mixed libraries and collections (`AppModel.offeringLoad()`). Valid for one minute.
    private var _offering: (for: ObjectIdentifier, shares: [String: LibraryShare],
                           directory: CollectionDirectory, time: Date)?
    /// The running look-up; whoever asks meanwhile waits for it instead of starting a second.
    private var _offeringTask: (for: ObjectIdentifier, task: Task<Void, Never>)?
    /// "All" across several libraries: the filter plus state in server paging
    /// (`LibraryModel.filterRef`, `rawOffset`, `rawTotal`).
    private var _filter: (key: String, filterRef: TitleFilter, offset: Int, raw: Int)?

    private func locked<T>(_ perform: () -> T) -> T {
        barrier.lock(); defer { barrier.unlock() }
        return perform()
    }

    private func viewList(_ c: JellyfinClient) async throws -> [Item] {
        let of = ObjectIdentifier(c)
        if let present = locked({ _views?.for == of ? _views?.list : nil }) { return present }
        let list = try await c.userViews()
        locked { _views = (of, list) }
        return list
    }

    /// `AppModel.sectionOffering(art:)`: what belongs to another account does not count.
    private func offering(art: String, _ c: JellyfinClient, views: [Item]) -> SectionOffering {
        let of = ObjectIdentifier(c)
        let state = locked { _offering?.for == of ? _offering : nil }
        return SectionOffering.compose(art: art, views: views, shares: state?.shares ?? [:],
                                      directory: state?.directory)
    }

    private func directory(_ c: JellyfinClient) -> CollectionDirectory? {
        let of = ObjectIdentifier(c)
        return locked { _offering?.for == of ? _offering?.directory : nil }
    }

    /// Fetches collections and shares of mixed libraries (`AppModel.offeringLoad()`): on demand,
    /// a state is valid for one minute, failed is not empty (the state then stays invalid).
    /// The libraries themselves are refreshed along the way.
    public func offeringLoad() async {
        guard let c = client else { return }
        let of = ObjectIdentifier(c)
        let (freshValue, ongoing) = locked { () -> (Bool, Task<Void, Never>?) in
            let freshValue = _offering.map { $0.for == of && Date().timeIntervalSince($0.time) < 60 } ?? false
            return (freshValue, _offeringTask?.for == of ? _offeringTask?.task : nil)
        }
        if freshValue { return }
        if let ongoing { await ongoing.value; return }
        let task = Task { [self] in
            let state: [Item]
            if let new = try? await c.userViews() {
                state = new
                locked { _views = (of, new) }
            } else if let alt = locked({ _views?.for == of ? _views?.list : nil }) {
                state = alt
            } else { return }
            async let shares = c.libraryShares(views: state)
            async let directory: CollectionDirectory? = {
                let withHidden = (try? await c.userViews(hidden: true)) ?? state
                if CollectionDirectory.hidden(visible: state, withHidden: withHidden) {
                    return .empty
                }
                return try? await c.collectionDirectory(viewList: withHidden)
            }()
            let newShares = await shares
            guard let newDirectory = await directory else { return }
            locked { _offering = (of, newShares, newDirectory, Date()) }
        }
        locked { _offeringTask = (of, task) }
        await task.value
        locked { if _offeringTask?.for == of { _offeringTask = nil } }
    }

    /// What the title offers to choose for movies or series (``SectionOffering``) and which choice
    /// applies: the remembered one, otherwise "All". Does not wait for collections and mixed
    /// libraries; they follow via ``offeringLoad()``, and `kennung` says whether anything changed
    /// (`LibraryView.offeringId`).
    /// Answer: `{"istMenue","hatBestand","wahl","kennung","eintraege":[{"wert","name","rubrik"}]}`.
    /// `name` only for libraries; Kotlin labels "All"/"Collections" from the catalog.
    public func sectionOffering(art: String, remembered: String) async throws -> String {
        return try await throwReadable { () async throws -> String in
            guard let c = client else { throw CoreError.notConnected }
            let a = offering(art: art, c, views: try await viewList(c))
            let entries = a.entries.map { e -> OfferingEntry in
                if case .library(let id) = e {
                    return OfferingEntry(value: e.rememberValue, name: a.library(id)?.name ?? "",
                                           category: e == a.firstLibrary)
                }
                return OfferingEntry(value: e.rememberValue, name: nil, category: false)
            }
            return try json(OfferingResponse(
                isMenu: a.isMenu, hasInventory: a.hasInventory,
                choice: a.choice(remembered: remembered).rememberValue,
                identifier: a.entries.map(\.rememberValue).joined(separator: ",") + "|"
                    + a.allSources.joined(separator: "+"),
                entries: entries))
        }
    }

    /// A page for "All" or a library of the section (`LibraryView.source` and
    /// `LibraryModel.laden/loadMore`). "All" reads from one library as before, from several
    /// filtered (``TitleFilter``): each title once, only from `allSources`. The core holds the
    /// filter; `since == 0` restarts it (on returning as far as paging had gone), otherwise it
    /// continues where the server stood.
    /// Answer: `{"titel","gesamt","gesiebt","nochMehr"}`; `evenMore` applies only when filtered.
    public func sectionPage(art: String, choice: String, sorting: String, filter: String,
                             since: Int, count: Int) async throws -> String {
        return try await throwReadable { () async throws -> String in
            guard let c = client, let a = addresses else { throw CoreError.notConnected }
            let s = Sorting(rawValue: sorting) ?? .name
            let f = LibraryFilter(rawValue: filter) ?? .all
            let offering = offering(art: art, c, views: try await viewList(c))
            let source: ShelfSource?
            switch SectionSelection(rememberValue: choice) {
            case .all:
                source = offering.hasInventory
                    ? ShelfSource(parent: offering.allOut, art: art,
                                  onlyOut: offering.allOut == nil ? offering.allSources : [])
                    : nil
            case .library(let id): source = ShelfSource(parent: id, art: art)
            case .collections: source = nil
            }
            guard let source else {
                return try json(SectionPagesResponse(title: [], total: 0, filtered: false, evenMore: false))
            }
            func page(_ start: Int, _ amount: Int) async throws -> ItemsResponse {
                try await c.items(parentID: source.parent, limit: amount, startIndex: start,
                                  sortBy: s.inputField, sortOrder: source.bearing(s),
                                  filters: f.jellyfinFilter, isWatched: f.isWatched,
                                  recursive: source.recursive, includeItemTypes: source.types)
            }
            guard source.isFiltering else {
                let answer = try await page(since, count)
                return try json(SectionPagesResponse(title: answer.items.map { gridTile($0, a) },
                                                      total: answer.totalRecordCount,
                                                      filtered: false, evenMore: false))
            }
            let key = "\(ObjectIdentifier(c))|\(source.key)|\(s.rawValue)|\(f.rawValue)"
            let before = locked { _filter }
            var filterRef: TitleFilter
            var offset: Int
            var first = count
            if since == 0 {
                filterRef = try await c.titleFilter(source, filters: f.jellyfinFilter, isWatched: f.isWatched)
                offset = 0
                if let before, before.key == key { first = max(count, before.offset) }
            } else {
                guard let before, before.key == key else {
                    return try json(SectionPagesResponse(title: [], total: 0, filtered: true, evenMore: false))
                }
                filterRef = before.filterRef
                offset = before.offset
            }
            // Fetch pages until something stays (`LibraryModel.fill`): a page can consist almost
            // entirely of duplicates, and without a new tile nothing would trigger loading more.
            var new: [Item] = []
            var raw = 0
            var amount = first
            repeat {
                let answer = try await page(offset, amount)
                new += filterRef.seven(answer.items)
                offset += answer.items.count
                raw = answer.totalRecordCount
                amount = count
                if answer.items.isEmpty { break }
            } while new.count < count / 2 && offset < raw
            let done = (key: key, filterRef: filterRef, offset: offset, raw: raw)
            locked { _filter = done }
            return try json(SectionPagesResponse(title: new.map { gridTile($0, a) }, total: filterRef.total,
                                                  filtered: true,
                                                  evenMore: ListRules.stillMorePresent(loaded: offset, total: raw)))
        }
    }

    /// The collections in the section, from two titles (``Sammlungsverzeichnis/sammlungen(art:)``).
    /// Answer: `[{"id","name","plakat","anzahl"}]`. `poster` is missing without an own image, and
    /// Kotlin then builds the mosaic (``collectionMosaic(id:art:height:)``).
    public func collections(art: String) async throws -> String {
        return try await throwReadable { () async throws -> String in
            guard let c = client, let a = addresses else { throw CoreError.notConnected }
            await offeringLoad()
            return try json((directory(c)?.collections(art: art) ?? []).map {
                CollectionEntry(id: $0.id, name: $0.item.name,
                                 poster: ImageSelection.portrait($0.item, addresses: a)?.absoluteString,
                                 count: $0.count(art: art))
            })
        }
    }

    /// "3 Movies" or "3 Series" under a collection tile (`collectionCount` in Kotlin); the rule
    /// is in the package (``Sammlung/anzahltext(art:anzahl:)``).
    public static func collectionCountText(art: String, count: Int) -> String {
        ItemCollection.countText(art: art, count: count)
    }

    /// The titles of a collection in their order (`AppModel.collectionTitle(_:art:)`).
    private func collectionTitle(_ c: JellyfinClient, id: String, art: String?) async throws -> [Item] {
        let source = ShelfSource(parent: id, art: art, collection: true)
        return try await c.items(parentID: source.parent, limit: 100,
                                 sortBy: Sorting.erscheinung.inputField,
                                 sortOrder: source.bearing(.erscheinung),
                                 recursive: source.recursive, includeItemTypes: source.types).items
    }

    /// The posters of the first four titles for a collection's substitute poster (`Sammlungsmosaik`).
    /// Silent: if it fails, the field stays empty. Answer: `["adresse" | null, ...]`.
    public func collectionMosaic(id: String, art: String, height: Int) async -> String {
        guard let c = client, let a = addresses,
              let list = try? await collectionTitle(c, id: id, art: art.isEmpty ? nil : art) else { return "[]" }
        let posters: [String?] = list.prefix(4).map {
            ImageSelection.portrait($0, addresses: a, maxHeight: height)?.absoluteString
        }
        return (try? json(posters)) ?? "[]"
    }

    /// A page of a collection (`CollectionView` or `LibraryView(collection:)`): not recursive,
    /// ascending by year (``Regalquelle/richtung(_:)``). `art` empty: everything inside.
    public func collectionPage(id: String, art: String, sorting: String, filter: String,
                              since: Int, count: Int) async throws -> String {
        return try await throwReadable { () async throws -> String in
            guard let c = client, let a = addresses else { throw CoreError.notConnected }
            let s = Sorting(rawValue: sorting) ?? .erscheinung
            let f = LibraryFilter(rawValue: filter) ?? .all
            let source = ShelfSource(parent: id, art: art.isEmpty ? nil : art, collection: true)
            let answer = try await c.items(parentID: source.parent, limit: count, startIndex: since,
                                            sortBy: s.inputField, sortOrder: source.bearing(s),
                                            filters: f.jellyfinFilter, isWatched: f.isWatched,
                                            recursive: source.recursive, includeItemTypes: source.types)
            return try json(GridPagesResponse(title: answer.items.map { gridTile($0, a) },
                                                total: answer.totalRecordCount))
        }
    }

    /// "Part of the collection" (`Sammlungsreihe`): at most two collections, with the other
    /// titles in them, without the open one and without duplicates. Silent: `[]` without a
    /// collection or on error. Answer: `[{"id","name","art","titel":[tile]}]`.
    public func collectionsForTitle(id: String) async -> String {
        guard let c = client, let a = addresses, let title = try? await c.item(id: id),
              let art = LibraryGenre.art(toType: title.type) else { return "[]" }
        await offeringLoad()
        guard let directory = directory(c) else { return "[]" }
        var rails: [CollectionRailsResponse] = []
        // At most two rows. If a movie is in more collections, the rest are usually automatically
        // created duplicates.
        for collection in directory.collections(with: title).prefix(2) {
            guard let list = try? await collectionTitle(c, id: collection.id, art: art) else { continue }
            let other = ListRules.withoutDouble(list).filter { $0.id != title.id }
            if !other.isEmpty {
                rails.append(CollectionRailsResponse(id: collection.id, name: collection.item.name, art: art,
                                                     title: other.map { gridTile($0, a) }))
            }
        }
        return (try? json(rails)) ?? "[]"
    }
}

// MARK: Answers (what Kotlin reads)

struct DelayResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case milliseconds = "millisekunden"
        case text
        case isNull = "istNull"
        case atStart = "amAnfang"
        case atEnd = "amEnde"
    }
    let milliseconds: Int
    let text: String
    let isNull: Bool
    let atStart: Bool
    let atEnd: Bool
}

struct ServerResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case name
        case version
        case address = "adresse"
    }
 let name, version, address: String }
struct HomeResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case rails = "reihen"
        case disrupted = "gestoert"
    }
 let rails: [RailsResponse]; let disrupted: Bool }
struct RailsResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case titleKey = "titelSchluessel"
        case name
        case landscape = "quer"
        case tiles = "kacheln"
        case library = "bibliothek"
        case collection = "sammlung"
    }
    /// German wording as key; Kotlin translates with `translated(...)`.
    let titleKey: String?
    /// Name of a genre row, not translated.
    let name: String?
    let landscape: Bool
    let tiles: [TileResponse]
    /// Only for a chosen library or collection: its ID; the row's header opens it.
    var library: String? = nil
    var collection: Bool = false
}
struct GridPagesResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case title = "titel"
        case total = "gesamt"
    }
 let title: [GridTileResponse]; let total: Int }
struct GridTileResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case id
        case title = "titel"
        case type = "typ"
        case subline = "unterzeile"
        case poster = "plakat"
        case progress = "fortschritt"
        case mark = "marke"
        case markCount = "markenzahl"
    }
    let id, title, type: String
    let subline, poster: String?
    let progress: Double?
    /// `watched`, `opened`, `seasons`, or nothing.
    let mark: String?
    let markCount: Int
}
struct TitleResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case type = "typ"
        case secondaryLine = "nebenzeile"
        case yearRuntime = "jahrLaufzeit"
        case headerImage = "kopfbild"
        case logo
        case rating = "bewertung"
        case sharing = "freigabe"
        case planPresent = "planDa"
        case lossless
        case method = "methode"
        case resumeFrom = "fortsetzenAb"
        case resumeText = "fortsetzenText"
        case remainingTime = "restzeit"
        case progress = "fortschritt"
        case description = "beschreibung"
        case direction = "regie"
        case actors = "darsteller"
        case remembered = "gemerkt"
        case watched = "gesehen"
        case trailer
        case file = "datei"
        case backdrop = "kulisse"
    }
    let id, name, type, secondaryLine: String
    /// "2026 · 1 h 52 min", without genre, for the TV.
    let yearRuntime: String
    let headerImage: String?
    /// Title logo, if the server has one (`ImageSelection.logo`).
    let logo: String?
    let rating: Double?
    let sharing: String?
    let planPresent, lossless: Bool
    let method: String?
    let resumeFrom: Double?
    let resumeText: String?
    /// "25 min left" and the fraction, under the main button, like `primaryButton` on iPhone.
    let remainingTime: String?
    let progress: Double?
    let description: String?
    let direction: [String]
    let actors: [PersonResponse]
    let remembered, watched: Bool
    let trailer: String?
    let file: FileResponse?
    /// See `Kern.backdrop`: the same URL as `TileResponse.backdrop`.
    let backdrop: String?
}
struct SeriesResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case year = "jahr"
        case seasonRow = "staffelzeile"
        case seasonCount = "staffelzahl"
        case genres = "gattungen"
        case headerImage = "kopfbild"
        case logo
        case rating = "bewertung"
        case sharing = "freigabe"
        case description = "beschreibung"
        case remembered = "gemerkt"
        case watched = "gesehen"
        case trailer
        case planPresent = "planDa"
        case lossless
        case method = "methode"
        case state = "stand"
        case buttonText = "knopftext"
        case seasons = "staffeln"
        case selected = "gewaehlt"
        case actors = "darsteller"
        case backdrop = "kulisse"
    }
    let id, name: String
    let year, seasonRow: String?
    let seasonCount: Int?
    let genres, headerImage: String?
    /// Title logo, if the server has one (`ImageSelection.logo`).
    let logo: String?
    let rating: Double?
    let sharing, description: String?
    let remembered, watched: Bool
    let trailer: String?
    let planPresent, lossless: Bool
    let method: String?
    let state: StateResponse?
    let buttonText: String
    let seasons: [SeasonResponse]
    let selected: String?
    let actors: [PersonResponse]
    /// See `Kern.backdrop`: the same URL as `TileResponse.backdrop`.
    let backdrop: String?
}
struct StateResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case id
        case resume = "fortsetzen"
        case remainingTime = "restzeit"
        case progress = "fortschritt"
        case season = "staffel"
        case episode = "folge"
        case since = "ab"
    }
    let id: String
    let resume: Bool
    let remainingTime: String?
    let progress: Double?
    let season, episode: Int?
    let since: Double?
}
struct SeasonResponse: Encodable { let id, name: String }
struct EpisodesResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case id
        case title = "titel"
        case subline = "unterzeile"
        case image = "bild"
        case progress = "fortschritt"
        case watched = "gesehen"
        case since = "ab"
        case name
        case number = "nummer"
        case runtimeMin = "laufzeitMin"
        case remainingTime = "restzeit"
    }
    let id, title: String
    let subline, image: String?
    let progress: Double?
    let watched: Bool
    let since: Double?
    /// Raw, for the TV; see `Kern.episodes(series:season:)`.
    let name: String
    let number: Int?
    let runtimeMin: Int?
    let remainingTime: String?
}
struct ServerCardsResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case address = "adresse"
        case host
        case active = "aktiv"
        case accounts = "konten"
    }
 let address, host: String; let active: Bool; let accounts: [AccountResponse] }
struct AccountResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case identifier = "kennung"
        case name
        case active = "aktiv"
        case image = "bild"
    }
 let identifier, name: String; let active: Bool; let image: String? }
struct TechRow: Encodable {
    enum CodingKeys: String, CodingKey {
        case text
        case art
        case key = "schluessel"
        case header = "kopf"
    }
 let text, art: String; var key: String? = nil; var header = false }
struct TechResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case input = "eingang"
        case demuxer
        case shows = "zeigt"
        case shown = "gezeigt"
        case should = "soll"
        case run = "lauf"
        case decoded = "dekodiert"
        case reserveSeconds = "vorratSekunden"
        case reserveKiB = "vorratKiB"
        case discarded = "verworfen"
        case audioLost = "tonVerloren"
        case beschaedigt
        case jumps = "spruenge"
    }
    let input, demuxer: String?
    let shows: Double?
    let shown: UInt64
    let should, run, decoded, reserveSeconds: Double?
    let reserveKiB, discarded, audioLost, beschaedigt, jumps: UInt64
}
struct SelectionResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case value = "wert"
        case text
    }
 let value, text: String }
struct BufferResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case value = "wert"
        case text
        case network = "netz"
    }
 let value, text: String; let network: Int? }
struct PlayPlanResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case url
        case lossless
        case method = "methode"
        case title = "titel"
        case subtitle = "untertitel"
        case next = "naechste"
        case fileRow = "dateizeile"
        case series = "serie"
        case abbreviation = "kuerzel"
        case image = "bild"
        case itemId
        case episode
        case seriesIdentifier = "serieId"
        case seasonIdentifier = "staffelId"
        case headerLine = "kopfzeile"
        case seasonNr = "staffelNr"
        case episodeNr = "folgeNr"
        case secondaryLine = "nebenzeile"
        case marks = "marken"
        case softwareDecoder = "softwareDekoder"
        case nextEpisode = "naechsteFolge"
        case cardImage = "kartenbild"
        case dolbyVision
        case audioCodec
    }
    let url: String
    let lossless: Bool
    let method, title, subtitle: String
    let next: Bool
    /// "MKV · 1080p · H.264 · German · AAC · Stereo", for the file line in the playback sheet.
    let fileRow: String?
    let series, abbreviation, image: String?
    /// For the new player's header (mirrors iOS) and the episode layer.
    let itemId: String
    let episode: Bool
    let seriesIdentifier, seasonIdentifier: String?
    /// Series for an episode, otherwise the title itself (`titleLine` on iOS).
    let headerLine: String
    let seasonNr, episodeNr: Int?
    /// Year · runtime · genre, for movies only (`metaText`/`item.secondaryLine` on iOS).
    let secondaryLine: String?
    /// The section boundaries (intro, outro ...): notches in the seek bar, as on iPhone.
    var marks: [Double] = []
    /// ``PlaybackPlan/softwareDekoder``: XviD/DivX go straight to software, without MediaCodec.
    var softwareDecoder = false
    /// The card of the next episode: ID, name, "S6 • E11", still.
    var nextEpisode: EpisodesCardsResponse? = nil
    /// The handover card's image if the still is black (`TakeoverModel.cardImageURL`).
    var cardImage: String? = nil
    /// **Dolby Vision in the file, unchanged**: the profile (5, 7, 8 …), 0 if unknown; `nil` without
    /// Dolby Vision or when the server converts. Kotlin plays such files with ExoPlayer (libVLC 3 only shows
    /// the base layer), if the device can.
    var dolbyVision: Int? = nil
    /// Codec of the default audio track, see `defaultAudioCodec(_:)`: `""` without sound, `nil` if unknown.
    var audioCodec: String? = nil
}
struct EpisodesCardsResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case abbreviation = "kuerzel"
        case image = "bild"
    }
 let id, name, abbreviation: String; let image: String? }
struct AccountSwitchResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case swap = "tausch"
        case landing = "landung"
        case paintEnd = "ringEnde"
        case change = "wechsel"
        case grow = "wachsen"
        case targetSize = "zielgroesse"
        case lane = "bahn"
        case ring
    }
    let swap, landing, paintEnd, change, grow, targetSize: Double
    let lane, ring: [Double]
}
struct EpisodesCardsMetrics: Encodable {
    enum CodingKeys: String, CodingKey {
        case width = "breite"
        case corner = "ecke"
        case ring
        case spacing = "abstand"
        case small = "klein"
        case title = "titel"
        case appearOmega = "erscheinenOmega"
        case appearLag = "erscheinenVerzug"
        case distanceOmega = "wegOmega"
        case zoomOmega
        case detailsOut = "angabenAus"
        case swap = "tausch"
        case imageFade = "bildBlende"
        case offset = "versatz"
        case startMetric = "startmass"
        case focusMetric = "fokusmass"
        case clickPress = "klickDruck"
        case clickDuration = "klickDauer"
        case bottomSpacing = "untenAbstand"
    }
    let width, corner, ring, spacing, small, title: Double
    let appearOmega, appearLag, distanceOmega, zoomOmega: Double
    let detailsOut, swap, imageFade, offset, startMetric, focusMetric, clickPress, clickDuration, bottomSpacing: Double
}
struct SwitchResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case result = "ergebnis"
        case playbackPlan = "spielplan"
        case error = "fehler"
        case pendingReport = "nachmeldung"
    }
    let result: String
    var playbackPlan, error, pendingReport: String?
}
/// What the side-by-side steps of an episode switch return.
final class SwitchStore: @unchecked Sendable {
    private let lock = NSLock()
    private var _pendingReport, _error, _playback_plan: String?
    func setDown(pendingReport: String) { lock.lock(); _pendingReport = pendingReport.isEmpty ? nil : pendingReport; lock.unlock() }
    func setDown(error: String) { lock.lock(); _error = error; lock.unlock() }
    func setDown(playbackPlan: String?) { lock.lock(); _playback_plan = playbackPlan; lock.unlock() }
    var pendingReport: String? { lock.lock(); defer { lock.unlock() }; return _pendingReport }
    var error: String? { lock.lock(); defer { lock.unlock() }; return _error }
    var playbackPlan: String? { lock.lock(); defer { lock.unlock() }; return _playback_plan }
}
struct TickResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case loadingScreenGone = "ladeschirmWeg"
        case tracksApply = "spurenAnwenden"
        case position
        case offering = "angebot"
        case to = "nach"
        case offeringText = "angebotstext"
        case overlay = "einblendung"
        case countdown
        case countdownRest
        case countdownLength = "countdownLaenge"
        case advance = "weiterschalten"
    }
    let loadingScreenGone, tracksApply: Bool
    let position: Double
    let offering: String
    let to: Double?
    let offeringText: String
    /// The overlay without controls: `nothing`, `button` or `card` (countdown, `countdown` 0...1).
    let overlay: String
    let countdown: Double
    /// Whole seconds until the switch, for TalkBack ("Starts in 5 seconds").
    let countdownRest: Int
    /// How long the card's fill runs; Kotlin animates the rest continuously from it.
    let countdownLength: Double
    let advance: Bool
}
struct PeoplePagesResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case description = "beschreibung"
        case born = "geboren"
        case place = "ort"
        case image = "bild"
        case banner
        case title = "titel"
        case tmdb
        case disrupted = "gestoert"
    }
    let description, born, place, image: String?
    let banner: [String]
    let title: [GridTileResponse]
    let tmdb: Int?
    /// The server did not answer the title list; not the same as "no titles".
    let disrupted: Bool
}
struct SeerrTileResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case id
        case art
        case title = "titel"
        case year = "jahr"
        case poster = "plakat"
        case backdrop = "kulisse"
        case state = "stand"
        case requestable = "anfragbar"
    }
    let id: Int
    let art, title: String
    let year: Int?
    let poster, backdrop: String?
    let state: Int
    let requestable: Bool
}
struct SeerrSeasonResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case number = "nummer"
        case episodes = "folgen"
        case state = "stand"
        case requestable = "anfragbar"
    }
 let number, episodes, state: Int; let requestable: Bool }
struct SeerrDetailResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case description = "beschreibung"
        case genres
        case runtime = "laufzeit"
        case rating = "bewertung"
        case seasons = "staffeln"
        case cast = "besetzung"
        case similarOne = "aehnliches"
        case state = "stand"
        case requestable = "anfragbar"
    }
    let description: String?
    let genres: [String]
    let runtime: Int?
    let rating: Double?
    let seasons: [SeerrSeasonResponse]
    let cast: [PersonResponse]
    let similarOne: [SeerrTileResponse]
    /// The fresh state of the whole title (`SeerrDetail.state`); missing if the answer did not carry it.
    let state: Int?
    let requestable: Bool?
}
struct PersonResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case role = "rolle"
        case image = "bild"
    }
 let id, name: String; let role, image: String? }
struct FileResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case container
        case video
        case audio = "ton"
        case subtitle = "untertitel"
        case hasSubtitle = "hatUntertitel"
    }
    let container, video: String?
    let audio: [String]
    let subtitle: String
    let hasSubtitle: Bool
}
struct FieldResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case similar = "aehnliche"
        case extras
    }
 let similar: [GridTileResponse]; let extras: [ExtraResponse] }
struct ExtraResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case image = "bild"
        case runtime = "laufzeit"
    }
 let id, name: String; let image, runtime: String? }
struct LabelResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case sorting = "sortierung"
        case filter
    }
    struct Record: Encodable {
    enum CodingKeys: String, CodingKey {
        case value = "wert"
        case text
    }
 let value, text: String }
    let sorting, filter: [Record]
}
struct TileResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case type = "typ"
        case subline = "unterzeile"
        case poster = "plakat"
        case landscape = "quer"
        case progress = "fortschritt"
        case mark = "marke"
        case markCount = "markenzahl"
        case detailsRow = "angabenzeile"
        case remainingTime = "restzeit"
        case continueWatchingRow = "weiterschauenzeile"
        case watched = "gesehen"
        case episodeName = "folgenname"
        case runtimeSeconds = "laufzeitSekunden"
        case positionSeconds = "positionSekunden"
        case rating = "bewertung"
        case sharing = "freigabe"
        case description = "beschreibung"
        case backdrop = "kulisse"
    }
    let id, name, type: String
    let subline: String?
    let poster: String?
    let landscape: String?
    let progress: Double?
    /// `watched`, `opened`, `seasons`, or nothing. Like `GridTileResponse.mark`.
    let mark: String?
    let markCount: Int
    /// For the home header zone when this tile holds focus: year, runtime, episode code, like
    /// `HeaderInfo.detailsRow` on tvOS.
    let detailsRow: String?
    /// "50 minutes left", like `RemainingTimeMark`. `nil` means nothing started.
    let remainingTime: String?
    /// "S2 · E5 · 12 min left" under a Continue Watching tile (`Item.continueWatchingRow`).
    var continueWatchingRow: String? = nil
    let watched: Bool
    /// Set only for an episode; the series name is already in `name`.
    let episodeName: String?
    /// For Android TV's Watch Next row; see `tile(_:newAccess:withMark:_:)`.
    let runtimeSeconds: Double?
    let positionSeconds: Double?
    /// For Android TV's header zone (`HeaderInfo`): the same three fields `HeaderInfo` on
    /// tvOS reads straight from the full `Item` (rating, certification, description). The phone's
    /// home page does not need them and does not read them.
    let rating: Double?
    let sharing: String?
    let description: String?
    /// See `Kern.backdrop`: the backdrop that movie and series pages show too.
    let backdrop: String?
}

struct DownloadResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case entries = "posten"
        case image = "bild"
        case seriesImage = "serienbild"
    }
 let entries: DownloadItem; let image, seriesImage: String? }
struct StopResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case store = "ablage"
        case entries = "posten"
    }
 let store: String; let entries: [DownloadItem] }
struct SpaceResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case suffices = "reicht"
        case freeAfter = "freiDanach"
        case dispensable = "entbehrlich"
        case dispensableBytes = "entbehrlichBytes"
        case sufficesToCleanUp = "reichtNachAufraeumen"
    }
    let suffices: Bool
    let freeAfter: Int64
    let dispensable: [String]
    let dispensableBytes: Int64
    let sufficesToCleanUp: Bool
}
struct DownloadGroupsResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case id
        case title = "titel"
        case bytes
        case seriesIdentifier = "serienId"
        case episodes = "folgen"
    }
 let id, title: String; let bytes: Int64; let seriesIdentifier: String?; let episodes: [String] }
struct PlanResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case lossless
        case method = "methode"
    }
 let lossless: Bool; let method: String }
struct ChapterBarsResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case pieces = "stuecke"
        case snap = "fang"
    }
 let pieces: [[Double]]; let snap: [Double] }
struct TrickplayReply: Encodable {
    enum CodingKeys: String, CodingKey {
        case width = "breite"
        case height = "hoehe"
        case tilesWide = "kachelnBreit"
        case tilesUp = "kachelnHoch"
        case count = "anzahl"
        case interval = "intervall"
    }
 let width, height, tilesWide, tilesUp, count, interval: Int }
struct OfferingReply: Encodable {
    enum CodingKeys: String, CodingKey {
        case id
        case itemID
        case device = "geraet"
        case art
        case titleLine = "titelzeile"
        case spot = "stelle"
        case pointText = "stelleText"
        case image = "bild"
        case name
        case series = "serie"
        case seasonNr = "staffelNr"
        case episodeNr = "folgeNr"
    }
    let id, itemID: String; let device: String?; let art, titleLine: String; let spot: Double; let pointText: String
    /// For the handover card: its image (`TakeoverModel.cardImageURL`) and the lines below it
    /// (`HandoffStyle.rows`: series and "season · episode", otherwise the title).
    var image: String? = nil
    var name: String = ""
    var series: String? = nil
    var seasonNr: Int? = nil
    var episodeNr: Int? = nil
}

struct RemoteCommandResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case art
        case value = "wert"
    }
 let art: String; let value: Double? }
struct SharedRequest: Encodable {
    enum CodingKeys: String, CodingKey {
        case title = "titel"
        case since = "ab"
    }
 let title: String; let since: Double }

/// Receives commands from the socket until the player picks them up. Own lock, since the
/// socket calls from its own thread.
final class CommandStore: @unchecked Sendable {
    private let barrier = NSLock()
    private var commands: [RemoteCommandResponse] = []

    func stash(_ command: RemoteCommand) {
        let entryRecord: RemoteCommandResponse
        switch command {
        case .pause: entryRecord = .init(art: "pause", value: nil)
        case .proceed: entryRecord = .init(art: "weiter", value: nil)
        case .toggle: entryRecord = .init(art: "umschalten", value: nil)
        case .stop: entryRecord = .init(art: "stopp", value: nil)
        case let .jumpOn(s): entryRecord = .init(art: "springen", value: s)
        case .forward: entryRecord = .init(art: "vor", value: nil)
        case .back: entryRecord = .init(art: "zurueck", value: nil)
        case .next: entryRecord = .init(art: "naechste", value: nil)
        case .previous: entryRecord = .init(art: "vorige", value: nil)
        default: return
        }
        barrier.lock(); commands.append(entryRecord); if commands.count > 20 { commands.removeFirst() }; barrier.unlock()
    }

    func pickUp() -> [RemoteCommandResponse] {
        barrier.lock(); defer { barrier.unlock() }
        let all = commands
        commands = []
        return all
    }

    /// The handover hint: who takes over next, and when it came (`AppModel.handoffTarget`).
    private var hint: (name: String, time: Date)?

    func hintStore(_ name: String) {
        barrier.lock(); hint = (name, Date()); barrier.unlock()
    }

    /// Pick up once; only if it is fresh (`Takeover.isHandoff`).
    func takeHint() -> String? {
        barrier.lock(); let h = hint; hint = nil; barrier.unlock()
        guard let h else { return nil }
        return Takeover.isHandoff(hintPre: Date().timeIntervalSince(h.time)) ? h.name : nil
    }
}

/// A track from libVLC, as Kotlin passes it in.
struct TrackInput: Decodable {
    enum CodingKeys: String, CodingKey {
        case id
        case identifier = "kennung"
        case name
        case language = "sprache"
        case fourcc
        case channels = "kanaele"
    }
    let id: Int
    /// `audio/<id>`, `spu/<id>`, a loaded file `<md5>/spu/<n>` (as in libVLC 4).
    let identifier: String
    let name: String
    let language: String?
    let fourcc: Int?
    let channels: Int?

    var track: PlayerTrack {
        let language = (self.language?.isEmpty == false) ? self.language : Self.bracketLanguage(name)
        return PlayerTrack(identifier: identifier, name: name, language: language,
                             codec: fourcc.flatMap { $0 == 0 ? nil : TechDetails.codecNameValue(vlcId: UInt32(truncatingIfNeeded: $0)) },
                             channels: channels.flatMap { $0 > 0 ? $0 : nil })
    }

    /// libVLC 3 names tracks "Track 1 - [English]"; the language is in the brackets.
    static func bracketLanguage(_ name: String) -> String? {
        guard name.hasSuffix("]"), let on = name.lastIndex(of: "[") else { return nil }
        let inner = name[name.index(after: on)..<name.index(before: name.endIndex)]
        return inner.isEmpty ? nil : String(inner)
    }
}
struct SubtitleFileResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case index
        case address = "adresse"
    }
 let index: Int; let address: String }
struct TrackSelectionResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case audio = "ton"
        case subtitle = "untertitel"
    }
 let audio: Int?; let subtitle: Int }
struct TrackName: Encodable {
    enum CodingKeys: String, CodingKey {
        case id
        case text
        case forced = "erzwungen"
        case file = "datei"
        case hearingImpaired = "hoergeschaedigt"
    }
 let id: Int; let text: String; let forced: Bool; let file: Bool; var hearingImpaired = false }
struct TrackNamesResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case audio = "ton"
        case subtitle = "untertitel"
    }
 let audio: [TrackName]; let subtitle: [TrackName] }
