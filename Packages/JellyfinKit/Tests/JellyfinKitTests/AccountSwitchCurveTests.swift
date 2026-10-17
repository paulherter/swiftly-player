import Foundation
import Testing
@testable import JellyfinKit

/// The flight of the profile picture on account switch. Apple, Android, Linux and Windows follow the same path.
@Suite struct AccountSwitchCurveTests {
    /// From the account card (bottom left, middle) to the top right, as on the iPhone.
    private let curve = AccountSwitchCurve(fromX: 60, fromY: 420, size: 40, toX: 360, toY: 70)

    /// **It grows in place first**, then lifts off; at the end it rests exactly on the target at target size.
    @Test func fromCardPostTop() {
        let beginning = curve.status(0)
        #expect(beginning.x == 60 && beginning.y == 420 && beginning.s == 40)
        #expect(abs(curve.status(AccountSwitchCurve.grow).s - 42.4) < 0.01)
        let end = curve.status(curve.swap)
        #expect(abs(end.x - 360) <= 0.3 && abs(end.y - 70) <= 0.3 && abs(end.s - 34) <= 0.3)
    }

    /// **Landing first, then ring; the switch before the rest point**, no earlier than 0.6 s. (The landing can
    /// come after the rest point: if the image sits just above the target, it crosses the target height only afterwards.)
    @Test func schedule() {
        #expect(curve.landing > AccountSwitchCurve.grow)
        #expect(curve.paintEnd > curve.landing)
        #expect(curve.change >= 0.6 && curve.change <= curve.swap)
        #expect(curve.swap < 3)
    }

    /// **The ring** pops in from 60 % and fades out after 0.8 s, at most 55 % opacity.
    @Test func ring() {
        #expect(abs(AccountSwitchCurve.ring(0).mass - 0.6) < 0.001)
        #expect(AccountSwitchCurve.ring(0).coverage == 0)
        #expect(abs(AccountSwitchCurve.ring(0.3).coverage - 0.55) < 0.001)
        #expect(AccountSwitchCurve.ring(0.8).coverage < 0.001)
    }

    /// The distance of the design: 297 to the right, 171 up, 72 → 34.
    let draft = AccountSwitchCurve(from: (100, 400), size: 72, to: (397, 229), targetSize: 34)

    @Test func startAtStartAndLiftsOff() {
        let a = draft.status(0)
        #expect(a.x == 100 && a.y == 400 && a.s == 72)
        let b = draft.status(AccountSwitchCurve.grow)
        #expect(abs(b.s - 72 * 1.06) < 0.01)
    }

    @Test func restsAtTarget() {
        let e = draft.status(draft.swap)
        #expect(abs(e.x - 397) <= 0.3 && abs(e.y - 229) <= 0.3 && abs(e.s - 34) <= 0.3)
        #expect(draft.swap > 0.6 && draft.swap < 3)
    }

    /// Swing out to the side first, then move in: the swing points away from the target.
    @Test func fetchesOut() {
        let early = draft.status(AccountSwitchCurve.grow + 0.03)
        #expect(early.x < 100)
    }

    /// The ring appears at the landing (which can be within 0.3 points of the
    /// rest point after it, since the last swing is smaller); the account switches
    /// before the rest point, no earlier than 0.6 s.
    @Test func railsEpisode() {
        #expect(draft.landing > AccountSwitchCurve.grow)
        #expect(draft.paintEnd > draft.landing)
        #expect(draft.change >= AccountSwitchCurve.switchEarliest)
        #expect(draft.change <= max(draft.swap, AccountSwitchCurve.switchEarliest))
    }

    /// No path, no movement: if the image is already at the target, it rests immediately.
    @Test func withoutDistance() {
        let k = AccountSwitchCurve(from: (10, 10), size: 34, to: (10, 10), targetSize: 34)
        #expect(k.swap < 1)
    }
}
