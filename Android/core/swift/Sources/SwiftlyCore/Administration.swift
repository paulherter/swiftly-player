import Foundation
import JellyfinKit

// MARK: - The administrator's server page, the bridge for Kotlin
//
// Mirrors `ServerDashboardView` on iPhone. Every word, number and colour role is decided in the
// package (`ServerDashboard`, `ServerStream`); Kotlin only lays it out. Two speeds as there:
// `dashboardOnce` when the page opens, `dashboardLive` every second.

struct DashboardOnceResponse: Encodable {
    let name, version: String
    let pendingRestart: Bool
    let movies, series, episodes: Int
    let uhd, hd, sd: Int?
}

struct DashboardLoadResponse: Encodable {
    let cpu, memory: String?
    let cpuShare, memoryShare: Double?
    let diskText: String?
}

struct DashboardDiskResponse: Encodable {
    let id, uses, freeText: String
    let freeShare: Double
    let nearlyFull: Bool
}

struct DashboardTaskResponse: Encodable {
    let id, name: String
    let category, progressText: String?
    let progress: Double?
}

struct DashboardBadgeResponse: Encodable { let kind, text: String }

/// One stream card. `id` changes only with a new session or title: Kotlin keys the card by it,
/// so the poster is not loaded again every second.
struct DashboardStreamResponse: Encodable {
    let id, title, user, device, timeLine, delivery: String
    let titleAddition, subtitle, poster, userImage: String?
    let square, audio, paused, deliveryGood: Bool
    let share: Double
    let badges: [DashboardBadgeResponse]
}

struct DashboardLiveResponse: Encodable {
    let load: DashboardLoadResponse?
    let disks: [DashboardDiskResponse]
    let tasks: [DashboardTaskResponse]
    let streams: [DashboardStreamResponse]
}

struct DashboardLogResponse: Encodable {
    let name, size: String
    let modified: Int64?
}

extension Kern {
    private var administration: (any ServerAdministration)? {
        guard let c = client, c.capabilities.contains(.administration) else { return nil }
        return c as? any ServerAdministration
    }

    /// Name, version and library counts. Throws a readable text when the server refuses.
    public func dashboardOnce() async throws -> String {
        guard let admin = administration else { throw CoreText(coreErrorText(CoreError.notConnected)) }
        let once: (system: ServerSystem, counts: ServerCounts, resolutions: ResolutionCounts?)
        do { once = try await admin.dashboardOnce() } catch { throw CoreText(coreErrorText(error)) }
        let r = once.resolutions
        return Self.encoded(DashboardOnceResponse(
            name: once.system.name, version: once.system.version,
            pendingRestart: once.system.pendingRestart,
            movies: once.counts.movies, series: once.counts.series, episodes: once.counts.episodes,
            uhd: r?.uhd, hd: r?.hd, sd: r?.sd))
    }

    /// Load, disks, running tasks and streams; never throws, missing parts stay empty.
    public func dashboardLive() async -> String {
        guard let admin = administration else { return "{}" }
        let live = await admin.dashboardLive()
        let a = addresses
        return Self.encoded(DashboardLiveResponse(
            load: live.load.map {
                DashboardLoadResponse(cpu: $0.cpuPercent.map(ServerLoad.percent),
                                      memory: $0.memoryPercent.map(ServerLoad.percent),
                                      cpuShare: $0.cpuPercent.map { $0 / 100 },
                                      memoryShare: $0.memoryPercent.map { $0 / 100 }, diskText: $0.diskText)
            },
            disks: live.disks.map {
                DashboardDiskResponse(id: $0.id, uses: $0.uses.joined(separator: ", "), freeText: $0.freeText,
                                      freeShare: $0.freeShare, nearlyFull: $0.nearlyFull)
            },
            tasks: live.tasks.map {
                DashboardTaskResponse(id: $0.id, name: $0.name, category: $0.category,
                                      progressText: $0.progressText, progress: $0.progress)
            },
            streams: live.streams.map { s in
                DashboardStreamResponse(
                    id: s.id, title: s.title, user: s.userName, device: s.deviceLine, timeLine: s.timeLine,
                    delivery: s.deliveryLine, titleAddition: s.titleAddition, subtitle: s.subtitle,
                    poster: a?.construct(itemID: s.posterID, mark: s.posterTag, mass: .atMostHigh(300))?.absoluteString,
                    userImage: s.userImageTag != nil ? s.userID.flatMap { a?.user($0, mark: s.userImageTag, border: 60)?.absoluteString } : nil,
                    square: s.squarePoster, audio: s.isAudio, paused: s.paused,
                    deliveryGood: TechDetails.weight(s.delivery) == .good, share: s.share,
                    badges: s.badges.map { DashboardBadgeResponse(kind: $0.kind.rawValue, text: $0.text) })
            }))
    }

    /// Empty when done, otherwise the readable error.
    public func serverRestart() async -> String {
        guard let admin = administration else { return coreErrorText(CoreError.notConnected) }
        do { try await admin.restartServer(); return "" } catch { return coreErrorText(error) }
    }

    public func librariesScan() async -> String {
        guard let admin = administration else { return coreErrorText(CoreError.notConnected) }
        do { try await admin.scanLibraries(); return "" } catch { return coreErrorText(error) }
    }

    /// The log files, newest first; `modified` in milliseconds since 1970.
    public func serverLogs() async throws -> String {
        guard let admin = administration else { throw CoreText(coreErrorText(CoreError.notConnected)) }
        let files: [ServerLogFile]
        do { files = try await admin.logFiles() } catch { throw CoreText(coreErrorText(error)) }
        return Self.encoded(files.map {
            DashboardLogResponse(name: $0.name, size: $0.sizeText,
                                 modified: $0.modified.map { Int64($0.timeIntervalSince1970 * 1000) })
        })
    }

    /// The end of one log file (`ServerDashboard.logLimit`).
    public func serverLog(name: String) async throws -> String {
        guard let admin = administration else { throw CoreText(coreErrorText(CoreError.notConnected)) }
        do { return try await admin.logText(name: name, limit: ServerDashboard.logLimit) }
        catch { throw CoreText(coreErrorText(error)) }
    }
}
