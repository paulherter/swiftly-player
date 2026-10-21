import JellyfinKit
import SwiftUI

// **The small seasonal extras: a web in a card's corner, a bat now and then.**
//
// The web hangs on its card. Whether either shows is decided in the package
// (`LookEffects`): only in the look's window, only with "Bats and details" on, never during
// playback, the bat never with "Reduce Motion" or in Low Power Mode. All of it is drawn as
// plain paths: no images, no blur, nothing that redraws while it stands still.
//
// Included in the iPhone/iPad and Mac targets.

extension LookEffects.Context {
    /// The context of this moment, from the app's state.
    @MainActor
    static func current(playing: Bool, foreground: Bool = true) -> LookEffects.Context {
        let store = LookStore.shared
        return LookEffects.Context(look: store.palette.look, now: LookClock.now, switchOn: store.effectsOn,
                                   playing: playing, reduceMotion: Theme.motionReduced,
                                   lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                   foreground: foreground)
    }
}

// MARK: - Web

/// **A web in the top trailing corner of a card that follows the card's rounding.**
///
/// The frame thread runs along the corner's arc, 3 pt inside it, and goes on along the two
/// straight edges; the hub sits on that arc where it is closest to the corner. Spokes fan
/// out from the hub into the card, the rings between them sag toward the hub like real
/// threads. Nothing leaves the card's shape.
struct CornerWeb: Shape {
    /// The card's corner radius.
    var cornerRadius: CGFloat
    /// How far the web reaches along each edge; at least 44 pt, so it reads as a web.
    var reach: CGFloat = 52
    var inset: CGFloat = 3

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = max(cornerRadius - inset, 0)
        // The center of the corner's arc, and the arc 3 pt inside the card's edge.
        let center = CGPoint(x: rect.maxX - cornerRadius, y: rect.minY + cornerRadius)
        let top = CGPoint(x: rect.maxX - reach, y: rect.minY + inset)
        let side = CGPoint(x: rect.maxX - inset, y: rect.minY + reach)

        // Frame: along the top edge, around the arc, down the side.
        path.move(to: top)
        path.addLine(to: CGPoint(x: center.x, y: rect.minY + inset))
        path.addArc(center: center, radius: radius, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: side)

        // The hub: on the arc, at 45 degrees.
        let hub = CGPoint(x: center.x + radius * cos(.pi / 4), y: center.y - radius * sin(.pi / 4))
        // Spokes from the hub to the frame's ends and three points in between, inside the card.
        let ends: [CGPoint] = [
            top,
            CGPoint(x: rect.maxX - reach * 0.92, y: rect.minY + reach * 0.42),
            CGPoint(x: rect.maxX - reach * 0.72, y: rect.minY + reach * 0.72),
            CGPoint(x: rect.maxX - reach * 0.42, y: rect.minY + reach * 0.92),
            side,
        ]
        for end in ends {
            path.move(to: hub)
            path.addLine(to: end)
        }
        // Three rings, each a chain of sagging threads between neighboring spokes.
        for share in [0.36, 0.62, 0.88] as [CGFloat] {
            let points = ends.map { CGPoint(x: hub.x + ($0.x - hub.x) * share, y: hub.y + ($0.y - hub.y) * share) }
            path.move(to: points[0])
            for index in 1..<points.count {
                let a = points[index - 1], b = points[index]
                let middle = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                // Sag a fifth of the way toward the hub.
                let control = CGPoint(x: middle.x + (hub.x - middle.x) * 0.2, y: middle.y + (hub.y - middle.y) * 0.2)
                path.addQuadCurve(to: b, control: control)
            }
        }
        return path
    }
}

extension View {
    /// **The web in the top trailing corner**, only when the look's details are on.
    func seasonWeb(cornerRadius: CGFloat, shown: Bool) -> some View {
        overlay {
            if shown {
                CornerWeb(cornerRadius: cornerRadius)
                    .stroke(Color.white.opacity(0.42), style: StrokeStyle(lineWidth: 0.75, lineCap: .round, lineJoin: .round))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
        }
    }
}

// MARK: - Bat

extension Notification.Name {
    /// Debug: "Halloween season now" was switched; a bat flies at once.
    static let lookBatNow = Notification.Name("de.paulherter.swiftly.lookBatNow")
}

/// **Now and then one bat across the home page.**
///
/// The first one about 6 s after the page stands, then one every 45 to 90 s (`LookEffects`).
/// One flight is 2.5 to 3.5 s. While nothing flies the timeline is paused and nothing is
/// drawn; it only runs during a flight, at 30 frames a second. It never reacts to touches.
/// It also flies over the home page under the looks panel, so the look can be judged there.
///
/// The decision whether one may fly is the package's (`LookEffects.batBlock`); the layer logs
/// each start and each reason it holds back, so a bat that never shows can be traced.
struct BatLayer: View {
    let playing: Bool
    let foreground: Bool
    /// Read by the owner from the environment so that a change re-evaluates the layer.
    let reduceMotion: Bool
    let lowPower: Bool

    @State private var flight: Flight?
    /// Counts "fly now" requests (debug); each one restarts the wait with a short one.
    @State private var nudge = 0
    @State private var handledNudge = 0
    @State private var lastBlock: LookEffects.BatBlock?

    private struct Flight: Equatable {
        let start: Date
        let duration: Double
        let leftToRight: Bool
        let height: CGFloat
    }

    private struct Trigger: Hashable {
        let allowed: Bool
        let nudge: Int
    }

    private var block: LookEffects.BatBlock? {
        let store = LookStore.shared
        let context = LookEffects.Context(look: store.palette.look, now: LookClock.now, switchOn: store.effectsOn,
                                          playing: playing, reduceMotion: reduceMotion, lowPower: lowPower,
                                          foreground: foreground)
        return LookEffects.batBlock(on: .home, context)
    }

    var body: some View {
        let block = block
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: flight == nil)) { timeline in
            Canvas { context, size in
                guard let flight else { return }
                let progress = timeline.date.timeIntervalSince(flight.start) / flight.duration
                guard progress >= 0, progress <= 1 else { return }
                Self.draw(in: &context, size: size, flight: flight, progress: progress,
                          time: timeline.date.timeIntervalSince(flight.start))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: .lookBatNow)) { _ in nudge += 1 }
        .task(id: Trigger(allowed: block == nil, nudge: nudge)) {
            let immediately = nudge != handledNudge
            handledNudge = nudge
            await fly(block: block, immediately: immediately)
        }
    }

    private func fly(block: LookEffects.BatBlock?, immediately: Bool) async {
        guard block == nil else {
            flight = nil
            // The look's own window is no news; anything else is the reason a bat is missing.
            if block != lastBlock, block != .outsideWindow, block != .switchOff {
                AppLog.writeOut("[Looks] Fledermaus gesperrt: \(block?.rawValue ?? "")")
            }
            lastBlock = block
            return
        }
        lastBlock = nil
        var first = true
        while !Task.isCancelled {
            let wait = immediately && first ? 0.5 : LookEffects.wait(first: first)
            first = false
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            let duration = Double.random(in: LookEffects.flight)
            let leftToRight = Bool.random()
            flight = Flight(start: .now, duration: duration, leftToRight: leftToRight,
                            height: CGFloat.random(in: 0.14...0.32))
            AppLog.writeOut(String(format: "[Looks] Fledermaus startet (%.1f s, %@)", duration,
                                   leftToRight ? "links nach rechts" : "rechts nach links"))
            try? await Task.sleep(for: .seconds(duration))
            flight = nil
        }
    }

    private static func draw(in context: inout GraphicsContext, size: CGSize, flight: Flight,
                             progress: Double, time: Double) {
        let travel = size.width + 80
        let x = flight.leftToRight ? -40 + travel * progress : size.width + 40 - travel * progress
        // A gentle dip and rise on the way across.
        let y = size.height * flight.height + sin(progress * .pi * 2) * 12
        // Wings: one beat every 0.32 s.
        let beat = cos(time / 0.32 * .pi * 2)
        BatShape.draw(in: &context, at: CGPoint(x: x, y: y), span: 30, beat: beat,
                      facingRight: flight.leftToRight)
    }
}

/// The bat itself: a body and two wings whose tips move with `beat` (-1 ... 1).
enum BatShape {
    static func draw(in context: inout GraphicsContext, at point: CGPoint, span: CGFloat, beat: Double,
                     facingRight: Bool) {
        let half = span / 2
        let lift = CGFloat(beat) * span * 0.28
        var path = Path()
        // Left wing, then right wing, as one outline with a scalloped trailing edge.
        path.move(to: CGPoint(x: -1.5, y: 0))
        path.addQuadCurve(to: CGPoint(x: -half, y: -lift), control: CGPoint(x: -half * 0.5, y: -lift - span * 0.12))
        path.addQuadCurve(to: CGPoint(x: -half * 0.55, y: span * 0.08 - lift * 0.4), control: CGPoint(x: -half * 0.8, y: span * 0.05 - lift * 0.6))
        path.addQuadCurve(to: CGPoint(x: -1.5, y: span * 0.12), control: CGPoint(x: -half * 0.25, y: span * 0.02))
        path.closeSubpath()
        path.move(to: CGPoint(x: 1.5, y: 0))
        path.addQuadCurve(to: CGPoint(x: half, y: -lift), control: CGPoint(x: half * 0.5, y: -lift - span * 0.12))
        path.addQuadCurve(to: CGPoint(x: half * 0.55, y: span * 0.08 - lift * 0.4), control: CGPoint(x: half * 0.8, y: span * 0.05 - lift * 0.6))
        path.addQuadCurve(to: CGPoint(x: 1.5, y: span * 0.12), control: CGPoint(x: half * 0.25, y: span * 0.02))
        path.closeSubpath()
        path.addEllipse(in: CGRect(x: -2.2, y: -2.5, width: 4.4, height: span * 0.32))
        var transform = CGAffineTransform(translationX: point.x, y: point.y)
        if !facingRight { transform = transform.scaledBy(x: -1, y: 1) }
        // Light, not black: the page is nearly black, and a dark bat vanished on it.
        context.fill(path.applying(transform), with: .color(Color(white: 0.84).opacity(0.92)))
    }
}
