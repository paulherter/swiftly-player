import Foundation

/// When VLC's time value may be believed, and when not.
///
/// This sounds minor and is why a resumed title visibly started at the
/// beginning before jumping to the right spot. The start seek goes along as a
/// media option, but VLC needs a few ticks for it, and meanwhile reports values
/// that belong to the **unseeked** stream: first zero, then the old time.
/// Taking those unchecked shows exactly that.
///
/// The rules come from the iPhone version, where they were worked out. They
/// live here so both platforms use the same ones.
public enum TimeAssumption {

    /// How close the player must be to the target for the seek to count as
    /// arrived.
    ///
    /// Two seconds: tighter would be too strict for a stream that can only seek to
    /// keyframes, where you regularly land a second off and the display would never
    /// leave the target. How long it may stay there at most is set by
    /// ``Wiedergabetakt/sprungdeckel``.
    public static let jumpArrived: Double = 2


    /// How long after opening a backward jump counts as setup flicker.
    public static let freshWindow: TimeInterval = 8
    /// From when the loading screen goes away in any case.
    public static let emergencyBrake: TimeInterval = 12

    /// The same emergency brake, while VLC is still homing in on the start position.
    ///
    /// Twelve seconds was too short. `VLCPlayerView` homes in on the start position
    /// after the first frame and gives up only after **twenty** seconds; for large
    /// files that takes longer than twelve. The loading screen then left in the
    /// middle of homing in, and the film visibly started at second zero until the
    /// seek landed, exactly the bug this file is meant to prevent. Movies on TV
    /// were affected; episodes are smaller and finished in time.
    ///
    /// Deliberately **behind** VLC's own give-up deadline so it does not interfere
    /// midway.
    public static let settleDeadline: TimeInterval = 25

    /// Whether the video output belongs to the **current** media.
    ///
    /// When the player switches episodes without tearing down the surface, VLC
    /// keeps the video output (`hasVideoOut`) and the clock of the old episode
    /// until the new one has its first frame. The tick took that as "picture
    /// showing", adopted the old time (75 s instead of 0) and reported it for the
    /// new episode; until `freshWindow` ran out, the real time counted as a
    /// backward jump and was discarded. Observed: `Progress 76 s` six seconds after
    /// the switch, then `14 s`.
    ///
    /// The frame count belongs to the media, not the player; a new media starts at
    public static func imageBelongsMedium(videoOutput: Bool, shownImages: UInt64,
                                            afterChange: Bool) -> Bool {
        videoOutput && (!afterChange || shownImages > 0)
    }

    /// Whether the loading screen may go away.
    ///
    /// `showsImage` alone is not enough: while VLC is still settling, the picture
    /// belongs to the old state. The emergency brake is still needed, since the
    /// loading screen must never stay up permanently even if something underneath
    /// is stuck. That happened once: audio played, picture stayed covered.
    public static func imagePresent(showsImage: Bool, seeksToStart: Bool, sinceStart: Date) -> Bool {
        let since = Date().timeIntervalSince(sinceStart)
        // While homing in, the longer deadline applies; otherwise the emergency brake
        // defeats exactly what it is meant to protect.
        if seeksToStart { return since > settleDeadline }
        if since > emergencyBrake { return true }
        return showsImage
    }

    /// Which time the display adopts, or `nil` if none.
    ///
    /// Three guards:
    ///
    /// 1. **Nothing under half a second.** On opening and right after the start
    ///    seek, VLC still reports zero for a tick or two.
    /// 2. **No jump back shortly after opening.** If the time jumps back by more
    ///    than thirty seconds while the title is freshly open, that is the
    ///    unseeked stream and not the viewer.
    /// 3. **After an episode switch, nothing that cannot have been played yet.**
    ///    The new episode starts at zero; more than the elapsed time plus
    ///    `switchPlaySpace` is VLC's clock from the transition. Observed: first
    ///    the old position (76 s), then with the first frame of the new episode
    ///    6130 s; both went to the server as progress and "Next episode" flashed.
    ///    Because guard 2 discarded the real time afterwards as a jump back, the
    ///    display was eight seconds off. Applies until the first adopted time (the
    ///    tick then clears `afterChange`), at most `settleDeadline` long, since a
    ///    slow start takes longer than the freshness window.
    public static func position(reported: Double, untilFrom: Double, sinceStart: Date,
                                afterChange: Bool = false) -> Double? {
        guard reported > 0.5 else { return nil }
        let since = Date().timeIntervalSince(sinceStart)
        let freshOpened = since < freshWindow
        if afterChange, since < settleDeadline, reported > since + switchPlaySpace { return nil }
        let backward = reported < untilFrom - 30
        guard !(backward && freshOpened) else { return nil }
        return reported
    }

    /// How far ahead of the wall clock the new episode's clock may be: buffer
    /// already read before `sinceStart`, and tick offset.
    public static let switchPlaySpace: TimeInterval = 5

    // MARK: The engine rebuilt its clock

    /// **The engine's clock no longer matches the film: how far behind it now is.**
    ///
    /// VLC 4 rebuilds its clock context around the paused start — deferred pause,
    /// seek, resume — and afterwards reports `0 + elapsed` while the picture stands at
    /// the resume point. Measured on an iPhone with VLCKit 4.0.0-a23, resume at 570 s:
    /// `[Melden] Start 570 s`, ten seconds later `[Melden] Progress 10 s`. The bar falls
    /// to zero and the server is told a position near zero, so "continue watching"
    /// loses the place, while the picture is where it should be.
    ///
    /// Such a jump back is never the viewer: every seek goes through the player's own
    /// seek paths and records when it was commanded. So the clock is what is broken,
    /// and the film keeps its position by carrying the difference.
    ///
    /// - Parameters:
    ///   - lastGood: the last position at which the picture demonstrably ran.
    ///   - reported: what the engine says now (film position, offset included).
    ///   - quietSinceLastGood: no seek was commanded since that reading. A drop that
    ///     follows a commanded seek is that seek (failed, slow, or still on its way),
    ///     not a rebuild — and treating it as one made skipping impossible.
    ///   - jumpPending: a supplied seek the engine has not confirmed yet.
    /// - Returns: what to add to the engine's clock, or `nil` for "nothing changed".
    public static func clockOffset(lastGood: Double, reported: Double,
                                   quietSinceLastGood: Bool,
                                   jumpPending: Bool) -> Double? {
        guard !jumpPending, quietSinceLastGood else { return nil }
        // Early in a film the difference is not yet meaningful; the start itself
        // moves the clock by more than `rebuildGap` without anything being broken.
        guard lastGood > rebuildNotBefore else { return nil }
        guard reported > 0, lastGood - reported > rebuildGap else { return nil }
        return lastGood - reported
    }

    /// A drop larger than this cannot be a seek the app commanded.
    public static let rebuildGap: Double = 30
    /// Below this position a rebuild cannot be told from the start of a film.
    public static let rebuildNotBefore: Double = 60
}
