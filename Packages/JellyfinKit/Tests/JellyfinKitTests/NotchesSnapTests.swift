import Testing
@testable import JellyfinKit

@Suite struct NotchesSnapTests {
    // 2700 s on 270 points: one point is ten seconds, the snap range 80 s.
    @Test func closeEnoughSnaps() {
        #expect(NotchesSnap.notch(value: 150, until: 2700, marks: [90, 2500], width: 270) == 90)
    }

    @Test func wideDistanceStaysFree() {
        #expect(NotchesSnap.notch(value: 400, until: 2700, marks: [90, 2500], width: 270) == nil)
    }

    @Test func closerOneWins() {
        #expect(NotchesSnap.notch(value: 100, until: 2700, marks: [60, 110], width: 270) == 110)
    }

    @Test func edgesCountNot() {
        #expect(NotchesSnap.notch(value: 5, until: 2700, marks: [0, 2700], width: 270) == nil)
    }

    @Test func withoutWidthNoSnap() {
        #expect(NotchesSnap.notch(value: 90, until: 2700, marks: [90], width: 0) == nil)
    }
}
