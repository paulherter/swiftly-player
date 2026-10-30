import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// **Settings that follow the Jellyfin account from device to device.**
///
/// No plugin: the server's own display preferences (`DisplayPreferences`) carry
/// them, under a client name of our own so the web client's data stays untouched.
/// Everything here is pure logic (keys, encoding, who wins), so it is tested without
/// a simulator and the Android version can take the same rules.
///
/// The key list and the encoding are written down in
/// `Documentation/settings-sync.md`. Change both together.
public enum SettingsSync {

    /// Display preferences ID and client name on the server. The client column holds
    /// 32 characters at most.
    public static let displayID = "swiftly"
    public static let clientName = "Swiftly"

    /// Every key of ours starts with this. Keys of other clients (and the ones the
    /// server maps to its own fields) are never touched.
    public static let prefix = "swiftly."
    /// Milliseconds since 1970 of the last change, as text.
    public static let changedKey = prefix + "changed"
    /// Version of this scheme. Written, not yet needed to read.
    public static let formatKey = prefix + "format"
    public static let format = "1"

    /// How a setting is held on the device and written as text.
    public enum Kind: Sendable {
        case bool
        /// Whole number between 0 and 3600.
        case int
        case text
        /// A list of strings, as a JSON array.
        case list
        /// A JSON document that is kept as text (the chosen library rows).
        case json
    }

    /// One synced setting: the name it has on the device (`UserDefaults`) and how it is
    /// encoded. On the server it is stored as `prefix + name`.
    public struct Entry: Sendable, Equatable {
        public let name: String
        public let kind: Kind
        /// The device key carries the server address as a suffix (`|https://…`). The
        /// suffix is not part of the synced name: the preferences live on that server
        /// anyway.
        public let perServer: Bool
    }

    /// **Per user and independent of the device, nothing else.** Wi-Fi only, volume,
    /// fill screen, buffer, counters, debug and everything about downloads stay
    /// on the device.
    public static let entries: [Entry] = [
        // Languages and what happens at the end of a title
        .init(name: "tonSprache", kind: .text, perServer: false),
        .init(name: "utSprache", kind: .text, perServer: false),
        .init(name: "utAuto", kind: .bool, perServer: false),
        .init(name: "naechsteAuto", kind: .bool, perServer: false),
        .init(name: "introAbspannAuto", kind: .bool, perServer: false),
        .init(name: "restzeitAlsEnde", kind: .bool, perServer: false),
        .init(name: "vorSek", kind: .int, perServer: false),
        .init(name: "zurueckSek", kind: .int, perServer: false),
        // Display
        .init(name: "titelAlsLogo", kind: .bool, perServer: false),
        .init(name: "fortschritt", kind: .bool, perServer: false),
        .init(name: "merklisteAn", kind: .bool, perServer: false),
        .init(name: "alphabetAn", kind: .bool, perServer: false),
        .init(name: "neuGetrennt", kind: .bool, perServer: false),
        // Home page
        .init(name: "startReihen", kind: .list, perServer: false),
        .init(name: "startAus", kind: .list, perServer: false),
        .init(name: "genreChips", kind: .bool, perServer: false),
        .init(name: "startGenres", kind: .list, perServer: false),
        .init(name: "startBibliotheken", kind: .json, perServer: true),
    ]

    /// The entry for a name as `UserDefaults` knows it. A server suffix is ignored.
    public static func entry(forDeviceKey key: String) -> Entry? {
        let base = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? key
        return entries.first { $0.name == base }
    }

    // MARK: - Values

    /// A setting's value, independent of where it is stored.
    public enum Value: Sendable, Equatable {
        case bool(Bool)
        case int(Int)
        case text(String)
        case list([String])
        /// The document as UTF-8 data.
        case json(Data)

        /// The text that goes to the server.
        public var encoded: String {
            switch self {
            case .bool(let b): return b ? "true" : "false"
            case .int(let i): return String(i)
            case .text(let s): return s
            case .list(let l):
                let data = (try? JSONEncoder().encode(l)) ?? Data("[]".utf8)
                return String(decoding: data, as: UTF8.self)
            case .json(let d): return String(decoding: d, as: UTF8.self)
            }
        }

        /// Reads a value back. **`nil` for anything that does not fit its kind**, so a
        /// damaged or foreign entry changes nothing instead of something wrong.
        public static func decode(_ text: String, as kind: Kind) -> Value? {
            switch kind {
            case .bool:
                switch text {
                case "true": return .bool(true)
                case "false": return .bool(false)
                default: return nil
                }
            case .int:
                guard let i = Int(text), (0...3600).contains(i) else { return nil }
                return .int(i)
            case .text:
                return .text(text)
            case .list:
                guard let list = try? JSONDecoder().decode([String].self, from: Data(text.utf8))
                else { return nil }
                return .list(list)
            case .json:
                let data = Data(text.utf8)
                guard (try? JSONSerialization.jsonObject(with: data)) != nil else { return nil }
                return .json(data)
            }
        }
    }

    /// Reads the device value of every synced setting that was ever set, keyed by the
    /// synced name. `read` gets the device key (with the server suffix where it
    /// applies) and the kind, and answers `nil` for "never set".
    public static func collect(serverSuffix: String,
                               read: (_ deviceKey: String, _ kind: Kind) -> Value?) -> [String: Value] {
        var result: [String: Value] = [:]
        for e in entries {
            if let v = read(e.name + (e.perServer ? serverSuffix : ""), e.kind) {
                result[e.name] = v
            }
        }
        return result
    }

    // MARK: - Server side

    /// What the server holds: our values and when they were written.
    public struct Remote: Sendable, Equatable {
        public var values: [String: Value]
        public var changed: Date?
        /// Whether our scheme is on the server at all.
        public var present: Bool { changed != nil && !values.isEmpty }
    }

    /// Picks our entries out of the whole `CustomPrefs` and ignores the rest.
    public static func remote(from prefs: [String: String]) -> Remote {
        var values: [String: Value] = [:]
        for e in entries {
            if let text = prefs[prefix + e.name], let v = Value.decode(text, as: e.kind) {
                values[e.name] = v
            }
        }
        let changed = prefs[changedKey].flatMap { Double($0) }
            .map { Date(timeIntervalSince1970: $0 / 1000) }
        return Remote(values: values, changed: changed)
    }

    /// The entries to write: every value plus time and version. Keys the device has not
    /// set are **left out and not removed**, so another device's choice survives.
    public static func fields(for values: [String: Value], changed: Date) -> [String: String] {
        var out: [String: String] = [:]
        for (name, value) in values where entries.contains(where: { $0.name == name }) {
            out[prefix + name] = value.encoded
        }
        out[changedKey] = String(Int64((changed.timeIntervalSince1970 * 1000).rounded()))
        out[formatKey] = format
        return out
    }

    // MARK: - Who wins

    public enum Decision: Sendable, Equatable {
        /// Take the server's values.
        case apply
        /// Write the device's values.
        case push
        case nothing
    }

    /// **Newest change wins, whole set at a time.**
    ///
    /// - `localChanged`: when something was last changed on this device, or taken from
    ///   the server. `nil` if never.
    /// - `otherAccount`: the device last synced with another account (or never). Then
    ///   the server's copy wins whatever the times say: switching to another account
    ///   should show that account's settings, not the previous one's.
    public static func decide(remote: Remote, localChanged: Date?, otherAccount: Bool) -> Decision {
        guard remote.present, let theirs = remote.changed else { return .push }
        if otherAccount { return .apply }
        guard let mine = localChanged else { return .apply }
        // Whole milliseconds: that is all the server holds.
        let a = Int64((theirs.timeIntervalSince1970 * 1000).rounded())
        let b = Int64((mine.timeIntervalSince1970 * 1000).rounded())
        if a > b { return .apply }
        if a < b { return .push }
        return .nothing
    }

    // MARK: - Seerr

    /// **The Seerr connection follows the account too**, but apart from the settings:
    /// it lives in the keychain, not in `UserDefaults`, and it has its own time, so a
    /// sign-in to Seerr on one device does not drag the whole settings set along.
    ///
    /// The value is ``SeerrAccess`` as JSON; an empty text means "disconnected", so a
    /// disconnect travels as well. It sits in the user's own display preferences on
    /// their own server, the place the server already keeps per user.
    public static let seerrKey = prefix + "seerr"
    public static let seerrChangedKey = prefix + "seerrChanged"

    public enum SeerrStep: Sendable, Equatable {
        /// Take the server's connection; `nil` is "disconnected".
        case adopt(SeerrAccess?, changed: Date)
        /// Write the device's connection.
        case push
        case nothing
    }

    /// Newest change wins, as with the settings.
    ///
    /// - `localChanged`: when this device last connected, disconnected or took the
    ///   connection from the server. `nil` if never.
    /// - `hasLocal`: the device holds a connection for this server.
    public static func seerrStep(remote prefs: [String: String], localChanged: Date?,
                                 hasLocal: Bool) -> SeerrStep {
        guard let text = prefs[seerrKey],
              let theirs = prefs[seerrChangedKey].flatMap(Double.init)
                .map({ Date(timeIntervalSince1970: $0 / 1000) }) else {
            return hasLocal ? .push : .nothing
        }
        // A value we cannot read is someone else's mistake, not a disconnect.
        let access: SeerrAccess?
        if text.isEmpty { access = nil }
        else if let read = try? JSONDecoder().decode(SeerrAccess.self, from: Data(text.utf8)) { access = read }
        else { return hasLocal ? .push : .nothing }
        guard let mine = localChanged else {
            // Never touched here: take the server's, unless it would only take away a
            // connection this device has had since before syncing existed.
            return access == nil && hasLocal ? .push : .adopt(access, changed: theirs)
        }
        let a = Int64((theirs.timeIntervalSince1970 * 1000).rounded())
        let b = Int64((mine.timeIntervalSince1970 * 1000).rounded())
        if a > b { return .adopt(access, changed: theirs) }
        if a < b { return .push }
        return .nothing
    }

    /// The fields that write the device's connection.
    public static func seerrFields(_ access: SeerrAccess?, changed: Date) -> [String: String] {
        let text = access.flatMap { try? JSONEncoder().encode($0) }
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        return [seerrKey: text,
                seerrChangedKey: String(Int64((changed.timeIntervalSince1970 * 1000).rounded()))]
    }

    /// The time for a change made now. **Never earlier than what the server already
    /// holds**: a device whose clock runs behind would otherwise lose against its own
    /// earlier write.
    public static func changeTime(now: Date, lastKnownRemote: Date?) -> Date {
        guard let last = lastKnownRemote, last >= now else { return now }
        return last.addingTimeInterval(0.001)
    }
}

// MARK: - The server's display preferences

/// A copy of the server's display preferences for one ID and client.
///
/// **The body is kept as received.** `POST` replaces everything, and the server maps
/// some keys of `CustomPrefs` (and the sorting) onto fields of its own; sending back
/// only our part would reset those.
public struct DisplayPreferencesCopy: Sendable {
    let body: Data

    init(body: Data) { self.body = body }

    /// `CustomPrefs` as text. Entries that are not text (the server may hold `null`)
    /// are left out here and stay untouched in the body.
    public var customPrefs: [String: String] {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let prefs = object["CustomPrefs"] as? [String: Any] else { return [:] }
        return prefs.compactMapValues { $0 as? String }
    }

    /// The body to send: everything as received, with `fields` written into
    /// `CustomPrefs`.
    func merged(setting fields: [String: String]) throws -> Data {
        var object = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        var prefs = (object["CustomPrefs"] as? [String: Any]) ?? [:]
        for (key, value) in fields { prefs[key] = value }
        object["CustomPrefs"] = prefs
        return try JSONSerialization.data(withJSONObject: object)
    }
}

public extension JellyfinClient {

    /// Fetches the display preferences. **Throws like any request**; the caller decides
    /// whether that matters. A server that does not know the ID creates and returns an
    /// empty set.
    func displayPreferences(id: String = SettingsSync.displayID,
                            client: String = SettingsSync.clientName) async throws -> DisplayPreferencesCopy {
        let s = try requireSessionForReporting()
        let req = try rawRequest("DisplayPreferences/\(id)", method: "GET", query: [
            .init(name: "userId", value: s.userID),
            .init(name: "client", value: client),
        ])
        let data: Data
        let response: URLResponse
        do { (data, response) = try await rawSession.data(for: req) }
        catch { throw JellyfinError(petition: error) }
        guard let http = response as? HTTPURLResponse else {
            throw JellyfinError.transport("Keine HTTP-Antwort.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw JellyfinError.http(status: http.statusCode,
                                     body: String(data: data.prefix(300), encoding: .utf8))
        }
        guard (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) != nil else {
            throw JellyfinError.decoding("DisplayPreferences")
        }
        return DisplayPreferencesCopy(body: data)
    }

    /// Writes `fields` into the display preferences, **on top of a copy fetched just
    /// before** (`copy`), so the rest of the set survives.
    func saveDisplayPreferences(_ copy: DisplayPreferencesCopy, setting fields: [String: String],
                                id: String = SettingsSync.displayID,
                                client: String = SettingsSync.clientName) async throws {
        let s = try requireSessionForReporting()
        var req = try rawRequest("DisplayPreferences/\(id)", method: "POST", query: [
            .init(name: "userId", value: s.userID),
            .init(name: "client", value: client),
        ])
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try copy.merged(setting: fields)
        try await sendIgnoringBody(req)
    }
}
