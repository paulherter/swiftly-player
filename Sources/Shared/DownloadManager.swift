import Foundation
import JellyfinKit
import Network
import Observation
import SwiftlyCore
#if canImport(UIKit)
import UIKit
#endif

/// What the screens see of the downloads: the list, the running progress and the commands.
///
/// **The rules, the queue and the list file live in the core** (`DownloadsModel`, the Rust download
/// manager): who is next, whether space suffices, Wi-Fi only, pausing, resume data, the next episode,
/// what is expendable. The transfer layer is `URLSessionDownloadHost` (background session, files, resume
/// data). This class is a thin layer with the members the 86 call sites already use, so the views did
/// not move: `entries` is rebuilt from the core's items on every change, and the running bytes go to
/// per-title `DownloadProgress` objects only, never into `entries` (a view that reads the list must not
/// redraw on every packet).
///
/// The files are excluded from backup (on the folder, see `DownloadFiles.folder()`).
@MainActor
@Observable
final class DownloadManager {

    /// Background session identifier. **Fixed and unique:** iOS matches running transfers by it.
    static let sessionId = DownloadFiles.sessionId

    private(set) var entries: [DownloadItem] = []
    /// Last measured free space. Refreshed when the page opens and after each finished download.
    private(set) var free: Int64 = 0
    /// The latest message a view should show.
    var message: String?

    /// Whether downloading is allowed over cellular (from settings): `true` means Wi-Fi only.
    var onlyOverWLAN = true {
        didSet {
            guard onlyOverWLAN != oldValue else { return }
            command(.onlyOverWlan(on: onlyOverWLAN))
        }
    }

    /// **"Load next episode".** Off by default (the key is the one the older build used).
    var nextAuto = UserDefaults.standard.bool(forKey: DownloadManager.nextAutoKey) {
        didSet {
            UserDefaults.standard.set(nextAuto, forKey: DownloadManager.nextAutoKey)
            if nextAuto != oldValue { command(.nextAuto(on: nextAuto)) }
        }
    }
    static let nextAutoKey = "naechsteFolgeLaden"

    // `@ObservationIgnored` is required for everything below that is lazy or not a view input.
    @ObservationIgnored private let holder = ClientHolder()
    @ObservationIgnored private var model: DownloadsModel?
    @ObservationIgnored private var host: URLSessionDownloadHost?
    @ObservationIgnored private var observing: Task<Void, Never>?
    /// **The running state per title, individually observable**; see `DownloadProgress`.
    @ObservationIgnored private var live: [String: DownloadProgress] = [:]
    /// Last published state per download and when (the number should count, not jitter).
    @ObservationIgnored private var reported: [String: Int64] = [:]
    @ObservationIgnored private var reportedAround: [String: Date] = [:]
    @ObservationIgnored private var started = false

    // MARK: The core

    /// The model and its transfer layer, made when first needed (the session of a background wake-up
    /// is created by the same call).
    private func core() -> DownloadsModel {
        if let model { return model }
        let host = URLSessionDownloadHost(hooks: makeHooks())
        let model = AppCore.shared.downloads(host: host, onlyOverWlan: onlyOverWLAN, nextAuto: nextAuto)
        host.attach(model)
        host.onProgress { [weak self] id, loaded, total in
            Task { @MainActor in self?.progress(id, loaded: loaded, total: total) }
        }
        model.onChange = { [weak self] in self?.refresh() }
        observing = Task { @MainActor in await model.observe() }
        host.start()
        self.model = model
        self.host = host
        return model
    }

    private func command(_ intent: DownloadsIntent) {
        guard model != nil || started else { return }
        do { try core().send(intent) } catch {
            AppLog.writeOut("[Download] Befehl abgelehnt: \(error)")
        }
        refresh()
    }

    /// Rebuild `entries` from the core's items. **Progress is not in `entries`**: the running bytes are
    /// copied from what the view already has, so an update that only moved bytes changes nothing and
    /// redraws nobody.
    private func refresh() {
        guard let model, var fresh = try? JSONDecoder().decode([DownloadItem].self, from: model.itemsJson())
        else { return }
        let before = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for i in fresh.indices where fresh[i].state == .loads {
            if let old = before[fresh[i].id], old.state == .loads { fresh[i].loaded = old.loaded }
        }
        // The running state follows the list: a title that is not loading has none.
        let loading = Set(fresh.filter { $0.state == .loads }.map(\.id))
        for id in Array(live.keys) where !loading.contains(id) {
            live[id] = nil
            reported[id] = nil
            reportedAround[id] = nil
        }
        for p in fresh where p.state == .loads && live[p.id] == nil {
            live[p.id] = DownloadProgress(loaded: p.loaded, total: p.bytes)
        }
        if fresh != entries { entries = fresh }
        spaceMeasure()
    }

    // MARK: Where things live

    nonisolated static func folder() -> URL { DownloadFiles.folder() }

    /// Titles whose file did not open this session: the player streams them instead.
    @ObservationIgnored var playFailed: Set<String> = []

    /// Where the file for a title lives, or `nil` if it is not there. **H8.** The player asks here first.
    func file(for id: String) -> URL? {
        guard let p = entries.first(where: { $0.id == id && $0.state == .done }) else { return nil }
        let distance = DownloadFiles.folder().appendingPathComponent(p.fileName)
        return FileManager.default.fileExists(atPath: distance.path) ? distance : nil
    }

    /// With the live state: whoever asks here sees the progress and redraws **only itself** on each update.
    func entries(for id: String) -> DownloadItem? {
        entries.first { $0.id == id }.map(current)
    }

    /// An item with what is currently downloaded (see the class comment).
    func current(_ p: DownloadItem) -> DownloadItem {
        guard p.state == .loads, let f = live[p.id] else { return p }
        var q = p
        q.loaded = f.loaded
        if q.bytes == 0 { q.bytes = f.total }
        return q
    }

    private func entry(_ id: String) -> DownloadItem? { entries.first { $0.id == id } }

    // MARK: Subtitles for offline

    /// Where the external subtitles for a downloaded file live (a separate folder, so VLC does not load
    /// them a second time).
    nonisolated static func subtitleFolder(to file: URL) -> URL { DownloadFiles.subtitleFolder(to: file) }

    /// The downloaded subtitles of a file from disk, for attaching. File name is `<index>.<extension>`.
    nonisolated static func subtitle(to file: URL, attribute: (URL) -> String?) -> [SubtitleFile] {
        let folder = subtitleFolder(to: file)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.sorted().compactMap { name in
            guard let index = Int(name.split(separator: ".").first ?? "") else { return nil }
            let distance = folder.appendingPathComponent(name)
            return SubtitleFile(index: index, address: distance, attribute: attribute(distance))
        }
    }

    /// For everything downloaded before 1.0.5 or that got no answer at download time. Needs a server.
    func sectionsCatchUp() { command(.sectionsCatchUp) }

    // MARK: Watched state on the device

    /// **Record a playback, even offline.** The thresholds and the next episode are the core's.
    func playbackRemember(_ id: String, ticks: Int64, moment: Date = Date()) {
        command(.playbackRemembered(id: id, ticks: ticks, now: moment.timeIntervalSince1970))
    }

    /// Pick up what could not be looked up yet. Called on contact with the server.
    func smartCatchUp() { command(.smartCatchUp) }

    // MARK: Account

    /// **H11.** After sign-in, what belongs to this account applies, and only that; an account switch
    /// stops the old account's transfers (the core), its titles stay on disk.
    func signIn(client: (any MediaServer)?, account: String?) {
        holder.client = client
        started = true
        command(.signIn(account: account, client: client != nil))
    }

    /// Measure fresh when a selection opens: the device may have filled up since sign-in.
    func spaceRefresh() { spaceMeasure() }

    private func spaceMeasure() {
        let bytes = DownloadFiles.freeSpace()
        guard bytes != free else { return }
        free = bytes
    }

    // MARK: Kicking off

    /// What a download would cost, for the sheet before starting.
    func inquiry(for bytes: Int64) -> DownloadRules.SpaceInfo {
        spaceMeasure()
        guard model != nil || started else { return DownloadRules.slot(for: bytes, free: free, available: entries) }
        let core = core()
        try? core.send(.spaceChanged(bytes: free))
        let answer = core.inquiry(bytes: bytes)
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return DownloadRules.SpaceInfo(
            suffices: answer.suffices, freeAfter: answer.freeAfter,
            dispensable: answer.dispensable.compactMap { byID[$0] },
            dispensableBytes: answer.dispensableBytes)
    }

    /// Queue a title. Starts it when it is its turn. `images` maps ids to image URLs (the title's own,
    /// the series' poster, and `headerKey(series)` for the large header), downloaded along so the page
    /// has images on a plane.
    func trigger(_ new: DownloadItem, images: [String: URL] = [:]) {
        trigger([new], images: images)
    }

    /// A whole season. One after another: the core's one-at-a-time rule.
    func trigger(_ many: [DownloadItem], images: [String: URL] = [:]) {
        let fresh = many.filter { p in !entries.contains(where: { $0.id == p.id }) }
        guard !fresh.isEmpty else { return }
        let requests = fresh.map { p in
            DownloadRequest(
                id: p.id, account: p.account, episodeKind: p.art == .episode, title: p.title,
                series: p.series, seriesId: p.seriesIdentifier, season: p.season.map(Int64.init),
                episode: p.episode.map(Int64.init), runtimeTicks: p.runtimeTicks, container: p.container,
                source: p.source, bytes: p.bytes, created: p.created.timeIntervalSince1970,
                image: images[p.id]?.absoluteString, quality: p.quality?.rawValue,
                audioIndex: p.audioIndex.map(Int64.init), audioLanguage: p.audioLanguage,
                videoCodec: p.videoCodec, replaces: p.replaces)
        }
        let ids = Set(fresh.map(\.id))
        let more = images.filter { !ids.contains($0.key) }.map { DownloadImage(key: $0.key, url: $0.value.absoluteString) }
        command(.start(items: requests, images: more, checkSpace: false))
    }

    /// **Failed immediately?** The download sheet closes on tap, and a download that aborts right away
    /// would show red only in Downloads, where nobody is looking. Returns the reason of the first failed
    /// one among the given titles within the deadline, otherwise `nil`.
    func immediateFailed(_ ids: [String], deadline: Duration = .seconds(4)) async -> String? {
        guard !ids.isEmpty else { return nil }
        let end = ContinuousClock.now + deadline
        while ContinuousClock.now < end {
            if let p = entries.first(where: { ids.contains($0.id) && $0.state == .error }) {
                return p.reason.map { String(localized: "Der Download ist gescheitert. \($0)") }
                    ?? String(localized: "Der Download ist gescheitert.")
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    // MARK: The images

    private static func imageDistance(_ account: String, _ identifier: String) -> URL {
        DownloadFiles.folder().appendingPathComponent(DownloadItem.imageName(account: account, identifier: identifier))
    }

    /// The image on the device, or `nil`, then the row uses the server URL. `asGroup` asks for the series
    /// poster instead of the single episode's image.
    func image(for p: DownloadItem, asGroup: Bool = false) -> URL? {
        let identifier = asGroup ? (p.seriesIdentifier ?? p.id) : p.id
        let distance = Self.imageDistance(p.account, identifier)
        return FileManager.default.fileExists(atPath: distance.path) ? distance : nil
    }

    /// Under this key the series page hands the large header image to `trigger(_:images:)`.
    static func headerKey(_ seriesIdentifier: String) -> String { "kopf:" + seriesIdentifier }

    /// The series' header image at screen resolution, for the series page in Downloads.
    func headerImage(series seriesIdentifier: String, account: String) -> URL? {
        let distance = Self.imageDistance(account, seriesIdentifier + "-kopf")
        return FileManager.default.fileExists(atPath: distance.path) ? distance : nil
    }

    /// For earlier downloads that lack it: fetch on the next open with network.
    func headerImageCatchUp(series seriesIdentifier: String, account: String, from address: URL) async -> URL? {
        let target = Self.imageDistance(account, seriesIdentifier + "-kopf")
        guard !FileManager.default.fileExists(atPath: target.path) else { return target }
        guard let (data, _) = try? await URLSession.shared.data(for: .withOwnHeaders(address)),
              data.count > 0, (try? data.write(to: target, options: .atomic)) != nil
        else { return nil }
        return target
    }

    // MARK: Commands

    /// **Pausing is not an error** (the core tells a cancellation by its generation).
    func halt(_ id: String) { command(.pause(id: id)) }

    func resume(_ id: String) { command(.resume(id: id)) }

    /// Several at once. Finished titles are deleted, the others cancelled; files and images go with them.
    func remove(_ ids: [String]) {
        let finished = entries.filter { ids.contains($0.id) && $0.state == .done }.map(\.id)
        let others = ids.filter { !finished.contains($0) }
        if !finished.isEmpty { command(.delete(ids: finished)) }
        for id in others where entries.contains(where: { $0.id == id }) { command(.cancel(id: id)) }
        spaceMeasure()
    }

    /// Pause everything without deleting anything (what switching the toggle off does).
    func allHalt() { command(.pauseAll) }

    /// The pause rule, the other answer: remove everything.
    func allRemove() { command(.deleteAll) }

    /// Start what is next. The core does this itself after every change; this stays for a caller that
    /// wants to nudge the queue.
    func tick() { command(.tick) }

    // MARK: Progress

    private func progress(_ id: String, loaded: Int64, total: Int64) {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].state == .loads else { return }
        // Not every callback is a visible change: half a percent on a ring, once per second at most.
        let now = Date()
        guard DownloadRules.progressShow(
            loaded: loaded, total: total > 0 ? total : entries[i].bytes,
            before: reported[id], elapsed: reportedAround[id].map { now.timeIntervalSince($0) })
        else { return }
        reported[id] = loaded
        reportedAround[id] = now
        // If the server gives no size in the catalog, the bar takes the one from the response (not saved).
        let newTotal = entries[i].bytes == 0 && total > 0 ? total : entries[i].bytes
        if let f = live[id] {
            f.loaded = loaded
            if f.total != newTotal { f.total = newTotal }
        } else {
            live[id] = DownloadProgress(loaded: loaded, total: newTotal)
        }
    }

    // MARK: Network

    /// Whether Wi-Fi is currently available.
    private(set) var wLAN = true
    /// No connection at all. **The day this feature is built for**: the page then switches its header.
    private(set) var noNetwork = false
    @ObservationIgnored private var networkRead = false
    /// **`NWPathMonitor`, rather than guessing**; it runs only while the feature is switched on. The
    /// verdict (Wi-Fi only, put back, wait for the first answer) is the core's.
    @ObservationIgnored private var sentry: NWPathMonitor?

    func networkObserve() {
        guard sentry == nil else { return }
        let w = NWPathMonitor()
        w.pathUpdateHandler = { [weak self] path in
            let wlan = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            let distance = path.status != .satisfied
            Task { @MainActor in self?.networkStatus(wLAN: wlan, noNetwork: distance) }
        }
        w.start(queue: DispatchQueue(label: "de.paulherter.swiftly.netzwache"))
        sentry = w
    }

    func networkNotMoreObserve() {
        sentry?.cancel()
        sentry = nil
        networkRead = false
        command(.networkObserveStopped)
    }

    #if DEBUG
    /// Self-test without network (`OfflineRun`): same effect as the path monitor.
    func simulateNetwork(distance: Bool) { networkStatus(wLAN: !distance, noNetwork: distance) }
    #endif

    private func networkStatus(wLAN wlan: Bool, noNetwork distance: Bool) {
        let first = !networkRead
        networkRead = true
        guard first || wlan != wLAN || distance != noNetwork else { return }
        wLAN = wlan
        noNetwork = distance
        AppLog.writeOut("[Download] Netz: \(distance ? "keins" : wlan ? "WLAN" : "Mobilfunk")")
        command(.networkChanged(wlan: wlan, none: distance))
    }

    // MARK: The title has disappeared from the server

    /// **Pull in what the server says in one go** (watched state, "no longer on the server"). What comes
    /// in is explicitly answered, not queried: someone offline gets no answer, and then "no longer on the
    /// server" would be the wrong verdict for every title. The caller keeps those apart.
    func follow(available: Set<String>, watchState: [String: UserItemData]) {
        let states = watchState.map { id, s in
            DownloadWatchState(
                id: id, played: s.played, positionTicks: s.playbackPositionTicks,
                playedPercentage: s.playedPercentage, lastPlayedDate: s.lastPlayedDate)
        }
        command(.serverFollow(available: Array(available), states: states))
        smartCatchUp()
    }

    /// **Offline playback the server has not seen**, decided by the core against the server's watch state
    /// (call after `follow`). The pending-report list as JSON, `"[]"` when there is nothing.
    func unreportedProgress(account: String, watchState: [String: UserItemData]) -> String {
        guard let model else { return "[]" }
        let states = watchState.map { id, s in
            DownloadWatchState(
                id: id, played: s.played, positionTicks: s.playbackPositionTicks,
                playedPercentage: s.playedPercentage, lastPlayedDate: s.lastPlayedDate)
        }
        return model.unreportedProgressJson(account: account, states: states)
    }

    // MARK: Hooks (everything the core asks that needs the signed-in client)

    private func makeHooks() -> DownloadHostHooks {
        let holder = holder
        return DownloadHostHooks(
            address: { id, source, quality, audioIndex in
                guard let client = holder.client else { throw JellyfinError.notAuthenticated }
                return try await client.downloadURL(
                    itemID: id, mediaSourceID: source, quality: DownloadQuality(rawValue: quality) ?? .original,
                    audioStreamIndex: audioIndex)
            },
            subtitles: { [weak self] id, source in
                // **Take external subtitles along** once the movie itself is there; for a built file also
                // the embedded text subtitles (the file only holds picture and sound).
                guard let client = holder.client, let p = await self?.entry(id),
                      let plan = try? await client.playbackPlan(for: id),
                      let session = await client.currentSession() else { return false }
                let file = DownloadFiles.folder().appendingPathComponent(p.fileName)
                let streams = plan.source?.mediaStreams ?? []
                let files = SubtitleFile.withLoad(
                    streams: streams, itemID: id, source: p.source ?? source ?? plan.source?.id,
                    server: session.serverURL, key: session.accessToken,
                    keyName: EmbyPaths.tokenName(for: session.kind), converted: p.streamed)
                // What an original file keeps inside (its subtitle tracks) is part of the stored list too.
                let embedded = DownloadedSubtitles.facts(streams: streams, fetched: [], embeddedStay: !p.streamed)
                guard !files.isEmpty || !embedded.isEmpty else { return true }
                let target = DownloadFiles.subtitleFolder(to: file)
                try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                var loaded = 0
                var fetched = Set<Int>()
                for d in files {
                    guard let (data, answer) = try? await URLSession.shared.data(for: .withOwnHeaders(d.address)),
                          (answer as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { continue }
                    let suffix = d.address.pathExtension.isEmpty ? "srt" : d.address.pathExtension
                    if (try? data.write(to: target.appendingPathComponent("\(d.index).\(suffix)"))) != nil {
                        loaded += 1
                        fetched.insert(d.index)
                    }
                }
                // The facts for the track list next to the files (`info.json`, the shape the Rust UIs write): language, title,
                // format, forced. Never an address or a key.
                DownloadedSubtitles.write(
                    DownloadedSubtitles.facts(streams: streams, fetched: fetched, embeddedStay: !p.streamed), to: target)
                AppLog.writeOut("[Download] Untertitel für \(id): \(loaded) von \(files.count)")
                return loaded == files.count
            },
            sections: { id in
                guard let client = holder.client, let parts = await client.segmentsToStore(for: id) else { return nil }
                AppLog.writeOut("[Download] Abschnitte für \(id): \(parts.count)")
                return parts.map { part in
                    let kind: PlayerSectionKind =
                        switch part.art {
                        case .unknown: .unknown
                        case .ads: .ads
                        case .preview: .preview
                        case .lookBack: .lookBack
                        case .credits: .credits
                        case .introSegment: .intro
                        }
                    return PlayerSection(kind: kind, from: part.from, until: part.until)
                }
            },
            successor: { [weak self] id, seriesId in
                // No answer (offline) stays pending; the core asks again on the next contact.
                guard let client = holder.client, let all = try? await client.episodes(seriesID: seriesId),
                      let current = await self?.entry(id),
                      let raw = try? JSONEncoder().encode(EpisodesAnswer(Items: all)) else { return nil }
                var image: String?
                if let next = DownloadRules.followingEpisode(after: current, in: all),
                   let landscape = await client.imageURL(for: next, maxHeight: 220) {
                    image = landscape.absoluteString
                }
                return (raw, image)
            },
            prepare: { request in request.ownHeadersSet() },
            failureText: { failure in
                switch failure {
                case .http(let status): readableError(JellyfinError.http(status: status, body: nil))
                case .error(let error): readableError(error)
                }
            })
    }
}

/// The server's `Items` answer shape the core reads the episode list from.
private struct EpisodesAnswer: Encodable { let Items: [Item] }

/// The signed-in client for the hooks, which run off the main actor.
private final class ClientHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (any MediaServer)?
    var client: (any MediaServer)? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// **A title's progress, observable on its own.**
///
/// A separate class per title so an update redraws only the views that read exactly this title. While it
/// was a number in `DownloadManager.entries`, every update changed the whole list.
@MainActor
@Observable
final class DownloadProgress {
    var loaded: Int64
    var total: Int64

    init(loaded: Int64, total: Int64) {
        self.loaded = loaded
        self.total = total
    }
}
