import Foundation

/// **How far startup has got: one log line per stage.**
///
/// On Windows the launcher (`Windows/Launcher`) reads these lines: it
/// redirects the app's stdout to `%APPDATA%\Swiftly\swiftly.log` and shows the
/// latest stage in the loading window. The name after `[Level]` is therefore an
/// interface; renaming one means renaming it in the launcher's `levels` table.
/// An unknown stage is shown raw; nothing breaks.
///
/// On Linux the line only goes into the existing log written by the start
/// script. No window, no second path.
///
/// **Never put anything secret in a stage.** No address, no name, no token; a
/// user may forward this file.
enum StartLevel {
    static func report(_ name: String) {
        let u = DateFormatter()
        u.dateFormat = "HH:mm:ss.SSS"
        print("\(u.string(from: Date())) [Stufe] \(name)")
        // Flush immediately: `print` to a file is block-buffered, and the launcher
        // should see the stage when it is reached, not when the buffer fills. See
        // `TrackSupport.write` in main.swift.
        fflush(nil)
    }
}
