import Foundation
import Testing
@testable import JellyfinKit

@Suite("Übernahme: welche Sitzung angeboten wird")
struct TakeoverTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// `Item` has no public init; build it from JSON, the way the server
    /// sends it.
    private func title(_ id: String = "e1") -> Item {
        let raw = "{\"Id\":\"\(id)\",\"Name\":\"Folge\",\"Type\":\"Episode\"}"
        return try! JSONDecoder().decode(Item.self, from: Data(raw.utf8))
    }

    private func session(id: String = "s1", device: String? = "iphone",
                         user: String? = "paul",
                         takesCommands: Bool = true, running: Item? = nil,
                         forwardSeconds: TimeInterval? = 5) -> RemoteSession {
        RemoteSession(id: id, userIdentifier: user,
                     devicesIdentifier: device, deviceName: "iPhone im Wohnzimmer",
                     program: "Swiftly", takesCommands: takesCommands,
                     running: running, state: .init(halted: false, spot: 812),
                     lastActivity: forwardSeconds.map { now.addingTimeInterval(-$0) })
    }

    // MARK: - The normal case

    @Test("Ein anderes Gerät mit laufendem Titel wird angeboten")
    func normal() {
        let a = Takeover.offering(from: [session(running: title())],
                                   ownDevicesIdentifier: "appletv", ownUserIdentifier: "paul", now: now)
        #expect(a?.id == "s1")
        #expect(a?.state?.spot == 812)
    }

    @Test("Ticks werden zu Sekunden")
    func ticks() throws {
        let raw = #"{"Id":"s1","DeviceId":"x","SupportsRemoteControl":true,"PlayState":{"IsPaused":false,"PositionTicks":8120000000}}"#
        let s = try JSONDecoder().decode(RemoteSession.self, from: Data(raw.utf8))
        #expect(s.state?.spot == 812)
    }

    @Test("Jellyfins Zeitstempel mit sieben Nachkommastellen wird gelesen")
    func timestamp() throws {
        // Exactly the shape `/Sessions` delivered.
        // `.iso8601` would have thrown here, and inside a `try?` the
        // value would have vanished silently, along with the quiet period.
        let raw = #"{"Id":"s1","DeviceId":"x","SupportsRemoteControl":true,"LastActivityDate":"2026-09-03T14:10:09.2201736Z"}"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { try TimestampFormat.read(from: $0) }
        let s = try d.decode(RemoteSession.self, from: Data(raw.utf8))
        #expect(s.lastActivity != nil)
        let expects = Date(timeIntervalSince1970: 1_788_444_609.22)
        #expect(abs((s.lastActivity ?? .distantPast).timeIntervalSince(expects)) < 1)
    }

    @Test("Und einer ohne Nachkommastellen auch")
    func timestampWithoutBreak() throws {
        let raw = #"{"Id":"s1","DeviceId":"x","SupportsRemoteControl":true,"LastActivityDate":"2026-09-03T14:10:09Z"}"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { try TimestampFormat.read(from: $0) }
        #expect(try d.decode(RemoteSession.self, from: Data(raw.utf8)).lastActivity != nil)
    }

    // MARK: - The four conditions, each on its own

    @Test("Das eigene Gerät wird nie angeboten")
    func notSelf() {
        // The most common bug here, and it only shows when a single
        // device is running.
        #expect(Takeover.offering(from: [session(device: "appletv", running: title())],
                                   ownDevicesIdentifier: "appletv", ownUserIdentifier: "paul", now: now) == nil)
    }

    @Test("Eine Sitzung ohne laufenden Titel wird nicht angeboten")
    func withoutTitle() {
        #expect(Takeover.offering(from: [session(running: nil)],
                                   ownDevicesIdentifier: "appletv", ownUserIdentifier: "paul", now: now) == nil)
    }

    @Test("Nimmt die Gegenstelle keine Befehle, wird nicht angeboten")
    func withoutRemoteControl() {
        // Otherwise it would keep playing there while the same starts here: two
        // audio tracks in the room.
        #expect(Takeover.offering(from: [session(takesCommands: false, running: title())],
                                   ownDevicesIdentifier: "appletv", ownUserIdentifier: "paul", now: now) == nil)
    }

    @Test("Nach 90 Sekunden Stille nicht mehr")
    func tooOld() {
        #expect(Takeover.offering(from: [session(running: title(), forwardSeconds: 91)],
                                   ownDevicesIdentifier: "appletv", ownUserIdentifier: "paul", now: now) == nil)
        #expect(Takeover.offering(from: [session(running: title(), forwardSeconds: 89)],
                                   ownDevicesIdentifier: "appletv", ownUserIdentifier: "paul", now: now) != nil)
    }

    @Test("Ohne Zeitangabe gilt sie als frisch")
    func withoutTime() {
        // If `LastActivityDate` is missing, rejecting is the worse choice: the
        // title is playing according to the server.
        #expect(Takeover.offering(from: [session(running: title(), forwardSeconds: nil)],
                                   ownDevicesIdentifier: "appletv", ownUserIdentifier: "paul", now: now) != nil)
    }

    @Test("Die Sitzung eines anderen Kontos wird nie angeboten")
    func foreignAccount() {
        // **The bug.** `controllableByUserId` does not return one's own
        // sessions but the ones one may control, for an
        // administrator the whole household. The badge then showed what
        // someone else is watching.
        #expect(Takeover.offering(from: [session(user: "koney", running: title())],
                                   ownDevicesIdentifier: "appletv",
                                   ownUserIdentifier: "paul", now: now) == nil)
    }

    @Test("Ohne Kontoangabe wird nicht angeboten")
    func withoutAccount() {
        // Better no badge than one that may show someone else's.
        #expect(Takeover.offering(from: [session(user: nil, running: title())],
                                   ownDevicesIdentifier: "appletv",
                                   ownUserIdentifier: "paul", now: now) == nil)
    }

    @Test("Das eigene Konto auf einem anderen Gerät schon")
    func ownAccount() {
        #expect(Takeover.offering(from: [session(user: "paul", running: title())],
                                   ownDevicesIdentifier: "appletv",
                                   ownUserIdentifier: "paul", now: now) != nil)
    }

    // MARK: - Several

    @Test("Bei mehreren gewinnt die jüngste Regung")
    func youngest() {
        let alt = session(id: "alt", device: "ipad", running: title(), forwardSeconds: 60)
        let new = session(id: "neu", device: "iphone", running: title(), forwardSeconds: 3)
        #expect(Takeover.offering(from: [alt, new],
                                   ownDevicesIdentifier: "appletv", ownUserIdentifier: "paul", now: now)?.id == "neu")
        #expect(Takeover.offering(from: [new, alt],
                                   ownDevicesIdentifier: "appletv", ownUserIdentifier: "paul", now: now)?.id == "neu",
                "die Reihenfolge der Antwort darf nichts ändern")
    }

    @Test("Untaugliche werden übersprungen, nicht der ganze Vorgang")
    func mixed() {
        let itself = session(id: "selbst", device: "appletv", running: title(), forwardSeconds: 1)
        let good = session(id: "gut", device: "iphone", running: title(), forwardSeconds: 30)
        #expect(Takeover.offering(from: [itself, good],
                                   ownDevicesIdentifier: "appletv", ownUserIdentifier: "paul", now: now)?.id == "gut")
    }

    @Test("Zwei Geräte: beide werden angeboten, jüngstes zuerst")
    func twoDevices() {
        let alt = session(id: "ipad", device: "ipad", running: title(), forwardSeconds: 40)
        let new = session(id: "iphone", device: "iphone", running: title(), forwardSeconds: 3)
        let list = Takeover.offerings(from: [alt, new], ownDevicesIdentifier: "appletv",
                                        ownUserIdentifier: "paul", now: now)
        #expect(list.map(\.id) == ["iphone", "ipad"])
    }

    @Test("Untaugliche stehen auch nicht in der Liste")
    func listFilter() {
        let foreign = session(id: "fremd", device: "mac", user: "koney", running: title())
        let itself = session(id: "selbst", device: "appletv", running: title())
        let good = session(id: "gut", device: "iphone", running: title())
        let list = Takeover.offerings(from: [foreign, itself, good], ownDevicesIdentifier: "appletv",
                                        ownUserIdentifier: "paul", now: now)
        #expect(list.map(\.id) == ["gut"])
    }

    @Test("Keine Sitzungen, kein Angebot")
    func empty() {
        #expect(Takeover.offering(from: [], ownDevicesIdentifier: "appletv", ownUserIdentifier: "paul", now: now) == nil)
    }

    // MARK: - Which device

    private func art(_ name: String?, program: String?) -> RemoteSession.DevicesKind {
        RemoteSession(id: "g", devicesIdentifier: "x", deviceName: name, program: program,
                     takesCommands: true, running: nil, state: nil).devicesKind
    }

    @Test("Swiftly auf einem Android-Telefon ist ein Telefon, kein Fernseher")
    func androidPhone() {
        #expect(art("Pixel 10 Pro", program: "Swiftly Player Android") == .phone)
    }

    @Test("Swiftly auf Android TV ist ein Fernseher")
    func androidTV() {
        #expect(art("TCL 55C805", program: "Swiftly Player Android TV") == .tv)
    }

    @Test("Ohne Android im Programm entscheidet weiter der Gerätename")
    func nameDecides() {
        #expect(art("iPhone im Wohnzimmer", program: "Swiftly Player") == .phone)
        #expect(art("iPad", program: nil) == .tablet)
    }

    @Test("Übernahme startet an der Stoppstelle, wenn sie ankam")
    func startPointPostStop() {
        // Session reported 600 s, the stop 608 s.
        #expect(Takeover.startPoint(session: 600, savedBefore: 1_000_000_000,
                                       savedAfterwards: 6_080_000_000) == 608)
    }

    @Test("Ohne neue Stoppstelle oder mit zurückgesetzter gilt die Sitzung")
    func startPointWithoutStop() {
        #expect(Takeover.startPoint(session: 600, savedBefore: 50, savedAfterwards: 50) == 600)
        #expect(Takeover.startPoint(session: 600, savedBefore: 50, savedAfterwards: nil) == 600)
        #expect(Takeover.startPoint(session: 600, savedBefore: 50, savedAfterwards: 0) == 600)
    }
}
