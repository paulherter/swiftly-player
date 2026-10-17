import Foundation

/// The version with which the app identifies itself to the server.
///
/// **"0.1.0" used to be the default value in `JellyfinClient`, and nobody ever
/// passed anything else.** It showed up in Jellyfin's own session overview:
/// "iPhone · Swiftly 0.1.0", for an app that is in the store as 1.0.1. A
/// version number that was never right is worse than none: it appears in every
/// error report a user copies from that overview.
///
/// Same lesson as for ``Version`` in the app: **read from the bundle, not
/// typed.** A number that has to be maintained by hand drifts apart, and you
/// do not notice at the place where it is used.
public enum VersionNumber {

    /// `CFBundleShortVersionString`, or "unbekannt" if there is no bundle. On
    /// Linux and Windows the same package version runs, and there is no Info list;
    /// the versions there set the value themselves.
    public static let outBundle: String = {
        let b = Bundle.main.infoDictionary
        if let short = b?["CFBundleShortVersionString"] as? String, !short.isEmpty {
            if let build = b?["CFBundleVersion"] as? String, !build.isEmpty {
                return "\(short) (\(build))"
            }
            return short
        }
        return "unbekannt"
    }()
}
