import AppKit
import Observation
import QuartzCore
import SwiftUI

/// **Stage of the account switch on the Mac**, counterpart of the iPhone's UIKit
/// stage (`Sources/iOS/Transitions.swift`). Sequence, timings and curve are shared
/// in ``AccountSwitchTransition``; this file only covers how the Mac shows them.
///
/// **Two deviations, both caused by the window:**
/// - **No snapshot.** The iPhone lays an image of the screen over everything and
/// slides it away as a page. On the Mac the profile page itself moves out
/// (`Navigator.clearEverything()`, the same motion as going back) and the sidebar
/// stays put, since that is where the image lands.
/// - **The image flies in a SwiftUI overlay**, not as a layer in the render server.
/// On iPhone it hung off the main run loop and stuttered because the home screen
/// is built during the switch. The switch itself happens 0.3 s before the motion
/// settles (``Kontowechselflug/switchPreIdle``), after which the image moves only
/// by fractions of a point.
@MainActor
enum AccountSwitchStage {
    /// Window width, for ``Kontowechselflug/targetReport(_:)``.
    static var windowWidthValue: CGFloat? { NSApp.keyWindow?.contentView?.bounds.width }

    /// What is on the stage, so an early finish can clear it.
    @MainActor
    final class Parts {
        let number: Int
        init(number: Int) { self.number = number }
        func cancel() { AccountSwitchEntrance.shared.distance(number) }
    }

    /// `nil` without a window, in which case there is no motion. `area` and
    /// `contentOff` are only needed for the iPhone's snapshot.
    static func play(curve: AccountSwitchTransition.Curve?, image: some View, from: CGRect,
                        area: Color, contentOff: CGFloat, calm: Bool,
                        start: CFTimeInterval) -> Parts? {
        guard NSApp.keyWindow ?? NSApp.mainWindow != nil else { return nil }
        guard let curve else { return Parts(number: 0) }
        return Parts(number: AccountSwitchEntrance.shared.showItem(curve: curve, image: AnyView(image),
                                                                 start: start))
    }
}

/// What is currently flying: one per window, shown by ``Kontowechselbild`` over
/// the whole `MainView`.
@MainActor
@Observable
final class AccountSwitchEntrance {
    static let shared = AccountSwitchEntrance()

    struct Entrance {
        let number: Int
        let curve: AccountSwitchTransition.Curve
        let image: AnyView
        let start: CFTimeInterval
    }

    private(set) var entrance: Entrance?
    @ObservationIgnored private var counter = 0

    func showItem(curve: AccountSwitchTransition.Curve, image: AnyView, start: CFTimeInterval) -> Int {
        counter += 1
        let number = counter
        entrance = Entrance(number: number, curve: curve, image: image, start: start)
        // Cleanup after the ring. Before that the image is already gone
        // (``Kontowechselbild`` draws it only until the swap).
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(0, curve.paintEnd + 0.05
                                                    - (CACurrentMediaTime() - start))))
            self.distance(number)
        }
        return number
    }

    func distance(_ number: Int) {
        guard entrance?.number == number else { return }
        entrance = nil
    }
}

/// **The flying profile picture and the ring**, following
/// ``Kontowechselflug/Kurve``: the same three springs, landing and ring as on
/// iPhone. Takes no clicks.
struct AccountSwitchImage: View {
    @State private var stage = AccountSwitchEntrance.shared

    var body: some View {
        GeometryReader { g in
            if let a = stage.entrance {
                let o = g.frame(in: .global).origin
                TimelineView(.animation) { _ in
                    let t = CACurrentMediaTime() - a.start
                    let base = a.curve.size * 1.06
                    ZStack(alignment: .topLeading) {
                        // Until the swap; after that the real image sits there.
                        if t < a.curve.swap {
                            let b = a.curve.status(max(0, t))
                            a.image
                                .frame(width: base, height: base)
                                .scaleEffect(b.s / base)
                                .position(x: b.x - o.x, y: b.y - o.y)
                        }
                        // The ring, only hinted at: from the landing, spring 0.35/0.75, fully visible for
                        // 0.45 s, then fading out over 0.35 s, 55 % at most. On the Mac it is scaled to
                        // the smaller target.
                        let r = t - a.curve.landing
                        if r >= 0, r < 0.8 {
                            let mass = AccountSwitchTransition.Curve.spring(0.6, 1, 0, 0.35, 0.75, r)
                            let d = r < 0.45 ? min(1, r / 0.05) : 1 - min(1, (r - 0.45) / 0.35)
                            let border = 52 * a.curve.targetSize / AccountSwitchTransition.Curve.targetSize
                            Circle()
                                .stroke(Theme.accent, lineWidth: 2)
                                .frame(width: border - 2, height: border - 2)
                                .scaleEffect(mass)
                                .opacity(d * 0.55)
                                .position(x: a.curve.to.x - o.x, y: a.curve.to.y - o.y)
                        }
                    }
                    .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
