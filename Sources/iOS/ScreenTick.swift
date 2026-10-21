import QuartzCore
import SwiftUI

/// **Measures at how many hertz the display serves this app.**
///
/// Not `UIScreen.maximumFramesPerSecond`: that states what the hardware could do
/// and would have dutifully reported 120 on an iPhone 15 Pro while the app
/// actually ran at 60. iOS caps every app at 60 Hz unless it sets
/// `CADisableMinimumFrameDurationOnPhone`; the hardware maximum says nothing
/// about that.
///
/// Only how often CoreAnimation *actually* calls us is reliable. That is what
/// this class counts, over one second so a skipped call does not make the number
/// jump.
///
/// Why it exists: 23.976 frames on 60 Hz do not divide evenly (2.503), on 120 Hz
/// almost (5.005). The difference is exactly the judder in pans, and without this
/// number, whether the cap is gone stays a matter of feel.
///
/// **One second per sample, then the link stops.** A display link that asks for
/// 120 Hz is itself a reason for the display to run at 120 Hz: while it counted
/// continuously, the tech badge held the panel at 120 for the whole film, the
/// very cost it was meant to rule out. Measured on an iPhone 15 Pro: without it,
/// 23.976 fps playback ran the panel at about 36 refreshes a second (intervals
/// of 12.5, 33.3 and 37.5 ms), not 120. The value stays until the next sample.
@MainActor
@Observable
final class ScreenTick {
    /// Measured calls per second of the last sample. `nil` until the first one ends.
    private(set) var hertz: Double?

    @ObservationIgnored private var linkPiece: CADisplayLink?
    @ObservationIgnored private var since: CFTimeInterval = 0
    @ObservationIgnored private var calls = 0

    /// Counts for one second, then stops by itself (see the type).
    func sample() {
        guard linkPiece == nil else { return }
        let target = Forwarding(owner: self)
        let new = CADisplayLink(target: target, selector: #selector(Forwarding.strike))
        // **The range must be requested.** Without it the counter itself runs at the
        // default and measures not the display but its own modesty.
        new.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        new.add(to: .main, forMode: .common)
        linkPiece = new
        since = CACurrentMediaTime()
        calls = 0
    }

    func halt() {
        linkPiece?.invalidate()
        linkPiece = nil
        hertz = nil
    }

    fileprivate func strike() {
        calls += 1
        let now = CACurrentMediaTime()
        let extentSpan = now - since
        guard extentSpan >= 1 else { return }
        hertz = Double(calls) / extentSpan
        linkPiece?.invalidate()
        linkPiece = nil
    }

    /// `CADisplayLink` retains its target. If this went directly to the class, it
    /// would have kept itself alive as long as nobody calls `halt`, and a
    /// forgotten counter on the main thread is exactly the kind of load this tool
    /// should measure.
    ///
    /// `@MainActor` is not a formality here: `CADisplayLink` calls on the main
    /// thread, and without the guarantee Swift 6 demands a hop across the actor
    /// boundary, which cannot exist on an `@objc` method.
    @MainActor
    private final class Forwarding: NSObject {
        weak var owner: ScreenTick?
        init(owner: ScreenTick) { self.owner = owner }
        @objc func strike() { owner?.strike() }
    }
}
