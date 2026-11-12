import Foundation
import Security

/// `KeyValueStore` over `UserDefaults` and the downloads folder (ARCHITECTURE.md D3, Storage).
///
/// **The core never owns a second copy**: the keys
/// the Swift code wrote before the core existed stay where and what they were, so the old and the new
/// build read each other's data.
///
///  - `sortierung.*`, `filter.*`, `letzteSuchen`, `letzteSuchen.<account>`: a plain `String` under
///    the same key (what `LibraryModel` and `SearchHistoryStore` stored).
///  - `pending.reports`: the JSON `Data` under `nachmeldungen` (the unsent play reports).
///  - `trackmemory.utJeTitel`, `trackmemory.tonJeTitel`: the dictionaries `TrackMemory` keeps under
///    `utJeTitel` / `tonJeTitel` (title key to track name or imprint JSON; empty means "off"); the core
///    sees them as one JSON object, so the old and the new build read and write the same entries.
///  - `downloads.list`: the file `Application Support/Downloads/liste.json` (`DownloadManager`).
///  - everything else (home snapshot ...): `Data` under `<prefix><key>`; only a cache, core-only.
public final class UserDefaultsKeyValueStore: KeyValueStore {
    // `UserDefaults` is documented thread-safe but not marked `Sendable` in the SDK.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let prefix: String
    private let downloadsFolder: URL

    /// Where a core key lives.
    enum Place: Equatable {
        case text(String)
        case data(String)
        case file(URL)
        /// A `[String: String]` dictionary in `UserDefaults`; the core's value is its JSON object.
        case map(String)
        /// A typed value the app always kept under this plain `UserDefaults` key (support and look records);
        /// the core's packed byte form of it is made and taken apart here.
        case legacy(String)
    }

    /// The `UserDefaults` keys of the support and look records, which the core reaches as `setting.<key>`.
    static let legacyKeys: Set<String> = [
        "support.status", "support.usage", "support.promptHistory", "support.plan",
        "look.selection", "look.owned", "look.gift.offered", "look.effects",
    ]

    /// - Parameters:
    ///   - defaults: the suite to use.
    ///   - prefix: put in front of every core-only key, so the core's values stay apart from the app's.
    ///   - downloadsFolder: the folder of `liste.json`; `nil` is `Application Support/Downloads`.
    public init(defaults: UserDefaults = .standard, prefix: String = "core.", downloadsFolder: URL? = nil) {
        self.defaults = defaults
        self.prefix = prefix
        self.downloadsFolder = downloadsFolder ?? Self.defaultDownloadsFolder()
    }

    /// The same folder as `DownloadManager.folder()`, made only when something is written.
    public static func defaultDownloadsFolder() -> URL {
        let base =
            (try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL.temporaryDirectory
        return base.appendingPathComponent("Downloads", isDirectory: true)
    }

    func place(_ key: String) -> Place {
        if key.hasPrefix("setting."), Self.legacyKeys.contains(String(key.dropFirst(8))) {
            return .legacy(String(key.dropFirst(8)))
        }
        if key.hasPrefix("sortierung.") || key.hasPrefix("filter.") || key == "letzteSuchen"
            || key.hasPrefix("letzteSuchen.")
        {
            return .text(key)
        }
        if key == "pending.reports" { return .data("nachmeldungen") }
        if key == "trackmemory.utJeTitel" { return .map("utJeTitel") }
        if key == "trackmemory.tonJeTitel" { return .map("tonJeTitel") }
        if key == "downloads.list" { return .file(downloadsFolder.appendingPathComponent("liste.json")) }
        return .data(prefix + key)
    }

    // **Writes must not block the caller.** The core calls `set` while it holds its own lock, and
    // `UserDefaults.set` posts a notification that waits for the main thread; the main thread in
    // turn waits for that lock (the freeze on the first Rust build). So writes land in a small
    // cache at once and reach `UserDefaults` from a background queue, in order.
    private let lock = NSLock()
    private nonisolated(unsafe) var pending: [String: Data?] = [:]
    private let queue = DispatchQueue(label: "de.paulherter.swiftly.core-store")

    public func get(key: String) -> Data? {
        lock.lock()
        let hit = pending[key]
        lock.unlock()
        if let hit { return hit }
        switch place(key) {
        case .text(let name): return defaults.string(forKey: name).map { Data($0.utf8) }
        case .data(let name): return defaults.data(forKey: name)
        case .file(let url): return Self.readList(url)
        case .map(let name):
            guard let all = defaults.dictionary(forKey: name) as? [String: String] else { return nil }
            return try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys])
        case .legacy(let name):
            return UserDefaultsSettingsStore.read(defaults.object(forKey: name)).map(Self.pack)
        }
    }

    /// The core's packed form of a typed value (`settings.rs`: a tag byte, then the body).
    static func pack(_ value: SettingValue) -> Data {
        var out = Data()
        switch value {
        case .bool(let v): out.append(contentsOf: [UInt8(ascii: "b"), v ? 1 : 0])
        case .int(let v): out.append(UInt8(ascii: "i")); withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) }
        case .double(let v):
            out.append(UInt8(ascii: "d")); withUnsafeBytes(of: v.bitPattern.littleEndian) { out.append(contentsOf: $0) }
        case .text(let v): out.append(UInt8(ascii: "s")); out.append(Data(v.utf8))
        case .data(let v): out.append(UInt8(ascii: "x")); out.append(v)
        case .list(let v): out.append(UInt8(ascii: "l")); out.append(Data(v.joined(separator: "\u{1f}").utf8))
        case .map(let v):
            out.append(UInt8(ascii: "m"))
            out.append(Data(v.sorted { $0.key < $1.key }.map { "\($0.key)\u{1e}\($0.value)" }.joined(separator: "\u{1f}").utf8))
        }
        return out
    }

    /// The reverse of `pack`; `nil` for a form this store does not know.
    static func unpack(_ data: Data) -> SettingValue? {
        guard let tag = data.first else { return nil }
        let body = data.dropFirst()
        let text = String(decoding: body, as: UTF8.self)
        switch tag {
        case UInt8(ascii: "b"): return body.first.map { .bool(value: $0 != 0) }
        case UInt8(ascii: "i"):
            guard body.count == 8 else { return nil }
            return .int(value: Int64(littleEndian: body.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }))
        case UInt8(ascii: "d"):
            guard body.count == 8 else { return nil }
            return .double(value: Double(bitPattern: UInt64(littleEndian: body.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })))
        case UInt8(ascii: "s"): return .text(value: text)
        case UInt8(ascii: "x"): return .data(value: Data(body))
        case UInt8(ascii: "l"): return .list(value: text.isEmpty ? [] : text.components(separatedBy: "\u{1f}"))
        default: return nil
        }
    }

    public func set(key: String, value: Data) { write(key, value) }
    public func remove(key: String) { write(key, nil) }

    /// Waits until every write has reached its place (tests, app suspension).
    public func flush() { queue.sync {} }

    private func write(_ key: String, _ value: Data?) {
        lock.lock()
        pending[key] = .some(value)
        lock.unlock()
        queue.async { [self] in
            switch place(key) {
            case .text(let name):
                if let value { defaults.set(String(decoding: value, as: UTF8.self), forKey: name) }
                else { defaults.removeObject(forKey: name) }
            case .data(let name):
                if let value { defaults.set(value, forKey: name) } else { defaults.removeObject(forKey: name) }
            case .file(let url):
                if let value { Self.writeList(value, to: url) } else { try? FileManager.default.removeItem(at: url) }
            case .legacy(let name):
                if let value, let typed = Self.unpack(value) { UserDefaultsSettingsStore.store(typed, name, defaults) }
                else { defaults.removeObject(forKey: name) }
            case .map(let name):
                if let value, let all = (try? JSONSerialization.jsonObject(with: value)) as? [String: String] {
                    defaults.set(all, forKey: name)
                } else if value == nil {
                    defaults.removeObject(forKey: name)
                }
            }
            lock.lock()
            // A newer write to the same key stays pending until its own turn.
            if pending[key] == .some(value) { pending[key] = nil }
            lock.unlock()
        }
    }

    /// `DownloadManager`'s rule: a list that does not parse is kept as `liste.defekt.json` and counts
    /// as empty, so the next write does not destroy the evidence.
    private static func readList(_ url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if (try? JSONSerialization.jsonObject(with: data)) is [Any] { return data }
        let broken = url.deletingLastPathComponent().appendingPathComponent("liste.defekt.json")
        try? FileManager.default.removeItem(at: broken)
        try? FileManager.default.copyItem(at: url, to: broken)
        return nil
    }

    /// Atomic, in the downloads folder, which stays out of the backup (the folder, not the files).
    private static func writeList(_ data: Data, to url: URL) {
        var folder = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        try? data.write(to: url, options: .atomic)
    }
}

/// `SecretStore` over the Keychain (generic passwords), **the same entries as the app's `Keychain`
/// wrapper** (`Sources/Shared/Keychain.swift`): service `de.paulherter.swiftly`, no access group (the
/// first one of the entitlements), `AfterFirstUnlockThisDeviceOnly`, on the Mac the data-protection
/// keychain with a one-time migration from the old file keychain, add first and update on a duplicate
/// (never delete first, so a kill in between cannot leave no entry), and delete in both keychains.
public final class KeychainSecretStore: SecretStore {
    private let service: String
    private let accessGroup: String?
    private let dataProtection: Bool

    /// - Parameter dataProtection: Mac only; `false` skips the data-protection keychain and the migration
    ///   (an unsigned test host has no entitlement for it).
    public init(service: String = "de.paulherter.swiftly", accessGroup: String? = nil, dataProtection: Bool = true) {
        self.service = service
        self.accessGroup = accessGroup
        self.dataProtection = dataProtection
    }

    func query(_ name: String, oldCache: Bool = false) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        #if os(macOS)
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = !oldCache }
        #endif
        return query
    }

    public func get(name: String) -> String? {
        if let data = read(name) { return String(data: data, encoding: .utf8) }
        #if os(macOS)
        // One-time migration; the old entry stays, so an older version keeps its login.
        guard dataProtection, let old = read(name, oldCache: true) else { return nil }
        _ = save(old, name)
        return String(data: old, encoding: .utf8)
        #else
        return nil
        #endif
    }

    public func set(name: String, value: String) { _ = save(Data(value.utf8), name) }

    public func remove(name: String) {
        SecItemDelete(query(name) as CFDictionary)
        #if os(macOS)
        if dataProtection { SecItemDelete(query(name, oldCache: true) as CFDictionary) }
        #endif
    }

    private func read(_ name: String, oldCache: Bool = false) -> Data? {
        var request = query(name, oldCache: oldCache)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &found) == errSecSuccess else { return nil }
        return found as? Data
    }

    @discardableResult
    func save(_ data: Data, _ name: String) -> OSStatus {
        var add = query(name)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let new: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            status = SecItemUpdate(query(name) as CFDictionary, new as CFDictionary)
        }
        return status
    }
}

/// `SettingsStore` over `UserDefaults`: the same keys and types the `@AppStorage` screens use
/// (`introAbspannAuto` is a Bool, `zurueckSek` an Int, `playerLautstaerke` a Double ...), so the
/// core's `SettingsVm` and the Swift screens share one set of values. Pass the app-group suite
/// where the app keeps a setting there; today's settings live in `.standard`.
public final class UserDefaultsSettingsStore: SettingsStore {
    private nonisolated(unsafe) let defaults: UserDefaults

    // Same rule as `UserDefaultsKeyValueStore`: the core calls `set` while it holds its own lock,
    // and `UserDefaults.set` can wait for the main thread. Writes land in a cache at once and
    // reach `UserDefaults` from a background queue, in order.
    private let lock = NSLock()
    private nonisolated(unsafe) var pending: [String: SettingValue?] = [:]
    private let queue = DispatchQueue(label: "de.paulherter.swiftly.core-settings")

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func get(key: String) -> SettingValue? {
        lock.lock()
        let hit = pending[key]
        lock.unlock()
        if let hit { return hit }
        return Self.read(defaults.object(forKey: key))
    }

    public func set(key: String, value: SettingValue) { write(key, value) }
    public func remove(key: String) { write(key, nil) }

    public func keys() -> [String] {
        lock.lock()
        let overlay = pending
        lock.unlock()
        var all = Set(defaults.dictionaryRepresentation().keys)
        for (key, value) in overlay { if value == nil { all.remove(key) } else { all.insert(key) } }
        return all.sorted()
    }

    /// Waits until every write has reached `UserDefaults` (tests, app suspension).
    public func flush() { queue.sync {} }

    private func write(_ key: String, _ value: SettingValue?) {
        lock.lock()
        pending[key] = .some(value)
        lock.unlock()
        queue.async { [self] in
            if let value { Self.store(value, key, defaults) } else { defaults.removeObject(forKey: key) }
            lock.lock()
            if pending[key] == .some(value) { pending[key] = nil }
            lock.unlock()
        }
    }

    static func read(_ object: Any?) -> SettingValue? {
        switch object {
        case nil: return nil
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(value: number.boolValue) }
            switch String(cString: number.objCType) {
            case "d", "f": return .double(value: number.doubleValue)
            default: return .int(value: number.int64Value)
            }
        case let text as String: return .text(value: text)
        case let data as Data: return .data(value: data)
        case let list as [String]: return .list(value: list)
        case let map as [String: String]: return .map(value: map)
        default: return nil
        }
    }

    static func store(_ value: SettingValue, _ key: String, _ defaults: UserDefaults) {
        switch value {
        case .bool(let v): defaults.set(v, forKey: key)
        case .int(let v): defaults.set(Int(v), forKey: key)
        case .double(let v): defaults.set(v, forKey: key)
        case .text(let v): defaults.set(v, forKey: key)
        case .data(let v): defaults.set(v, forKey: key)
        case .list(let v): defaults.set(v, forKey: key)
        case .map(let v): defaults.set(v, forKey: key)
        }
    }
}
