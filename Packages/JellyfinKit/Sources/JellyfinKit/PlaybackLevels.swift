import Foundation

/// The playback speeds the player offers.
///
/// Five numbers nobody takes for logic, which is why they stood three times,
/// once per platform. If one adds 0.5x, the others would not have it.
public enum SpeedLevels {

    public static let values: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    /// "1,25×" in German, "1.25×" in English.
    ///
    /// **Not `String(format: "%g", ...)` with the dot swapped.** The iPhone version
    /// did that and it hard-coded the comma: English showed "1,25×". The
    /// locale-aware output handles both and trims "1,0" to "1" as `%g` did.
    public static func label(_ value: Float) -> String {
        value.formatted(.number) + "×"
    }
}

/// The sleep timer steps, in minutes.
///
/// Same story as the speed steps: the same list three times.
public enum SleepTimes {
    public static let values = [15, 30, 45, 60, 90]
}

/// The running time in the player: "1:23" or "1:23:45".
///
/// Stood three times, once per platform, and was still identical: different
/// variable names, same result. The state `Titelangaben` once grew out of,
/// before one version forgot the hours.
///
/// Deliberately **not** locale-aware: colon and zeros are the same everywhere
/// for durations, unlike the decimal separator of the speed steps.
public enum PlayTime {
    public static func text(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let whole = Int(capped: seconds)
        let s = whole % 60, m = (whole / 60) % 60, h = whole / 3600
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}
