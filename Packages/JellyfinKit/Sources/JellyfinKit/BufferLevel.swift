import Foundation

/// **How much buffer the player holds before the picture appears.**
///
/// Prompted by a user who has an unreliable connection and wants a video cache
/// of 30 s. The case is real, but the number does not transfer: **the buffer is
/// held in bytes, not seconds.** The same 16 MiB is roughly twenty-five seconds
/// for a 5 Mbit series and barely two for an 80 Mbit film. Setting "30
/// seconds" would give something completely different per title.
///
/// Hence three levels instead of a number. They say what you pick them *for*,
/// not what happens internally.
///
/// **Every level costs something.** A bigger buffer means longer startup and
/// longer waits after every seek, because it has to be refilled. That is why
/// `normal` is the default and not the most generous level: `network-caching`
/// of 10000 was tried and removed because the buffer was not the problem. 211
/// seconds were buffered; the bottleneck sat behind the demuxer.
public enum BufferLevel: String, CaseIterable, Sendable, Codable, Identifiable {

    /// **Identity for pickers.**
    ///
    /// Added because it was missing: two platforms each built the same wrapper just
    /// to attach an identifier. Two identical detours in two places mean the path
    /// is missing.
    public var id: String { rawValue }


    /// As before. Fast seeks, buffer from the prefetch filter.
    case normal

    /// For a connection that occasionally drops.
    case bad = "schlecht"

    /// For a connection that is sometimes gone entirely.
    case veryBad = "sehrSchlecht"

    /// How much the prefetch filter holds, in KiB (VLC's own unit).
    ///
    /// 16 MiB is the measured current value; the higher levels multiply it by four
    /// and twelve. More than 192 MiB would be rude on a phone: the memory is shared.
    public var prefetchKiB: Int {
        switch self {
        case .normal:       16_384
        case .bad:     65_536
        case .veryBad: 196_608
        }
    }

    /// VLC's time-ahead in milliseconds, or `nil` for "leave alone".
    ///
    /// **Deliberately `nil` for `normal`, not 1000.** Setting VLC's default again
    /// explicitly looks intentional but changes nothing, and whoever searches for
    /// it later takes it for a deliberate decision.
    public var networkLeadMilliseconds: Int? {
        switch self {
        case .normal:       nil
        case .bad:     15_000
        case .veryBad: 45_000
        }
    }

    /// Rough guide for the UI: about how many seconds this is at the given bitrate.
    ///
    /// **Approximate, and it says so.** The bitrate varies considerably within a
    /// film; a figure accurate to the second would be a lie.
    public func approxSeconds(bitsPerSecond: Int) -> Int? {
        guard bitsPerSecond > 0 else { return nil }
        let bytes = Double(prefetchKiB) * 1024
        return Int((bytes * 8 / Double(bitsPerSecond)).rounded())
    }

    /// The level's name in settings.
    ///
    /// **Lives here, not in a view.** The naming first sat in a view file that only
    /// one platform translates, but the other platforms would have needed the same
    /// three sentences again, exactly the kind of copy where versions drift apart.
    ///
    /// The names describe the situation, not the value: "64 MiB" answers no
    /// question anyone asks, "Poor connection" does.
    public var name: String {
        switch self {
        case .normal:       translated("Normal")
        case .bad:     translated("Schlechte Verbindung")
        case .veryBad: translated("Sehr schlechte Verbindung")
        }
    }
}
