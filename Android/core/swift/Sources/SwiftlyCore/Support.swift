import Foundation
import JellyfinKit

// MARK: - "Support Swiftly", the bridge for Kotlin
//
// **Every rule lives in the package** (`SupportPrompt`, `SupportStore`, `WatchTimeCounter`). Kotlin
// keeps the three records as plain strings in SharedPreferences under the package's keys
// (`SupportStorageKey`: `support.status`, `support.usage`, `support.promptHistory`) and hands them
// in here; what comes back is the new record, in exactly the JSON the package writes on Apple.
//
// Only the shared part is here. The supporter key of the direct build is checked in Kotlin
// (`src/direct`), so this library is the same binary for both flavors and carries neither the
// website nor the key.

/// The package's records over strings Kotlin holds. Not thread-safe; one per call.
private final class StringSupportStorage: SupportStorage {
    var values: [String: Data] = [:]

    init(status: String = "", usage: String = "", history: String = "") {
        put(status, SupportStorageKey.status)
        put(usage, SupportStorageKey.usage)
        put(history, SupportStorageKey.promptHistory)
    }

    private func put(_ text: String, _ key: String) {
        if !text.isEmpty { values[key] = Data(text.utf8) }
    }

    func data(forKey key: String) -> Data? { values[key] }
    func setData(_ data: Data?, forKey key: String) { values[key] = data }

    func text(_ key: String) -> String {
        values[key].map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

private struct SupportDecisionResponse: Encodable {
    let showsHeart: Bool
    let showsCard: Bool
    let showsSheet: Bool
    let watchedHours: Int
    let isSupporter: Bool
}

private func supportDate(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

extension Kern {
    /// `SupportStore.recordLaunch`: the first start, once. Returns the usage record.
    public static func supportRecordLaunch(usage: String, nowMs: Int64) -> String {
        let storage = StringSupportStorage(usage: usage)
        SupportStore(storage: storage).recordLaunch(now: supportDate(nowMs))
        return storage.text(SupportStorageKey.usage)
    }

    /// `SupportPrompt.decide` for Android (`tv`: Android TV). Answer:
    /// `{"showsHeart","showsCard","showsSheet","watchedHours","isSupporter"}`.
    public static func supportDecide(status: String, usage: String, history: String, isPlaying: Bool,
                                     secondsSinceLaunch: Double, tv: Bool, nowMs: Int64) -> String {
        let store = SupportStore(storage: StringSupportStorage(status: status, usage: usage, history: history))
        let context = SupportPrompt.Context(now: supportDate(nowMs), status: store.status, usage: store.usage,
                                            history: store.promptHistory, isPlaying: isPlaying,
                                            secondsSinceLaunch: secondsSinceLaunch,
                                            platform: tv ? .androidTV : .android)
        let d = SupportPrompt.decide(context, calendar: Calendar.current)
        let hours = WatchTimeCounter(totalSeconds: store.usage.watchedSeconds).watchedHours
        return supportEncoded(SupportDecisionResponse(showsHeart: d.showsHeart, showsCard: d.showsCard,
                                                      showsSheet: d.showsSheet, watchedHours: hours,
                                                      isSupporter: store.status.isSupporter))
    }

    /// The history after an answer: `snooze` ("Not now" on the card), `dismiss` ("Don't show
    /// again"), `sheetShown` (the sheet appeared). Anything else returns it unchanged.
    public static func supportHistoryAfter(history: String, answer: String, nowMs: Int64) -> String {
        let storage = StringSupportStorage(history: history)
        let store = SupportStore(storage: storage)
        var h = store.promptHistory
        switch answer {
        case "snooze": h.snoozeCard(now: supportDate(nowMs))
        case "dismiss": h.dismissCard()
        case "sheetShown": h.recordSheetShown(at: supportDate(nowMs))
        default: break
        }
        store.promptHistory = h
        return storage.text(SupportStorageKey.promptHistory)
    }

    /// The status record for a purchase from Google Play. `sinceMs` 0 means unknown.
    public static func supportStoreStatus(sinceMs: Int64) -> String {
        let storage = StringSupportStorage()
        SupportStore(storage: storage).status = .supporter(source: .store, since: sinceMs > 0 ? supportDate(sinceMs) : nil)
        return storage.text(SupportStorageKey.status)
    }

    /// The status record for a verified supporter key, dated by its issue day (`SupporterKey.status`).
    /// The key itself is checked in the direct build; only the outcome comes here.
    public static func supportKeyStatus(issuedMs: Int64) -> String {
        let storage = StringSupportStorage()
        SupportStore(storage: storage).status = .supporter(source: .key, since: supportDate(issuedMs))
        return storage.text(SupportStorageKey.status)
    }

    /// Whether a status record says supporter, and from where: "store", "key" or "" for none.
    public static func supportSource(status: String) -> String {
        guard case let .supporter(source, _) = SupportStore(storage: StringSupportStorage(status: status)).status
        else { return "" }
        return source.rawValue
    }

    /// The tip products in display order, with their German and English titles and the symbol:
    /// `[{"id","de","en","emoji"}]`. Prices come from Google Play, never from here.
    public static func supportTips() -> String {
        struct Tip: Encodable { let id, de, en, emoji: String }
        return supportEncoded(SupportTip.ordered.map {
            Tip(id: $0.productID, de: $0.title.de, en: $0.title.en, emoji: $0.emoji)
        })
    }

    // MARK: Watch time

    /// Start the counter from the stored usage record, once per app start. The playback tick
    /// feeds it (`playbackTick`), the end of playback stops it.
    public func supportWatchBegin(usage: String) {
        watch.begin(seconds: SupportStore(storage: StringSupportStorage(usage: usage)).usage.watchedSeconds)
    }

    /// The usage record with the counted seconds, when enough piled up (`needsSave`) or `force`
    /// (playback ended, app in the background); "" when there is nothing to store yet.
    public func supportWatchTake(usage: String, force: Bool) -> String {
        watch.take(usage: usage, force: force)
    }

    private static func supportEncoded<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

/// **The watch-time counter with its own lock.** The playback tick may feed it while holding
/// `Kern`'s lock; this one never takes that lock, so the two cannot deadlock.
final class WatchBox: @unchecked Sendable {
    private let lock = NSLock()
    private var counter = WatchTimeCounter()

    func begin(seconds: Double) {
        lock.lock(); counter = WatchTimeCounter(totalSeconds: seconds); lock.unlock()
    }

    func progress(isPlaying: Bool) {
        lock.lock(); counter.playbackProgress(isPlaying: isPlaying, at: Date()); lock.unlock()
    }

    func stopped() {
        lock.lock(); counter.playbackStopped(at: Date()); lock.unlock()
    }

    func take(usage: String, force: Bool) -> String {
        lock.lock(); defer { lock.unlock() }
        guard force ? counter.unsavedSeconds > 0 : counter.needsSave else { return "" }
        let storage = StringSupportStorage(usage: usage)
        SupportStore(storage: storage).save(&counter)
        return storage.text(SupportStorageKey.usage)
    }
}
