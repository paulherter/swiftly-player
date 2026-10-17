import Foundation
import Testing
@testable import JellyfinKit

@Suite struct PauseJumpBackTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func shortPauseStaysState() {
        let since = now.addingTimeInterval(-PauseJumpBack.threshold)
        #expect(PauseJumpBack.target(position: 600, pausedSince: since, now: now,
                                       inGroup: false) == nil)
    }

    @Test func longPauseSetsBack() {
        let since = now.addingTimeInterval(-PauseJumpBack.threshold - 1)
        #expect(PauseJumpBack.target(position: 600, pausedSince: since, now: now,
                                       inGroup: false) == 600 - PauseJumpBack.range)
    }

    @Test func notPreStart() {
        let since = now.addingTimeInterval(-3600)
        #expect(PauseJumpBack.target(position: 2, pausedSince: since, now: now,
                                       inGroup: false) == 0)
        #expect(PauseJumpBack.target(position: 0, pausedSince: since, now: now,
                                       inGroup: false) == nil)
        #expect(PauseJumpBack.target(position: .nan, pausedSince: since, now: now,
                                       inGroup: false) == nil)
    }

    @Test func inGroupNever() {
        let since = now.addingTimeInterval(-3600)
        #expect(PauseJumpBack.target(position: 600, pausedSince: since, now: now,
                                       inGroup: true) == nil)
    }

    @Test func withoutPauseNever() {
        #expect(PauseJumpBack.target(position: 600, pausedSince: nil, now: now,
                                       inGroup: false) == nil)
    }
}
