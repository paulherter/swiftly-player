import Foundation

/// **The next episode as a card at the bottom right, and how it zooms into the picture.**
///
/// The running picture stays large. From the credits (otherwise in the last
/// ``restfenster`` seconds) the next episode slides in at the bottom right as a card:
/// thumbnail, “S6 · F11”, title, a ring as countdown. On tap or timeout the card zooms
/// to the full picture and takes it over; its thumbnail becomes the first frame of the
/// new episode, with no black in between. Tapping the picture (iPhone) or Menu (TV)
/// slides the card out again and the credits keep running.
///
/// Replaces the “next episode” countdown pill (`OfferingLayer.Anzeige.card`)
/// and the title transition. The button in the open controls stays.
///
/// **All motion is springs from the current state**, critically damped, with the
/// natural frequencies of the design: `1 − e^(−ωt)·(1 + ωt)`. On Apple this is
/// `interpolatingSpring(stiffness: ω², damping: 2ω)`, interruptible by itself.
/// Sizes in points, per platform.
public enum EpisodeCard {

    /// Without a credits section: this many seconds before the end.
    public static let remainingWindow: Double = 30

    // MARK: Springs (natural frequency ω, critically damped)

    /// Slide in, 0.12 s after the credits start.
    public static let appearOmega: Double = 9
    public static let appearLag: Double = 0.12
    /// Slide out (dismissed).
    public static let distanceOmega: Double = 12
    /// Zoom to the full picture.
    public static let zoomOmega: Double = 10

    /// Stiffness and damping of a critically damped spring with mass 1.
    public static func spring(_ omega: Double) -> (stiffness: Double, damping: Double) {
        (omega * omega, 2 * omega)
    }

    /// How far such a spring is after `t` seconds, 0 to 1.
    public static func springTravel(_ t: Double, omega: Double) -> Double {
        t <= 0 ? 0 : 1 - exp(-omega * t) * (1 + omega * t)
    }

    // MARK: Sequence after the start

    /// Ring and details below the card fade out over this many seconds.
    public static let detailsOut: Double = 0.15
    /// **Only here is the new episode started**: the card now covers
    /// the picture (zoom to 98 %). Earlier, black would show around it.
    public static let swap: Double = 0.6
    /// From the first frame of the new episode (at the earliest ``swap``) the
    /// thumbnail fades out over this many seconds, the video sits underneath.
    public static let imageFade: Double = 0.4

    /// When the thumbnail starts fading out, measured from the start.
    public static func fadeOff(imageSince: Double) -> Double { max(imageSince, swap) }

    /// **The longest the card covers without a picture arriving.**
    ///
    /// The zoomed card sits above everything, and while it does there is neither control
    /// nor loading screen, so no close button. If the first frame of the new episode never
    /// comes (plan hangs, stream does not start), the user would be stuck. After this time
    /// it yields to the ordinary loading screen and the switch continues underneath.
    public static let atMostCovers: Double = 5

    /// Should the card go now? `imageSince` is `nil` while the first frame of the new
    /// episode is missing.
    public static func yields(since: Double, imageSince: Double?) -> Bool {
        imageSince == nil && since >= atMostCovers
    }

    // MARK: Appearance (from the design)

    /// On slide-in: from the right by this many points, and from 94 % size.
    public static let offset: Double = 40
    public static let startMetric: Double = 0.94
    /// TV: the focused card lifts by 6 %, a click presses it in by 3.5 % for 0.3 s.
    public static let focusMetric: Double = 1.06
    public static let clickPress: Double = 0.035
    public static let clickDuration: Double = 0.3

    /// Sizes per platform: card width, corner, ring, gap to the line below,
    /// font sizes of the two lines.
    public struct Metrics: Sendable, Equatable {
        public let width: Double
        public let corner: Double
        public let ring: Double
        public let spacing: Double
        public let small: Double
        public let title: Double
    }
    public static let iPhone = Metrics(width: 240, corner: 12, ring: 52, spacing: 12, small: 12, title: 17)
    public static let tv = Metrics(width: 600, corner: 24, ring: 130, spacing: 32, small: 30, title: 42)

    // MARK: Position and dismissal (iPhone)

    /// At most this share of the safe width; on an iPhone SE in landscape
    /// (667 pt) the card gets narrower instead of reaching into the middle.
    public static let atMostShare: Double = 0.3
    /// Gap between the lines under the card and the bottom safe edge.
    public static let bottomSpacing: Double = 12
    /// Swiped this far (points) right or down, the card is gone, or if the momentum
    /// would carry it twice as far.
    public static let swipeAway: Double = 70
    /// Left and up it follows the finger only by a fifth.
    public static let resistance: Double = 0.2

    /// The card width for a given safe width.
    public static func width(_ m: Metrics, safeWidth: Double, large: Bool) -> Double {
        min(m.width * (large ? 1.25 : 1), safeWidth * atMostShare)
    }

    /// The offset while dragging: free to the right and down, stiff left and up.
    public static func dragged(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        (x > 0 ? x : x * resistance, y > 0 ? y : y * resistance)
    }

    /// Whether a swipe pushes the card away.
    public static func swipedAway(x: Double, y: Double, momentumX: Double, momentumY: Double) -> Bool {
        x > swipeAway || y > swipeAway || momentumX > 2 * swipeAway || momentumY > 2 * swipeAway
    }

    /// The frame between card (`zoom` 0) and full picture (1).
    public static func frameRect(card: (x: Double, y: Double, b: Double, h: Double),
                              whole: (b: Double, h: Double), zoom: Double)
        -> (x: Double, y: Double, b: Double, h: Double) {
        func l(_ a: Double, _ b: Double) -> Double { a + (b - a) * zoom }
        return (l(card.x, 0), l(card.y, 0), l(card.b, whole.b), l(card.h, whole.h))
    }
}
