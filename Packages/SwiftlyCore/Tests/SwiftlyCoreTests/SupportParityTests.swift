import Foundation
import Testing

import JellyfinKit
@testable import SwiftlyCore

/// The core's `SupportModel` against the old Swift rules (`SupportStore`, `SupportPrompt`, `WatchTimeCounter`)
/// on the same stored bytes: equal status, equal decisions, and a write by the core reads back through the old store.
@Suite(.serialized) struct SupportParityTests {
    private static let day = 86_400.0
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// The old store and a core over copies of the same bytes.
    /// The core runs over the app's own `UserDefaultsKeyValueStore`, so the stored bytes are the old plain keys.
    private static func suite() -> (UserDefaults, UserDefaultsKeyValueStore) {
        let defaults = UserDefaults(suiteName: "support-parity-\(UUID().uuidString)")!
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (defaults, UserDefaultsKeyValueStore(defaults: defaults, downloadsFolder: tmp))
    }

    private static func pair(_ old: SupportStore, _ mem: InMemorySupportStorage) -> (SupportModel, UserDefaults) {
        let (defaults, kv) = suite()
        for key in SupportStorageKey.all { if let d = mem.data(forKey: key) { defaults.set(d, forKey: key) } }
        return (makeCore(store: kv).supportModel(), defaults)
    }

    @Test func statusAndHoursReadTheOldBytes() {
        for status in [
            SupportStatus.none, .supporter(source: .store, since: Self.now), .supporter(source: .key, since: nil),
        ] {
            let mem = InMemorySupportStorage()
            let old = SupportStore(storage: mem)
            old.status = status
            old.usage = SupportUsage(firstLaunch: Self.now, watchedSeconds: 3 * 3_600 + 5)
            let (core, _) = Self.pair(old, mem)
            let info = core.status()
            #expect(info.supporter == status.isSupporter)
            if case let .supporter(source, since) = status {
                #expect(info.source == source.rawValue)
                #expect(info.since == since?.timeIntervalSince1970)
            }
            #expect(core.watchedHours() == 3)
        }
    }

    @Test func decisionsMatchTheOldRules() {
        let kinds: [(SupportPlatformKind, SupportPlatform)] = [
            (.iPhone, .iPhone), (.iPad, .iPad), (.mac, .mac), (.appleTv, .appleTV),
        ]
        var checked = 0
        for (kind, platform) in kinds {
            for status in [SupportStatus.none, .supporter(source: .store, since: Self.now)] {
                for firstLaunchDays in [0.0, 2, 4, 8, 40] {
                    for hours in [0.0, 1, 3] {
                        for history in [
                            SupportPromptHistory(),
                            SupportPromptHistory(cardSnoozedUntil: Self.now.addingTimeInterval(Self.day), cardSnoozes: 1),
                            SupportPromptHistory(cardDismissed: true),
                            SupportPromptHistory(sheetShownAt: [Self.now.addingTimeInterval(-10 * Self.day)]),
                            SupportPromptHistory(sheetShownAt: (1...3).map { Self.now.addingTimeInterval(-Double($0) * 100 * Self.day) }),
                        ] {
                            for (playing, since) in [(false, 120.0), (true, 120), (false, 10)] {
                                let mem = InMemorySupportStorage()
                                let old = SupportStore(storage: mem)
                                old.status = status
                                let usage = SupportUsage(
                                    firstLaunch: Self.now.addingTimeInterval(-firstLaunchDays * Self.day),
                                    watchedSeconds: hours * 3_600)
                                old.usage = usage
                                old.promptHistory = history
                                let (core, _) = Self.pair(old, mem)
                                let expected = SupportPrompt.decide(.init(
                                    now: Self.now, status: status, usage: usage, history: history, isPlaying: playing,
                                    secondsSinceLaunch: since, platform: platform))
                                let got = core.decide(
                                    now: Self.now.timeIntervalSince1970, isPlaying: playing, secondsSinceLaunch: since,
                                    platform: kind, utcOffset: Int64(Calendar.current.timeZone.secondsFromGMT(for: Self.now)))
                                #expect(got.showsHeart == expected.showsHeart)
                                #expect(got.showsCard == expected.showsCard)
                                #expect(got.showsSheet == expected.showsSheet)
                                checked += 1
                            }
                        }
                    }
                }
            }
        }
        #expect(checked == 4 * 2 * 5 * 3 * 5 * 3)
    }

    @Test func writesByTheCoreReadBackThroughTheOldStore() throws {
        let (defaults, kv) = Self.suite()
        let core = makeCore(store: kv).supportModel()
        try core.recordLaunch(now: Self.now.timeIntervalSince1970)
        try core.setStatus(status: SupportStatusInfo(supporter: true, source: "key", since: Self.now.timeIntervalSince1970))
        try core.snoozeCard(now: Self.now.timeIntervalSince1970)
        try core.recordSheetShown(now: Self.now.timeIntervalSince1970)
        try core.playbackProgress(isPlaying: true, at: 1_000)
        try core.playbackStopped(at: 1_020)
        kv.flush()
        let mem = InMemorySupportStorage()
        for key in SupportStorageKey.all { if let d = defaults.data(forKey: key) { mem.setData(d, forKey: key) } }
        let old = SupportStore(storage: mem)
        #expect(old.status == .supporter(source: .key, since: Self.now))
        #expect(old.usage.firstLaunch == Self.now)
        #expect(old.usage.watchedSeconds == 20)
        #expect(old.promptHistory.cardSnoozes == 1)
        #expect(old.promptHistory.cardSnoozedUntil == Self.now.addingTimeInterval(SupportPrompt.cardSnooze))
        #expect(old.promptHistory.sheetShownAt == [Self.now])
        // And the other way: the old store writes a dismissal, the core's decision follows.
        var h = old.promptHistory
        h.dismissCard()
        old.promptHistory = h
        defaults.set(mem.data(forKey: SupportStorageKey.promptHistory)!, forKey: SupportStorageKey.promptHistory)
        let fresh = makeCore(store: kv).supportModel()
        #expect(!fresh.decide(
            now: Self.now.timeIntervalSince1970 + 30 * Self.day, isPlaying: false, secondsSinceLaunch: 600,
            platform: .iPhone, utcOffset: 0).showsCard)
    }
}
