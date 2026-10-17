import Foundation

/// **VLC's counters, computed without VLC.**
///
/// The tech badge numbers come from the difference of two measurements and the time between
/// them. This calculation lives in the package because every platform needs it; a copied
/// function is a bug. Where the raw values come from (`VLCMedia` on Apple,
/// `libvlc_media_get_stats` on Linux) is up to the platform; both deliver the same fields.
public struct Counter: Sendable, Equatable {

    /// The raw values of one measurement as VLC keeps them: totals since playback began,
    /// not per second.
    public struct RawValues: Sendable, Equatable {
        public var hasRead: UInt64
        public var unpacked: UInt64
        public var shown: UInt64
        public var discarded: UInt64
        public var tooLate: UInt64
        public var videoBlocks: UInt64
        public var audioBlocks: UInt64
        public var audioPlay: UInt64
        public var audioLost: UInt64
        public var beschaedigt: UInt64
        public var jumps: UInt64

        public init(hasRead: UInt64 = 0, unpacked: UInt64 = 0, shown: UInt64 = 0,
                    discarded: UInt64 = 0, tooLate: UInt64 = 0, videoBlocks: UInt64 = 0,
                    audioBlocks: UInt64 = 0, audioPlay: UInt64 = 0, audioLost: UInt64 = 0,
                    beschaedigt: UInt64 = 0, jumps: UInt64 = 0) {
            self.hasRead = hasRead; self.unpacked = unpacked; self.shown = shown
            self.discarded = discarded; self.tooLate = tooLate
            self.videoBlocks = videoBlocks; self.audioBlocks = audioBlocks
            self.audioPlay = audioPlay; self.audioLost = audioLost
            self.beschaedigt = beschaedigt; self.jumps = jumps
        }
    }

    // MARK: Passed through

    public let raw: RawValues
    /// When this measurement was taken; the next one derives the duration from it.
    /// **Measured, not assumed:** a wait lasts *at least* the requested time, not exactly
    /// it. With an assumed duration a 23.976 fps file showed "30.0 fps" because the real
    /// gap was two and a half seconds.
    public let measuredAt: Date
    /// The position in the movie, in seconds.
    public let spot: Double

    // MARK: Computed

    /// Bits per second at the input, or `nil` the first time: there is no previous value,
    /// and a zero would be a claim we cannot make.
    public let input: Double?
    public let demuxer: Double?
    /// Displayed frames per second over the long window.
    public let showsProSecond: Double?
    /// Decoded frames per second; separates decoder from output.
    public let decodedProSecond: Double?
    /// How fast the position advances against the real clock. 1 is real time; below that is
    /// lost time, which shows as stutter.
    public let runShare: Double?
    /// How much has been read but not yet unpacked: the buffer in bytes.
    public var preAdviceBytes: UInt64 { raw.hasRead >= raw.unpacked ? raw.hasRead - raw.unpacked : 0 }

    // MARK: Window

    let baseShown: UInt64
    let baseDecoded: UInt64
    let basePoint: Double
    let baseTime: Date

    /// **Twenty seconds.**
    ///
    /// A short window is noisy: VLC does not update `shown` frame by frame but in bursts.
    /// A two-second window catches two bursts or none, so the number is random. Twenty
    /// seconds are about five hundred frames; one burst more or less does not matter.
    public static let window: TimeInterval = 20
    /// Nothing is reported before then; see `window`.
    public static let atLeast: TimeInterval = 4

    /// **If VLC never filled the structure, it contains garbage.** A billion frames at 60
    /// Hz would be over half a year; anything above that is not a measurement.
    static let limit: UInt64 = 1_000_000_000

    public init?(_ raw: RawValues, spot: Double, running: Bool,
                 before: Counter? = nil, now: Date = Date()) {
        guard raw.shown < Self.limit, raw.discarded < Self.limit,
              raw.tooLate < Self.limit, raw.videoBlocks < Self.limit,
              raw.audioBlocks < Self.limit, raw.audioLost < Self.limit,
              raw.beschaedigt < Self.limit, raw.jumps < Self.limit,
              raw.audioPlay < Self.limit
        else { return nil }

        self.raw = raw
        self.spot = spot
        self.measuredAt = now
        let seconds = before.map { now.timeIntervalSince($0.measuredAt) } ?? 0

        // **A seek invalidates the window**, and the ramp-up does not count. The counters
        // keep running while seeking but the position jumps, and while not playing the
        // waiting time would count as standstill in `runShare`.
        let continuesRunning = running && (before.map {
            spot >= $0.spot && spot - $0.spot <= seconds * 2 + 1
        } ?? false)

        if let v = before, continuesRunning, raw.shown >= v.baseShown,
           now.timeIntervalSince(v.baseTime) < Self.window {
            baseShown = v.baseShown; baseDecoded = v.baseDecoded
            basePoint = v.basePoint;   baseTime = v.baseTime
        } else if let v = before, continuesRunning, raw.shown >= v.raw.shown {
            baseShown = v.raw.shown;  baseDecoded = v.raw.videoBlocks
            basePoint = v.spot;        baseTime = v.measuredAt
        } else {
            baseShown = raw.shown;    baseDecoded = raw.videoBlocks
            basePoint = spot;          baseTime = now
        }

        let extentSpan = now.timeIntervalSince(baseTime)
        let reif = extentSpan >= Self.atLeast
        showsProSecond = reif && raw.shown >= baseShown
            ? Double(raw.shown - baseShown) / extentSpan : nil
        decodedProSecond = reif && raw.videoBlocks >= baseDecoded
            ? Double(raw.videoBlocks - baseDecoded) / extentSpan : nil
        runShare = reif && spot >= basePoint
            ? (spot - basePoint) / extentSpan : nil

        input = Self.rate(raw.hasRead, before?.raw.hasRead, seconds)
        demuxer = Self.rate(raw.unpacked, before?.raw.unpacked, seconds)
    }

    /// **The rate is computed, not read.** VLC's own floating-point fields were both **0**
    /// on Apple TV during playback. What reliably increases are the totals.
    static func rate(_ now: UInt64, _ before: UInt64?, _ seconds: Double) -> Double? {
        guard let before, seconds > 0, now >= before else { return nil }
        let bit = Double(now - before) * 8 / seconds
        return bit > 0 ? bit : nil
    }

    /// The buffer in seconds, if the file's bitrate demand is known. **Read minus
    /// unpacked** is the fill level, the number other clients show as "buffer".
    public func reserveSeconds(bytesJeSecond: Double) -> Double? {
        guard bytesJeSecond > 0 else { return nil }
        return Double(preAdviceBytes) / bytesJeSecond
    }
}
