import AVFoundation
import AetherEngine
import CoreImage
import Foundation
import SwiftlyCore
import Testing

/// HDR / Dolby Vision / AV1 10-bit titles of the media matrix (`Werkzeuge/pruefstand-medien.py`). They run through the same
/// plan / ready / duration / frame / seek / end / download checks as every title (`benchTitles`), and here also the pixel check.
let hdrTitles = [
    "bm-hdr10-mp4", "bm-hdr10-mkv", "bm-hlg-mkv", "bm-dv5-mp4", "bm-dv5-mkv", "bm-dv81-mp4", "bm-dv81-mkv",
    "bm-dv10-mp4", "bm-dv10-mkv", "bm-av110-mp4", "bm-av110-mkv",
]

/// What the decoded picture looks like, measured in RGB: the numbers that tell a green, black or white picture from a good one.
struct FrameStats: CustomStringConvertible {
    var meanLuma: Double
    var lumaSpread: Double
    var greenShare: Double      // pixels where green clearly dominates (the wrong-colour-space look)
    var litBottom: Double       // share of bright pixels in the bottom third (a burned-in subtitle bar)
    var source: String
    var description: String {
        String(format: "luma %.2f spread %.2f green %.2f bottom-bright %.3f via %@", meanLuma, lumaSpread, greenShare, litBottom, source)
    }
    /// Not black, not white, not flat, not mostly green.
    var looksRight: Bool { meanLuma > 0.08 && meanLuma < 0.92 && lumaSpread > 0.05 && greenShare < 0.45 }

    init?(_ image: CGImage, source: String) {
        let w = 160, h = 90
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var sum = 0.0, sumSq = 0.0, green = 0, bright = 0
        for i in 0..<(w * h) {
            let r = Double(px[i * 4]), g = Double(px[i * 4 + 1]), b = Double(px[i * 4 + 2])
            let y = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
            sum += y; sumSq += y * y
            if g > r + 40, g > b + 40 { green += 1 }
            if i / w >= h * 2 / 3, y > 0.8 { bright += 1 }   // CGContext rows run bottom-up: the first rows are the bottom of the picture
        }
        let n = Double(w * h)
        meanLuma = sum / n
        lumaSpread = max(sumSq / n - (sum / n) * (sum / n), 0).squareRoot()
        greenShare = Double(green) / n
        litBottom = Double(bright) / (n / 3)
        self.source = source
    }
}

/// A frame of what the engine plays: the pixels of the playing AVPlayer item (native route), else the engine's own frame
/// extractor (software route, which has no AVPlayer item).
@MainActor
func grabFrame(_ opened: Opened) async -> FrameStats? {
    let engine = opened.port.engine
    if let item = engine.currentAVPlayer?.currentItem {
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        defer { item.remove(output) }
        for _ in 0..<40 {
            let time = item.currentTime()
            if output.hasNewPixelBuffer(forItemTime: time), let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                let context = CIContext()
                if let image = context.createCGImage(CIImage(cvPixelBuffer: buffer), from: CIImage(cvPixelBuffer: buffer).extent) {
                    return FrameStats(image, source: "AVPlayerItemVideoOutput")
                }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
    if let image = await engine.scrubThumbnail(atSeconds: opened.port.position, maxWidth: 320) {
        return FrameStats(image, source: "engine frame extractor")
    }
    return nil
}

@Suite(.serialized) @MainActor struct PictureTests {
    /// **Column "picture"**: the frame the engine decodes is a real picture (not green, black, white or flat).
    @Test(arguments: hdrTitles)
    func decodedFrameIsAPicture(_ id: String) async throws {
        let opened = try await Opened(id: id)
        defer { opened.close() }
        guard await opened.playing(within: 25) != nil else {
            Record.note(id, "picture", false, "never played: \(opened.port.failure ?? "-")")
            #expect(Bool(false), "\(id) did not play"); return
        }
        _ = await until(5) { opened.port.position > 1.0 }
        let stats = await grabFrame(opened)
        let ok = stats?.looksRight ?? false
        Record.note(id, "picture", ok, stats.map(\.description) ?? "no frame could be read")
        #expect(ok, "\(stats?.description ?? "no frame")")
    }
}

/// A server transcode (HLS) of a title the core refuses to play as it is, or that is above the bitrate limit.
@Suite(.serialized) @MainActor struct TranscodeTests {
    /// The core's plan: DV 10.0 is a transcode on every route (AVPlayer: green picture; the Mac engine: refuses the title in
    /// software); a title above the bitrate limit is a transcode on every route.
    @Test func planChoosesTheServerTranscode() async throws {
        var failures: [String] = []
        func method(_ ready: PlayReady?) -> String {
            guard let ready else { return "no plan" }
            switch ready.start.method { case .directPlay: return "directPlay"; case .directStream: return "directStream"; case .transcode: return "transcode" }
        }
        for (id, flavour, expected) in [
            ("bm-dv100-transcode", PlayFlavour.avPlayer, "transcode"), ("bm-dv100-transcode", .avPlayerAv1, "transcode"),
            ("bm-dv100-transcode", .aether, "transcode"),   // the Mac engine refuses it on a Mac without hardware AV1
            ("bm-limit-transcode", .aether, "transcode"), ("bm-limit-transcode", .avPlayer, "transcode"),
            // the plain DV 10.0 title is offered a transcode too (hosts without AV1 hardware ask for one); the fixture
            // answers it from the same HLS folder as bm-dv100-transcode
            ("bm-dv100-mkv", .avPlayer, "transcode"),
        ] {
            let (ready, _) = try await Opened.plan(id, flavour: flavour)
            let got = method(ready)
            let url = ready?.start.url ?? ""
            let folder = id == "bm-dv100-mkv" ? "bm-dv100-transcode" : id
            if got != expected || (expected == "transcode" && !url.contains("/videos/\(folder)/master.m3u8")) { failures.append("\(id)/\(flavour): \(got) \(url)") }
        }
        Record.note("transcode-plan", "plan", failures.isEmpty, failures.isEmpty ? "DV 10.0 transcodes on every route; bitrate limit transcodes" : failures.joined(separator: "; "))
        #expect(failures.isEmpty, "\(failures)")
    }

    /// The HLS the server made plays in the real engine; the burned-in bitmap subtitle is in the picture at 2 to 4 s, not later.
    @Test(arguments: [("bm-dv100-transcode", PlayFlavour.aether, true), ("bm-limit-transcode", PlayFlavour.aether, false)])
    func hlsPlaysAndShowsWhatItShould(_ id: String, _ flavour: PlayFlavour, _ burned: Bool) async throws {
        let opened = try await Opened(id: id, flavour: flavour)
        defer { opened.close() }
        var problems: [String] = []
        func check(_ column: String, _ ok: Bool, _ detail: String) {
            Record.note(id, column, ok, detail)
            if !ok { problems.append("\(column): \(detail)") }
        }
        let ready = await opened.playing(within: 30)
        check("ready", ready != nil, ready.map { String(format: "%.1f s, \(opened.ready.start.url.suffix(40))", $0) } ?? "no playing state/first frame: \(opened.port.failure ?? "-")")
        guard ready != nil else { #expect(Bool(false), "\(problems)"); return }
        _ = await until(6) { opened.port.duration > 0 }
        check("duration", abs(opened.port.duration - 10) < 0.7, String(format: "engine %.2f s", opened.port.duration))
        // At about 3 s the burned-in bar is in the picture (the bitmap track burned by the server); the text-subtitle title has none.
        _ = await until(8) { opened.port.position > 2.4 }
        let early = await grabFrame(opened)
        check("picture", early?.looksRight ?? false, early.map(\.description) ?? "no frame")
        if burned, let early {
            check("burned subtitle", early.litBottom > 0.02, "bar at 2-4 s: \(early)")
        }
        opened.model.send(.seekTo(seconds: 6))
        let landed = await until(10) { abs(opened.port.position - 6) < 1.5 || opened.port.position > 6 }
        let moving = await opened.advances(by: 0.5)
        check("seek", landed != nil && moving, "after seek to 6 s: \(String(format: "%.1f", opened.port.position)) s")
        opened.model.send(.seekTo(seconds: 9))
        let ended = await until(15) { opened.port.ended }
        check("end", ended != nil, "state \(opened.port.state), position \(String(format: "%.1f", opened.port.position)) s")
        #expect(problems.isEmpty, "\(problems)")
    }
}

/// DV 10.0 as the plain file (no transcode on offer): the Mac engine plays it only where AV1 has hardware decode (M3 and newer);
/// elsewhere it refuses with its own message. Either is a clear answer; a frozen or green picture would not be.
@Suite(.serialized) @MainActor struct Dv10DirectTests {
    @Test func plainFileEitherPlaysOrRefusesWithAMessage() async throws {
        let opened = try await Opened(id: "bm-dv100-mkv")
        defer { opened.close() }
        let played = await opened.playing(within: 25)
        if played != nil, let stats = await grabFrame(opened) {
            Record.note("bm-dv100-mkv", "picture", stats.looksRight, stats.description)
            #expect(stats.looksRight, "\(stats)")
        } else {
            let message = opened.port.failure ?? ""
            Record.known("bm-dv100-mkv", "picture", "this Mac has no hardware AV1: engine refuses, plan asks the server for a transcode instead: \(message.prefix(90))")
            #expect(message.contains("Dolby Vision"), "refused without a message: \(message)")
        }
    }
}
