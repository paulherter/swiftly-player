import AppKit
import SwiftUI

/// Whether the keyboard focus mark (system ring and our own focus surface) is visible.
///
/// **Like a normal Mac app:** nothing at launch, on the splash or in the player. The mark
/// appears once the user navigates with the keyboard (Tab, Shift-Tab, arrows) and goes away
/// again on the next mouse click. Focus itself always exists, so Tab keeps working; only
/// its drawing is gated. With Full Keyboard Access on, AppKit hands first focus to the first
/// button (the "Home" row) before anyone pressed a key, which is what showed the ring.
///
/// One enum, all transitions in ``reduce(_:_:)``.
enum KeyboardFocus: Equatable, Sendable {
    /// Start state and after any pointer use: no mark.
    case quiet
    /// The user navigated by keyboard: the mark shows.
    case keyboard

    enum Event: Equatable, Sendable {
        /// Tab, Shift-Tab, an arrow key or Space/Return on a focused control.
        case navigationKey
        /// Any other key (typing, shortcuts): says nothing about focus.
        case otherKey
        case pointerDown
    }

    static func reduce(_ state: KeyboardFocus, _ event: Event) -> KeyboardFocus {
        switch event {
        case .navigationKey: .keyboard
        case .pointerDown: .quiet
        case .otherKey: state
        }
    }

    var showsMark: Bool { self == .keyboard }

    /// Key codes that start keyboard navigation: Tab, arrows.
    static func isNavigation(keyCode: UInt16) -> Bool {
        [48, 123, 124, 125, 126].contains(keyCode)
    }

    /// Hidden views must not hold focus: the sidebar and the pages lie *under* the player
    /// overlay and under the launch curtain, still in the focus chain, so their first row took
    /// the focus and its ring was drawn through the overlay as an empty box.
    static func isReachable(playerOpen: Bool, curtainShown: Bool) -> Bool {
        !playerOpen && !curtainShown
    }
}

/// Feeds ``KeyboardFocus`` from real key and mouse events of the app.
@MainActor
@Observable
final class KeyboardFocusMonitor {
    private(set) var state: KeyboardFocus = .quiet
    @ObservationIgnored private var tokens: [Any] = []

    /// Starts the local event monitors; safe to call more than once.
    func start() {
        guard tokens.isEmpty else { return }
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
        let mouse = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
        tokens = [keys, mouse].compactMap { $0 }
    }

    func stop() {
        tokens.forEach(NSEvent.removeMonitor)
        tokens.removeAll()
    }

    func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            let navigates = KeyboardFocus.isNavigation(keyCode: event.keyCode)
            send(navigates ? .navigationKey : .otherKey)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            send(.pointerDown)
        default:
            break
        }
    }

    func send(_ event: KeyboardFocus.Event) {
        let next = KeyboardFocus.reduce(state, event)
        if next != state { state = next }
    }
}

private struct KeyboardMarkKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// `true` only after keyboard navigation started. Our own focus surfaces read this next to `isFocused`.
    var keyboardMarkShown: Bool {
        get { self[KeyboardMarkKey.self] }
        set { self[KeyboardMarkKey.self] = newValue }
    }
}

extension View {
    /// Gates the system focus ring and publishes ``EnvironmentValues/keyboardMarkShown``.
    func keyboardFocusMark(_ state: KeyboardFocus) -> some View {
        environment(\.keyboardMarkShown, state.showsMark)
            .focusEffectDisabled(!state.showsMark)
    }
}
