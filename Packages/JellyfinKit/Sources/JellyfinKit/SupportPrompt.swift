import Foundation

/// Where the app runs, as far as the support prompt cares.
public enum SupportPlatform: String, Codable, Sendable, CaseIterable {
    case iPhone = "iPhone"
    case iPad = "iPad"
    case mac = "mac"
    case appleTV = "appleTV"
    case android = "android"
    case androidTV = "androidTV"
    case linux = "linux"
    case windows = "windows"

    /// Apple TV gets the heart and the card, never the sheet: a sheet over the TV's
    /// full-screen interface would stand in the way.
    public var allowsSheet: Bool {
        self != .appleTV
    }
}

/// **When to ask for support: one pure decision, the same on every platform.**
///
/// The heart (the always-visible "Support Swiftly" entry) is always there. The card at the end
/// of the home page and the one-time thank-you sheet follow the rules below; every number is
/// a constant here so the platforms cannot drift apart.
///
/// Card: at least 3 days after the first launch and at least 2 hours watched. "Not now" hides
/// it for 30 days, "Don't show again" for good.
///
/// Sheet: first at least 7 days after the first launch (and 2 hours watched), then at most
/// every 90 days and at most 3 times per calendar year. "Maybe later" counts as shown.
///
/// Neither ever appears for a supporter, during playback, or in the first 60 seconds after
/// the app started. When the sheet is due, the card waits, so there is one ask at a time.
public enum SupportPrompt {
    public static let day: TimeInterval = 86_400

    public static let minimumWatchedSeconds: Double = 2 * 3_600
    public static let quietAfterLaunch: TimeInterval = 60
    public static let cardDelay: TimeInterval = 3 * day
    public static let cardSnooze: TimeInterval = 30 * day
    public static let sheetDelay: TimeInterval = 7 * day
    public static let sheetSpacing: TimeInterval = 90 * day
    public static let sheetsPerYear = 3

    /// Everything the decision looks at. `now` is the injected clock.
    public struct Context: Sendable {
        public var now: Date
        public var status: SupportStatus
        public var usage: SupportUsage
        public var history: SupportPromptHistory
        public var isPlaying: Bool
        public var secondsSinceLaunch: TimeInterval
        public var platform: SupportPlatform

        public init(now: Date, status: SupportStatus, usage: SupportUsage,
                    history: SupportPromptHistory, isPlaying: Bool,
                    secondsSinceLaunch: TimeInterval, platform: SupportPlatform) {
            self.now = now
            self.status = status
            self.usage = usage
            self.history = history
            self.isPlaying = isPlaying
            self.secondsSinceLaunch = secondsSinceLaunch
            self.platform = platform
        }
    }

    public struct Decision: Sendable, Equatable {
        /// The "Support Swiftly" entry in Settings and About. Always true.
        public var showsHeart: Bool
        public var showsCard: Bool
        public var showsSheet: Bool

        public init(showsHeart: Bool = true, showsCard: Bool, showsSheet: Bool) {
            self.showsHeart = showsHeart
            self.showsCard = showsCard
            self.showsSheet = showsSheet
        }
    }

    /// `calendar` decides what "calendar year" means; the default follows the device's time zone.
    public static func decide(_ context: Context,
                              calendar: Calendar = Calendar(identifier: .gregorian)) -> Decision {
        let sheet = sheetIsDue(context, calendar: calendar)
        return Decision(showsCard: !sheet && cardIsDue(context), showsSheet: sheet)
    }

    /// The rules both the card and the sheet share.
    private static func mayAsk(_ context: Context, after delay: TimeInterval) -> Bool {
        guard !context.status.isSupporter,
              !context.isPlaying,
              context.secondsSinceLaunch >= quietAfterLaunch,
              context.usage.watchedSeconds >= minimumWatchedSeconds,
              let firstLaunch = context.usage.firstLaunch
        else { return false }
        return context.now.timeIntervalSince(firstLaunch) >= delay
    }

    static func cardIsDue(_ context: Context) -> Bool {
        guard mayAsk(context, after: cardDelay), !context.history.cardDismissed else { return false }
        if let until = context.history.cardSnoozedUntil, context.now < until { return false }
        return true
    }

    static func sheetIsDue(_ context: Context, calendar: Calendar) -> Bool {
        guard context.platform.allowsSheet, mayAsk(context, after: sheetDelay) else { return false }
        let shown = context.history.sheetShownAt
        if let last = shown.max(), context.now.timeIntervalSince(last) < sheetSpacing { return false }
        let year = calendar.component(.year, from: context.now)
        let thisYear = shown.filter { calendar.component(.year, from: $0) == year }.count
        return thisYear < sheetsPerYear
    }
}

// MARK: - Watch time

/// **What the apps feed with playback progress.** Call it from the same place that reports
/// progress to the server (the 500 ms playback tick is fine too), on the actor that owns
/// the counter.
public protocol WatchTimeFeed {
    /// One observation: is the video playing right now?
    mutating func playbackProgress(isPlaying: Bool, at now: Date)
    /// Playback ended, the player closed, or the app went to the background.
    mutating func playbackStopped(at now: Date)
}

/// **Sums the seconds that were actually played.** Local only, never sent.
///
/// The time between two observations counts when the earlier one said "playing". A gap
/// longer than `maximumGap` (the app was suspended, the device slept) or a clock that went
/// backwards counts nothing, so the number can only undercount, never inflate.
public struct WatchTimeCounter: WatchTimeFeed, Sendable, Equatable {
    /// Progress arrives every 0.5 to 10 seconds; anything much longer is not watching.
    public static let maximumGap: TimeInterval = 30
    /// How much unsaved time is worth one write to storage.
    public static let saveEvery: TimeInterval = 60

    public private(set) var totalSeconds: Double
    public private(set) var unsavedSeconds: Double = 0
    private var playingSince: Date?

    public init(totalSeconds: Double = 0) {
        self.totalSeconds = max(0, totalSeconds)
    }

    /// Whole hours, for "You have watched 25 hours with Swiftly."
    public var watchedHours: Int {
        Int(min(totalSeconds / 3_600, Double(Int32.max)))
    }

    /// True once enough time has piled up to store it (`SupportStore.save(_:)`).
    public var needsSave: Bool {
        unsavedSeconds >= Self.saveEvery
    }

    public mutating func playbackProgress(isPlaying: Bool, at now: Date) {
        countUntil(now)
        playingSince = isPlaying ? now : nil
    }

    public mutating func playbackStopped(at now: Date) {
        countUntil(now)
        playingSince = nil
    }

    public mutating func markSaved() {
        unsavedSeconds = 0
    }

    private mutating func countUntil(_ now: Date) {
        guard let since = playingSince else { return }
        let gap = now.timeIntervalSince(since)
        guard gap > 0, gap <= Self.maximumGap else { return }
        totalSeconds += gap
        unsavedSeconds += gap
    }
}
