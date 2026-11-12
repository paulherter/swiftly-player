import CoreGraphics
import Foundation
import Observation

extension ImagePixels {
    /// The decoded picture as a `CGImage` (premultiplied RGBA, 8 bit), `nil` when the sizes do not fit the data.
    public var cgImage: CGImage? {
        let w = Int(width)
        let h = Int(height)
        guard w > 0, h > 0, rgba.count >= w * h * 4, let provider = CGDataProvider(data: rgba as CFData) else {
            return nil
        }
        return CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// The `@MainActor @Observable` adapter of `ImageLoader`. The core decodes and caches; the host asks for
/// pictures (`request`), and `watch()` polls the loader about every 40 ms while it is running and bumps
/// `generation` and calls `onArrived` with the urls whose picture came in, so a view re-reads only those.
@MainActor
@Observable
public final class ImageLoaderController {
    /// Counts up whenever pictures arrived.
    public private(set) var generation: UInt64 = 0
    /// Called with the urls that arrived (or failed) since the last poll.
    @ObservationIgnored public var onArrived: ([String]) -> Void = { _ in }

    @ObservationIgnored public let loader: ImageLoader

    /// - Parameters:
    ///   - core: the core that owns the HTTP and the memory-pressure registry.
    ///   - cacheDir: the disk plate folder; `nil` keeps everything in memory (`Platform.cacheDir()`).
    public init(core: Core, cacheDir: String?, device: ImageDevice) {
        self.loader = core.imageLoader(cacheDir: cacheDir, device: device)
    }

    public func request(_ url: String, border: UInt32, priority: ImagePriority = .visible) -> ImageSlot {
        loader.request(url: url, border: border, priority: priority)
    }

    public func cached(_ url: String) -> ImagePixels? { loader.cached(url: url) }
    public func cancel(_ url: String) { loader.cancel(url: url) }
    public func prefetch(_ urls: [String], border: UInt32) { loader.prefetch(urls: urls, border: border) }
    public func setFastScroll(_ fast: Bool) { loader.setFastScroll(fast: fast) }
    public func retry(_ url: String) { loader.retry(url: url) }
    public func tones(_ url: String) -> [Double]? { loader.tones(url: url) }
    public func trim(level: UInt8) { loader.trim(level: level) }
    public func wipe() { loader.wipe() }
    public var stats: ImageStats { loader.stats() }

    /// The edge in pixels to ask for, from the size on screen in points.
    public func border(forDisplayEdge points: Float?) -> UInt32 { loader.borderFor(displayEdgePoints: points) }

    /// Returns when the calling Task is cancelled.
    public func watch() async {
        while !Task.isCancelled {
            let arrived = loader.poll()
            if !arrived.isEmpty {
                generation = loader.generation()
                onArrived(arrived)
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
    }
}

/// The `@MainActor @Observable` adapter of `LookModel` (selection, gifts, try-on, effects switch). Every
/// call that can change something re-reads the four properties.
@MainActor
@Observable
public final class LookController {
    public private(set) var selection: LookSelectionInfo
    public private(set) var shown: LookSelectionInfo
    public private(set) var isPreviewing: Bool
    public private(set) var effectsOn: Bool

    @ObservationIgnored private let model: LookModel

    public init(model: LookModel) {
        self.model = model
        self.selection = model.selection()
        self.shown = model.shown()
        self.isPreviewing = model.isPreviewing()
        self.effectsOn = model.effectsOn()
    }

    private func reread() {
        selection = model.selection()
        shown = model.shown()
        isPreviewing = model.isPreviewing()
        effectsOn = model.effectsOn()
    }

    public func mayWear(_ selection: LookSelectionInfo) -> Bool { model.mayWear(selection: selection) }
    public func setEffectsOn(_ on: Bool) throws { try model.setEffectsOn(on: on); reread() }
    public func setSupporter(_ supporter: Bool) throws { try model.setSupporter(supporter: supporter); reread() }
    public func beginPreview() throws { try model.beginPreview(); reread() }
    public func tryOn(_ selection: LookSelectionInfo) throws { try model.tryOn(selection: selection); reread() }
    public func endPreview() throws { try model.endPreview(); reread() }

    @discardableResult
    public func keep() throws -> LookKeep {
        defer { reread() }
        return try model.keep()
    }

    public func supportSheetClosed() throws { try model.supportSheetClosed(); reread() }

    @discardableResult
    public func purchaseCompleted() throws -> LookSelectionInfo? {
        defer { reread() }
        return try model.purchaseCompleted()
    }

    @discardableResult
    public func choose(_ selection: LookSelectionInfo) throws -> Bool {
        defer { reread() }
        return try model.choose(selection: selection)
    }

    public func claim(_ lookId: String) throws -> LookSelectionInfo? {
        defer { reread() }
        return try model.claim(lookId: lookId)
    }

    public func reset() throws { try model.reset(); reread() }

    public func markOffered(_ lookId: String, now: Double, utcOffset: Int64) throws {
        try model.markOffered(lookId: lookId, now: now, utcOffset: utcOffset)
    }

    public func giftDue(
        now: Double, homeReady: Bool, playing: Bool, askedThisSession: Bool, secondsOnHome: Double, utcOffset: Int64
    ) -> String? {
        model.giftDue(
            now: now, homeReady: homeReady, playing: playing, askedThisSession: askedThisSession,
            secondsOnHome: secondsOnHome, utcOffset: utcOffset)
    }

    public func freeLooks(now: Double, utcOffset: Int64) -> [String] { model.freeLooks(now: now, utcOffset: utcOffset) }
    public func pickerLooks(now: Double, utcOffset: Int64) -> [String] { model.pickerLooks(now: now, utcOffset: utcOffset) }
}

/// The `@MainActor @Observable` adapter of `SupportModel` (status, watch time, prompt history).
@MainActor
@Observable
public final class SupportController {
    public private(set) var status: SupportStatusInfo
    public private(set) var watchedHours: Int64

    @ObservationIgnored private let model: SupportModel

    public init(model: SupportModel) {
        self.model = model
        self.status = model.status()
        self.watchedHours = model.watchedHours()
    }

    private func reread() {
        status = model.status()
        watchedHours = model.watchedHours()
    }

    public func setStatus(_ status: SupportStatusInfo) throws { try model.setStatus(status: status); reread() }
    public func recordLaunch(now: Double) throws { try model.recordLaunch(now: now); reread() }
    public func playbackProgress(isPlaying: Bool, at: Double) throws {
        try model.playbackProgress(isPlaying: isPlaying, at: at)
        reread()
    }
    public func playbackStopped(at: Double) throws { try model.playbackStopped(at: at); reread() }
    public func snoozeCard(now: Double) throws { try model.snoozeCard(now: now) }
    public func dismissCard() throws { try model.dismissCard() }
    public func recordSheetShown(now: Double) throws { try model.recordSheetShown(now: now) }

    public func decide(
        now: Double, isPlaying: Bool, secondsSinceLaunch: Double, platform: SupportPlatformKind, utcOffset: Int64
    ) -> SupportDecision {
        model.decide(
            now: now, isPlaying: isPlaying, secondsSinceLaunch: secondsSinceLaunch, platform: platform,
            utcOffset: utcOffset)
    }
}

/// The `@MainActor @Observable` adapter of `TakeoverModel` ("Wo weiterschauen?"): `card` is what to draw;
/// the host polls `/Sessions`, hands the JSON over with `polled`, and reports the outcome of a handover.
@MainActor
@Observable
public final class TakeoverController {
    public private(set) var state: TakeoverState

    @ObservationIgnored private let model: TakeoverModel

    public init(model: TakeoverModel) {
        self.model = model
        self.state = model.state()
    }

    public var card: TakeoverCard { state.card }

    private func reread() { state = model.state() }

    /// The answer of `GET /Sessions`, raw.
    public func polled(sessionsJson: Data, now: Double = Date().timeIntervalSince1970) throws {
        try model.polled(sessionsJson: sessionsJson, now: now)
        reread()
    }

    public func tapped() { model.tapped(); reread() }
    public func selected(_ sessionId: String) { model.selected(sessionId: sessionId); reread() }
    public func cancelled() { model.cancelled(); reread() }
    public func succeeded() { model.succeeded(); reread() }
    public func failed(_ message: String) { model.failed(message: message); reread() }
    public func finished() { model.finished(); reread() }
}
