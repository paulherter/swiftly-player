import SwiftUI
import UIKit

// When iPadOS puts its buttons on our window.
//
// **Its own file, and that is the point.** This used to live in `HeroHeader.swift`
// because it was needed when building the detail page, but by now almost every
// header hangs on it: `Seitenleiste`, `BlurHeader`, `DetailHeader`, `PagesArrow`,
// `MainView`, `HomeView`, `SearchView` and both players. Whoever looks for the
// traffic lights does not look in the hero image.

private struct WindowButtonsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// iPadOS puts its own window buttons over the top left corner.
    ///
    /// As soon as the app shares the screen (split view, Stage Manager) iPadOS puts its
    /// traffic lights on the window. Exactly there sits our back arrow: `PagesArrow`
    /// keeps 8 points from the left and 6 from the top. In full screen the status bar
    /// pushes it down; a window has none, and the buttons cover it.
    ///
    /// Detection is by width, not size class: "shares the screen" means exactly that the
    /// window is narrower than the screen. Slide Over, half and two-thirds screen all
    /// fall under it, full screen does not.
    var windowButtons: Bool {
        get { self[WindowButtonsKey.self] }
        set { self[WindowButtonsKey.self] = newValue }
    }
}


/// Where iPadOS puts its window buttons and how much room they need.
///
/// **Why this is a function and not only the environment value above:** the player
/// is a `fullScreenCover`. It does not hang under `MainView`, and it explicitly
/// ignores the safe area, since the picture lives there. A safe-area inset the frame
/// takes therefore does not reach it. Whatever needs room at the top in the player
/// must take it itself.
///
/// The first version failed on exactly that: it padded the frame and forgot the
/// player because it looks like a part of it.
enum WindowButtons {
    /// Height to keep free. The traffic lights sit in a field about 44 points tall at the top left; 32 on top of the 18 the headers hold anyway pushes the button below it.
    static let height: CGFloat = 32

    /// The app is in a window instead of full screen.
    ///
    /// **Measured on device, not derived.** Two assumptions were wrong before, and both
    /// sounded plausible:
    ///
    /// - "A window has no status bar, so no top safe area." Wrong. Measured, it is 32
    /// points in **both** cases; the safe area distinguishes nothing.
    /// - "A window reports its own screen." Also wrong. `screen.bounds.width` reports
    /// 1180 while the window measures 375.
    ///
    /// So the width comparison is right. What was wrong was the assumption that a
    /// safe-area inset on the frame reaches everyone; see `height`.
    @MainActor
    static func inWindow(windowWidthValue: CGFloat) -> Bool {
        guard Theme.atPad, windowWidthValue > 0 else { return false }
        let screen = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.width ?? 0
        return screen > 0 && windowWidthValue < screen - 8
    }
}
