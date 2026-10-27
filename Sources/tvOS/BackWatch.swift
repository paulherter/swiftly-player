import UIKit
import ObjectiveC

/// **Back must never be lost in the player.**
///
/// Measured on the Apple TV: after the controls came up at the start of a film (focus reported on the bar), the Menu press reached the app but `onExitCommand` never ran. Press after press, the screen stayed as it was, while Play/Pause still worked. A press at the application level is seen regardless of what the focus system thinks, so this watches there: if the player's own handler has not answered a Menu press within a quarter of a second, the same handler runs from here.
///
/// In the normal case the handler answers within milliseconds, `handled` is newer than the press, and this does nothing.
@MainActor
enum BackWatch {
    nonisolated(unsafe) private static var installed = false
    nonisolated(unsafe) private static var handler: (@MainActor () -> Void)?
    nonisolated(unsafe) private static var handledAt: CFTimeInterval = 0

    static func arm(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        guard !installed else { return }
        installed = true
        guard let original = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.sendEvent(_:))),
              let replacement = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.backWatchSendEvent(_:)))
        else { return }
        method_exchangeImplementations(original, replacement)
    }

    static func disarm() { handler = nil }

    /// The player's own handler calls this first.
    static func answered() { handledAt = CACurrentMediaTime() }

    fileprivate static func pressed() {
        guard handler != nil else { return }
        let at = CACurrentMediaTime()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard let handler, handledAt < at else { return }
            AppLog.writeOut("[Zurück] Taste kam an, Handler blieb stumm → nachgeholt")
            handledAt = CACurrentMediaTime()
            handler()
        }
    }
}

extension UIApplication {
    /// After the exchange this name holds the original implementation.
    @objc fileprivate func backWatchSendEvent(_ event: UIEvent) {
        if let presses = event as? UIPressesEvent,
           presses.allPresses.contains(where: { $0.phase == .began && $0.type == .menu }) {
            MainActor.assumeIsolated { BackWatch.pressed() }
        }
        backWatchSendEvent(event)
    }
}
