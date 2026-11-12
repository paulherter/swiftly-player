import Foundation
import Synchronization
import Testing

import JellyfinKit
@testable import SwiftlyCore

/// An `HttpClient` that answers from a script and keeps what was sent.
final class ParityHttp: HttpClient, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [NetRequest] = []
    private let script: @Sendable (NetRequest) -> (UInt16, Data)

    init(_ script: @escaping @Sendable (NetRequest) -> (UInt16, Data)) { self.script = script }

    var requests: [NetRequest] { lock.withLock { sent } }

    func send(request: NetRequest) async throws -> NetResponse {
        lock.withLock { sent.append(request) }
        let (status, body) = script(request)
        return NetResponse(status: status, headers: [], body: body, url: request.url)
    }
}

/// Settings sync: the core's `SettingsSyncModel.runWithSeerr` against the old Swift rules
/// (`JellyfinKit.SettingsSync`: `remote`, `decide`, `fields`, `seerrStep`, `seerrFields`, `changeTime`)
/// composed the way the old `SettingsSyncRun.runOnce` composed them: same decision, same fields written to
/// `CustomPrefs`, same time stamps.
@Suite(.serialized) struct SettingsSyncParityTests {

    private static func date(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }
    private static let base = 1_700_000_000_000.0
    private static let accessA = SeerrAccess(address: URL(string: "https://seerr.example")!, cookie: "connect.sid=aaa")
    private static let accessB = SeerrAccess(
        address: URL(string: "http://192.168.1.5:5055")!, cookie: "connect.sid=bbb",
        headers: [OwnHeader(name: "CF-Access-Client-Id", value: "x")])

    private static func json(_ a: SeerrAccess?) -> String? {
        a.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
    }

    struct Scenario: CustomStringConvertible {
        var description: String
        var prefs: [String: String] = [:]
        var local: [String: SettingsSync.Value] = [:]
        var localChanged: Double?  // ms
        var other = false
        var seerr: SeerrAccess?
        var seerrChanged: Double?  // ms
        var now = SettingsSyncParityTests.base + 100_000
        var remoteSeen: Double?  // ms
    }

    private static let mine: [String: SettingsSync.Value] = [
        "tonSprache": .text("de"), "vorSek": .int(10), "utAuto": .bool(true), "startReihen": .list(["a", "b"]),
    ]
    private static let theirs: [String: SettingsSync.Value] = ["tonSprache": .text("fr"), "vorSek": .int(30)]

    private static func remote(_ values: [String: SettingsSync.Value], at ms: Double, seerr: String? = nil,
                               seerrAt: Double? = nil) -> [String: String] {
        var p = SettingsSync.fields(for: values, changed: date(ms))
        p["Other.client.key"] = "kept"
        if let seerr { p[SettingsSync.seerrKey] = seerr }
        if let seerrAt { p[SettingsSync.seerrChangedKey] = String(Int64(seerrAt)) }
        return p
    }

    static let scenarios: [Scenario] = {
        let b = base
        return [
            Scenario(description: "nothing on the server: push", local: mine),
            Scenario(description: "server newer: apply", prefs: remote(theirs, at: b + 5000), local: mine, localChanged: b),
            Scenario(description: "server older: push with the local stamp", prefs: remote(theirs, at: b - 5000),
                     local: mine, localChanged: b),
            Scenario(description: "equal: nothing", prefs: remote(theirs, at: b), local: mine, localChanged: b),
            Scenario(description: "other account: apply whatever the times say", prefs: remote(theirs, at: b - 5000),
                     local: mine, localChanged: b, other: true),
            Scenario(description: "never changed here: apply", prefs: remote(theirs, at: b), local: mine),
            Scenario(description: "clock behind the server: stamp after the server's", local: mine,
                     now: b - 10_000, remoteSeen: b),
            Scenario(description: "seerr: server newer is adopted", prefs: remote(theirs, at: b, seerr: json(accessA), seerrAt: b + 9000),
                     local: theirs, localChanged: b, seerr: accessB, seerrChanged: b),
            Scenario(description: "seerr: local newer goes out alone", prefs: remote(theirs, at: b, seerr: json(accessA), seerrAt: b - 9000),
                     local: theirs, localChanged: b, seerr: accessB, seerrChanged: b),
            Scenario(description: "seerr: a disconnect travels", prefs: remote(theirs, at: b, seerr: "", seerrAt: b + 9000),
                     local: theirs, localChanged: b, seerr: accessB, seerrChanged: b),
            Scenario(description: "seerr: a value nobody can read is no disconnect",
                     prefs: remote(theirs, at: b, seerr: "{bad", seerrAt: b + 9000),
                     local: theirs, localChanged: b, seerr: accessB, seerrChanged: b),
            Scenario(description: "seerr: never touched here, nothing on the server: push at once",
                     prefs: remote(theirs, at: b), local: theirs, localChanged: b, seerr: accessB),
            Scenario(description: "seerr: never touched here, the server only disconnects: keep ours",
                     prefs: remote(theirs, at: b, seerr: "", seerrAt: b + 9000), local: theirs, localChanged: b, seerr: accessB),
            Scenario(description: "seerr: both at the same time: nothing",
                     prefs: remote(theirs, at: b, seerr: json(accessA), seerrAt: b), local: theirs, localChanged: b,
                     seerr: accessB, seerrChanged: b),
            Scenario(description: "settings and seerr push in one write", local: mine, localChanged: b, seerr: accessB, seerrChanged: b),
            Scenario(description: "nothing of the device's own: only the connection travels", seerr: accessB),
        ]
    }()

    /// The old run's result for a scenario, from the old Swift rules.
    private struct Expected {
        var settings: String  // "apply", "pushed", "nothing"
        var applied: [String: String] = [:]
        var changed: Double?
        var seerr: String  // "nothing", "adopt", "pushed"
        var seerrJSON: String?
        var seerrAt: Double?
        var written: [String: String]?  // the CustomPrefs after the write, nil = no write
    }

    private static func oracle(_ s: Scenario) -> Expected {
        let remote = SettingsSync.remote(from: s.prefs)
        var decision = SettingsSync.decide(
            remote: remote, localChanged: s.localChanged.map(date), otherAccount: s.other)
        let step = SettingsSync.seerrStep(
            remote: s.prefs, localChanged: s.seerrChanged.map(date), hasLocal: s.seerr != nil)
        var out = Expected(settings: "nothing", seerr: "nothing")
        var seerrFields: [String: String] = [:]
        switch step {
        case .adopt(let access, let changed):
            out.seerr = "adopt"; out.seerrJSON = json(access) ?? ""; out.seerrAt = changed.timeIntervalSince1970
        case .push:
            let stamp = s.seerrChanged.map(date) ?? date(s.now)
            out.seerr = "pushed"; out.seerrAt = stamp.timeIntervalSince1970
            seerrFields = SettingsSync.seerrFields(s.seerr, changed: stamp)
        case .nothing: break
        }
        var fields: [String: String] = [:]
        if decision != .push { fields = seerrFields }
        switch decision {
        case .apply:
            out.settings = "apply"
            out.applied = remote.values.mapValues(\.encoded)
            out.changed = remote.changed?.timeIntervalSince1970
        case .nothing: break
        case .push:
            if s.local.isEmpty {
                fields = seerrFields
            } else {
                let stamp = s.localChanged.map(date)
                    ?? SettingsSync.changeTime(now: date(s.now), lastKnownRemote: s.remoteSeen.map(date))
                out.settings = "pushed"; out.changed = stamp.timeIntervalSince1970
                fields = SettingsSync.fields(for: s.local, changed: stamp).merging(seerrFields) { _, n in n }
            }
        }
        decision = .nothing
        if !fields.isEmpty { out.written = s.prefs.merging(fields) { _, new in new } }
        return out
    }

    /// Intended deviation: the core writes the Seerr connection as compact JSON without escaped slashes
    /// (`https://`), Swift's `JSONEncoder` writes `https:\/\/` and an unstable key order. Both read back as
    /// the same connection with every reader, so the tests compare the decoded value.
    private static func same(_ a: String?, _ b: String?) -> Bool {
        func read(_ t: String?) -> SeerrAccess? {
            t.flatMap { try? JSONDecoder().decode(SeerrAccess.self, from: Data($0.utf8)) }
        }
        return (a ?? "").isEmpty && (b ?? "").isEmpty || (read(a) != nil && read(a) == read(b))
    }

    private static func normalised(_ prefs: [String: String]) -> [String: String] {
        var out = prefs
        if let t = prefs[SettingsSync.seerrKey], let a = try? JSONDecoder().decode(SeerrAccess.self, from: Data(t.utf8)) {
            out[SettingsSync.seerrKey] = String(describing: a)
        }
        return out
    }

    private static func customPrefs(_ body: Data?) -> [String: String] {
        guard let body, let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let p = o["CustomPrefs"] as? [String: Any]
        else { return [:] }
        return p.compactMapValues { $0 as? String }
    }

    @Test(arguments: scenarios.indices) func theCoreRunsLikeTheOldRules(_ index: Int) async throws {
        let s = Self.scenarios[index]
        let expected = Self.oracle(s)
        let copy: [String: Any] = ["Id": "swiftly", "SortBy": "SortName", "CustomPrefs": s.prefs]
        let get = try JSONSerialization.data(withJSONObject: copy)
        let http = ParityHttp { _ in (200, get) }
        let core = Core(platform: FakePlatform(), secrets: FakeSecrets(), store: MemoryKeyValue(), http: http)
        let account = AccountRef(
            baseUrl: "http://sync.test", userId: "u1", token: "T", serverKind: .jellyfin, deviceId: "d")
        let model = try core.settingsSyncModel(account: account, locale: "de")

        let round = try await model.runWithSeerr(
            local: s.local.map { SyncSetting(name: $0.key, value: $0.value.encoded) },
            localChanged: s.localChanged.map { $0 / 1000 }, remoteSeen: s.remoteSeen.map { $0 / 1000 },
            otherAccount: s.other, now: s.now / 1000, seerr: Self.json(s.seerr),
            seerrChanged: s.seerrChanged.map { $0 / 1000 })

        switch round.settings {
        case .apply(let values, let changed):
            #expect(expected.settings == "apply", "\(s)")
            #expect(Dictionary(uniqueKeysWithValues: values.map { ($0.name, $0.value) }) == expected.applied, "\(s)")
            #expect(changed == expected.changed, "\(s)")
        case .pushed(let changed):
            #expect(expected.settings == "pushed", "\(s)")
            #expect(changed == expected.changed, "\(s)")
        case .nothing: #expect(expected.settings == "nothing", "\(s)")
        case .unreachable: Issue.record("unreachable: \(s)")
        }
        switch round.seerr {
        case .adopt(let access, let changed):
            #expect(expected.seerr == "adopt", "\(s)")
            #expect(Self.same(access, expected.seerrJSON), "\(s)")
            #expect(changed == expected.seerrAt, "\(s)")
        case .pushed(let changed):
            #expect(expected.seerr == "pushed", "\(s)")
            #expect(changed == expected.seerrAt, "\(s)")
        case .nothing: #expect(expected.seerr == "nothing", "\(s)")
        }
        let posts = http.requests.filter { $0.method == .post }
        if let written = expected.written {
            #expect(posts.count == 1, "\(s)")
            #expect(Self.normalised(Self.customPrefs(posts.first?.body)) == Self.normalised(written), "\(s)")
            // The rest of the copy (the server's own fields) goes back untouched.
            let sent = try #require(posts.first?.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
            #expect(sent["SortBy"] as? String == "SortName", "\(s)")
        } else {
            #expect(posts.isEmpty, "\(s)")
        }
        // The address and the client name the old `DisplayPreferences` calls used.
        let get1 = try #require(http.requests.first)
        #expect(get1.url == "http://sync.test/DisplayPreferences/swiftly?userId=u1&client=Swiftly")
    }

    @Test func theSeerrConnectionTheCoreHandsBackReadsAsTheOldAccess() throws {
        // What `Adopt` carries is decoded by the app with the Swift `SeerrAccess` decoder.
        let json = try #require(Self.json(Self.accessB))
        #expect(try JSONDecoder().decode(SeerrAccess.self, from: Data(json.utf8)) == Self.accessB)
    }

    @Test func theEntryListIsTheOldOne() {
        #expect(
            settingsSyncEntries().map { "\($0.name):\($0.perServer)" }
                == SettingsSync.entries.map { "\($0.name):\($0.perServer)" })
    }
}
