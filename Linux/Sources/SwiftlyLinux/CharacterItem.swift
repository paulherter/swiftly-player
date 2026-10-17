import CGtk
import Foundation

/// **The application icon and the menu entry.**
///
/// Under Wayland the taskbar does not show what a window tells it but what is
/// in the `.desktop` entry it finds via the application ID. Without the entry
/// there is no icon, which is why it was missing although the image was
/// already there.
///
/// On Apple, Xcode handles this; here there is no package to put anything in.
/// So the app installs both itself, in **its own** directory under
/// `~/.local/share`; nothing touches the system.
enum CharacterItem {

    static let identifier = "de.paulherter.swiftly"

    /// Location of the bundled images, derived from the binary path:
    /// `Linux/.build/<target>/debug/SwiftlyLinux`; four levels up is `Linux/`,
    /// and `Resources` is there.
    private static var bundled: URL? {
        Platform.bundled("icons").map { URL(fileURLWithPath: $0) }
    }

    /// Installs icon and entry if they are missing or older.
    ///
    /// **Silent on failure.** A missing icon is a cosmetic flaw; stopping or
    /// complaining would be worse than the missing icon.
    static func setUp() {
        guard let source = bundled else { return }

        // **The menu entry is a Linux thing.** It exists because Wayland takes the
        // icon from the `.desktop` file, not from the window. Windows handles its
        // shortcuts differently, and a program that writes to the Start menu
        // unasked would be intrusive there; that belongs in the installer, not at
        // startup.
        #if os(Linux)
        let dm = FileManager.default
        let homeBase = URL(fileURLWithPath: NSHomeDirectory())
        let target = homeBase.appendingPathComponent(".local/share/icons/hicolor")

        for size in ["32x32", "64x64", "128x128", "256x256", "512x512"] {
            let from = source.appendingPathComponent("hicolor/\(size)/apps/\(identifier).png")
            let to = target.appendingPathComponent("\(size)/apps/\(identifier).png")
            guard dm.fileExists(atPath: from.path) else { continue }
            try? dm.createDirectory(at: to.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            if let new = try? Data(contentsOf: from),
               (try? Data(contentsOf: to)) != new {
                try? new.write(to: to)
            }
        }

        let entryRecord = """
        [Desktop Entry]
        Type=Application
        Name=Swiftly
        GenericName=for Jellyfin
        Comment=Jellyfin-Client, der niemals transkodiert
        Exec=\(realpath("/proc/self/exe"))
        Icon=\(identifier)
        StartupWMClass=\(identifier)
        Categories=AudioVideo;Video;Player;
        Terminal=false

        """
        let wo = homeBase.appendingPathComponent(".local/share/applications/\(identifier).desktop")
        try? dm.createDirectory(at: wo.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        if (try? String(contentsOf: wo, encoding: .utf8)) != entryRecord {
            try? entryRecord.write(to: wo, atomically: true, encoding: .utf8)
        }

        #endif

        // So GTK finds the image without restarting the session.
        // This applies on both platforms: the window icon comes from here.
        if let display = gdk_display_get_default() {
            gtk_icon_theme_add_search_path(gtk_icon_theme_get_for_display(display),
                                           source.path)
        }
    }

    private static func realpath(_ path: String) -> String {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? path
    }
}
