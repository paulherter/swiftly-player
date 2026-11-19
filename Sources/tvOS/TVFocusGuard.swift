import OSLog
import SwiftUI
import UIKit

/// **Nothing focusable during tvOS's first focus pass.**
///
/// tvOS runs its first focus pass when the window appears. At launch the curtain, the
/// profile picker, the sign-in screen or a skeleton is what exists then; if the pass finds
/// nothing, UIKit logs "Failed to update focus … nextFocusedItem: nil" and never asks again:
/// content that becomes focusable later stays unfocused and the remote does nothing.
///
/// This guard asks again: when a screen change (`key`) or the first content arrives it
/// checks, after a short and a longer delay, whether the focus system holds an item, and
/// if not it requests a focus update on the topmost view controller. It never moves focus
/// that exists.
@MainActor
enum TVFocusGuard {
    private static let log = Logger(subsystem: "app.swiftly", category: "focus")

    /// Pure decision, tested: ask for a focus update only when nothing holds focus.
    nonisolated static func needsRequest(focusHolds: Bool) -> Bool { !focusHolds }

    /// Delays (seconds) after a trigger: one frame of layout, then the end of transitions.
    nonisolated static let checks: [Double] = [0.15, 0.7]

    private static var generation = 0

    static func request(_ reason: String) {
        generation += 1
        let mine = generation
        for delay in checks {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                guard mine == generation else { return }
                recover(reason, after: delay)
            }
        }
    }

    private static func recover(_ reason: String, after delay: Double) {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first,
            var top = window.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        let system = UIFocusSystem.focusSystem(for: top)
        guard needsRequest(focusHolds: system?.focusedItem != nil) else { return }
        log.notice("focus empty \(delay, privacy: .public)s after \(reason, privacy: .public): requesting update")
        top.setNeedsFocusUpdate()
        top.updateFocusIfNeeded()
    }
}

extension View {
    /// Requests a focus recovery on appear and whenever `key` changes.
    func tvFocusGuard<Key: Equatable>(_ reason: String, key: Key) -> some View {
        onAppear { TVFocusGuard.request(reason) }
            .onChange(of: key) { _, _ in TVFocusGuard.request(reason) }
    }
}
