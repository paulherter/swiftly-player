import Foundation

/// **Subtitle or audio delay in the player**: one rule for all platforms.
///
/// When subtitles or audio drift from the picture, they are shifted in 50 ms
/// steps until they line up. Positive means later: the subtitle appears later,
/// the audio arrives later. VLC 4 (`currentVideoSubTitleDelay`,
/// `currentAudioPlaybackDelay`) and libVLC 3 (`setSpuDelay`, `setAudioDelay`)
/// count it the same way, both in microseconds.
///
/// **The value belongs to playback, not to a setting.** A shifted track is a
/// defect of that one file; the next episode of the same series usually comes
/// from the same source and keeps it (`forNewTitle`), anything else starts
/// at zero.
///
/// **VLC forgets it for every new media.** Measured with VLCKit 4.0.0a23 on the
/// Mac: set before `play`, VLC reads 0 afterwards, and also 0 after a media
/// change; set into the running media it stays (±10 s read back as set). The
/// platform therefore re-applies it whenever VLC reports something other than
/// intended (`softOff`).
public struct Delay: Equatable, Hashable, Sendable {

    /// One press of − or +.
    public static let step = 50
    /// No track is off by more than ten seconds if you still wanted to shift it;
    /// beyond that it is the wrong track.
    public static let limit = 10_000
    public static let null = Delay(milliseconds: 0)

    /// Always a multiple of `step`, always within ±`limit`.
    public let milliseconds: Int

    public init(milliseconds: Int) {
        let limited = min(max(milliseconds, -Self.limit), Self.limit)
        // To the nearest step, halves away from zero, so a value VLC reads back as
        // 199 999 µs becomes 200 ms again.
        let steps = (Double(limited) / Double(Self.step)).rounded(.toNearestOrAwayFromZero)
        self.milliseconds = Int(steps) * Self.step
    }

    /// From VLC's microseconds.
    public init(microseconds: Int) {
        self.init(milliseconds: Int((Double(microseconds) / 1000).rounded()))
    }

    /// For VLC.
    public var microseconds: Int { milliseconds * 1000 }

    public var isNull: Bool { milliseconds == 0 }
    public var atStart: Bool { milliseconds <= -Self.limit }
    public var atEnd: Bool { milliseconds >= Self.limit }

    /// Earlier (−1) or later (+1), by `schritte` steps.
    public func shifted(_ bearing: Int, steps: Int = 1) -> Delay {
        Delay(milliseconds: milliseconds + bearing.signum() * max(steps, 1) * Self.step)
    }

    // MARK: Holding the button

    /// **Holding speeds up.** The first ten repeats are one step each, then two,
    /// from the thirtieth five. From zero to ten seconds takes a few seconds of
    /// holding instead of twenty, and someone who wants only a little lets go
    /// earlier.
    public static func steps(onRepetition n: Int) -> Int {
        switch n {
        case ..<10: return 1
        case ..<30: return 2
        default: return 5
        }
    }

    /// Counts the repeats of a held button.
    ///
    /// The buttons repeat through the system (`buttonRepeatBehavior` on Apple, key
    /// repeat elsewhere), which delivers presses but no count. A press that follows
    /// the previous one closely belongs to the same series; after a pause the
    /// series starts over.
    public struct HoldCounter: Sendable {
        /// Longer than the system's repeat pause, shorter than a deliberate second tap.
        public static let railsGap: TimeInterval = 0.3
        private var lastOne: Date?
        private var rail = 0

        public init() {}

        /// How many steps this press counts for.
        public mutating func press(now: Date = Date()) -> Int {
            if let lastOne, now.timeIntervalSince(lastOne) < Self.railsGap {
                rail += 1
            } else {
                rail = 0
            }
            lastOne = now
            return Delay.steps(onRepetition: rail)
        }
    }

    // MARK: Display

    /// "+0.20 s", "−1.50 s", "0.00 s": decimal separator per `locale`, the minus as
    /// a real minus sign, two decimals because a step is 0.05.
    public func text(locale: Locale = .current) -> String {
        let magnitude = abs(milliseconds)
        let comma = locale.decimalSeparator ?? "."
        let hundredths = (magnitude % 1000) / 10
        let figure = "\(magnitude / 1000)\(comma)\(hundredths < 10 ? "0" : "")\(hundredths)"
        let preCharacter = milliseconds > 0 ? "+" : (milliseconds < 0 ? "\u{2212}" : "")
        return "\(preCharacter)\(figure) s"
    }

    // MARK: Keeping

    /// **What applies when switching to another title.** The same title (reloaded,
    /// e.g. with another quality) and the same series keep the value; anything
    /// else, a movie or another series, starts at zero.
    public static func forNewTitle(_ untilFrom: Delay,
                                      oldTitle: String, oldSeries: String?,
                                      newTitle: String, addedSeries: String?) -> Delay {
        if oldTitle == newTitle { return untilFrom }
        guard let oldSeries, let addedSeries, oldSeries == addedSeries else { return .null }
        return untilFrom
    }

    /// Does VLC report a different value than intended? Then re-apply. Under one
    /// millisecond is rounding, not a deviation.
    public func softOff(fromMicroseconds hasRead: Int) -> Bool {
        abs(hasRead - microseconds) >= 1000
    }
}
