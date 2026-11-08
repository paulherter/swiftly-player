import CGtk
import Foundation
import JellyfinKit

/// **How text subtitles look**, same values as on Apple: Inter SemiBold, the size steps
/// multiply ``baseScale`` (only the preview uses it; the player gets the step as `sub-scale`).
/// Colour, outline, shadow, background and position come from the profile's ``SubtitleLook``
/// (page "Untertitel"), turned into mpv options by ``mpvOptions(look:outputHeight:)`` in
/// `Player.swift`.
///
/// **mpv (libass) must find the font itself.** It queries fontconfig with its own
/// configuration (`FcInitLoadConfigAndFonts`), which `fonts_load` from
/// `Style.swift` does not see, so bundled fonts are not available to it. A small
/// configuration therefore includes the system's and adds our folder, via
/// `FONTCONFIG_FILE`. If the variable is already set, it is kept.
///
/// **On Windows** the player finds fonts via GDI and the registry, not fontconfig, so a
/// bundled file is unreachable. Segoe UI Semibold ships with every Windows and is
/// the closest relative.
enum SubtitleStyle {
    /// Reference size for the preview and the size steps (as on Apple) 
    static let baseScale = 0.78

    /// **The height of the first screen in pixels, 1080 if unknown.** the raised margin is computed in pixels of the output, which is not known when the core is
    /// created; the screen is the best stand-in (a title is rarely sharper than the
    /// screen it plays on).
    static func outputHeight() -> Int {
        guard let display = gdk_display_get_default(),
              let list = gdk_display_get_monitors(display),
              g_list_model_get_n_items(list) > 0,
              let raw = g_list_model_get_item(list, 0) else { return 1080 }
        var area = GdkRectangle()
        gdk_monitor_get_geometry(OpaquePointer(raw), &area)
        let scale = Int(max(gdk_monitor_get_scale_factor(OpaquePointer(raw)), 1))
        g_object_unref(raw)
        let height = Int(area.height) * scale
        return height >= 480 ? height : 1080
    }

    #if !os(Windows)
    /// **Asked once.** ``fontBundled()`` sets `FONTCONFIG_FILE`, and a second call finds it set and
    /// answers no; a new core (changed look) would then fall back to "Sans".
    private static let interAvailable = fontBundled()
    #endif

    /// The face the player is given, and the page's preview draws with the same one.
    static var fontFamily: String {
        #if os(Windows)
        return "Segoe UI Semibold"
        #else
        return interAvailable ? "Inter 18pt SemiBold" : "Sans"
        #endif
    }

    #if !os(Windows)
    private static func fontBundled() -> Bool {
        let dm = FileManager.default
        guard let folder = Platform.bundled("Fonts"),
              dm.fileExists(atPath: folder + "/Inter-SemiBold.ttf") else { return false }
        if ProcessInfo.processInfo.environment["FONTCONFIG_FILE"] != nil { return false }
        let system = "/etc/fonts/fonts.conf"
        guard dm.fileExists(atPath: system) else { return false }
        let between = URL(fileURLWithPath: String(cString: g_get_user_cache_dir()))
            .appendingPathComponent("swiftly")
        let file = between.appendingPathComponent("untertitel-fonts.conf")
        let content = """
            <?xml version="1.0"?>
            <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
            <fontconfig>
              <include ignore_missing="yes">\(system)</include>
              <dir>\(folder)</dir>
            </fontconfig>
            """
        do {
            try dm.createDirectory(at: between, withIntermediateDirectories: true)
            try content.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            AppLog.writeOut("[Untertitel] fontconfig-Datei nicht geschrieben: \(error)")
            return false
        }
        file.path.withCString { _ = g_setenv("FONTCONFIG_FILE", $0, 1) }
        return true
    }
    #endif
}
