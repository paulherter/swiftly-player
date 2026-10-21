import CGtk
import Foundation
import JellyfinKit
#if os(Windows)
import WinSDK
#endif

/// Entry point. Everything else is in ``App``.
///
/// **The app lives in a global reference** because GTK callbacks come from C
/// and cannot capture anything. It is created once at startup and kept until
/// the end.
// **Pango should take the same path on Windows as on Linux.**
//
// PangoCairo has two backends there: Win32 and fontconfig. Without a setting
// it picks Win32, which knows neither the bundled font nor the same glyph
// alignment as Linux and the Mac. Measured: with the default, the UI stayed on
// Segoe UI although Inter was present and registered correctly.
//
// Must come before everything else: the font map is created at the first text,
// and the choice cannot be changed afterwards. The 0 means "do not overwrite",
// so an explicit setting by the user is kept.
#if os(Windows)
_ = g_setenv("PANGOCAIRO_BACKEND", "fc", 0)
#endif

// **The first line that counts.** Up to here Windows has loaded all DLLs (and
// had Defender check them on first start). The gap between "[Start] App
// gestartet" and this line in the log is exactly that check.
StartLevel.report("programm")
// **Where the timestamp comes from.** If this shows UTC although the machine
// is elsewhere, the times are shifted against the launcher's, and the runtime
// is the measure. See ``AppLog``.
AppLog.timeZoneReport()
// Which language the UI uses and why; otherwise a report like "English on a
// German Windows" cannot be resolved.
AppLog.writeOut("[Sprache] Wuensche \(upperAreasCatalog.requests.joined(separator: ", ")), "
    + "vorhanden \(upperAreasCatalog.availableLanguages.joined(separator: ", ")), "
    + "gewaehlt \(upperAreasCatalog.language)")

// **The package gets its output channel**, as on the Apple versions. The
// control channel and the session query in the package otherwise fail
// silently. `print` is enough here: the start script redirects the output to
// `swiftly-linux.log` anyway.
TrackSupport.write = { text in
    // **With a timestamp.** Without it the log shows *what* happened but not
    // *when*, and for a connection that goes up and down the interval is the
    // information. Twenty "connection lost" lines in a row are useless if you
    // cannot tell whether they span a minute or an hour.
    let u = DateFormatter()
    u.dateFormat = "HH:mm:ss"
    print("\(u.string(from: Date())) [Paket] \(text)")
    LogRing.shared.append("[Paket] \(text)")
    // **And write out immediately.**
    //
    // `print` into a **redirected** file is block-buffered, not line-buffered. On a
    // terminal this never shows; in a log file it does. While a diagnostic ran
    // every second the buffer filled quickly and everything appeared; once it got
    // quiet, **nothing** arrived, and it looked as if the function was not running.
    // It was running the whole time.
    //
    // This also explains half-written lines like `[Paket] [Dis` mid-sentence: a
    // buffer flushed between two writers.
    // `fflush(nil)` rather than `fflush(stdout)`: `stdout` is a mutable global
    // variable, and Swift 6 rejects it in a concurrent context ("not
    // concurrency-safe because it involves shared mutable state"). `nil` flushes
    // all open streams and avoids the name.
    fflush(nil)
}
// The forwarder in front of libVLC (issue #4) logs to the same log.
StreamForwarder.log = { TrackSupport.write?($0) }

nonisolated(unsafe) let app = App()

nonisolated(unsafe) private let start: @convention(c) (UnsafeMutableRawPointer?, gpointer?) -> Void = { hostApp, _ in
    StartLevel.report("oberflaeche")
    // Before the style sheet and before the first measurement: both ask for the
    // scale factor.
    Scaling.setUp(user: app.selection.surface)
    // The look first: the first frame is already in its colors.
    Theme.wear(app.looks.palette)
    Theme.apply()
    app.buildUp(hostApp: hostApp!.assumingMemoryBound(to: GtkApplication.self))
    app.headerRowSetUp()
    // Debug builds only: a file tells the app where to go, so a session can look
    // before reporting anything.
    RemoteConsole.eavesdrop(app)
}

// **Without a session bus there is no single instance.**
//
// `GApplication` registers on D-Bus at startup; that is where the behavior
// comes from that a second copy brings the first to the front instead of
// opening a second window. Windows has no such bus: registration fails and
// `g_application_run` returns **without ever building the window**. Measured
// on first start: the app was gone after a tenth of a second, with only a
// warning about the missing bus.
//
// The cost is that the app can be started twice on Windows, which is also the
// usual behavior there.
//
// `G_APPLICATION_NON_UNIQUE` does not reach Swift by name: the enumeration was
// renamed in glib 2.74 and the old names are only macros. 32 is the value it
// has always carried (the sixth bit).
#if os(Windows)
let traits = GApplicationFlags(rawValue: 32)
// **The installer must see that Swiftly is running.** `Swiftly.iss` names the
// same names under `AppMutex`; if one exists, setup warns instead of failing on
// a locked EXE. Once per session and once global, as Inno Setup recommends, so
// an installer from another login also sees the running app. The handles stay
// open until the process ends; Windows then cleans them up. If the global one
// fails, the local one suffices.
nonisolated(unsafe) let runMarks: [HANDLE?] = ["SwiftlyPlayer", "Global\\SwiftlyPlayer"].map {
    $0.withCString(encodedAs: UTF16.self) { CreateMutexW(nil, false, $0) }
}
#else
let traits = GApplicationFlags(rawValue: 0)
#endif

// **First remove whatever an older version still runs or leaves behind**
// (`OldRun.swift`); otherwise the second copy brings the first to the front,
// and after an update that is the old one.
#if os(Linux)
OldRun.cleanUp()
#endif

let hostApp = gtk_application_new("de.paulherter.swiftly", traits)
g_signal_connect_data(UnsafeMutableRawPointer(hostApp), "activate",
                      unsafeBitCast(start, to: GCallback.self),
                      nil, nil, GConnectFlags(rawValue: 0))

let result = g_application_run(
    unsafeBitCast(hostApp, to: UnsafeMutablePointer<GApplication>.self), 0, nil)
exit(result)
