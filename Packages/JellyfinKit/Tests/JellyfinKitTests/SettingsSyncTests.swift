import Foundation
import Testing
@testable import JellyfinKit

@Suite("Einstellungen abgleichen")
struct SettingsSyncTests {

    @Test("Werte laufen verlustfrei durch den Text")
    func roundtrip() {
        let samples: [(SettingsSync.Value, SettingsSync.Kind)] = [
            (.bool(true), .bool), (.bool(false), .bool), (.int(30), .int),
            (.text("deu"), .text), (.text(""), .text),
            (.list(["a", "b"]), .list), (.list([]), .list),
            (.json(Data(#"[{"id":"1"}]"#.utf8)), .json),
        ]
        for (value, kind) in samples {
            #expect(SettingsSync.Value.decode(value.encoded, as: kind) == value)
        }
    }

    @Test("Unpassendes wird nicht übernommen")
    func rejectsGarbage() {
        #expect(SettingsSync.Value.decode("ja", as: .bool) == nil)
        #expect(SettingsSync.Value.decode("-5", as: .int) == nil)
        #expect(SettingsSync.Value.decode("99999", as: .int) == nil)
        #expect(SettingsSync.Value.decode("nicht json", as: .list) == nil)
        #expect(SettingsSync.Value.decode("{", as: .json) == nil)
    }

    @Test("Fremde Schlüssel bleiben außen vor")
    func ignoresForeign() {
        let r = SettingsSync.remote(from: [
            "swiftly.vorSek": "45", "swiftly.changed": "2000",
            "homesection0": "latestmedia", "swiftly.unbekannt": "x",
        ])
        #expect(r.values == ["vorSek": .int(45)])
        #expect(r.present)
    }

    @Test("Wer gewinnt")
    func decisions() {
        let t = Date(timeIntervalSince1970: 1000)
        let older = Date(timeIntervalSince1970: 500)
        let none = SettingsSync.Remote(values: [:], changed: nil)
        let theirs = SettingsSync.Remote(values: ["utAuto": .bool(true)], changed: t)
        #expect(SettingsSync.decide(remote: none, localChanged: t, otherAccount: false) == .push)
        #expect(SettingsSync.decide(remote: theirs, localChanged: older, otherAccount: false) == .apply)
        #expect(SettingsSync.decide(remote: theirs, localChanged: nil, otherAccount: false) == .apply)
        #expect(SettingsSync.decide(remote: theirs, localChanged: t, otherAccount: false) == .nothing)
        #expect(SettingsSync.decide(remote: theirs, localChanged: t.addingTimeInterval(5), otherAccount: false) == .push)
        #expect(SettingsSync.decide(remote: theirs, localChanged: t.addingTimeInterval(5), otherAccount: true) == .apply)
    }

    @Test("Änderungszeit läuft nie hinter dem Server her")
    func changeTime() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(SettingsSync.changeTime(now: now, lastKnownRemote: nil) == now)
        #expect(SettingsSync.changeTime(now: now, lastKnownRemote: now.addingTimeInterval(-1)) == now)
        #expect(SettingsSync.changeTime(now: now, lastKnownRemote: now.addingTimeInterval(60)) > now.addingTimeInterval(60))
    }

    @Test("Schreiben lässt den Rest der Einstellungen stehen")
    func mergeKeepsRest() throws {
        let body = Data(#"{"Id":"x","SortBy":"DateCreated","CustomPrefs":{"homesection0":"resume","a":null}}"#.utf8)
        let copy = DisplayPreferencesCopy(body: body)
        #expect(copy.customPrefs == ["homesection0": "resume"])
        let out = try copy.merged(setting: ["swiftly.vorSek": "45"])
        let object = try #require(JSONSerialization.jsonObject(with: out) as? [String: Any])
        #expect(object["SortBy"] as? String == "DateCreated")
        let prefs = try #require(object["CustomPrefs"] as? [String: Any])
        #expect(prefs["homesection0"] as? String == "resume")
        #expect(prefs["swiftly.vorSek"] as? String == "45")
        #expect(prefs.keys.contains("a"))
    }

    @Test("Der Gerätename mit Server-Anhang findet seinen Eintrag")
    func suffix() {
        #expect(SettingsSync.entry(forDeviceKey: "startBibliotheken|https://x.de")?.name == "startBibliotheken")
        #expect(SettingsSync.entry(forDeviceKey: "nurUeberWLAN") == nil)
    }

    @Test("Seerr: neuere Verbindung gewinnt, Trennen reist mit")
    func seerr() {
        let access = SeerrAccess(address: URL(string: "https://seerr.example")!, cookie: "connect.sid=1")
        let t1 = Date(timeIntervalSince1970: 1_000), t2 = Date(timeIntervalSince1970: 2_000)
        let written = SettingsSync.seerrFields(access, changed: t2)
        // Nothing on the server: push what is here.
        #expect(SettingsSync.seerrStep(remote: [:], localChanged: nil, hasLocal: true) == .push)
        #expect(SettingsSync.seerrStep(remote: [:], localChanged: nil, hasLocal: false) == .nothing)
        // Server newer: take it, the connection survives the round trip.
        #expect(SettingsSync.seerrStep(remote: written, localChanged: t1, hasLocal: false)
                == .adopt(access, changed: t2))
        #expect(SettingsSync.seerrStep(remote: written, localChanged: nil, hasLocal: false)
                == .adopt(access, changed: t2))
        // Device newer: write it; the same time: done.
        let old = SettingsSync.seerrFields(access, changed: t1)
        #expect(SettingsSync.seerrStep(remote: old, localChanged: t2, hasLocal: true) == .push)
        #expect(SettingsSync.seerrStep(remote: old, localChanged: t1, hasLocal: true) == .nothing)
        // A newer disconnect elsewhere disconnects here.
        let gone = SettingsSync.seerrFields(nil, changed: t2)
        #expect(SettingsSync.seerrStep(remote: gone, localChanged: t1, hasLocal: true)
                == .adopt(nil, changed: t2))
        // A device that never synced keeps its old connection against a disconnect.
        #expect(SettingsSync.seerrStep(remote: gone, localChanged: nil, hasLocal: true) == .push)
        // Garbage on the server is no disconnect.
        var broken = written; broken[SettingsSync.seerrKey] = "{"
        #expect(SettingsSync.seerrStep(remote: broken, localChanged: nil, hasLocal: true) == .push)
    }
}
