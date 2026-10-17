import Foundation
import Testing
@testable import JellyfinKit

/// Page change without cross-fade, and the curves for it.
@Suite struct FadeTimesTests {
    /// **Never both at once:** as long as the old page has opacity, the
    /// new one has none.
    @Test func neverOverFade() {
        var t = 0.0
        while t <= FadeTimes.pageTotal + 0.05 {
            let d = FadeTimes.pagesSwitch(t)
            #expect(d.alt == 0 || d.new == 0, "bei \(t): \(d)")
            t += 0.005
        }
    }

    @Test func startAndEnd() {
        let a = FadeTimes.pagesSwitch(0)
        #expect(a.alt == 1 && a.new == 0)
        let center = FadeTimes.pagesSwitch(FadeTimes.pageToOut)
        #expect(center.alt == 0 && center.new == 0)
        let e = FadeTimes.pagesSwitch(FadeTimes.pageTotal)
        #expect(e.alt == 0 && e.new == 1)
    }

    /// Out shorter than in; the arrows in the range 150-200 ms.
    @Test func lastFor() {
        #expect(FadeTimes.pageToOut < FadeTimes.pageFromIn)
        #expect(FadeTimes.arrows >= 0.15 && FadeTimes.arrows <= 0.2)
    }

    /// `easeIn` starts slowly, `easeOut` ends slowly, both hit
    /// 0 and 1.
    @Test func curves() {
        for k in [FadeTimes.easeIn, FadeTimes.easeOut, FadeTimes.easeInOut] {
            #expect(abs(k(0)) < 1e-9 && abs(k(1) - 1) < 1e-9)
        }
        #expect(FadeTimes.easeIn(0.5) < 0.5)
        #expect(FadeTimes.easeOut(0.5) > 0.5)
        #expect(abs(FadeTimes.easeInOut(0.5) - 0.5) < 0.01)
    }
}
