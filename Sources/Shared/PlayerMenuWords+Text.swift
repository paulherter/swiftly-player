import Foundation
import SwiftlyCore

/// The text of a menu word from the core: a catalogue key (translated here, in the app's catalogue), a key with one
/// `%lld`, two keys joined with " · ", or a literal the core already formatted (names, numbers).
extension PlayerMenuWords {
    var text: String {
        switch self {
        case let .key(key): Self.translate(key)
        case let .count(key, count): String(format: Self.translate(key), count)
        case let .pair(first, second): "\(Self.translate(first)) · \(Self.translate(second))"
        case let .literal(text): text
        }
    }

    private static func translate(_ key: String) -> String { String(localized: String.LocalizationValue(key)) }
}
