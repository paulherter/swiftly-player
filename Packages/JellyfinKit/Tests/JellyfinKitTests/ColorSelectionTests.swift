import Foundation
import Testing
@testable import JellyfinKit

/// The color math in OKLab, on which the fade-out of the image color rests.
@Suite struct ColorSelectionTests {
    /// **There and back** gives the same color.
    @Test func toAndBack() throws {
        let lab = ColorSelection.oklab(0.6, 0.13, 0.11)
        let rgb = try #require(ColorSelection.srgb(L: lab.L, a: lab.a, b: lab.b))
        #expect(abs(rgb.r - 0.6) < 0.002 && abs(rgb.g - 0.13) < 0.002 && abs(rgb.b - 0.11) < 0.002)
    }

    /// **Gray has no chroma**, the target of every fade-out.
    @Test func grayIsAchromatic() {
        let lab = ColorSelection.oklab(16.0 / 255, 16.0 / 255, 16.0 / 255)
        #expect(abs(lab.a) < 0.0005 && abs(lab.b) < 0.0005)
    }

    /// **The hue stays when the color does not fit in sRGB**; the chroma
    /// gives way, not the hue.
    @Test func audioStaysInFit() {
        let f = ColorSelection.srgb(L: 0.25, C: 0.4, h: 29)
        let lab = ColorSelection.oklab(f.r, f.g, f.b)
        var h = atan2(lab.b, lab.a) * 180 / .pi
        if h < 0 { h += 360 }
        #expect(ColorSelection.spacing(h, 29) < 3)
    }
}
