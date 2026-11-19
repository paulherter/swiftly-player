import Foundation

/// The bar buttons that open a player menu or panel on Apple TV.
public enum PlayerBarButton: Hashable, Sendable {
    case episodes, chapters, tracks, settings
}

/// **Where focus goes when a player menu closes: back to the button that opened it.**
///
/// The player's controls hide while a menu is open and come back when it closes. Their own "controls appeared" rule puts focus on
/// the timeline, and it ran after the menu's close and overrode it. The opener is remembered when the menu opens (another button
/// swapping the open menu replaces it) and handed out once on close; the controls' rule then lands on it instead of the timeline.
public struct PlayerMenuFocusReturn: Equatable, Sendable {
    public private(set) var opener: PlayerBarButton?

    public init() {}

    /// A menu opened from `button`; `nil` for a box that hangs from another box (the season list), which keeps the opener.
    public mutating func opened(from button: PlayerBarButton?) {
        if let button { opener = button }
    }

    /// The menu closed: the button to focus, once.
    public mutating func closed() -> PlayerBarButton? {
        defer { opener = nil }
        return opener
    }
}
