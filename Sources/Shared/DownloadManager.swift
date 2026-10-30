import Foundation
import JellyfinKit
import Network
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// What is actually downloading and where it is stored.
///
/// **The rules do not live here.** Who is next, whether space suffices and what
/// is expendable is `DownloadRules` in the package, tested there without a
/// simulator. This class only holds what needs a file system and a running process.
///
/// **Why a background session and not `URLSession.shared`.** An 18 GB file
/// cannot finish in the thirty seconds iOS gives an app in the background.
/// `URLSessionConfiguration.background` hands the transfer to a system service
/// that keeps running after the app is terminated and relaunches the app when
/// it finishes. That is the only approach that works at these sizes.
///
/// **The files are excluded from backup.** Writing forty gigabytes of video to an
/// iCloud backup is wrong in itself and violates Apple's Data Storage Guidelines:
/// re-downloadable content does not belong in a backup. The flag is set on the
/// folder, not on each file, so a future storage location cannot forget it.
@MainActor
@Observable
final class DownloadManager {

    /// Background session identifier. **Fixed and unique:** iOS matches running
    /// transfers by it, and a new identifier would mean a restarted app no longer
    /// finds its running downloads.
    static let sessionId = "de.paulherter.swiftly.downloads"

    private(set) var entries: [DownloadItem] = []
    /// Last measured free space. Refreshed when the page opens and after each
    /// finished download.
    private(set) var free: Int64 = 0
    /// The latest message a view should show.
    var message: String?

    /// Whether downloading is allowed at all (from settings).
    var onlyOverWLAN = true { didSet { tick() } }

    // **`@ObservationIgnored` is required here, not polish.** `@Observable` adds an
    // `init` accessor for every stored property, which cannot reach a `lazy`; the
    // build fails with "init accessors can refer only to stored properties".
    // Nothing here needs observing anyway: no view reads the session, the delegate
    // or the running tasks.
    @ObservationIgnored private var client: JellyfinClient?
    @ObservationIgnored private var account: String?
    /// Item id to running task.
    @ObservationIgnored private var tasks: [String: URLSessionDownloadTask] = [:]
    /// Resume data returned on pause, for resuming.
    @ObservationIgnored private var resumeData: [String: Data] = [:]
    /// The current generation per title; see `DownloadTask`.
    @ObservationIgnored private var generation: [String: Int] = [:]
    /// Counts up, never back. Starts from the clock so a number from an earlier
    /// process run cannot accidentally match again.
    @ObservationIgnored private var generationCounter = Int(Date().timeIntervalSince1970 * 1000)
    /// **The running state per title, individually observable**; see
    /// `DownloadProgress`.
    @ObservationIgnored private var live: [String: DownloadProgress] = [:]
    /// While tasks from a previous run are being looked up, `tick` starts
    /// nothing, otherwise the same title would run twice.
    @ObservationIgnored private var searchesTasks = false

    @ObservationIgnored private lazy var session: URLSession = {
        let k = URLSessionConfiguration.background(withIdentifier: Self.sessionId)
        // **Both on purpose.** `isDiscretionary` would let iOS defer the download to a
        // "good moment" (night, on power); whoever taps download wants it now. And
        // `waitsFor…` makes a download wait in a dead zone instead of failing.
        k.isDiscretionary = false
        k.waitsForConnectivity = true
        // Cellular is decided by us, so the session allows both and is
        // controlled by `mayLoad`.
        k.allowsCellularAccess = true
        k.sessionSendsLaunchEvents = true
        return URLSession(configuration: k, delegate: reporter, delegateQueue: nil)
    }()

    @ObservationIgnored private lazy var reporter = DownloadReporter(
        progress: { [weak self] t, loaded, total in
            Task { @MainActor in self?.progress(t, loaded: loaded, total: total) }
        },
        done: { [weak self] t, file in
            // **The file must be moved here, not later.** iOS deletes it as soon as the
            // callback returns; a `Task` that picks it up on the main thread later finds
            // nothing.
            let target = DownloadManager.folder().appendingPathComponent(file.name)
            try? FileManager.default.removeItem(at: target)
            let worked = (try? FileManager.default.moveItem(at: file.temp, to: target)) != nil
            Task { @MainActor in self?.completed(t, worked: worked) }
        },
        failed: { [weak self] t, reason, resume in
            Task { @MainActor in self?.failed(t, reason: reason, resume: resume) }
        })

    // MARK: Ablage

    /// **`nonisolated` because the delegate needs it.** It runs on the session's
    /// queue, a foreign thread, and must move the finished file from where iOS puts
    /// it before returning, or it is gone. The function touches no state, so this
    /// costs nothing.
    nonisolated static func folder() -> URL {
        let f = FileManager.default
        let base = (try? f.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? URL.temporaryDirectory
        var folder = base.appendingPathComponent("Downloads", isDirectory: true)
        if !f.fileExists(atPath: folder.path) {
            try? f.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // On the folder, not the files (see above).
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        return folder
    }

    nonisolated private static var directoryFile: URL {
        folder().appendingPathComponent("liste.json")
    }

    /// Where the file for a title lives, or `nil` if it is not there.
    ///
    /// **H8.** The player asks here first and notices nothing else.
    func file(for id: String) -> URL? {
        guard let p = entries.first(where: { $0.id == id && $0.state == .done }) else { return nil }
        let distance = Self.folder().appendingPathComponent(p.fileName)
        return FileManager.default.fileExists(atPath: distance.path) ? distance : nil
    }

    /// With the live state: whoever asks here sees the progress and redraws
    /// **only itself** on each update.
    func entries(for id: String) -> DownloadItem? {
        entries.first { $0.id == id }.map(current)
    }

    /// An item with what is currently downloaded.
    ///
    /// **Progress is not in `entries`.** It used to be, and because `@Observable`
    /// tracks the whole list as one property, every update redrew every view that
    /// read anything from the list: the downloads page with all rows, every episode
    /// list, the bar. Now only callers of this function read it, and only for their title.
    func current(_ p: DownloadItem) -> DownloadItem {
        guard let f = live[p.id] else { return p }
        var q = p
        q.loaded = f.loaded
        if q.bytes == 0 { q.bytes = f.total }
        return q
    }

    // MARK: - Subtitles for offline

    /// Where the external subtitles for a downloaded file live.
    ///
    /// **A separate folder, not next to the file.** VLC loads subtitles whose name
    /// starts with the file's name by itself, so the same track would show twice
    /// in the list, once from VLC and once from us.
    nonisolated static func subtitleFolder(to file: URL) -> URL {
        file.deletingLastPathComponent()
            .appendingPathComponent(file.lastPathComponent + ".untertitel", isDirectory: true)
    }

    /// The downloaded subtitles of a file from disk, for attaching.
    /// File name is `<Jellyfin-Index>.<extension>`.
    nonisolated static func subtitle(to file: URL, attribute: (URL) -> String?) -> [SubtitleFile] {
        let folder = subtitleFolder(to: file)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.sorted().compactMap { name in
            guard let index = Int(name.split(separator: ".").first ?? "") else { return nil }
            let distance = folder.appendingPathComponent(name)
            return SubtitleFile(index: index, address: distance, attribute: attribute(distance))
        }
    }

    /// **Take external subtitles along** once the movie itself is there.
    ///
    /// Embedded subtitles are in the file and travel with it; external ones (.srt,
    /// .ass next to the movie on the server) were previously fetched over the
    /// network only, so offline they were not selectable.
    private func subtitleFetch(_ p: DownloadItem) {
        guard let client else { return }
        let file = Self.folder().appendingPathComponent(p.fileName)
        Task {
            guard let plan = try? await client.playbackPlan(for: p.id),
                  let session = await client.currentSession() else { return }
            // For a transcoded file also the embedded text subtitles; the file only
            // contains picture and sound.
            let files = SubtitleFile.withLoad(streams: plan.source?.mediaStreams ?? [],
                                                   itemID: p.id, source: p.source ?? plan.source?.id,
                                                   server: session.serverURL,
                                                   key: session.accessToken,
                                                   converted: p.streamed)
            guard !files.isEmpty else { return }
            let target = Self.subtitleFolder(to: file)
            try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            var loaded = 0
            for d in files {
                guard let (data, answer) = try? await URLSession.shared.data(for: .withOwnHeaders(d.address)),
                      (answer as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { continue }
                let suffix = d.address.pathExtension.isEmpty ? "srt" : d.address.pathExtension
                if (try? data.write(to: target.appendingPathComponent("\(d.index).\(suffix)"))) != nil {
                    loaded += 1
                }
            }
            AppLog.writeOut("[Download] Untertitel für \(p.id): \(loaded) von \(files.count)")
        }
    }

    // MARK: - Segments for offline

    /// **Take intro and credits along** once the file is there, otherwise there is
    /// no "Skip intro" and no "Next episode" card without a server. No answer
    /// (`nil`) leaves the field empty, and ``sectionsCatchUp()`` asks again
    /// on the next contact.
    private func sectionsFetch(_ id: String) {
        guard let client else { return }
        Task {
            guard let parts = await client.segmentsToStore(for: id),
                  let i = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[i].sections = parts
            secure()
            AppLog.writeOut("[Download] Abschnitte für \(id): \(parts.count)")
        }
    }

    /// For everything downloaded before 1.0.5 or that got no answer at download
    /// time. Needs a server (``AppModel/downloadsNachziehen()``).
    func sectionsCatchUp() {
        for p in entries where p.state == .done && p.sections == nil {
            sectionsFetch(p.id)
        }
    }

    // MARK: - Watched state on the device

    /// **Record a playback, even offline.** The list then shows the checkmark once
    /// an episode finished on a plane, the series play button picks the next one,
    /// and the list starts at the remembered position. The thresholds are the
    /// server's (``Downloadposten/postPlayback(ticks:wann:)``).
    func playbackRemember(_ id: String, ticks: Int64, moment: Date = Date()) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i] = entries[i].postPlayback(ticks: ticks, moment: moment)
        // Watched to the end: the next episode is due. Marked first, so a lookup that
        // finds no server is repeated on the next contact (``smartCatchUp()``).
        if nextAuto, DownloadRules.hasSuccessor(entries[i]),
           DownloadRules.reachedEnd(ticks: ticks, runtimeTicks: entries[i].runtimeTicks) {
            entries[i].nextPending = true
            smartNext(id)
        }
        secure()
    }

    // MARK: - Next episode

    /// **"Load next episode".** Off by default; whoever switches it on gets the next
    /// episode of a series loaded when a downloaded one was watched to the end, in
    /// the same quality and audio, and the watched one removed once the new one has
    /// arrived. Kept here and not in `AppModel`: nothing else needs to know.
    var nextAuto = UserDefaults.standard.bool(forKey: DownloadManager.nextAutoKey) {
        didSet { UserDefaults.standard.set(nextAuto, forKey: DownloadManager.nextAutoKey) }
    }
    static let nextAutoKey = "naechsteFolgeLaden"

    /// Episodes whose successor is being looked up, so one lookup runs at a time.
    @ObservationIgnored private var successorSearches: Set<String> = []

    /// Queue the successor of a watched, downloaded episode. **Wi-Fi-only needs no
    /// extra code**: the entry joins the queue like any other and ``tick()`` holds it
    /// back until the rule allows it.
    private func smartNext(_ id: String) {
        guard nextAuto, let client, !successorSearches.contains(id),
              let watched = entries.first(where: { $0.id == id }),
              watched.nextPending == true, DownloadRules.hasSuccessor(watched),
              let seriesID = watched.seriesIdentifier else { return }
        successorSearches.insert(id)
        Task { [weak self] in
            let all = try? await client.episodes(seriesID: seriesID)
            guard let self else { return }
            self.successorSearches.remove(id)
            // No answer (offline): stays pending.
            guard let all, let i = self.entries.firstIndex(where: { $0.id == id }) else { return }
            let current = self.entries[i]
            self.entries[i].nextPending = nil
            self.secure()
            // After the last episode the watched one simply stays. An episode already on
            // the device or in the queue is not loaded again.
            guard let next = DownloadRules.followingEpisode(after: current, in: all),
                  !self.entries.contains(where: { $0.id == next.id }) else { return }
            let follower = DownloadRules.followUp(to: current, next: next)
            guard self.inquiry(for: follower.bytes).suffices else { return }
            var images: [String: URL] = [:]
            if let landscape = await client.imageURL(for: next, maxHeight: 220) {
                images[next.id] = landscape
            }
            self.trigger(follower, images: images)
            AppLog.writeOut("[Download] nächste Folge \(next.id) nach \(id)")
        }
    }

    /// Pick up what could not be looked up yet. Called on contact with the server.
    func smartCatchUp() {
        for p in entries where p.nextPending == true { smartNext(p.id) }
    }

    // MARK: Konto

    /// **H11.** After sign-in, what belongs to this account applies, and only that.
    ///
    /// **On account switch the old account stops downloading.** Before, its task
    /// kept running and its callbacks landed in the new account's list, even on
    /// the same title when two users of one server shared ids. The old account's
    /// titles stay on disk and wait until it signs in again.
    func signIn(client: JellyfinClient?, account: String?) {
        self.client = client
        // What is queued goes out **now**, still under the old account; right after,
        // `load` re-reads the list, and by then items and account no longer matched.
        if self.account != nil, safePreRemembered || account != self.account { immediateSafe() }
        if account != self.account { release() }
        self.account = account
        load()
        spaceMeasure()
        // Set before the `Task`, not inside it: in between no other `tick` may start
        // a title whose task is about to be found again.
        searchesTasks = true
        Task {
            await tasksAgainFind()
            searchesTasks = false
            tick()
        }
    }

    /// Stop and forget everything that ran for the previous account.
    private func release() {
        for (id, task) in tasks {
            newGeneration(id)
            task.cancel()
        }
        tasks = [:]
        resumeData = [:]
        reported = [:]
        reportedAround = [:]
        live = [:]
    }

    @discardableResult
    private func newGeneration(_ id: String) -> Int {
        generationCounter += 1
        generation[id] = generationCounter
        return generationCounter
    }

    /// **What kept running in the system belongs again.**
    ///
    /// The background session keeps downloading after the app is terminated. On the
    /// next launch the title still showed "waiting" and `tick` started it a second
    /// time alongside. Now the running tasks are looked up and adopted first.
    private func tasksAgainFind() async {
        guard account != nil else { return }
        let all = await session.allTasks
        for task in all {
            guard let d = task as? URLSessionDownloadTask,
                  d.state == .running || d.state == .suspended,
                  let t = DownloadTask.dismantle(d.taskDescription) else { continue }
            guard tasks[t.id] == nil else { continue }
            guard let i = entries.firstIndex(where: { $0.id == t.id }),
                  entries[i].state == .waits || entries[i].state == .loads else {
                // Belongs to no waiting title of this account: paused, removed, or another
                // account. Then it does not continue.
                d.cancel()
                continue
            }
            generation[t.id] = t.generation
            tasks[t.id] = d
            entries[i].state = .loads
            live[t.id] = DownloadProgress(loaded: max(entries[i].loaded, d.countOfBytesReceived),
                                             total: entries[i].bytes)
            if d.state == .suspended { d.resume() }
            AppLog.writeOut("[Download] laufende Aufgabe übernommen: \(t.id)")
        }
    }

    private func load() {
        // **Read after the last write.** Saving happens off the main path; without
        // waiting, this load might read a state from before the latest change, and a
        // just-started title would be gone.
        guard let account, let all = Self.writeQueue.sync(execute: { Self.allRead() })
        else { entries = []; return }
        // The list on disk holds the titles of **all** accounts; only the current
        // one is shown. Nothing is deleted here; the other account finds its titles
        // again when it signs in.
        entries = all.filter { $0.account == account }
        // What was mid-download last time waits again, unless its task is still
        // running in this process (same account signing in again). Otherwise `tick`
        // would start it a second time. What kept running in the system is found by
        // `tasksAgainFind`.
        for i in entries.indices where entries[i].state == .loads && tasks[entries[i].id] == nil {
            entries[i].state = .waits
        }
    }

    /// **Saving happens once per pass, and not on the main path.**
    ///
    /// Every change used to write the whole list immediately and synchronously: read,
    /// decrypt, encrypt, write. `nachziehen` did that twice per title and
    /// `allHalt` once per title, so eighty times in a row on the main path for
    /// forty episodes. Now each change only marks itself; at the end of a pass **one**
    /// state goes to a private queue that writes in order.
    @ObservationIgnored private var safePreRemembered = false

    private func secure() {
        guard account != nil, !safePreRemembered else { return }
        safePreRemembered = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.safePreRemembered = false
            self.immediateSafe()
        }
    }

    private func immediateSafe() {
        guard let account else { return }
        let state = entries.map(current)
        Self.writeQueue.async { Self.allWrite(state, account: account) }
    }

    /// Serial: two states must not overtake each other while writing.
    private static let writeQueue = DispatchQueue(label: "de.paulherter.swiftly.downloadliste",
                                                       qos: .utility)

    /// The whole list of all accounts, or `nil` if none exists or it cannot be read.
    ///
    /// **A broken list is not silently overwritten.** It used to count as empty:
    /// the page showed nothing and the next save wrote back only the current
    /// account, losing every other account's titles and orphaning their files.
    /// Now it is logged and the file is set aside first.
    nonisolated private static func allRead() -> [DownloadItem]? {
        let distance = directoryFile
        guard let raw = try? Data(contentsOf: distance) else { return nil }
        do {
            return try JSONDecoder().decode([DownloadItem].self, from: raw)
        } catch {
            let backup = distance.deletingPathExtension().appendingPathExtension("defekt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: distance, to: backup)
            AppLog.writeOut("[Download] Liste nicht lesbar (\(raw.count) Byte), beiseitegelegt: \(error)")
            return nil
        }
    }

    nonisolated private static func allWrite(_ ownOnes: [DownloadItem], account: String) {
        var all = allRead() ?? []
        all.removeAll { $0.account == account }
        all.append(contentsOf: ownOnes)
        guard let raw = try? JSONEncoder().encode(all) else { return }
        try? raw.write(to: directoryFile, options: .atomic)
    }

    /// Measure fresh when a selection opens: the device may have filled up since
    /// sign-in, and the footer calculates with this number.
    func spaceRefresh() { spaceMeasure() }

    private func spaceMeasure() {
        // **`…ForImportantUsage` does not exist on tvOS**, and that is not arbitrary:
        // an Apple TV has no user storage to report on, it cleans up by itself. That is
        // why there are no downloads there; this class is only compiled in because
        // `AppModel` is shared.
        //
        // The number also differs from plain free capacity: it includes what iOS
        // would purge for an important request, which is what a download actually
        // gets.
        #if os(tvOS)
        free = 0
        #else
        let values = try? Self.folder().resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        free = Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
        #endif
    }

    // MARK: Kicking off

    /// What a download would cost, for the sheet before starting.
    func inquiry(for bytes: Int64) -> DownloadRules.SpaceInfo {
        spaceMeasure()
        return DownloadRules.slot(for: bytes, free: free, available: entries)
    }

    /// Queue a title. Starts it when it is its turn.
    ///
    /// `poster` is the poster URL and is **downloaded along**. Without it the
    /// downloads page would have no images on a plane: the app's image cache lives
    /// in memory only, and the URLs point to a server that is not there. A poster
    /// is a few dozen kilobytes next to eighteen gigabytes.
    ///
    /// `images` maps ids to image URLs: the title's own, and for an episode also
    /// the series'. **Both are needed**: the list shows the poster for a series, the
    /// episode list below it each episode's landscape image, as elsewhere in the
    /// app. Saving only the series poster would show the same image three times in
    /// the episode list.
    func trigger(_ new: DownloadItem, images: [String: URL] = [:]) {
        trigger([new], images: images)
    }

    /// A whole season. One after another, not at once; the one-at-a-time rule ensures that by itself
    /// since only one runs at a time.
    func trigger(_ many: [DownloadItem], images: [String: URL] = [:]) {
        for p in many where !entries.contains(where: { $0.id == p.id }) {
            entries.append(p)
            if let own = images[p.id] { imageSafe(p.account, p.id, from: own) }
            if let sid = p.seriesIdentifier, let series = images[sid] {
                imageSafe(p.account, sid, from: series)
            }
            // The series' large header image, once per series; `imageSafe` does not
            // download what already exists.
            if let sid = p.seriesIdentifier, let header = images[Self.headerKey(sid)] {
                imageSafe(p.account, sid + "-kopf", from: header)
            }
        }
        secure()
        tick()
    }

    /// **Failed immediately?** The download sheet closes on tap, and a download that
    /// aborts right away (no URL from the server, no network) would show red only
    /// in Downloads, where nobody is looking. Waits briefly and returns the reason
    /// of the first failed one among the given titles, otherwise `nil`.
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
        folder().appendingPathComponent(DownloadItem.imageName(account: account, identifier: identifier))
    }

    /// The image on the device, or `nil`, then the row uses the server URL.
    /// **Offline there is only the disk**, and that is when this page is needed.
    ///
    /// `asGroup` asks for the series poster instead of the single episode's image.
    func image(for p: DownloadItem, asGroup: Bool = false) -> URL? {
        let identifier = asGroup ? (p.seriesIdentifier ?? p.id) : p.id
        let distance = Self.imageDistance(p.account, identifier)
        return FileManager.default.fileExists(atPath: distance.path) ? distance : nil
    }

    /// Under this key the series page hands the large header image to
    /// `trigger(_:images:)`.
    static func headerKey(_ seriesIdentifier: String) -> String { "kopf:" + seriesIdentifier }

    /// **The series' header image at screen resolution**, for the series page in
    /// Downloads. The poster and landscape images are sized for rows (300 and 220
    /// high) and looked stretched and soft there.
    func headerImage(series seriesIdentifier: String, account: String) -> URL? {
        let distance = Self.imageDistance(account, seriesIdentifier + "-kopf")
        return FileManager.default.fileExists(atPath: distance.path) ? distance : nil
    }

    /// For earlier downloads that lack it: fetch on the next open with network.
    /// Returns the path once it exists.
    func headerImageCatchUp(series seriesIdentifier: String, account: String, from address: URL) async -> URL? {
        let target = Self.imageDistance(account, seriesIdentifier + "-kopf")
        guard !FileManager.default.fileExists(atPath: target.path) else { return target }
        guard let (data, _) = try? await URLSession.shared.data(for: .withOwnHeaders(address)),
              data.count > 0, (try? data.write(to: target, options: .atomic)) != nil
        else { return nil }
        return target
    }

    private func imageSafe(_ account: String, _ identifier: String, from address: URL) {
        let target = Self.imageDistance(account, identifier)
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(for: .withOwnHeaders(address)),
                  data.count > 0 else { return }
            try? data.write(to: target, options: .atomic)
        }
    }

    /// **Pausing is not an error.**
    ///
    /// `URLSession` reports a cancellation as an error, the same callback that a
    /// network change or a crashed server triggers. Without telling them apart,
    /// `failed` cannot distinguish the three and sets `.error` as soon as the
    /// server gives no resume data. The ring then showed red instead of pause, and
    /// a second tap meant "retry" while the download kept going.
    ///
    /// **Via the generation.** Pausing advances it; the cancellation the session
    /// reports afterwards carries the old one and is ignored. A list of deliberately
    /// paused items did not help when the download was resumed between pause and
    /// report: the old cancellation then hit the new task.
    func halt(_ id: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let now = newGeneration(id)
        if let task = tasks[id] {
            task.cancel { [weak self] data in
                Task { @MainActor in
                    // Only as long as nobody restarted it since.
                    if let data, self?.generation[id] == now { self?.resumeData[id] = data }
                }
            }
            tasks[id] = nil
        }
        stateLet(i)
        entries[i].state = .halted
        secure()
        tick()
    }

    /// Like ``halt``, but the title waits afterwards: the network change
    /// stopped it, not the pause button. Resume data is kept.
    private func putBack(_ id: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let now = newGeneration(id)
        if let task = tasks[id] {
            task.cancel { [weak self] data in
                Task { @MainActor in
                    if let data, self?.generation[id] == now { self?.resumeData[id] = data }
                }
            }
            tasks[id] = nil
        }
        stateLet(i)
        entries[i].state = .waits
        secure()
    }

    /// Move the running state into the item and stop tracking it separately; the
    /// title is no longer downloading.
    private func stateLet(_ i: Int) {
        let id = entries[i].id
        entries[i] = current(entries[i])
        live[id] = nil
        reported[id] = nil
        reportedAround[id] = nil
    }

    func resume(_ id: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].state = .waits
        entries[i].reason = nil
        secure()
        tick()
    }

    func remove(_ id: String) {
        removeWithoutSafe(id)
        secure()
        spaceMeasure()
        tick()
    }

    private func removeWithoutSafe(_ id: String) {
        newGeneration(id)
        if let task = tasks[id] { task.cancel(); tasks[id] = nil }
        resumeData[id] = nil
        live[id] = nil
        reported[id] = nil
        reportedAround[id] = nil
        if let p = entries.first(where: { $0.id == id }) {
            let file = Self.folder().appendingPathComponent(p.fileName)
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: Self.subtitleFolder(to: file))
            // Its own image always goes.
            try? FileManager.default.removeItem(at: Self.imageDistance(p.account, p.id))
            // All episodes share the series poster; it goes with the last one. Otherwise
            // the second-to-last episode would be left without an image.
            if let sid = p.seriesIdentifier,
               !entries.contains(where: { $0.id != id && $0.seriesIdentifier == sid }) {
                try? FileManager.default.removeItem(at: Self.imageDistance(p.account, sid))
                try? FileManager.default.removeItem(at: Self.imageDistance(p.account, sid + "-kopf"))
            }
        }
        entries.removeAll { $0.id == id }
    }

    /// Several at once: measure once, tick once, not per title.
    func remove(_ ids: [String]) {
        for id in ids { removeWithoutSafe(id) }
        secure()
        spaceMeasure()
        tick()
    }

    /// Pause everything without deleting anything.
    ///
    /// This is what switching the toggle off does. What is on disk stays; what was
    /// running waits. Switch it on again and it continues where it stopped.
    func allHalt() {
        for p in entries where p.state == .loads || p.state == .waits {
            halt(p.id)
        }
    }

    /// The pause rule, the other answer: remove everything.
    func allRemove() {
        remove(entries.map(\.id))
    }

    // MARK: The tick

    /// **The single place where a download starts.**
    ///
    /// Called after every change: queued, paused, finished, network change, app
    /// start. So there is no second way into a running download, and
    /// `DownloadRules.nextOne` is the only decision about who is next.
    func tick() {
        guard !searchesTasks else { return }
        switch DownloadRules.networkVerdict(wLAN: networkRead ? wLAN : nil,
                                            onlyOverWLAN: onlyOverWLAN) {
        case .load:
            break
        case .waitFor:
            // The path monitor's first update is still pending. Start nothing and stop
            // nothing; it arrives within milliseconds.
            return
        case .putBack:
            // No Wi-Fi with Wi-Fi-only set: what runs goes back to the queue. Otherwise it
            // would continue over cellular although that is off. **Back to "waiting", not
            // paused:** nobody would pick a paused item up again on Wi-Fi.
            for p in entries where p.state == .loads { putBack(p.id) }
            return
        }
        guard let nextOne = DownloadRules.nextOne(
            from: entries, wLAN: wLAN, onlyOverWLAN: onlyOverWLAN) else { return }
        start(nextOne)
    }

    private func start(_ p: DownloadItem) {
        guard let client, let i = entries.firstIndex(where: { $0.id == p.id }) else { return }

        // **State is set before waiting, not after.** `JellyfinClient` is an actor, so
        // the URL only arrives after an `await`. If `.loads` were set after it, a
        // second `tick()` in between would see no running download and start the same
        // title again. The one-at-a-time rule depends on this.
        entries[i].state = .loads
        entries[i].reason = nil
        secure()
        let now = newGeneration(p.id)

        let resume = resumeData[p.id]
        resumeData[p.id] = nil
        // **A built file starts from scratch** (converted, or cut down to one audio
        // track). The server accepts no range requests for it (`Accept-Ranges: none`), so there is no resume data; what was
        // downloaded before no longer counts.
        if resume == nil, entries[i].streamed { entries[i].loaded = 0 }
        live[p.id] = DownloadProgress(loaded: entries[i].loaded, total: entries[i].bytes)

        Task { [weak self] in
            guard let address = try? await client.downloadURL(itemID: p.id,
                                                              mediaSourceID: p.source,
                                                              quality: p.guete,
                                                              audioStreamIndex: p.audioIndex) else {
                self?.failed(.init(id: p.id, generation: now, file: p.fileName),
                                        reason: String(localized: "Keine Adresse vom Server."),
                                        resume: nil)
                return
            }
            self?.taskStart(p, generation: now, address: address, resume: resume)
        }
    }

    private func taskStart(_ p: DownloadItem, generation now: Int,
                                address: URL, resume: Data?) {
        // In the meantime the item may have been removed or paused; then nothing starts
        // here. **And not twice:** whoever paused and resumed while waiting has a newer
        // generation whose own start arrives right here.
        guard generation[p.id] == now,
              entries.first(where: { $0.id == p.id })?.state == .loads else { return }
        let task = resume.map { session.downloadTask(withResumeData: $0) }
            // With the server's own headers (issue #4); without an entry the same request
            // as before. Resume data carries them.
            ?? session.downloadTask(with: .withOwnHeaders(address))
        // The file name travels with the task because the callback comes from the
        // system and cannot reach our list there.
        task.taskDescription = DownloadTask.description(id: p.id, generation: now,
                                                               file: p.fileName)
        tasks[p.id] = task
        task.resume()
    }

    // MARK: - Callbacks from the session

    /// Last published state per download; see `progress`.
    @ObservationIgnored private var reported: [String: Int64] = [:]
    /// When last published; the number should count, not jitter.
    @ObservationIgnored private var reportedAround: [String: Date] = [:]

    /// Whether a callback belongs to the title's current task.
    private func applies(_ t: DownloadTask.Parts) -> Bool {
        DownloadTask.applies(reported: t.generation, current: generation[t.id])
    }

    private func progress(_ t: DownloadTask.Parts, loaded: Int64, total: Int64) {
        guard applies(t) else { return }
        let id = t.id
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }

        // **Not every callback is a visible change.**
        //
        // `URLSession` reports progress at the pace of incoming packets, many times per
        // frame on a fast connection. Each update writes to `entries`, and because
        // `@Observable` tracks the **whole** list as one property, every view reading
        // anything from it redraws: in an episode list, every row with its ring. That
        // is the flicker.
        //
        // **Since 1.0.5 it no longer writes to `entries`**, but to the title's own
        // `DownloadProgress`; see `current`.
        //
        // Half a percent on a 28-point ring is about half a pixel of arc: nothing to
        // see below that, and the last step to full arrives via `abgeschlossen` anyway.
        //
        // **And at most once per second.** The half percent alone let five or more
        // numbers per second through on a fast connection, and the subline read like
        // jitter. The rule lives in the package.
        let now = Date()
        guard DownloadRules.progressShow(
            loaded: loaded, total: total > 0 ? total : entries[i].bytes,
            before: reported[id],
            elapsed: reportedAround[id].map { now.timeIntervalSince($0) })
        else { return }
        reported[id] = loaded
        reportedAround[id] = now

        // If the server gives no size in the catalog, the bar takes the one from the
        // response. **Not saved:** that would be a write per progress update; see
        // `DownloadState`.
        let newTotal = entries[i].bytes == 0 && total > 0 ? total : entries[i].bytes
        if let f = live[id] {
            f.loaded = loaded
            if f.total != newTotal { f.total = newTotal }
        } else {
            live[id] = DownloadProgress(loaded: loaded, total: newTotal)
        }
    }

    private func completed(_ t: DownloadTask.Parts, worked: Bool) {
        guard applies(t) else { return }
        let id = t.id
        tasks[id] = nil
        guard let i = entries.firstIndex(where: { $0.id == id }) else {
            live[id] = nil; reported[id] = nil; reportedAround[id] = nil
            return
        }
        stateLet(i)
        if worked {
            entries[i].state = .done
            // **The estimate yields to the real size** once the transcoded file exists,
            // otherwise usage would keep counting a calculated number.
            if entries[i].streamed,
               let real = try? Self.folder().appendingPathComponent(entries[i].fileName)
                   .resourceValues(forKeys: [.fileSizeKey]).fileSize, real > 0 {
                entries[i].bytes = Int64(real)
            }
            entries[i].loaded = entries[i].bytes
            subtitleFetch(entries[i])
            sectionsFetch(entries[i].id)
            // **The watched episode goes only now**, with its successor safely on the
            // device. Never before: a failed download must not leave a gap.
            let replaced = nextAuto ? DownloadRules.replacedOne(by: entries[i], in: entries) : nil
            entries[i].replaces = nil
            if let replaced { removeWithoutSafe(replaced) }
        } else {
            entries[i].state = .error
            entries[i].reason = String(localized: "Die Datei liess sich nicht ablegen.")
        }
        secure()
        spaceMeasure()
        tick()
    }

    private func failed(_ t: DownloadTask.Parts, reason: String, resume: Data?) {
        // **Whoever paused does not see an error.**
        //
        // The cancellation arrives here as an error because `URLSession` reports it
        // that way. Whether it came from the pause button or a dropped network is not
        // in the report, but the generation is: pausing advanced it, and the report
        // carries the old one. Without this, a halt without resume data stayed as
        // `.error`, the ring turned red and the next tap said "retry" instead of
        // "resume".
        guard applies(t) else { return }
        let id = t.id
        tasks[id] = nil
        if let resume { resumeData[id] = resume }
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        stateLet(i)

        // A cancelled download with resume data is not an error but a pause, usually
        // a network change. Shown as an error, it would put a red mark where only the
        // subway was to blame.
        entries[i].state = resume != nil ? .halted : .error
        entries[i].reason = resume != nil ? nil : reason
        secure()
        tick()
    }

    // MARK: Network

    /// Whether Wi-Fi is currently available.
    private(set) var wLAN = true
    /// No connection at all. **The day this feature is built for**: the page then
    /// switches its header.
    private(set) var noNetwork = false
    /// Whether the path monitor has reported yet. Before that, ``wLAN`` is only
    /// the default and the tick waits.
    @ObservationIgnored private var networkRead = false

    /// **`NWPathMonitor`, rather than guessing.**
    ///
    /// Without a monitor `wLAN` would stay `true` permanently, so the mobile-data rule would do
    /// nothing: the "Wi-Fi only" toggle would be a line without effect, which is
    /// worse than no line. (The continuous load seen on Linux came from an open
    /// `URLSessionWebSocketTask`, not from a path monitor.)
    ///
    /// It runs only while the feature is switched on.
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
    }

    #if DEBUG
    /// Self-test without network (`OfflineRun`): same effect as the path monitor,
    /// without touching the computer's network.
    func simulateNetwork(distance: Bool) { networkStatus(wLAN: !distance, noNetwork: distance) }
    #endif

    private func networkStatus(wLAN wlan: Bool, noNetwork distance: Bool) {
        let first = !networkRead
        networkRead = true
        guard first || wlan != wLAN || distance != noNetwork else { return }
        wLAN = wlan
        noNetwork = distance
        AppLog.writeOut("[Download] Netz: \(distance ? "keins" : wlan ? "WLAN" : "Mobilfunk")")
        // The tick stops or continues, depending on what applies now.
        tick()
    }

    // MARK: the title has disappeared from the server

    /// Sets the hint without touching the file.
    ///
    /// **Two-way.** Before, only the downward path existed; a title that a server
    /// sweep picked up again would have kept the hint forever.
    func onServer(_ id: String, _ an: Bool) {
        guard let i = entries.firstIndex(where: { $0.id == id }),
              entries[i].stillOnTheServer != an else { return }
        entries[i].stillOnTheServer = an
        secure()
    }

    /// Pull in what the server says about watched state, so the expendable-titles rule knows what is
    /// watched and the list shows the same offline as online. A newer local state
    /// stays (``Downloadregeln/nachziehen(_:sehstand:)``).
    private func watchState(_ id: String, _ state: UserItemData?) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let new = DownloadRules.follow(entries[i], watchState: state)
        guard new != entries[i] else { return }
        entries[i] = new
        secure()
    }

    /// **Pull in what the server says in one go: the expendable-titles rule and H9.**
    ///
    /// The setters above existed without anyone calling them. That was not
    /// harmless, only invisible: `DownloadRules.dispensable` filters on `watched`
    /// and therefore **always** returned an empty list, so the way out that the expendable-titles rule
    /// offers when space runs short never appeared. And `stillOnTheServer` stayed
    /// true although both download pages already draw the hint for it.
    ///
    /// What comes in here is explicitly **answered**, not queried: someone offline
    /// gets no answer, and then "no longer on the server" would be the wrong
    /// verdict for every title. The caller keeps those apart.
    func follow(available: Set<String>, watchState: [String: UserItemData]) {
        for id in entries.map(\.id) {
            if available.contains(id) { self.watchState(id, watchState[id]) }
            onServer(id, available.contains(id))
        }
        smartCatchUp()
    }
}

/// The messenger between the background session and the main thread.
///
/// **Deliberately not `@MainActor`.** The callbacks come from the session's
/// queue, a foreign thread. A `@MainActor` class whose methods are called from
/// there aborts under Swift 6 with only "terminated due to signal 5" in the log
/// and no cause shown. That is how it went wrong on the lock screen. So this
/// delegate hops each callback individually.
final class DownloadReporter: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    struct ReadyMessage { let temp: URL; let name: String }

    typealias Parts = DownloadTask.Parts
    private let onProgress: @Sendable (Parts, Int64, Int64) -> Void
    private let onDone: @Sendable (Parts, ReadyMessage) -> Void
    private let onError: @Sendable (Parts, String, Data?) -> Void

    init(progress: @escaping @Sendable (Parts, Int64, Int64) -> Void,
         done: @escaping @Sendable (Parts, ReadyMessage) -> Void,
         failed: @escaping @Sendable (Parts, String, Data?) -> Void) {
        self.onProgress = progress
        self.onDone = done
        self.onError = failed
    }

    /// Id, generation and file name: everything hangs on the task because the
    /// callback cannot reach our list.
    private func parts(_ task: URLSessionTask) -> Parts? {
        DownloadTask.dismantle(task.taskDescription)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let t = parts(downloadTask) else { return }
        onProgress(t, totalBytesWritten, max(0, totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let t = parts(downloadTask) else { return }
        // **A status code is not success.** Jellyfin answers an expired login with 401
        // and a body, and that landed here as a "finished file" of 40 bytes.
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // The sentence comes from `readableError`, not from the code: otherwise
            // "HTTP 401" would appear literally on screen.
            onError(t, readableError(JellyfinError.http(status: http.statusCode, body: nil)), nil)
            return
        }
        onDone(t, ReadyMessage(temp: location, name: t.file))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error as NSError?, let t = parts(task) else { return }
        let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        onError(t, readableError(error), data)
    }
}

/// **A title's progress, observable on its own.**
///
/// A separate class per title so an update redraws only the views that read
/// exactly this title. While it was a number in `DownloadManager.entries`,
/// every update changed the whole list.
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
