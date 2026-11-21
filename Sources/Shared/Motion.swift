import SwiftUI

// MARK: - Motion
//
// **The few curves the supporter surfaces move with, in one place.**
//
// The reference is the account switch (`AccountTransition.swift`): springs that arrive
// without overshoot, 0.35 to 0.5 s to settle, short linear fades of 0.2 s, and everything
// interruptible, because a spring redirects instead of restarting. New surfaces (looks,
// sheets, pop-ups, the gift, segments) take their curve from here and never write
// `.easeInOut(duration:)` of their own: four places with four curves read as four apps.
//
// With Reduce Motion every curve is the short cross-fade (`Theme.fadeReduced`), not a
// cut: Apple replaces motion with a fade, never with stillness.
//
// Included in the iPhone/iPad and Mac targets.

#if os(iOS) || os(macOS)
extension Animation {
    /// A design-token motion role as a SwiftUI animation: `curve` is the token's curve name (bezier points come from the
    /// generated `SwiftlyDesignTokens.Curves`), `duration` its seconds.
    static func token(_ curve: String, _ duration: Double) -> Animation {
        typealias C = SwiftlyDesignTokens.Curves
        switch curve {
        case "drawer":
            return .timingCurve(C.drawerX1, C.drawerY1, C.drawerX2, C.drawerY2, duration: duration)
        case "ease-in-out":
            return .timingCurve(C.easeInOutX1, C.easeInOutY1, C.easeInOutX2, C.easeInOutY2, duration: duration)
        case "linear":
            return .linear(duration: duration)
        case "smooth":
            return .smooth(duration: duration)
        case "snappy":
            return .snappy(duration: duration)
        default:  // "ease-out"
            return .timingCurve(C.easeOutX1, C.easeOutY1, C.easeOutX2, C.easeOutY2, duration: duration)
        }
    }
}
#endif

enum Motion {
    /// **A surface from below** (sheet, panel): fast approach, no overshoot. The same as
    /// the app's own sheet (`Theme.sheetMotion`), which takes its numbers from here.
    static var sheet: Animation {
        #if os(iOS) || os(macOS)
        Theme.motionReduced ? Theme.fadeReduced : .token(SwiftlyDesignTokens.Layout.motionEmphasizedCurve, SwiftlyDesignTokens.Layout.motionEmphasizedDuration)   // token motion.emphasized
        #else
        Theme.motionReduced ? Theme.fadeReduced : .spring(response: 0.35, dampingFraction: 0.86)
        #endif
    }

    /// **Content that changes in place**: a look's colors and glow, a step of the gift,
    /// the thank-you page. Smooth, 0.28 s, no overshoot (`Theme.reveal` is the same).
    static var change: Animation {
        #if os(iOS) || os(macOS)
        Theme.motionReduced ? Theme.fadeReduced : .token(SwiftlyDesignTokens.Layout.motionStandardCurve, SwiftlyDesignTokens.Layout.motionStandardDuration)   // token motion.standard
        #else
        Theme.motionReduced ? Theme.fadeReduced : .smooth(duration: 0.28)
        #endif
    }

    /// **A small selection**: the segments' surface, the ring around a chosen dot.
    static var select: Animation {
        #if os(iOS) || os(macOS)
        Theme.motionReduced ? Theme.fadeReduced : .token(SwiftlyDesignTokens.Layout.motionSelectCurve, SwiftlyDesignTokens.Layout.motionSelectDuration)   // token motion.select
        #else
        Theme.motionReduced ? Theme.fadeReduced : .smooth(duration: 0.25)
        #endif
    }

    /// **Something that lands**: the picked-up gift's icon, like the profile picture that
    /// settles in the header (spring of about 0.45 s, almost critically damped).
    static var land: Animation {
        #if os(iOS) || os(macOS)
        Theme.motionReduced ? Theme.fadeReduced : .token(SwiftlyDesignTokens.Layout.motionEmphasizedLandCurve, SwiftlyDesignTokens.Layout.motionEmphasizedLandDuration)   // token motion.emphasized-land
        #else
        Theme.motionReduced ? Theme.fadeReduced : .spring(response: 0.45, dampingFraction: 0.86)
        #endif
    }

    /// **How long the page takes before a sheet follows it**, in seconds: the profile
    /// slides away (the system's own pop, about 0.35 s) and the sheet comes up while it
    /// settles, never at the same moment as a second movement.
    static let pageBeforeSheet = 0.18

    /// **A look's colors change with one cross-fade** (`change`'s 0.28 s). On the Mac the
    /// window itself fades from the old picture to the new one, done by the render server:
    /// animating every color through SwiftUI redrew the whole page on each frame and the
    /// fade stuttered (probe "look anprobiert": 10 of 142 frames dropped). The change
    /// itself then lands at once, in the same transaction the fade covers.
    @MainActor @discardableResult
    static func recolor<Result>(_ change: () -> Result) -> Result {
        #if os(macOS)
        for window in NSApp.windows where window.isVisible {
            guard let layer = window.contentView?.layer else { continue }
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Theme.motionReduced ? 0.14 : 0.28
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(fade, forKey: "recolor")
        }
        var still = Transaction()
        still.disablesAnimations = true
        return withTransaction(still, change)
        #else
        return withAnimation(Self.change, change)
        #endif
    }
}
