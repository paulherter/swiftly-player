import Foundation
import OSLog
import Security

/// Minimaler Keychain-Zugriff für das Access-Token.
/// Bewusst nicht UserDefaults: der Token ist ein vollwertiger Serverzugang.
enum Keychain {
    private static let log = Logger(subsystem: "de.paulherter.swiftly", category: "keychain")
    private static let service = "de.paulherter.swiftly"

    enum Fehler: Error, CustomStringConvertible {
        case schreiben(OSStatus)
        case lesen(OSStatus)

        var description: String {
            switch self {
            case let .schreiben(s): "Keychain schreiben fehlgeschlagen: \(Keychain.text(s))"
            case let .lesen(s):     "Keychain lesen fehlgeschlagen: \(Keychain.text(s))"
            }
        }
    }

    static func text(_ status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    }

    /// Wirft, statt still zu scheitern — sonst merkt man erst beim nächsten
    /// Start, dass nichts gespeichert wurde.
    static func save(_ data: Data, key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)

        var add = query
        add[kSecValueData as String] = data
        // AfterFirstUnlock, nicht WhenUnlocked: die App spielt mit dem
        // Audio-Hintergrundmodus weiter, während das Gerät gesperrt ist, und
        // meldet dabei den Fortschritt. Solange die Sitzung im Speicher liegt,
        // geht das auch mit WhenUnlocked gut — aber sobald etwas die App im
        // gesperrten Zustand neu startet, wäre der Eintrag unlesbar und die
        // Anmeldung weg. `ThisDeviceOnly` hält ihn aus fremden Sicherungen
        // heraus: ein Serverzugang gehört nicht auf ein anderes Gerät.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw Fehler.schreiben(status) }
    }

    static func load(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status != errSecSuccess, status != errSecItemNotFound {
            log.error("Lesen: \(text(status), privacy: .public)")
        }
        return out as? Data
    }

    static func delete(key: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ] as CFDictionary)
    }
}
