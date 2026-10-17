import AppKit
import SwiftUI

/// Removes the title bar's own material.
///
/// `.windowStyle(.hiddenTitleBar)` hides only the **title**; the bar itself stays
/// and lays a light system material over the content, leaving a brightened strip
/// at the top while everywhere else in this app content runs **under** header and
/// bar.
///
/// Three settings are needed: a transparent bar, the window background set to our
/// base tone (otherwise Apple's window white flashes while resizing), and the full
/// content area so it reaches under the traffic lights.
struct WindowLine: NSViewRepresentable {

    final class Probe: NSView {
        private var observer: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            highlight()

            // **Applying it once is not enough.** AppKit and SwiftUI reset bar and material
            // from time to time, on entering full screen and when the window comes back to
            // the front. The styling then hit state that was already replaced by rebuilt
            // views, and the light bar returned.
            //
            // Same pattern as the traffic-light bug: the code that applies the state must run
            // again wherever its precondition changes. Remove the old observers when leaving
            // the window, otherwise they accumulate if the view moves several times.
            observer.forEach(NotificationCenter.default.removeObserver)
            observer.removeAll()
            guard let window = window else { return }
            for name: Notification.Name in [NSWindow.didBecomeKeyNotification,
                                            NSWindow.didEnterFullScreenNotification,
                                            NSWindow.didExitFullScreenNotification] {
                observer.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.highlight() }
                    })
            }
        }

        private func highlight() {
            guard let window = window else { return }
            WindowLine.highlight(window)
        }
    }

    /// **The styling lives in one place, not two.**
    ///
    /// The `Probe` applies it on window change and full screen. The player needs the
    /// same styling when it opens, since AppKit restores the bar's material from time
    /// to time and a light strip then appears above the picture. Two copies of the same
    /// steps would be exactly the duplication to avoid, so it lives here once and
    /// `WindowHolder` calls it too.
    @MainActor
    static func highlight(_ window: NSWindow) {
        // **Touch nothing in full screen.**
        //
        // macOS fades the title bar in and out itself when the pointer reaches the top
        // edge. Reaching into its views during that motion (`isHidden` on its material
        // views, a new style frame) makes the whole system stall for a moment.
        //
        // There is nothing to switch off in full screen anyway: the bar is not there.
        guard !window.styleMask.contains(.fullScreen) else { return }

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(Theme.reason)
        window.isOpaque = true
        window.styleMask.insert(.fullSizeContentView)

        // **`titlebarAppearsTransparent` alone is not enough.** The bar keeps its own
        // material and brightens even when content runs underneath, the same as with
        // `.ultraThinMaterial`: every material carries a light layer.
        //
        // Three things have to go: a set toolbar, the separator line, and the material in
        // the bar itself.
        window.toolbar = nil
        window.titlebarSeparatorStyle = .none

        // The bar is the parent view of the traffic lights. Any `NSVisualEffectView` in it
        // is the light layer.
        if let bar = window.standardWindowButton(.closeButton)?.superview {
            materialHide(in: bar)
        }
    }

    /// Looks for material views in the bar and hides them.
    ///
    /// **It leaves the traffic lights alone.** They sit in the same view, so only what
    /// really is an `NSVisualEffectView` is hidden, not the parent view.
    @MainActor
    private static func materialHide(in viewRef: NSView) {
        for part in viewRef.subviews {
            if let material = part as? NSVisualEffectView {
                material.material = .windowBackground
                material.blendingMode = .withinWindow
                material.state = .inactive
                material.isHidden = true
            }
            materialHide(in: part)
        }
    }

    func makeNSView(context: Context) -> Probe { Probe(frame: .zero) }
    func updateNSView(_ viewRef: Probe, context: Context) {}
}
