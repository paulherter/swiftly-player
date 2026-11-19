import SwiftUI

/// The motion of the arrival stack: one spring for opening, closing and for the cards that close a gap, so every
/// card of one change arrives together. Reduce Motion: a short fade, nothing flies.
enum ArrivalMotion {
    /// How far each card behind the front one peeks out below it (drawn, not laid out).
    static let peek: CGFloat = 12
    /// The room a closed stack takes below its front card. The peeking cards are decoration and reach into the gap to the
    /// next row; only this much is laid out, so the front card's distance to the next row stays near the Start page's
    /// normal section gap (`Theme.railsSpacing`) instead of growing by the whole peek.
    static let closedRoom: CGFloat = 8

    static var spring: Animation {
        Theme.motionReduced ? Theme.reveal : .spring(response: 0.42, dampingFraction: 0.84)
    }
}
