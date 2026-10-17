import OSLog
import QuartzCore
import SwiftUI
import UIKit

// MARK: - The account-switch stage in UIKit: iPhone, iPad, TV
//
// Sequence and curve of the account switch are shared in
// `Sources/Shared/AccountTransition.swift`; here only what UIKit needs. On the Mac
// the stage is in `Sources/macOS/AccountSwitchStage.swift`.

/// **The account-switch stage in UIKit**: still image and flying image as layers
/// in the window, with Core Animation keyframes; see ``AccountSwitchTransition``.
@MainActor
enum AccountSwitchStage {
    /// Width of the window, for ``Kontowechselflug/targetReport(_:)``.
    static var windowWidthValue: CGFloat? { window?.bounds.width }

    private static var window: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }

    /// What is on the stage, so an early completion can clear it.
    final class Parts {
        var stillImage: UIView?
        var layer: CALayer?
        var ring: CALayer?

        /// The still fades out briefly, image and ring go immediately; the real image is in their place.
        func cancel() {
            if let stillImage {
                UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState],
                               animations: { stillImage.alpha = 0 },
                               completion: { _ in stillImage.removeFromSuperview() })
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.removeFromSuperlayer()
            ring?.removeFromSuperlayer()
            CATransaction.commit()
            stillImage = nil; layer = nil; ring = nil
        }
    }

    /// `nil` without a window: then there is no motion.
    static func play(curve: AccountSwitchTransition.Curve?, image: some View, from: CGRect,
                        area: Color, contentOff: CGFloat, calm: Bool,
                        start: CFTimeInterval) -> Parts? {
        guard let window else { return nil }
        let area = UIColor(area)
        let parts = Parts()
        // 1. The still image of the profile page. The tapped image is covered on it,
        // since it is already flying.
        //
        // **With a sidebar (wide iPad) only the content to its right**: the bar stays, and
        // the image lands in it.
        let crop = CGRect(x: contentOff, y: 0, width: window.bounds.width - contentOff,
                                height: window.bounds.height)
        let stillImage = contentOff > 0
            ? window.resizableSnapshotView(from: crop, afterScreenUpdates: false,
                                            withCapInsets: .zero)
            : window.snapshotView(afterScreenUpdates: false)
        if let stillImage {
            stillImage.frame = crop
            if curve != nil {
                // On TV the ring and the magnifier lie around the focused image; the cover takes both along.
                #if os(tvOS)
                let capEdge: CGFloat = -8
                #else
                let capEdge: CGFloat = -3
                #endif
                let cap = UIView(frame: from.insetBy(dx: capEdge, dy: capEdge)
                    .offsetBy(dx: -contentOff, dy: 0))
                cap.backgroundColor = area
                cap.layer.cornerRadius = cap.bounds.width / 2
                stillImage.addSubview(cap)
            }
            // **No shadow**: it was huge under the departing page and vanished abruptly at
            // the end. Taps go through: the profile at the top is tappable again at once, even
            // while the page is still moving away.
            stillImage.isUserInteractionEnabled = false
            window.addSubview(stillImage)
            parts.stillImage = stillImage
            #if os(tvOS)
            // **TV fades out**: tvOS does not push pages, and the app's areas crossfade too (`Theme.pagesSwitch`).
            let hide = true
            #else
            let hide = calm
            #endif
            if hide {
                UIView.animate(withDuration: calm ? 0.2 : 0.3, delay: calm ? 0 : 0.08,
                               options: [.curveEaseOut], animations: { stillImage.alpha = 0 },
                               completion: { _ in stillImage.removeFromSuperview(); parts.stillImage = nil })
            } else {
                // Like an ordinary back: spring 0.42, no overshoot, 80 ms after the tap.
                UIView.animate(springDuration: 0.42, bounce: 0, initialSpringVelocity: 0, delay: 0.08,
                               options: [], animations: {
                    stillImage.transform = CGAffineTransform(translationX: crop.width, y: 0)
                }, completion: { _ in stillImage.removeFromSuperview(); parts.stillImage = nil })
            }
        }
        guard let curve else { return parts }

        // 2. The flying image: drawn once, then only moved.
        let base = curve.size * 1.06
        let drawer = ImageRenderer(content: image.frame(width: base, height: base))
        drawer.scale = window.screen.scale
        let layer = CALayer()
        layer.contents = drawer.cgImage
        layer.contentsScale = window.screen.scale
        layer.bounds = CGRect(x: 0, y: 0, width: base, height: base)
        layer.position = curve.to
        layer.transform = CATransform3DMakeScale(curve.targetSize / base,
                                                 curve.targetSize / base, 1)
        var places: [NSValue] = [], metrics: [NSNumber] = [], times: [NSNumber] = []
        let steps = max(2, Int(curve.swap * 120))
        for i in 0 ... steps {
            let t = curve.swap * Double(i) / Double(steps)
            let b = curve.status(t)
            places.append(NSValue(cgPoint: CGPoint(x: b.x, y: b.y)))
            metrics.append(NSNumber(value: Double(b.s / base)))
            times.append(NSNumber(value: Double(i) / Double(steps)))
        }
        let place = CAKeyframeAnimation(keyPath: "position")
        place.values = places
        let mass = CAKeyframeAnimation(keyPath: "transform.scale")
        mass.values = metrics
        for a in [place, mass] {
            a.keyTimes = times
            a.duration = curve.swap
            a.beginTime = start
            a.fillMode = .backwards
            a.calculationMode = .linear
            layer.add(a, forKey: a.keyPath)
        }
        window.layer.addSublayer(layer)
        parts.layer = layer

        // 3. The ring, only hinted: from the landing, spring 0.35/0.75, 0.45 s full, then 0.35 s out, at most 55%.
        let ring = CAShapeLayer()
        // On TV as large as the focus ring of the header bar (`ProfileStyle`: 4 point, 8 outside, with magnifier); the pop lands inside it.
        #if os(tvOS)
        let ringMetric: CGFloat = (60 + 16) * Theme.focusMagnifierSmall, stroke: CGFloat = 4
        #else
        let ringMetric: CGFloat = 52, stroke: CGFloat = 2
        #endif
        ring.path = UIBezierPath(ovalIn: CGRect(x: stroke / 2, y: stroke / 2,
                                                width: ringMetric - stroke, height: ringMetric - stroke)).cgPath
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = UIColor(Theme.accent).cgColor
        ring.lineWidth = stroke
        ring.bounds = CGRect(x: 0, y: 0, width: ringMetric, height: ringMetric)
        ring.position = curve.to
        ring.opacity = 0
        var ringMetrics: [NSNumber] = [], ringCoverage: [NSNumber] = [], ringTimes: [NSNumber] = []
        for i in 0 ... 96 {
            let r = 0.8 * Double(i) / 96
            ringMetrics.append(NSNumber(value: Double(AccountSwitchTransition.Curve.spring(0.6, 1, 0, 0.35, 0.75, r))))
            let d = r < 0.45 ? min(1, r / 0.05) : 1 - min(1, (r - 0.45) / 0.35)
            ringCoverage.append(NSNumber(value: d * 0.55))
            ringTimes.append(NSNumber(value: Double(i) / 96))
        }
        let rm = CAKeyframeAnimation(keyPath: "transform.scale")
        rm.values = ringMetrics
        let rd = CAKeyframeAnimation(keyPath: "opacity")
        rd.values = ringCoverage
        for a in [rm, rd] {
            a.keyTimes = ringTimes
            a.duration = 0.8
            a.beginTime = start + curve.landing
            ring.add(a, forKey: a.keyPath)
        }
        window.layer.addSublayer(ring)
        parts.ring = ring

        // Clean up: the image one pass after the swap (the real one is up by then), the ring after its end.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(0, curve.swap + 0.05 - (CACurrentMediaTime() - start))))
            parts.layer?.removeFromSuperlayer()
            parts.layer = nil
            try? await Task.sleep(for: .seconds(max(0, curve.paintEnd + 0.05 - (CACurrentMediaTime() - start))))
            parts.ring?.removeFromSuperlayer()
            parts.ring = nil
        }
        return parts
    }
}

#if DEBUG
/// **Frame times during the account switch, on device** (debug only): a
/// `CADisplayLink` at 120 Hz measures every frame duration; anything taking longer
/// than 1.5 nominal (12.5 ms at 120 Hz) is logged with time, duration and stage. The
/// layers run in the render server and are unaffected; what shows up here is the
/// main thread (home page, header, rows).
@MainActor
final class ImageTimeMeasure: NSObject {
    static let shared = ImageTimeMeasure()
    private var tick: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var last: CFTimeInterval = 0
    private var outlier: [String] = []
    private var images = 0
    var curve: AccountSwitchTransition.Curve?

    func start() {
        tick?.invalidate()
        startTime = CACurrentMediaTime()
        last = 0
        outlier = []
        images = 0
        let t = CADisplayLink(target: self, selector: #selector(image(_:)))
        t.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        t.add(to: .main, forMode: .common)
        tick = t
    }

    func halt() {
        tick?.invalidate()
        tick = nil
        AccountSwitchTransition.note("bildzeit: \(self.images) bilder, \(self.outlier.count) zu lang: \(self.outlier.joined(separator: " "))")
    }

    @objc private func image(_ t: CADisplayLink) {
        images += 1
        defer { last = t.timestamp }
        guard last > 0 else { return }
        let duration = t.timestamp - last
        // The nominal value from the tick itself: 8.3 ms at 120 Hz, 16.7 ms at 60 Hz (simulator, low power).
        let should = max(t.targetTimestamp - t.timestamp, 1.0 / 120)
        guard duration > should * 1.5 else { return }
        let since = t.timestamp - startTime
        outlier.append("\(Int(since * 1000))ms/\(Int(duration * 1000))ms/\(rung(since))")
    }

    private func rung(_ t: Double) -> String {
        guard let k = curve else { return "ohne-flug" }
        if t < 0.08 { return "tipp" }
        if t < AccountSwitchTransition.Curve.grow { return "abheben" }
        if t < 0.55 { return "seite+flug" }
        if t < k.landing { return "flug" }
        if t < k.swap - AccountSwitchTransition.switchPreIdle { return "landung" }
        if t < k.swap { return "wechsel" }
        if t < k.swap + 0.05 { return "tausch" }
        return "reihen"
    }
}
#endif

#if DEBUG
/// **Account-switch self-test**, without interaction and without a real server:
///
/// xcrun simctl launch <device> <bundle id> \
/// -testsitzung http://127.0.0.1:8899 -testsitzung2 -kontowechsellauf
///
/// After launch it opens the profile and switches to the other account there, by
/// the same path as a tap. The sequence is in the log with timestamps, category
/// `accountSwitch`.
enum AccountSwitchRun {
    static var an: Bool { ProcessInfo.processInfo.arguments.contains("-kontowechsellauf") }
    /// `-profileTip <ms>`: tap the profile at the top (open it) this long after the switch tap, in mid-flight or during fade-in.
    static var profileTip: Int? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-profiltipp"), i + 1 < a.count else { return nil }
        return Int(a[i + 1])
    }
    /// The self-test switches once, not on every opening of the profile.
    @MainActor static var wasTapped = false
}
#endif


