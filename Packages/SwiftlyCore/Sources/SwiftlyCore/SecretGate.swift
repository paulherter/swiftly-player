import Foundation
import Security

/// **The one door to the Keychain for the app's accounts and secrets.**
///
/// `Keychain` (the app's wrapper) and `KeychainSecretStore` (the core's secrets) reach the system only through
/// this type. A DEBUG `-SwiftlyLiveMemory` run (a fixture server on a Mac or device that holds real accounts) keeps
/// everything it writes in this process and reads nothing from the Keychain, so it can neither find nor switch to
/// a stored account (a 401 signs the fixture account out and the app moves on to the next stored account), and never
/// leaves an entry behind. A Release build always uses the system Keychain, and so does every other launch.
///
/// Nothing outside this file may call `SecItem…` for accounts; `SecretGateTests` fails on a new call site.
public final class SecretGate: @unchecked Sendable {
    /// The gate every store of this process uses.
    public static let shared = SecretGate(memoryOnly: ProofIsolation.usesMemoryOnly())

    /// `true`: entries live in this process only and the system Keychain is never called.
    public let memoryOnly: Bool

    private let lock = NSLock()
    private var memory: [String: Data] = [:]

    public init(memoryOnly: Bool) { self.memoryOnly = memoryOnly }

    // MARK: The four calls the stores use (same shape as the `SecItem…` calls they replace)

    public func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        guard memoryOnly else { return SecItemCopyMatching(query, result) }
        guard let slot = Self.slot(query) else { return errSecParam }
        lock.lock()
        let found = memory[slot]
        lock.unlock()
        guard let found else { return errSecItemNotFound }
        if (query as? [String: Any])?[kSecReturnData as String] as? Bool == true { result?.pointee = found as CFData }
        return errSecSuccess
    }

    public func add(_ attributes: CFDictionary) -> OSStatus {
        guard memoryOnly else { return SecItemAdd(attributes, nil) }
        guard let slot = Self.slot(attributes), let data = (attributes as? [String: Any])?[kSecValueData as String] as? Data
        else { return errSecParam }
        lock.lock()
        defer { lock.unlock() }
        guard memory[slot] == nil else { return errSecDuplicateItem }
        memory[slot] = data
        return errSecSuccess
    }

    public func update(_ query: CFDictionary, _ new: CFDictionary) -> OSStatus {
        guard memoryOnly else { return SecItemUpdate(query, new) }
        guard let slot = Self.slot(query) else { return errSecParam }
        lock.lock()
        defer { lock.unlock() }
        guard memory[slot] != nil else { return errSecItemNotFound }
        if let data = (new as? [String: Any])?[kSecValueData as String] as? Data { memory[slot] = data }
        return errSecSuccess
    }

    @discardableResult
    public func delete(_ query: CFDictionary) -> OSStatus {
        guard memoryOnly else { return SecItemDelete(query) }
        guard let slot = Self.slot(query) else { return errSecParam }
        lock.lock()
        defer { lock.unlock() }
        return memory.removeValue(forKey: slot) == nil ? errSecItemNotFound : errSecSuccess
    }

    /// Service, account and which of the two Mac keychains (the old file one is `kSecUseDataProtectionKeychain: false`).
    private static func slot(_ dictionary: CFDictionary) -> String? {
        guard let d = dictionary as? [String: Any], let service = d[kSecAttrService as String] as? String,
              let account = d[kSecAttrAccount as String] as? String else { return nil }
        let old = (d[kSecUseDataProtectionKeychain as String] as? Bool) == false
        return "\(service)\u{1f}\(account)\u{1f}\(old ? "old" : "new")"
    }
}
