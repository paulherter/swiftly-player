import SwiftUI

// MARK: - Transitions
//
// Spring and card from the badge, on iPhone, iPad, Mac and TV. The color from
// the image lives in `ImageMood.swift` (iPhone) and `ImageTone.swift`.

extension Theme {
    /// **The spring for everything that opens and closes.** Critically damped
    /// enough that nothing overshoots (0.9), fast enough to answer the finger
    /// (0.35). A spring instead of a duration: closing in the middle of opening
    /// redirects the motion instead of restarting it. With Reduce Motion, the short
    /// cross-fade.
    static var spring: Animation {
        motionReduced ? fadeReduced : .spring(response: 0.35, dampingFraction: 0.9)
    }
}

// MARK: - From a point

/// **A card that grows out of its button** and shrinks back to it.
///
/// The point is given in global coordinates; where it lies relative to the card
/// is computed by `visualEffect` from the card's current frame, without the card
/// changing its layout. Only scale and opacity change, both without a new layout
/// per frame.
struct OriginEntrance: ViewModifier {
    /// 0 = at the point, 1 = there.
    let share: Double
    let provenance: CGPoint?

    /// As large as the badge relative to a card of about 360.
    nonisolated private static let beginning: CGFloat = 0.12

    func body(content: Content) -> some View {
        content
            .visualEffect { [share, provenance] content, status in
                let frameRect = status.frame(in: .global)
                let anchor = provenance.map {
                    UnitPoint(x: ($0.x - frameRect.minX) / max(frameRect.width, 1),
                              y: ($0.y - frameRect.minY) / max(frameRect.height, 1))
                } ?? .center
                let mass = Self.beginning + (1 - Self.beginning) * CGFloat(share)
                return content.scaleEffect(mass, anchor: anchor)
            }
            // Opacity runs faster than scale: fully shrunk the card is nearly invisible,
            // and when closing it is gone before it becomes a point.
            .opacity(min(1, share * 1.6))
    }
}

extension AnyTransition {
    /// Grows out of `provenance` (global); without a point or with Reduce Motion
    /// simply cross-faded.
    static func outPoint(_ provenance: CGPoint?) -> AnyTransition {
        guard provenance != nil, !Theme.motionReduced else { return .opacity }
        return .modifier(active: OriginEntrance(share: 0, provenance: provenance),
                         identity: OriginEntrance(share: 1, provenance: provenance))
    }
}

/// **Where the most recently tapped badge is**, in global coordinates. The
/// picker grows out of there and shrinks back to it. There are several badges in
/// the tree, one per page; the one meant is always the one that received the
/// tap, so it is set on tap and not through a default from the tree. On TV there
/// is only the one in the header bar; it reports its frame continuously.
@MainActor
enum BadgeOrigin {
    static var point: CGPoint?
}

// The account switch (sequence, curve, staggered rows) lives in
// `Sources/Shared/AccountTransition.swift`, shared by all Apple platforms; the
// stage and self-test in UIKit live in `AccountSwitchStageUIKit.swift`.
