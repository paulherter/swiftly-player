import Testing
@testable import JellyfinKit

@Suite struct JumpTargetTests {
    @Test func noNumberIsNoTarget() {
        #expect(JumpTarget.seconds(.nan) == nil)
        #expect(JumpTarget.seconds(.infinity) == nil)
        #expect(JumpTarget.seconds(-.infinity) == nil)
    }

    @Test func becomesLimited() {
        #expect(JumpTarget.seconds(-3) == 0)
        #expect(JumpTarget.seconds(125.5) == 125.5)
        #expect(JumpTarget.seconds(1e300) == JumpTarget.upperLimit)
    }

    @Test func millisecondsOverRunNever() {
        // Exactly the conversion the player does afterwards.
        let ms = Int(JumpTarget.seconds(.greatestFiniteMagnitude)! * 1000)
        #expect(Int32(clamping: ms) == 1_000_000_000)
    }
}
