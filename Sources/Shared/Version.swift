import Foundation
import JellyfinKit
#if canImport(UIKit)
import UIKit
#endif

// **Its own file so the TV target gets it too.**
//
// It used to live in `Components.swift`, which the tvOS target does not
// include, so Apple TV had no version info. That is exactly the information
// a bug report needs.

/// What the profile page shows at the bottom: "Swiftly Player 1.0.1 (Build 1)".
///
/// **Read from the bundle, not typed.** The iPhone once showed "Swiftly 1.0",
/// a number nobody updated that had been wrong since the first submission. A
/// version string maintained by hand is worse than none: it looks reliable.
///
/// The build number is included because in a bug report it is the actual
/// information; twelve builds carried "1.0.0".
///
/// **Why here and not in `ProfileView`.** It was a `static` in
/// `Sources/Shared/ProfileView.swift`, a file that belongs to the iPhone; the
/// Mac has its own profile page and could not reach it. That is how the
/// copies arise that gave this file its name, so the computation lives where
/// everyone sees it and the views only set the text.
enum Version {

    /// The player's version. **Typed once, not three times**: it used to appear
    /// literally in `Sources/Shared/SettingsView.swift` and again in
    /// `Sources/macOS/SettingsView.swift`. At the next VLCKit change one of
    /// them would have survived.
    static let mediaPlayer = "VLCKit 4.0.0-a23"

    /// Who the app is. **On the profile page**, where someone checks which
    /// version they have.
    static var row: String {
        let b = Bundle.main.infoDictionary
        let version = b?["CFBundleShortVersionString"] as? String ?? "?"
        let build = b?["CFBundleVersion"] as? String ?? "?"
        // **"Swiftly Player", not "Swiftly for Jellyfin".**
        //
        // App Review rejected the submission under guideline 4.1(c): an app's name
        // must not carry another developer's product brand. The store listing is
        // therefore "Swiftly Player", and this line is shown in the profile of the
        // same app, so it must say the same.
        return "Swiftly Player \(version) (Build \(build))"
    }

    /// The same line plus the underlying components. **In settings**, because
    /// that is where the bug report starts.
    ///
    /// The two differ, and still do, but now for a reason and from **one** source:
    /// the profile says who the app is, settings say what it is made of. Whoever
    /// reports a bug is sent to settings, not to the profile.
    static var withBase: String { row + " · " + mediaPlayer }

    /// A new GitHub issue with version and system already filled in.
    /// The address and what may go in are defined in the package (`Community`).
    static var errorReport: URL {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if os(tvOS)
        let system = "tvOS"
        #elseif os(macOS)
        let system = "macOS"
        #else
        let system = UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        #endif
        return Community.errorReport(version: withBase,
                                         platform: "\(system) \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")
    }
}
