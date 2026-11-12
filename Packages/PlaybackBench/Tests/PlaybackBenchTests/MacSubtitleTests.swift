import AppKit
import Foundation
import JellyfinKit
import SwiftlyCore
import Testing

/// What the drawn line looks like on the Mac player path (contract lines 11, 14, 15).
extension MacPlayer {
    /// Fill colour (0xRRGGBB, sRGB) and font size of the first visible text layer.
    func drawnLook() -> (rgb: Int, size: CGFloat)? {
        guard let layer = overlayLayer?.sublayers?.compactMap({ $0 as? CATextLayer }).first(where: { !$0.isHidden }),
              let text = layer.string as? NSAttributedString, text.length > 0,
              let colour = (text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB),
              let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else { return nil }
        let byte = { (v: CGFloat) in Int((v * 255).rounded()) }
        return (byte(colour.redComponent) << 16 | byte(colour.greenComponent) << 8 | byte(colour.blueComponent), font.pointSize)
    }

    /// Frame of the first visible text layer, in the overlay's coordinates.
    func drawnFrame() -> CGRect? {
        overlayLayer?.sublayers?.compactMap { $0 as? CATextLayer }.first(where: { !$0.isHidden })?.frame
    }
}

/// **All subtitle tests of the Mac player path run one after the other**: they share the saved look in the defaults
/// (`utAussehen`), which a running overlay follows at once, so a test that changes it must not overlap another.
@Suite(.serialized) @MainActor enum MacSubtitleGroup {
    /// **Subtitles on the real macOS player path**: not "the engine delivers cues" (`FeatureTests`) but "the cue is drawn into the overlay
    /// of the player view".
    @Suite(.serialized) @MainActor struct MacSubtitleTests {
        @Test(arguments: [("bm-multi-mkv", 4, "srt embedded"), ("bm-ext-subs", 2, "srt external file")])
        func panelChoiceDrawsTheCue(_ id: String, _ index: Int, _ label: String) async throws {
            let player = try await MacPlayer(id: id)
            defer { player.close() }
            guard await until(25, { player.playing }) != nil else {
                Record.note(id, "mac overlay: \(label)", false, "never played: \(player.failure ?? "-")"); #expect(Bool(false)); return
            }
            _ = await until(10) { !(player.backend?.request.source.mediaStreams ?? []).isEmpty }
            // What the panel does for a tap on a track (`avSubtitleChosen`).
            let track = player.view.avSubtitleTracks(player.backend!).first { $0.stream?.index == index }
            player.view.avSubtitleChosen(player.backend!, track)
            player.backend?.move(to: 4.2)
            let drawn = await until(10) { player.drawnText().contains { $0.contains("Bench") } }
            // The text must also be VISIBLE: rendered through the layer tree it leaves light pixels (white text on the black surface).
            // A black layer above the overlay (the render surface's backing layer) hides it.
            let light = player.lightPixels()
            let alone = player.lightPixels(of: player.overlayLayer)
            let detail = "drawn \(player.drawnText()), light pixels \(light) (overlay layer alone \(alone)); layers: \(player.overlayState()); engine sub \(String(describing: player.backend?.subtitleIndex))"
            let ok = drawn != nil && alone > 0 && light >= max(1, alone / 2)
            Record.note(id, "mac overlay: \(label)", ok, detail)
            #expect(ok, "\(detail)")
        }
    }

    /// **Contract line 14 on the Mac player path: the cue follows the clock.** `bm-multi-mkv` track 4 has cues 1-3 s, 4-6 s, 7-9 s
    /// ("Bench cue one/two/three"). Each step moves or changes something and reads what the overlay draws.
    @Suite(.serialized) @MainActor struct MacSubtitleTimingTests {
        private func open(_ id: String = "bm-multi-mkv", index: Int = 4) async throws -> MacPlayer? {
            let player = try await MacPlayer(id: id)
            guard await until(25, { player.playing }) != nil else {
                Record.note(id, "mac subs timing", false, "never played: \(player.failure ?? "-")"); #expect(Bool(false)); player.close(); return nil
            }
            _ = await until(10) { !(player.backend?.request.source.mediaStreams ?? []).isEmpty }
            let track = player.view.avSubtitleTracks(player.backend!).first { $0.stream?.index == index }
            player.view.avSubtitleChosen(player.backend!, track)
            return player
        }

        private func shows(_ player: MacPlayer, _ word: String, within seconds: Double = 8) async -> Bool {
            await until(seconds) { player.drawnText().contains { $0.contains(word) } } != nil
        }

        private func hides(_ player: MacPlayer, within seconds: Double = 8) async -> Bool {
            await until(seconds) { player.drawnText().isEmpty } != nil
        }

        @Test func seekPauseSpeedAndDelayKeepTheTextInSync() async throws {
            guard let player = try await open() else { return }
            defer { player.close() }
            let backend = player.backend!
            var steps: [String] = []
            func step(_ name: String, _ ok: Bool) { steps.append("\(name) \(ok ? "ok" : "FAILED")") }

            // Seek forward and back while playing.
            backend.move(to: 7.4)
            step("seek to cue three", await shows(player, "cue three"))
            backend.move(to: 4.4)
            step("seek back to cue two", await shows(player, "cue two"))
            // Seek into a gap: nothing is drawn.
            backend.move(to: 6.4)
            step("gap draws nothing", await hides(player))

            // Pause, then seek while paused: the line still follows the position.
            backend.pause()
            _ = await until(5) { !backend.isPlaying }
            backend.move(to: 4.5)
            step("seek while paused", await shows(player, "cue two"))
            backend.move(to: 1.5)
            step("seek back while paused", await shows(player, "cue one"))
            backend.resume()
            _ = await until(5) { backend.isPlaying }

            // Speed: at 2x the position runs ahead; the cue still matches the clock.
            backend.move(to: 0.5)
            backend.tempo = 2
            step("speed 2x reaches cue one", await shows(player, "cue one"))
            step("speed 2x reaches cue two", await shows(player, "cue two"))
            backend.tempo = 1

            // Delay: +2 s shows each cue 2 s later, so at 7.5 s the line is cue two (4-6 s cue + 2 s).
            backend.pause()
            _ = await until(5) { !backend.isPlaying }
            backend.subtitleDelay = Delay(milliseconds: 2000)
            backend.move(to: 7.5)
            step("delay +2 s", await shows(player, "cue two"))
            backend.subtitleDelay = Delay(milliseconds: -2000)
            backend.move(to: 2.5)
            step("delay -2 s (cue two starts 2 s early)", await shows(player, "cue two"))
            backend.subtitleDelay = Delay(milliseconds: 0)
            backend.move(to: 2.5)
            step("delay back to 0", await shows(player, "cue one"))

            let ok = !steps.contains { $0.hasSuffix("FAILED") }
            Record.note("bm-multi-mkv", "mac subs timing", ok, steps.joined(separator: "; "))
            #expect(ok, "\(steps.joined(separator: "; "))")
        }
    }

    /// **Contract line 11 on the Mac player path: the saved look is used from the first picture, and a running player follows a change
    /// at once.** The look is read from the store (the sync writes `utAussehen` there).
    @Suite(.serialized) @MainActor struct MacSubtitleLookTests {
        private func play(look: SubtitleLook) async throws -> MacPlayer? {
            UserDefaults.standard.set(look.encoded(), forKey: "utAussehen")
            let player = try await MacPlayer(id: "bm-multi-mkv")
            guard await until(25, { player.playing }) != nil else {
                Record.note("bm-multi-mkv", "mac subs look", false, "never played"); #expect(Bool(false)); player.close(); return nil
            }
            _ = await until(10) { !(player.backend?.request.source.mediaStreams ?? []).isEmpty }
            let track = player.view.avSubtitleTracks(player.backend!).first { $0.stream?.index == 4 }
            player.view.avSubtitleChosen(player.backend!, track)
            player.backend?.move(to: 4.2)
            return player
        }

        @Test func lookIsAppliedFromTheFirstPlayAndFollowsAChangeAtOnce() async throws {
            defer { UserDefaults.standard.removeObject(forKey: "utAussehen") }
            // 1. The look was saved BEFORE the player was made (settings arrived from another device during sign-in).
            guard let player = try await play(look: SubtitleLook(size: .huge, colour: .yellow, outline: .normal)) else { return }
            defer { player.close() }
            _ = await until(10) { player.drawnText().contains { $0.contains("Bench") } }
            let first = player.drawnLook()
            let firstOK = first?.rgb == SubtitleLook.Colour.yellow.rgb
            // 2. A change while the title plays (sync or the settings page): white, small.
            UserDefaults.standard.set(SubtitleLook(size: .small, colour: .white, outline: .normal).encoded(), forKey: "utAussehen")
            let followed = await until(3) { player.drawnLook()?.rgb == SubtitleLook.Colour.white.rgb }
            let second = player.drawnLook()
            let smaller = (second?.size ?? .greatestFiniteMagnitude) < (first?.size ?? 0)
            let detail = "first \(String(describing: first)), after change \(String(describing: second)), followed in \(followed.map { String(format: "%.2f s", $0) } ?? "never")"
            let ok = firstOK && followed != nil && smaller
            Record.note("bm-multi-mkv", "mac subs look", ok, detail)
            #expect(ok, "\(detail)")
        }
    }

    /// **Contract line 15 on the Mac player path: the text stays above the picture when the window changes size or the picture is
    /// filled**, 16 pt above the bottom of the picture.
    @Suite(.serialized) @MainActor struct MacSubtitleFullScreenTests {
        @Test func textStaysAboveThePictureAtOtherSizes() async throws {
            UserDefaults.standard.removeObject(forKey: "utAussehen")
            let player = try await MacPlayer(id: "bm-multi-mkv")
            defer { player.close() }
            guard await until(25, { player.playing }) != nil else {
                Record.note("bm-multi-mkv", "mac subs full screen", false, "never played"); #expect(Bool(false)); return
            }
            _ = await until(10) { !(player.backend?.request.source.mediaStreams ?? []).isEmpty }
            let track = player.view.avSubtitleTracks(player.backend!).first { $0.stream?.index == 4 }
            player.view.avSubtitleChosen(player.backend!, track)
            player.backend?.move(to: 4.2)
            var notes: [String] = []
            for size in [CGSize(width: 640, height: 360), CGSize(width: 1920, height: 1080), CGSize(width: 1000, height: 700)] {
                player.window.setContentSize(size)
                player.view.frame = CGRect(origin: .zero, size: size)
                player.view.layoutSubtreeIfNeeded()
                player.backend?.place(in: player.view.bounds)
                let drawn = await until(8) { player.drawnText().contains { $0.contains("Bench") } && player.drawnFrame() != nil }
                let frame = player.drawnFrame()
                // The test clip is 16:9: at 1000 x 700 the picture is 1000 x 562.5 and centred, so its bottom edge is 68.75 up.
                let picture = AVMakeRectLike(size)
                let gap = (frame?.minY ?? -1) - picture.minY
                let inside = frame.map { picture.contains($0.insetBy(dx: 0, dy: 0.5)) } ?? false
                let fine = drawn != nil && abs(gap - 16) < 1.5 && inside
                notes.append("\(Int(size.width))x\(Int(size.height)): gap \(String(format: "%.1f", gap)) inside \(inside) \(fine ? "ok" : "FAILED")")
            }
            player.backend?.fill(true)
            let filled = await until(5) { player.drawnFrame().map { $0.minY >= 0 && $0.maxY <= player.view.bounds.height } ?? false }
            notes.append("fill picture: text inside the view \(filled != nil)")
            let ok = !notes.contains { $0.contains("FAILED") } && filled != nil
            Record.note("bm-multi-mkv", "mac subs full screen", ok, notes.joined(separator: "; "))
            #expect(ok, "\(notes.joined(separator: "; "))")
        }

        /// Where a 16:9 picture sits in a view of `size` (aspect-fit, centred); AppKit coordinates (origin bottom left).
        private func AVMakeRectLike(_ size: CGSize) -> CGRect {
            let height = min(size.height, size.width * 9 / 16)
            let width = height * 16 / 9
            return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
        }
    }


}

/// **The Mac writes its file log in every build** (the Release candidate wrote none, so nobody could read a failed run).
/// Meaningful only in a release configuration: `swift test -c release -Xswiftc -enable-testing` (debug builds always log).
@MainActor struct MacLogTests {
    @Test func appLogWritesTheFileInThisBuild() throws {
        let marker = "[Test] log marker \(UUID().uuidString)"
        AppLog.writeOut(marker)
        let text = (try? String(contentsOf: AppLog.path, encoding: .utf8)) ?? ""
        let configuration: String
        #if DEBUG
        configuration = "debug"
        #else
        configuration = "release"
        #endif
        Record.note("mac-log", "file log (\(configuration))", text.contains(marker), AppLog.path.path)
        #expect(text.contains(marker), "no line in \(AppLog.path.path) (\(configuration) build)")
    }
}

/// **"Adults" loaded forever on the Mac**: a file without a header duration, played the way the Mac screen starts a title.
/// Either it plays within seconds, or the screen is told (`startErrorReported` / `fileFailed`) within seconds. Never silence.
@Suite(.serialized) @MainActor struct MacStartTests {
    @Test func headerlessMkvFromTheServerPlaysOrReportsWithinSeconds() async throws {
        let id = "bm-noduration-mkv"
        let player = try await MacPlayer(id: id)
        defer { player.close() }
        let settled = await until(12) { player.playing || player.failure != nil }
        let detail = "playing \(player.playing), failure \(player.failure ?? "-") after \(player.failedAfter.map { String(format: "%.1f s", $0) } ?? "-"), "
            + "state \(String(describing: player.backend?.transportNow.phase))"
        Record.note(id, "mac start: stream", settled != nil, detail)
        #expect(settled != nil, "neither playing nor reported within 12 s: \(detail)")
    }

    /// The download of that file (no duration in the header, stored runtime known): plays, or the screen plays the stream.
    @Test func headerlessMkvDownloadPlaysOrFallsBackWithinSeconds() async throws {
        let id = "bm-noduration-mkv"
        let file = try await DownloadTests.store("/Videos/\(id)/stream?static=true", name: "\(id).mac.mkv")
        let player = try await MacPlayer(id: id, downloaded: file)
        defer { player.close() }
        let settled = await until(12) { player.playing || player.fellBackToStream }
        let detail = "playing \(player.playing), fell back \(player.fellBackToStream) after \(player.failedAfter.map { String(format: "%.1f s", $0) } ?? "-"), failure \(player.failure ?? "-")"
        Record.note(id, "mac start: download", settled != nil, detail)
        #expect(settled != nil, "neither playing nor fell back within 12 s: \(detail)")
    }

    /// The reported beta case: a download rebuilt to ONE audio track (no duration in its header), with several tracks in the title.
    @Test func rebuiltSingleAudioDownloadPlaysOrFallsBackWithinSeconds() async throws {
        let id = "bm-multi-mkv"
        let file = try await DownloadTests.store("/Videos/\(id)/stream.mkv?static=false&container=mkv&audioStreamIndex=2", name: "\(id).mac.single.mkv")
        let player = try await MacPlayer(id: id, downloaded: file)
        defer { player.close() }
        let settled = await until(12) { player.playing || player.fellBackToStream }
        let detail = "playing \(player.playing), fell back \(player.fellBackToStream) after \(player.failedAfter.map { String(format: "%.1f s", $0) } ?? "-"), failure \(player.failure ?? "-")"
        Record.note(id, "mac start: rebuilt download", settled != nil, detail)
        #expect(settled != nil, "neither playing nor fell back within 12 s: \(detail)")
    }

    /// A stored file that cannot be opened at all falls back to the stream within seconds (the screen's `fileFailed`).
    @Test func unreadableDownloadFallsBackToTheStreamWithinSeconds() async throws {
        let id = "bm-noduration-mkv"
        let dir = FileManager.default.temporaryDirectory.appending(path: "pbench-downloads")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "\(id).broken.mkv")
        try Data(repeating: 0x42, count: 4096).write(to: file)
        let player = try await MacPlayer(id: id, downloaded: file)
        defer { player.close() }
        let settled = await until(15) { player.fellBackToStream }
        let detail = "fell back \(player.fellBackToStream) after \(player.failedAfter.map { String(format: "%.1f s", $0) } ?? "-"): \(player.failure ?? "-")"
        Record.note(id, "mac start: broken download", settled != nil, detail)
        #expect(settled != nil, "no fallback within 15 s: \(detail)")
    }
}

/// **Every player screen must be able to say that a start failed** (`startErrorReported`) and must not wait forever for the first
/// picture. The Mac screen had neither: a title that could not start showed the spinner for ever. Reads the screens' sources.
struct PlayerScreenStartGuard {
    private static var root: URL { BenchServer.root }

    @Test(arguments: ["iOS", "macOS", "tvOS"])
    func screenReportsAndTimesOutAFailedStart(_ platform: String) throws {
        let url = Self.root.appending(path: "Sources/\(platform)/PlayerScreen.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let takesReport = text.contains("startErrorReported")
        let hasTimeout = text.contains("PlayerStartTimeout.seconds")
        Record.note("screen-\(platform)", "start failure shown", takesReport && hasTimeout,
                    "startErrorReported \(takesReport), timeout \(hasTimeout)")
        #expect(takesReport, "\(platform) PlayerScreen never reads startErrorReported: a failed start shows the spinner for ever")
        #expect(hasTimeout, "\(platform) PlayerScreen has no start timeout")
    }
}
