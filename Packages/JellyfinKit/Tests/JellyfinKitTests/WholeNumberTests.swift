import Testing
@testable import JellyfinKit

/// `Int(capped:)`: on 32-bit Android `Int` is only 32 bits, and `Int(x)` crashed there.
@Suite("Ganzzahl")
struct WholeNumberTests {
    @Test func ordinary() {
        #expect(Int(capped: 42.9) == 42)
        #expect(Int(capped: -3.5) == -3)
    }

    @Test func nanAndInfinity() {
        #expect(Int(capped: .nan) == 0)
        #expect(Int(capped: .infinity) == .max)
        #expect(Int(capped: -.infinity) == .min)
    }

    @Test func tooLarge() {
        #expect(Int(capped: 1e30) == .max)
        #expect(Int(capped: -1e30) == .min)
    }

    /// A 4 GB file with a wrong runtime of one second: 34 Gbit/s, clamped instead of crashing.
    @Test func bitrateWrongRuntime() {
        let b = DownloadQuality.bitrate(bytes: 4_294_967_296, runtimeTicks: 10_000_000)
        #expect(b != nil && b! > 0)
    }

    @Test func runtimeHuge() {
        #expect(!runtime(9.2e11).isEmpty)
        #expect(!timeText(.nan).isEmpty)
    }
}
