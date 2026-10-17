import Foundation

/// When a frozen picture is a dropout, and when merely a sluggish stream.
///
/// **This rule once did exactly the opposite.** Measured on an HEVC episode that
/// "loaded" for minutes: the buffer rose to 52%, six seconds later the
/// emergency brake tore the stream down, rebuilding cost ten seconds plus a
/// new seek, and then the same began again. It did not fix the stall but made
/// it permanent.
///
/// Hence it lives here and no longer in ``VLCPlayer``: five thresholds that
/// together decide whether a stream is torn down. Four platforms use the same
/// ones, and a wrong one costs the viewer ten seconds of film. It is only
/// verifiable if it runs without a player.
///
/// **The numbers are measured, not chosen.** Changing one changes behavior; the
/// reason is next to each constant.
public enum StreamWatch {

    /// How long a network change counts as an explanation for a stall.
    ///
    /// After that it no longer does: a picture frozen two minutes after the change
    /// is frozen for another reason.
    public static let networkSwitchDeadline: TimeInterval = 90

    /// Stall before intervening, **after** a network change.
    ///
    /// Short, because the cause is then known and waiting achieves nothing.
    public static let standstillAfterSwitch: TimeInterval = 2

    /// Stall before intervening, otherwise.
    ///
    /// Three times as long: with no known cause it may be a sluggish server, and
    /// there patience beats a teardown.
    public static let standstillNormal: TimeInterval = 6

    /// Quiet period after every seek command.
    ///
    /// Measured: with a file whose index is unreadable the seek arrived by no path,
    /// the brake fired and tore the stream down while VLC was still reading
    /// forward. That once took a minute, when a seek could take arbitrarily long;
    /// since the mkv patch it takes milliseconds, and shorter is better: while the
    /// period runs, protection against real dropouts is suspended.
    public static let jumpIdle: TimeInterval = 20

    /// How fresh the last buffer growth must be for the guard to wait.
    ///
    /// **A stream that buffers is alive and must not be torn down.** The brake is
    /// for dropouts: dead spot, server outage. There nothing grows anymore.
    public static let bufferIdle: TimeInterval = 4

    /// What the guard advises.
    ///
    /// Five cases instead of a `Bool`, so the log can say **why** it waits. When
    /// hunting a stall that is the information that matters.
    public enum Rat: Sendable, Equatable {
        /// Has not stood long enough yet.
        case notYet
        /// A seek is in flight or was just commanded.
        case jumpRunning
        /// The buffer is growing, so the stream is alive.
        case bufferGrows
        /// Dropout. Rebuild the stream.
        case newConnect
    }

    /// - Parameters:
    ///   - stillstandSeit: How long the picture has been frozen.
    ///   - netzwechselVor: How long ago the last network change was, `nil` if
    ///     there was none.
    ///   - jumpOpen: Whether a seek is in flight.
    ///   - letzterSprungVor: How long ago the last seek command was.
    ///   - bufferGrewPre: How long ago the buffer last grew.
    public static func rat(standstillSince: TimeInterval,
                           networkChangeForward: TimeInterval?,
                           jumpOpen: Bool,
                           lastJumpForward: TimeInterval,
                           bufferGrewPre: TimeInterval) -> Rat {

        let freshValue = networkChangeForward.map { $0 < networkSwitchDeadline } ?? false
        let needed = freshValue ? standstillAfterSwitch : standstillNormal
        guard standstillSince >= needed else { return .notYet }

        if jumpOpen || lastJumpForward < jumpIdle { return .jumpRunning }
        if bufferGrewPre < bufferIdle { return .bufferGrows }
        return .newConnect
    }

    // MARK: Frame flow

    /// Are the frames frozen while the clock runs?
    ///
    /// `nil`: nothing to say, either no previous value or this media has never
    /// shown a frame. Without this second guard a title with no video track (or
    /// one VLC does not decode) counted as a dead stream and the player rebuilt it
    /// every few seconds.
    public static func imagesState(before: UInt64?, now: UInt64) -> Bool? {
        guard let before, before > 0 else { return nil }
        return now == before
    }

    /// New bytes since the last look. A new media counts from zero; the raw
    /// difference went below zero and Swift traps on that.
    public static func growth(_ now: UInt64, since before: UInt64) -> UInt64 {
        now >= before ? now - before : 0
    }
}
