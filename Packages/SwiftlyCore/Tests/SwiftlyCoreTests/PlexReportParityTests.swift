import Foundation
import Synchronization
import Testing

import JellyfinKit
@testable import SwiftlyCore

/// **Plex playback reports: the old path (`ReportQueue` + `PlexClient`, as `AppModel.messages` used it) and the
/// core's `PlayReporter` on a Plex account**, on the same events (start, progress, pause, stop, a late progress, a
/// second stop). Compared on what the Plex server receives: the requests in order, path and query (the
/// `X-Plex-*` identity parameters are the client's own and left out). A difference is a core bug.
@Suite(.serialized) struct PlexReportParityTests {
    struct Row: Equatable, CustomStringConvertible {
        var path: String
        var query: [String]
        var description: String { "\(path)?\(query.joined(separator: "&"))" }
        init(url: URL?) {
            path = url?.path ?? ""
            let items = URLComponents(url: url ?? URL(string: "x:")!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            query = items.filter { !$0.name.hasPrefix("X-Plex-") }.map { "\($0.name)=\($0.value ?? "")" }.sorted()
        }
    }

    final class OldServer: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var rows: [Row] = []
        static let lock = NSLock()
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            Self.lock.lock(); Self.rows.append(Row(url: request.url)); Self.lock.unlock()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    final class NewServer: HttpClient {
        let rows = Mutex<[Row]>([])
        func send(request: NetRequest) async throws -> NetResponse {
            rows.withLock { $0.append(Row(url: URL(string: request.url))) }
            return NetResponse(status: 200, headers: [], body: Data(), url: request.url)
        }
    }

    static let base = "https://plex.example.test"

    static func plan() throws -> PlaybackPlan {
        let source = try JSONDecoder().decode(
            MediaSource.self, from: Data(#"{"Id":"m1","RunTimeTicks":36000000000}"#.utf8))
        return PlaybackPlan.assembled(
            url: URL(string: "\(base)/video/:/transcode/universal/start")!, method: .directPlay, mediaSourceID: "m1",
            playSessionID: nil, source: source, itemID: "10", profile: .vlc(maxBitrate: 0))
    }

    struct Payload: Sendable { var plan: PlaybackPlan; var seconds: Double }

    @Test func theNormalRunReportsTheSameTimeline() async throws {
        OldServer.rows = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OldServer.self]
        let client = PlexClient(
            baseURL: URL(string: Self.base)!, token: "TOKEN",
            identity: PlexIdentity(clientID: "client-1", product: "Test", version: "1.0", platform: "macOS",
                                   device: "Mac", deviceName: "Test"),
            urlSession: URLSession(configuration: configuration))
        let queue = ReportQueue<Payload> { message in
            let p = message.payload
            let ticks = JellyfinClient.ticks(fromSeconds: p.seconds)
            switch message.art {
            case .start: try await client.reportStart(itemID: "10", plan: p.plan, ticks: ticks)
            case .progress(let paused):
                try await client.reportProgress(itemID: "10", plan: p.plan, positionTicks: ticks, paused: paused)
            case .stop: try await client.reportStopped(itemID: "10", plan: p.plan, positionTicks: ticks)
            }
        }
        let plan = try Self.plan()
        let key = StopLock.key(itemID: "10", playSessionID: nil)
        func old(_ art: ReportQueue<Payload>.Art, _ seconds: Double) -> ReportQueue<Payload>.Message {
            .init(art: art, key: key, payload: Payload(plan: plan, seconds: seconds))
        }
        queue.report(old(.start, 0))
        try await Task.sleep(for: .milliseconds(150))
        queue.report(old(.progress(paused: false), 10))
        try await Task.sleep(for: .milliseconds(150))
        queue.report(old(.progress(paused: true), 20))
        try await Task.sleep(for: .milliseconds(150))
        let oldStop = await queue.reportAndWait(old(.stop, 100))
        let oldLate = queue.report(old(.progress(paused: false), 110))
        let oldSecond = await queue.reportAndWait(old(.stop, 111))

        let http = NewServer()
        let core = Core(platform: FakePlatform(), secrets: FakeSecrets(), store: MemoryKeyValue(), http: http)
        let account = AccountRef(baseUrl: Self.base, userId: "u1", token: "TOKEN", serverKind: .plex,
                                 deviceId: "client-1")
        let reporter = try core.playReporter(account: account, locale: "de", accountKey: "u1")
        let report = PlayReportPlan(playSessionId: nil, mediaSourceId: "m1", method: .directPlay, runtimeMs: 3_600_000)
        reporter.start(itemId: "10", plan: report, seconds: 0, audio: 1, subtitle: nil)
        try await Task.sleep(for: .milliseconds(150))
        _ = reporter.progress(itemId: "10", plan: report, seconds: 10, paused: false, audio: 1, subtitle: nil)
        try await Task.sleep(for: .milliseconds(150))
        _ = reporter.progress(itemId: "10", plan: report, seconds: 20, paused: true, audio: 1, subtitle: nil)
        try await Task.sleep(for: .milliseconds(150))
        let newStop = try await reporter.stop(itemId: "10", plan: report, seconds: 100)
        let newLate = reporter.progress(itemId: "10", plan: report, seconds: 110, paused: false, audio: 1, subtitle: nil)
        let newSecond = try await reporter.stop(itemId: "10", plan: report, seconds: 111)

        #expect("\(oldStop)" == "sent" && "\(newStop)" == "sent")
        #expect(oldLate == false && newLate == false)
        #expect("\(oldSecond)" == "discarded" && "\(newSecond)" == "discarded")
        let new = http.rows.withLock { $0 }.filter { $0.path.hasSuffix("timeline") }
        let oldRows = OldServer.rows.filter { $0.path.hasSuffix("timeline") }
        #expect(oldRows.count == 4)
        if oldRows != new { Issue.record("old \(oldRows)\nnew \(new)") }
        #expect(oldRows == new)
    }
}
