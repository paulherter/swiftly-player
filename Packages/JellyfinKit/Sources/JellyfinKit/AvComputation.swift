import Foundation

/// **The computation behind the image color**: from the pixels of an image to
/// the hues, and from the hues to the color at every point of a page.
///
/// Apple and Android TV compute the same numbers from this one place. Decoding
/// the image and drawing stay with the platform.
///
/// The reasoning for the individual steps (circular mean, weighting by the
/// square of the saturation, several peaks, taking only the hue from the
/// image) is documented at `ImageTone` in `Sources/Shared/ImageTone.swift`.
public enum AvComputation {

    // MARK: Numbers (style tokens, `Colors.swift`)

    /// Saturation away from the backdrop.
    public static let saturation = 0.38
    /// Saturation added near the backdrop.
    public static let saturationNear = 0.20
    /// Brightness away from the backdrop, just above `reason`.
    public static let brightness = 0.075
    /// Brightness added near the backdrop.
    public static let brightnessNear = 0.140
    /// How fast brightness falls with distance (exponent).
    public static let drop = 1.6
    /// How far the secondary hues may deviate from the main hue (fraction).
    public static let spanRange = 0.34

    /// `reason` (#101010) in OKLab; every fade ends exactly here.
    public static let reasonL = ColorSelection.oklab(16.0 / 255, 16.0 / 255, 16.0 / 255).L

    // MARK: Hues from the image

    /// Up to five hues in degrees, by weight; empty if none can be derived.
    /// `rgba`: pixels of four bytes each (red, green, blue, alpha), ideally
    /// downscaled to at most 48 pixels on a side.
    public static func tones(rgba points: [UInt8]) -> [Double] {
        let bins = 36
        var bucket = [Double](repeating: 0, count: bins)
        var total = 0.0

        var i = 0
        while i + 3 < points.count {
            let r = Double(points[i]) / 255
            let g = Double(points[i + 1]) / 255
            let b = Double(points[i + 2]) / 255
            i += 4

            let up = max(r, g, b), deep = min(r, g, b)
            let extentSpan = up - deep
            guard extentSpan > 0.04, up > 0.08 else { continue }

            let saturation = extentSpan / up
            var audio: Double
            switch up {
            case r: audio = (g - b) / extentSpan
            case g: audio = 2 + (b - r) / extentSpan
            default: audio = 4 + (r - g) / extentSpan
            }
            audio *= 60
            if audio < 0 { audio += 360 }

            let weight = saturation * saturation * up
            bucket[min(bins - 1, Int(audio / 10))] += weight
            total += weight
        }

        guard total > 0.5 else { return [] }

        // Pick peaks: the strongest bin, then the strongest one at least
        // three bins (30 degrees) away, and so on.
        var selected: [Double] = []
        var leftover = bucket
        for _ in 0 ..< 5 {
            guard let (compartment, value) = leftover.enumerated().max(by: { $0.element < $1.element }),
                  value > total * 0.035 else { break }
            // The exact hue comes from the bin and its neighbors, so it does not
            // snap to multiples of ten degrees.
            var x = 0.0, y = 0.0
            for offset in -1 ... 1 {
                let f = (compartment + offset + bins) % bins
                let arc = (Double(f) * 10 + 5) * .pi / 180
                x += cos(arc) * bucket[f]
                y += sin(arc) * bucket[f]
            }
            var grad = atan2(y, x) * 180 / .pi
            if grad < 0 { grad += 360 }
            selected.append(grad)
            for offset in -1 ... 1 { leftover[(compartment + offset + bins) % bins] = 0 }
        }
        return selected
    }

    // MARK: Color at a point

    /// The hue at position `run` (0…1), blended between the hues found along the
    /// shortest path on the color wheel; each hue is moved toward the main
    /// color by ``spannweite``.
    public static func audioAt(_ tones: [Double], _ run: Double) -> Double {
        guard let lead = tones.first else { return 0 }
        func damped(_ audio: Double) -> Double {
            var distance = audio - lead
            if distance > 180 { distance -= 360 }
            if distance < -180 { distance += 360 }
            return lead + distance * spanRange
        }
        guard tones.count > 1 else { return lead }

        let spot = run * Double(tones.count - 1)
        let a = max(0, min(Int(spot), tones.count - 2))
        let t = spot - Double(a)

        let from = damped(tones[a]), until = damped(tones[a + 1])
        var distance = until - from
        if distance > 180 { distance -= 360 }
        if distance < -180 { distance += 360 }
        var audio = from + distance * (t * t * (3 - 2 * t))
        if audio < 0 { audio += 360 }
        if audio >= 360 { audio -= 360 }
        return audio
    }

    /// Hue, saturation and brightness (each 0…1, hue in degrees) at a point of
    /// the surface: `x` from left to right, `y` from top to bottom, both 0…1.
    /// The backdrop sits at the top right, where it is brightest.
    public static func hsb(_ tones: [Double], x: Double, y: Double)
        -> (audio: Double, saturation: Double, brightness: Double) {
        let dx = 1 - x, dy = y
        let proximity = 1 - min(1, (dx * dx + dy * dy).squareRoot() / 1.414)
        return (audioAt(tones, (x + y) / 2),
                saturation + saturationNear * proximity,
                brightness + brightnessNear * pow(proximity, drop))
    }

    /// The same color as sRGB (0…1); `decay` (1 … 0) leads it back to
    /// `reason` **in OKLab**: brightness and chroma together, until at 0 exactly
    /// `reason` remains. Without hues: `reason`.
    public static func color(_ tones: [Double], x: Double, y: Double, decay f: Double = 1)
        -> (r: Double, g: Double, b: Double) {
        let gray = 16.0 / 255
        guard !tones.isEmpty else { return (gray, gray, gray) }
        let t = hsb(tones, x: x, y: y)
        let rgb = hsbPostRGB(t.audio, t.saturation, t.brightness)
        if f >= 1 { return rgb }
        let lab = ColorSelection.oklab(rgb.r, rgb.g, rgb.b)
        let L = reasonL + (lab.L - reasonL) * f
        return ColorSelection.srgb(L: L, a: lab.a * f, b: lab.b * f) ?? (L, L, L)
    }

    /// How much of the color is still present on the way into the background
    /// (1 … 0): fully until `since`, then over `runOut` on a smootherstep curve
    /// to exactly zero, with no kink at start or end.
    public static func decay(y: Double, since: Double, runOut: Double) -> Double {
        guard runOut > 0 else { return y < since ? 1 : 0 }
        let t = max(0, min(1, (y - since) / runOut))
        return 1 - t * t * t * (t * (t * 6 - 15) + 10)
    }

    /// **The mesh of a detail page that fades out into `reason`**, as points:
    /// `columns` × `rows` colors (row by row, ARGB with full alpha) over the
    /// height `height`. At the top the TV image above `colorHeight`, from `since` over
    /// `runOut` exactly to `reason`. The platform interpolates the points
    /// smoothly across the surface (bilinear); this replaces the mesh SwiftUI has
    /// as `MeshGradient`. Without a fade (`runOut` 0, `since` ≥ `height`) it is the
    /// background of a whole page, as on the TV.
    public static func points(_ tones: [Double], columns: Int, rows: Int, height: Double,
                              colorHeight: Double, since: Double, runOut: Double) -> [Int32] {
        guard columns > 1, rows > 1, height > 0 else { return [] }
        var from: [Int32] = []
        from.reserveCapacity(columns * rows)
        for z in 0 ..< rows {
            let y = height * Double(z) / Double(rows - 1)
            let f = decay(y: y, since: since, runOut: runOut)
            for s in 0 ..< columns {
                let x = Double(s) / Double(columns - 1)
                let c = color(tones, x: x, y: min(1, y / max(colorHeight, 1)), decay: f)
                func k(_ w: Double) -> UInt32 { UInt32(max(0, min(255, (w * 255).rounded()))) }
                let argb: UInt32 = 0xFF00_0000 | (k(c.r) << 16) | (k(c.g) << 8) | k(c.b)
                from.append(Int32(bitPattern: argb))
            }
        }
        return from
    }

    /// HSB to sRGB (0…1).
    public static func hsbPostRGB(_ h: Double, _ s: Double, _ v: Double) -> (r: Double, g: Double, b: Double) {
        let c = v * s, hh = h / 60, x = c * (1 - abs(hh.truncatingRemainder(dividingBy: 2) - 1)), m = v - c
        switch Int(hh) % 6 {
        case 0: return (c + m, x + m, m)
        case 1: return (x + m, c + m, m)
        case 2: return (m, c + m, x + m)
        case 3: return (m, x + m, c + m)
        case 4: return (x + m, m, c + m)
        default: return (c + m, m, x + m)
        }
    }
}
