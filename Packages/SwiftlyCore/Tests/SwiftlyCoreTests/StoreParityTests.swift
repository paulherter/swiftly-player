import Foundation
import Security
import Testing

@testable import SwiftlyCore

/// Data written by the OLD code paths (UserDefaults strings, `liste.json`, Keychain entries made like
/// `Sources/Shared/Keychain.swift`) must be read by the core's stores, and what the core writes must be
/// read by the old code.
@Suite("Store parity (old and new read each other)")
struct StoreParityTests {
    private func suite() -> (UserDefaults, String) {
        let name = "swiftly.parity.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("parity-\(UUID().uuidString)")
    }

    // MARK: Sort, filter, search history (plain strings)

    @Test func oldStringsAreReadByTheCore() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        // What `LibraryModel` / `SearchHistoryStore` wrote.
        defaults.set("bewertung", forKey: "sortierung.filme")
        defaults.set("angefangen", forKey: "filter.filme")
        defaults.set("Matrix\nAlien", forKey: "letzteSuchen")
        defaults.set("Dune", forKey: "letzteSuchen.konto1")
        let store = UserDefaultsKeyValueStore(defaults: defaults, downloadsFolder: folder())
        #expect(store.get(key: "sortierung.filme").map { String(decoding: $0, as: UTF8.self) } == "bewertung")
        #expect(store.get(key: "filter.filme").map { String(decoding: $0, as: UTF8.self) } == "angefangen")
        #expect(store.get(key: "letzteSuchen").map { String(decoding: $0, as: UTF8.self) } == "Matrix\nAlien")
        #expect(store.get(key: "letzteSuchen.konto1").map { String(decoding: $0, as: UTF8.self) } == "Dune")
    }

    @Test func coreStringsAreReadByTheOldCode() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsKeyValueStore(defaults: defaults, downloadsFolder: folder())
        store.set(key: "sortierung.filme", value: Data("neueste".utf8))
        store.set(key: "filter.filme", value: Data("alle".utf8))
        store.set(key: "letzteSuchen.konto1", value: Data("Heat\nCasino".utf8))
        store.flush()
        // Old code reads `string(forKey:)`, never `data(forKey:)`.
        #expect(defaults.string(forKey: "sortierung.filme") == "neueste")
        #expect(defaults.string(forKey: "filter.filme") == "alle")
        #expect(defaults.string(forKey: "letzteSuchen.konto1") == "Heat\nCasino")
        #expect(defaults.object(forKey: "core.sortierung.filme") == nil)
        store.remove(key: "filter.filme")
        store.flush()
        #expect(defaults.object(forKey: "filter.filme") == nil)
    }

    // MARK: Pending reports

    @Test func pendingReportsShareTheOldKey() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let old = Data(#"[{"id":"x"}]"#.utf8)
        defaults.set(old, forKey: "nachmeldungen")
        let store = UserDefaultsKeyValueStore(defaults: defaults, downloadsFolder: folder())
        #expect(store.get(key: "pending.reports") == old)
        let new = Data(#"[]"#.utf8)
        store.set(key: "pending.reports", value: new)
        store.flush()
        #expect(defaults.data(forKey: "nachmeldungen") == new)
    }

    // MARK: Track memory (dictionaries)

    @Test func trackMemoryIsTheOldDictionary() throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["acct|s1": "", "s2": #"{"language":"deu"}"#], forKey: "utJeTitel")
        let store = UserDefaultsKeyValueStore(defaults: defaults, downloadsFolder: folder())
        let read = try JSONSerialization.jsonObject(with: #require(store.get(key: "trackmemory.utJeTitel")))
        #expect(read as? [String: String] == ["acct|s1": "", "s2": #"{"language":"deu"}"#])
        #expect(store.get(key: "trackmemory.tonJeTitel") == nil)
        store.set(key: "trackmemory.tonJeTitel", value: Data(#"{"acct|s1":"Deutsch"}"#.utf8))
        store.flush()
        // What the old `TrackMemory` reads.
        #expect(defaults.dictionary(forKey: "tonJeTitel") as? [String: String] == ["acct|s1": "Deutsch"])
        #expect(store.get(key: "trackmemory.tonJeTitel").flatMap { String(data: $0, encoding: .utf8) } == #"{"acct|s1":"Deutsch"}"#)
    }

    // MARK: Downloads list file

    @Test func downloadsListIsTheOldFile() throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let list = Data(#"[{"konto":"a","titel":"T","stand":"fertig","art":"film"}]"#.utf8)
        try list.write(to: dir.appendingPathComponent("liste.json"))
        let store = UserDefaultsKeyValueStore(defaults: defaults, downloadsFolder: dir)
        #expect(store.get(key: "downloads.list") == list)

        let new = Data(#"[{"konto":"a","titel":"U"}]"#.utf8)
        store.set(key: "downloads.list", value: new)
        store.flush()
        #expect(try Data(contentsOf: dir.appendingPathComponent("liste.json")) == new)
        #expect(defaults.object(forKey: "core.downloads.list") == nil)
        #expect(defaults.object(forKey: "downloads.list") == nil)
    }

    @Test func brokenListIsKeptAndCountsAsEmpty() throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("liste.json"))
        let store = UserDefaultsKeyValueStore(defaults: defaults, downloadsFolder: dir)
        #expect(store.get(key: "downloads.list") == nil)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("liste.defekt.json").path))
    }

    @Test func coreOnlyKeysStayApart() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsKeyValueStore(defaults: defaults, downloadsFolder: folder())
        store.set(key: "home.snapshot", value: Data([1, 2]))
        store.flush()
        #expect(defaults.data(forKey: "core.home.snapshot") == Data([1, 2]))
        #expect(store.get(key: "home.snapshot") == Data([1, 2]))
    }

    // MARK: Settings types

    @Test func settingsKeepTheAppStorageTypes() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "introAbspannAuto")
        defaults.set(15, forKey: "zurueckSek")
        defaults.set(0.5, forKey: "playerLautstaerke")
        defaults.set("de", forKey: "sprache")
        let store = UserDefaultsSettingsStore(defaults: defaults)
        #expect(store.get(key: "introAbspannAuto") == .bool(value: true))
        #expect(store.get(key: "zurueckSek") == .int(value: 15))
        #expect(store.get(key: "playerLautstaerke") == .double(value: 0.5))
        #expect(store.get(key: "sprache") == .text(value: "de"))
        store.set(key: "zurueckSek", value: .int(value: 30))
        store.set(key: "vorSek", value: .int(value: 10))
        store.set(key: "flag", value: .bool(value: false))
        store.flush()
        #expect(defaults.integer(forKey: "zurueckSek") == 30)
        #expect(defaults.integer(forKey: "vorSek") == 10)
        #expect(defaults.object(forKey: "flag") as? Bool == false)
    }

    // MARK: Keychain

    /// The query `Sources/Shared/Keychain.swift` builds (macOS: file keychain here, since the unsigned
    /// test host has no data-protection entitlement).
    private func oldQuery(_ service: String, _ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    @Test func keychainReadsOldEntriesAndOldCodeReadsNew() {
        let service = "swiftly.parity.\(UUID().uuidString)"
        let secrets = KeychainSecretStore(service: service, dataProtection: false)
        defer {
            secrets.remove(name: "konten")
            secrets.remove(name: "aktiveArt")
        }
        // Old build wrote the bundle like `Keychain.save`.
        var add = oldQuery(service, "konten")
        add[kSecValueData as String] = Data(#"{"konten":[]}"#.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            Issue.record("keychain not usable in this test host")
            return
        }
        #expect(secrets.get(name: "konten") == #"{"konten":[]}"#)

        // The core overwrites it (update path, never delete first) and the old reader sees the new value.
        secrets.set(name: "konten", value: #"{"konten":[1]}"#)
        var read = oldQuery(service, "konten")
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        #expect(SecItemCopyMatching(read as CFDictionary, &out) == errSecSuccess)
        #expect((out as? Data).map { String(decoding: $0, as: UTF8.self) } == #"{"konten":[1]}"#)

        // A new entry carries the old access class, with exactly one entry per key.
        secrets.set(name: "aktiveArt", value: "jellyfin")
        var attrs = oldQuery(service, "aktiveArt")
        attrs[kSecReturnAttributes as String] = true
        attrs[kSecMatchLimit as String] = kSecMatchLimitOne
        var info: CFTypeRef?
        #expect(SecItemCopyMatching(attrs as CFDictionary, &info) == errSecSuccess)
        let dict = info as? [String: Any]
        // The Mac file keychain keeps no accessibility class; iOS and tvOS (and the data-protection keychain) do.
        #if !os(macOS)
        #expect(dict?[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #endif
        #expect(dict?[kSecAttrService as String] as? String == service)
        #expect(dict?[kSecAttrAccount as String] as? String == "aktiveArt")

        // Remove: gone for the old reader as well.
        secrets.remove(name: "aktiveArt")
        #expect(secrets.get(name: "aktiveArt") == nil)
        #expect(SecItemCopyMatching(oldQuery(service, "aktiveArt") as CFDictionary, nil) == errSecItemNotFound)
    }

    @Test func keychainDefaultServiceIsTheAppsService() {
        let mirror = Mirror(reflecting: KeychainSecretStore())
        #expect(mirror.children.first { $0.label == "service" }?.value as? String == "de.paulherter.swiftly")
        #expect(mirror.children.first { $0.label == "accessGroup" }?.value as? String == nil)
    }

    // MARK: Own headers

    @Test func prepareHookAddsTheOwnHeaders() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        let client = URLSessionHttpClient(prepare: { $0.setValue("own-gateway", forHTTPHeaderField: "Authorization") })
        let request = NetRequest(
            method: .get, url: server.address + "/System/Info/Public", headers: [], body: nil, timeoutMs: 5000)
        _ = try await client.send(request: request)
        #expect(server.seen.last?.authorization == "own-gateway")
    }
}
