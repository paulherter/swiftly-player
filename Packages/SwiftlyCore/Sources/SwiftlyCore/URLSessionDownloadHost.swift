import Foundation

/// Where the downloads live on this device. **Exactly the places the Swift download manager used**
/// (`Application Support/Downloads`, the list file `liste.json`, `<file>.untertitel`, image names), so
/// downloads made by an older build keep working and the older build still reads what this one writes.
public enum DownloadFiles {
    /// Background session identifier. **Fixed and unique:** the system matches running transfers by it,
    /// and a new identifier would mean a restarted app no longer finds its running downloads.
    public static let sessionId = "de.paulherter.swiftly.downloads"

    /// The downloads folder; made when missing and **excluded from backup** (on the folder, not on each
    /// file, so a future file cannot forget it).
    public static func folder() -> URL {
        let files = FileManager.default
        let base =
            (try? files.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL.temporaryDirectory
        var folder = base.appendingPathComponent("Downloads", isDirectory: true)
        if !files.fileExists(atPath: folder.path) {
            try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        return folder
    }

    /// The folder of external subtitles of a media file. A separate folder, not next to the file: VLC loads
    /// subtitles named like the file by itself, so the same track would show twice.
    public static func subtitleFolder(to file: URL) -> URL {
        file.deletingLastPathComponent()
            .appendingPathComponent(file.lastPathComponent + ".untertitel", isDirectory: true)
    }

    /// Free space as the system would grant it to an important request (includes what it could purge).
    /// `0` on tvOS, which has no user storage and no downloads.
    public static func freeSpace() -> Int64 {
        #if os(tvOS)
        return 0
        #else
        let values = try? folder().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
        #endif
    }
}

/// What went wrong with a transfer; the app turns it into the sentence the user reads.
public enum DownloadFailure: Sendable {
    /// The server answered with a status that is not a success (an expired login gives 401 and a body).
    case http(status: Int)
    case error(any Error)
}

/// The server-bound work of the host (everything that needs the signed-in client). The transfer layer
/// itself knows no server.
public struct DownloadHostHooks: Sendable {
    /// The file address for a title (`id`, media source, quality name, audio stream index).
    public var address: @Sendable (_ id: String, _ source: String?, _ quality: String, _ audioIndex: Int?) async throws -> URL
    /// Fetch the external subtitle files of a finished title next to its media file.
    public var subtitles: @Sendable (_ id: String, _ source: String?) async -> Bool
    /// The intro/credits sections of a finished title; `nil` when the server gave no answer.
    public var sections: @Sendable (_ id: String) async -> [PlayerSection]?
    /// The episodes of a series as the server's `Items` JSON and the landscape image address of the
    /// episode after `id`; `nil` when no answer came (stays pending).
    public var successor: @Sendable (_ id: String, _ seriesId: String) async -> (episodes: Data, image: String?)?
    /// Adds the user's own headers (and anything else every request of the app carries).
    public var prepare: @Sendable (inout URLRequest) -> Void
    /// The readable sentence for a failure.
    public var failureText: @Sendable (DownloadFailure) -> String

    public init(
        address: @escaping @Sendable (String, String?, String, Int?) async throws -> URL,
        subtitles: @escaping @Sendable (String, String?) async -> Bool,
        sections: @escaping @Sendable (String) async -> [PlayerSection]?,
        successor: @escaping @Sendable (String, String) async -> (episodes: Data, image: String?)?,
        prepare: @escaping @Sendable (inout URLRequest) -> Void = { _ in },
        failureText: @escaping @Sendable (DownloadFailure) -> String
    ) {
        self.address = address
        self.subtitles = subtitles
        self.sections = sections
        self.successor = successor
        self.prepare = prepare
        self.failureText = failureText
    }
}

/// **The platform side of the downloads**: a URLSession background session that carries the transfers
/// the core asks for, the files in `DownloadFiles.folder()`, resume data, the free-space measure and the
/// server-bound extras (through `DownloadHostHooks`).
///
/// Why a background session: an 18 GB file cannot finish in the thirty seconds the system gives an app
/// in the background. `URLSessionConfiguration.background` hands the transfer to a system service that
/// keeps running after the app is terminated and relaunches the app when it finishes.
///
/// Everything the host learns goes back to the core as an intent, **from a task of its own, never from
/// inside a command** (the core holds its lock while it runs effects). The delegate is deliberately not
/// `@MainActor`: its callbacks come from the session's queue, and a main-actor delegate called from
/// there aborts under Swift 6.
public final class URLSessionDownloadHost: NSObject, DownloadHost, URLSessionDownloadDelegate, @unchecked Sendable {
    private let hooks: DownloadHostHooks
    private let lock = NSLock()
    /// Item id to its running (or adopted) transfers.
    private var tasks: [String: [URLSessionDownloadTask]] = [:]
    private weak var model: DownloadsModel?
    private var wake: (@Sendable () -> Void)?
    private var progressHandler: (@Sendable (String, Int64, Int64) -> Void)?

    public init(hooks: DownloadHostHooks) {
        self.hooks = hooks
        super.init()
    }

    /// Where the intents go. Set once, right after the model is made.
    @MainActor public func attach(_ model: DownloadsModel) {
        lock.withLock { self.model = model }
    }

    /// Running bytes per title (`id`, loaded, total), for an owner that shows per-title progress next to the
    /// core's list; the throttle is the owner's.
    public func onProgress(_ handler: @escaping @Sendable (String, Int64, Int64) -> Void) {
        lock.withLock { progressHandler = handler }
    }

    /// Called by the system when the session has delivered everything for a background wake-up.
    public func onWake(_ handler: @escaping @Sendable () -> Void) { lock.withLock { wake = handler } }

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: DownloadFiles.sessionId)
        // Both on purpose: `isDiscretionary` would let the system defer the download to a good moment
        // (night, on power); whoever taps download wants it now. And `waitsForConnectivity` makes a
        // download wait in a dead zone instead of failing.
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        // Cellular is decided by the core (`only over WLAN`), so the session allows both.
        configuration.allowsCellularAccess = true
        configuration.sessionSendsLaunchEvents = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// Create the session now (a background wake-up needs its delegate alive before anything else).
    public func start() { _ = session }

    private func emit(_ intent: DownloadsIntent) {
        let target = lock.withLock { model }
        Task { @MainActor in try? target?.send(intent) }
    }

    // MARK: Task description (id, generation, file): everything hangs on the task because the callback
    // comes from the system and cannot reach the list.

    private static let separator = "\u{1F}"

    static func description(id: String, generation: Int64, file: String) -> String {
        [id, String(generation), file].joined(separator: separator)
    }

    struct Parts: Equatable {
        let id: String
        /// `0` for a task from a version without generations.
        let generation: Int64
        let file: String
    }

    static func parts(_ text: String?) -> Parts? {
        let pieces = (text ?? "").components(separatedBy: separator)
        switch pieces.count {
        case 2 where !pieces[0].isEmpty:
            return Parts(id: pieces[0], generation: 0, file: pieces[1])
        case 3... where !pieces[0].isEmpty:
            guard let generation = Int64(pieces[1]) else {
                return Parts(id: pieces[0], generation: 0, file: pieces.dropFirst().joined(separator: separator))
            }
            return Parts(id: pieces[0], generation: generation, file: pieces.dropFirst(2).joined(separator: separator))
        default:
            return nil
        }
    }

    // MARK: DownloadHost

    public func startTransfer(id: String, generation: Int64, file: String, address: String, resume: Data?) {
        guard let url = URL(string: address) else {
            emit(
                .transferFailed(
                    id: id, generation: generation, file: file, reason: hooks.failureText(.http(status: 0)), resume: nil))
            return
        }
        let task: URLSessionDownloadTask
        if let resume {
            // Resume data carries the headers of the first request.
            task = session.downloadTask(withResumeData: resume)
        } else {
            var request = URLRequest(url: url)
            hooks.prepare(&request)
            task = session.downloadTask(with: request)
        }
        task.taskDescription = Self.description(id: id, generation: generation, file: file)
        lock.withLock { tasks[id, default: []].append(task) }
        task.resume()
    }

    public func cancelTransfer(id: String, taskGeneration: Int64?, newGeneration: Int64, wantResumeData: Bool) {
        let matching = lock.withLock { () -> [URLSessionDownloadTask] in
            let all = tasks[id] ?? []
            let hit = all.filter { task in
                guard let wanted = taskGeneration else { return true }
                return Self.parts(task.taskDescription)?.generation == wanted
            }
            tasks[id] = all.filter { task in !hit.contains { $0 === task } }
            return hit
        }
        for task in matching {
            if wantResumeData {
                task.cancel { [weak self] data in
                    guard let data else { return }
                    self?.emit(.resumeData(id: id, generation: newGeneration, data: data))
                }
            } else {
                task.cancel()
            }
        }
    }

    public func resumeTransfer(id: String) {
        let suspended = lock.withLock { (tasks[id] ?? []).filter { $0.state == .suspended } }
        for task in suspended { task.resume() }
    }

    public func runningTransfers() -> [RunningTransferInfo] {
        // The answer is synchronous, the session's list is not: wait for it, briefly. The callback comes
        // on the session's queue, never the caller's.
        let done = DispatchSemaphore(value: 0)
        let found = Box<[URLSessionTask]>([])
        session.getAllTasks { all in
            found.value = all
            done.signal()
        }
        _ = done.wait(timeout: .now() + 3)
        var out: [RunningTransferInfo] = []
        for case let task as URLSessionDownloadTask in found.value
        where task.state == .running || task.state == .suspended {
            out.append(
                RunningTransferInfo(
                    description: task.taskDescription, suspended: task.state == .suspended,
                    bytesReceived: task.countOfBytesReceived))
            // Adopt it: the core may cancel or resume it later by id.
            if let parts = Self.parts(task.taskDescription) {
                lock.withLock {
                    if !(tasks[parts.id] ?? []).contains(where: { $0 === task }) { tasks[parts.id, default: []].append(task) }
                }
            }
        }
        return out
    }

    public func requestAddress(id: String, generation: Int64, source: String?, quality: String, audioIndex: Int64?) {
        let hooks = hooks
        Task { [weak self] in
            do {
                let url = try await hooks.address(id, source, quality.lowercased(), audioIndex.map(Int.init))
                self?.emit(.addressReady(id: id, generation: generation, address: url.absoluteString))
            } catch {
                // The old manager showed one sentence for every failure here; the core owns it.
                self?.emit(.addressFailed(id: id, generation: generation, reason: "Keine Adresse vom Server."))
            }
        }
    }

    public func deleteFile(kind: String, name: String) {
        let target = DownloadFiles.folder().appendingPathComponent(name)
        try? FileManager.default.removeItem(at: target)
    }

    public func fetchImage(name: String, url: String) {
        let target = DownloadFiles.folder().appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: target.path), let address = URL(string: url) else { return }
        let hooks = hooks
        Task {
            var request = URLRequest(url: address)
            hooks.prepare(&request)
            guard let (data, _) = try? await URLSession.shared.data(for: request), data.count > 0 else { return }
            try? data.write(to: target, options: .atomic)
        }
    }

    public func measureSpace() {
        emit(.spaceChanged(bytes: DownloadFiles.freeSpace()))
    }

    public func fetchSubtitles(id: String, source: String?) {
        let hooks = hooks
        // The core counts the download as finished only after this answer; `false` makes it ask again later.
        Task { [weak self] in
            let ok = await hooks.subtitles(id, source)
            self?.emit(.subtitlesFetched(id: id, ok: ok))
        }
    }

    public func fetchSections(id: String) {
        let hooks = hooks
        Task { [weak self] in
            // No answer leaves the field empty; the core asks again on the next contact.
            guard let sections = await hooks.sections(id) else { return }
            self?.emit(.sectionsFetched(id: id, sections: sections))
        }
    }

    public func lookupSuccessor(id: String, seriesId: String) {
        let hooks = hooks
        Task { [weak self] in
            let answer = await hooks.successor(id, seriesId)
            self?.emit(
                .successorFound(
                    id: id, episodesJson: answer?.episodes, image: answer?.image, now: Date().timeIntervalSince1970))
        }
    }

    // MARK: URLSessionDownloadDelegate

    public func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard let parts = Self.parts(downloadTask.taskDescription) else { return }
        let observer = lock.withLock { progressHandler }
        observer?(parts.id, totalBytesWritten, max(0, totalBytesExpectedToWrite))
        emit(
            .transferProgress(
                id: parts.id, generation: parts.generation, file: parts.file, loaded: totalBytesWritten,
                total: max(0, totalBytesExpectedToWrite), now: Date.timeIntervalSinceReferenceDate))
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let parts = Self.parts(downloadTask.taskDescription) else { return }
        // A status code is not success: an expired login answers 401 with a body, and that would land
        // here as a "finished file" of forty bytes.
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            emit(
                .transferFailed(
                    id: parts.id, generation: parts.generation, file: parts.file,
                    reason: hooks.failureText(.http(status: http.statusCode)), resume: nil))
            return
        }
        // **The file must be moved here, not later.** The system deletes it as soon as this returns.
        let target = DownloadFiles.folder().appendingPathComponent(parts.file)
        try? FileManager.default.removeItem(at: target)
        let worked = (try? FileManager.default.moveItem(at: location, to: target)) != nil
        let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? nil
        emit(
            .transferFinished(
                id: parts.id, generation: parts.generation, file: parts.file, worked: worked,
                realSize: worked ? size : nil))
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let parts = Self.parts(task.taskDescription) {
            lock.withLock { tasks[parts.id] = (tasks[parts.id] ?? []).filter { $0 !== task } }
            if let error = error as NSError? {
                let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                emit(
                    .transferFailed(
                        id: parts.id, generation: parts.generation, file: parts.file,
                        reason: hooks.failureText(.error(error)), resume: data))
            }
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = lock.withLock { wake }
        handler?()
    }
}

private final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
