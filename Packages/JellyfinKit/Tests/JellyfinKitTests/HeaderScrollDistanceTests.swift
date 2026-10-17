import Testing
@testable import JellyfinKit

@Suite struct HeaderScrollDistanceTests {
    /// Values taken from measurements.
    @Test func sumIsDistance() {
        #expect(abs(HeaderScrollDistance.distance(margin: 130.8, offset: -130.3)! - 0.5) < 0.001)
        #expect(abs(HeaderScrollDistance.distance(margin: 115.0, offset: -114.7)! - 0.3) < 0.001)
        #expect(HeaderScrollDistance.distance(margin: 115, offset: 85) == 200)
    }

    @Test func intermediateIsSkipped() {
        #expect(HeaderScrollDistance.distance(margin: 130.8, offset: 0) == nil)
        #expect(HeaderScrollDistance.distance(margin: 130.8, offset: 0.4) == nil)
    }

    @Test func withoutEdgeCountsAlsoNull() {
        #expect(HeaderScrollDistance.distance(margin: 0, offset: 0) == 0)
    }
}
