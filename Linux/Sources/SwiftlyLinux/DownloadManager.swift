import Foundation
import JellyfinKit
import CGtk

// On Apple `URLSession` lives in Foundation; here it is in FoundationNetworking.
// The package has the same conditional import for the same reason.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// **Downloads on Linux and Windows.**
///
/// The rules are not here. Which item loads next, whether there is enough
/// space, what is expendable and how the list is grouped live in
/// `DownloadRules` in the package and are identical on all six platforms.
/// This file only handles how the bytes arrive.
///
/// **They arrive differently than on Apple.** There `URLSessionConfiguration.background`
/// keeps a transfer going while the app is not in the foreground. Linux and Windows
/// have no such thing, but also lack the problem it solves: nobody kills the app
/// for going to the background, and a hidden window keeps running.
///
/// So a plain session with a **data task** is used, not `downloadTask`:
///
/// - `downloadTask` only puts the file in place at the end. An abort at 90 % loses
///   everything, and swift-corelibs-foundation does not reliably support the
///   `resumeData` Apple uses to solve that.
/// - A data task hands over every chunk immediately. Each chunk is appended to the
///   file, so the progress is always known (it is also kept in `DownloadItem.loaded`).
/// - Resuming therefore uses `Range: bytes=N-`, plain HTTP instead of an opaque resume
///   blob. Jellyfin answers with `206`; a `200` means the range request was ignored
///   and the file starts over. That case is detected instead of silently appending
///   the wrong data.
///
/// **One download at a time**, as everywhere else: `DownloadRules.nextOne` decides,
/// and `tick()` is the only place that starts anything.
final class DownloadManager: NSObject, @unchecked Sendable {

    /// Called on the main thread after every change. The UI hangs off this;
    /// the manager knows no widgets.
    var change: (() -> Void)?

    private(set) var entries: [DownloadItem] = []

    private var client: JellyfinClient?
    private var account: String?

    private var session: URLSession!
    private var job: URLSessionDataTask?
    /// ID of the item that is currently loading. Not derived from `entries`:
    /// the callback arrives on a foreign thread and needs an answer that does
    /// not change underneath it.
    private var ongoing: String?
    private var target: FileHandle?
    private var targetPath: URL?
    /// **The file belongs to the task that writes it, and only to that task.**
    ///
    /// `target` is closed on the main thread (pause, remove, completion) but written on
    /// the session's queue. Without a lock a late chunk would write into a just-closed
    /// file, and after a pause followed immediately by the next download even into the
    /// **next** title's file. Task and file are kept together here; a callback whose
    /// task is no longer the current one writes nothing.
    private let writeLock = NSLock()
    private var writeJob: URLSessionTask?
    private var writeTarget: FileHandle?
    private var writeBefore: Int64 = 0
    /// How much was already there at the start of this attempt. Progress counts
    /// from it, otherwise the bar would restart at zero when resuming.
    private var before: Int64 = 0
    private var lastSafe = Date.distantPast

    /// The mobile-data rule does not apply here: a desktop has no mobile network, and the app cannot
    /// know what a USB modem costs. The rule is still consulted so that there is
    /// **one** place for it.
    /// **There is something to measure after all.**
    ///
    /// This used to hardcode `wLAN = true` and `onlyOverWLAN = false` on the grounds that
    /// a desktop is never on a mobile connection. The setting was shown and saved, but
    /// nothing read it. A control that promises an effect it does not have is worse
    /// than none.
    ///
    /// GLib answers exactly this question: `g_network_monitor_get_network_metered`
    /// says whether the connection is metered (mobile data with NetworkManager, or
    /// a Wi-Fi marked as metered).
    ///
    /// **This is stricter than macOS, which is a known difference.**
    /// There it checks `path.usesInterfaceType(.wifi) || .wiredEthernet`
    /// (`Sources/Shared/DownloadManager.swift`), the interface type rather than
    /// metering. A phone hotspot counts as Wi-Fi on the Mac and downloads despite the
    /// setting; here it waits. GLib does not know the interface type, and
    /// `NWPathMonitor.isExpensive` would be the Apple equivalent of what is measured
    /// here, but it is not called anywhere. **Open decision:** either the Mac also
    /// checks `isExpensive`, or this line reverts to "always Wi-Fi". Until then Linux
    /// does what the mobile-data rule says and the Mac is more permissive.
    /// Not private: the download sheet asks it before labelling the button.
    var wLAN: Bool {
        guard let guards = g_network_monitor_get_default() else { return true }
        return g_network_monitor_get_network_metered(guards) == 0
    }
    var onlyOverWLAN: Bool { Choices.read().onlyOverWLAN }

    override init() {
        super.init()
        let k = URLSessionConfiguration.default
        // A download may take long; a server that says nothing at all must not.
        k.timeoutIntervalForRequest = 60
        k.timeoutIntervalForResource = 60 * 60 * 24
        session = URLSession(configuration: k, delegate: self, delegateQueue: nil)
        // **Nothing is loaded here.** Which titles apply depends on the account,
        // which is not known at startup; `anmelden(client:account:)` loads.
        cleanUpAfterCrash()
    }

    // MARK: Account

    func signIn(client: JellyfinClient?, account: String?) {
        self.client = client
        self.account = account
        load()
        tick()
    }

    /// **A download belongs to its account**.
    ///
    /// The list on disk holds the titles of **all** accounts; only the current
    /// account's are shown. Reading the unfiltered `Cache.downloadsRead()` in
    /// `init` made two accounts on one device see the same titles and the same
    /// progress, exactly the harm the per-account rule describes (same lesson as `SeriesCache`).
    ///
    /// **Nothing is deleted here.** The other account gets its titles back when it
    /// signs in.
    private func load() {
        let all = Cache.downloadsRead()
        guard let account else { entries = []; foreignOnes = all; return }
        entries = all.filter { $0.account == account }
        foreignOnes = all.filter { $0.account != account }
        // Whatever was mid-download last time waits again.
        for i in entries.indices where entries[i].state == .loads {
            entries[i].state = .waits
        }
    }

    /// **Whatever was mid-download last time waits again.**
    ///
    /// `.loads` on disk means the app went away while something was running. If it
    /// stayed, `DownloadRules.nextOne` would treat it as a running download and
    /// never start anything again, so the one-at-a-time rule would work against itself.
    private func cleanUpAfterCrash() {
        var changed = false
        for i in entries.indices where entries[i].state == .loads {
            entries[i].state = .waits
            changed = true
        }
        if changed { secure() }
    }

    // MARK: Storage

    func file(for id: String) -> URL? {
        guard let p = entries.first(where: { $0.id == id }), p.state == .done else { return nil }
        let path = Cache.downloadFolder.appendingPathComponent(p.fileName)
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    func entries(for id: String) -> DownloadItem? {
        entries.first { $0.id == id }
    }

    /// **Foreign items are kept**. Writing only the own list would delete the
    /// other account's titles from disk while their files stay behind with nobody
    /// knowing who owns them.
    ///
    /// **Read once at sign-in, not on every save.** `Cache.downloadsRead()` here
    /// meant reading the whole list from disk once per second during a download just to
    /// write back the other accounts' items. Nobody else changes them: only this manager
    /// writes the file, and the app runs only once.
    private func secure() {
        // Before the first sign-in nothing is remembered, so read from disk as before;
        // otherwise the titles of all accounts would be lost.
        let mine = account
        let other = foreignOnes ?? Cache.downloadsRead().filter { $0.account != mine }
        Cache.downloadsWrite(other + entries)
        report()
    }

    /// The other accounts' items, as read at sign-in.
    private var foreignOnes: [DownloadItem]?

    /// **The callback is read on the main thread, not captured.** Capturing it here and
    /// calling it over there would pass a function across a thread boundary that is not
    /// declared safe, and the compiler rightly rejects that. Read via `self`, the value
    /// at the time of drawing applies.
    private func report() {
        onMainThread { [weak self] in self?.change?() }
    }

    // MARK: Space

    /// Free space on disk, in bytes.
    ///
    /// `FileManager` answers this the same way on all three systems.
    /// `volumeAvailableCapacityForImportantUsageKey` exists only on Apple, hence the
    /// simpler key. If nothing answers, the space is unknown, not "zero": a zero here
    /// would mean nothing may be downloaded anymore.
    var freeSpace: Int64 {
        let values = try? Cache.downloadFolder
            .resourceValues(forKeys: [.volumeAvailableCapacityKey])
        if let free = values?.volumeAvailableCapacity { return Int64(free) }
        let homeBase = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(homeBase?.volumeAvailableCapacity ?? Int.max)
    }

    func inquiry(for bytes: Int64) -> DownloadRules.SpaceInfo {
        DownloadRules.slot(for: bytes, free: freeSpace, available: entries)
    }

    // MARK: Kick-off

    func trigger(_ new: DownloadItem, images: [String: URL] = [:]) {
        trigger([new], images: images)
    }

    func trigger(_ many: [DownloadItem], images: [String: URL] = [:]) {
        for n in many where !entries.contains(where: { $0.id == n.id }) {
            entries.append(n)
            if let address = images[n.id] { imageSafe(n.account, n.id, from: address) }
            if let sid = n.seriesIdentifier, let address = images[sid] {
                imageSafe(n.account, sid, from: address)
            }
        }
        secure()
        tick()
    }

    // MARK: Images

    private static func imageDistance(_ account: String, _ identifier: String) -> URL {
        Cache.downloadFolder.appendingPathComponent(DownloadItem.imageName(account: account, identifier: identifier))
    }

    /// The image on disk, or `nil` (then the symbol stays).
    ///
    /// **Without network only the disk exists**, and that is exactly when this page is
    /// needed. A poster fetched from the server would be missing in the one case
    /// downloads are for. Same reasoning as `DownloadManager.image(fuer:)` on Apple.
    func image(for p: DownloadItem, asGroup: Bool = false) -> URL? {
        let identifier = asGroup ? (p.seriesIdentifier ?? p.id) : p.id
        let distance = Self.imageDistance(p.account, identifier)
        return FileManager.default.fileExists(atPath: distance.path) ? distance : nil
    }

    /// **The series header image at window resolution**, for the page of a downloaded
    /// series (`DownloadManager.headerImage` on Apple). The poster and landscape images
    /// are sized for rows and would look stretched and soft there.
    func headerImage(series seriesIdentifier: String, account: String) -> URL? {
        let distance = Self.imageDistance(account, seriesIdentifier + "-kopf")
        return FileManager.default.fileExists(atPath: distance.path) ? distance : nil
    }

    /// **Comes along with the first download of a series**: header image and poster,
    /// once each; what is already there is not fetched again. The download selection
    /// passes both in as soon as it kicks off episodes.
    func seriesImageSafe(series seriesIdentifier: String, account: String,
                             header: URL?, poster: URL?) {
        if let header { imageSafe(account, seriesIdentifier + "-kopf", from: header) }
        if let poster { imageSafe(account, seriesIdentifier, from: poster) }
    }

    /// For earlier downloads that do not have it yet: fetch on the next open with
    /// network. Returns the path once it exists; without network it fails silently.
    func headerImageCatchUp(series seriesIdentifier: String, account: String,
                           from address: URL) async -> URL? {
        let target = Self.imageDistance(account, seriesIdentifier + "-kopf")
        guard !FileManager.default.fileExists(atPath: target.path) else { return target }
        try? FileManager.default.createDirectory(at: Cache.downloadFolder,
                                                 withIntermediateDirectories: true)
        guard let (data, _) = try? await URLSession.shared.data(for: .withOwnHeaders(address)),
              !data.isEmpty, (try? data.write(to: target, options: .atomic)) != nil
        else { return nil }
        return target
    }

    private func imageSafe(_ account: String, _ identifier: String, from address: URL) {
        let target = Self.imageDistance(account, identifier)
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        try? FileManager.default.createDirectory(at: Cache.downloadFolder,
                                                 withIntermediateDirectories: true)
        Task {
            guard let (data, _) = try? await URLSession.shared.data(for: .withOwnHeaders(address)),
                  !data.isEmpty else { return }
            try? data.write(to: target, options: .atomic)
            self.report()
        }
    }

    // MARK: Pause, resume, remove

    func halt(_ id: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        if ongoing == id { cancel() }
        entries[i].state = .halted
        secure()
        tick()
    }

    func resume(_ id: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].state = .waits
        entries[i].reason = nil
        secure()
        tick()
    }

    func remove(_ id: String) {
        remove([id])
    }

    func remove(_ ids: [String]) {
        let distance = Set(ids)
        if let ongoing, distance.contains(ongoing) { cancel() }
        for p in entries where distance.contains(p.id) {
            try? FileManager.default.removeItem(
                at: Cache.downloadFolder.appendingPathComponent(p.fileName))
            // The image belongs to the item. If it stayed, the folder would collect
            // posters for titles that no longer exist here.
            try? FileManager.default.removeItem(at: Self.imageDistance(p.account, p.id))
            // **All episodes share the series poster**, so it goes only with the last one,
            // otherwise the second-to-last would be left without an image. Here it never
            // went: the file stayed in the folder forever for any series ever downloaded.
            // The Mac checks at the same place (`Sources/Shared/DownloadManager.swift`).
            if let sid = p.seriesIdentifier,
               !entries.contains(where: { !distance.contains($0.id) && $0.seriesIdentifier == sid }) {
                try? FileManager.default.removeItem(at: Self.imageDistance(p.account, sid))
                try? FileManager.default.removeItem(at: Self.imageDistance(p.account, sid + "-kopf"))
            }
        }
        entries.removeAll { distance.contains($0.id) }
        secure()
        tick()
    }

    func allHalt() {
        cancel()
        for i in entries.indices where entries[i].state == .loads || entries[i].state == .waits {
            entries[i].state = .halted
        }
        secure()
    }

    func allRemove() {
        remove(entries.map(\.id))
    }

    /// the server no longer knows the title. The file stays.
    func notMoreServer(_ id: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }),
              entries[i].stillOnTheServer else { return }
        entries[i].stillOnTheServer = false
        secure()
    }

    /// Pull in what the server says about watch state, so the expendable-titles rule knows what is watched
    /// and the list shows the same offline as online. A newer local state is kept
    /// (``Downloadregeln/nachziehen(_:sehstand:)``).
    private func watchState(_ id: String, _ state: UserItemData?) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let new = DownloadRules.follow(entries[i], watchState: state)
        guard new != entries[i] else { return }
        entries[i] = new
        secure()
    }

    // MARK: Watch state on the device

    /// **Record a playback, even offline.** The list then shows the check mark as soon
    /// as an episode finishes without a server, and starts at the remembered position.
    /// The thresholds are the server's (``Downloadposten/postPlayback(ticks:wann:)``).
    /// Only on GTK's thread.
    func playbackRemember(_ id: String, ticks: Int64, moment: Date = Date()) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i] = entries[i].postPlayback(ticks: ticks, moment: moment)
        secure()
    }

    // MARK: Segments for offline

    /// **Take intro and credits along** once the file is there, otherwise there is
    /// neither "Skip intro" nor the "Next episode" card without a server. No answer
    /// (`nil`) leaves the field empty, and ``sectionsCatchUp()`` asks again on the
    /// next contact.
    private func sectionsFetch(_ id: String) {
        guard let client else { return }
        Task.detached { [self] in
            guard let parts = await client.segmentsToStore(for: id) else { return }
            onMainThread {
                guard let i = self.entries.firstIndex(where: { $0.id == id }) else { return }
                self.entries[i].sections = parts
                self.secure()
                AppLog.writeOut("[Download] Abschnitte fuer \(id): \(parts.count)")
            }
        }
    }

    /// For everything downloaded before 1.0.5 or that got no answer while downloading.
    /// Runs only with a server (``nachziehen()``).
    private func sectionsCatchUp() {
        for p in entries where p.state == .done && p.sections == nil {
            sectionsFetch(p.id)
        }
    }

    /// **What the server says in the meantime** (the expendable-titles rule and the missing-title rule).
    ///
    /// `notMoreServer` and `watched` existed here, but **nothing called
    /// them**: both stayed at the state of download time. The expendable-titles rule ("which titles are
    /// expendable") thus always worked on old data, and the quiet notice of the missing-title rule never
    /// appeared. On Apple the same sync runs as `AppModel.downloadsCatchUp`
    /// whenever the main view appears.
    ///
    /// **One hundred IDs per request**, the same size the library pages use. With ten
    /// downloads that is one request.
    func follow() {
        guard let client, !entries.isEmpty else { return }
        let ids = entries.map(\.id)
        let account = account ?? ""
        Task.detached { [self] in
            // **Report first, then read.** Otherwise the server's list returns the state from
            // before the offline period, and the check mark of an episode watched offline
            // would vanish until the report has gone through.
            await PostReportSlip.submit(client, account: account)
            var available: Set<String> = []
            var watchStates: [String: UserItemData] = [:]
            for since in stride(from: 0, to: ids.count, by: 100) {
                let piece = Array(ids[since ..< min(since + 100, ids.count)])
                guard let answer = try? await client.items(limit: piece.count, ids: piece)
                else { return }
                for title in answer.items {
                    available.insert(title.id)
                    watchStates[title.id] = title.userData
                }
            }
            let present = available, state = watchStates
            onMainThread {
                for id in self.entries.map(\.id) {
                    if present.contains(id) { self.watchState(id, state[id]) }
                    // **What comes back exists; what is missing is gone.**
                    if !present.contains(id) { self.notMoreServer(id) }
                }
                self.sectionsCatchUp()
            }
        }
    }

    // MARK: The tick

    /// The **only** place that starts a download.
    func tick() {
        guard ongoing == nil else { return }
        guard let nextOne = DownloadRules.nextOne(from: entries, wLAN: wLAN,
                                                       onlyOverWLAN: onlyOverWLAN)
        else { return }
        start(nextOne)
    }

    private func start(_ p: DownloadItem) {
        guard let client, let i = entries.firstIndex(where: { $0.id == p.id }) else { return }

        // **The state is set before waiting, not after.** The URL only arrives after an
        // `await`; if `.loads` were set after it, a second `tick()` in between would see
        // no running download and start the same title again. The one-at-a-time rule depends on this.
        // Apple has the same paragraph.
        entries[i].state = .loads
        entries[i].reason = nil
        ongoing = p.id
        secure()

        // **Back to the main thread, and only if it is still the current one.**
        //
        // This used to be a bare `Task {}`: the class is not main-actor, so the rest ran on
        // the thread pool, `entries` was changed from there and `report()` built GTK rows
        // off GTK's thread. And anyone pausing during the wait got the next title
        // aborted: `failed` saw the paused item and called `cancel()` on the
        // download that had meanwhile started.
        Task.detached { [self] in
            let address = try? await client.downloadURL(itemID: p.id,
                                                        mediaSourceID: p.source,
                                                        quality: p.guete)
            onMainThread {
                guard self.ongoing == p.id else { return }
                guard let address else {
                    self.failed(p.id, reason: translated("Keine Adresse vom Server."))
                    return
                }
                self.jobStart(p, address: address)
            }
        }
    }

    private func jobStart(_ p: DownloadItem, address: URL) {
        // The item may have been removed or paused in the meantime; then nothing
        // starts here.
        guard entries.first(where: { $0.id == p.id })?.state == .loads else { return }

        let folder = Cache.downloadFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent(p.fileName)

        // What is already on disk counts, not what the list says. The list can be
        // older than the file if the app was gone while writing.
        before = (try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? Int64) ?? 0
        // **A converted file starts from the beginning.** The server does not accept
        // range requests for it (`Accept-Ranges: none`); what was there before no
        // longer applies.
        if p.converted, before > 0 {
            try? FileManager.default.removeItem(at: path)
            before = 0
        }

        var petition = URLRequest.withOwnHeaders(address)
        if before > 0 { petition.setValue("bytes=\(before)-", forHTTPHeaderField: "Range") }

        if !FileManager.default.fileExists(atPath: path.path) {
            FileManager.default.createFile(atPath: path.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: path) else {
            failed(p.id, reason: translated("Die Datei ließ sich nicht anlegen."))
            return
        }
        try? handle.seekToEnd()
        target = handle
        targetPath = path

        let a = session.dataTask(with: petition)
        job = a
        writeLock.lock()
        writeJob = a
        writeTarget = handle
        writeBefore = before
        writeLock.unlock()
        a.resume()
    }

    /// Cancels what is running without setting the state. Whoever cancels says
    /// what applies afterwards.
    /// Is this the task that is currently running? Main thread only.
    fileprivate func isRunning(_ identifier: ObjectIdentifier) -> Bool {
        job.map(ObjectIdentifier.init) == identifier
    }

    private func cancel() {
        job?.cancel()
        job = nil
        writeLock.lock()
        writeJob = nil
        writeTarget = nil
        writeLock.unlock()
        try? target?.close()
        target = nil
        targetPath = nil
        ongoing = nil
    }

    // MARK: Callbacks from the session

    /// Last reported state per download, see ``progress(_:)``.
    private var reported: [String: Int64] = [:]
    private var reportedAround: [String: Date] = [:]

    private func progress(_ loaded: Int64) {
        guard let id = ongoing, let i = entries.firstIndex(where: { $0.id == id }) else { return }

        // **Not every callback is a visible change.**
        //
        // It arrives at the pace of incoming packets, many times per frame on a fast
        // connection, and `report()` redraws the rows and ring that depend on it. That
        // caused flicker, which was fixed on Apple earlier
        // (`Sources/Shared/DownloadManager.swift`).
        //
        // Half a percent is about half a pixel of arc on a small ring; below that there is
        // nothing to see, and the last step to full comes via completion anyway.
        //
        // **At most once per second.** The half-percent limit alone let several values per
        // second through on a fast connection, each rebuilding the list. In between the row
        // keeps counting itself (`ProgressEstimator`). The rule lives in the package.
        let now = Date()
        guard DownloadRules.progressShow(
            loaded: loaded, total: entries[i].bytes, before: reported[id],
            elapsed: reportedAround[id].map { now.timeIntervalSince($0) })
        else { return }
        reported[id] = loaded
        reportedAround[id] = now

        entries[i].loaded = loaded

        // **Not to disk on every chunk.** Progress changes several times per second;
        // saving each change would keep the disk busy for a number that is stale again
        // immediately. Once per second is enough, and pausing saves it anyway.
        if now.timeIntervalSince(lastSafe) > 1 {
            lastSafe = now
            secure()
        }
        report()
    }

    private func completed(_ id: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].state = .done
        entries[i].reason = nil
        // The size the server stated may have been wrong. What is actually there counts.
        if let path = targetPath,
           let size = try? FileManager.default
               .attributesOfItem(atPath: path.path)[.size] as? Int64 {
            entries[i].loaded = size
            // When converted, the estimate differs from the real size.
            if entries[i].converted { entries[i].bytes = size }
        }
        sectionsFetch(id)
        cancel()
        secure()
        tick()
    }

    private func failed(_ id: String, reason: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else {
            cancel(); tick(); return
        }
        // **A cancel is not an error.** `cancel()` reports back as an error, the same
        // callback as a dropped network. A manual pause should not show a red message.
        if entries[i].state == .halted {
            cancel(); tick(); return
        }
        entries[i].state = .error
        entries[i].reason = reason
        cancel()
        secure()
        tick()
    }
}

// MARK: - The thread the bytes arrive on

/// **Everything else runs on the main thread.**
///
/// The callbacks come from the session's queue. Touching `entries` from there would
/// let the main thread see a list changing under it, and GTK would draw from a list
/// being rebuilt. So every callback goes through ``onMainThread``; only writing to
/// the file stays here, since nobody else needs it.
extension DownloadManager: URLSessionDataDelegate {

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let identifier = ObjectIdentifier(dataTask)
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.allow); return
        }
        // **A range request answered with 200 is not one.** The server then sends from the
        // start. Appending would put the same beginning into the file a second time and
        // silently corrupt it. So write from the start.
        //
        // **Here, not on the main thread.** Truncating used to go through `onMainThread`,
        // i.e. at some later time, while the first chunks were already written past the old
        // state. The main thread then truncated the file from under them.
        writeLock.lock()
        if dataTask === writeJob, writeBefore > 0, http.statusCode == 200 {
            try? writeTarget?.truncate(atOffset: 0)
            try? writeTarget?.seek(toOffset: 0)
            writeBefore = 0
            onMainThread { [weak self] in self?.before = 0 }
        }
        writeLock.unlock()
        if http.statusCode >= 400 {
            let code = http.statusCode
            onMainThread { [weak self] in
                guard let self, self.isRunning(identifier), let id = self.ongoing else { return }
                self.failed(id, reason: String(format: translated("Der Server antwortete mit %d."), code))
            }
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let identifier = ObjectIdentifier(dataTask)
        writeLock.lock()
        guard dataTask === writeJob, let target = writeTarget else {
            writeLock.unlock()
            return
        }
        let state: Int64
        do {
            try target.write(contentsOf: data)
            state = (try? target.offset()).map(Int64.init) ?? 0
            writeLock.unlock()
        } catch {
            writeLock.unlock()
            let text = readableError(error)
            onMainThread { [weak self] in
                guard let self, self.isRunning(identifier), let id = self.ongoing else { return }
                self.failed(id, reason: text)
            }
            dataTask.cancel()
            return
        }
        onMainThread { [weak self] in
            guard let self, self.isRunning(identifier) else { return }
            self.progress(state)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let text = error.map(readableError)
        let identifier = ObjectIdentifier(task)
        // **Only the own task.** A paused one reports its end as "cancelled" late; by
        // then the next title was often already running and would show an error it never had.
        onMainThread { [weak self] in
            guard let self, self.isRunning(identifier), let id = self.ongoing else { return }
            if let text {
                self.failed(id, reason: text)
            } else {
                self.completed(id)
            }
        }
    }
}
