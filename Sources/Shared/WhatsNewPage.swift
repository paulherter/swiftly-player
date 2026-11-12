import Foundation
import JellyfinKit
import struct SwiftlyCore.WhatsNewSheet
import func SwiftlyCore.whatsNewSheet

/// The what's-new file of a version as the core reads it (texts already in the UI language, 3 to 5
/// lines, never a draft). The same page for iPhone, iPad, Mac and Apple TV.
typealias WhatsNewPage = SwiftlyCore.WhatsNewSheet

extension WhatsNewPage {
    /// The raw file shipped for `version`.
    static func bundledJson(for version: String) -> Data? { WhatsNewEntry.bundledData(for: version) }

    /// The page for `version`, or `nil` (no file, a draft, a broken file).
    static func bundled(for version: String) -> WhatsNewPage? {
        guard let json = bundledJson(for: version) else { return nil }
        return whatsNewSheet(entryJson: json, language: Bundle.main.preferredLocalizations.first ?? "en")
    }

    /// The gift this page offers, if it has a gift module.
    var giftLook: Look? {
        guard let id = giftLookId else { return nil }
        let look = Look.with(id: id)
        return look.id == id && look.isGift ? look : nil
    }
}
