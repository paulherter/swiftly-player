#if DEBUG
import Foundation
import JellyfinKit

/// **Measurement run for the episode switch** - time from the "next episode" command
/// to the first frame, with and without preparation (`EpisodePreparation`).
///
/// xcrun simctl launch <device> <bundle-id> -wechsellauf [-ohnevorpuffer]
///
/// Needs a signed-in app. Takes a fixed series, season 6 episode 10, remembers
/// the state of episodes 10 and 11, starts 170 s before the end (where the player
/// prepares the next episode), advances after 25 s, then closes and restores both
/// states. The time is in the log: `[Wechsel] Beginn` to `[Wechsel] firstOne Picture to ... ms`.
@MainActor
enum SwitchRun {
    static var an: Bool { ProcessInfo.processInfo.arguments.contains("-wechsellauf") }
    static var withoutPrebuffer: Bool { ProcessInfo.processInfo.arguments.contains("-ohnevorpuffer") }
    private static var backup: [(String, Data)] = []

    static func wish(_ model: AppModel) async -> PlayRequest? {
        guard let client = model.client else { log("nicht angemeldet"); return nil }
        guard let series = await model.search("The Mentalist")?.first(where: { $0.type == "Series" })
        else { log("keine Serie"); return nil }
        let all = await model.episodes(series: series.id, season: nil) ?? []
        guard let f10 = all.first(where: { $0.parentIndexNumber == 6 && $0.indexNumber == 10 }),
              let f11 = all.first(where: { $0.parentIndexNumber == 6 && $0.indexNumber == 11 }),
              let plan = await model.plan(for: f10.id) else { log("Folgen fehlen"); return nil }
        backup = []
        for f in [f10, f11] {
            guard let raw = try? await client.userDataRaw(itemID: f.id) else { continue }
            backup.append((f.id, raw))
            log("Stand vorher F\(f.indexNumber ?? 0): \(String(decoding: raw, as: UTF8.self))")
        }
        let duration = Double(f10.runTimeTicks ?? 0) / 10_000_000
        log("Start F10 bei \(Int(duration - 170)) s von \(Int(duration)) s · Vorbereitung \(withoutPrebuffer ? "aus" : "an")")
        return PlayRequest(item: f10, plan: plan, startAt: max(duration - 170, 0))
    }

    static func flow(_ model: AppModel, close: () -> Void) async {
        for _ in 0..<60 where !PlayState.playerRuns { try? await Task.sleep(for: .seconds(1)) }
        try? await Task.sleep(for: .seconds(25))
        log("Befehl naechste")
        model.remoteCommand?(.next)
        try? await Task.sleep(for: .seconds(15))
        model.remoteCommand?(.stop)
        try? await Task.sleep(for: .seconds(3))
        close()
        try? await Task.sleep(for: .seconds(3))
        guard let client = model.client else { return }
        for (id, raw) in backup {
            do {
                try await client.userDataBackPut(itemID: id, raw: raw)
                let afterwards = try await client.userDataRaw(itemID: id)
                log("Stand nachher: \(String(decoding: afterwards, as: UTF8.self))")
            } catch {
                log("Zuruecklegen fehlgeschlagen: \(error)")
            }
        }
        log("Ende")
    }

    private static func log(_ text: String) { AppLog.writeOut("[Wechsellauf] " + text) }
}
#endif
