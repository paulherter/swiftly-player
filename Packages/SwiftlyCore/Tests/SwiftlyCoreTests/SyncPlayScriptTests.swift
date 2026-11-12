import Foundation
import Synchronization
import Testing

@testable import SwiftlyCore

/// Scripted SyncPlay sessions: a fake Jellyfin (the fixture server answers the SyncPlay requests and records
/// them) plus control-channel messages fed in by the test, exactly as the WebSocket would deliver them.
private final class RecordingHost: SyncPlayHost {
    let log = Mutex<(steps: [SyncPlayStep], loads: [String])>(([], []))
    func playerStep(step: SyncPlayStep) { log.withLock { $0.steps.append(step) } }
    func loadTitle(title: String, since: Double) { log.withLock { $0.loads.append("\(title)@\(Int(since))") } }
    var steps: [SyncPlayStep] { log.withLock { $0.steps } }
    var loads: [String] { log.withLock { $0.loads } }
}

@MainActor
private final class Script {
    let server: FixtureServer
    let host = RecordingHost()
    let controller: SyncPlayController
    let observing: Task<Void, Never>
    var machine = TogetherState.off

    static func start() async throws -> Script {
        let server = try await FixtureServer.start()
        server.answerGroups(#"[{"GroupId":"g1","GroupName":"Filmabend","State":"Idle","Participants":["Bob"]}]"#)
        return try Script(server: server)
    }

    init(server: FixtureServer) throws {
        self.server = server
        let model = try makeCore().syncPlayModel(
            account: account(server), locale: "de", selfName: "Anna", host: host)
        controller = SyncPlayController(model: model)
        let controller = controller
        observing = Task { @MainActor in await controller.observe() }
    }

    func stop() async {
        observing.cancel()
        _ = await observing.value
        server.stop()
    }

    var page: SyncPlayPage { controller.page }

    func settle(_ condition: @MainActor () -> Bool) async -> Bool {
        let ok = await eventuallyOnMain {
            self.machine = TogetherState.reduce(self.machine, .page(self.controller.page))
            return condition()
        }
        return ok
    }

    func posts(_ name: String) -> Int { server.seen.filter { $0.target.contains("SyncPlay/\(name)") }.count }

    private static func stamp(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    func update(_ type: String, _ data: String? = nil) {
        let inner = data.map { #","Data":\#($0)"# } ?? ""
        controller.feed(#"{"MessageType":"SyncPlayGroupUpdate","Data":{"GroupId":"g1","Type":"\#(type)"\#(inner)}}"#)
    }

    func joined() {
        update("GroupJoined", #"{"GroupId":"g1","GroupName":"Filmabend","State":"Idle","Participants":["Anna","Bob"],"LastUpdatedAt":"\#(Self.stamp())"}"#)
    }

    func queue(title: String = "i1", since: Int = 0, playing: Bool = false) {
        update(
            "PlayQueue",
            #"{"Reason":"NewPlaylist","LastUpdate":"\#(Self.stamp())","Playlist":[{"ItemId":"\#(title)","PlaylistItemId":"p1"}],"PlayingItemIndex":0,"StartPositionTicks":\#(since * 10_000_000),"IsPlaying":\#(playing)}"#)
    }

    func command(_ name: String, ticks: Int? = nil) {
        let position = ticks.map { #","PositionTicks":\#($0)"# } ?? ""
        controller.feed(
            #"{"MessageType":"SyncPlayCommand","Data":{"GroupId":"g1","PlaylistItemId":"p1","When":"\#(Self.stamp())","EmittedAt":"\#(Self.stamp())","Command":"\#(name)"\#(position)}}"#)
    }

    func attach(ready: Bool = true, spot: Double = 0) {
        controller.playerAttached(SyncPlayPlayer(title: "i1", ready: ready, spot: spot))
        machine = TogetherState.reduce(machine, .playerAttached)
    }
}

@Suite(.serialized) struct SyncPlayScriptTests {
    @Test @MainActor func joinShowsTheGroupAndWhoIsThere() async throws {
        let s = try await Script.start()
        defer { Task { await s.stop() } }
        s.controller.refresh()
        #expect(await s.settle { s.page.groups.count == 1 })
        #expect(s.page.groups[0].name == "Filmabend")
        #expect(s.machine == .idle)
        s.controller.join("g1")
        #expect(await s.settle { s.posts("Join") == 1 && s.page.works })
        #expect(s.machine == .working)
        s.joined()
        #expect(await s.settle { s.page.current?.name == "Filmabend" })
        #expect(s.machine.inGroup)
        #expect(s.page.current?.withWhom.contains("Bob") == true)
        #expect(s.page.detail.group?.names.contains("Bob") == true)
        #expect(s.page.detail.accepted > 0)
        s.update("UserJoined", #""Carla""#)
        #expect(await s.settle { s.page.detail.noticeKind == "dabei" && s.page.notice != nil })
    }

    @Test @MainActor func pauseUnpauseAndSeekReachTheServerAndThePlayer() async throws {
        let s = try await Script.start()
        defer { Task { await s.stop() } }
        s.joined()
        #expect(await s.settle { s.machine.inGroup })
        s.queue()
        #expect(await eventuallyOnMain { s.host.loads == ["i1@0"] })
        s.attach()
        #expect(s.machine == .watching(.empty) || s.machine.phase != nil)
        #expect(await eventuallyOnMain { s.posts("Ready") >= 1 })
        // Requests go to the server; the player moves when the command comes back.
        s.controller.requestToggle(runningNow: false)
        #expect(await eventuallyOnMain { s.posts("Unpause") == 1 })
        s.controller.requestToggle(runningNow: true)
        #expect(await eventuallyOnMain { s.posts("Pause") == 1 })
        s.controller.requestJump(45)
        #expect(await eventuallyOnMain { s.posts("Seek") == 1 })
        let before = s.host.steps.count  // the queue opened paused
        #expect(before <= 1)
        s.command("Unpause")
        #expect(await eventuallyOnMain { s.host.steps.contains(.proceed) })
        s.command("Pause")
        #expect(await eventuallyOnMain { s.host.steps.contains(.halt) })
        s.command("Seek", ticks: 300_000_000)
        #expect(await eventuallyOnMain { s.host.steps.contains(.jump(seconds: 30)) })
    }

    @Test @MainActor func bufferingIsReportedAndTheGroupWaits() async throws {
        let s = try await Script.start()
        defer { Task { await s.stop() } }
        s.joined()
        s.queue()
        s.attach()
        #expect(await eventuallyOnMain { s.posts("Ready") >= 1 })
        s.update("StateUpdate", #"{"State":"Waiting","Reason":"Buffer"}"#)
        #expect(await s.settle { s.machine.phase == .waits })
        // The group runs, the picture stands still for 3 s: "Buffering".
        s.command("Unpause")
        #expect(await eventuallyOnMain { s.host.steps.contains(.proceed) })
        for _ in 0..<9 {
            s.controller.playerUpdate(SyncPlayPlayer(title: "i1", ready: false, spot: 5))
            s.controller.playerTick()
            try await Task.sleep(for: .milliseconds(500))
        }
        #expect(await eventuallyOnMain { s.posts("Buffering") >= 1 })
    }

    @Test @MainActor func leavingRemembersTheGroupForRejoin() async throws {
        let s = try await Script.start()
        defer { Task { await s.stop() } }
        s.joined()
        #expect(await s.settle { s.machine.inGroup })
        s.controller.leave()
        #expect(await eventuallyOnMain { s.posts("Leave") == 1 })
        s.update("GroupLeft")
        #expect(await s.settle { s.page.current == nil })
        #expect(s.page.lastLeave == "Filmabend")
        #expect(!s.machine.inGroup)
        s.controller.rejoin()
        #expect(await eventuallyOnMain { s.posts("Join") == 1 })
    }

    @Test @MainActor func aClosedGroupCleansUpWithAnError() async throws {
        let s = try await Script.start()
        defer { Task { await s.stop() } }
        s.joined()
        #expect(await s.settle { s.machine.inGroup })
        s.update("GroupDoesNotExist")
        #expect(await s.settle { s.page.current == nil && s.page.detail.errorCount == 1 })
        #expect(s.page.error != nil)
        #expect(!s.machine.inGroup)
        s.controller.dismissError()
        #expect(await s.settle { s.page.error == nil })
    }

    @Test @MainActor func aLostConnectionKeepsTheGroupUntilItIsBackAndJoinsAgain() async throws {
        let s = try await Script.start()
        defer { Task { await s.stop() } }
        s.joined()
        s.queue()
        #expect(await s.settle { s.machine.inGroup })
        s.controller.linkLost()
        s.controller.linkAgain()
        #expect(await eventuallyOnMain { s.posts("Join") >= 1 })
        s.joined()
        #expect(await s.settle { s.machine.inGroup })
    }
}

@Suite struct TogetherStateTests {
    private func page(group: String? = nil, works: Bool = false, create: Bool = false) -> SyncPlayPage {
        let detail = SyncPlayDetail(
            offerings: [],
            group: group.map { SyncPlayGroupDetail(id: "g", name: "G", participants: [], names: [], phase: $0) },
            other: [], noticeKind: nil, noticeId: nil, errorLast: nil, errorCount: 0, accepted: 0)
        return SyncPlayPage(
            version: 1, groups: [], mayCreate: create, mayJoin: create, current: nil, notice: nil, error: nil,
            works: works, queueTitle: nil, lastLeave: nil, detail: detail)
    }

    @Test func theTransitionTable() {
        typealias S = TogetherState
        let table: [(S, S.Event, S)] = [
            (.off, .page(page(create: true)), .idle),
            (.idle, .page(page()), .off),
            (.idle, .page(page(works: true, create: true)), .working),
            (.working, .page(page(group: "laeuft")), .inGroup(.running)),
            (.inGroup(.running), .page(page(group: "wartet")), .inGroup(.waits)),
            (.inGroup(.waits), .playerAttached, .watching(.waits)),
            (.watching(.waits), .page(page(group: "angehalten")), .watching(.halted)),
            (.watching(.halted), .page(page(group: nil, create: true)), .idle),
            (.watching(.halted), .playerDetached, .inGroup(.halted)),
            (.inGroup(.empty), .page(page(group: "zzz")), .inGroup(.empty)),
            (.idle, .playerAttached, .idle),  // illegal: no group
            (.working, .playerDetached, .working),  // illegal
            (.inGroup(.running), .unavailable, .off),
        ]
        for (from, event, to) in table { #expect(S.reduce(from, event) == to) }
    }
}
