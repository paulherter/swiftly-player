import Foundation
import Testing

@testable import JellyfinKit
@testable import SwiftlyCore

/// The core's `HandoffFlowModel` against the old Swift rules (`Takeover.offerings`, `takesHint`, `startPoint`)
/// on scripted `/Sessions` answers: the same sessions are offered in the same order, the hint goes only to
/// Swiftly players, and the start point is the old one.
@Suite(.serialized) struct HandoffFlowParityTests {
    private static let now = 1_700_000_000.0

    private static func iso(_ back: Double) -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: Date(timeIntervalSince1970: now - back))
    }

    private static func row(_ id: String, device: String, user: String, program: String, back: Double,
                            video: Bool = true, commands: Bool = true) -> [String: Any] {
        [
            "Id": id, "DeviceId": device, "UserId": user, "DeviceName": "Gerät \(id)", "Client": program,
            "SupportsRemoteControl": commands, "LastActivityDate": iso(back),
            "NowPlayingItem": ["Id": "item-\(id)", "Name": "Folge", "Type": video ? "Episode" : "Audio"],
            "PlayState": ["IsPaused": false, "PositionTicks": 1_200_000_000],
        ]
    }

    private static var scripts: [[[String: Any]]] { [
        [],
        [row("a", device: "own", user: "u1", program: "Swiftly Player", back: 2)],
        [row("a", device: "tv", user: "u1", program: "Swiftly Player", back: 30),
         row("b", device: "mac", user: "u1", program: "Jellyfin Web", back: 4)],
        [row("a", device: "tv", user: "u2", program: "Swiftly Player", back: 3),
         row("b", device: "mac", user: "u1", program: "Swiftly", back: 200),
         row("c", device: "pad", user: "u1", program: "Swiftly Player", back: 10, video: false),
         row("d", device: "tv2", user: "u1", program: "Swiftly Player", back: 10, commands: false)],
        [row("a", device: "tv", user: "u1", program: "Swiftly Player", back: 8),
         row("b", device: "pad", user: "u1", program: "Swiftly", back: 8)],
    ] }

    private func flow() -> HandoffFlowModel {
        let account = AccountRef(baseUrl: "http://srv.test", userId: "u1", token: "T", serverKind: .jellyfin,
                                 deviceId: "own")
        return makeCore().handoffFlow(account: account)
    }

    @Test func offeredSessionsMatchTheOldRules() throws {
        for script in Self.scripts {
            let data = try JSONSerialization.data(withJSONObject: script)
            let old = try JSONDecoder.sessions.decode([RemoteSession].self, from: data)
            let want = Takeover.offerings(from: old, ownDevicesIdentifier: "own", ownUserIdentifier: "u1",
                                          now: Date(timeIntervalSince1970: Self.now)).map(\.id)
            let f = flow()
            _ = try f.step(event: .start)
            #expect(try f.step(event: .tick(playerRuns: false, signedIn: true)) == [.ask])
            let fx = try f.step(event: .answered(sessionsJson: data, now: Self.now))
            let offered = fx.compactMap { e -> [String]? in if case let .offer(ids) = e { ids } else { nil } }.first
            #expect(offered == want)
            #expect(f.phase() == "quiet")
        }
    }

    @Test func hintAndStartPointMatchTheOldRules() throws {
        let cases: [(program: String, before: Int64?, afterwards: [Int64?], fresh: Double?)] = [
            ("Swiftly Player", 500_000_000, [500_000_000, 1_500_000_000], 120),
            ("Swiftly", nil, [nil], nil),
            ("Jellyfin Web", 100_000_000, [900_000_000], 100),
            ("Swiftly Player", 500_000_000, Array(repeating: 500_000_000, count: 15), 120),
            ("Swiftly Player", 500_000_000, [nil], 30),
        ]
        for c in cases {
            let data = try JSONSerialization.data(withJSONObject:
                [Self.row("a", device: "tv", user: "u1", program: c.program, back: 3)])
            let old = try JSONDecoder.sessions.decode([RemoteSession].self, from: data)
            let f = flow()
            _ = try f.step(event: .start)
            _ = try f.step(event: .tick(playerRuns: false, signedIn: true))
            _ = try f.step(event: .answered(sessionsJson: data, now: Self.now))
            #expect(try f.step(event: .adopt(sessionId: "a")) == [.prepare(itemId: "item-a")])
            var fx = try f.step(event: .prepared(plan: true, savedBefore: c.before, freshPoint: c.fresh))
            let hinted = fx == [.sendHint(sessionId: "a")]
            #expect(hinted == Takeover.takesHint(old[0]))
            if hinted { fx = try f.step(event: .hintDone(error: nil)) }
            #expect(fx == [.sendStop(sessionId: "a")])
            fx = try f.step(event: .stopAccepted)
            var played: (Double, Bool)?
            var step = 0
            while played == nil, step < 40 {   // a bound, so a machine that never plays fails instead of hanging
                #expect(fx.contains(.readPosition(itemId: "item-a")) || fx.contains { if case .play = $0 { true } else { false } })
                let ticks: Int64? = step < c.afterwards.count ? c.afterwards[step] : c.afterwards[c.afterwards.count - 1]
                step += 1
                fx = try f.step(event: .position(ticks: ticks))
                for e in fx { if case let .play(_, since, unreported, _) = e { played = (since, unreported) } }
            }
            try #require(played != nil)
            let session = c.fresh ?? old[0].state?.spot ?? 0
            // The old loop: the first read that differs from `before` counts; none after 15 reads = nil.
            let changed = c.afterwards.prefix(15).first { $0 != c.before }
            let want = Takeover.startPoint(session: session, savedBefore: c.before,
                                           savedAfterwards: changed ?? nil)
            #expect(played?.0 == want)
            #expect(f.phase() == "quiet")
        }
    }

    @Test func illegalEventsAreIgnoredAndFinishStops() throws {
        let f = flow()
        #expect(try f.step(event: .stopAccepted).isEmpty)
        #expect(try f.step(event: .tick(playerRuns: false, signedIn: true)).isEmpty)
        _ = try f.step(event: .start)
        #expect(try f.step(event: .tick(playerRuns: true, signedIn: true)).isEmpty)
        #expect(try f.step(event: .adopt(sessionId: "nope")).isEmpty)
        #expect(try f.step(event: .finish) == [.offer(sessionIds: [])])
        #expect(f.phase() == "stopped")
    }
}

private extension JSONDecoder {
    static var sessions: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { try TimestampFormat.read(from: $0) }
        return d
    }
}
