import Foundation

/// **What is named differently on each platform but means the same.**
///
/// The UI exists exactly once in the repo and is built jointly for Linux and
/// Windows. For that to hold, no path or folder name may appear in the middle
/// of the code; otherwise the first difference moves into an `#if` branch, the
/// second into the next, and eventually the versions drift apart unnoticed.
/// Everything that differs is therefore here.
enum Platform {

    /// What the system is called, in the hand-over hint to the other device
    /// (``Uebergabekarte/departurePostTop(von:nach:)`` counts both as desktop, like
    /// the Mac). Product names, not translated.
    static var system: String {
        #if os(Windows)
        return "Windows"
        #else
        return "Linux"
        #endif
    }

    /// The path of the running program.
    ///
    /// **On Linux via `/proc/self/exe`**, not `Bundle.main`: with a SwiftPM build
    /// the bundle path points to the build directory rather than the file, and the
    /// location of the shipped resources is derived from it. Windows has no
    /// symbolic link there; Foundation returns the path directly.
    static var programPath: String? {
        #if os(Linux)
        return try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")
        #else
        return Bundle.main.executablePath ?? CommandLine.arguments.first
        #endif
    }

    /// The folder with the shipped resources: icon and start animation.
    ///
    /// Derived from the binary path: `<platform>/.build/<target>/debug/<name>` lies
    /// four levels below the platform directory, which contains `Resources`. When
    /// installed, the folder sits directly next to it. Both are checked so the same
    /// code works for the build and for the installation.
    static func bundled(_ name: String) -> String? {
        guard let itself = programPath else { return nil }
        let dm = FileManager.default
        var candidates: [URL] = []

        var tree = URL(fileURLWithPath: itself).deletingLastPathComponent()
        candidates.append(tree.appendingPathComponent("Resources"))
        for _ in 0..<4 {
            tree.deleteLastPathComponent()
            candidates.append(tree.appendingPathComponent("Resources"))
        }

        for k in candidates {
            let path = k.appendingPathComponent(name).path
            if dm.fileExists(atPath: path) { return path }
        }
        return nil
    }

    /// Where the app stores its settings.
    ///
    /// Linux follows the XDG specification, Windows the location the system
    /// provides for application data (`%APPDATA%`). Both match what users of the
    /// respective platform expect, and neither needs privileges.
    static var settingFolder: URL {
        #if os(Windows)
        let base = ProcessInfo.processInfo.environment["APPDATA"]
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("AppData/Roaming")
        return base.appendingPathComponent("Swiftly")
        #else
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
        return base.appendingPathComponent("swiftly")
        #endif
    }

    /// Where the app stores what it can fetch again at any time: images.
    ///
    /// Not next to the settings: on Windows `%APPDATA%` roams with the profile over
    /// the network, and some backups include `~/.config`. Linux uses
    /// `XDG_CACHE_HOME`, Windows `%LOCALAPPDATA%`, where both systems expect
    /// disposable data.
    static var cacheFolder: URL {
        #if os(Windows)
        let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"]
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("AppData/Local")
        return base.appendingPathComponent("Swiftly")
        #else
        let base = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cache")
        return base.appendingPathComponent("swiftly")
        #endif
    }
}
