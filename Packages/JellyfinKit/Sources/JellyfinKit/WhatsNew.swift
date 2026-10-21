import Foundation

/// **"What's new": one sheet after an update, filled from one JSON per version.**
///
/// The file is `Resources/whatsnew/<version>.json` in this package, so every platform reads
/// the same one. Shape and rules: `Notizen/Supporter/WHATS-NEW-SYSTEM.md`.
public struct WhatsNewEntry: Sendable, Equatable, Decodable {
    /// A text in both languages of the app.
    public struct Text: Sendable, Equatable, Decodable {
        public let en: String
        public let de: String

        public init(en: String, de: String) {
            self.en = en
            self.de = de
        }

        /// German for a German device, English for everyone else (the app's fallback).
        public func localized(_ language: String) -> String {
            language.hasPrefix("de") ? de : en
        }
    }

    public struct Item: Sendable, Equatable, Decodable {
        /// An SF Symbol name.
        public let symbol: String
        public let title: Text
        public let detail: Text?
    }

    public enum Variant: String, Sendable, Decodable {
        case standard, feature, gift, looks
    }

    public struct Module: Sendable, Equatable, Decodable {
        /// `gift` today.
        public let type: String
        public let lookId: String?
    }

    public struct Primary: Sendable, Equatable, Decodable {
        /// `continue`, `try`, `grab`, `tryLook`.
        public let label: String
        /// `dismiss`, `open:<target>`, `applyLook:<id>`.
        public let action: String
    }

    public let version: String
    public let variant: Variant
    public let title: Text
    public let items: [Item]
    public let module: Module?
    public let primary: Primary
    /// A draft is never shown: someone reads the file and removes the flag before a release.
    public let draft: Bool?

    /// The gift this sheet offers, if it has a gift module.
    public var giftLook: Look? {
        guard module?.type == "gift", let id = module?.lookId else { return nil }
        let look = Look.with(id: id)
        return look.id == id && look.isGift ? look : nil
    }

    public static func decoded(from data: Data) -> WhatsNewEntry? {
        guard let entry = try? JSONDecoder().decode(WhatsNewEntry.self, from: data),
              entry.draft != true, (3...5).contains(entry.items.count) else { return nil }
        return entry
    }

    /// The file shipped for `version`, or `nil`.
    public static func bundled(for version: String) -> WhatsNewEntry? {
        let url = Bundle.module.url(forResource: version, withExtension: "json", subdirectory: "whatsnew")
            ?? Bundle.module.url(forResource: version, withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return decoded(from: data)
    }
}

/// **Whether the sheet is due, from the stored last version.**
public enum WhatsNew {
    public static let lastSeenKey = "whatsnew.lastSeen"

    public enum Decision: Sendable, Equatable {
        /// A fresh install or nothing new: store the version, show nothing.
        case markSeen
        /// After an update with a file for this version.
        case show
        /// Seen already.
        case nothing
    }

    /// - Parameters:
    ///   - lastSeen: the stored version; `nil` on a fresh install, and on the first update
    ///     that brings this sheet at all.
    ///   - usedBefore: the app ran before this launch (it has older records). Tells the first
    ///     update with this sheet apart from a fresh install, which both have no `lastSeen`.
    ///   - hasEntry: a file exists for `current`.
    public static func decide(lastSeen: String?, usedBefore: Bool, current: String,
                              hasEntry: Bool) -> Decision {
        if let lastSeen {
            guard isNewer(current, than: lastSeen) else { return .nothing }
        } else if !usedBefore {
            return .markSeen
        }
        return hasEntry ? .show : .markSeen
    }

    /// Compares by number parts: 1.0.10 is newer than 1.0.9.
    public static func isNewer(_ version: String, than other: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = other.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
