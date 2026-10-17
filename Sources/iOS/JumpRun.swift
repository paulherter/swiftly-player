#if DEBUG
import Foundation
import JellyfinKit

/// **Measurement run for seeks**: after a double tap, time and offer
/// button appeared only seconds later. Without fingers, via the log only.
///
/// xcrun simctl launch <device> <bundle-id> -sprunglauf
///
/// Takes an episode with an intro section, remembers its playback state,
/// seeks forward, fast forward twice, back, jumps into the recap and out,
/// paused into the outro and out, closes and restores the state. The player
/// writes a `[Sprungtakt]` line every tick with display, VLC time and
/// offer; the log's timestamps carry milliseconds.
@MainActor
enum JumpRun {
    static var an: Bool { ProcessInfo.processInfo.arguments.contains("-sprunglauf") }

    private static var episode: Item?
    private static var raw: Data?
    private static var introSegment: JellyfinKit.Segment?
    private static var credits: JellyfinKit.Segment?

    static func wish(_ model: AppModel) async -> PlayRequest? {
        guard let client = model.client else { AppLog.writeOut("[Sprunglauf] nicht angemeldet"); return nil }
        guard let series = await model.search("The Mentalist")?.first(where: { $0.type == "Series" })
        else { AppLog.writeOut("[Sprunglauf] keine Serie"); return nil }
        for candidate in (await model.episodes(series: series.id, season: nil) ?? []).prefix(60) {
            let sections = await model.sections(for: candidate.id)
            guard let intro = sections.first(where: { $0.art == .introSegment || $0.art == .lookBack }),
                  let end = sections.first(where: { $0.art == .credits }),
                  let plan = await model.plan(for: candidate.id) else { continue }
            let data = try? await client.userDataRaw(itemID: candidate.id)
            episode = candidate; raw = data; introSegment = intro; credits = end
            AppLog.writeOut("[Sprunglauf] Folge \(candidate.id) \(candidate.name) · Vorspann \(intro.from)–\(intro.until) · Stand vorher \(String(decoding: data ?? Data(), as: UTF8.self))")
            return PlayRequest(item: candidate, plan: plan, startAt: intro.until + 240)
        }
        AppLog.writeOut("[Sprunglauf] keine Folge mit Vorspann")
        return nil
    }

    static func flow(_ model: AppModel, close: () -> Void) async {
        guard let episode, let introSegment, let credits else { return }
        for _ in 0..<60 where !PlayState.playerRuns { try? await Task.sleep(for: .seconds(1)) }
        try? await Task.sleep(for: .seconds(4))
        func command(_ b: RemoteCommand, holdOn: Double) async {
            AppLog.writeOut("[Sprunglauf] Befehl \(b)")
            model.remoteCommand?(b)
            try? await Task.sleep(for: .seconds(holdOn))
        }
        await command(.forward, holdOn: 7)
        await command(.forward, holdOn: 0.25)
        await command(.forward, holdOn: 7)
        await command(.back, holdOn: 7)
        await command(.jumpOn(introSegment.from + 3), holdOn: 7)
        await command(.jumpOn(introSegment.until + 30), holdOn: 7)
        // Like "Skip", immediately followed by "30 s forward" (once jumped
        // back).
        await command(.jumpOn(introSegment.until), holdOn: 0.3)
        await command(.forward, holdOn: 6)
        // Paused so the card's countdown does not switch to the next episode and
        // change its state.
        await command(.pause, holdOn: 2)
        await command(.jumpOn(credits.from + 3), holdOn: 7)
        await command(.jumpOn(credits.from - 60), holdOn: 7)
        await command(.stop, holdOn: 4)
        close()
        try? await Task.sleep(for: .seconds(2))
        guard let client = model.client, let raw else { return }
        do {
            try await client.userDataBackPut(itemID: episode.id, raw: raw)
            let afterwards = try await client.userDataRaw(itemID: episode.id)
            AppLog.writeOut("[Sprunglauf] Stand nachher \(String(decoding: afterwards, as: UTF8.self))")
        } catch {
            AppLog.writeOut("[Sprunglauf] Zuruecklegen fehlgeschlagen: \(error)")
        }
    }
}
#endif
