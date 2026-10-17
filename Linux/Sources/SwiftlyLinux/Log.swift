import Foundation
import JellyfinKit
#if os(Windows)
import WinSDK
#endif

/// **One log line, with wall-clock time and elapsed time.**
///
/// Every call site used to write its own format: ``Startstufe`` and
/// `TrackSupport.write` with a time, player lines with a bare `print` and none. A
/// tester's log therefore said *what* happened but, for half the lines, not
/// *when*, and when a fault shows up as waiting, the gap between two lines is
/// the whole answer.
///
/// **Why elapsed time as well.** The same log carried two clock times: the
/// launcher wrote 20:33, the app 18:33. On Windows, Foundation does not always
/// get the time zone and falls back to UTC. The clock time is therefore not a
/// common measure. Elapsed time since process start is: it comes from a clock
/// without a time zone, behaves the same on both platforms and answers the
/// question that matters, how many seconds passed between opening and the
/// first frame.
///
/// The clock time stays: it connects the log with what a viewer says ("around
/// half past eight").
///
/// **Never anything secret.** No URL with a token, no server name, no account
/// name; users may forward the file. Same rule as ``Startstufe``.
enum AppLog {

    /// Zero point of the elapsed time. Set on first access, which happens in
    /// `main.swift` before anything else.
    private static let start = ContinuousClock.now

    /// Seconds since process start, from a clock without a time zone.
    static var runtime: Double {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds)
             + Double(d.components.attoseconds) / 1e18
    }

    private static let clock: DateFormatter = {
        let u = DateFormatter()
        u.dateFormat = "HH:mm:ss.SSS"
        return u
    }()

    /// `20:33:42.406 +1.5s [Spieler] …`
    static func writeOut(_ text: String) {
        // **Decimal point, not comma.** Without a fixed locale Foundation formats
        // the elapsed time in the machine's language, and a log that says "6,3" in
        // one place and "6.3" in another cannot be parsed. `max(0, …)` catches the
        // negative zero of the very first line, which would print as "+-0.0s".
        print(String(format: "%@ +%.1fs %@", locale: Locale(identifier: "en_US_POSIX"),
                     clock.string(from: Date()), max(0, runtime), text))
        // Also into the ring for "Protokoll teilen": redacted on entry, in memory
        // only, as on the Apple versions.
        LogRing.shared.append(text)
        // Flush immediately: `print` into a redirected file is block-buffered.
        // Details in `main.swift`.
        fflush(nil)
    }

    /// **How long a section took on the main thread.**
    ///
    /// Only writes if it took long enough to notice: anything over 100 ms keeps
    /// GTK from drawing, and from about a quarter second a viewer calls the window
    /// frozen. Without these lines there is no telling which call it was.
    ///
    /// The measurement itself costs nothing and stays in every build.
    @discardableResult
    static func withClock<T>(_ was: String, _ block: () -> T) -> T {
        let begun = ContinuousClock.now
        let result = block()
        let d = ContinuousClock.now - begun
        let ms = Double(d.components.seconds) * 1000
              + Double(d.components.attoseconds) / 1e15
        if ms >= 100 {
            writeOut(String(format: "[Hauptfaden] %@ hat %.0f ms gebraucht", was, ms))
        }
        return result
    }

    /// **Once at startup: where the clock time comes from.**
    ///
    /// If this says `UTC` although the machine is elsewhere, the log's clock times
    /// are offset against the launcher's, and the elapsed time is the measure
    /// rather than the clock.
    ///
    /// **On Windows it asks the system itself** (`GetTimeZoneInformation`).
    /// Foundation fell back to GMT on a machine where it was 21:43 local time. If
    /// Foundation differs, the Windows offset applies to the whole app: this
    /// clock and every `DateFormatter` created afterwards.
    static func timeZoneReport() {
        #if os(Windows)
        if let w = windowsTimeZone() {
            if TimeZone.current.secondsFromGMT() != w.seconds,
               let fixed = TimeZone(secondsFromGMT: w.seconds) {
                NSTimeZone.default = fixed
                clock.timeZone = fixed
            }
            writeOut(String(format: "[Protokoll] Zeitzone %@, Versatz %+.1f h (Windows)",
                           locale: Locale(identifier: "en_US_POSIX"), w.name, Double(w.seconds) / 3600))
            return
        }
        #endif
        let z = TimeZone.current
        writeOut("[Protokoll] Zeitzone \(z.identifier), Versatz \(z.secondsFromGMT() / 3600) h")
    }

    #if os(Windows)
    /// Name and UTC offset as Windows currently has them, including daylight
    /// saving. `Bias` is UTC minus local time in minutes, i.e. the opposite sign of
    /// the offset. Constants as numbers, as in ``Wachhalter``: the macros with
    /// their cast do not import into Swift reliably.
    private static func windowsTimeZone() -> (name: String, seconds: Int)? {
        var info = TIME_ZONE_INFORMATION()
        let art = GetTimeZoneInformation(&info)
        guard art != 0xFFFF_FFFF else { return nil }     // TIME_ZONE_ID_INVALID
        let summer = art == 2                            // TIME_ZONE_ID_DAYLIGHT
        let bias = Int(info.Bias) + Int(summer ? info.DaylightBias : info.StandardBias)
        let name = withUnsafeBytes(of: summer ? info.DaylightName : info.StandardName) { raw in
            String(decoding: raw.bindMemory(to: UInt16.self).prefix { $0 != 0 }, as: UTF16.self)
        }
        return (name.isEmpty ? "?" : name, -bias * 60)
    }
    #endif
}

/// **"Protokoll teilen": the last hour as a text file.**
///
/// The same file as `LogFile.write()` in
/// `Sources/Shared/LogShare.swift`: version, system, state, then the
/// lines from ``Protokollring``. There is no share menu as on the Mac; the
/// file is shown in the file manager instead, from where it can be dragged
/// into a chat or mail.
enum LogFile {
    static func write() -> URL? {
        #if os(Windows)
        let system = "Windows"
        #else
        let system = "Linux"
        #endif
        var rows = [
            "\(Version.full) · libVLC \(VLCVersion.text)",
            "\(system) \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Stand \(ISO8601DateFormatter().string(from: Date()))",
            "",
        ]
        let excerpt = LogRing.shared.excerpt(seconds: 3600)
        rows += excerpt.isEmpty
            ? ["(no lines in the last hour — reproduce the problem first, then share without closing the app)"]
            : excerpt
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Swiftly-Protokoll.txt")
        do {
            try Data(rows.joined(separator: "\n").utf8).write(to: url, options: .atomic)
        } catch {
            AppLog.writeOut("[Protokoll] Datei liess sich nicht schreiben: \(error.localizedDescription)")
            return nil
        }
        return url
    }
}
