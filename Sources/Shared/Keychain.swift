import Foundation
import OSLog
import Security

/// Minimal Keychain access for the access token.
/// Deliberately not UserDefaults: the token is a full server credential.
///
/// **On the Mac there are two keychains, which is the reason for half this
/// file.** The old, file-based one ties the right to **modify** an entry to the
/// signature of the program that created it. The newer one, the only one on iOS
/// and tvOS, ties it to the access group from the entitlements.
///
/// This cost an evening: Apple required the Mac app to be named `Swiftly`
/// instead of `Swiftly-macOS`. After the rename it was a different program from
/// the old keychain's point of view. **Reading still worked, writing did not**,
/// and `save` failed silently in a `catch` while `load` kept returning the old
/// state. It showed up as "the app does not remember the chosen profile": the
/// switch was in memory, the keychain kept the old pointer.
///
/// It is not just us. **Every Mac user updating from build <= 8 has an entry
/// from `Swiftly-macOS`**: they stay signed in, but every change to the account
/// would be silently lost. On a fresh machine none of this is visible, which is
/// why it would have survived any check done on a new machine.
enum Keychain {
    private static let log = Logger(subsystem: "de.paulherter.swiftly", category: "keychain")
    private static let service = "de.paulherter.swiftly"

    enum Failure: Error, CustomStringConvertible {
        case write(OSStatus)
        case read(OSStatus)

        var description: String {
            switch self {
            case let .write(s): "Keychain schreiben fehlgeschlagen: \(Keychain.text(s))"
            case let .read(s):     "Keychain lesen fehlgeschlagen: \(Keychain.text(s))"
            }
        }
    }

    static func text(_ status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    }

    /// The base query, explicitly for the keychain tied to the access group on the
    /// Mac.
    ///
    /// **`kSecUseDataProtectionKeychain` exists only on the Mac.** On iOS and tvOS
    /// this keychain is the only one; the key would have no effect there, and the
    /// `#if` says exactly that instead of leaving it unsaid.
    private static func query(_ key: String, oldCache: Bool = false) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        #if os(macOS)
        q[kSecUseDataProtectionKeychain as String] = !oldCache
        #endif
        return q
    }

    /// Throws instead of failing silently; otherwise you only notice at the next
    /// launch that nothing was saved.
    static func save(_ data: Data, key: String) throws {
        let query = query(key)

        var add = query
        add[kSecValueData as String] = data
        // AfterFirstUnlock, not WhenUnlocked: the app keeps playing with the audio
        // background mode while the device is locked, and reports progress meanwhile.
        // As long as the session is in memory that works with WhenUnlocked too, but as
        // soon as something restarts the app in the locked state, the entry would be
        // unreadable and the login gone. `ThisDeviceOnly` keeps it out of foreign
        // backups: a server credential does not belong on another device.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        // **Create, and overwrite an existing entry; never delete first.**
        //
        // A `SecItemDelete` used to precede this. Between delete and create there is a
        // window of a few microseconds, and anyone terminated in exactly that window
        // (memory pressure, crash, iOS kill) ends up with **no** entry rather than a
        // stale one. The user sees the login screen and does not know why. That is the
        // costliest imaginable outcome for the cheapest imaginable cause.
        //
        // The deletion still had a purpose, and it is not lost: it made sure an old
        // entry got today's protection level. `SecItemUpdate` only changes what it is
        // told, which is why `kSecAttrAccessible` is listed explicitly here. Without it,
        // an entry from an older version would silently keep its old level.
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let new: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            status = SecItemUpdate(query as CFDictionary, new as CFDictionary)
        }
        guard status == errSecSuccess else { throw Failure.write(status) }
    }

    static func load(key: String) -> Data? {
        if let data = read(key) { return data }

        #if os(macOS)
        // **One-time migration.** Nothing is in the new store, perhaps something in the
        // old one, then it should be brought here. The old entry stays: someone who
        // starts an older version again should not suddenly be signed out. The same
        // form as taking over the single session in `AppModel.loadBundle()`.
        guard let alt = read(key, oldCache: true) else { return nil }
        log.info("Umzug aus dem alten Schlüsselbund: \(key, privacy: .public)")
        do {
            try save(alt, key: key)
        } catch {
            // The migration is an improvement, not a requirement. If it fails, whatever is
            // in the old store still applies; reading always worked there.
            log.error("Umzug fehlgeschlagen: \(String(describing: error), privacy: .public)")
        }
        return alt
        #else
        return nil
        #endif
    }

    private static func read(_ key: String, oldCache: Bool = false) -> Data? {
        var query = query(key, oldCache: oldCache)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status != errSecSuccess, status != errSecItemNotFound {
            log.error("Lesen: \(text(status), privacy: .public)")
        }
        return out as? Data
    }

    /// Deletes in **both** stores.
    ///
    /// Otherwise the old entry would remain after signing out and the next launch
    /// would bring it back via the migration, leaving the user signed in again
    /// without doing anything.
    static func delete(key: String) {
        SecItemDelete(query(key) as CFDictionary)
        #if os(macOS)
        SecItemDelete(query(key, oldCache: true) as CFDictionary)
        #endif
    }
}
