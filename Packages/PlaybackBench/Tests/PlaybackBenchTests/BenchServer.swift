import Foundation
import SwiftlyCore

/// The fixture server (`cargo xtask fixture-server`) with the generated media, started once per test run.
final class BenchServer: @unchecked Sendable {
    static let shared: BenchServer = {
        do { return try BenchServer() } catch { fatalError("fixture server did not start: \(error)") }
    }()

    /// A second fixture server for the Plex shape: one request per connection (`Connection: close`, HTTP/1.1 like a Plex
    /// origin), the Plex titles 9001.. of `Werkzeuge/pruefstand-plex.py`. `SWIFTLY_FIXTURE_LATENCY_MS` is not set here
    /// (the first-load measurement starts its own server with a delay).
    static let plex: BenchServer = {
        do { return try BenchServer(extraEnvironment: ["SWIFTLY_FIXTURE_ONE_REQUEST": "1"]) } catch { fatalError("plex fixture server did not start: \(error)") }
    }()

    private nonisolated(unsafe) static var running: [Process] = []
    private static let runningLock = NSLock()
    /// Every fixture server of this run is stopped when the test process ends (one `atexit` for all of them).
    private static func register(_ process: Process) {
        runningLock.withLock {
            if running.isEmpty { atexit { BenchServer.terminateAll() } }
            running.append(process)
        }
    }
    private static func terminateAll() {
        runningLock.withLock { for process in running where process.isRunning { process.terminate() } }
    }

    let process = Process()
    let address: String
    let media: String

    static var root: URL {
        var url = URL(filePath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }   // .../Packages/PlaybackBench/Tests/PlaybackBenchTests/x.swift
        return url
    }

    init(extraEnvironment: [String: String] = [:]) throws {
        media = ProcessInfo.processInfo.environment["PBENCH_MEDIA"] ?? "build/pbench-media"
        let binary = Self.root.appending(path: "target/debug/xtask").path
        process.executableURL = URL(filePath: binary)
        process.arguments = ["fixture-server", "--port", "0"]
        process.currentDirectoryURL = Self.root
        var env = ProcessInfo.processInfo.environment
        env["SWIFTLY_FIXTURE_MEDIA_DIR"] = media
        for (key, value) in extraEnvironment { env[key] = value }
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        var line = ""
        let deadline = Date().addingTimeInterval(20)
        var buffer = Data()
        while Date() < deadline, !line.contains("listening on") {
            let chunk = out.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            line = String(decoding: buffer, as: UTF8.self)
        }
        guard let range = line.range(of: "http://127.0.0.1:") else { throw CocoaError(.fileReadUnknown) }
        address = String(line[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        Self.register(process)
    }

    func json(_ path: String) async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: address + path)!)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func data(_ path: String, range: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: address + path)!)
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, response as! HTTPURLResponse)
    }

    var account: AccountRef {
        AccountRef(baseUrl: address, userId: "u1", token: "TOKEN", serverKind: .jellyfin, deviceId: "bench-device")
    }

    /// The same server as a Plex account (the token goes into every file address, like a player must).
    var plexAccount: AccountRef {
        AccountRef(baseUrl: address, userId: "u1", token: "PLEXTOKEN", serverKind: .plex, deviceId: "bench-device")
    }
}

final class BenchKeyValue: KeyValueStore {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func get(key: String) -> Data? { lock.withLock { values[key] } }
    func set(key: String, value: Data) { lock.withLock { values[key] = value } }
    func remove(key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}

final class BenchSecrets: SecretStore {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func get(name: String) -> String? { lock.withLock { values[name] } }
    func set(name: String, value: String) { lock.withLock { values[name] = value } }
    func remove(name: String) { lock.withLock { _ = values.removeValue(forKey: name) } }
}

final class BenchPlatform: Platform {
    func deviceName() -> String { "Bench Mac" }
    func log(line: String) {}
    func cacheDir() -> String? { nil }
}

func benchCore() -> Core {
    let configuration = URLSessionHttpClient.defaultConfiguration()
    configuration.waitsForConnectivity = false
    return Core(platform: BenchPlatform(), secrets: BenchSecrets(), store: BenchKeyValue(),
                http: URLSessionHttpClient(configuration: configuration))
}

let benchSettings = PlaySettings(
    audioLanguage: "eng", subtitleLanguage: "eng", automaticSubtitles: false, maxBitrate: 120_000_000,
    bufferLevel: .normal, frameRateMatch: false, serverExtractsText: false)

func benchRequest(_ id: String, flavour: PlayFlavour = .aether, since: Double? = nil, sourceId: String? = nil,
                  downloaded: PlayDownloaded? = nil, hardwareAv1: Bool = false) -> PlayPlanRequest {
    PlayPlanRequest(itemId: id, sourceId: sourceId, since: since, flavour: flavour, hardwareAv1: hardwareAv1, askVersions: false,
                    downloaded: downloaded, ordered: nil, accountKey: "u1", settings: benchSettings,
                    next: .rule(downloadsJson: "[]", withoutNetwork: false))
}
