import Foundation
import Testing
@testable import JellyfinKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// **Two devices in a group, against a simulated server.**
///
/// The server here does what Jellyfin's `SyncPlay` group does as far as
/// synchronization goes: accept requests, wait for everyone, distribute commands
/// with a timestamp in the future. Its clock runs 2.5 s ahead, and the
/// two devices hear it at different speeds (30 and 150 ms); the time
/// sync has to absorb both. What is measured is when and where the two players
/// continue, pause, and stand after a jump.
@Suite("SyncPlay: zwei Geräte im Gleichschritt", .serialized)
struct SyncPlaySameStepTests {

    // MARK: The simulated server

    final class GroupsServer: @unchecked Sendable {
        static let clockPreRun: TimeInterval = 2.5
        static let barrier = NSLock()
        nonisolated(unsafe) static var ongoing: GroupsServer?

        struct Member { let name: String; let session: SyncPlaySession; let lag: Double }
        var members: [String: Member] = [:]   // device ID
        var inside: Set<String> = []
        var ready: Set<String> = []
        var title = ""
        var entryRecord = "p1"
        var spot: Double = 0
        var pointOff = Date()          // server time from which `spot` applies, while playing
        var running = false
        var nextPostJump = false
        var log: [String] = []

        func now() -> Date { Date().addingTimeInterval(Self.clockPreRun) }

        func currentPoint() -> Double {
            running ? spot + now().timeIntervalSince(pointOff) : spot
        }

        func dispatch(_ an: String, _ n: SyncPlayPostDirection) {
            guard let m = members[an] else { return }
            Task {
                try? await Task.sleep(for: .seconds(m.lag))
                m.session.accept(n)
            }
        }
        func forAll(_ n: SyncPlayPostDirection) { for id in inside { dispatch(id, n) } }

        func command(_ art: SyncPlayCommand.Art, in seconds: Double) {
            let b = SyncPlayCommand(group: "g1", entryRecord: entryRecord, art: art,
                                   moment: now().addingTimeInterval(seconds),
                                   spot: currentPoint(), emitted: now())
            log.append("Server: \(art.rawValue) bei \(String(format: "%.2f", b.spot ?? 0)) s")
            forAll(.command(b))
        }

        func group() -> SyncPlayGroup {
            SyncPlayGroup(id: "g1", name: "Messlauf", condition: running ? .running : .halted,
                           participant: inside.compactMap { members[$0]?.name }.sorted())
        }

        func queue() -> SyncPlayQueue {
            .init(reason: "NewPlaylist", state: now(), entries: [.init(title: title, entryRecord: entryRecord)],
                  index: 0, startPoint: spot, running: running)
        }

        /// A call from a device. Returns the body of the response.
        func call(_ device: String, _ path: String, _ shell: [String: Any]) -> Data {
            Self.barrier.lock(); defer { Self.barrier.unlock() }
            switch path {
            case "GetUtcTime":
                let t = SyncPlay.timeText(now())
                return Data(#"{"RequestReceptionTime":"\#(t)","ResponseTransmissionTime":"\#(t)"}"#.utf8)
            case "SyncPlay/New":
                ready = []
                inside = [device]
                dispatch(device, .joined(group()))
            case "SyncPlay/Join":
                for id in inside { dispatch(id, .someoneJoined(members[device]!.name)) }
                inside.insert(device)
                dispatch(device, .joined(group()))
                ready.remove(device)
                dispatch(device, .queue(queue()))
            case "SyncPlay/SetNewQueue":
                title = (shell["PlayingQueue"] as? [String])?.first ?? ""
                spot = SyncPlay.seconds((shell["StartPositionTicks"] as? NSNumber)?.int64Value ?? 0)
                running = false
                ready = []
                forAll(.queue(queue()))
            case "SyncPlay/Ready":
                ready.insert(device)
                if ready.count == inside.count, nextPostJump {
                    nextPostJump = false
                    command(.proceed, in: 0.5)
                    running = true; pointOff = now().addingTimeInterval(0.5)
                }
            case "SyncPlay/Unpause":
                guard ready.count == inside.count else { break }
                // Like Jellyfin: in the future, so everyone hears it in time.
                command(.proceed, in: 0.5)
                running = true; pointOff = now().addingTimeInterval(0.5)
            case "SyncPlay/Pause":
                spot = currentPoint(); running = false
                command(.pause, in: 0)
            case "SyncPlay/Seek":
                nextPostJump = running
                running = false
                spot = SyncPlay.seconds((shell["PositionTicks"] as? NSNumber)?.int64Value ?? 0)
                ready = []
                command(.jump, in: 0)
            default:
                break
            }
            return Data()
        }
    }

    final class Line: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            let path = String(request.url!.path.dropFirst())
            let header = request.value(forHTTPHeaderField: "Authorization") ?? ""
            let device = header.components(separatedBy: "DeviceId=\"").dropFirst().first?
                .components(separatedBy: "\"").first ?? "?"
            var data = request.httpBody ?? Data()
            if data.isEmpty, let feed = request.httpBodyStream {
                feed.open()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while feed.hasBytesAvailable {
                    let n = feed.read(&buffer, maxLength: buffer.count)
                    if n <= 0 { break }
                    data.append(buffer, count: n)
                }
                feed.close()
            }
            let shell = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let responseData = GroupsServer.ongoing?.call(device, path, shell) ?? Data()
            let answer = HTTPURLResponse(url: request.url!, statusCode: responseData.isEmpty ? 204 : 200,
                                          httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: answer, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseData)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    // MARK: A player with a clock

    final class ClockPlayer: SyncPlayPlayer, @unchecked Sendable {
        private let barrier = NSLock()
        private let id: String
        private var base: Double = 0
        private var since = Date()
        private var running = false
        private(set) var advanceBy: [Date] = []
        init(_ id: String) { self.id = id }
        private func now() -> Double { running ? base + Date().timeIntervalSince(since) : base }
        func nextTimes() -> [Date] { barrier.withLock { advanceBy } }
        func title() async -> String { id }
        func ready() async -> Bool { true }
        func spot() async -> Double { barrier.withLock { now() } }
        func proceed() async { barrier.withLock { base = now(); since = Date(); running = true; advanceBy.append(Date()) } }
        func halt() async { barrier.withLock { base = now(); running = false } }
        func jump(_ target: Double) async { barrier.withLock { base = target; since = Date() } }
    }

    private func device(_ id: String, _ name: String, lag: Double, server: GroupsServer)
        -> (SyncPlaySession, ClockPlayer) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Line.self]
        let address = URL(string: "https://tv.example.de")!
        let c = JellyfinClient(baseURL: address, deviceID: id, deviceName: name,
                               session: .init(accessToken: "tok-\(id)", userID: "u-\(id)",
                                              userName: name, serverURL: address),
                               urlSession: URLSession(configuration: config))
        let player = ClockPlayer("i1")
        let s = SyncPlaySession(client: { c }, ich: { name }, titleLoad: { _, _ in true })
        GroupsServer.barrier.withLock {
            server.members[id] = .init(name: name, session: s, lag: lag)
        }
        return (s, player)
    }

    private func until(_ deadline: Double = 5, _ requirement: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if await requirement() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await requirement()
    }

    @Test func pausePlaySeekArriveTogether() async throws {
        let server = GroupsServer()
        GroupsServer.ongoing = server
        defer { GroupsServer.ongoing = nil }
        var log: [String] = []
        func jotDown(_ s: String) { log.append(s) }

        let (a, playerA) = device("a", "Paul", lag: 0.03, server: server)
        let (b, playerB) = device("b", "Tom", lag: 0.15, server: server)
        await a.plugIn(playerA)
        await b.plugIn(playerB)

        // A creates, B joins.
        #expect(await a.create(name: "Messlauf", title: "i1"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(await b.join(SyncPlayGroup(id: "g1", name: "Messlauf")))
        // Both measure the clock and report "ready".
        #expect(await until { GroupsServer.barrier.withLock { server.ready.count } == 2 })
        #expect(await until {
            let x = await a.reconcile.ready
            let y = await b.reconcile.ready
            return x && y
        })
        let offsetA = await a.reconcile.offset, offsetB = await b.reconcile.offset
        jotDown("Uhr: A \(Int(offsetA * 1000)) ms, B \(Int(offsetB * 1000)) ms (Server geht 2500 ms vor)")
        #expect(abs(offsetA - GroupsServer.clockPreRun) < 0.1)
        #expect(abs(offsetB - GroupsServer.clockPreRun) < 0.1)

        func spacing(_ was: String) async -> Double {
            let sa = await playerA.spot(), sb = await playerB.spot()
            jotDown("\(was): A \(String(format: "%.3f", sa)) s · B \(String(format: "%.3f", sb)) s · Versatz \(Int(abs(sa - sb) * 1000)) ms")
            return abs(sa - sb)
        }
        func startSpacing(_ n: Int) -> Double {
            let ta = playerA.nextTimes(), tb = playerB.nextTimes()
            guard ta.count > n, tb.count > n else { return .infinity }
            let d = abs(ta[n].timeIntervalSince(tb[n]))
            jotDown("Weiter Nr. \(n + 1): Start liegt \(Int(d * 1000)) ms auseinander")
            return d
        }

        // Continue (B asks, the slower one).
        await b.bitToggle(runningCurrently: false)
        #expect(await until { playerA.nextTimes().count == 1 && playerB.nextTimes().count == 1 })
        #expect(startSpacing(0) < 0.1)
        try await Task.sleep(for: .seconds(1.5))
        #expect(await spacing("nach 1,5 s Lauf") < 0.1)

        // Pause (A asks).
        await a.bitToggle(runningCurrently: true)
        try await Task.sleep(for: .milliseconds(600))
        // The pause applies "now"; whoever hears it later stops later. Under
        // the jump threshold it stays where it is (like jellyfin-web).
        #expect(await spacing("angehalten") < SyncPlay.jumpLimit + 0.05)

        // Seek to 300 s while stopped, then continue.
        await a.bitJump(on: 300)
        #expect(await until { GroupsServer.barrier.withLock { server.ready.count } == 2 })
        #expect(await spacing("nach dem Sprung") < 0.1)
        #expect(abs(await playerA.spot() - 300) < 0.5)
        await b.bitToggle(runningCurrently: false)
        #expect(await until { playerA.nextTimes().count >= 3 && playerB.nextTimes().count >= 3 })
        #expect(startSpacing(playerA.nextTimes().count - 1) < 0.1)
        try await Task.sleep(for: .seconds(1))
        #expect(await spacing("nach 1 s Lauf") < 0.1)

        // Seek while playing: everyone stops, jumps, and continues together.
        let beforeA = playerA.nextTimes().count, beforeB = playerB.nextTimes().count
        await b.bitJump(on: 120)
        // Once to prime after the jump, once for the shared continue.
        #expect(await until { playerA.nextTimes().count >= beforeA + 2
                            && playerB.nextTimes().count >= beforeB + 2 })
        try await Task.sleep(for: .seconds(1))
        #expect(await spacing("Sprung im Lauf, danach") < 0.1)
        #expect(abs(await playerA.spot() - 120) < 3)

        await a.bitToggle(runningCurrently: true)
        try await Task.sleep(for: .milliseconds(600))
        #expect(await spacing("zum Schluss angehalten") < SyncPlay.jumpLimit + 0.05)

        await a.detach(); await b.detach()
        for row in GroupsServer.barrier.withLock({ server.log }) + log {
            print("[Gleichschritt] \(row)")
        }
    }
}
