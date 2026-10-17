import Foundation

/// What measuring a title logo yields: the opaque crop, how full it is and how
/// bright.
public struct LogoMeasurement: Equatable, Sendable {
    /// Crop in pixels, without the transparent border.
    public let x: Int, y: Int, width: Int, height: Int
    /// Share of opaque pixels in the crop, 0...1.
    public let density: Double
    /// Mean relative luminance of the opaque pixels, 0...1.
    public let luminance: Double

    public var pagesRatio: Double { Double(width) / Double(max(height, 1)) }
}

/// The rules for title logos: crop, measure, choose size.
/// Pure functions; the image work itself lives in the UI.
public enum TitleMarksMetric {
    /// From here a pixel counts as opaque (out of 255).
    public static let alphaThreshold: UInt8 = 8
    /// Below this a logo counts as dark and is drawn as a light silhouette.
    public static let darkLimit = 0.25

    /// Measures an 8-bit RGBA image, **premultiplied** (row by row, `width * 4`
    /// bytes). `nil` if nothing is opaque.
    public static func measure(rgba: [UInt8], width: Int, height: Int) -> LogoMeasurement? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        var left = width, right = -1, top = height, bottom = -1
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width where rgba[row + x * 4 + 3] > alphaThreshold {
                if x < left { left = x }
                if x > right { right = x }
                if y < top { top = y }
                bottom = y
            }
        }
        guard right >= left, bottom >= top else { return nil }
        var opaque = 0
        var lightSum = 0.0
        for y in top...bottom {
            let row = y * width * 4
            for x in left...right {
                let i = row + x * 4
                let a = Double(rgba[i + 3]) / 255
                guard rgba[i + 3] > alphaThreshold else { continue }
                opaque += 1
                // Premultiplied: divide by alpha, then linearize.
                let r = linear(Double(rgba[i]) / 255 / a)
                let g = linear(Double(rgba[i + 1]) / 255 / a)
                let b = linear(Double(rgba[i + 2]) / 255 / a)
                lightSum += 0.2126 * r + 0.7152 * g + 0.0722 * b
            }
        }
        let b = right - left + 1, h = bottom - top + 1
        return LogoMeasurement(x: left, y: top, width: b, height: h,
                           density: Double(opaque) / Double(b * h),
                           luminance: opaque > 0 ? lightSum / Double(opaque) : 1)
    }

    private static func linear(_ c: Double) -> Double {
        let c = min(max(c, 0), 1)
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    public static func isDark(luminance: Double) -> Bool { luminance < darkLimit }

    /// Gentle compensation: very full logos a little smaller, very thin ones a
    /// little larger, 0.85...1.15.
    public static func densityFactor(_ density: Double) -> Double {
        let d = max(density, 0.05)
        return min(max((0.5 / d).squareRoot(), 0.85), 1.15)
    }

    /// Size for equal visual weight: via a target area instead of a fixed height.
    /// `row` is one title line in points.
    ///
    /// h = sqrt(area / aspect) * density factor, w = h * aspect; then at least one
    /// line high, at most 2.2 lines high and `maxWidth` wide (and, if set, at most
    /// `maxHeight` high); the upper limits win.
    public static func size(pagesRatio: Double, density: Double,
                               row: Double, maxWidth: Double,
                               maxHeight: Double? = nil) -> (width: Double, height: Double) {
        let v = max(pagesRatio, 0.05)
        let area = 12 * row * row
        var h = (area / v).squareRoot() * densityFactor(density)
        h = max(h, row)
        h = min(h, 2.2 * row)
        // A title slot of fixed height (Mac, TV) takes precedence over the minimum height.
        if let maxHeight { h = min(h, max(maxHeight, 1)) }
        var w = h * v
        if w > maxWidth {
            w = max(maxWidth, 1)
            h = w / v
        }
        return (w, h)
    }
}
