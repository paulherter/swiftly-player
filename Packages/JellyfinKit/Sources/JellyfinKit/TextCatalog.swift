#if !canImport(Darwin)
import Foundation
#if os(Windows)
import WinSDK
#endif

// **Why this file exists: on Linux, Foundation does not translate.**
//
// Measured on Linux against a shipped release, with the installed bundles:
//
// ```
// preferredLanguages            ["en-001"]        — independent of LANG
// SwiftlyLinux  localizations   ["de", "en"]
//               preferred       ["en"]
//               development     "de"
//               NSLocalizedString("Anmelden")   -> "Anmelden"     (German)
// JellyfinKit   localizations   ["de", "en"]
//               preferred       ["de"]
//               development     "en"
//               NSLocalizedString("Zuletzt")    -> "Recent"       (English)
// ```
//
// This establishes two things. First, `NSLocalizedString` ignores
// `preferredLocalizations` and takes the bundle's **development language**;
// on Linux there is no Apple language setting for CFBundle to choose from.
// Second, the two bundles therefore diverge: the UI is always German
// (`defaultLocalization: "de"`), the package texts always English
// (`defaultLocalization: "en"`). Every user gets **both** languages at once,
// and nobody gets theirs.
//
// What demonstrably works is going through the file itself:
// `url(forResource:withExtension:subdirectory:localization:)` returns the right
// `.lproj`, and `NSDictionary(contentsOf:)` reads it completely. So the lookup
// is done here instead of leaving it to Foundation.
//
// **Another reason to avoid `NSLocalizedString`: it crashes.** If a
// `Localizable.stringsdict` sits next to the `Localizable.strings` (in the
// package it does), the call segfaults for every key that is in the
// stringsdict, in `Bundle.localizedString(forKey:value:table:)` while bridging
// the plural dictionary. Today this does not hit us, because the code does
// not look up that key at all (see ``Textschluessel``); after a fix it would.
// The own path avoids the crash completely.

/// A key for ``TextCatalog``, the Linux replacement for
/// `String.LocalizationValue`.
///
/// **The problem it solves.** On Apple the parameter of ``translated(_:)`` is a
/// `String.LocalizationValue`; it captures the interpolation and turns
/// `translated("Staffel \(3)")` into the key `"Staffel %lld"` with the argument
/// `3`. On Linux the parameter used to be a plain `String`, so the
/// interpolation ran immediately, `"Staffel 3"` was looked up, and that is in
/// no catalog. Measured:
///
/// ```
/// looked up "Staffel 3"          -> "Staffel 3"     (not found)
/// catalog key "Staffel %lld"     -> "Season %lld"   (would be there)
/// ```
///
/// **That made all 21 places with interpolation dead on Linux**: runtime,
/// season count, remaining time, button labels, all error messages, and
/// regardless of whether the lookup path is right. This type builds the same
/// key as Apple and keeps the arguments for formatting.
///
/// The specifiers are those of `String.LocalizationValue`: `Int` becomes
/// `%lld`, `String` becomes `%@`, `Double` becomes `%lf`. A type missing here is
/// **intentional**: the build breaks instead of silently producing a key that
/// differs from the one on Apple.
public struct TextKey: ExpressibleByStringInterpolation, Sendable {

    /// What waits for arguments. An enumeration instead of `[any CVarArg]`, so the
    /// type stays `Sendable` and the catalog may be global.
    enum Argument: Sendable {
        case figure(Int)
        case text(String)
        case commaNumber(Double)

        /// **`Int64`, not `Int`.** `%lld` always reads 64 bits. On 32-bit Android
        /// (armeabi-v7a, e.g. Mi Box S) `Int` is 32 bits wide: two numbers landed in one
        /// slot, and "1 Std. 40 Min." became "171798691841 Std. …".
        var asFormatArgument: any CVarArg {
            switch self {
            case let .figure(w):      Int64(w)
            case let .text(w):      w
            case let .commaNumber(w): w
            }
        }
    }

    let format: String
    let arguments: [Argument]

    /// A key without placeholders, the path for callers that already hold a
    /// `String` (the UI formats itself).
    public init(_ text: String) {
        format = text
        arguments = []
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public init(stringInterpolation: StringInterpolation) {
        format = stringInterpolation.format
        arguments = stringInterpolation.arguments
    }

    public struct StringInterpolation: StringInterpolationProtocol, Sendable {
        var format = ""
        var arguments: [Argument] = []

        public init(literalCapacity: Int, interpolationCount: Int) {}

        /// **A `%` in the literal is doubled**, exactly as on Apple: the key ends up
        /// in `String(format:)`, where a single `%` would be a placeholder. The catalog
        /// then contains `%%` as well. Today the case occurs nowhere.
        public mutating func appendLiteral(_ literal: String) {
            format += literal.replacingOccurrences(of: "%", with: "%%")
        }

        public mutating func appendInterpolation(_ value: Int) {
            format += "%lld"
            arguments.append(.figure(value))
        }

        public mutating func appendInterpolation(_ value: String) {
            format += "%@"
            arguments.append(.text(value))
        }

        public mutating func appendInterpolation(_ value: Double) {
            format += "%lf"
            arguments.append(.commaNumber(value))
        }
    }
}

/// The text catalog of a bundle, read once at startup.
///
/// A bundle finds only what is in it, so each target gets its own: the package
/// its own, the UI its own. What is shared is the **procedure**, not the
/// content; a second copy of this mechanism would be the sure way for the two to
/// drift apart.
public struct TextCatalog: Sendable {

    /// A plural entry from the `Localizable.stringsdict`, translated into Swift
    /// types, since `NSDictionary` is not `Sendable`.
    struct MoreNumberRule: Sendable {
        /// The frame, e.g. `%#@n@`.
        let format: String
        /// Variable name → category (`one`, `other`, …) → wording.
        let variables: [String: [String: String]]
    }

    /// The language that was chosen. For debugging and for tests.
    public let language: String
    /// The requested languages in order, as the selection saw them, for the log.
    public let requests: [String]
    /// The languages the bundle ships, for the log.
    public let availableLanguages: [String]
    private let entries: [String: String]
    private let plural: [String: MoreNumberRule]

    // MARK: Language selection

    /// The display languages the system itself reports.
    ///
    /// **Only on Windows.** There nobody sets `LANG`; the language is in the system
    /// settings and available through `GetUserPreferredUILanguages`. Without this
    /// source every Windows user would get English: measured in a Windows VM, empty
    /// environment, `UICulture: en-US`, catalog choice `en`, even on a German
    /// system.
    ///
    /// **On Linux the list stays empty on purpose.** Foundation reports
    /// `Locale.preferredLanguages == ["en-001"]` there regardless of anything, the
    /// very false answer this file exists because of. Feeding it in here would
    /// bring the error back through the back door.
    static func systemLanguages() -> [String] {
        #if os(Windows)
        var count: ULONG = 0
        var symbolText: ULONG = 0
        // First ask how large the buffer needs to be.
        // **No `.boolValue`.** Swift's WinSDK overlay already maps `BOOL` to `Bool`
        // here; `WindowsBool` would appear only for a return type the overlay does not
        // know. Seen on the first compile on Windows: "value of type 'Bool' has no
        // member 'boolValue'".
        guard GetUserPreferredUILanguages(DWORD(MUI_LANGUAGE_NAME), &count, nil, &symbolText),
              symbolText > 0 else { return [] }
        var buffer = [WCHAR](repeating: 0, count: Int(symbolText))
        guard GetUserPreferredUILanguages(DWORD(MUI_LANGUAGE_NAME), &count,
                                          &buffer, &symbolText) else { return [] }
        // Double-null-terminated list: "de-DE\0en-US\0\0".
        var names: [String] = []
        var beginning = 0
        for (i, characterValue) in buffer.enumerated() where characterValue == 0 {
            if i > beginning {
                names.append(String(decoding: buffer[beginning..<i], as: UTF16.self))
            }
            beginning = i + 1
        }
        return names
        #else
        return []
        #endif
    }

    /// The user's language preferences, in descending order.
    ///
    /// **From the environment, because there is nothing else.** Linux has no Apple
    /// language setting; what the user wants is in `LANGUAGE`, `LC_ALL`,
    /// `LC_MESSAGES` and `LANG`, in that order, as every gettext program on the
    /// system reads it. `LANGUAGE` is a colon-separated list ("I can also do
    /// English"), the others carry one value.
    ///
    /// `de_DE.UTF-8@euro` becomes `de-DE`, then `de`; both are tried so that a
    /// catalog with `pt-BR` **and** one with `pt` are found. `C` and `POSIX` are
    /// not languages and are dropped.
    ///
    /// `en` always comes last: someone running French would rather get the English
    /// version than a German one. If that is missing too, the key stays, and that
    /// is the German wording, never a cryptic identifier.
    static func languageRequests(from environment: [String: String],
                               system: [String] = []) -> [String] {
        var raw: [String] = []
        if let list = environment["LANGUAGE"] {
            raw += list.split(separator: ":").map(String.init)
        }
        for name in ["LC_ALL", "LC_MESSAGES", "LANG"] {
            if let value = environment[name] { raw.append(value) }
        }
        // **The environment beats the system.** Whoever sets `LANG` means it; that is
        // a manual intervention and should win. On Windows the list is normally empty,
        // and the system decides there.
        raw += system

        var requests: [String] = []
        for entryRecord in raw {
            // Drop encoding and modifier: `de_DE.UTF-8@euro` -> `de_DE`.
            let withoutItem = entryRecord.split(separator: ".").first?.split(separator: "@").first ?? ""
            // **Split at the hyphen too.** Windows reports its languages as `de-DE`, not
            // `de_DE`. Split only at the underscore, `de-DE` stayed whole, no catalog is
            // named that, and the choice fell to the appended `en`: the UI was English on
            // German Windows while the launcher detected German.
            let parts = withoutItem.split(whereSeparator: { $0 == "_" || $0 == "-" })
            guard let language = parts.first.map(String.init),
                  !language.isEmpty, language != "C", language != "POSIX"
            else { continue }
            if parts.count > 1 { requests.append("\(language)-\(parts[1])") }
            requests.append(language)
        }
        requests.append("en")

        // Keep the order, drop repetitions.
        var watched = Set<String>()
        return requests.filter { watched.insert($0).inserted }
    }

    /// The languages for which the bundle contains a `.lproj`.
    ///
    /// **Look for yourself, do not just trust `bundle.localizations`.** The SwiftPM
    /// resource bundle has no `Info.plist` on Windows and Linux; what Foundation
    /// then reports as the language list depends on the version. The folders
    /// themselves do not lie. `Base` is not a language.
    static func languageFolder(in bundle: Bundle) -> Set<String> {
        var found = Set(bundle.localizations.filter { $0 != "Base" })
        let places = [bundle.resourcePath, bundle.bundlePath].compactMap { $0 }
        for place in Set(places) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: place) else { continue }
            for name in names where name.hasSuffix(".lproj") {
                let language = String(name.dropLast(".lproj".count))
                if !language.isEmpty, language != "Base" { found.insert(language) }
            }
        }
        return found
    }

    // MARK: Reading

    /// A catalog without entries: every text stands as its own key.
    init(empty language: String) {
        self.language = language
        requests = []
        availableLanguages = []
        entries = [:]
        plural = [:]
    }

    /// - Parameter wunsch: The language the platform specifies. On Android it comes
    ///   from Kotlin, where there is no environment variable for `systemLanguages()`
    ///   to read.
    public init(bundle: Bundle, language wish: String? = nil) {
        let available = Self.languageFolder(in: bundle)
        // **A local constant, not `self.language`.** The helper function below reads
        // it; if it accessed it through `self`, the compiler would demand full
        // initialization before the first field is set.
        let selected = wish.flatMap { available.contains($0) ? $0 : nil }
            ?? Self.languageRequests(from: ProcessInfo.processInfo.environment,
                                   system: Self.systemLanguages())
            .first { available.contains($0) } ?? bundle.developmentLocalization ?? "de"
        language = selected
        requests = wish.map { [$0] }
            ?? Self.languageRequests(from: ProcessInfo.processInfo.environment,
                                   system: Self.systemLanguages())
        availableLanguages = available.sorted()

        func file(_ suffix: String) -> NSDictionary? {
            guard let url = bundle.url(forResource: "Localizable", withExtension: suffix,
                                       subdirectory: nil, localization: selected)
            else { return nil }
            return NSDictionary(contentsOf: url)
        }

        entries = (file("strings") as? [String: String]) ?? [:]

        var rules: [String: MoreNumberRule] = [:]
        if let raw = file("stringsdict") {
            for key in raw.allKeys.compactMap({ $0 as? String }) {
                guard let detail = raw[key] as? NSDictionary,
                      let format = detail["NSStringLocalizedFormatKey"] as? String
                else { continue }
                var variables: [String: [String: String]] = [:]
                for name in detail.allKeys.compactMap({ $0 as? String })
                where name != "NSStringLocalizedFormatKey" {
                    guard let inner = detail[name] as? NSDictionary else { continue }
                    var categoryTags: [String: String] = [:]
                    for k in inner.allKeys.compactMap({ $0 as? String })
                    where !k.hasPrefix("NSStringFormat") {
                        if let wording = inner[k] as? String { categoryTags[k] = wording }
                    }
                    variables[name] = categoryTags
                }
                rules[key] = MoreNumberRule(format: format, variables: variables)
            }
        }
        plural = rules
    }

    // MARK: Lookup

    /// The translated text, or the key if nothing is there.
    public func text(_ key: TextKey) -> String {
        let preStatus = moreNumberPreStatus(key)
            ?? entries[key.format]
            ?? key.format
        guard !key.arguments.isEmpty else { return preStatus }
        return String(format: preStatus, arguments: key.arguments.map(\.asFormatArgument))
    }

    /// The plural form, if the key is in the `stringsdict`.
    ///
    /// **Only the case we have: one variable, one number.** The catalog contains
    /// exactly one such entry (`%lld neue Folgen`). Several variables in one
    /// sentence would not come out right without the full CLDR rules anyway; they
    /// therefore fall back to the plain translation instead of being guessed.
    ///
    /// **The category comes from ``PluralCategory``**, per language: Russian needs
    /// three forms where German and English need two. A missing category falls back
    /// to `other`.
    private func moreNumberPreStatus(_ key: TextKey) -> String? {
        guard let rule = plural[key.format],
              rule.variables.count == 1,
              let (name, categoryTags) = rule.variables.first,
              case let numbers = key.arguments.compactMap({
                  if case let .figure(w) = $0 { w } else { nil }
              }),
              numbers.count == 1, let figure = numbers.first
        else { return nil }

        guard let wording = categoryTags[PluralCategory.of(figure, language: language)]
                ?? categoryTags["other"]
        else { return nil }
        return rule.format.replacingOccurrences(of: "%#@\(name)@", with: wording)
    }
}
#endif
