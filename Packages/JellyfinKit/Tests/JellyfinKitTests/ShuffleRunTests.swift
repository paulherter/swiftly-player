import Testing
@testable import JellyfinKit

@Suite("Zufällig abspielen")
struct ShuffleRunTests {
    struct Fixed: RandomNumberGenerator {
        var state: UInt64 = 42
        mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
    }

    @Test("Ungesehene zuerst, nichts geht verloren")
    func unplayedFirst() {
        var g = Fixed()
        let items = Array(1...20)
        let out = ShuffleRun.mix(items, isPlayed: { $0 % 2 == 0 }, using: &g)
        #expect(out.sorted() == items)
        #expect(out.prefix(10).allSatisfy { $0 % 2 == 1 })
    }
}
