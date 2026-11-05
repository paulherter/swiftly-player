import Foundation

/// **The server at a glance, for its administrator**: name and version, what the libraries
/// hold, how loaded the machine is, what runs and who plays what right now.
///
/// Only Jellyfin and only for an account with `Policy.IsAdministrator`; every endpoint here
/// answers 403 to anyone else. CPU and memory are not part of Jellyfin's API at all: they come
/// from the Jelly Twiggy plugin (`GET /JellyTwiggy/SystemMetrics`), and without it that part of
/// the page is simply absent. The same plugin counts resolutions per item in one cached request;
/// without it the counts come from three item queries with Jellyfin's own `Is4K`/`IsHd` filters.
public enum ServerDashboard {
    /// How much of a log the page shows: the end, where the error just happened.
    public static let logLimit = 256 * 1024
}

/// What the page asks for every second.
public struct ServerLive: Sendable, Equatable {
    /// `nil` without the plugin or on a server that is not Linux (the plugin reads `/proc`).
    public var load: ServerLoad?
    /// Empty on servers before 10.11, which have no storage endpoint.
    public var disks: [ServerDisk]
    /// Running only (``ServerTask/running(_:)``).
    public var tasks: [ServerTask]
    public var streams: [ServerStream]

    public init(load: ServerLoad? = nil, disks: [ServerDisk] = [], tasks: [ServerTask] = [],
                streams: [ServerStream] = []) {
        self.load = load
        self.disks = disks
        self.tasks = tasks
        self.streams = streams
    }
}

// MARK: - System

/// `GET /System/Info`, the parts the page shows.
public struct ServerSystem: Sendable, Equatable, Decodable {
    public let name: String
    public let version: String
    /// An update or a plugin waits for a restart; the restart button says so.
    public let pendingRestart: Bool

    enum CodingKeys: String, CodingKey {
        case name = "ServerName", version = "Version"
        case pendingRestart = "HasPendingRestart"
    }

    public init(name: String, version: String, pendingRestart: Bool = false) {
        self.name = name
        self.version = version
        self.pendingRestart = pendingRestart
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        version = (try? c.decode(String.self, forKey: .version)) ?? ""
        pendingRestart = (try? c.decode(Bool.self, forKey: .pendingRestart)) ?? false
    }
}

/// `GET /Items/Counts`.
public struct ServerCounts: Sendable, Equatable, Decodable {
    public let movies: Int
    public let series: Int
    public let episodes: Int

    enum CodingKeys: String, CodingKey {
        case movies = "MovieCount", series = "SeriesCount", episodes = "EpisodeCount"
    }

    public init(movies: Int, series: Int, episodes: Int) {
        self.movies = movies
        self.series = series
        self.episodes = episodes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        movies = (try? c.decode(Int.self, forKey: .movies)) ?? 0
        series = (try? c.decode(Int.self, forKey: .series)) ?? 0
        episodes = (try? c.decode(Int.self, forKey: .episodes)) ?? 0
    }
}

/// **Films and episodes by resolution.** HD is 720p and 1080p together. Only what Jellyfin
/// itself can count, so the numbers are the same with and without the plugin; HDR and Dolby
/// Vision sit on the video track, which only the plugin reads, and are left out.
public struct ResolutionCounts: Sendable, Equatable {
    public let uhd: Int
    public let hd: Int
    public let sd: Int

    public init(uhd: Int, hd: Int, sd: Int) {
        self.uhd = uhd
        self.hd = hd
        self.sd = sd
    }

    /// The plugin's answer: kind → bucket → count (`Movie`, `Episode`, `MusicVideo`; `4K`,
    /// `1080p`, `720p`, `SD`, `HDR`, `DV`). Films and episodes are summed; music videos are no
    /// part of "films, series, episodes" above, so they stay out here too. One cached request
    /// instead of three counts over the whole library.
    public static func plugin(_ answer: [String: [String: Int]]) -> ResolutionCounts {
        let kinds = ["Movie", "Episode"].compactMap { answer[$0] }
        func sum(_ bucket: String) -> Int { kinds.reduce(0) { $0 + ($1[bucket] ?? 0) } }
        return ResolutionCounts(uhd: sum("4K"), hd: sum("1080p") + sum("720p"), sd: sum("SD"))
    }

    /// **From Jellyfin's own filters**: `Is4K` (width ≥ 3800) and `IsHd` (width ≥ 1200), each
    /// counted with `Limit=0`. `IsHd=true` includes 4K, so 4K is taken off; `IsHd=false` is SD.
    public static func filters(uhd: Int, hdOrBetter: Int, sd: Int) -> ResolutionCounts {
        ResolutionCounts(uhd: uhd, hd: max(hdOrBetter - uhd, 0), sd: sd)
    }
}

/// `GET /JellyTwiggy/SystemMetrics`. Every value can be missing (not Linux, `/proc` unreadable).
public struct ServerLoad: Sendable, Equatable, Decodable {
    public let cpuPercent: Double?
    public let memoryPercent: Double?
    public let memoryUsed: Int64?
    public let memoryTotal: Int64?
    public let diskRead: Double?
    public let diskWrite: Double?

    enum CodingKeys: String, CodingKey {
        case cpuPercent = "CpuPercent", memoryPercent = "MemoryPercent"
        case memoryUsed = "MemoryUsedBytes", memoryTotal = "MemoryTotalBytes"
        case diskRead = "DiskReadBytesPerSecond", diskWrite = "DiskWriteBytesPerSecond"
    }

    public init(cpuPercent: Double?, memoryPercent: Double?, memoryUsed: Int64? = nil,
                memoryTotal: Int64? = nil, diskRead: Double? = nil, diskWrite: Double? = nil) {
        self.cpuPercent = cpuPercent
        self.memoryPercent = memoryPercent
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.diskRead = diskRead
        self.diskWrite = diskWrite
    }

    /// The plugin answers on every server, with nothing in it off Linux. Nothing to show then.
    public var isEmpty: Bool { cpuPercent == nil && memoryPercent == nil }

    /// "13%" in the middle of a ring.
    public static func percent(_ value: Double) -> String { "\(Int(min(max(value, 0), 100).rounded()))%" }

    /// "↓ 12 MB/s · ↑ 1,3 MB/s" for read and write; `nil` without a value.
    public var diskText: String? {
        guard let r = diskRead, let w = diskWrite else { return nil }
        func rate(_ v: Double) -> String { DownloadRules.size(Int64(v.rounded())) + "/s" }
        return "↓ \(rate(r)) · ↑ \(rate(w))"
    }
}

// MARK: - Disks

/// `GET /System/Info/Storage` (Jellyfin 10.11 and later).
struct SystemStorage: Decodable {
    struct Folder: Decodable {
        let path: String
        let free: Int64
        let used: Int64
        let device: String?
        enum CodingKeys: String, CodingKey {
            case path = "Path", free = "FreeSpace", used = "UsedSpace", device = "DeviceId"
        }
    }
    struct Library: Decodable {
        let name: String
        let folders: [Folder]
        enum CodingKeys: String, CodingKey { case name = "Name", folders = "Folders" }
    }
    let programData: Folder?
    let cache: Folder?
    let metadata: Folder?
    let transcoding: Folder?
    let libraries: [Library]

    enum CodingKeys: String, CodingKey {
        case programData = "ProgramDataFolder", cache = "CacheFolder"
        case metadata = "InternalMetadataFolder", transcoding = "TranscodingTempFolder"
        case libraries = "Libraries"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        programData = try? c.decodeIfPresent(Folder.self, forKey: .programData)
        cache = try? c.decodeIfPresent(Folder.self, forKey: .cache)
        metadata = try? c.decodeIfPresent(Folder.self, forKey: .metadata)
        transcoding = try? c.decodeIfPresent(Folder.self, forKey: .transcoding)
        libraries = (try? c.decode([Library].self, forKey: .libraries)) ?? []
    }
}

/// **One drive of the server**, with everything that lives on it.
///
/// The server reports per folder, and the free and used space of a folder are those of the
/// drive it sits on. Ten library folders on one array are one drive, not ten; they are
/// joined by the drive's id (its mount point), else by the folder's path.
public struct ServerDisk: Sendable, Equatable, Identifiable {
    public let id: String
    /// Library names and "Jellyfin" / "Transkodierung", in the order they first appear.
    public let uses: [String]
    public let free: Int64
    public let used: Int64

    public init(id: String, uses: [String], free: Int64, used: Int64) {
        self.id = id
        self.uses = uses
        self.free = free
        self.used = used
    }

    public var total: Int64 { free + used }
    /// 0...1, how much is free: the bar shows what is left, the number says it.
    public var freeShare: Double { total > 0 ? min(max(Double(free) / Double(total), 0), 1) : 0 }
    /// "50%" free. Only the share: the page answers "is a drive running full", and the sizes
    /// and mount points are the server dashboard's business.
    public var freeText: String { ServerLoad.percent(freeShare * 100) }
    /// Under 10 percent free is worth a colour.
    public var nearlyFull: Bool { freeShare < 0.1 }

    static func disks(_ storage: SystemStorage) -> [ServerDisk] {
        var order: [String] = []
        var found: [String: (uses: [String], free: Int64, used: Int64)] = [:]
        func add(_ folder: SystemStorage.Folder?, _ use: String) {
            // -1 is the server's "could not read this drive".
            guard let folder, folder.free >= 0, folder.used >= 0 else { return }
            let key = folder.device.flatMap { $0.isEmpty ? nil : $0 } ?? folder.path
            if var known = found[key] {
                if !known.uses.contains(use) { known.uses.append(use) }
                found[key] = known
            } else {
                order.append(key)
                found[key] = ([use], folder.free, folder.used)
            }
        }
        for library in storage.libraries {
            for folder in library.folders { add(folder, library.name) }
        }
        for folder in [storage.programData, storage.metadata, storage.cache] { add(folder, "Jellyfin") }
        add(storage.transcoding, translated("Transkodierung"))
        return order.compactMap { key in
            found[key].map { ServerDisk(id: key, uses: $0.uses, free: $0.free, used: $0.used) }
        }
    }
}

// MARK: - Tasks

/// One scheduled task (`GET /ScheduledTasks`). The page lists only the running ones.
public struct ServerTask: Sendable, Equatable, Identifiable, Decodable {
    public let id: String
    public let name: String
    public let category: String?
    public let state: String
    /// 0...100 while running; the server sends none in the first moments.
    public let progress: Double?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", category = "Category", state = "State"
        case progress = "CurrentProgressPercentage"
    }

    public init(id: String, name: String, category: String? = nil, state: String, progress: Double? = nil) {
        self.id = id
        self.name = name
        self.category = category
        self.state = state
        self.progress = progress
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        category = try? c.decodeIfPresent(String.self, forKey: .category)
        state = (try? c.decode(String.self, forKey: .state)) ?? "Idle"
        progress = try? c.decodeIfPresent(Double.self, forKey: .progress)
    }

    /// `Running` and `Cancelling`; both still take the machine.
    public var isRunning: Bool { state != "Idle" }

    /// "42 %", or `nil` before the server reports a value.
    public var progressText: String? {
        progress.map { "\(Int(min(max($0, 0), 100).rounded())) %" }
    }

    /// Running tasks only, the furthest along first.
    public static func running(_ all: [ServerTask]) -> [ServerTask] {
        all.filter(\.isRunning).sorted { ($0.progress ?? 0) > ($1.progress ?? 0) }
    }
}

// MARK: - Logs

/// One log file (`GET /System/Logs`).
public struct ServerLogFile: Sendable, Equatable, Identifiable, Decodable {
    public var id: String { name }
    public let name: String
    public let size: Int64
    public let modified: Date?

    enum CodingKeys: String, CodingKey { case name = "Name", size = "Size", modified = "DateModified" }

    public init(name: String, size: Int64, modified: Date?) {
        self.name = name
        self.size = size
        self.modified = modified
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        size = (try? c.decode(Int64.self, forKey: .size)) ?? 0
        modified = try? c.decodeIfPresent(Date.self, forKey: .modified)
    }

    /// "1,4 MB".
    public var sizeText: String { DownloadRules.size(size) }

    /// Newest first: the one that is being written is what someone looking for an error wants.
    public static func newestFirst(_ files: [ServerLogFile]) -> [ServerLogFile] {
        files.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    /// **The end of a log, at a line start.** A log of a busy day is tens of megabytes; a phone
    /// shows the last part, which is where the error just happened. Cut after a line break so the
    /// first line shown is whole.
    public static func tail(_ data: Data, limit: Int) -> String {
        guard data.count > limit else { return String(decoding: data, as: UTF8.self) }
        var part = data.suffix(limit)
        if let newline = part.firstIndex(of: 0x0A) { part = part[part.index(after: newline)...] }
        return String(decoding: part, as: UTF8.self)
    }
}
