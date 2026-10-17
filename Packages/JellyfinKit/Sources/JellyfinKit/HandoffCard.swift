import Foundation

/// **"Continue watching here" as a card that grows out of the badge.**
///
/// **Receiver:** tap on the badge; the page steps back, a card with the episode
/// image grows on a straight path from the badge to the middle, title and
/// episode below it. While the stream is not ready it hovers slightly, with a
/// loading line if the wait is longer. Once the first picture is there it zooms
/// to the full picture; the video fades in underneath.
///
/// **Sender:** the mirror image: the running picture stands still, shrinks to
/// the card, hovers briefly and flies out at the top; then the player closes.
///
/// Three rejected attempts before (light point, wave, Metal) showed:
/// **position, size and opacity only**, no effects on top, and the motion
/// computed in advance; the platform hands it to the render server as
/// keyframes so that player setup and network work on the main thread do not
/// disturb it. With reduced motion it only cross-fades.
///
/// Springs as with the account switch (``Kontowechselkurve/feder(_:_:_:_:_:_:)``)
/// with momentum carried from phase to phase. Sizes in points, times in
/// seconds from the tap (receiver) or from the stop (sender).
public enum HandoffCard {

    // MARK: Dimensions

    /// Card width at rest, corner, font sizes and distance to the line below.
    public struct Metrics: Sendable, Equatable {
        public let width: Double
        public let corner: Double
        public let title: Double
        public let small: Double
        public let spacing: Double
        public init(width: Double, corner: Double, title: Double, small: Double, spacing: Double) {
            self.width = width; self.corner = corner; self.title = title
            self.small = small; self.spacing = spacing
        }
    }
    public static let iPhone = Metrics(width: 240, corner: 12, title: 17, small: 13, spacing: 12)
    public static let iPad = Metrics(width: 320, corner: 14, title: 20, small: 15, spacing: 14)
    public static let tv = Metrics(width: 600, corner: 24, title: 42, small: 30, spacing: 26)
    public static let mac = Metrics(width: 320, corner: 12, title: 17, small: 13, spacing: 12)

    /// Center and width of the card; the height is always 16:9.
    public struct Status: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public init(x: Double, y: Double, width: Double) {
            self.x = x; self.y = y; self.width = width
        }
        public var height: Double { width * 9 / 16 }
    }

    /// **The full picture**: 16:9 fitted into the screen, centered. In portrait
    /// that is screen width, which is exactly where the video sits in the player.
    public static func fullscreen(width: Double, height: Double) -> Status {
        Status(x: width / 2, y: height / 2, width: min(width, height * 16 / 9))
    }

    /// **Where the card rests**: horizontally centered, so far above the middle
    /// that the card and the two lines below it together are centered.
    public static func idleStatus(width: Double, height: Double, metrics: Metrics) -> Status {
        let b = min(metrics.width, width * 0.7)
        let rows = metrics.spacing + metrics.title * 1.2 + metrics.small * 1.2 + 6
        return Status(x: width / 2, y: height / 2 - rows / 2, width: b)
    }

    /// Top edge of the lines under a card in this position.
    public static func rowsTop(_ l: Status, metrics: Metrics) -> Double {
        l.y + l.height / 2 + metrics.spacing * 0.6
    }

    /// **The visible corner**: at rest ``Masse/ecke``, towards the full picture
    /// down to zero, and never more than 5.5 % of the width, so the small card at
    /// the badge does not become a pill.
    public static func corner(_ l: Status, metrics: Metrics, full: Status) -> Double {
        let extentSpan = max(full.width - metrics.width, 1)
        let share = min(max((full.width - l.width) / extentSpan, 0), 1)
        return min(metrics.corner * share, l.width * 0.055)
    }

    // MARK: Springs

    static func linear(_ t: Double, _ a: Double, _ b: Double) -> Double {
        min(max((t - a) / (b - a), 0), 1)
    }

    static func smooth(_ u: Double) -> Double { u * u * (3 - 2 * u) }

    // MARK: Receiver

    /// The page steps back (opacity of the backdrop above it, linear).
    public static let pageFrom = 0.08
    public static let pageUntil = 0.28
    /// From here the card is there; it fades in over ``cardsShow``.
    public static let cardsStart = 0.1
    public static let cardsShow = 0.05
    /// The straight path out of the badge: response 0.55 s, damping 0.8 for
    /// position and size, a small overshoot as with the account switch. Softer
    /// values (0.86/0.9) felt as if the easing was missing.
    public static let transitionResponse = 0.55
    public static let transitionDamping = 0.8
    public static let sizesDamping = 0.8
    /// Title and episode under the card.
    public static let rowsFrom = 0.45
    public static let rowsUntil = 0.7
    /// **Earliest zoom.** If the picture is there earlier, the card waits until
    /// here; if it is later, the card hovers.
    public static let float = 0.7
    /// Hovering: this many points up and down, one oscillation in this many
    /// seconds, faded in over 0.4 s from 0.15 s before ``float``.
    public static let hoverTravel = 1.8
    public static let hoverPeriod = 1.8
    /// The loading line only appears if the picture is still missing at this time.
    public static let loadingBarOut = float + 0.05
    public static let loadingBarShow = 0.2
    /// One sweep of the loading line across the card width.
    public static let loadingBarTick = 1.0 / 0.9
    /// **Zoom to the full picture**: spring response 0.5 s, damping 0.85, and
    /// **with the momentum the card currently has**, from flight or from hovering
    /// without a stop. A critically damped zoom from rest (ω 10) stopped the card
    /// mid-flight when the picture came early and started again, which looked
    /// mechanical.
    public static let zoomResponse = 0.5
    public static let zoomDamping = 0.85
    /// After the zoom starts: lines away, black behind, card off; the fade begins
    /// when the spring is almost at its target.
    public static let rowsOut = 0.15
    public static let blackDuration = 0.3
    public static let cardsOutFrom = 0.42
    public static let cardsOutUntil = 0.72
    /// After that the stage is cleared.
    public static let end = cardsOutUntil + 0.05
    /// **The longest the card waits for the first picture**, from the moment the
    /// player is up. After that it zooms anyway, and the player shows its own
    /// loader.
    public static let atMostWait = 6.0
    /// With reduced motion: each fade this long.
    public static let fade = 0.2
    public static let fadeOut = 0.3

    /// When the zoom happens if the first picture came at `ready` (from the tap).
    public static func zoomStart(ready: Double) -> Double { max(float, ready) }

    /// **The card in flight**: center and width after `t` seconds, without
    /// hovering. Before ``cardsStart`` it sits at the badge.
    ///
    /// `since`: when the flight starts, otherwise at ``cardsStart``. If the screen
    /// rotates to landscape on the way, the card flies anew from where it is to
    /// the landscape resting position.
    public static func transition(_ t: Double, from: Status, to: Status, since: Double = cardsStart) -> Status {
        let u = t - since
        guard u > 0 else { return from }
        let f = AccountSwitchCurve.spring
        return Status(x: f(from.x, to.x, 0, transitionResponse, transitionDamping, u),
                    y: f(from.y, to.y, 0, transitionResponse, transitionDamping, u),
                    width: f(from.width, to.width, 0, transitionResponse, sizesDamping, u))
    }

    /// Vertical offset while hovering.
    public static func hoverOffset(_ t: Double) -> Double {
        let since = float - 0.15
        guard t > since else { return 0 }
        // Faded in softly: the breathing starts without a kink.
        return sin((t - since) * 2 * .pi / hoverPeriod) * hoverTravel * smooth(linear(t, since, float + 0.4))
    }

    /// Flight plus hovering: how the card stands while the picture is missing.
    public static func wait(_ t: Double, from: Status, to: Status, since: Double = cardsStart) -> Status {
        var l = transition(t, from: from, to: to, since: since)
        l.y += hoverOffset(t)
        return l
    }

    /// **How fast the card currently moves while waiting** (per second, per axis):
    /// the momentum the zoom takes over.
    public static func momentum(_ t: Double, from: Status, to: Status, since: Double = cardsStart) -> Status {
        let h = 1.0 / 240
        let a = wait(max(0, t - h), from: from, to: to, since: since)
        let b = wait(t + h, from: from, to: to, since: since)
        let d = t + h - max(0, t - h)
        return Status(x: (b.x - a.x) / d, y: (b.y - a.y) / d, width: (b.width - a.width) / d)
    }

    /// **The zoom** `z` seconds after its start, from the position and momentum
    /// the card had at that moment.
    public static func zoom(_ z: Double, from: Status, momentum v: Status, to full: Status) -> Status {
        let f = AccountSwitchCurve.spring
        return Status(x: f(from.x, full.x, v.x, zoomResponse, zoomDamping, z),
                    y: f(from.y, full.y, v.y, zoomResponse, zoomDamping, z),
                    width: f(from.width, full.width, v.width, zoomResponse, zoomDamping, z))
    }

    /// Opacity of the card until the zoom.
    public static func cardsCoverage(_ t: Double) -> Double {
        linear(t, cardsStart, cardsStart + cardsShow)
    }

    /// Opacity of the backdrop above the page.
    public static func pagesCoverage(_ t: Double) -> Double { smooth(linear(t, pageFrom, pageUntil)) }

    /// Opacity of the lines; `zoomOff` is the zoom start, if already known.
    public static func rowsCoverage(_ t: Double, zoomOff: Double?) -> Double {
        let an = linear(t, rowsFrom, rowsUntil)
        guard let zoomOff else { return an }
        return an * (1 - linear(t, zoomOff, zoomOff + rowsOut))
    }

    /// Opacity of the whole stage after the zoom start `z`: fully visible first,
    /// then softly out, the video stands underneath.
    public static func stageCoverage(toZoom z: Double) -> Double {
        1 - smooth(linear(z, cardsOutFrom, cardsOutUntil))
    }

    /// Whether the loading line appears: only if the picture is missing at ``loadingBarOut``.
    public static func loadLine(ready: Double?) -> Bool {
        guard let ready else { return true }
        return ready > loadingBarOut
    }

    // MARK: Sender

    // **The mirror image of the receiver**: the same springs, the path reversed.
    // The full picture shrinks with the zoom spring to the card, hovers briefly and
    // flies out over the top edge with the growth spring; then the player closes
    // and you are back on the page. Faster shrinking, sideways gliding and a "now
    // playing on ..." text were tried and felt too fast and unlike the arrival.

    /// The picture stands still, then starts to shrink.
    public static let exitStart = 0.12
    /// Title and episode appear when the card is almost small, mirroring the zoom,
    /// where they leave.
    public static let exitRowsFrom = exitStart + 0.35
    public static let exitRowsUntil = exitStart + 0.6
    /// Short hovering from here (faded in softly as with the receiver).
    public static let exitFloatOff = exitStart + 0.55
    /// **Departure**, with position and momentum from the hovering.
    public static let departure = exitStart + 1.1
    /// On departure the card shrinks further to this fraction, back to the small
    /// size it had on arrival.
    public static let departureMass = 0.6
    /// With reduced motion: picture off, then closed.
    public static let exitReducedEnd = fadeOut + 0.1

    /// **Where the card flies: to where the other device usually is.**
    /// Ordered by size (Apple TV/Android TV > Mac > iPad > iPhone/Android; Linux
    /// and Windows count as desk like the Mac): if the target is larger, up (the
    /// phone lies below the TV), if it is smaller, down. Equal or unknown: up.
    /// - Parameters: `from`, `to`: device names as in the handoff notice.
    public static func departurePostTop(from: String, to: String) -> Bool {
        guard let a = sizesRank(from), let b = sizesRank(to) else { return true }
        return b >= a
    }

    static func sizesRank(_ name: String) -> Int? {
        switch name {
        // The Android version reports as "Android TV" or "Android" (phone).
        case "Apple TV", "Android TV": 3
        case "Mac", "Linux", "Windows": 2
        case "iPad": 1
        case "iPhone", "Android": 0
        default: nil
        }
    }

    /// A direction on the screen, unit vector, y pointing down.
    public struct Direction: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
        public static let top = Direction(x: 0, y: -1)
        public static let bottom = Direction(x: 0, y: 1)
    }

    /// How the interface is oriented (`UIInterfaceOrientation`): portrait, upside
    /// down, landscape with the home button on the right or left.
    public enum UserInterface: Sendable {
        case up, upsideDown, landscapeHomeRight, landscapeHomeLeft
    }

    /// **Where "physically up" lies on the screen**, from gravity
    /// (`CMDeviceMotion.gravity`, device coordinates: x right, y to the top edge,
    /// z out of the glass) and the interface orientation. If the iPhone is already
    /// held upright again while the player is still in landscape, up is the left or
    /// right side of the screen; held at an angle, also at an angle. If it lies
    /// flat (gravity almost only on z), the interface's own up applies.
    /// `toTop` false: the opposite direction (towards the smaller device).
    public static func departureDirection(gravityX gx: Double, gravityY gy: Double,
                                      surface: UserInterface, toTop: Bool) -> Direction {
        let length = (gx * gx + gy * gy).squareRoot()
        guard length >= flatLimit else { return toTop ? .top : .bottom }
        // "Up" is against gravity; on a portrait screen y points down.
        let px = -gx / length, py = gy / length
        var r: Direction
        switch surface {
        case .up:           r = Direction(x: px, y: py)
        case .upsideDown:      r = Direction(x: -px, y: -py)
        case .landscapeHomeRight: r = Direction(x: py, y: -px)
        case .landscapeHomeLeft:  r = Direction(x: -py, y: px)
        }
        if !toTop { r = Direction(x: -r.x, y: -r.y) }
        return r
    }

    /// Below this (share of gravity in the glass plane) the device lies flat.
    public static let flatLimit = 0.35

    /// **Where the card flies**: along `bearing` until it is fully off the screen,
    /// plus half a card height. The screen follows from the centered `full`.
    public static func departureTarget(card: Status, full: Status, bearing: Direction = .top) -> Status {
        let b = card.width * departureMass
        let half = (b / 2, b * 9 / 32)
        let screen = (full.x * 2, full.y * 2)
        var distance = Double.infinity
        if abs(bearing.x) > 1e-6 {
            let margin = bearing.x > 0 ? screen.0 - card.x : card.x
            distance = min(distance, (margin + half.0) / abs(bearing.x))
        }
        if abs(bearing.y) > 1e-6 {
            let margin = bearing.y > 0 ? screen.1 - card.y : card.y
            distance = min(distance, (margin + half.1) / abs(bearing.y))
        }
        distance += card.height / 2
        return Status(x: card.x + bearing.x * distance, y: card.y + bearing.y * distance, width: b)
    }

    /// Vertical offset during the departer's short hovering.
    static func exitFloat(_ t: Double) -> Double {
        hoverOffset(t - exitFloatOff + float - 0.15)
    }

    /// Shrinking and hovering, without departure.
    static func exitPreDeparture(_ t: Double, full: Status, card: Status) -> Status {
        let u = t - exitStart
        guard u > 0 else { return full }
        let f = AccountSwitchCurve.spring
        return Status(x: f(full.x, card.x, 0, zoomResponse, zoomDamping, u),
                    y: f(full.y, card.y, 0, zoomResponse, zoomDamping, u) + exitFloat(t),
                    width: f(full.width, card.width, 0, zoomResponse, zoomDamping, u))
    }

    /// **The outgoing picture** after `t` seconds from the stop.
    public static func exit(_ t: Double, full: Status, card: Status, bearing: Direction = .top) -> Status {
        guard t > departure else { return exitPreDeparture(t, full: full, card: card) }
        let start = exitPreDeparture(departure, full: full, card: card)
        let h = 1.0 / 240
        let prior = exitPreDeparture(departure - h, full: full, card: card)
        let v = Status(x: (start.x - prior.x) / h, y: (start.y - prior.y) / h,
                     width: (start.width - prior.width) / h)
        let target = departureTarget(card: card, full: full, bearing: bearing)
        let f = AccountSwitchCurve.spring, u = t - departure
        return Status(x: f(start.x, target.x, v.x, transitionResponse, transitionDamping, u),
                    y: f(start.y, target.y, v.y, transitionResponse, transitionDamping, u),
                    width: f(start.width, target.width, v.width, transitionResponse, sizesDamping, u))
    }

    /// Opacity of the lines under the outgoing card: they appear when it is small,
    /// leave on departure.
    public static func exitRowsCoverage(_ t: Double) -> Double {
        linear(t, exitRowsFrom, exitRowsUntil) * (1 - linear(t, departure, departure + rowsOut))
    }

    /// **When the card is fully out of the picture**; then the player closes.
    public static func exitOut(full: Status, card: Status, bearing: Direction = .top) -> Double {
        var t = departure
        while t < departure + 3 {
            let l = exit(t, full: full, card: card, bearing: bearing)
            let outside = l.y + l.height / 2 < 0 || l.y - l.height / 2 > full.y * 2
                || l.x + l.width / 2 < 0 || l.x - l.width / 2 > full.x * 2
            if outside { return t }
            t += 1.0 / 240
        }
        return t
    }

    // MARK: Keyframes

    /// Keyframes for a keyframe animation: `schritte + 1` evenly spaced values from
    /// `from` to `until`.
    public static func anchorPoints<T>(from: Double, until: Double, jeSecond: Double = 120,
                                       _ value: (Double) -> T) -> [T] {
        let steps = max(2, Int(((until - from) * jeSecond).rounded(.up)))
        return (0 ... steps).map { value(from + (until - from) * Double($0) / Double(steps)) }
    }
}
