import SwiftUI
import UIKit

/// **The player in its own UIKit frame - the app stays portrait.**
///
/// Previously the player hung on the page as a `fullScreenCover`, and rotation
/// went through the mask of the whole scene. On close the app behind was
/// still landscape and only rotated back afterwards; rotating early made
/// rotating and sliding away judder against each other.
///
/// Streaming apps do it this way: only the player controller allows
/// landscape, everything else is portrait. On show and close UIKit rotates
/// **in the same transition** - the app below is never laid out in landscape.
///
/// On iPad it stays a `fullScreenCover`: everything rotates freely there.
final class PlayerFrame: UIHostingController<AnyView> {
    /// The frame currently shown - `PlayerScreen` closes through it.
    private(set) static weak var active: PlayerFrame?

    private var ended: (() -> Void)?
    /// From closing on, portrait is allowed too: otherwise player and app would
    /// share no orientation during the transition, and UIKit would not rotate.
    private var closes = false
    /// How often UIKit was asked per press - a cap, not a loop.
    private var attempts = 0

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        closes ? .allButUpsideDown : Orientierung.shared.allowed
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        // If the phone is already held in landscape, open in that direction.
        // From a handover: portrait until the card is gone.
        if Orientierung.shared.handoffHolds { return .portrait }
        switch UIDevice.current.orientation {
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        default: return Orientierung.shared.allowed == .landscape ? .landscapeRight : .portrait
        }
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    /// Shows the player over the topmost controller.
    /// - Parameter `calm`: no cross-fade - from a handover, where the player
    /// opens under the card and is only visible with its zoom.
    static func showItem(_ content: AnyView, landscapeFixed: Bool, calm: Bool = false,
                       ended: @escaping () -> Void) {
        guard active == nil,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
              var top = scene.keyWindow?.rootViewController else { return }
        while let proceed = top.presentedViewController { top = proceed }

        // Open the mask first, then present: UIKit asks during the transition.
        Orientierung.shared.playerOpened(landscapeFixed: landscapeFixed, demand: false)
        let frameRect = PlayerFrame(rootView: content)
        frameRect.ended = ended
        frameRect.modalPresentationStyle = .fullScreen
        // **Cross-fade instead of slide.** Sliding happens in the player's coordinate
        // system: in landscape it came in "from the bottom" - from the left in
        // portrait - and left going down in portrait. Different directions in and
        // out make no sense; a fade has no direction.
        frameRect.modalTransitionStyle = .crossDissolve
        frameRect.overrideUserInterfaceStyle = .dark
        frameRect.view.backgroundColor = .black
        active = frameRect
        top.present(frameRect, animated: !calm)
    }

    /// Closes the player; the rotation back runs in the same transition.
    ///
    /// **Every call reaches the goal, not just the first.** Previously the first
    /// call set a latch and asked UIKit once to dismiss. If a transition was
    /// running at that moment, UIKit silently drops the request without a
    /// completion - the latch stayed set and every further "close" bounced off
    /// it. Now the request waits for a running transition to end and counts as
    /// done only once the frame is really gone.
    func close() {
        AppLog.writeOut("[Rahmen] Schließen · schon dabei \(closes) · Übergang \(transitionCoordinator != nil)")
        if !closes {
            closes = true
            Orientierung.shared.playerClosed(demand: false)
        }
        attempts = 0
        remove()
    }

    /// On the presenter of the frame: that removes it with everything it presents
    /// itself. `dismiss` on the frame itself would only have removed the topmost
    /// one and the player would have stayed.
    private func remove() {
        guard let below = presentingViewController else { done(); return }
        if let ongoing = transitionCoordinator ?? below.transitionCoordinator {
            ongoing.animate(alongsideTransition: nil) { [weak self] _ in self?.remove() }
            return
        }
        guard attempts < 3 else {
            AppLog.writeOut("[Rahmen] nach \(attempts) Versuchen noch da")
            return
        }
        attempts += 1
        below.dismiss(animated: true) { [weak self] in
            guard let self else { return }
            // Closed when nobody presents it anymore - otherwise once more.
            if self.presentingViewController == nil { self.done() } else { self.remove() }
        }
    }

    private func done() {
        guard let ended else { return }
        self.ended = nil
        if PlayerFrame.active === self { PlayerFrame.active = nil }
        ended()
    }
}

extension View {
    /// Opens the player - on iPhone in its own frame (`PlayerFrame`),
    /// on iPad as a `fullScreenCover` as before.
    func playerCover<ContentBody: View>(item wish: Binding<PlayRequest?>,
                                   @ViewBuilder content: @escaping (PlayRequest) -> ContentBody) -> some View {
        modifier(PlayerCover(wish: wish, coverContent: content))
    }
}

private struct PlayerCover<ContentBody: View>: ViewModifier {
    @Binding var wish: PlayRequest?
    let coverContent: (PlayRequest) -> ContentBody
    @AppStorage("querformatFest") private var landscapeFixed = true

    func body(content: Content) -> some View {
        if Theme.atPad {
            content.fullScreenCover(item: $wish, content: coverContent)
        } else {
            content.onChange(of: wish?.id, initial: true) { _, id in
                if let opened = wish, id != nil {
                    PlayerFrame.showItem(AnyView(coverContent(opened)), landscapeFixed: landscapeFixed,
                                        calm: HandoffStage.shared.active) {
                        wish = nil
                    }
                } else {
                    PlayerFrame.active?.close()
                }
            }
        }
    }
}
