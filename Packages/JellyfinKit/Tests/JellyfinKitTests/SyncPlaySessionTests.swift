import Foundation
import Testing
@testable import JellyfinKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The group flow against a server that only records, and a
/// player that only counts. The times are real, but short.
@Suite("SyncPlay: Sitzung", .serialized)
struct SyncPlaySessionTests {

    // MARK: A server that records

    final class WithFont: URLProtocol, @unchecked Sendable {
        struct Invocation: Sendable { let path: String; let shell: [String: String] }
        nonisolated(unsafe) static var calls: [Invocation] = []
        nonisolated(unsafe) static var denied: Set<String> = []
        static let barrier = NSLock()

        static func reset() {
            barrier.withLock { calls = []; denied = [] }
        }
        static func all(_ path: String) -> [Invocation] {
            barrier.withLock { calls.filter { $0.path == path } }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }

        override func startLoading() {
            let path = String(request.url!.path.dropFirst())
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
            var shell: [String: String] = [:]
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (k, v) in json { shell[k] = "\(v)" }
            }
            Self.barrier.lock()
            Self.calls.append(.init(path: path, shell: shell))
            let no = Self.denied.contains(path)
            Self.barrier.unlock()

            let body: Data
            if path == "GetUtcTime" {
                let now = SyncPlay.timeText(Date())
                body = Data(#"{"RequestReceptionTime":"\#(now)","ResponseTransmissionTime":"\#(now)"}"#.utf8)
            } else {
                body = Data()
            }
            let answer = HTTPURLResponse(url: request.url!, statusCode: no ? 403 : 204,
                                          httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: answer, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private static let server = URL(string: "https://tv.example.de")!

    private static func client() -> JellyfinClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WithFont.self]
        return JellyfinClient(baseURL: server, deviceID: "dev-1", deviceName: "Prueflauf",
                              session: .init(accessToken: "tok", userID: "u1", userName: "Paul",
                                             serverURL: server),
                              urlSession: URLSession(configuration: config))
    }

    // MARK: A player that counts

    final class ProbePlayer: SyncPlayPlayer, @unchecked Sendable {
        private let barrier = NSLock()
        private var _title: String
        private var _ready: Bool
        private var base: Double
        private var since = Date()
        private var running = false
        private(set) var steps: [String] = []
        private(set) var advanceBy: Date?

        init(title: String, ready: Bool = true, spot: Double = 0) {
            _title = title; _ready = ready; base = spot
        }

        private func now() -> Double {
            running ? base + Date().timeIntervalSince(since) : base
        }
        func log() -> [String] { barrier.withLock { steps } }
        func nextTime() -> Date? { barrier.withLock { advanceBy } }

        func title() async -> String { barrier.withLock { _title } }
        func ready() async -> Bool { barrier.withLock { _ready } }
        func spot() async -> Double { barrier.withLock { now() } }
        func proceed() async {
            barrier.withLock {
                base = now(); since = Date(); running = true
                advanceBy = Date()
                steps.append("weiter")
            }
        }
        func halt() async {
            barrier.withLock {
                base = now(); running = false
                steps.append("anhalten")
            }
        }
        func jump(_ target: Double) async {
            barrier.withLock {
                base = target; since = Date()
                steps.append("springen \(Int(target.rounded()))")
            }
        }
    }

    final class LoadList: @unchecked Sendable {
        private let barrier = NSLock()
        private var list: [(String, Double)] = []
        func remember(_ t: String, _ since: Double) { barrier.withLock { list.append((t, since)) } }
        func all() -> [(String, Double)] { barrier.withLock { list } }
    }

    // MARK: Helpers

    private let loaded = LoadList()

    private func session() -> SyncPlaySession {
        WithFont.reset()
        let c = Self.client()
        let list = loaded
        return SyncPlaySession(client: { c }, ich: { "Paul" },
                               titleLoad: { t, since in list.remember(t, since); return true })
    }

    /// Waits until it holds, at most `deadline` seconds.
    private func until(_ deadline: Double = 3, _ requirement: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if await requirement() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await requirement()
    }

    private let group = SyncPlayGroup(id: "g1", name: "Filmabend", condition: .empty, participant: ["Paul"])

    private func queue(_ title: String = "i1", entryRecord: String = "p1", since: Double = 0) -> SyncPlayQueue {
        .init(reason: "NewPlaylist", state: Date(), entries: [.init(title: title, entryRecord: entryRecord)],
              index: 0, startPoint: since, running: false)
    }

    /// In the group, title loaded, "ready" reported.
    private func loadedSession(spot: Double = 60) async -> (SyncPlaySession, ProbePlayer) {
        let s = session()
        let p = ProbePlayer(title: "i1", spot: spot)
        s.accept(.joined(group))
        #expect(await until { await s.status.group != nil })
        await s.plugIn(p)
        s.accept(.queue(queue(since: spot)))
        #expect(await until { !WithFont.all("SyncPlay/Ready").isEmpty })
        return (s, p)
    }

    // MARK: Tests

    @Test func joinAndWhoCame() async {
        let s = session()
        s.accept(.joined(group))
        s.accept(.someoneJoined("Tom"))
        #expect(await until { await s.status.group?.participant == ["Paul", "Tom"] })
        #expect(await s.status.event?.art == .present("Tom"))
        #expect(await s.status.event?.text.contains("Tom") == true)

        // Oneself on a second device: no notice.
        let before = await s.status.event?.id
        s.accept(.someoneJoined("Paul"))
        #expect(await until { await s.status.group?.participant.count == 3 })
        #expect(await s.status.event?.id == before)

        s.accept(.someoneLeft("Tom"))
        #expect(await until { await s.status.event?.art == .gone("Tom") })
        // The clock starts after joining.
        #expect(await until { !WithFont.all("GetUtcTime").isEmpty })
    }

    @Test func queueWithoutPlayerOpensIt() async {
        let s = session()
        s.accept(.joined(group))
        s.accept(.queue(queue("i7", since: 42)))
        #expect(await until { !loaded.all().isEmpty })
        #expect(loaded.all().first?.0 == "i7")
        #expect(loaded.all().first?.1 == 42)
        #expect(await s.status.belongsGroup("i7"))

        // The player opens and has the picture: pause and "ready".
        let p = ProbePlayer(title: "i7", spot: 42)
        await s.plugIn(p)
        #expect(await until { !WithFont.all("SyncPlay/Ready").isEmpty })
        #expect(p.log().contains("anhalten"))
        let ready = WithFont.all("SyncPlay/Ready")[0].shell
        #expect(ready["PlaylistItemId"] == "p1")
        #expect(ready["PositionTicks"] == "420000000")
        #expect(ready["IsPlaying"] == "0")
    }

    @Test func nextTimestamp() async {
        let (s, p) = await loadedSession()
        let moment = Date().addingTimeInterval(0.6)
        s.accept(.command(.init(group: "g1", entryRecord: "p1", art: .proceed, moment: moment, spot: 60)))
        #expect(await until { p.nextTime() != nil })
        let um = try! #require(p.nextTime())
        // Not before, and not noticeably after.
        #expect(um.timeIntervalSince(moment) > -0.05)
        #expect(um.timeIntervalSince(moment) < 0.3)
        // Was at the position already: no jump.
        #expect(!p.log().contains { $0.hasPrefix("springen") && $0 != "springen 60" })
    }

    @Test func nextMissedJumpsToWoGroupIs() async {
        let (s, p) = await loadedSession()
        s.accept(.command(.init(group: "g1", entryRecord: "p1", art: .proceed,
                                 moment: Date().addingTimeInterval(-5), spot: 60)))
        #expect(await until { p.nextTime() != nil })
        #expect(p.log().contains("springen 65"))
    }

    @Test func newCommandSolvesWaitingOff() async {
        let (s, p) = await loadedSession()
        s.accept(.command(.init(group: "g1", entryRecord: "p1", art: .proceed,
                                 moment: Date().addingTimeInterval(1), spot: 60)))
        s.accept(.command(.init(group: "g1", entryRecord: "p1", art: .pause,
                                 moment: Date().addingTimeInterval(0.1), spot: 60)))
        try? await Task.sleep(for: .seconds(1.4))
        #expect(p.nextTime() == nil)
        #expect(p.log().filter { $0 == "anhalten" }.count >= 2)
    }

    @Test func jumpPlayAnAndReportTarget() async {
        let (s, p) = await loadedSession()
        let before = WithFont.all("SyncPlay/Ready").count
        s.accept(.command(.init(group: "g1", entryRecord: "p1", art: .jump,
                                 moment: Date(), spot: 120)))
        #expect(await until { WithFont.all("SyncPlay/Ready").count > before })
        let steps = p.log()
        let i = try! #require(steps.lastIndex(of: "springen 120"))
        #expect(Array(steps[i...].prefix(3)) == ["springen 120", "weiter", "anhalten"])
        #expect(WithFont.all("SyncPlay/Ready").last?.shell["PositionTicks"] == "1200000000")
    }

    @Test func commandOtherEntryWaits() async {
        let (s, p) = await loadedSession()
        s.accept(.command(.init(group: "g1", entryRecord: "p9", art: .proceed,
                                 moment: Date(), spot: 0)))
        try? await Task.sleep(for: .milliseconds(300))
        #expect(p.nextTime() == nil)
    }

    @Test func leaveRememberGroup() async {
        let (s, _) = await loadedSession()
        await s.detach()
        #expect(await s.status.group == nil)
        #expect(await s.status.lastLeave?.id == "g1")
        #expect(await s.inPlayer == false)
        #expect(await until { !WithFont.all("SyncPlay/Leave").isEmpty })

        await s.finish()
        #expect(await s.status.lastLeave == nil)
    }

    @Test func bitDeniedComesAsError() async {
        let s = session()
        WithFont.barrier.withLock { WithFont.denied = ["SyncPlay/Pause"] }
        var withPart = s.withPart.makeAsyncIterator()
        await s.bitToggle(runningCurrently: true)
        #expect(!WithFont.all("SyncPlay/Pause").isEmpty)
        var found = false
        for _ in 0..<5 {
            guard let m = await withPart.next() else { break }
            if case .error(.notReleased) = m { found = true; break }
        }
        #expect(found)
    }

    @Test func missingCleansUp() async {
        let (s, _) = await loadedSession()
        s.accept(.doesNotExist)
        #expect(await until { await s.status.group == nil })
        #expect(await s.status.queueTitle == nil)
    }

    @Test func accountSwitchLeavesWithOldClient() async {
        let (s, _) = await loadedSession()
        await s.finish(oldClient: Self.client())
        #expect(await s.status.group == nil)
        #expect(await s.status.lastLeave == nil)
        #expect(await until { !WithFont.all("SyncPlay/Leave").isEmpty })
    }

    @Test func episodesSelectionSetsQueue() async {
        let (s, _) = await loadedSession()
        await s.bitTitle("i2", since: 30)
        let call = WithFont.all("SyncPlay/SetNewQueue").last?.shell
        #expect(call?["StartPositionTicks"] == "300000000")
        #expect(call?["PlayingQueue"]?.contains("i2") == true)
    }

    // MARK: Connection dropped

    @Test func teardownWithReentryRejoinsGroup() async {
        let (s, p) = await loadedSession(spot: 60)
        await s.patienceSet(conduit: 5, attempts: 3, answer: 1, pause: 0.05)
        let readyBefore = WithFont.all("SyncPlay/Ready").count

        s.accept(.connectionLost)
        // The group stays put as long as it is being fought for.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await s.status.group?.id == "g1")
        #expect(WithFont.all("SyncPlay/Join").isEmpty)

        s.accept(.connectionAgain)
        #expect(await until { !WithFont.all("SyncPlay/Join").isEmpty })
        #expect(WithFont.all("SyncPlay/Join")[0].shell["GroupId"] == "g1")

        // The server confirms: report state, no error message.
        s.accept(.joined(group))
        #expect(await until { WithFont.all("SyncPlay/Ready").count > readyBefore })
        #expect(WithFont.all("SyncPlay/Ready").last?.shell["IsPlaying"] == "0")
        #expect(await s.status.group?.id == "g1")
        _ = p
    }

    @Test func teardownWithoutAgainEntryReportLoss() async {
        let (s, _) = await loadedSession()
        await s.patienceSet(conduit: 5, attempts: 2, answer: 0.1, pause: 0.02)
        let hearer = Task<String?, Never> {
            for await m in s.withPart {
                if case let .error(f) = m, case .connectionLost = f { return f.text }
            }
            return nil
        }
        s.accept(.connectionLost)
        s.accept(.connectionAgain)
        // No GroupJoined: after the attempts the group is gone, with a notice.
        #expect(await until { await s.status.group == nil })
        let errorText = await hearer.value
        #expect(WithFont.all("SyncPlay/Join").count == 2)
        #expect(errorText?.isEmpty == false)
    }

    @Test func lineNeverReturns() async {
        let (s, _) = await loadedSession()
        await s.patienceSet(conduit: 0.1, attempts: 1, answer: 0.1, pause: 0.02)
        s.accept(.connectionLost)
        #expect(await until { await s.status.group == nil })
        #expect(WithFont.all("SyncPlay/Join").isEmpty)
    }

    @Test func teardownWithoutGroupDoesNothing() async {
        let s = session()
        s.accept(.connectionLost)
        s.accept(.connectionAgain)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(WithFont.all("SyncPlay/Join").isEmpty)
    }
}
