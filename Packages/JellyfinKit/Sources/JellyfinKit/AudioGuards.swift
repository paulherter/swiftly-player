import Foundation

/// When a route change may rebuild the audio output.
///
/// **The rule exists because its first version crashed the app.**
/// The first Bluetooth fix handled four route-change reasons. Two of them,
/// `categoryChange` and `routeConfigurationChange`, are not device changes at
/// all: they fire when the app **itself** sets up its audio session, i.e.
/// right at startup. On Apple TV this produced the following chain, seen in
/// the device log:
///
/// ```
/// [Ton] Routenwechsel (8) — Ausgang neu aufbauen
/// Paused · Position 0 s        paused in the middle of starting
/// Playing · Position 9 s       nine seconds later
/// picture is too late (missing 8366 ms)   × hundreds
/// ```
///
/// Two guards remain: only real device changes, and a grace period after
/// opening.
///
/// **The grace period is a guess, not a measurement.** Five seconds was a
/// plausible number, not a measured value, which is why it is documented here
/// and not as a bare number in a `guard`. Before changing it, measure: how long
/// does it take from opening to the last self-caused route notification?
/// Until someone does, it belongs here and not with the measured values.
public enum AudioWatch {

    /// Ignore route changes for this long after opening.
    ///
    /// **Unmeasured.** See above.
    public static let rampUpIdle: TimeInterval = 5

    /// Whether this route change should rebuild the output.
    ///
    /// - Parameters:
    ///   - echterGeraetewechsel: Whether the reason was `.newDeviceAvailable` or
    ///     `.override`, the only two where someone really changed the
    ///     destination. The caller decides this, because `AVAudioSession` is not
    ///     available in the package.
    ///   - spielt: Whether anything is playing at all. A paused player needs no
    ///     new output.
    ///   - sinceTakeover: How long the player has held the central controller.
    public static func outputNewBuildUp(realDeviceSwitch: Bool,
                                          playsNow: Bool,
                                          sinceTakeover: TimeInterval) -> Bool {
        guard realDeviceSwitch, playsNow else { return false }
        return sinceTakeover > rampUpIdle
    }
}
