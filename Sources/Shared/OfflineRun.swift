#if DEBUG
import Foundation
import JellyfinKit

/// **Self-test for downloads without network**, no touch input, via the log
/// only.
///
/// xcrun simctl launch <device> <bundle-id> -offlinelauf -offlinekonto <name>
///
/// Takes two consecutive episodes of a series with intro and credits chapters,
/// downloads both (unless already present), cuts the network via ``Netzsperre``
/// and checks:
///
/// 1. whether chapters and next episode are available without the server,
/// 2. what the player offers at both points and whether "Next Episode" switches,
/// 3. what is remembered locally (queued reports, state at download),
/// 4. after reconnecting: what arrives at the server, that an older report does
///    not overwrite a newer server state, and that nothing is sent twice.
///
/// Afterwards it restores the playback state of both episodes exactly as it was
/// and removes downloads it created itself.
@MainActor
enum OfflineRun {
    static var an: Bool { ProcessInfo.processInfo.arguments.contains("-offlinelauf") }

    private static var first: Item?
    private static var second: Item?
    private static var raw: [String: Data] = [:]
    private static var introSegment: JellyfinKit.Segment?
    private static var credits: JellyfinKit.Segment?
    private static var selfLoaded: [String] = []
    private static var beforeAccount: String?

    private static func log(_ text: String) { AppLog.writeOut("[Offlinelauf] " + text) }

    /// Finds the pair, downloads, cuts the network and returns the request for the
    /// player, or `nil` if something is missing.
    static func wish(_ model: AppModel) async -> PlayRequest? {
        guard model.session != nil else { log("nicht angemeldet"); return nil }
        log("Konto \(model.session?.userName ?? "?") · im Bund: \(model.accounts.map { "\($0.userName) \($0.serverURL.host() ?? "")" })")
        // **Only on the explicitly named profile** (`-offlinekonto <name>`), never
        // another, since real watch states live there. If it is in the bundle but not in
        // front, it is switched to and back at the end.
        let args = ProcessInfo.processInfo.arguments
        let allowed = args.firstIndex(of: "-offlinekonto").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        guard let allowed, !allowed.lowercased().contains("eltern")
        else { log("Profil nicht freigegeben — Lauf endet"); return nil }
        if model.session?.userName != allowed,
           let target = model.accounts.first(where: { $0.userName == allowed }) {
            beforeAccount = model.session?.accountKey
            model.switchAccount(toward: target.accountKey)
            for _ in 0..<40 where model.session?.userName != allowed || model.client == nil {
                try? await Task.sleep(for: .milliseconds(500))
            }
            try? await Task.sleep(for: .seconds(3))
            log("umgeschaltet auf \(model.session?.userName ?? "?")")
        }
        guard model.session?.userName == allowed, let client = model.client,
              let account = model.session?.userID
        else { log("Profil \(allowed) nicht aktiv — Lauf endet"); return nil }
        let hit = await model.search("Mentalist")
        guard let series = hit?.first(where: { $0.type == "Series" && $0.name == "The Mentalist" })
        else { log("keine Serie: \(hit.map { $0.map(\.name) } ?? ["Fehler"])"); return nil }
        let all = await model.episodes(series: series.id, season: nil) ?? []
        var withSections = 0
        for (a, b) in zip(all, all.dropFirst())
        where a.parentIndexNumber == b.parentIndexNumber && (a.parentIndexNumber ?? 0) > 0 {
            let parts = await model.sections(for: a.id)
            if !parts.isEmpty { withSections += 1 }
            guard let intro = parts.first(where: { $0.art == .introSegment || $0.art == .lookBack }),
                  let end = parts.first(where: { $0.art == .credits }) else { continue }
            first = a; second = b; introSegment = intro; credits = end
            break
        }
        guard let first, let second, let introSegment, let credits
        else { log("kein Folgenpaar mit Vorspann und Abspann — \(all.count) Folgen, \(withSections) mit Abschnitten"); return nil }
        for f in [first, second] {
            raw[f.id] = try? await client.userDataRaw(itemID: f.id)
            log("Stand vorher \(f.id) \(String(decoding: raw[f.id] ?? Data(), as: UTF8.self))")
        }
        log("Paar \(first.id) S\(first.parentIndexNumber ?? 0)F\(first.indexNumber ?? 0) → \(second.id) · Vorspann \(introSegment.from)–\(introSegment.until) · Abspann \(credits.from)–\(credits.until)")

        // Download: original, the same source the player would take.
        let new = [first, second].filter { model.downloads.entries(for: $0.id) == nil }
        selfLoaded = new.map(\.id)
        model.downloads.trigger(new.map { f in
            let q = f.mediaSources?.first
            return DownloadItem(
                id: f.id, account: account, art: .episode, title: f.name,
                series: series.name, seriesIdentifier: series.id,
                season: f.parentIndexNumber, episode: f.indexNumber,
                runtimeTicks: f.runTimeTicks, container: q?.container,
                source: q?.id, bytes: q?.size ?? 0,
                watchState: f.userData, videoCodec: q?.videoCodec)
        })
        log("lade \(new.count) (\(new.map { DownloadRules.size($0.mediaSources?.first?.size ?? 0) }))")
        for round in 0..<360 {
            let done = [first, second].allSatisfy { model.downloads.file(for: $0.id) != nil }
            if done { break }
            if round % 6 == 0 {
                let state = [first, second].map { model.downloads.entries(for: $0.id).map { "\($0.state.rawValue) \($0.loaded)/\($0.bytes)" } ?? "—" }
                log("warte auf Downloads: \(state)")
            }
            try? await Task.sleep(for: .seconds(5))
        }
        guard [first, second].allSatisfy({ model.downloads.file(for: $0.id) != nil })
        else { log("Downloads nicht fertig"); return nil }
        // Saving chapters starts after storing; allow a moment.
        try? await Task.sleep(for: .seconds(3))
        state(model, [first, second])

        // **Network off.**
        NetworkLock.an = true
        model.downloads.simulateNetwork(distance: true)
        log("Netz aus")

        let t0 = Date()
        let parts = await model.sections(for: first.id)
        log("offline Abschnitte \(first.id): \(parts.map { "\($0.art.rawValue) \($0.from)–\($0.until)" }) in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
        let t1 = Date()
        let to = await model.episodePost(first)
        log("offline nächste Folge nach \(first.id): \(to?.id ?? "keine") in \(String(format: "%.2f", Date().timeIntervalSince(t1))) s")

        guard let plan = await model.plan(for: first.id) else { log("kein Plan von der Platte"); return nil }
        return PlayRequest(item: first, plan: plan, startAt: introSegment.from + 2)
    }

    static func flow(_ model: AppModel, close: () -> Void) async {
        guard let first, let second, let credits else { return }
        for _ in 0..<60 where !PlayState.running { try? await Task.sleep(for: .seconds(1)) }
        try? await Task.sleep(for: .seconds(5))
        func command(_ b: RemoteCommand, holdOn: Double) async {
            log("Befehl \(b)")
            model.remoteCommand?(b)
            try? await Task.sleep(for: .seconds(holdOn))
        }
        // In the intro "Skip Intro" appears (skip-beat rows).
        await command(.jumpOn(credits.from + 2), holdOn: 6)
        // In the credits "Next Episode" appears, and the command switches.
        await command(.next, holdOn: 10)
        log("läuft jetzt: \(model.runningTitleId ?? "nichts")")
        await command(.jumpOn(600), holdOn: 6)
        await command(.stop, holdOn: 4)
        close()
        try? await Task.sleep(for: .seconds(3))

        log("Nachmeldungen offline: \(model.pendingReportsRun.map { "\($0.itemID) \($0.ticks / 10_000_000) s" })")
        state(model, [first, second])

        // **Network back on**, the same way as in the app: the connectivity check
        // reports afterwards.
        NetworkLock.an = false
        model.downloads.simulateNetwork(distance: false)
        log("Netz an")
        // Twice at once: nothing may arrive twice.
        async let a = model.connectionCheck()
        async let b = model.connectionCheck()
        log("Prüfung: \(await a) / \(await b)")
        log("Nachmeldungen danach: \(model.pendingReportsRun.count)")
        guard let client = model.client else { return }
        await serverState(client, [first, second])

        // **The newer state wins:** a position from an hour ago must not overwrite
        // the one that just arrived.
        model.pendingReportUnderPush(second.id, ticks: 120 * 10_000_000,
                                       moment: Date().addingTimeInterval(-3600))
        await model.pendingSubmit()
        log("ältere Meldung: danach liegen \(model.pendingReportsRun.count)")
        await serverState(client, [second])

        // After reconnecting, the list pulls the server state.
        await model.downloadsCatchUp()
        state(model, [first, second])

        await cleanUp(model)
    }

    private static func state(_ model: AppModel, _ episodes: [Item]) {
        for f in episodes {
            guard let p = model.downloads.entries(for: f.id) else { continue }
            log("Download \(f.id): gesehen \(p.watched) · Stelle \(p.pointTicks.map { "\($0 / 10_000_000) s" } ?? "—") · Abschnitte \(p.sections.map { "\($0.count)" } ?? "nie gefragt")")
        }
    }

    private static func serverState(_ client: JellyfinClient, _ episodes: [Item]) async {
        for f in episodes {
            let afterwards = (try? await client.userDataRaw(itemID: f.id)) ?? Data()
            log("Stand am Server \(f.id) \(String(decoding: afterwards, as: UTF8.self))")
        }
    }

    static func cleanUp(_ model: AppModel) async {
        NetworkLock.an = false
        model.downloads.simulateNetwork(distance: false)
        guard let client = model.client else { return }
        for (id, data) in raw {
            do {
                try await client.userDataBackPut(itemID: id, raw: data)
                let afterwards = try await client.userDataRaw(itemID: id)
                log("zurückgelegt \(id) \(String(decoding: afterwards, as: UTF8.self))")
            } catch {
                log("Zurücklegen fehlgeschlagen \(id): \(error)")
            }
        }
        model.downloads.remove(selfLoaded)
        log("fertig, entfernt \(selfLoaded.count)")
        if let beforeAccount {
            model.switchAccount(toward: beforeAccount)
            log("zurück auf das vorige Konto")
        }
    }
}
#endif
