import Foundation
import Testing
@testable import JellyfinKit

@Suite("SyncPlay: Nachrichten, Uhren, Befehle")
struct SyncPlayTests {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Reading messages (wording as from the server, openapi 12.1)

    @Test func commandWithSevenPostCommaSet() throws {
        let text = """
        {"MessageType":"SyncPlayCommand","MessageId":"x","Data":{"GroupId":"g1",\
        "PlaylistItemId":"p1","When":"2026-09-24T10:00:01.5000000Z","PositionTicks":123450000,\
        "Command":"Unpause","EmittedAt":"2026-09-24T10:00:00.9000000Z"}}
        """
        guard case let .command(b)? = SyncPlayPostDirection.read(text) else {
            Issue.record("kein Befehl"); return
        }
        #expect(b.art == .proceed)
        #expect(b.group == "g1")
        #expect(b.entryRecord == "p1")
        #expect(abs((b.spot ?? 0) - 12.345) < 0.0001)
        let expects = try #require(SyncPlay.timeRead("2026-09-24T10:00:01.500Z"))
        #expect(abs(b.moment.timeIntervalSince(expects)) < 0.002)
    }

    @Test func groupNews() {
        func update(_ art: String, _ data: String) -> SyncPlayPostDirection? {
            SyncPlayPostDirection.read(#"{"MessageType":"SyncPlayGroupUpdate","Data":{"GroupId":"g1","Type":"\#(art)","Data":\#(data)}}"#)
        }
        #expect(update("UserJoined", #""Tom""#) == .someoneJoined("Tom"))
        #expect(update("UserLeft", #""Tom""#) == .someoneLeft("Tom"))
        #expect(update("GroupLeft", #""g1""#) == .leave)
        #expect(update("NotInGroup", #""""#) == .notInGroup)
        #expect(update("LibraryAccessDenied", #""""#) == .noAccess)
        #expect(update("StateUpdate", #"{"State":"Waiting","Reason":"Buffer"}"#)
                == .condition(.waits, reason: "Buffer"))

        let joinEvent = update("GroupJoined", #"{"GroupId":"g1","GroupName":"Filmabend","State":"Idle","Participants":["Paul"],"LastUpdatedAt":"2026-09-24T10:00:00.1234567Z"}"#)
        guard case let .joined(g)? = joinEvent else { Issue.record("kein Beitritt"); return }
        #expect(g.name == "Filmabend")
        #expect(g.condition == .empty)
        #expect(g.participant == ["Paul"])
        #expect(g.state != nil)
    }

    @Test func queue() {
        let text = #"{"MessageType":"SyncPlayGroupUpdate","Data":{"GroupId":"g1","Type":"PlayQueue","Data":{"Reason":"NewPlaylist","LastUpdate":"2026-09-24T10:00:00Z","Playlist":[{"ItemId":"i1","PlaylistItemId":"p1"},{"ItemId":"i2","PlaylistItemId":"p2"}],"PlayingItemIndex":1,"StartPositionTicks":600000000,"IsPlaying":false,"ShuffleMode":"Sorted","RepeatMode":"RepeatNone"}}}"#
        guard case let .queue(w)? = SyncPlayPostDirection.read(text) else {
            Issue.record("keine Warteschlange"); return
        }
        #expect(w.current == .init(title: "i2", entryRecord: "p2"))
        #expect(w.startPoint == 60)
        #expect(w.switchesTitle)
        #expect(!w.running)
    }

    @Test func foreignStaysPut() {
        #expect(SyncPlayPostDirection.read(#"{"MessageType":"ForceKeepAlive","Data":60}"#) == nil)
        #expect(SyncPlayPostDirection.read("kein json") == nil)
        #expect(SyncPlayPostDirection.read(#"{"MessageType":"SyncPlayGroupUpdate","Data":{"GroupId":"g","Type":"Neu","Data":1}}"#) == nil)
    }

    @Test func groupsListWithoutFields() throws {
        let raw = #"[{"GroupId":"g1","GroupName":"Filmabend","State":"Playing","Participants":["Paul","Tom","Paul"]},{"GroupId":"g2"}]"#
        let list = try JSONDecoder().decode([SyncPlayGroup].self, from: Data(raw.utf8))
        #expect(list.count == 2)
        #expect(list[0].condition == .running)
        #expect(list[0].other(asValue: "Paul") == ["Tom", "Paul"], "das zweite Geraet desselben Kontos bleibt")
        #expect(list[1].name == "")
        #expect(list[1].participant.isEmpty)
    }

    @Test func othersWithoutMeOrDuplicates() {
        let g = SyncPlayGroup(id: "g", name: "n", participant: ["Paul", "Tom", "Tom", "Lena"])
        #expect(g.other(asValue: "Paul") == ["Tom", "Lena"])
        #expect(g.other(asValue: nil) == ["Paul", "Tom", "Lena"])
    }

    // MARK: Clocks

    private func measurement(offset: TimeInterval, there: TimeInterval, back: TimeInterval,
                         since: Date) -> TimeReconcile.Reading {
        // Server computes 5 ms.
        let within = since.addingTimeInterval(there + offset)
        let out = within.addingTimeInterval(0.005)
        return .init(sent: since, serverReceive: within, serverSent: out,
                     receive: out.addingTimeInterval(-offset + back))
    }

    @Test func offsetFromSymmetricMeasurement() {
        let m = measurement(offset: 2.5, there: 0.04, back: 0.04, since: t0)
        #expect(abs(m.offset - 2.5) < 0.0001)
        #expect(abs(m.runtime - 0.08) < 0.0001)
    }

    @Test func shortestRuntimeApplies() {
        var a = TimeReconcile()
        #expect(!a.ready)
        #expect(a.offset == 0)
        // A long, skewed measurement and a short one.
        a.record(measurement(offset: 1, there: 0.4, back: 0.02, since: t0))
        a.record(measurement(offset: 1, there: 0.01, back: 0.01, since: t0))
        #expect(abs(a.offset - 1) < 0.001)
        #expect(a.pingMilliseconds == 10)
        let localOnly = t0.addingTimeInterval(10)
        #expect(abs(a.localOnly(a.server(localOnly)).timeIntervalSince(localOnly)) < 0.0001)
    }

    @Test func onlyEightMeasurementsRemain() {
        var a = TimeReconcile()
        for i in 0..<12 { a.record(measurement(offset: Double(i), there: 0.01, back: 0.01, since: t0)) }
        #expect(a.measurements.count == TimeReconcile.keep)
        #expect(TimeReconcile.pause(toMeasurements: 0) == 1)
        #expect(TimeReconcile.pause(toMeasurements: 3) == 60)
    }

    // MARK: Executing commands

    private func reconcile(offset: TimeInterval) -> TimeReconcile {
        var a = TimeReconcile()
        a.record(measurement(offset: offset, there: 0.01, back: 0.01, since: t0))
        return a
    }

    private func command(_ art: SyncPlayCommand.Art, moment: Date, spot: Double?) -> SyncPlayCommand {
        .init(group: "g", entryRecord: "p", art: art, moment: moment, spot: spot)
    }

    @Test func nextInFutureWaits() {
        // Server clock runs 3 s ahead. The command applies 1.5 s of server time from now.
        let a = reconcile(offset: 3)
        let now = t0
        let b = command(.proceed, moment: a.server(now).addingTimeInterval(1.5), spot: 100)
        let x = SyncPlayExecution.of(b, now: now, reconcile: a, localPoint: 100.1)
        #expect(x.step == .proceed)
        #expect(abs(x.wait - 1.5) < 0.001)
        #expect(x.spot == nil, "100 ms daneben ist kein Sprung")

        let y = SyncPlayExecution.of(b, now: now, reconcile: a, localPoint: 90)
        #expect(y.spot == 100)
    }

    @Test func nextInPastFetches() {
        let a = reconcile(offset: -2)
        let now = t0
        // Started at 100 four seconds ago (server time).
        let b = command(.proceed, moment: a.server(now).addingTimeInterval(-4), spot: 100)
        let x = SyncPlayExecution.of(b, now: now, reconcile: a, localPoint: 100)
        #expect(x.wait == 0)
        #expect(abs((x.spot ?? 0) - 104) < 0.001)
    }

    @Test func pauseJumpsPointGroup() {
        let a = reconcile(offset: 0)
        let x = SyncPlayExecution.of(command(.pause, moment: t0.addingTimeInterval(0.3), spot: 50),
                                         now: t0, reconcile: a, localPoint: 51)
        #expect(x.step == .pause)
        #expect(x.spot == 50)
        #expect(abs(x.wait - 0.3) < 0.001)
    }

    @Test func jumpAlwaysWithPoint() {
        let a = reconcile(offset: 0)
        let x = SyncPlayExecution.of(command(.jump, moment: t0.addingTimeInterval(-1), spot: 600),
                                         now: t0, reconcile: a, localPoint: 600)
        #expect(x == .init(step: .jump, spot: 600, wait: 0))
        let s = SyncPlayExecution.of(command(.stop, moment: t0, spot: nil),
                                         now: t0, reconcile: a, localPoint: 1)
        #expect(s.step == .stop)
    }

    @Test func updateFirstOffSecond() {
        let a = reconcile(offset: 0)
        let b = command(.proceed, moment: t0, spot: 10)
        let now = t0.addingTimeInterval(20)   // group at 30
        #expect(SyncPlayExecution.bringUpToDate(lastOne: b, entryRecord: "p", now: now,
                                                reconcile: a, localPoint: 29.5) == nil)
        let should = SyncPlayExecution.bringUpToDate(lastOne: b, entryRecord: "p", now: now,
                                                   reconcile: a, localPoint: 27)
        #expect(abs((should ?? 0) - 30) < 0.001)
        // Another entry, paused, or not yet due: never.
        #expect(SyncPlayExecution.bringUpToDate(lastOne: b, entryRecord: "anders", now: now,
                                                reconcile: a, localPoint: 0) == nil)
        #expect(SyncPlayExecution.bringUpToDate(lastOne: command(.pause, moment: t0, spot: 10),
                                                entryRecord: "p", now: now, reconcile: a,
                                                localPoint: 0) == nil)
        #expect(SyncPlayExecution.bringUpToDate(lastOne: b, entryRecord: "p", now: t0.addingTimeInterval(-1),
                                                reconcile: a, localPoint: 0) == nil)
    }

    // MARK: Buffering

    @Test func bufferGuard() {
        var w = BufferGuard()
        var t = t0
        #expect(w.tick(spot: 10, shouldRun: true, now: t) == nil)
        t += 1; #expect(w.tick(spot: 11, shouldRun: true, now: t) == nil)
        // Standing.
        t += 1; #expect(w.tick(spot: 11, shouldRun: true, now: t) == nil)
        t += 1; #expect(w.tick(spot: 11, shouldRun: true, now: t) == nil)
        t += 1; #expect(w.tick(spot: 11, shouldRun: true, now: t) == nil)
        t += 1; #expect(w.tick(spot: 11, shouldRun: true, now: t) == .buffers)
        t += 1; #expect(w.tick(spot: 11, shouldRun: true, now: t) == nil, "nur einmal")
        t += 1; #expect(w.tick(spot: 11.5, shouldRun: true, now: t) == .ready)
        // Stopped does not count as buffering.
        for _ in 0..<5 { t += 1; #expect(w.tick(spot: 11.5, shouldRun: false, now: t) == nil) }
    }

    @Test func readyPostJump() {
        #expect(SyncPlayExecution.readyPoint(target: 600, actualValue: 600.3) == 600)
        #expect(SyncPlayExecution.readyPoint(target: 600, actualValue: 599.2) == 600)
        #expect(SyncPlayExecution.readyPoint(target: 600, actualValue: 604) == 604)
    }

    @Test func timeTextReadsServer() throws {
        let text = SyncPlay.timeText(t0.addingTimeInterval(0.25))
        #expect(text.hasSuffix("Z"))
        #expect(text.contains(".250"))
        let back = try #require(SyncPlay.timeRead(text))
        #expect(abs(back.timeIntervalSince(t0) - 0.25) < 0.001)
    }

    @Test func tickConversion() {
        #expect(SyncPlay.ticks(1.5) == 15_000_000)
        #expect(SyncPlay.seconds(600_000_000) == 60)
        #expect(SyncPlayRight(rawValue: "JoinGroups")?.mayCreate == false)
        #expect(SyncPlayRight(rawValue: "JoinGroups")?.mayJoin == true)
        #expect(SyncPlayRight.no.mayJoin == false)
    }
}
