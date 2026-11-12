import Foundation
import SwiftlyCore

// Test-only stand-ins for the two app classes the real player files lean on (`AppModel`, `AppCore`). Everything
// else in `AppFiles/` is the app's own source, linked (symlinks), not copied: the tests run the real macOS player path
// (`VLCPlayerView`, `CorePlaybackBackend`, `CoreAetherPort`, `AetherPlayerEngine`, `SubtitleOverlay`).

struct BenchSession { let storageAccount = "u1" }

struct BenchDownload { var runtimeTicks: Int64? }
struct BenchDownloads {
    var ticks: [String: Int64] = [:]
    func entries(for id: String) -> BenchDownload? { ticks[id].map { BenchDownload(runtimeTicks: $0) } }
}

@MainActor
final class AppModel {
    var session: BenchSession? = BenchSession()
    var downloads = BenchDownloads()
    var backSeconds = 10
    var forwardSeconds = 30
    var nextAutomatic = false
    var alwaysDirectPlay = false
    var bitratesLimit = 120_000_000
    var convertAllowed = true
    var subtitleWish: [String: Int64] = [:]
    private(set) var owned = Set<String>()
    func reporterForCore() -> PlayReporter? {
        try? AppCore.shared.raw.playReporter(account: BenchServer.shared.account, locale: "de", accountKey: "u1")
    }
    func coreOwns(_ key: String) { owned.insert(key) }
    func coreReleased(_ key: String) { owned.remove(key) }
}

@MainActor
final class AppCore {
    static let shared = AppCore()
    let raw = benchCore()
    enum Unavailable: Error { case account }
    func playerShared(session: BenchSession, start: PlayerStart, prefs: PlayerPrefs, engine: PlayerEngine,
                      reporter: PlayReporter) throws -> PlayerModel {
        PlayerModel(vm: try raw.playerVmShared(account: BenchServer.shared.account, accountKey: session.storageAccount,
                                               locale: "de", start: start, prefs: prefs, engine: engine, reporter: reporter))
    }
}
