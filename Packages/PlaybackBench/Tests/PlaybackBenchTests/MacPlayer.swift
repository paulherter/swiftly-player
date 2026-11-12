import AppKit
import Foundation
import JellyfinKit
import SwiftlyCore

/// **The macOS player path without the screen around it.** `VLCPlayerView` (the view `MacVideoSurface` makes), the real
/// `trackRequest` the Mac `PlayerScreen` builds, `VLCPlayerView.play`, then `CorePlaybackBackend` -> `CoreAetherPort` ->
/// `AetherPlayerEngine` -> `SubtitleOverlay`, all from the app's own sources (`AppFiles/`). Only `AppModel`/`AppCore` are
/// stand-ins (`AppStubs.swift`). The view sits in an AppKit window that is never shown.
@MainActor
final class MacPlayer {
    let view = VLCPlayerView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
    let window: NSWindow
    let app = AppModel()
    let plan: PlaybackPlan
    let item: Item
    let engineRequest: EngineRequest
    private(set) var failure: String?
    private(set) var failedAfter: Double?
    /// What the screen does with a file that does not open (`fileFailed`): play the stream instead.
    private(set) var fellBackToStream = false
    private(set) var firstFrame = false
    let openedAt = Date()
    var backend: CorePlaybackBackend? { view.avEngine as? CorePlaybackBackend }

    /// `subtitle`/`automatic`: the Mac settings (language of the wish, "only when the audio is not in it").
    init(id: String, audio: String = "eng", subtitle: String = "", automatic: Bool = false,
         downloaded file: URL? = nil, keepFileStyle: Bool = false) async throws {
        let core = AppCore.shared.raw
        let account = BenchServer.shared.account
        guard case .plan(let planned) = await PlanFromCore.plan(
            core: core, account: account, itemID: id, sourceID: nil, maxBitrate: 120_000_000, locale: "de")
        else { throw NSError(domain: "bench", code: 2, userInfo: [NSLocalizedDescriptionKey: "no plan for \(id)"]) }
        plan = planned
        let itemFile = URL(filePath: BenchServer.shared.media).appending(path: "\(id).item.json")
        item = try JSONDecoder().decode(Item.self, from: Data(contentsOf: itemFile))
        let server = URL(string: BenchServer.shared.address)!
        // `AppModel.engineRequest(for:plan:)`, line for line (Sources/Shared/AppModel+Engine.swift).
        let files = SubtitleFile.forAVPlayer(
            streams: planned.source?.mediaStreams ?? [], itemID: id, source: planned.mediaSourceID,
            server: server, key: "TOKEN", keyName: "ApiKey", serverExtracts: true,
            keepFileStyle: keepFileStyle)
        engineRequest = EngineRequest(itemID: id, source: planned.source!, subtitleFiles: files,
                                      transcoded: planned.method == .transcode)
        window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.startErrorReported = { [weak self] reason in
            guard let self else { return }
            failure = reason
            failedAfter = Date().timeIntervalSince(openedAt)
        }
        view.fileFailed = { [weak self] reason in
            guard let self, file != nil else { return false }
            fellBackToStream = true
            failedAfter = Date().timeIntervalSince(openedAt)
            failure = reason
            return true
        }
        view.trackRequest = VLCPlayerView.TrackRequest(
            audio: audio, subtitle: subtitle, automatic: automatic, source: planned.source,
            title: StartTracks.key(for: item, account: "u1"), ordered: nil,
            // A downloaded file has no server description (`AppModel.engineRequest` is nil for a file URL).
            engine: file == nil ? engineRequest : nil,
            coreStart: .init(item: item, plan: planned, model: app))
        if let file { app.downloads.ticks[id] = item.runTimeTicks ?? 0 }
        view.play(url: file ?? planned.url, offSeconds: 0, container: planned.container, subtitle: file == nil ? files : [],
                  softwareDecoder: planned.softwareDecoder)
    }

    func close() { view.stop() }

    var playing: Bool { view.avEngine?.pictureShown == true && view.avEngine?.isPlaying == true }

    // MARK: What is drawn

    /// Every `CATextLayer` under the view's layer that is showing text now (visible all the way up), with its string.
    func drawnText() -> [String] {
        guard let root = view.layer else { return [] }
        var found: [String] = []
        func walk(_ layer: CALayer, hidden: Bool) {
            let hide = hidden || layer.isHidden || layer.opacity == 0
            if let text = layer as? CATextLayer, !hide, text.frame.width > 1, text.frame.height > 1 {
                if let s = text.string as? NSAttributedString { found.append(s.string) }
                else if let s = text.string as? String { found.append(s) }
            }
            for sub in layer.sublayers ?? [] { walk(sub, hidden: hide) }
        }
        walk(root, hidden: false)
        return found
    }

    /// The overlay's layer is attached under the view's layer AND not covered by a later sibling that has a picture or
    /// a background (the render surface is black).
    func overlayState() -> String {
        guard let root = view.layer else { return "view has no layer" }
        func path(_ layer: CALayer) -> String {
            let subs = (layer.sublayers ?? []).map { "\(type(of: $0))\($0.isHidden ? "(hidden)" : "")" }
            return "\(type(of: layer)) subs \(subs)"
        }
        var lines = [path(root)]
        for sub in root.sublayers ?? [] { lines.append("  " + path(sub)) }
        return lines.joined(separator: " | ")
    }
}

extension MacPlayer {
    /// The subtitle overlay's own layer (the one that carries the text layers).
    var overlayLayer: CALayer? {
        view.layer?.sublayers?.first { $0.sublayers?.contains { $0 is CATextLayer } == true }
    }

    /// Renders the layer tree into a bitmap and reports whether there are light pixels (subtitle text is white).
    func lightPixels(of layer: CALayer? = nil) -> Int {
        guard let root = layer ?? view.layer else { return -1 }
        let w = Int(root.bounds.width), h = Int(root.bounds.height)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                               space: CGColorSpaceCreateDeviceRGB(),
                                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return -1 }
        root.render(in: ctx)
        guard let data = ctx.data else { return -1 }
        let bytes = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var count = 0
        for i in stride(from: 0, to: w * h * 4, by: 4) where bytes[i] > 200 && bytes[i + 1] > 200 && bytes[i + 2] > 200 { count += 1 }
        return count
    }
}
