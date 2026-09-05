import Foundation
import OSLog
import Security

/// Minimaler Keychain-Zugriff für das Access-Token.
/// Bewusst nicht UserDefaults: der Token ist ein vollwertiger Serverzugang.
///
/// **Auf dem Mac gibt es zwei Schlüsselbunde, und das ist der Grund für die
/// halbe Datei.** Der alte, dateibasierte hängt das Recht, einen Eintrag zu
/// **ändern**, an der Signatur des Programms, das ihn angelegt hat. Der
/// neuere — derselbe, den iOS und tvOS als einzigen haben — hängt es an die
/// Zugriffsgruppe aus den Entitlements.
///
/// Am 05.09.2026 hat uns das einen halben Abend gekostet: Apple verlangte,
/// dass die Mac-App nicht mehr `Swiftly-macOS` heißt, sondern `Swiftly`. Nach
/// der Umbenennung war es aus Sicht des alten Schlüsselbunds ein anderes
/// Programm. **Lesen ging weiter, Schreiben nicht** — und `save` scheiterte
/// still in einem `catch`, während `load` weiter den alten Stand lieferte.
/// Sichtbar wurde es als „die App merkt sich das gewählte Profil nicht": der
/// Wechsel stand im Speicher, der Schlüsselbund behielt den alten Zeiger.
///
/// Das trifft nicht nur uns. **Jeder Mac-Nutzer, der von Build ≤ 8
/// aktualisiert, hat einen Eintrag von `Swiftly-macOS`** — angemeldet bleibt
/// er, aber jede Änderung am Konto ginge lautlos verloren. Auf einem frischen
/// Rechner ist davon nichts zu sehen, und genau deshalb hätte es jede Prüfung
/// überstanden, die mit einem neuen Rechner arbeitet.
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

    /// Die Grundabfrage — auf dem Mac ausdrücklich für den Schlüsselbund, der
    /// an der Zugriffsgruppe hängt.
    ///
    /// **`kSecUseDataProtectionKeychain` gibt es nur auf dem Mac.** Auf iOS
    /// und tvOS ist dieser Schlüsselbund der einzige; der Schlüssel wäre dort
    /// wirkungslos, und das `#if` sagt genau das, statt es zu verschweigen.
    private static func abfrage(_ key: String, alterSpeicher: Bool = false) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        #if os(macOS)
        q[kSecUseDataProtectionKeychain as String] = !alterSpeicher
        #endif
        return q
    }

    /// Wirft, statt still zu scheitern — sonst merkt man erst beim nächsten
    /// Start, dass nichts gespeichert wurde.
    static func save(_ data: Data, key: String) throws {
        let query = abfrage(key)
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

        var status = SecItemAdd(add as CFDictionary, nil)
        // **Ein vorhandener Eintrag ist kein Fehlschlag.** Lässt sich der alte
        // nicht löschen — genau der Fall nach einer Umbenennung —, wird er
        // überschrieben statt neu angelegt.
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else { throw Fehler.schreiben(status) }
    }

    static func load(key: String) -> Data? {
        if let daten = lesen(key) { return daten }

        #if os(macOS)
        // **Einmaliger Umzug.** Im neuen Speicher steht nichts, im alten
        // vielleicht schon — dann gehört er hierher geholt. Der alte Eintrag
        // bleibt stehen: wer noch einmal eine ältere Fassung startet, soll
        // nicht plötzlich abgemeldet sein. Dieselbe Form wie die Übernahme
        // der Einzelsitzung in `AppModel.bundLaden()`.
        guard let alt = lesen(key, alterSpeicher: true) else { return nil }
        log.info("Umzug aus dem alten Schlüsselbund: \(key, privacy: .public)")
        do {
            try save(alt, key: key)
        } catch {
            // Der Umzug ist eine Verbesserung, kein Muss. Scheitert er, gilt
            // weiter, was im alten Speicher steht — lesen ging dort immer.
            log.error("Umzug fehlgeschlagen: \(String(describing: error), privacy: .public)")
        }
        return alt
        #else
        return nil
        #endif
    }

    private static func lesen(_ key: String, alterSpeicher: Bool = false) -> Data? {
        var query = abfrage(key, alterSpeicher: alterSpeicher)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status != errSecSuccess, status != errSecItemNotFound {
            log.error("Lesen: \(text(status), privacy: .public)")
        }
        return out as? Data
    }

    /// Löscht in **beiden** Speichern.
    ///
    /// Sonst bliebe nach dem Abmelden der alte Eintrag liegen und der nächste
    /// Start holte ihn über den Umzug zurück — der Nutzer wäre wieder
    /// angemeldet, ohne etwas getan zu haben.
    static func delete(key: String) {
        SecItemDelete(abfrage(key) as CFDictionary)
        #if os(macOS)
        SecItemDelete(abfrage(key, alterSpeicher: true) as CFDictionary)
        #endif
    }
}
