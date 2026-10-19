import Foundation
import Testing
@testable import JellyfinKit

@Suite("Support prompt")
struct SupportPromptTests {
    static let day = SupportPrompt.day
    static let hour: Double = 3_600
    /// 2027-01-10 12:00 UTC, far enough from a year boundary for the plain rules.
    static let start = Date(timeIntervalSince1970: 1_799_582_400)

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// A context where everything is allowed, `days` after the first launch.
    func context(days: Double, watchedHours: Double = 2, status: SupportStatus = .none,
                 history: SupportPromptHistory = .init(), isPlaying: Bool = false,
                 secondsSinceLaunch: TimeInterval = 120,
                 platform: SupportPlatform = .iPhone) -> SupportPrompt.Context {
        SupportPrompt.Context(now: Self.start.addingTimeInterval(days * Self.day),
                              status: status,
                              usage: SupportUsage(firstLaunch: Self.start, watchedSeconds: watchedHours * Self.hour),
                              history: history, isPlaying: isPlaying,
                              secondsSinceLaunch: secondsSinceLaunch, platform: platform)
    }

    func decide(_ c: SupportPrompt.Context) -> SupportPrompt.Decision {
        SupportPrompt.decide(c, calendar: Self.utc)
    }

    // MARK: Heart

    @Test("The heart is always there, even for supporters and during playback")
    func heartAlways() {
        #expect(decide(context(days: 0, watchedHours: 0)).showsHeart)
        #expect(decide(context(days: 100, status: .supporter(source: .store, since: nil), isPlaying: true)).showsHeart)
    }

    // MARK: Card

    @Test("Card: not before 3 days since the first launch")
    func cardWaitsThreeDays() {
        #expect(!decide(context(days: 2.99)).showsCard)
        #expect(decide(context(days: 3)).showsCard)
    }

    @Test("Card: not before 2 hours watched")
    func cardWaitsTwoHours() {
        #expect(!decide(context(days: 5, watchedHours: 1.99)).showsCard)
        #expect(decide(context(days: 5, watchedHours: 2)).showsCard)
    }

    @Test("Card: no first launch recorded means no card")
    func cardNeedsFirstLaunch() {
        var c = context(days: 10)
        c.usage.firstLaunch = nil
        #expect(!decide(c).showsCard)
    }

    @Test("Card: Not now hides it for exactly 30 days")
    func cardSnooze() {
        var history = SupportPromptHistory()
        // A recent sheet keeps the sheet out of the way until day 97.
        history.recordSheetShown(at: context(days: 7).now)
        let now = context(days: 4).now
        history.snoozeCard(now: now)
        #expect(history.cardSnoozedUntil == now.addingTimeInterval(30 * Self.day))
        #expect(!decide(context(days: 4, history: history)).showsCard)
        #expect(!decide(context(days: 33.99, history: history)).showsCard)
        #expect(decide(context(days: 34, history: history)).showsCard)
    }

    @Test("Card: Don't show again ends it for good")
    func cardDismissed() {
        var history = SupportPromptHistory()
        history.dismissCard()
        #expect(!decide(context(days: 4, history: history)).showsCard)
        #expect(!decide(context(days: 4_000, watchedHours: 900, history: history)).showsCard)
    }

    @Test("Card: allowed on Apple TV")
    func cardOnAppleTV() {
        #expect(decide(context(days: 3, platform: .appleTV)).showsCard)
    }

    // MARK: Sheet

    @Test("Sheet: not before 7 days since the first launch")
    func sheetWaitsSevenDays() {
        #expect(!decide(context(days: 6.99)).showsSheet)
        #expect(decide(context(days: 7)).showsSheet)
    }

    @Test("Sheet: not before 2 hours watched")
    func sheetWaitsTwoHours() {
        #expect(!decide(context(days: 8, watchedHours: 1.5)).showsSheet)
        #expect(decide(context(days: 8, watchedHours: 2)).showsSheet)
    }

    @Test("Sheet: at most every 90 days; Maybe later counts as shown")
    func sheetSpacing() {
        var history = SupportPromptHistory()
        history.recordSheetShown(at: context(days: 7).now) // answered "Maybe later"
        #expect(!decide(context(days: 7, history: history)).showsSheet)
        #expect(!decide(context(days: 96.99, history: history)).showsSheet)
        #expect(decide(context(days: 97, history: history)).showsSheet)
    }

    @Test("Sheet: at most 3 times per calendar year")
    func sheetYearlyLimit() {
        // 2027-01-01 00:00 UTC; three showings 90 days apart all fall in 2027.
        let newYear = Date(timeIntervalSince1970: 1_798_761_600)
        var history = SupportPromptHistory()
        for i in 0..<3 { history.recordSheetShown(at: newYear.addingTimeInterval(Double(i) * 90 * Self.day)) }
        var c = context(days: 0)
        c.usage.firstLaunch = newYear.addingTimeInterval(-30 * Self.day)
        c.history = history
        c.now = newYear.addingTimeInterval(300 * Self.day) // 2027-10-28, 120 days after the last
        #expect(!decide(c).showsSheet)
        c.now = Date(timeIntervalSince1970: 1_830_297_600) // 2028-01-01 00:00 UTC
        #expect(decide(c).showsSheet)
    }

    @Test("Sheet: never on Apple TV, the card shows instead")
    func noSheetOnAppleTV() {
        let d = decide(context(days: 10, platform: .appleTV))
        #expect(!d.showsSheet)
        #expect(d.showsCard)
        #expect(!SupportPlatform.appleTV.allowsSheet)
        #expect(SupportPlatform.allCases.filter { !$0.allowsSheet } == [.appleTV])
    }

    @Test("When the sheet is due, the card waits")
    func oneAskAtATime() {
        let d = decide(context(days: 10))
        #expect(d.showsSheet)
        #expect(!d.showsCard)
    }

    // MARK: Shared rules

    @Test("Never for supporters, from either source")
    func neverForSupporters() {
        for source in SupportStatus.Source.allCases {
            let d = decide(context(days: 100, watchedHours: 50, status: .supporter(source: source, since: nil)))
            #expect(!d.showsCard && !d.showsSheet)
        }
    }

    @Test("Never during playback")
    func neverWhilePlaying() {
        let d = decide(context(days: 100, isPlaying: true))
        #expect(!d.showsCard && !d.showsSheet)
    }

    @Test("Never in the first 60 seconds after launch")
    func quietAfterLaunch() {
        let early = decide(context(days: 100, secondsSinceLaunch: 59.9))
        #expect(!early.showsCard && !early.showsSheet)
        #expect(decide(context(days: 100, secondsSinceLaunch: 60)).showsSheet)
        let earlyCard = decide(context(days: 5, secondsSinceLaunch: 10))
        #expect(!earlyCard.showsCard)
    }

    @Test("History keeps only the last 12 sheet dates")
    func historyTrimmed() {
        var history = SupportPromptHistory()
        for i in 0..<20 { history.recordSheetShown(at: Self.start.addingTimeInterval(Double(i))) }
        #expect(history.sheetShownAt.count == SupportPromptHistory.keptSheetDates)
        #expect(history.sheetShownAt.last == Self.start.addingTimeInterval(19))
    }
}

@Suite("Watch time counter")
struct WatchTimeCounterTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func at(_ seconds: Double) -> Date { Self.t0.addingTimeInterval(seconds) }

    @Test("Counts the time between playing observations")
    func countsPlaying() {
        var counter = WatchTimeCounter()
        for s in stride(from: 0.0, through: 100, by: 10) { counter.playbackProgress(isPlaying: true, at: at(s)) }
        #expect(counter.totalSeconds == 100)
        counter.playbackStopped(at: at(105))
        #expect(counter.totalSeconds == 105)
    }

    @Test("Paused time does not count")
    func pausedNotCounted() {
        var counter = WatchTimeCounter()
        counter.playbackProgress(isPlaying: true, at: at(0))
        counter.playbackProgress(isPlaying: false, at: at(10)) // 10 s played
        counter.playbackProgress(isPlaying: false, at: at(20))
        counter.playbackProgress(isPlaying: true, at: at(25))
        counter.playbackProgress(isPlaying: true, at: at(30))  // 5 s played
        #expect(counter.totalSeconds == 15)
    }

    @Test("Long gaps and clocks running backwards count nothing")
    func gapsIgnored() {
        var counter = WatchTimeCounter()
        counter.playbackProgress(isPlaying: true, at: at(0))
        counter.playbackProgress(isPlaying: true, at: at(31))   // suspended: dropped
        counter.playbackProgress(isPlaying: true, at: at(41))   // 10 s
        counter.playbackProgress(isPlaying: true, at: at(35))   // backwards: dropped
        counter.playbackProgress(isPlaying: true, at: at(65))   // 30 s, at the limit
        #expect(counter.totalSeconds == 40)
    }

    @Test("Nothing counts after a stop until playback resumes")
    func stopEndsCounting() {
        var counter = WatchTimeCounter(totalSeconds: 100)
        counter.playbackProgress(isPlaying: true, at: at(0))
        counter.playbackStopped(at: at(5))
        counter.playbackStopped(at: at(10))
        counter.playbackProgress(isPlaying: true, at: at(12))
        #expect(counter.totalSeconds == 105)
    }

    @Test("Whole hours and the save threshold")
    func hoursAndSaving() {
        var counter = WatchTimeCounter(totalSeconds: 2 * 3_600 - 1)
        #expect(counter.watchedHours == 1)
        #expect(!counter.needsSave)
        for s in stride(from: 0.0, through: 60, by: 10) { counter.playbackProgress(isPlaying: true, at: at(s)) }
        #expect(counter.watchedHours == 2)
        #expect(counter.needsSave)

        let store = SupportStore(storage: InMemorySupportStorage())
        store.save(&counter)
        #expect(!counter.needsSave)
        #expect(store.usage.watchedSeconds == counter.totalSeconds)
        #expect(WatchTimeCounter(totalSeconds: -5).totalSeconds == 0)
    }

    @Test("Usable through the feed protocol")
    func feedProtocol() {
        func feed(_ sink: inout some WatchTimeFeed) {
            sink.playbackProgress(isPlaying: true, at: at(0))
            sink.playbackStopped(at: at(20))
        }
        var counter = WatchTimeCounter()
        feed(&counter)
        #expect(counter.totalSeconds == 20)
    }
}
