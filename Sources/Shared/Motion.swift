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

enum Motion {
    /// **A surface from below** (sheet, panel): fast approach, no overshoot. The same as
    /// the app's own sheet (`Theme.sheetMotion`), which takes its numbers from here.
    static var sheet: Animation {
        Theme.motionReduced ? Theme.fadeReduced : .spring(response: 0.35, dampingFraction: 0.86)
    }

    /// **Content that changes in place**: a look's colors and glow, a step of the gift,
    /// the thank-you page. Smooth, 0.28 s, no overshoot (`Theme.reveal` is the same).
    static var change: Animation {
        Theme.motionReduced ? Theme.fadeReduced : .smooth(duration: 0.28)
    }

    /// **A small selection**: the segments' surface, the ring around a chosen dot.
    static var select: Animation {
        Theme.motionReduced ? Theme.fadeReduced : .smooth(duration: 0.25)
    }

    /// **Something that lands**: the picked-up gift's icon, like the profile picture that
    /// settles in the header (spring of about 0.45 s, almost critically damped).
    static var land: Animation {
        Theme.motionReduced ? Theme.fadeReduced : .spring(response: 0.45, dampingFraction: 0.86)
    }

    /// **How long the page takes before a sheet follows it**, in seconds: the profile
    /// slides away (the system's own pop, about 0.35 s) and the sheet comes up while it
    /// settles, never at the same moment as a second movement.
    static let pageBeforeSheet = 0.18
}
