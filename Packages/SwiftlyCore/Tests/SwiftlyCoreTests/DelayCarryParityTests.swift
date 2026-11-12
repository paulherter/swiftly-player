import Testing

import JellyfinKit
@testable import SwiftlyCore

/// `Delay.forNewTitle` (as `VLCPlayerView.delayForNewTitle` called it) against `DelayCarry.forNewTitle` (the
/// core's `delayForNewTitle`) over the delays, the same/other titles and the series that match, differ or are missing.
@Suite struct DelayCarryParityTests {
    @Test func theGridCarriesTheSameDelay() {
        let delays = [-10_000, -9_950, -200, -50, 0, 50, 350, 10_000].map { Delay(milliseconds: $0) }
        let titles = [("e1", "e1"), ("e1", "e2"), ("m", "n")]
        let series: [(String?, String?)] = [(nil, nil), ("s", "s"), ("s", "t"), ("s", nil), (nil, "s")]
        var checked = 0
        for delay in delays {
            for (oldTitle, newTitle) in titles {
                for (oldSeries, addedSeries) in series {
                    let old = Delay.forNewTitle(
                        delay, oldTitle: oldTitle, oldSeries: oldSeries, newTitle: newTitle, addedSeries: addedSeries)
                    let new = DelayCarry.forNewTitle(
                        delay, oldTitle: oldTitle, oldSeries: oldSeries, newTitle: newTitle, addedSeries: addedSeries)
                    #expect(old == new, "\(delay) \(oldTitle)>\(newTitle) \(String(describing: oldSeries))/\(String(describing: addedSeries))")
                    checked += 1
                }
            }
        }
        #expect(checked == 120)
    }
}
