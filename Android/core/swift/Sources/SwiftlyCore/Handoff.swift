import Foundation
import JellyfinKit

// MARK: - "Continue here" as a card, the bridge for Kotlin
//
// **All timings, springs and dimensions live in the package** (`HandoffCard`). Here they are only
// emitted as sample points, the way `HandoffStage` on Apple hands them to Core Animation: 120 per
// second, linear in between. Kotlin (`Handoff.kt`) puts them into `graphicsLayer`: position, size,
// opacity only.
//
// Units: in and out in dp. On TV the package computes in tvOS points (1920 wide), Android TV at half
// of that, so values are doubled, computed and halved again, so the float height and the way out
// are right too.

struct HandoffResponse: Encodable { let reason: String; let since: Double }

extension Kern {
    /// **The card's image** (`TakeoverModel.cardImageURL`): for episodes the episode's image (it shows
    /// *where* you are), otherwise the title's landscape image.
    static func cardImage(_ title: Item, addresses a: ImageAddress) -> String? {
        if title.seriesId != nil, let mark = title.imageTags?["Primary"] {
            return a.construct(itemID: title.id, mark: mark, mass: .atMostWide(1280))?.absoluteString
        }
        return ImageSelection.landscape(title, addresses: a, width: 1280)?.url.absoluteString
    }
}

enum HandoffPath {
    typealias K = HandoffCard

    struct MetricResponse: Encodable { let width, corner, title, small, spacing: Double }

    /// Timings from the package, so Kotlin keeps none of its own.
    struct Times: Encodable {
        let pageUntil = K.pageUntil
        let cardsStart = K.cardsStart
        let float = K.float
        let loadingBarOut = K.loadingBarOut
        let loadingBarShow = K.loadingBarShow
        let loadingBarTick = K.loadingBarTick
        let rowsOut = K.rowsOut
        let blackDuration = K.blackDuration
        let cardsOutFrom = K.cardsOutFrom
        let end = K.end
        let atMostWait = K.atMostWait
        let fade = K.fade
        let fadeOut = K.fadeOut
        let exitStart = K.exitStart
        let exitReducedEnd = K.exitReducedEnd
        /// The wait path is computed up to here, far beyond the longest wait (`HandoffStage.pathPut`).
        let waitUntil = K.float + K.atMostWait + 8
    }

    struct StatusResponse: Encodable {
        enum CodingKeys: String, CodingKey {
            case full = "voll"
            case idle = "ruhe"
            case metrics = "masse"
        }
        let full: [Double]
        let idle: [Double]
        let metrics: MetricResponse
        let times = Times()
    }

    static func scale(_ tv: Bool) -> Double { tv ? 0.5 : 1 }
    static func metrics(_ tv: Bool) -> K.Metrics { tv ? K.tv : K.iPhone }

    static func situations(width: Double, height: Double, tv: Bool) -> StatusResponse {
        let s = scale(tv), m = metrics(tv)
        let b = width / s, h = height / s
        let v = K.fullscreen(width: b, height: h), r = K.idleStatus(width: b, height: h, metrics: m)
        return StatusResponse(full: [v.x * s, v.y * s, v.width * s], idle: [r.x * s, r.y * s, r.width * s],
                            metrics: MetricResponse(width: m.width * s, corner: m.corner * s, title: m.title * s,
                                               small: m.small * s, spacing: m.spacing * s))
    }

    struct Input: Decodable {
        enum CodingKeys: String, CodingKey {
            case art
            case tv = "fernseher"
            case from = "von"
            case idle = "ruhe"
            case full = "voll"
            case transitionOut = "flugAb"
            case since = "ab"
            case until = "bis"
            case screen = "schirm"
            case toTop = "nachOben"
            case gravity = "schwerkraft"
            case surface = "oberflaeche"
        }
        /// `wait`, `coverage`, `zoom`, `exit` or `new` (flight after a rotation: the position at `since`).
        let art: String
        let tv: Bool
        var from: [Double]?
        var idle: [Double]?
        var full: [Double]?
        /// When the (last) flight began (`HandoffStage.transitionOut`).
        var transitionOut: Double?
        var since: Double?
        var until: Double?
        /// Exit: screen size and direction.
        var screen: [Double]?
        var toTop: Bool?
        /// Exit on the phone: gravity like `CMDeviceMotion.gravity` and the orientation of the UI
        /// (`up`, `upsideDown`, `landscapeHomeRight`, `landscapeHomeLeft`); `HandoffCard.departureDirection`.
        var gravity: [Double]?
        var surface: String?
    }

    struct Reply: Encodable {
        enum CodingKeys: String, CodingKey {
            case t0
            case dt
            case l
            case d
            case dn
            case out = "raus"
            case status = "lage"
        }
        /// From when (seconds) and at what spacing the points stand.
        var t0: Double = 0
        var dt: Double = 0
        /// Per point x, y, width, corner and top edge of the rows below (dp).
        var l: [Double] = []
        /// Per point one or more coverages, `dn` per point.
        var d: [Double] = []
        var dn = 0
        /// Exit: when the card is out. `new`: position at `since`.
        var out: Double?
        var status: [Double]?
    }

    static func compute(_ e: Input) -> Reply {
        let s = scale(e.tv), m = metrics(e.tv)
        func status(_ a: [Double]?) -> K.Status {
            guard let a, a.count >= 3 else { return K.Status(x: 0, y: 0, width: 1) }
            return K.Status(x: a[0] / s, y: a[1] / s, width: a[2] / s)
        }
        let from = status(e.from), idle = status(e.idle), full = status(e.full)
        let transitionOut = e.transitionOut ?? K.cardsStart
        var answer = Reply()
        func points(from t0: Double, until t1: Double, status f: ((Double) -> K.Status)?, coverage g: ((Double) -> [Double])?) {
            let steps = max(2, Int(((t1 - t0) * 120).rounded(.up)))
            answer.t0 = t0
            answer.dt = (t1 - t0) / Double(steps)
            for i in 0 ... steps {
                let t = t0 + (t1 - t0) * Double(i) / Double(steps)
                if let f {
                    let l = f(t)
                    answer.l += [l.x * s, l.y * s, l.width * s, K.corner(l, metrics: m, full: full) * s,
                                  K.rowsTop(l, metrics: m) * s]
                }
                if let g { let d = g(t); answer.dn = d.count; answer.d += d }
            }
        }
        switch e.art {
        case "warten":
            points(from: e.since ?? 0, until: e.until ?? (K.float + K.atMostWait + 8),
                   status: { K.wait($0, from: from, to: idle, since: transitionOut) }, coverage: nil)
        case "deckung":
            // Card, backdrop above the page, rows: the first second (`HandoffStage.transitionPut`).
            points(from: 0, until: 1, status: nil) {
                [K.cardsCoverage($0), K.pagesCoverage($0), K.rowsCoverage($0, zoomOff: nil)]
            }
        case "neu":
            let l = K.transition(e.since ?? 0, from: from, to: idle, since: transitionOut)
            answer.status = [l.x * s, l.y * s, l.width * s]
        case "zoom":
            // From the position **and momentum** of the waiting card (`HandoffStage.zoomIn`).
            let z = e.since ?? K.float
            let start = K.wait(z, from: from, to: idle, since: transitionOut)
            let momentum = K.momentum(z, from: from, to: idle, since: transitionOut)
            points(from: 0, until: K.end, status: { K.zoom($0, from: start, momentum: momentum, to: full) }) {
                [K.stageCoverage(toZoom: $0)]
            }
        case "abgang":
            let screen = e.screen ?? [full.x * 2 * s, full.y * 2 * s]
            let card = K.idleStatus(width: screen[0] / s, height: screen[1] / s, metrics: m)
            let top = e.toTop ?? true
            var bearing: K.Direction = top ? .top : .bottom
            if let g = e.gravity, g.count >= 2 {
                let o: K.UserInterface = switch e.surface {
                case "kopfueber": .upsideDown
                case "querHomeRechts": .landscapeHomeRight
                case "querHomeLinks": .landscapeHomeLeft
                default: .up
                }
                bearing = K.departureDirection(gravityX: g[0], gravityY: g[1], surface: o, toTop: top)
            }
            // The screen for `departureTarget` follows from the centered `full`, as on Apple.
            let out = K.exitOut(full: full, card: card, bearing: bearing)
            points(from: 0, until: out + 0.1, status: { K.exit($0, full: full, card: card, bearing: bearing) }) {
                [K.exitRowsCoverage($0)]
            }
            answer.out = out
            answer.status = [card.x * s, card.y * s, card.width * s]
        default:
            break
        }
        return answer
    }
}
