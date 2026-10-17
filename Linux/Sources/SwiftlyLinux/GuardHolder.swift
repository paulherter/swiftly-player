import CGtk
import Foundation
#if os(Windows)
import WinSDK
#endif

/// **The screen stays on during playback.**
///
/// The screen saver is inhibited while libVLC is running; it is released on
/// pause and when the player closes, as on the Apple versions
/// (`isIdleTimerDisabled` and the Mac's power assertion).
///
/// Linux uses `gtk_application_inhibit` (idle), Windows
/// `SetThreadExecutionState`, which is per thread, so call it from the main
/// thread only; the playing-state event already arrives there.
enum GuardHolder {
    #if os(Windows)
    nonisolated(unsafe) private static var active = false
    #else
    nonisolated(unsafe) private static var mark: guint = 0
    /// Which application inhibited: release with the same one, even when the end
    /// comes from VLC's event and no window is known.
    nonisolated(unsafe) private static var hostApp: UnsafeMutablePointer<GtkApplication>?
    #endif

    /// Stopped, ended or aborted with an error: no `Paused` follows, and without
    /// this the inhibition would stay until the player is closed.
    static func share() { setDown(false, window: nil) }

    static func setDown(_ awake: Bool, window: Widget!) {
        #if os(Windows)
        guard awake != active else { return }
        active = awake
        // ES_CONTINUOUS 0x80000000, ES_DISPLAY_REQUIRED 0x2,
        // ES_SYSTEM_REQUIRED 0x1, as numbers because the macros with their
        // `((DWORD)…)` cast do not import into Swift reliably.
        let traits: EXECUTION_STATE = awake ? 0x8000_0003 : 0x8000_0000
        _ = SetThreadExecutionState(traits)
        AppLog.writeOut("[Wach] \(awake ? "gehemmt" : "freigegeben")")
        #else
        if awake {
            guard mark == 0, let window,
                  let new = gtk_window_get_application(asWindow(window)) else { return }
            // **Suspend too, not just the screen saver.** Windows also sets
            // `ES_SYSTEM_REQUIRED`; `IDLE` alone only kept the screen on, and a power
            // setting like "suspend after 20 min" put the machine to sleep mid-movie
            // when the desktop environment handles idle and sleep separately (KDE does).
            let was = GtkApplicationInhibitFlags(
                rawValue: GTK_APPLICATION_INHIBIT_IDLE.rawValue | GTK_APPLICATION_INHIBIT_SUSPEND.rawValue)
            mark = gtk_application_inhibit(new, asWindow(window), was, translated("Wiedergabe"))
            hostApp = new
            AppLog.writeOut("[Wach] gehemmt (\(mark))")
        } else {
            guard mark != 0, let hostApp else { return }
            gtk_application_uninhibit(hostApp, mark)
            AppLog.writeOut("[Wach] freigegeben (\(mark))")
            mark = 0
        }
        #endif
    }
}
