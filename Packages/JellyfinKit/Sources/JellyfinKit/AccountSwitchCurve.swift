import Foundation

/// Flight path of the profile picture when switching accounts.
///
/// Three springs, one per axis: horizontal is critically damped with an initial
/// push to the left, vertical is slightly bouncy with a small push down, and
/// size is separate. **Computed instead of animated**: only then can initial
/// velocity, landing and rest be known up front. The swap to the real image
/// happens at rest, the account switch runs shortly before, and the ring pops
/// on landing.
///
/// Lives in the package so every platform flies the same path. The push grows
/// with the distance so the arc keeps its shape on other screen sizes
/// (reference: 297 x -171 pt).
/// Sizes in points (iOS) or dp (Android), times in seconds from the tap.
public struct AccountSwitchCurve: Sendable, Equatable {
    public let fromX, fromY, size, toX, toY: Double
    /// Size of the image at the target (top right on iPhone, smaller on TV).
    public let target: Double
    /// When the image is at rest (within 0.3 pt).
    public let swap: Double
    /// When it first falls back to target height: the ring pops here.
    public let landing: Double
    public var paintEnd: Double { landing + 0.8 }

    /// The image grows 6% in place for this long before it lifts off.
    public static let grow = 0.1
    /// Size of the profile picture at the top right.
    public static let targetSize = 34.0
    /// **When the account actually switches**: 0.3 s before the image rests. The
    /// switch costs the main loop time, and shortly before rest the image moves
    /// only by fractions of a point.
    public static let switchPreIdle = 0.3
    /// The account switches no earlier than this after the tap.
    public static let switchEarliest = 0.6

    public init(fromX: Double, fromY: Double, size: Double, toX: Double, toY: Double,
                targetSize: Double = AccountSwitchCurve.targetSize) {
        self.fromX = fromX; self.fromY = fromY; self.size = size
        self.toX = toX; self.toY = toY; self.target = targetSize
        var idle = 0.0, over = -1.0, land = -1.0
        var t = Self.grow
        let dt = 1.0 / 240
        while t < 5 {
            let b = Self.status(fromX, fromY, size, toX, toY, targetSize, t)
            if max(abs(b.x - toX), abs(b.y - toY), abs(b.s - targetSize)) > 0.3 { idle = t }
            if over < 0, b.y < toY - 0.5 { over = t }
            if over >= 0, land < 0, b.y >= toY { land = t }
            t += dt
        }
        swap = idle + dt
        landing = land >= 0 ? land : (over >= 0 ? over : swap - 0.3)
    }

    /// Same, with points as pairs (Linux, Windows).
    public init(from: (x: Double, y: Double), size: Double, to: (x: Double, y: Double),
                targetSize: Double) {
        self.init(fromX: from.x, fromY: from.y, size: size, toX: to.x, toY: to.y,
                  targetSize: targetSize)
    }

    /// When the account switches: `switchPreIdle` before rest, but no earlier
    /// than `switchEarliest`.
    public var change: Double { max(Self.switchEarliest, swap - Self.switchPreIdle) }

    /// Center and size of the image after `t` seconds.
    public func status(_ t: Double) -> (x: Double, y: Double, s: Double) {
        Self.status(fromX, fromY, size, toX, toY, target, t)
    }

    private static func status(_ vx0: Double, _ vy0: Double, _ size: Double, _ nx: Double, _ ny: Double,
                             _ zs: Double, _ t: Double) -> (x: Double, y: Double, s: Double) {
        if t < grow {
            let k = max(0, min(1, t / grow))
            return (vx0, vy0, size * (1 + 0.06 * k))
        }
        let u = t - grow
        // The push grows with the distance so the arc keeps its shape on other
        // screen sizes. **Calmer than the original design**: half the initial push,
        // longer responses and almost critical damping.
        let vx = -900 * (nx - vx0) / 297
        let vy = 80 * (ny - vy0) / -171
        return (spring(vx0, nx, vx, 0.8, 1, u),
                spring(vy0, ny, vy, 0.9, 0.88, u),
                spring(size * 1.06, zs, 0, 0.8, 0.95, u))
    }

    /// A damped spring, solved in closed form: response `r` (s), damping `z`,
    /// initial velocity `v0` (per second).
    public static func spring(_ from: Double, _ to: Double, _ v0: Double,
                             _ r: Double, _ z: Double, _ t: Double) -> Double {
        guard t > 0 else { return from }
        let w = 2 * Double.pi / r, x0 = from - to
        let x: Double
        if z < 1 {
            let wd = w * (1 - z * z).squareRoot()
            x = exp(-z * w * t) * (x0 * cos(wd * t) + (v0 + z * w * x0) / wd * sin(wd * t))
        } else {
            x = (x0 + (v0 + w * x0) * t) * exp(-w * t)
        }
        return to + x
    }

    /// **The ring on landing**, only hinted: `r` seconds after landing (0 ... 0.8)
    /// its scale (spring 0.35/0.75 from 0.6) and opacity (0.05 s in, full at 0.45,
    /// then 0.35 s out, at most 55%).
    public static func ring(_ r: Double) -> (mass: Double, coverage: Double) {
        let d = r < 0.45 ? min(1, r / 0.05) : 1 - min(1, (r - 0.45) / 0.35)
        return (spring(0.6, 1, 0, 0.35, 0.75, r), max(0, d) * 0.55)
    }

    // MARK: Rows after the switch

    /// **Home rows pop in staggered**: 80 ms per row, opacity linear over 0.22 s,
    /// from 14 pt lower and 96% size (`Reihenauftritt`).
    public static let railsSeason = 0.08
    public static let railsFade = 0.22
    public static let railsOffset = 14.0
    public static let railsMass = 0.96
    /// How long after the swap the rows may appear.
    public static let railsPostSwap = 0.03
}
