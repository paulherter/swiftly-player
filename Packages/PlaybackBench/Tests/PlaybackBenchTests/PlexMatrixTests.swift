import AetherEngine
import Foundation
import JellyfinKit
import SwiftlyCore
import Testing

/// **The Plex shape of the bench** (`Werkzeuge/pruefstand-plex.py`, `xtask/src/fixture_plex.rs`): the same real media as the
/// Jellyfin titles, served the way a Plex server answers (stream ids unrelated to the place in the file, `index` = place in
/// the file, an external subtitle with a `key`, the file only with an `X-Plex-Token`, one request per connection).
/// 9001 = bm-multi-mkv (audio 3, SRT, ASS), 9002 = bm-pgs-mkv (resume at 120 s, PGS forced + full, SRT), 9003 = bm-ext-subs.
@Suite(.serialized) @MainActor struct PlexMatrixTests {
    static let account = BenchServer.plex.plexAccount

    private static func source(_ ready: PlayReady) throws -> JellyfinKit.MediaSource {
        let json = try #require(ready.sourceJson)
        return try JSONDecoder().decode(JellyfinKit.MediaSource.self, from: Data(json.utf8))
    }

    /// **Track list = the old app's list** for the same Plex answer: the old `PlexClient.plan` (the shipping Swift line)
    /// and the core's plan name the same streams with the same server number, codec, language, kind and the same place in
    /// the file for the engine.
    @Test(arguments: [9001, 9002, 9003])
    func trackListEqualsTheOldApp(_ key: Int) async throws {
        let id = "\(key)"
        let (ready, answer) = try await Opened.plan(id, account: Self.account)
        let planned = try #require(ready, "no plan: \(answer)")
        let new = try Self.source(planned)
        let identity = PlexIdentity(clientID: "bench-device", product: "Bench", version: "1", platform: "macOS", device: "Mac", deviceName: "Bench")
        let client = PlexClient(baseURL: URL(string: BenchServer.plex.address)!, token: "PLEXTOKEN", identity: identity)
        let old = try #require(try await client.plan(for: id).source)
        func rows(_ s: JellyfinKit.MediaSource) -> [String] {
            (s.mediaStreams ?? []).map { "\($0.type ?? "?")|\($0.codec ?? "")|\($0.language ?? "")|server \($0.index ?? -1)|engine \($0.engineIndex ?? -1)|ext \($0.isExternal == true)" }
        }
        let detail = "old \(rows(old)) new \(rows(new))"
        Record.note("plex-\(key)", "plex track list", rows(old) == rows(new), detail)
        #expect(rows(old) == rows(new), "\(detail)")
        // The core's reduced list (what the player state machine shows) names the same server numbers.
        let listed = planned.start.streams.map(\.index)
        #expect(listed == (new.mediaStreams ?? []).compactMap { $0.index.map(Int64.init) })
    }

    /// The address of a Plex part carries the token (a player cannot set headers) and the title starts: the fixture answers
    /// `401` to a file request without `X-Plex-Token`.
    @Test func partAddressCarriesTheTokenAndPlays() async throws {
        let opened = try await Opened(id: "9001", account: Self.account)
        defer { opened.close() }
        let url = opened.ready.start.url
        let ready = await opened.playing(within: 25)
        let detail = "url \(url), ready \(ready.map { String(format: "%.1f s", $0) } ?? "never"): \(opened.port.failure ?? "-")"
        Record.note("plex-9001", "plex direct play", ready != nil && url.contains("X-Plex-Token=PLEXTOKEN"), detail)
        #expect(url.contains("X-Plex-Token=PLEXTOKEN"), "\(detail)")
        #expect(ready != nil, "\(detail)")
    }

    /// Every subtitle track of a Plex title, picked by its Plex stream id the way the player panel does, shows cues at the
    /// right time: text for SRT / ASS, a picture for PGS (also after the resume at 120 s, the Blu-ray rip shape).
    /// `position` counts the title's subtitle tracks; `needle` is the cue text ("" = a picture). The engine's ACTIVE track must be
    /// the one picked (a forced PGS track that switches itself on would otherwise show a picture for the wrong choice).
    /// (The SRT track of 9002 has one cue at 3 s, before the resume point, so it is not asked for here.)
    @Test(arguments: [(9001, 0, "srt embedded", "Bench"), (9001, 1, "ass embedded", "Bench"),
                      (9002, 0, "pgs forced", ""), (9002, 1, "pgs full", ""),
                      (9003, 0, "srt external", "Bench")] as [(Int, Int, String, String)])
    func subtitleCues(_ key: Int, _ position: Int, _ label: String, _ needle: String) async throws {
        let id = "\(key)"
        let opened = try await Opened(id: id, account: Self.account)
        defer { opened.close() }
        let column = "plex subs: \(label)"
        guard await opened.playing(within: 25) != nil else {
            Record.note(id, column, false, "never played: \(opened.port.failure ?? "-")"); #expect(Bool(false)); return
        }
        _ = await until(10) { !opened.port.subtitleTracks.isEmpty || !opened.ready.start.subtitleFiles.isEmpty }
        let subtitles = opened.ready.start.streams.filter { $0.kind.lowercased() == "subtitle" }
        let chosen = try #require(position < subtitles.count ? subtitles[position] : nil, "no subtitle at \(position)")
        let expected = chosen.isExternal ? nil : BenchTrackNumbers(sourceJson: opened.ready.sourceJson).engine(forServer: Int(chosen.index))
        opened.model.send(.selectSubtitle(index: chosen.index))
        // The pick reaches the engine a moment after `send` (core effect, then the port), and the title's forced track is already
        // on with its cue in view: cues counted before the switch landed belong to the OLD track. Wait for the engine's switch first.
        if let expected { _ = await until(10) { opened.port.engine.activeSubtitleTrackIndex == expected } }
        let seen = await until(25) { opened.port.subtitleCues.contains { cue in
            switch cue.body {
            case .image: return needle.isEmpty
            case .text(let t): return !needle.isEmpty && t.contains(needle)
            case .richText(let runs): return !needle.isEmpty && runs.map(\.text).joined().contains(needle)
            }
        } }
        let rightTrack = expected == nil || opened.port.engine.activeSubtitleTrackIndex == expected
        let detail = "picked Plex id \(chosen.index) (\(chosen.codec ?? "?")); engine tracks \(opened.port.subtitleTracks.map { "\($0.id):\($0.codec)" }), "
            + "active \(String(describing: opened.port.engine.activeSubtitleTrackIndex)), cues \(opened.port.subtitleCues.count), plan startAt \(opened.ready.start.startAt), engine at \(String(format: "%.1f", opened.port.position)) s"
        Record.note(id, column, seen != nil && rightTrack, detail)
        #expect(seen != nil, "\(detail)")
        #expect(rightTrack, "wrong engine track active (wanted \(String(describing: expected))): \(detail)")
    }

    /// Resume deep into the file: the plan starts at the server's `viewOffset` and the engine lands there.
    @Test func resumeStartsAtTheViewOffset() async throws {
        let opened = try await Opened(id: "9002", account: Self.account)
        defer { opened.close() }
        let played = await opened.playing(within: 25)
        let landed = played != nil && opened.port.position >= 119
        let detail = "plan startAt \(opened.ready.start.startAt), engine at \(String(format: "%.1f", opened.port.position)) s"
        Record.note("plex-9002", "plex resume", opened.ready.start.startAt == 120 && landed, detail)
        #expect(opened.ready.start.startAt == 120 && landed, "\(detail)")
    }
}

/// **Plex first load slow** (reported): the time to the first home row against a Plex-shaped fixture that answers every
/// request after 500 ms (long enough that machine noise stays small next to it), one request per connection. One round trip is 0.5 s, so the time divided by 0.5 is the length of the
/// serial request chain. The home page's requests are independent (libraries, continue watching, on deck, recently added per
/// library), so the chain must stay short however many libraries there are.
@Suite(.serialized) @MainActor struct PlexFirstLoadTests {
    @Test func firstHomeRowArrivesInAShortChainOfRoundTrips() async throws {
        let server = try BenchServer(extraEnvironment: ["SWIFTLY_FIXTURE_ONE_REQUEST": "1", "SWIFTLY_FIXTURE_LATENCY_MS": "500"])
        defer { server.process.terminate() }
        let vm = try benchCore().homeVm(account: server.plexAccount, locale: "de")
        let started = Date()
        vm.send(intent: .load)
        let rows = await until(30) { vm.rails().rails.contains { !$0.ids.isEmpty } }
        let elapsed = Date().timeIntervalSince(started)
        let api = try await server.data("/fixture/seen").0
        let list = (try? JSONSerialization.jsonObject(with: api) as? [String]) ?? []
        let detail = String(format: "first row after %.2f s = %.1f round trips of 0.5 s; %d requests: ", elapsed, elapsed / 0.5, list.count)
            + list.filter { !$0.contains("/thumb") && !$0.contains("/art") }.joined(separator: " ")
        Record.note("plex-home", "plex first load", rows != nil && elapsed / 0.5 <= 4.0, detail)
        #expect(rows != nil, "no row: \(detail)")
        #expect(elapsed / 0.5 <= 4.0, "\(detail)")
    }
}
