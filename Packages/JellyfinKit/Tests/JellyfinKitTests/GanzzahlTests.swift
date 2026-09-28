import Testing
@testable import JellyfinKit

/// `Int(gekappt:)` — auf 32-Bit-Android ist `Int` nur 32 Bit, dort brach `Int(x)` ab.
@Suite("Ganzzahl")
struct GanzzahlTests {
    @Test func gewoehnlich() {
        #expect(Int(gekappt: 42.9) == 42)
        #expect(Int(gekappt: -3.5) == -3)
    }

    @Test func nanUndUnendlich() {
        #expect(Int(gekappt: .nan) == 0)
        #expect(Int(gekappt: .infinity) == .max)
        #expect(Int(gekappt: -.infinity) == .min)
    }

    @Test func zuGross() {
        #expect(Int(gekappt: 1e30) == .max)
        #expect(Int(gekappt: -1e30) == .min)
    }

    /// Eine 4-GB-Datei mit falscher Laufzeit von einer Sekunde: 34 Gbit/s — gekappt statt Absturz.
    @Test func bitrateFalscheLaufzeit() {
        let b = Downloadqualitaet.bitrate(bytes: 4_294_967_296, laufzeitTicks: 10_000_000)
        #expect(b != nil && b! > 0)
    }

    @Test func laufzeitRiesig() {
        #expect(!laufzeit(9.2e11).isEmpty)
        #expect(!zeitText(.nan).isEmpty)
    }
}
