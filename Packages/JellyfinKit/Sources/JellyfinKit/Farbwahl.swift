import Foundation

/// **OKLab — Farbe so gerechnet, wie das Auge sie sieht** (Björn Ottosson).
/// Für den Auslauf der Bildfarbe in den Grund (`Bildton`): Helligkeit und
/// Buntheit laufen hier gemeinsam und ohne Farbstich auf ein Grau zu.
///
/// Eine Farbwahl nach Gruppen in OKLCH stand hier vom 27.09. an drei Runden
/// lang; sie traf die Farbe genauer, wirkte aber zu bunt, dann zu tot, und
/// die erste Wahl (`Bildton`, Töne in HSB) gefiel am Ende am besten.
public enum Farbwahl {
    static func abstand(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }

    // MARK: OKLab (Björn Ottosson)

    static func linear(_ x: Double) -> Double {
        x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }
    static func gamma(_ x: Double) -> Double {
        x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
    }

    public static func oklab(_ r8: Double, _ g8: Double, _ b8: Double) -> (L: Double, a: Double, b: Double) {
        let r = linear(r8), g = linear(g8), b = linear(b8)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// OKLab nach sRGB (0…1). `nil`, wenn außerhalb von sRGB.
    public static func srgb(L: Double, a: Double, b: Double) -> (r: Double, g: Double, b: Double)? {
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
        let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let bb = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        guard [r, g, bb].allSatisfy({ $0 >= -0.0001 && $0 <= 1.0001 }) else { return nil }
        return (gamma(max(0, r)), gamma(max(0, g)), gamma(max(0, bb)))
    }

    /// OKLCH nach sRGB mit **erhaltenem Ton**: passt es nicht in sRGB, wird
    /// die Buntheit verringert, nie der Ton verschoben.
    public static func srgb(L: Double, C: Double, h: Double) -> (r: Double, g: Double, b: Double) {
        var c = C
        let w = h * .pi / 180
        while c > 0 {
            if let f = srgb(L: L, a: c * cos(w), b: c * sin(w)) { return f }
            c -= 0.005
        }
        return srgb(L: L, a: 0, b: 0) ?? (L, L, L)
    }
}
