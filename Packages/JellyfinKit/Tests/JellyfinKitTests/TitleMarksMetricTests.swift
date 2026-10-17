import Testing
@testable import JellyfinKit

@Suite struct TitleMarksMetricTests {
    /// 6×4 image, one opaque rectangle (columns 2-3, rows 1-2).
    private func image(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: 6 * 4 * 4)
        for y in 1...2 { for x in 2...3 {
            let i = (y * 6 + x) * 4
            px[i] = r; px[i + 1] = g; px[i + 2] = b; px[i + 3] = 255
        } }
        return px
    }

    @Test func alphaBoxCutsEdge() throws {
        let m = try #require(TitleMarksMetric.measure(rgba: image(255, 255, 255), width: 6, height: 4))
        #expect(m.x == 2 && m.y == 1 && m.width == 2 && m.height == 2)
        #expect(m.density == 1)
    }

    @Test func emptyImageGivesNil() {
        #expect(TitleMarksMetric.measure(rgba: [UInt8](repeating: 0, count: 6 * 4 * 4), width: 6, height: 4) == nil)
    }

    @Test func weakEdgePixelsDontCount() throws {
        var px = image(255, 255, 255)
        px[3] = 8   // top left corner, just under the threshold
        px[(3 * 6 + 5) * 4 + 3] = 9 // just over
        let m = try #require(TitleMarksMetric.measure(rgba: px, width: 6, height: 4))
        #expect(m.x == 2 && m.y == 1 && m.width == 4 && m.height == 3)
    }

    @Test func darkId() throws {
        let black = try #require(TitleMarksMetric.measure(rgba: image(0, 0, 0), width: 6, height: 4))
        let white = try #require(TitleMarksMetric.measure(rgba: image(255, 255, 255), width: 6, height: 4))
        let rot = try #require(TitleMarksMetric.measure(rgba: image(230, 30, 30), width: 6, height: 4))
        #expect(TitleMarksMetric.isDark(luminance: black.luminance))
        #expect(!TitleMarksMetric.isDark(luminance: white.luminance))
        #expect(!TitleMarksMetric.isDark(luminance: rot.luminance + 0.2))
    }

    @Test func densityFactorLimited() {
        #expect(TitleMarksMetric.densityFactor(1) == 0.85)
        #expect(TitleMarksMetric.densityFactor(0.01) == 1.15)
        #expect(TitleMarksMetric.densityFactor(0.5) == 1)
    }

    @Test func equalWeightInsteadOfEqualHeight() {
        let z = 28.0, maxB = 250.0
        let from = TitleMarksMetric.size(pagesRatio: 3, density: 0.5, row: z, maxWidth: maxB)
        let wideFlat = TitleMarksMetric.size(pagesRatio: 8, density: 0.5, row: z, maxWidth: maxB)
        let squareAdvice = TitleMarksMetric.size(pagesRatio: 1.2, density: 0.5, row: z, maxWidth: maxB)
        #expect(wideFlat.height > z && wideFlat.width <= maxB + 0.001)
        #expect(wideFlat.width > from.width)
        #expect(squareAdvice.height > from.height)
        // Never above 2.2 rows, never below one.
        #expect(squareAdvice.height <= 2.2 * z + 0.001)
        let tiny = TitleMarksMetric.size(pagesRatio: 20, density: 0.5, row: z, maxWidth: 1000)
        #expect(tiny.height >= z - 0.001)
    }

    @Test func densityLogosAreSmaller() {
        let dense = TitleMarksMetric.size(pagesRatio: 3, density: 0.9, row: 28, maxWidth: 250)
        let thin = TitleMarksMetric.size(pagesRatio: 3, density: 0.25, row: 28, maxWidth: 250)
        #expect(dense.height < thin.height)
    }

    @Test func titleCompartmentCapHeight() {
        let g = TitleMarksMetric.size(pagesRatio: 1.2, density: 0.5, row: 28,
                                        maxWidth: 500, maxHeight: 42)
        #expect(g.height <= 42.001)
        #expect(abs(g.width - g.height * 1.2) < 0.001)
    }
}
