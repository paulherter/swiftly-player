import Foundation
import Testing
@testable import JellyfinKit

/// The image color, computed the way Apple and Android compute it.
@Suite struct AvComputationTests {
    private func area(_ r: UInt8, _ g: UInt8, _ b: UInt8, points: Int = 256) -> [UInt8] {
        (0 ..< points).flatMap { _ in [r, g, b, 255] }
    }

    /// **A red image has the red hue**, a gray one none.
    @Test func audioOutImage() throws {
        let rot = AvComputation.tones(rgba: area(200, 30, 30))
        let audio = try #require(rot.first)
        #expect(ColorSelection.spacing(audio, 0) < 6)
        #expect(AvComputation.tones(rgba: area(120, 120, 120)).isEmpty)
    }

    /// **Two colors, two hues**, with a minimum distance, by weight.
    @Test func twoPeak() {
        let image = area(20, 60, 200, points: 300) + area(220, 140, 20, points: 100)
        let tones = AvComputation.tones(rgba: image)
        #expect(tones.count == 2)
        #expect(ColorSelection.spacing(tones[0], 225) < 12)
        #expect(ColorSelection.spacing(tones[1], 38) < 12)
    }

    /// **The fade-out ends exactly on `reason`** and starts without a jump.
    @Test func runOutEndsReason() {
        #expect(AvComputation.decay(y: 100, since: 300, runOut: 1300) == 1)
        #expect(AvComputation.decay(y: 1600, since: 300, runOut: 1300) == 0)
        #expect(abs(AvComputation.decay(y: 301, since: 300, runOut: 1300) - 1) < 0.0001)
        let c = AvComputation.color([200], x: 0.9, y: 0.1, decay: 0)
        #expect(abs(c.r - 16.0 / 255) < 0.003 && abs(c.g - 16.0 / 255) < 0.003 && abs(c.b - 16.0 / 255) < 0.003)
    }

    /// **Brightest at the top right**, where the backdrop sits.
    @Test func backdropTopRight() {
        let near = AvComputation.hsb([200], x: 1, y: 0)
        let far = AvComputation.hsb([200], x: 0, y: 1)
        #expect(near.brightness > far.brightness)
        #expect(abs(near.brightness - (AvComputation.brightness + AvComputation.brightnessNear)) < 0.0001)
    }

    /// **Points for the surface**: count, full opacity, base color when there are no hues.
    @Test func points() {
        let p = AvComputation.points([30, 200], columns: 5, rows: 8, height: 1000, colorHeight: 900,
                                       since: 300, runOut: 600)
        #expect(p.count == 40)
        #expect(p.allSatisfy { UInt32(bitPattern: $0) >> 24 == 0xFF })
        let gray = AvComputation.points([], columns: 2, rows: 2, height: 10, colorHeight: 10, since: 10, runOut: 0)
        #expect(gray.allSatisfy { UInt32(bitPattern: $0) == 0xFF10_1010 })
    }
}
