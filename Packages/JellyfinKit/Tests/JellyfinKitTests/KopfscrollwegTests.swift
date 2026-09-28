import Testing
@testable import JellyfinKit

@Suite struct KopfscrollwegTests {
    /// Die Werte aus der Messung vom 22.09.2026.
    @Test func summeIstDerWeg() {
        #expect(abs(Kopfscrollweg.weg(rand: 130.8, versatz: -130.3)! - 0.5) < 0.001)
        #expect(abs(Kopfscrollweg.weg(rand: 115.0, versatz: -114.7)! - 0.3) < 0.001)
        #expect(Kopfscrollweg.weg(rand: 115, versatz: 85) == 200)
    }

    @Test func zwischenstandWirdUebergangen() {
        #expect(Kopfscrollweg.weg(rand: 130.8, versatz: 0) == nil)
        #expect(Kopfscrollweg.weg(rand: 130.8, versatz: 0.4) == nil)
    }

    @Test func ohneRandZaehltAuchNull() {
        #expect(Kopfscrollweg.weg(rand: 0, versatz: 0) == 0)
    }
}
