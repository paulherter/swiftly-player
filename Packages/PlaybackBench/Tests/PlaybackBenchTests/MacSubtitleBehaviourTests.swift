import AppKit
@testable import AetherEngine
import CoreVideo
import Foundation
import JellyfinKit
import SwiftlyCore
import Testing

/// Contract lines 13 and 15 on the Mac player path.
extension MacSubtitleGroup {
    /// **Line 13: choosing, switching and turning off work during playback, and the choice is remembered per title.**
    @Suite(.serialized) @MainActor struct MacSubtitleChoiceTests {
        @Test func turningOffAndSwitchingWorkAndAreRemembered() async throws {
            UserDefaults.standard.removeObject(forKey: "utJeTitel")
            defer { UserDefaults.standard.removeObject(forKey: "utJeTitel") }
            let id = "bm-multi-mkv"
            let player = try await MacPlayer(id: id)
            defer { player.close() }
            guard await until(25, { player.playing }) != nil else {
                Record.note(id, "mac subs choice", false, "never played"); #expect(Bool(false)); return
            }
            _ = await until(10) { !(player.backend?.request.source.mediaStreams ?? []).isEmpty }
            let backend = player.backend!
            let streams = backend.request.source.mediaStreams ?? []
            let key = StartTracks.key(for: player.item, account: "u1")
            // The player screen hands the title's key to the view after `play` (`wendeLanguagesAn`); a hand choice is
            // remembered under it.
            player.view.trackTitle = key
            func remembered() -> Int {
                StartTracks.choose(streams: streams, defaultAudio: nil, defaultSubtitle: nil, audioLanguage: "eng",
                                   subtitleLanguage: "", automatic: false, title: key, ordered: nil).subtitle
            }
            func pick(_ index: Int?) {
                let track = index.flatMap { i in player.view.avSubtitleTracks(backend).first { $0.stream?.index == i } }
                player.view.avSubtitleChosen(backend, track)
            }
            var steps: [String] = []
            func step(_ name: String, _ ok: Bool) { steps.append("\(name) \(ok ? "ok" : "FAILED")") }

            pick(4); backend.move(to: 4.2)
            step("srt shows", await until(8) { player.drawnText().contains { $0.contains("Bench") } } != nil)
            step("srt remembered (got \(remembered()), memory \(UserDefaults.standard.dictionary(forKey: "utJeTitel") ?? [:]))", remembered() == 4)

            pick(nil)
            step("off clears the line", await until(5) { player.drawnText().isEmpty } != nil)
            step("engine index off", backend.subtitleIndex == -1)
            backend.move(to: 7.4)
            try await Task.sleep(for: .seconds(1.5))
            step("off stays off at the next cue", player.drawnText().isEmpty)
            step("off remembered", remembered() == -1)

            pick(5); backend.move(to: 4.4)
            step("ass shows after off", await until(8) { player.drawnText().contains { $0.contains("Bench ass") } } != nil)
            step("ass remembered (got \(remembered()))", remembered() == 5)

            pick(4); backend.move(to: 4.4)
            step("switch back to srt", await until(8) { backend.subtitleIndex == 4 && player.drawnText().contains { $0.contains("Bench cue") } } != nil)
            step("srt remembered again", remembered() == 4)
            let ok = !steps.contains { $0.hasSuffix("FAILED") }
            Record.note(id, "mac subs choice", ok, steps.joined(separator: "; "))
            #expect(ok, "\(steps.joined(separator: "; "))")
        }
    }

    /// **Line 14, quality change: the reload keeps the chosen track and the delay, and the line matches the clock.** The screen's
    /// quality choice plays the same title again from the current position (`VLCPlayerView.play`, the old engine is replaced).
    @Suite(.serialized) @MainActor struct MacSubtitleQualityChangeTests {
        @Test func reloadAtTheSamePositionKeepsTrackDelayAndTiming() async throws {
            UserDefaults.standard.removeObject(forKey: "utJeTitel")
            defer { UserDefaults.standard.removeObject(forKey: "utJeTitel") }
            let id = "bm-multi-mkv"
            let player = try await MacPlayer(id: id)
            defer { player.close() }
            guard await until(25, { player.playing }) != nil else {
                Record.note(id, "mac subs quality change", false, "never played"); #expect(Bool(false)); return
            }
            _ = await until(10) { !(player.backend?.request.source.mediaStreams ?? []).isEmpty }
            player.view.trackTitle = StartTracks.key(for: player.item, account: "u1")
            let first = player.backend!
            player.view.avSubtitleChosen(first, player.view.avSubtitleTracks(first).first { $0.stream?.index == 4 })
            player.view.subtitleDelay = Delay(milliseconds: 2000)
            // The quality change: the same title, started again at the position it had.
            let files = SubtitleFile.forAVPlayer(
                streams: player.plan.source?.mediaStreams ?? [], itemID: id, source: player.plan.mediaSourceID,
                server: URL(string: BenchServer.shared.address)!, key: "TOKEN", keyName: "ApiKey", serverExtracts: true)
            player.view.coreQualityWish = true
            player.view.play(url: player.plan.url, offSeconds: 3.5, container: player.plan.container, subtitle: files)
            guard await until(25, { player.playing && player.backend !== first }) != nil, let second = player.backend else {
                Record.note(id, "mac subs quality change", false, "reload never played"); #expect(Bool(false)); return
            }
            // Cues 1-3, 4-6, 7-9 s, delay +2 s: they show at 3-5, 6-8, 9-11 s. At 3.5 s that is cue one.
            _ = await until(10) { !(second.request.source.mediaStreams ?? []).isEmpty }
            var steps: [String] = []
            func step(_ name: String, _ ok: Bool) { steps.append("\(name) \(ok ? "ok" : "FAILED")") }
            step("new engine, not the old one", second !== first)
            step("same track (got \(second.subtitleIndex))", await until(8) { second.subtitleIndex == 4 } != nil)
            step("delay kept (\(second.subtitleDelay.milliseconds) ms)", second.subtitleDelay.milliseconds == 2000)
            second.move(to: 3.8)
            step("cue one at 3.8 s with +2 s", await until(8) { player.drawnText().contains { $0.contains("cue one") } } != nil)
            second.move(to: 5.5)
            step("gap at 5.5 s", await until(8) { player.drawnText().isEmpty } != nil)
            second.move(to: 6.6)
            step("cue two at 6.6 s", await until(8) { player.drawnText().contains { $0.contains("cue two") } } != nil)
            let ok = !steps.contains { $0.hasSuffix("FAILED") }
            Record.note(id, "mac subs quality change", ok, steps.joined(separator: "; "))
            #expect(ok, "\(steps.joined(separator: "; "))")
        }
    }

    /// **Line 15, Picture in Picture on the software route: the picture handed to the window carries the cue.** The window shows only
    /// the sample-buffer layer, so the engine draws the active cue into the frames while `pictureInPictureSubtitles(true)` is on.
    /// The frame comes from the running engine (`SoftwarePlaybackHost.displayedFrame`), the cues are the ones it delivered for the chosen
    /// track, and the engine's own compositor draws them: pixels changed in the lower third with a cue up, none with the window off,
    /// in a gap, or before a delayed cue starts. (The engine does not give the composited frame back after it enqueues it, so the
    /// wiring from the flag to the layer is not read back.)
    @Suite(.serialized) @MainActor struct MacSubtitlePiPTests {
        /// Luma of every pixel of the lower third (rows from 2/3 of the height), row by row.
        static func lowerThirdLuma(_ buffer: CVPixelBuffer) -> [UInt8] {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let planar = CVPixelBufferIsPlanar(buffer)
            let width = planar ? CVPixelBufferGetWidthOfPlane(buffer, 0) : CVPixelBufferGetWidth(buffer)
            let height = planar ? CVPixelBufferGetHeightOfPlane(buffer, 0) : CVPixelBufferGetHeight(buffer)
            let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
            guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer) else { return [] }
            let format = CVPixelBufferGetPixelFormatType(buffer)
            let wide = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            var out: [UInt8] = []
            for y in (height * 2 / 3)..<height {
                let row = base.advanced(by: y * stride)
                for x in 0..<width {
                    if planar {
                        out.append(wide ? UInt8(row.load(fromByteOffset: x * 2, as: UInt16.self) >> 8) : row.load(fromByteOffset: x, as: UInt8.self))
                    } else {
                        let p = row.advanced(by: x * 4).assumingMemoryBound(to: UInt8.self)   // BGRA
                        out.append(UInt8((Int(p[0]) + Int(p[1]) + Int(p[2])) / 3))
                    }
                }
            }
            return out
        }

        /// How many pixels of the lower third differ clearly (luma by more than 40) between the plain frame and the one handed to the window.
        static func changedPixels(_ plain: CVPixelBuffer, _ handed: CVPixelBuffer) -> Int {
            let a = lowerThirdLuma(plain), b = lowerThirdLuma(handed)
            guard a.count == b.count, !a.isEmpty else { return -1 }
            return zip(a, b).reduce(0) { $0 + (abs(Int($1.0) - Int($1.1)) > 40 ? 1 : 0) }
        }

        @Test func softwareRouteFramesCarryTheCueWhileThePictureInPictureWindowIsOpen() async throws {
            let id = "bm-ext-subs"
            AetherEngine.setForceSoftwarePathForTesting(true)
            defer { AetherEngine.setForceSoftwarePathForTesting(false) }
            let player = try await MacPlayer(id: id)
            defer { player.close() }
            guard await until(25, { player.playing }) != nil else {
                Record.note(id, "pip subs (software route)", false, "never played: \(player.failure ?? "-")"); #expect(Bool(false)); return
            }
            _ = await until(10) { !(player.backend?.request.source.mediaStreams ?? []).isEmpty }
            let backend = player.backend!
            let track = player.view.avSubtitleTracks(backend).first { $0.stream?.index == 2 }
            player.view.avSubtitleChosen(backend, track)
            guard let running = backend.runningEngine, let host = running.aether.softwareHost else {
                Record.note(id, "pip subs (software route)", false, "not on the software route"); #expect(Bool(false)); return
            }
            _ = await until(10) { !running.aether.subtitleCues.isEmpty }
            // The frame the engine hands over, and the engine's own cues of the chosen track at the clip's cue times.
            _ = await until(10) { host.displayedFrame() != nil }
            backend.move(to: 1.0)
            guard let frame = host.displayedFrame() else {
                Record.note(id, "pip subs (software route)", false, "no frame"); #expect(Bool(false)); return
            }
            let cues = running.aether.subtitleCues
            let compositor = SubtitleFrameCompositor(styleProvider: { .standard }, observesSystemStyle: false)
            compositor.update(cues: cues, enabled: false, delaySeconds: 0)
            let off = Self.changedPixels(frame, compositor.composite(frame, ptsSeconds: 4.5))
            running.pictureInPictureSubtitles(true)
            let flagged = running.aether.pictureInPictureActive
            compositor.update(cues: cues, enabled: flagged, delaySeconds: 0)
            let atCue = Self.changedPixels(frame, compositor.composite(frame, ptsSeconds: 4.5))
            let inGap = Self.changedPixels(frame, compositor.composite(frame, ptsSeconds: 6.5))
            // A delay of +2 s moves the cues (1-3, 4-6, 7-9 s) to 3-5, 6-8, 9-11 s: 7.5 s shows cue two, 5.5 s is a gap.
            backend.subtitleDelay = Delay(milliseconds: 2000)
            _ = await until(5) { running.aether.softwareSubtitleDelaySeconds == 2 }
            let forwarded = running.aether.softwareSubtitleDelaySeconds
            compositor.update(cues: cues, enabled: true, delaySeconds: forwarded)
            let delayed = Self.changedPixels(frame, compositor.composite(frame, ptsSeconds: 7.5))
            let betweenDelayed = Self.changedPixels(frame, compositor.composite(frame, ptsSeconds: 5.5))
            running.pictureInPictureSubtitles(false)
            let closed = running.aether.pictureInPictureActive
            let ok0 = flagged && !closed && forwarded == 2
            let detail = "\(cues.count) cues; pixels changed in the lower third: window off at cue \(off), open at cue \(atCue), in a gap \(inGap), delay +2 s at 7.5 s \(delayed) and 0 expected at 5.5 s \(betweenDelayed); flag on/off \(flagged)/\(closed), delay forwarded \(forwarded)"
            let ok = ok0 && off == 0 && atCue > 100 && inGap == 0 && delayed > 100 && betweenDelayed == 0
            Record.note(id, "pip subs (software route)", ok, detail)
            #expect(ok, "\(detail)")
        }
    }
}
