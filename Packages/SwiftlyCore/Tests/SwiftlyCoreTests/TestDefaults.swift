import Foundation

/// The one place a test gets a `UserDefaults` suite (a copy of this file lives in each test target; keep them equal).
///
/// **One fixed, wiped suite per test class, never a UUID or random name.** Every suite a test writes to becomes a
/// persistent domain file in `~/Library/Preferences` that `cfprefsd` keeps a directory handle for. Hundreds of
/// UUID-named suites from repeated runs pushed `cfprefsd` past its file-handle limit ("Too many open files"), and
/// then every app on the Mac stopped reading its settings. With a fixed name a crashed run leaves at most one
/// domain per class, and the next run starts by removing it.
///
/// The suites of one test class share a name, so a class that uses this must be `.serialized` (Swift Testing runs
/// the tests of a suite in parallel otherwise). A test that needs two stores at once gives each its own `slot`.
/// Stores that write from a background queue (`UserDefaultsKeyValueStore`, `UserDefaultsSettingsStore`) must be
/// flushed before the next `make`, or a late write lands in the fresh domain.
enum TestDefaults {
    /// `de.paulherter.swiftly.tests.<Class>` or `de.paulherter.swiftly.tests.<Class>.<slot>`.
    static func name(for type: Any.Type, slot: String? = nil) -> String {
        let base = "de.paulherter.swiftly.tests.\(type)"
        guard let slot else { return base }
        return "\(base).\(slot)"
    }

    /// An empty suite for the test class (whatever an earlier or crashed run left is removed first).
    static func make(for type: Any.Type, slot: String? = nil) -> UserDefaults {
        let name = name(for: type, slot: slot)
        guard let defaults = UserDefaults(suiteName: name) else {
            preconditionFailure("UserDefaults(suiteName: \(name)) is nil")
        }
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// Removes the class's values; call it when the test is done (`defer`, or a suite class's `deinit`).
    /// macOS keeps an empty plist for the name afterwards, which is why the names must be fixed and few.
    static func remove(for type: Any.Type, slot: String? = nil) {
        let name = name(for: type, slot: slot)
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
    }
}
