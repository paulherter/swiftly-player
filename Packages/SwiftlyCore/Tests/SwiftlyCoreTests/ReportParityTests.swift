import Foundation
import Synchronization
import Testing

import JellyfinKit
@testable import SwiftlyCore

/// **The old report path (`ReportQueue` + `JellyfinClient`, as `AppModel.messages` used it) and the
/// core's `PlayReporter` on the same events**, compared on what the server receives: the requests in
/// order (path and the JSON body, key by key) and the outcome the stop reports back. Scenarios: the
/// normal run (start, progress, pause, stop, a late progress, a second stop), a slow start with progress
/// piling up behind it (coalescing, the stop takes the unsent progress with it), and a stop the server
/// refuses (kept for the next connection, the lock released so the retry goes out, the kept position
/// forgotten once it got through). A difference here is a core bug: fix it in the crate.
@Suite(.serialized) struct ReportParityTests {
    struct Row: Equatable, CustomStringConvertible {
        var path: String
        var body: String
        var description: String { "\(path) \(body)" }
    }

    // MARK: Old side

    final class OldServer: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var rows: [Row] = []
        nonisolated(unsafe) static var slowStart = false
        nonisolated(unsafe) static var refuseStop = false
        static let lock = NSLock()
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            let path = request.url?.path ?? ""
            let body = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buffer, maxLength: buffer.count)
                    if n <= 0 { break }
                    data.append(buffer, count: n)
                }
                return data
            } ?? Data()
            let respond = { [self] in
                Self.lock.lock()
                Self.rows.append(Row(path: path, body: canonical(body)))
                Self.lock.unlock()
                let refused = Self.refuseStop && path.hasSuffix("/Stopped")
                let response = HTTPURLResponse(url: request.url!, statusCode: refused ? 500 : 204,
                                               httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            }
            if Self.slowStart && path == "/Sessions/Playing" {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.4, execute: respond)
            } else {
                respond()
            }
        }
        override func stopLoading() {}
    }

    struct Payload: Sendable {
        var item: String
        var plan: PlaybackPlan
        var seconds: Double
        var audio: Int?
        var subtitle: Int?
    }

    /// The dispatch of the old `AppModel.messages`.
    func oldQueue() -> (ReportQueue<Payload>, JellyfinClient) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OldServer.self]
        let client = JellyfinClient(
            baseURL: URL(string: "http://srv.test")!, deviceID: "test-device", deviceName: "Test",
            session: Session(accessToken: "TOKEN", userID: "u1", userName: "", serverURL: URL(string: "http://srv.test")!),
            urlSession: URLSession(configuration: configuration))
        let queue = ReportQueue<Payload> { message in
            let p = message.payload
            let ticks = JellyfinClient.ticks(fromSeconds: p.seconds)
            switch message.art {
            case .start:
                try? await client.reportCapabilities()
                try await client.reportStart(itemID: p.item, plan: p.plan, ticks: ticks,
                                             tracks: TrackIndices(audio: p.audio, subtitle: p.subtitle))
            case .progress(let paused):
                try await client.reportProgress(itemID: p.item, plan: p.plan, positionTicks: ticks, paused: paused,
                                                tracks: TrackIndices(audio: p.audio, subtitle: p.subtitle))
            case .stop:
                try await client.reportStopped(itemID: p.item, plan: p.plan, positionTicks: ticks)
            }
        }
        return (queue, client)
    }

    static func plan() -> PlaybackPlan {
        PlaybackPlan.fromSlab(URL(string: "http://srv.test/Videos/m1/stream")!, container: "mkv", mediaSourceID: "m1")
    }

    // MARK: New side

    final class NewServer: HttpClient {
        let rows = Mutex<[Row]>([])
        let slowStart: Bool
        let refuseStop = Mutex(false)
        init(slowStart: Bool) { self.slowStart = slowStart }
        func send(request: NetRequest) async throws -> NetResponse {
            let path = URL(string: request.url)?.path ?? ""
            if slowStart && path == "/Sessions/Playing" { try await Task.sleep(for: .milliseconds(400)) }
            rows.withLock { $0.append(Row(path: path, body: canonical(request.body ?? Data()))) }
            let refused = refuseStop.withLock { $0 } && path.hasSuffix("/Stopped")
            return NetResponse(status: refused ? 500 : 204, headers: [], body: Data(), url: request.url)
        }
    }

    func newReporter(_ http: NewServer, store: MemoryKeyValue = MemoryKeyValue()) throws -> PlayReporter {
        let core = Core(platform: FakePlatform(), secrets: FakeSecrets(), store: store, http: http)
        let account = AccountRef(baseUrl: "http://srv.test", userId: "u1", token: "TOKEN", serverKind: .jellyfin,
                                 deviceId: "test-device")
        return try core.playReporter(account: account, locale: "de", accountKey: "u1")
    }

    static let planB = PlayReportPlan(playSessionId: nil, mediaSourceId: "m1", method: .directPlay, runtimeMs: nil)

    static func name(_ outcome: ReportQueue<Payload>.Outcome) -> String {
        switch outcome {
        case .sent: "sent"
        case .failed: "failed"
        case .timeOverStep: "timeOut"
        case .discarded: "discarded"
        }
    }

    static func name(_ outcome: PlayReportOutcome) -> String {
        switch outcome {
        case .sent: "sent"
        case .failed: "failed"
        case .timedOut: "timeOut"
        case .discarded: "discarded"
        }
    }

    func payload(_ seconds: Double, audio: Int? = 1, subtitle: Int? = nil) -> Payload {
        Payload(item: "m1", plan: Self.plan(), seconds: seconds, audio: audio, subtitle: subtitle)
    }

    func key() -> String { StopLock.key(itemID: "m1", playSessionID: nil) }

    // MARK: Scenarios

    @Test func theNormalRun() async throws {
        OldServer.rows = []; OldServer.slowStart = false; OldServer.refuseStop = false
        let (queue, _) = oldQueue()
        func old(_ art: ReportQueue<Payload>.Art, _ seconds: Double) -> ReportQueue<Payload>.Message {
            .init(art: art, key: key(), payload: payload(seconds))
        }
        queue.report(old(.start, 0))
        try await Task.sleep(for: .milliseconds(150))
        queue.report(old(.progress(paused: false), 10))
        try await Task.sleep(for: .milliseconds(150))
        queue.report(old(.progress(paused: true), 20))
        try await Task.sleep(for: .milliseconds(150))
        let oldStop = Self.name(await queue.reportAndWait(old(.stop, 100)))
        let oldLate = queue.report(old(.progress(paused: false), 110))
        let oldSecond = Self.name(await queue.reportAndWait(old(.stop, 111)))

        let http = NewServer(slowStart: false)
        let reporter = try newReporter(http)
        reporter.start(itemId: "m1", plan: Self.planB, seconds: 0, audio: 1, subtitle: nil)
        try await Task.sleep(for: .milliseconds(150))
        _ = reporter.progress(itemId: "m1", plan: Self.planB, seconds: 10, paused: false, audio: 1, subtitle: nil)
        try await Task.sleep(for: .milliseconds(150))
        _ = reporter.progress(itemId: "m1", plan: Self.planB, seconds: 20, paused: true, audio: 1, subtitle: nil)
        try await Task.sleep(for: .milliseconds(150))
        let newStop = Self.name(try await reporter.stop(itemId: "m1", plan: Self.planB, seconds: 100))
        let newLate = reporter.progress(itemId: "m1", plan: Self.planB, seconds: 110, paused: false, audio: 1, subtitle: nil)
        let newSecond = Self.name(try await reporter.stop(itemId: "m1", plan: Self.planB, seconds: 111))

        #expect(oldStop == "sent" && newStop == oldStop)
        #expect(oldLate == false && newLate == oldLate)
        #expect(oldSecond == "discarded" && newSecond == oldSecond)
        #expect(compare(OldServer.rows, http.rows.withLock { $0 }))
        #expect(OldServer.rows.map(\.path) == [
            "/Sessions/Capabilities/Full", "/Sessions/Playing", "/Sessions/Playing/Progress",
            "/Sessions/Playing/Progress", "/Sessions/Playing/Stopped",
        ])
    }

    @Test func aSlowStartCoalescesAndTheStopTakesTheUnsentProgress() async throws {
        OldServer.rows = []; OldServer.slowStart = true; OldServer.refuseStop = false
        defer { OldServer.slowStart = false }
        let (queue, _) = oldQueue()
        func old(_ art: ReportQueue<Payload>.Art, _ seconds: Double) -> ReportQueue<Payload>.Message {
            .init(art: art, key: key(), payload: payload(seconds))
        }
        queue.report(old(.start, 0))
        queue.report(old(.progress(paused: false), 5))
        queue.report(old(.progress(paused: false), 6))
        queue.report(old(.progress(paused: true), 7))
        let oldStop = Self.name(await queue.reportAndWait(old(.stop, 50)))

        let http = NewServer(slowStart: true)
        let reporter = try newReporter(http)
        reporter.start(itemId: "m1", plan: Self.planB, seconds: 0, audio: 1, subtitle: nil)
        for (s, paused) in [(5.0, false), (6, false), (7, true)] {
            _ = reporter.progress(itemId: "m1", plan: Self.planB, seconds: s, paused: paused, audio: 1, subtitle: nil)
        }
        let newStop = Self.name(try await reporter.stop(itemId: "m1", plan: Self.planB, seconds: 50))

        #expect(oldStop == "sent" && newStop == oldStop)
        #expect(compare(OldServer.rows, http.rows.withLock { $0 }))
        #expect(OldServer.rows.map(\.path) == [
            "/Sessions/Capabilities/Full", "/Sessions/Playing", "/Sessions/Playing/Stopped",
        ])
    }

    @Test func aRefusedStopIsKeptAndTheRetryGoesOut() async throws {
        OldServer.rows = []; OldServer.slowStart = false; OldServer.refuseStop = true
        defer { OldServer.refuseStop = false }
        let (queue, _) = oldQueue()
        let message = ReportQueue<Payload>.Message(art: .stop, key: key(), payload: payload(300))
        let oldFirst = Self.name(await queue.reportAndWait(message))
        OldServer.refuseStop = false
        let oldRetry = Self.name(await queue.reportAndWait(message))

        let store = MemoryKeyValue()
        let http = NewServer(slowStart: false)
        http.refuseStop.withLock { $0 = true }
        let reporter = try newReporter(http, store: store)
        let newFirst = Self.name(try await reporter.stop(itemId: "m1", plan: Self.planB, seconds: 300))
        // What the old `AppModel.reportLater` would have stored, as the old code reads it.
        let kept = try JSONDecoder().decode([PendingReport].self, from: #require(store.get(key: "pending.reports")))
        #expect(kept.count == 1)
        #expect(kept.first?.itemID == "m1" && kept.first?.account == "u1" && kept.first?.ticks == 3_000_000_000)
        http.refuseStop.withLock { $0 = false }
        let newRetry = Self.name(try await reporter.stop(itemId: "m1", plan: Self.planB, seconds: 300))
        // It got through after all: the kept one must never go out afterwards.
        let after = try JSONDecoder().decode([PendingReport].self, from: #require(store.get(key: "pending.reports")))

        #expect(oldFirst == "failed" && newFirst == oldFirst)
        #expect(oldRetry == "sent" && newRetry == oldRetry)
        #expect(after.isEmpty)
        #expect(compare(OldServer.rows, http.rows.withLock { $0 }))
    }

    /// Same requests in the same order. The capabilities body carries device facts the two sides
    /// name differently in this test, so it is compared by path only.
    func compare(_ old: [Row], _ new: [Row]) -> Bool {
        func cut(_ rows: [Row]) -> [Row] {
            rows.map { $0.path.hasSuffix("Capabilities/Full") ? Row(path: $0.path, body: "") : $0 }
        }
        let same = cut(old) == cut(new)
        if !same { Issue.record("old \(old)\nnew \(new)") }
        return same
    }
}

/// The JSON of a body with sorted keys, so the key order does not matter.
private func canonical(_ data: Data) -> String {
    guard !data.isEmpty, let object = try? JSONSerialization.jsonObject(with: data),
          let sorted = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    else { return String(decoding: data, as: UTF8.self) }
    return String(decoding: sorted, as: UTF8.self)
}
