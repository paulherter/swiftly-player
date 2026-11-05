import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// ``ServerAdministration`` for Jellyfin. Every path here needs an administrator's token.
extension JellyfinClient {

    public func dashboardOnce() async throws -> (system: ServerSystem, counts: ServerCounts, resolutions: ResolutionCounts?) {
        async let system = fetch("System/Info", as: ServerSystem.self)
        async let counts = fetch("Items/Counts", as: ServerCounts.self)
        async let resolutions = resolutionCounts()
        return try await (system, counts, resolutions)
    }

    /// **Load, disks, tasks and streams side by side**, every one on its own: a server before
    /// 10.11 has no storage endpoint, one without the plugin no load, and neither may take the
    /// streams with it.
    public func dashboardLive() async -> ServerLive {
        async let load = systemLoad()
        async let disks = storage()
        async let tasks = try? fetch("ScheduledTasks", query: [.init(name: "isHidden", value: "false")],
                                     as: [ServerTask].self)
        async let streams = activeStreams()
        return await ServerLive(load: load, disks: disks, tasks: ServerTask.running(tasks ?? []),
                                streams: streams)
    }

    public func restartServer() async throws { try await call("System/Restart") }

    /// Every library, as "Scan all libraries" on the server's dashboard does.
    public func scanLibraries() async throws { try await call("Library/Refresh") }

    /// Cancels a running scheduled task; the server sets it to `Cancelling`, then `Idle`.
    public func stopTask(id: String) async throws {
        try await call("ScheduledTasks/Running/\(id)", method: "DELETE")
    }

    /// **Stops a session's playback, then tells the viewer why.**
    ///
    /// Stop first: a message sent while the player is open sits behind it on some clients and
    /// goes with it when it closes. Without a timeout Jellyfin's clients show the message as a
    /// dialog the viewer confirms, so it cannot pass unseen. A failed message does not undo
    /// the stop and is not reported; the stop is what was asked for.
    public func stopPlayback(sessionID: String, message: String) async throws {
        try await call("Sessions/\(sessionID)/Playing/Stop")
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        try? await call("Sessions/\(sessionID)/Message",
                        body: SessionMessage(header: translated("Nachricht vom Administrator"), text: text))
    }

    public func logFiles() async throws -> [ServerLogFile] {
        ServerLogFile.newestFirst(try await fetch("System/Logs", as: [ServerLogFile].self))
    }

    public func logText(name: String, limit: Int) async throws -> String {
        ServerLogFile.tail(try await fetchData("System/Logs/Log", query: [.init(name: "name", value: name)]),
                           limit: limit)
    }

    // MARK: Parts

    /// The plugin's counts first (one request, cached on the server, with HDR and DV);
    /// otherwise three counts with Jellyfin's filters. `nil` when neither answers.
    func resolutionCounts() async -> ResolutionCounts? {
        if !dashboardPluginAbsent,
           let answer = try? await fetch("JellyTwiggy/LibraryResolutions", as: [String: [String: Int]].self) {
            return ResolutionCounts.plugin(answer)
        }
        func count(_ filter: String, _ value: Bool) async -> Int? {
            let query: [URLQueryItem] = [
                .init(name: "Recursive", value: "true"),
                .init(name: "IncludeItemTypes", value: "Movie,Episode"),
                .init(name: "IsMissing", value: "false"),
                .init(name: filter, value: value ? "true" : "false"),
                .init(name: "Limit", value: "0"),
                .init(name: "EnableTotalRecordCount", value: "true"),
            ]
            return try? await fetch("Items", query: query, as: RecordCount.self).total
        }
        async let uhd = count("Is4K", true)
        async let hd = count("IsHd", true)
        async let sd = count("IsHd", false)
        guard let u = await uhd, let h = await hd, let s = await sd else { return nil }
        return ResolutionCounts.filters(uhd: u, hdOrBetter: h, sd: s)
    }

    /// The plugin's load. A 404 means no plugin, and the page stops asking for the session.
    func systemLoad() async -> ServerLoad? {
        guard !dashboardPluginAbsent else { return nil }
        do {
            let load = try await fetch("JellyTwiggy/SystemMetrics", as: ServerLoad.self)
            return load.isEmpty ? nil : load
        } catch JellyfinError.http(let status, _) where status == 404 || status == 405 {
            dashboardPluginAbsent = true
            return nil
        } catch {
            return nil
        }
    }

    func storage() async -> [ServerDisk] {
        guard let s = try? await fetch("System/Info/Storage", as: SystemStorage.self) else { return [] }
        return ServerDisk.disks(s)
    }

    /// Sessions active in the last minute that play something.
    func activeStreams() async -> [ServerStream] {
        guard let data = try? await fetchData("Sessions", query: [.init(name: "activeWithinSeconds", value: "60")])
        else { return [] }
        return (try? ServerStream.playing(data, decoder: answerDecoder)) ?? []
    }
}

/// `POST /Sessions/{id}/Message`. No `TimeoutMs`: the clients then show a dialog to confirm.
struct SessionMessage: Encodable {
    let header: String
    let text: String
    enum CodingKeys: String, CodingKey { case header = "Header", text = "Text" }
}

/// `TotalRecordCount` of an item query with `Limit=0`.
struct RecordCount: Decodable {
    let total: Int
    enum CodingKeys: String, CodingKey { case total = "TotalRecordCount" }
}
