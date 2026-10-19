import Foundation

/// **Whether this device belongs to a supporter, and how it became one.**
///
/// Stored locally only; nothing about it leaves the device. Store builds set it from the
/// store's purchase history, direct builds from a verified supporter key.
///
/// The JSON shape is fixed by explicit coding keys (`kind`, `source`, `since`), so renaming a
/// case or a label never changes what a device has already stored.
public enum SupportStatus: Sendable, Equatable {
    case none
    /// `since` is when this device learned about it (purchase date or key issue day); `nil`
    /// when unknown, for example after a restore without dates.
    case supporter(source: Source, since: Date?)

    /// Where the status came from.
    public enum Source: String, Codable, Sendable, CaseIterable {
        /// A tip bought through the App Store or Google Play.
        case store = "store"
        /// A supporter key from the website, verified offline.
        case key = "key"
    }

    public var isSupporter: Bool {
        if case .supporter = self { true } else { false }
    }
}

extension SupportStatus: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind = "kind"
        case source = "source"
        case since = "since"
    }

    private enum Kind: String, Codable {
        case none = "none"
        case supporter = "supporter"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .none:
            self = .none
        case .supporter:
            self = .supporter(source: try container.decode(Source.self, forKey: .source),
                              since: try container.decodeIfPresent(Date.self, forKey: .since))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode(Kind.none, forKey: .kind)
        case let .supporter(source, since):
            try container.encode(Kind.supporter, forKey: .kind)
            try container.encode(source, forKey: .source)
            try container.encodeIfPresent(since, forKey: .since)
        }
    }
}

/// **Local usage numbers the support prompt decides on.** Never sent anywhere.
public struct SupportUsage: Codable, Sendable, Equatable {
    /// First start of the app on this device; `nil` until the app records it.
    public var firstLaunch: Date?
    /// Seconds of actual playback, summed by `WatchTimeCounter`.
    public var watchedSeconds: Double

    private enum CodingKeys: String, CodingKey {
        case firstLaunch = "firstLaunch"
        case watchedSeconds = "watchedSeconds"
    }

    public init(firstLaunch: Date? = nil, watchedSeconds: Double = 0) {
        self.firstLaunch = firstLaunch
        self.watchedSeconds = watchedSeconds
    }
}

/// **What the person already answered to the card and the sheet.**
public struct SupportPromptHistory: Codable, Sendable, Equatable {
    /// "Not now" on the card: hidden until this moment.
    public var cardSnoozedUntil: Date?
    /// "Don't show again" on the card: the card never comes back.
    public var cardDismissed: Bool
    /// Every time the sheet appeared, newest last. "Maybe later" counts as shown.
    public var sheetShownAt: [Date]

    /// Older entries do not matter for any rule (the yearly limit looks at one year).
    public static let keptSheetDates = 12

    private enum CodingKeys: String, CodingKey {
        case cardSnoozedUntil = "cardSnoozedUntil"
        case cardDismissed = "cardDismissed"
        case sheetShownAt = "sheetShownAt"
    }

    public init(cardSnoozedUntil: Date? = nil, cardDismissed: Bool = false, sheetShownAt: [Date] = []) {
        self.cardSnoozedUntil = cardSnoozedUntil
        self.cardDismissed = cardDismissed
        self.sheetShownAt = sheetShownAt
    }

    /// "Not now" on the card.
    public mutating func snoozeCard(now: Date) {
        cardSnoozedUntil = now.addingTimeInterval(SupportPrompt.cardSnooze)
    }

    /// "Don't show again" on the card.
    public mutating func dismissCard() {
        cardDismissed = true
    }

    /// Call when the sheet appears, before any answer. "Maybe later" needs nothing extra.
    public mutating func recordSheetShown(at now: Date) {
        sheetShownAt.append(now)
        if sheetShownAt.count > Self.keptSheetDates {
            sheetShownAt.removeFirst(sheetShownAt.count - Self.keptSheetDates)
        }
    }
}

// MARK: - Storage

/// **Where the support state lives on a platform.** One blob per key.
///
/// Apple: `UserDefaults`; Android: `SharedPreferences` through the core; Linux and Windows:
/// the settings file. The package ships only `InMemorySupportStorage`, for tests and previews.
public protocol SupportStorage {
    func data(forKey key: String) -> Data?
    /// `nil` removes the entry.
    func setData(_ data: Data?, forKey key: String)
}

/// The fixed storage keys. Changing one loses what devices have stored.
public enum SupportStorageKey {
    public static let status = "support.status"
    public static let usage = "support.usage"
    public static let promptHistory = "support.promptHistory"
    public static let all = [status, usage, promptHistory]
}

/// Keeps everything in a dictionary. For tests and previews, not thread-safe.
public final class InMemorySupportStorage: SupportStorage {
    public private(set) var values: [String: Data]

    public init(values: [String: Data] = [:]) {
        self.values = values
    }

    public func data(forKey key: String) -> Data? {
        values[key]
    }

    public func setData(_ data: Data?, forKey key: String) {
        values[key] = data
    }
}

/// **Typed access to the three records**, encoded as JSON with dates in seconds since 1970.
///
/// A record that is missing or unreadable reads as its empty value; nothing here throws,
/// because a damaged record must never block the app.
public struct SupportStore {
    public let storage: any SupportStorage

    public init(storage: any SupportStorage) {
        self.storage = storage
    }

    public var status: SupportStatus {
        get { read(SupportStatus.self, SupportStorageKey.status) ?? .none }
        nonmutating set { write(newValue, SupportStorageKey.status) }
    }

    public var usage: SupportUsage {
        get { read(SupportUsage.self, SupportStorageKey.usage) ?? SupportUsage() }
        nonmutating set { write(newValue, SupportStorageKey.usage) }
    }

    public var promptHistory: SupportPromptHistory {
        get { read(SupportPromptHistory.self, SupportStorageKey.promptHistory) ?? SupportPromptHistory() }
        nonmutating set { write(newValue, SupportStorageKey.promptHistory) }
    }

    /// Call once per app start. Records the first launch only the first time.
    public func recordLaunch(now: Date) {
        var current = usage
        guard current.firstLaunch == nil else { return }
        current.firstLaunch = now
        usage = current
    }

    /// Stores the counter's total. Call when `WatchTimeCounter.needsSave` is true and when
    /// playback stops or the app goes to the background.
    public func save(_ counter: inout WatchTimeCounter) {
        var current = usage
        current.watchedSeconds = counter.totalSeconds
        usage = current
        counter.markSaved()
    }

    private func read<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = storage.data(forKey: key) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, _ key: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        storage.setData(try? encoder.encode(value), forKey: key)
    }
}
