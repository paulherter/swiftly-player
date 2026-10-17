import JellyfinKit
import QuartzCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import CoreMotion
#endif
#if !canImport(UIKit)
import AppKit
#endif

// MARK: - "Continue watching here" as a card: iPhone, iPad, TV, Mac
//
// Timeline and springs live in the package (`HandoffCard`); here only what
// Core Animation needs. **Everything as keyframes in the render server**: the
// player builds up under the card, VLC opens, the network answers, all of that
// runs on the main thread and must not stall the motion. Only position, size and
// opacity are animated; no glow, no screenshot.

/// **A pass-through layer above everything**: on iPhone, iPad and TV its own window
/// above the app's, on the Mac a child window. Both also lie above the player,
/// which opens underneath during the handover. Coordinates as in SwiftUI: top left,
/// in points.
@MainActor
final class StageHolder {
    let root: CALayer
    private(set) var size: CGSize
    let scale: CGFloat
    /// The screen rotates (iPhone, iPad): the new size.
    var onSize: ((CGSize) -> Void)?
    #if canImport(UIKit)
    private var window: UIWindow?
    #else
    private var window: NSWindow?
    private weak var parent: NSWindow?
    #endif

    #if canImport(UIKit)
    private final class ThroughLet: UIWindow {
        // Taps go through; the stage is only to be seen.
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    }

    private final class Support: UIViewController {
        var sizeSwitches: ((CGSize) -> Void)?
        #if os(iOS)
        override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

        override func viewWillTransition(to size: CGSize,
                                         with coordinator: any UIViewControllerTransitionCoordinator) {
            super.viewWillTransition(to: size, with: coordinator)
            sizeSwitches?(size)
        }
        #endif
    }

    private init(window: UIWindow, support: Support) {
        self.window = window
        self.root = support.view.layer
        size = window.bounds.size
        scale = window.screen.scale
        support.sizeSwitches = { [weak self] new in
            self?.size = new
            self?.onSize?(new)
        }
    }

    static func buildUp() -> StageHolder? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              let main = scene.keyWindow else { return nil }
        let f = ThroughLet(windowScene: scene)
        f.frame = main.frame
        f.windowLevel = UIWindow.Level(rawValue: main.windowLevel.rawValue + 1)
        f.backgroundColor = .clear
        let support = Support()
        support.view.backgroundColor = .clear
        support.view.isUserInteractionEnabled = false
        f.rootViewController = support
        f.isHidden = false
        return StageHolder(window: f, support: support)
    }

    /// A view's frame in stage coordinates.
    func frameRect(from viewRef: UIView) -> CGRect { viewRef.convert(viewRef.bounds, to: nil) }

    func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
    }
    #else
    private init(window: NSWindow, parent: NSWindow, root: CALayer, size: CGSize) {
        self.window = window
        self.parent = parent
        self.root = root
        self.size = size
        scale = parent.backingScaleFactor
    }

    static func buildUp() -> StageHolder? {
        guard let main = NSApp.keyWindow ?? NSApp.mainWindow, let content = main.contentView
        else { return nil }
        let frameRect = main.convertToScreen(content.convert(content.bounds, to: nil))
        let f = NSWindow(contentRect: frameRect, styleMask: .borderless, backing: .buffered, defer: false)
        f.isOpaque = false
        f.backgroundColor = .clear
        f.hasShadow = false
        f.ignoresMouseEvents = true
        f.isReleasedWhenClosed = false
        let viewRef = NSView(frame: CGRect(origin: .zero, size: frameRect.size))
        viewRef.wantsLayer = true
        f.contentView = viewRef
        // Top left as in SwiftUI: its own, flipped layer inside.
        let root = CALayer()
        root.frame = viewRef.bounds
        root.isGeometryFlipped = true
        viewRef.layer?.addSublayer(root)
        main.addChildWindow(f, ordered: .above)
        return StageHolder(window: f, parent: main, root: root, size: frameRect.size)
    }

    /// A view's frame in stage coordinates (top left).
    func frameRect(from viewRef: NSView) -> CGRect {
        let r = viewRef.convert(viewRef.bounds, to: nil)
        let height = parent?.contentView?.bounds.height ?? size.height
        return CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
    }

    func tearDown() {
        if let window { parent?.removeChildWindow(window); window.orderOut(nil) }
        window = nil
    }
    #endif

    /// Render a SwiftUI view once, for the card's image and rows.
    func draw(_ content: some View) -> CGImage? {
        let drawer = ImageRenderer(content: content)
        drawer.scale = scale
        return drawer.cgImage
    }
}

/// Platform measures and colors of the handover.
@MainActor
enum HandoffStyle {
    static var metrics: HandoffCard.Metrics {
        #if os(tvOS)
        HandoffCard.tv
        #elseif os(macOS)
        HandoffCard.mac
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? HandoffCard.iPad : HandoffCard.iPhone
        #endif
    }

    /// This is how wide the card is at the badge when it opens.
    static var badgeWidth: Double {
        #if os(tvOS)
        60
        #elseif os(macOS)
        32
        #else
        44
        #endif
    }

    static func color(_ c: Color) -> CGColor {
        #if canImport(UIKit)
        UIColor(c).cgColor
        #else
        NSColor(c).cgColor
        #endif
    }

    /// Title and episode: "The Mentalist" and "Season 6 · Episode 7".
    static func rows(_ title: Item) -> (title: String, under: String?) {
        if let series = title.seriesName, !series.isEmpty {
            if let s = title.parentIndexNumber, let f = title.indexNumber {
                return (series, String(localized: "Staffel \(s) · Folge \(f)"))
            }
            return (series, title.name)
        }
        return (title.name, nil)
    }

    /// The rows under the card, left-aligned at card width; space above for the loading line.
    static func rowsView(_ z: (title: String, under: String?), width: Double,
                              metrics: HandoffCard.Metrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.spacing * 0.25) {
            Text(verbatim: z.title)
                .font(.system(size: metrics.title, weight: .semibold))
                .foregroundStyle(Theme.font)
            if let under = z.under {
                Text(verbatim: under)
                    .font(.system(size: metrics.small))
                    .foregroundStyle(Theme.fontQuiet)
            }
        }
        .lineLimit(1)
        .padding(.top, 2 + metrics.spacing * 0.35)
        .frame(width: width, alignment: .leading)
    }

    static func cardsView(_ image: Image?, size: CGSize) -> some View {
        ZStack {
            Theme.area
            if let image { image.resizable().aspectRatio(contentMode: .fill) }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

/// **Frame times during the handover, on device**: every frame duration over 1.5
/// nominal is logged with time, duration and phase (`[Uebergabe] bildzeit`). The
/// motion runs in the render server; what shows up here is the main thread (player
/// build-up, network).
@MainActor
final class HandoffImageTime: NSObject {
    private let role: String
    private let phase: (Double) -> String
    private var tick: CADisplayLink?
    private var start: CFTimeInterval = 0
    private var last: CFTimeInterval = 0
    private var outlier: [String] = []
    private var images = 0

    init(role: String, phase: @escaping (Double) -> String) {
        self.role = role
        self.phase = phase
    }

    func start(since: CFTimeInterval) {
        start = since
        #if canImport(UIKit)
        let t = CADisplayLink(target: self, selector: #selector(image(_:)))
        #else
        guard let t = NSScreen.main?.displayLink(target: self, selector: #selector(image(_:))) else { return }
        #endif
        t.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        t.add(to: .main, forMode: .common)
        tick = t
    }

    func halt() {
        guard let tick else { return }
        tick.invalidate()
        self.tick = nil
        AppLog.writeOut("[Uebergabe] bildzeit \(role): \(images) bilder, \(outlier.count) zu lang"
            + (outlier.isEmpty ? "" : ": " + outlier.joined(separator: " ")))
    }

    @objc private func image(_ t: CADisplayLink) {
        images += 1
        defer { last = t.timestamp }
        guard last > 0 else { return }
        let duration = t.timestamp - last
        let should = max(t.targetTimestamp - t.timestamp, 1.0 / 120)
        guard duration > should * 1.5 else { return }
        let since = t.timestamp - start
        outlier.append("\(Int(since * 1000))ms/\(Int(duration * 1000))ms/\(phase(since))")
    }
}

/// A point as a keyframe value; `NSValue` is named differently on both sides.
private func point(_ p: CGPoint) -> NSValue {
    #if canImport(UIKit)
    NSValue(cgPoint: p)
    #else
    NSValue(point: p)
    #endif
}

/// Keyframes as a keyframe animation: linear between the points, the curve is in the points themselves.
@MainActor
private func prop(_ path: String, _ values: [Any], beginning: CFTimeInterval, duration: Double) -> CAKeyframeAnimation {
    let a = CAKeyframeAnimation(keyPath: path)
    a.values = values
    a.calculationMode = .linear
    a.beginTime = beginning
    a.duration = duration
    a.fillMode = .forwards
    a.isRemovedOnCompletion = false
    return a
}

// MARK: - Receiver

/// **The receiver's card.** Started on the tap on the badge, runs alongside the
/// takeover and is replaced by the player once its first frame is up
/// (``bildDa(_:)``).
@MainActor
final class HandoffStage {
    static let shared = HandoffStage()
    private init() {}

    /// Is a handover running? Then the player opens without its own fade and stays portrait until the card is gone.
    private(set) var active = false

    private var holder: StageHolder?
    private var stage: CALayer?
    private var card: CALayer?
    private var rows: CALayer?
    private var line: CALayer?
    private var black: CALayer?
    private var beginning: CFTimeInterval = 0
    private var from = HandoffCard.Status(x: 0, y: 0, width: 1)
    /// When the (last) flight began; restarts after a rotation.
    private var transitionOut = HandoffCard.cardsStart
    /// This is how wide the card is drawn; all measures scale from it.
    private var base: Double = 1
    private var idle = HandoffCard.Status(x: 0, y: 0, width: 1)
    private var full = HandoffCard.Status(x: 0, y: 0, width: 1)
    private var metrics = HandoffCard.iPhone
    private var reduced = false
    private var titleID: String?
    private var ready: Double?
    private var zoomOff: Double?
    private var run = 0
    private var measurement: HandoffImageTime?

    private var now: Double { CACurrentMediaTime() - beginning }

    private func time(_ was: String) {
        AppLog.writeOut("[Uebergabe] Karte +\(Int(now * 1000)) ms \(was)")
    }

    /// **On the tap**, before the network is even asked.
    func start(title: Item?, model: AppModel) {
        tidyAway()
        guard let h = StageHolder.buildUp() else { return }
        run += 1
        active = true
        holder = h
        beginning = CACurrentMediaTime()
        titleID = title?.id
        ready = nil
        zoomOff = nil
        metrics = HandoffStyle.metrics
        reduced = Theme.motionReduced
        transitionOut = HandoffCard.cardsStart
        #if os(iOS)
        // **Landscape fixed: the player is landscape from the start.** It opens landscape
        // under the card, the stage rotates along and the card flies into the landscape
        // position (``newAlign(_:)``); after the zoom nothing rotates anymore.
        // Otherwise it stays portrait until the card is gone.
        let fixed = UserDefaults.standard.object(forKey: "querformatFest") as? Bool ?? true
        if !(fixed && Orientierung.landscapeLockPossible) {
            Orientierung.shared.holdHandoff()
        }
        #endif
        VLCPlayerView.handoffFadeIn = true

        let b = Double(h.size.width), hh = Double(h.size.height)
        full = HandoffCard.fullscreen(width: b, height: hh)
        idle = HandoffCard.idleStatus(width: b, height: hh, metrics: metrics)
        if let p = BadgeOrigin.point, !reduced {
            from = .init(x: p.x, y: p.y, width: HandoffStyle.badgeWidth)
        } else {
            from = idle
        }

        let layer = CALayer()
        layer.frame = CGRect(origin: .zero, size: h.size)
        h.root.addSublayer(layer)
        stage = layer

        // The ground above the page; the page steps back.
        let reason = CALayer()
        reason.frame = layer.bounds
        reason.backgroundColor = HandoffStyle.color(Theme.reason)
        reason.opacity = 0
        layer.addSublayer(reason)

        let black = CALayer()
        black.frame = layer.bounds
        black.backgroundColor = HandoffStyle.color(.black)  // like the player's ground
        black.opacity = 0
        layer.addSublayer(black)
        self.black = black

        // The card drawn at full size, animated scaled down.
        let cardsSize = CGSize(width: full.width, height: full.height)
        base = full.width
        let card = CALayer()
        card.bounds = CGRect(origin: .zero, size: cardsSize)
        card.masksToBounds = true
        card.opacity = 0
        card.contentsGravity = .resizeAspectFill
        layer.addSublayer(card)
        self.card = card
        let url = title.flatMap { TakeoverModel.cardImageURL($0, model: model) }
        let available = url.flatMap { ImageCache.shared.image($0) }
        card.contents = h.draw(HandoffStyle.cardsView(available, size: cardsSize))
        if available == nil, let url {
            let myOwn = run
            Task { @MainActor in
                guard let image = await ImageCache.shared.load(url, border: 1280),
                      myOwn == self.run, let h = self.holder else { return }
                // If the image arrives later, it crossfades (the layer's default fade).
                self.card?.contents = h.draw(HandoffStyle.cardsView(image, size: cardsSize))
                self.time("Bild nachgeladen")
            }
        }

        // Title and episode below, with space for the loading line.
        let rows = CALayer()
        if let title {
            let z = HandoffStyle.rows(title)
            let image = h.draw(HandoffStyle.rowsView(z, width: idle.width, metrics: metrics))
            rows.contents = image
            let height = image.map { CGFloat($0.height) / h.scale } ?? 0
            rows.bounds = CGRect(x: 0, y: 0, width: idle.width, height: height)
        }
        rows.anchorPoint = CGPoint(x: 0.5, y: 0)
        rows.opacity = 0
        layer.addSublayer(rows)
        self.rows = rows

        let line = CALayer()
        line.frame = CGRect(x: 0, y: 0, width: idle.width, height: 2)
        line.cornerRadius = 1  // half height: a capsule
        line.masksToBounds = true
        line.backgroundColor = HandoffStyle.color(Theme.margin)
        line.opacity = 0
        let stripe = CALayer()
        stripe.frame = CGRect(x: 0, y: 0, width: idle.width * 0.3, height: 2)
        stripe.cornerRadius = 1
        stripe.backgroundColor = HandoffStyle.color(Theme.accent)
        line.addSublayer(stripe)
        rows.addSublayer(line)
        self.line = line

        if reduced { fadePut(reason: reason) } else { transitionPut(reason: reason) }
        h.onSize = { [weak self] new in self?.newAlign(new) }

        measurement = HandoffImageTime(role: "empfaenger") { [weak self] t in self?.phase(t) ?? "?" }
        measurement?.start(since: beginning)
        time(reduced ? "blendet auf (reduziert)" : "wächst aus dem Abzeichen")

        // The loading line only if the image is still missing at 0.75 s.
        let myOwn = self.run
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(HandoffCard.loadingBarOut))
            guard myOwn == self.run, self.active, self.zoomOff == nil,
                  HandoffCard.loadLine(ready: self.ready) else { return }
            self.showLoadLine()
        }
    }

    private func phase(_ t: Double) -> String {
        if let z = zoomOff {
            if t >= z + HandoffCard.cardsOutFrom { return "blende" }
            if t >= z { return "zoom" }
        }
        if t < HandoffCard.pageUntil { return "seite" }
        if t < HandoffCard.float { return "flug" }
        return "schweben"
    }

    /// Flight from the badge and hover, computed well beyond the longest wait; the zoom lays over it later.
    private func transitionPut(reason: CALayer) {
        guard let card, let rows else { return }
        pathPut(since: 0)

        let short = HandoffCard.anchorPoints(from: 0, until: 1) { $0 }
        card.add(prop("opacity", short.map { NSNumber(value: HandoffCard.cardsCoverage($0)) },
                           beginning: beginning, duration: 1), forKey: "flug.deckung")
        reason.add(prop("opacity", short.map { NSNumber(value: HandoffCard.pagesCoverage($0)) },
                           beginning: beginning, duration: 1), forKey: "seite")
        rows.add(prop("opacity", short.map { NSNumber(value: HandoffCard.rowsCoverage($0, zoomOff: nil)) },
                            beginning: beginning, duration: 1), forKey: "zeilen.an")
    }

    /// The path of the waiting card from `since` (seconds since the tap).
    private func pathPut(since: Double) {
        guard let card, let rows else { return }
        let until = HandoffCard.float + HandoffCard.atMostWait + 8
        guard until > since else { return }
        let (vo, na, fa) = (from, idle, transitionOut)
        let situations = HandoffCard.anchorPoints(from: since, until: until) {
            HandoffCard.wait($0, from: vo, to: na, since: fa)
        }
        let v = full, m = metrics, b = base
        card.add(prop("position", situations.map { point(CGPoint(x: $0.x, y: $0.y)) },
                           beginning: beginning + since, duration: until - since), forKey: "flug.ort")
        card.add(prop("transform.scale", situations.map { NSNumber(value: $0.width / b) },
                           beginning: beginning + since, duration: until - since), forKey: "flug.mass")
        card.add(prop("cornerRadius", situations.map {
            NSNumber(value: HandoffCard.corner($0, metrics: m, full: v) * b / $0.width)
        }, beginning: beginning + since, duration: until - since), forKey: "flug.ecke")
        rows.add(prop("position", situations.map {
            point(CGPoint(x: $0.x, y: HandoffCard.rowsTop($0, metrics: m)))
        }, beginning: beginning + since, duration: until - since), forKey: "flug.ort")
    }

    /// **The screen rotates** while the card waits, usually because the player opens
    /// landscape underneath. The stage takes the new size, and the card flies from
    /// where it is to the resting position of the new format; the zoom then goes
    /// straight to the landscape image.
    private func newAlign(_ new: CGSize) {
        guard active, let stage else { return }
        let t = now
        time("Drehung auf \(Int(new.width))×\(Int(new.height))")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.frame = CGRect(origin: .zero, size: new)
        for e in stage.sublayers ?? [] where e !== card && e !== rows {
            e.frame = stage.bounds
        }
        CATransaction.commit()
        let b = Double(new.width), hh = Double(new.height)
        full = HandoffCard.fullscreen(width: b, height: hh)
        let oldIdle = idle
        idle = HandoffCard.idleStatus(width: b, height: hh, metrics: metrics)
        guard !reduced, zoomOff == nil else {
            if reduced, let card, let rows {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                card.position = CGPoint(x: idle.x, y: idle.y)
                rows.position = CGPoint(x: idle.x, y: HandoffCard.rowsTop(idle, metrics: metrics))
                CATransaction.commit()
            }
            return
        }
        from = HandoffCard.transition(t, from: from, to: oldIdle, since: transitionOut)
        transitionOut = t
        pathPut(since: t)
    }

    /// With reduced motion: everything stands still, only fades.
    private func fadePut(reason: CALayer) {
        guard let card, let rows else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.position = CGPoint(x: idle.x, y: idle.y)
        card.transform = CATransform3DMakeScale(idle.width / base, idle.width / base, 1)
        card.cornerRadius = metrics.corner * base / idle.width
        rows.position = CGPoint(x: idle.x, y: HandoffCard.rowsTop(idle, metrics: metrics))
        CATransaction.commit()
        for (layer, since) in [(reason, 0.0), (card, HandoffCard.cardsStart), (rows, HandoffCard.cardsStart)] {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 0; a.toValue = 1
            a.beginTime = beginning + since
            a.duration = HandoffCard.fade
            a.fillMode = .both
            a.isRemovedOnCompletion = false
            layer.add(a, forKey: "blende")
        }
    }

    private func showLoadLine() {
        guard let line, let run = line.sublayers?.first else { return }
        time("Ladelinie")
        let an = CABasicAnimation(keyPath: "opacity")
        an.fromValue = 0; an.toValue = 1
        an.beginTime = CACurrentMediaTime()
        an.duration = HandoffCard.loadingBarShow
        an.fillMode = .forwards
        an.isRemovedOnCompletion = false
        line.add(an, forKey: "an")
        let b = line.bounds.width, w = run.bounds.width
        let travel = CABasicAnimation(keyPath: "position.x")
        travel.fromValue = -w / 2
        travel.toValue = b + w / 2
        travel.duration = HandoffCard.loadingBarTick
        travel.repeatCount = .infinity
        run.add(travel, forKey: "fahrt")
    }

    /// **The player is up** (invisible under the card). From here the card waits at
    /// most ``Uebergabekarte/hoechstensWarten`` for the first frame.
    func playerComes(_ itemID: String) {
        guard active else { return }
        titleID = itemID
        time("Player geöffnet")
        let myOwn = run
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(HandoffCard.atMostWait))
            guard myOwn == self.run, self.active, self.zoomOff == nil else { return }
            self.time("kein erstes Bild — Karte gibt trotzdem frei")
            self.zoomIn(ready: self.now)
        }
    }

    /// **The first frame is up**: now the card zooms (at the earliest at
    /// ``Uebergabekarte/schweben``) and releases the picture.
    func imagePresent(_ itemID: String) {
        guard active, zoomOff == nil, itemID == titleID else { return }
        time("erstes Bild")
        zoomIn(ready: now)
    }

    private func zoomIn(ready t: Double) {
        guard let card, let rows, let black, let stage else { return }
        ready = t
        let z = reduced ? t : HandoffCard.zoomStart(ready: t)
        zoomOff = z
        let since = beginning + z

        if reduced {
            let from = CABasicAnimation(keyPath: "opacity")
            from.fromValue = 1; from.toValue = 0
            from.beginTime = since
            from.duration = HandoffCard.fadeOut
            from.fillMode = .forwards
            from.isRemovedOnCompletion = false
            stage.add(from, forKey: "aus")
            finish(to: z + HandoffCard.fadeOut + 0.05)
            return
        }

        // From position **and momentum** of the waiting card; no stop.
        let start = HandoffCard.wait(z, from: from, to: idle, since: transitionOut)
        let momentum = HandoffCard.momentum(z, from: from, to: idle, since: transitionOut)
        let duration = HandoffCard.end
        let situations = HandoffCard.anchorPoints(from: 0, until: duration) {
            HandoffCard.zoom($0, from: start, momentum: momentum, to: full)
        }
        let v = full, m = metrics, b = base
        card.add(prop("position", situations.map { point(CGPoint(x: $0.x, y: $0.y)) },
                           beginning: since, duration: duration), forKey: "zoom.ort")
        card.add(prop("transform.scale", situations.map { NSNumber(value: $0.width / b) },
                           beginning: since, duration: duration), forKey: "zoom.mass")
        card.add(prop("cornerRadius", situations.map {
            NSNumber(value: HandoffCard.corner($0, metrics: m, full: v) * b / $0.width)
        }, beginning: since, duration: duration), forKey: "zoom.ecke")
        rows.add(prop("position", situations.map {
            point(CGPoint(x: $0.x, y: HandoffCard.rowsTop($0, metrics: m)))
        }, beginning: since, duration: duration), forKey: "zoom.ort")

        let rowsOut = CABasicAnimation(keyPath: "opacity")
        rowsOut.fromValue = 1; rowsOut.toValue = 0
        rowsOut.beginTime = since
        rowsOut.duration = HandoffCard.rowsOut
        rowsOut.fillMode = .forwards
        rowsOut.isRemovedOnCompletion = false
        rows.add(rowsOut, forKey: "zeilen.aus")

        let blackAn = CABasicAnimation(keyPath: "opacity")
        blackAn.fromValue = 0; blackAn.toValue = 1
        blackAn.beginTime = since
        blackAn.duration = HandoffCard.blackDuration
        blackAn.fillMode = .forwards
        blackAn.isRemovedOnCompletion = false
        black.add(blackAn, forKey: "an")

        let from = HandoffCard.anchorPoints(from: 0, until: duration) {
            NSNumber(value: HandoffCard.stageCoverage(toZoom: $0))
        }
        stage.add(prop("opacity", from, beginning: since, duration: duration), forKey: "aus")
        time("Zoom ab +\(Int(z * 1000)) ms")
        finish(to: z + duration)
    }

    private func finish(to t: Double) {
        let myOwn = run
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(0, t - self.now)))
            guard myOwn == self.run else { return }
            self.time("fertig")
            self.tidyAway()
        }
    }

    /// **The handover failed** (no plan, stop rejected) or the player was closed while waiting: the stage fades out.
    func cancel(_ reason: String) {
        guard active, let stage else { return }
        time("abgebrochen: \(reason)")
        VLCPlayerView.handoffFadeIn = false
        let from = CABasicAnimation(keyPath: "opacity")
        from.fromValue = stage.presentation()?.opacity ?? 1
        from.toValue = 0
        from.duration = HandoffCard.fade
        from.fillMode = .forwards
        from.isRemovedOnCompletion = false
        stage.add(from, forKey: "aus")
        let myOwn = run
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(HandoffCard.fade + 0.05))
            guard myOwn == self.run else { return }
            self.tidyAway()
        }
    }

    /// The player closed before the card released it.
    func playerDistance(_ itemID: String) {
        guard active, itemID == titleID, zoomOff == nil else { return }
        cancel("Player geschlossen")
    }

    private func tidyAway() {
        measurement?.halt()
        measurement = nil
        holder?.tearDown()
        holder = nil
        stage = nil; card = nil; rows = nil; line = nil; black = nil
        guard active else { return }
        active = false
        run += 1
        // Applies to exactly this start; if it never came, not to the next.
        VLCPlayerView.handoffFadeIn = false
        #if os(iOS)
        // **Landscape only now**, and only if the setting says the player opens landscape.
        let fixed = UserDefaults.standard.object(forKey: "querformatFest") as? Bool ?? true
        Orientierung.shared.handoffShare(landscapeFixed: fixed)
        #endif
    }
}

// MARK: - Handing-over side

/// **The sender's picture leaves as a card, the mirror image of the receiver.**
///
/// **In its own layer above everything, not in the player**: until then the video
/// surface in the player itself was moved, with its controls and layers above it,
/// so the card ran underneath and was barely visible. Now the player pauses, VLC
/// hands out its still image (``VLCPlayerView/standbild(breite:)``), and the stage
/// places itself with that image exactly where the video was, opaque over the whole
/// screen; from its first frame nothing of the player is visible. The card shrinks
/// with the zoom spring, hovers briefly and flies out with the grow spring: up
/// toward the larger device, down toward the smaller
/// (``Uebergabekarte/departurePostTop(von:nach:)``). Only then does the player close,
/// under the stage (on iPhone it rotates back to portrait, invisible under the
/// solid ground), and the ground fades out onto the page.
@MainActor
enum HandoffExit {
    private static var holder: StageHolder?
    private static var measurement: HandoffImageTime?
    /// Until the page below is up: close, including the rotation back.
    private static let closeDuration = 0.5
    #if os(iOS)
    /// Gravity on departure: how the iPhone is actually held, independent of how the UI is oriented.
    private static var motion: CMMotionManager?
    #endif

    /// **Posture measurement off, on every path.** It used to be stopped only in
    /// `departureDirection`, which runs neither with reduced motion nor when there is no
    /// image. There the motion sensor kept running at 60 Hz until the next handover,
    /// which only overwrote it.
    private static func motionOut() {
        #if os(iOS)
        motion?.stopDeviceMotionUpdates()
        motion = nil
        #endif
    }

    /// - Parameters:
    /// - flaeche: the player's video surface.
    /// - ziel: who takes over ("iPhone", "Apple TV" ...); determines the departure direction.
    /// - anhalten: immediately; the picture stands, the sound is gone.
    /// - fertig: the card is out; the player closes (under the stage).
    static func start(area: VLCPlayerView, target: String, title: Item, model: AppModel,
                        halt: @escaping () -> Void, done: @escaping () -> Void) {
        holder?.tearDown()
        holder = nil
        measurement?.halt()
        measurement = nil
        motionOut()
        let reduced = Theme.motionReduced
        let stop = CACurrentMediaTime()
        func time(_ was: String) {
            AppLog.writeOut("[Uebergabe] Abgang +\(Int((CACurrentMediaTime() - stop) * 1000)) ms \(was)")
        }
        time("an \(target)\(reduced ? " (reduziert)" : "")")
        halt()
        #if os(iOS)
        let m = CMMotionManager()
        if m.isDeviceMotionAvailable {
            m.deviceMotionUpdateInterval = 1.0 / 60
            m.startDeviceMotionUpdates()
            motion = m
        }
        #endif

        #if canImport(UIKit)
        let pixel = Int(area.bounds.width * area.contentScaleFactor)
        #else
        let pixel = Int(area.bounds.width * (area.window?.backingScaleFactor ?? 2))
        #endif
        Task { @MainActor in
            // **The real image if it is one, otherwise the episode image.** On iPhone VLC's
            // still image returned a completely black image after 74-158 ms, and the card flew
            // black. An almost black still therefore does not count.
            var image = await area.stillImage(width: pixel)
            if let b = image, let bright = brightness(b), bright < 0.04 {
                time("Standbild schwarz (Helligkeit \(String(format: "%.3f", bright))) — Folgenbild")
                image = nil
            } else if image == nil {
                time("kein Standbild — Folgenbild")
            } else {
                time("Standbild da")
            }
            var filled = false
            if image == nil, let url = TakeoverModel.cardImageURL(title, model: model) {
                let episodeImage: Image?
                if let present = ImageCache.shared.image(url) { episodeImage = present }
                else { episodeImage = await ImageCache.shared.load(url, border: 1280) }
                if let episodeImage, let h0 = StageHolder.buildUp() {
                    let r = h0.frameRect(from: area)
                    let v = HandoffCard.fullscreen(width: r.width, height: r.height)
                    image = h0.draw(HandoffStyle.cardsView(episodeImage,
                                       size: CGSize(width: v.width, height: v.height)))
                    h0.tearDown()
                    filled = true
                }
            }
            guard let image, let h = StageHolder.buildUp() else {
                time("weder Standbild noch Folgenbild — Player schließt wie sonst")
                motionOut()
                done()
                return
            }
            holder = h
            if filled { time("Folgenbild da") }
            #if os(iOS)
            // The first measurement arrives after a few hundredths of a second.
            var n = 0
            while motion != nil, motion?.deviceMotion == nil, n < 6 {
                try? await Task.sleep(for: .milliseconds(20))
                n += 1
            }
            #endif
            play(h, image: image, frameRect: h.frameRect(from: area), target: target, title: title,
                    reduced: reduced, time: time, done: done)
        }
    }

    /// **The departure direction on screen.** On iPhone and iPad by the real posture
    /// (gravity): whoever already holds the phone upright again during the switch while
    /// the player is landscape sees the card fly toward the physically upper edge,
    /// toward the TV. TV and Mac: simply up or down.
    private static func departureDirection(toTop: Bool, time: (String) -> Void) -> HandoffCard.Direction {
        #if os(iOS)
        defer { motionOut() }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let g = motion?.deviceMotion?.gravity, let status = scene?.interfaceOrientation else {
            time("keine Schwerkraft — Oben der Oberfläche")
            return toTop ? .top : .bottom
        }
        let surface: HandoffCard.UserInterface
        switch status {
        case .portraitUpsideDown: surface = .upsideDown
        case .landscapeRight: surface = .landscapeHomeRight
        case .landscapeLeft: surface = .landscapeHomeLeft
        default: surface = .up
        }
        time("Schwerkraft \(String(format: "%.2f, %.2f, %.2f", g.x, g.y, g.z)) · Oberfläche \(surface)")
        return HandoffCard.departureDirection(gravityX: g.x, gravityY: g.y,
                                             surface: surface, toTop: toTop)
        #else
        return toTop ? .top : .bottom
        #endif
    }

    /// Fetches the episode image into the image cache in advance.
    static func preload(_ title: Item, model: AppModel) async {
        guard let url = TakeoverModel.cardImageURL(title, model: model),
              ImageCache.shared.image(url) == nil else { return }
        _ = await ImageCache.shared.load(url, border: 1280)
    }

    /// Mean brightness 0...1, scaled down to 16 x 16 points.
    private static func brightness(_ image: CGImage) -> Double? {
        let n = 16
        var points = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &points, width: n, height: n, bitsPerComponent: 8,
                                  bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        var sum = 0.0
        for i in stride(from: 0, to: points.count, by: 4) {
            sum += 0.2126 * Double(points[i]) + 0.7152 * Double(points[i + 1]) + 0.0722 * Double(points[i + 2])
        }
        return sum / Double(n * n) / 255
    }

    private static func play(_ h: StageHolder, image: CGImage, frameRect r: CGRect, target: String,
                                title: Item, reduced: Bool, time: @escaping (String) -> Void,
                                done: @escaping () -> Void) {
        let beginning = CACurrentMediaTime()
        let metrics = HandoffStyle.metrics
        let screen = h.size

        // Where the video stood in the surface: fitted to the image itself.
        let pages = Double(image.width) / Double(max(image.height, 1))
        let vb = min(Double(r.width), Double(r.height) * pages)
        let full = HandoffCard.Status(x: r.midX, y: r.midY, width: vb)
        let card = HandoffCard.idleStatus(width: screen.width, height: screen.height, metrics: metrics)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let reason = CALayer()
        reason.frame = CGRect(origin: .zero, size: screen)
        reason.backgroundColor = HandoffStyle.color(Theme.reason)
        h.root.addSublayer(reason)
        let black = CALayer()
        black.frame = reason.frame
        black.backgroundColor = HandoffStyle.color(.black)  // like the player's ground
        h.root.addSublayer(black)
        let kl = CALayer()
        kl.bounds = CGRect(x: 0, y: 0, width: vb, height: vb / pages)
        kl.position = CGPoint(x: full.x, y: full.y)
        kl.contents = image
        kl.contentsGravity = .resizeAspect
        kl.masksToBounds = true
        h.root.addSublayer(kl)
        CATransaction.commit()
        h.onSize = { new in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            reason.frame = CGRect(origin: .zero, size: new)
            black.frame = reason.frame
            CATransaction.commit()
        }
        time("Bühne deckt den Player ab ihrem ersten Bild")

        let out: Double
        if reduced {
            motionOut()
            for e in [kl, black] {
                let from = CABasicAnimation(keyPath: "opacity")
                from.fromValue = 1; from.toValue = 0
                from.beginTime = beginning
                from.duration = HandoffCard.fadeOut
                from.fillMode = .forwards
                from.isRemovedOnCompletion = false
                e.add(from, forKey: "aus")
            }
            out = HandoffCard.fadeOut
        } else {
            let z = HandoffStyle.rows(title)
            let rows = CALayer()
            let rowImage = h.draw(HandoffStyle.rowsView(z, width: card.width, metrics: metrics))
            rows.contents = rowImage
            rows.bounds = CGRect(x: 0, y: 0, width: card.width,
                                   height: rowImage.map { CGFloat($0.height) / h.scale } ?? 0)
            rows.anchorPoint = CGPoint(x: 0.5, y: 0)
            rows.opacity = 0
            h.root.addSublayer(rows)

            let top = HandoffCard.departurePostTop(from: TakeoverModel.ownName, to: target)
            let bearing = departureDirection(toTop: top, time: time)
            out = HandoffCard.exitOut(full: full, card: card, bearing: bearing)
            time("fliegt nach \(top ? "oben" : "unten") (\(String(format: "%.2f, %.2f", bearing.x, bearing.y))), draußen nach \(Int(out * 1000)) ms")
            let until = out + 0.1
            let situations = HandoffCard.anchorPoints(from: 0, until: until) {
                HandoffCard.exit($0, full: full, card: card, bearing: bearing)
            }
            kl.add(prop("position", situations.map { point(CGPoint(x: $0.x, y: $0.y)) },
                            beginning: beginning, duration: until), forKey: "ort")
            kl.add(prop("transform.scale", situations.map { NSNumber(value: $0.width / vb) },
                            beginning: beginning, duration: until), forKey: "mass")
            kl.add(prop("cornerRadius", situations.map {
                NSNumber(value: HandoffCard.corner($0, metrics: metrics, full: full) * vb / $0.width)
            }, beginning: beginning, duration: until), forKey: "ecke")
            rows.add(prop("position", situations.map {
                point(CGPoint(x: $0.x, y: HandoffCard.rowsTop($0, metrics: metrics)))
            }, beginning: beginning, duration: until), forKey: "ort")
            rows.add(prop("opacity", HandoffCard.anchorPoints(from: 0, until: until) {
                NSNumber(value: HandoffCard.exitRowsCoverage($0))
            }, beginning: beginning, duration: until), forKey: "deckung")
            // Mirror of the receiver: black goes when the card shrinks.
            let blackOut = CABasicAnimation(keyPath: "opacity")
            blackOut.fromValue = 1; blackOut.toValue = 0
            blackOut.beginTime = beginning + HandoffCard.exitStart
            blackOut.duration = HandoffCard.blackDuration
            blackOut.fillMode = .forwards
            blackOut.isRemovedOnCompletion = false
            black.add(blackOut, forKey: "aus")
        }

        measurement = HandoffImageTime(role: "abgeber") { t in
            if reduced { return "blende" }
            if t < HandoffCard.exitStart { return "stand" }
            if t < HandoffCard.exitFloatOff { return "schrumpfen" }
            if t < HandoffCard.departure { return "schweben" }
            if t < out { return "abflug" }
            return "schliessen"
        }
        measurement?.start(since: beginning)

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(0, out - (CACurrentMediaTime() - beginning))))
            time("Karte draußen — Player schließt unter der Bühne")
            done()
            try? await Task.sleep(for: .seconds(closeDuration))
            #if os(iOS)
            // **Only when the frame is really closed**: it was still up after 0.5 s (closing including the rotation takes longer), and the ground faded onto the player instead of the page. At most 2 s.
            var waited = 0
            while PlayerFrame.active != nil, waited < 30 {
                try? await Task.sleep(for: .milliseconds(50))
                waited += 1
            }
            time("Player weg: \(PlayerFrame.active == nil ? "ja" : "nein") — Grund blendet zur Seite")
            #else
            time("Grund blendet zur Seite")
            #endif
            let from = CABasicAnimation(keyPath: "opacity")
            from.fromValue = 1; from.toValue = 0
            from.duration = HandoffCard.fade
            from.fillMode = .forwards
            from.isRemovedOnCompletion = false
            reason.add(from, forKey: "aus")
            try? await Task.sleep(for: .seconds(HandoffCard.fade + 0.05))
            measurement?.halt()
            measurement = nil
            h.tearDown()
            if holder === h { holder = nil }
        }
    }
}
