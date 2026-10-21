#if DEBUG
import UIKit
import JellyfinKit

/// **Self-test for the player's battery cost**, no touch input and no server,
/// via the log only.
///
/// xcrun devicectl device process launch --device <id> <bundle-id> \
///   -akkulauf Documents/<file> [-akkudauer <s>]
///
/// `-akkulauf server` instead opens the real player (controls, overlays, SwiftUI)
/// on a fixed test episode for `-akkudauer` seconds, then restores its playback
/// state. Needs a signed-in app.
///
/// Puts a bare player over the whole window, plays `<file>` (relative to the app
/// container, or absolute) and writes an `[Akkulauf]` line every five seconds:
/// shown frames per second, process CPU time per second, thermal state. Meant to
/// run under `xctrace record` (Animation Hitches / Power Profiler), which sees the
/// display rate without asking for one; a `CADisplayLink` counter would raise the
/// very rate it measures.
@MainActor
enum BatteryRun {
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }
    static var an: Bool { arguments.contains("-akkulauf") }

    private static func value(_ name: String) -> String? {
        arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }
    private static func log(_ text: String) { AppLog.writeOut("[Akkulauf] " + text) }

    /// User plus system time of the whole process, in seconds.
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return s(usage.ru_utime) + s(usage.ru_stime)
    }

    static var withServer: Bool { value("-akkulauf") == "server" }
    private static var backup: (String, Data)?

    static func wish(_ model: AppModel) async -> PlayRequest? {
        guard let client = model.client else { log("nicht angemeldet"); return nil }
        let hits = await model.search("Mentalist")
        guard let series = hits?.first(where: { $0.type == "Series" }) else {
            log("keine Serie: \(hits.map { $0.map { "\($0.type ?? "?") \($0.name)" } } ?? ["Fehler"])")
            return nil
        }
        let all = await model.episodes(series: series.id, season: nil) ?? []
        guard let episode = all.first(where: { $0.parentIndexNumber == 6 && $0.indexNumber == 10 }),
              let plan = await model.plan(for: episode.id) else { log("Folge fehlt"); return nil }
        if let raw = try? await client.userDataRaw(itemID: episode.id) { backup = (episode.id, raw) }
        log("Start Server-Folge \(episode.id)")
        return PlayRequest(item: episode, plan: plan, startAt: 600)
    }

    static func flow(_ model: AppModel, close: () -> Void) async {
        for _ in 0..<60 where !PlayState.playerRuns { try? await Task.sleep(for: .seconds(1)) }
        let seconds = value("-akkudauer").flatMap(Int.init) ?? 45
        var lastCPU = cpuSeconds()
        for step in 1...(seconds / 5) {
            try? await Task.sleep(for: .seconds(5))
            let cpu = cpuSeconds()
            log("t=\(step * 5) s · CPU \(Int((cpu - lastCPU) / 5 * 100)) %"
                + " · Wärme \(ProcessInfo.processInfo.thermalState.rawValue)")
            lastCPU = cpu
        }
        model.remoteCommand?(.stop)
        try? await Task.sleep(for: .seconds(3))
        close()
        try? await Task.sleep(for: .seconds(3))
        if let client = model.client, let (id, raw) = backup {
            do { try await client.userDataBackPut(itemID: id, raw: raw) } catch { log("Zuruecklegen fehlgeschlagen: \(error)") }
        }
        log("Ende")
    }

    static func start() {
        guard !withServer else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard let raw = value("-akkulauf") else { log("keine Datei"); return }
            let address = raw.hasPrefix("/")
                ? URL(fileURLWithPath: raw)
                : URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(raw)
            let window = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
            guard let window else { log("kein Fenster"); return }
            let seconds = value("-akkudauer").flatMap(Int.init) ?? 45
            let viewRef = VLCPlayerView(frame: window.bounds)
            viewRef.testVideoTrack = true
            window.addSubview(viewRef)
            log("Start \(address.lastPathComponent) · \(seconds) s")
            viewRef.play(url: address)
            var lastShown = 0
            var lastCPU = cpuSeconds()
            for step in 1...(seconds / 5) {
                try? await Task.sleep(for: .seconds(5))
                let shown = Int(viewRef.statistics?.displayedPictures ?? 0)
                let cpu = cpuSeconds()
                log("t=\(step * 5) s · Bilder/s \(String(format: "%.1f", Double(shown - lastShown) / 5))"
                    + " · CPU \(Int((cpu - lastCPU) / 5 * 100)) %"
                    + " · Wärme \(ProcessInfo.processInfo.thermalState.rawValue)")
                lastShown = shown
                lastCPU = cpu
            }
            viewRef.stop()
            viewRef.removeFromSuperview()
            log("Ende")
        }
    }
}
#endif
