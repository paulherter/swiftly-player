import Foundation
import JellyfinKit
// On Linux and Windows, Foundation's networking lives in a separate module;
// on Apple it is part of Foundation. The same line exists in `JellyfinClient`
// for the same reason.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(Windows)
import WinSDK
#endif

/// **Check for a newer version and install it; Windows only.**
///
/// On Linux the package repository does this: anyone who set up via
/// `swiftly-install.sh` gets Swiftly with the other system updates. On
/// Windows there is no equivalent; users download the installer by hand from
/// the release page and do not remember to.
///
/// **Only on request, never by itself.** The app does not check at startup.
/// That is a decision, not a convenience: GitHub counts anonymous requests per
/// address (sixty per hour), and an app that checks at every start becomes
/// self-running without anyone asking for it. Installation also only happens
/// on request.
enum Update {

    /// Where the information comes from. No access token, so nothing that would
    /// have to be cut out of a log.
    private static let inquiry =
        URL(string: "https://api.github.com/repos/paulherter/swiftly-player/releases/latest")!

    struct Snapshot {
        /// "1.0.4", without the `v` of the tag.
        let version: String
        /// The build number from the release text, if it names one.
        let build: Int?
        let address: URL
        /// What changes, as written on the release page.
        let notes: String
        let size: Int
    }

    enum Failure: Error {
        case noResponse
        case noInstaller
        case incomplete
    }

    // MARK: Search

    /// `nil` means there is nothing newer.
    static func searching() async throws -> Snapshot? {
        var petition = URLRequest(url: inquiry)
        // GitHub requires a user agent and otherwise returns 403.
        petition.setValue("Swiftly/\(Version.number)", forHTTPHeaderField: "User-Agent")
        petition.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        petition.timeoutInterval = 20
        let (data, answer) = try await URLSession.shared.data(for: petition)
        guard let http = answer as? HTTPURLResponse, http.statusCode == 200,
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Failure.noResponse }

        let marker = (raw["tag_name"] as? String) ?? ""
        let version = marker.hasPrefix("v") ? String(marker.dropFirst()) : marker
        let notes = (raw["body"] as? String) ?? ""
        let build = buildNumber(from: notes)

        guard newAsOur(version: version, build: build) else { return nil }

        // **The Windows installer, not the first attachment.** A release also has
        // `.deb`, `.rpm` and a tarball attached.
        let attachments = (raw["assets"] as? [[String: Any]]) ?? []
        guard let exe = attachments.first(where: {
            (($0["name"] as? String) ?? "").lowercased().hasSuffix("-setup.exe")
        }), let place = exe["browser_download_url"] as? String, let address = URL(string: place)
        else { throw Failure.noInstaller }

        return Snapshot(version: version, build: build, address: address, notes: notes,
                     size: (exe["size"] as? Int) ?? 0)
    }

    /// Both live in the package (``JellyfinKit/Fassungsvergleich``) because the
    /// GTK layer has no test target. Nine tests cover them there, including that
    /// 1.0.10 is newer than 1.0.9.
    static func buildNumber(from text: String) -> Int? {
        VersionComparison.buildNumber(fromText: text)
    }

    static func newAsOur(version: String, build: Int?) -> Bool {
        VersionComparison.newer(there: version, here: Version.number,
                                buildThere: build, buildHere: Int(Version.build) ?? 0)
    }

    // MARK: Download and start

    /// **The file is written by the app itself, and that is the point.**
    ///
    /// Windows attaches a second data stream called `Zone.Identifier` (the mark of
    /// the web) to everything arriving via `URLDownloadToFile` or the attachment
    /// service. SmartScreen keys on it: a marked, unsigned file is flagged at
    /// launch. A file a program writes itself with ordinary writes does not get it.
    ///
    /// Hence `URLSession` and a custom `write` here. Replacing this with something
    /// more convenient brings the warning back.
    static func fetch(_ state: Snapshot) async throws -> URL {
        var petition = URLRequest(url: state.address)
        petition.setValue("Swiftly/\(Version.number)", forHTTPHeaderField: "User-Agent")
        petition.timeoutInterval = 600
        let (data, answer) = try await URLSession.shared.data(for: petition)
        // **Only start what really is the installer.** Every response used to be
        // written as `.exe` and executed, including an error page from GitHub (404,
        // 503) or an interrupted transfer. Windows then reported "not a valid
        // application" after the app had already quit. GitHub states the size with the
        // attachment; if it does not match, the file was incomplete.
        guard let http = answer as? HTTPURLResponse, http.statusCode == 200
        else { throw Failure.noResponse }
        guard state.size <= 0 || data.count == state.size
        else { throw Failure.incomplete }
        let target = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Swiftly-\(state.version)-Setup.exe")
        try? FileManager.default.removeItem(at: target)
        try data.write(to: target)
        return target
    }

    /// Start the installer and quit the app; it cannot replace a running
    /// `Swiftly.exe`.
    static func inPlay(_ file: URL) throws {
        #if os(Windows)
        // Release the run marks first: the installer checks them at startup
        // (`AppMutex`), and the app is about to exit anyway.
        for mark in runMarks { if let mark { CloseHandle(mark) } }
        #endif
        let run = Process()
        run.executableURL = file
        try run.run()
    }
}
