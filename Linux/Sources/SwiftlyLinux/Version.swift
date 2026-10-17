import Foundation

/// Which version runs here, **in one place, not three.**
///
/// **Why this has its own file.** The profile and the settings each had a
/// hand-typed "Swiftly 1.0". It is what a tester writes into a bug report, and
/// a wrong number there costs time searching the wrong version.
///
/// **On Apple it comes from the bundle** (`CFBundleShortVersionString` and
/// `CFBundleVersion`); Linux has no Info.plist, so it is defined here. The two
/// numbers therefore live in exactly **two** places: here and in
/// `Linux/Install/PKGBUILD` (`pkgver`), which the build touches anyway.
/// Whoever changes one changes the other.
enum Version {
    static let number = "1.0.6"
    /// **The build number counts when the same version is released again.**
    /// Without it, a bug report just says "1.0.4" and nobody knows whether the
    /// fix was included.
    static let build = "1"

    /// "Swiftly Player 1.0.0 (Build 10)": the full name, as the other platforms
    /// show it in the profile.
    static var full: String { "Swiftly Player \(number) (Build \(build))" }
}
