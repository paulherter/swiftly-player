import Foundation

/// The values offered in the playback settings: which bitrates, skip lengths and languages
/// exist.
///
/// They are not views but the selection itself, so they live in the package:
/// `Sources/Shared` is SwiftUI and unreachable for the Linux version, and a second list
/// there would be the kind of copy that drifts apart (same reason as ``ImageSelection`` and
/// ``secondaryLine``).

/// 0 means unlimited.
public struct Bitrate: Identifiable, Sendable {
    public let value: Int
    public init(_ value: Int) { self.value = value }
    public var id: Int { value }
    public static let levels = [0, 4, 8, 20, 40, 80].map(Bitrate.init)
    public static func text(_ value: Int) -> String {
        value <= 0 ? translated("Unbegrenzt") : translated("\(value) Mbit/s")
    }
}

public struct Span: Identifiable, Sendable {
    public let value: Int
    public init(_ value: Int) { self.value = value }
    public var id: Int { value }
    public static let levels = [5, 10, 15, 30, 60].map(Span.init)
}

/// An empty value means "do not preselect".
public struct LanguageSelection: Identifiable, Sendable {
    public let name: String
    public let value: String
    public var id: String { value }

    public static var all: [LanguageSelection] {
        [LanguageSelection(name: translated("Wie die Datei"), value: "")]
            + Language.all.map { LanguageSelection(name: $0.name, value: $0.name) }
    }

    public static func all(from label: String) -> [LanguageSelection] {
        [LanguageSelection(name: label, value: "")]
            + Language.all.map { LanguageSelection(name: $0.name, value: $0.name) }
    }
}
