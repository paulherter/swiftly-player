import Foundation
import JellyfinKit
import SwiftlyCore
import Testing

/// Every title of the matrix: the same list for the plan, the play and the download tests.
let benchTitles = [
    "bm-h264-aac-mp4", "bm-h264-aac-mkv", "bm-h264-ac3-mkv", "bm-h264-eac3-mp4", "bm-h264-flac-mkv", "bm-h264-opus-mkv",
    "bm-h264-truehd-mkv", "bm-h264-aac-ts", "bm-hevc8-aac-mp4", "bm-hevc10-eac3-mkv", "bm-av1-opus-mkv",
    "bm-vp9-opus-webm", "bm-mpeg4-mp3-avi", "bm-multi-mkv", "bm-ext-subs", "bm-noduration-mkv",
] + hdrTitles

/// **Column "plan"**: the core's `playPlan` and the shipping line's `PlaybackPlan.make` (old Swift rule) on the same
/// PlaybackInfo of the fixture server: same method, source, session and address, for the Aether profile and both AVPlayer ones.
@Suite(.serialized) struct PlanTests {
    struct Outcome: Equatable, CustomStringConvertible {
        var method: String
        var source: String?
        var session: String?
        var path: String
        var query: [String: String]
        var description: String { "\(method) \(path) \(source ?? "-")" }
    }

    static func outcome(_ url: String, method: String, source: String?, session: String?) -> Outcome {
        let parts = URLComponents(string: url)
        let query = Dictionary(parts?.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { _, last in last })
        return Outcome(method: method, source: source, session: session, path: parts?.path ?? "", query: query)
    }

    @Test(arguments: benchTitles)
    func coreAndOldRuleAgree(_ id: String) async throws {
        let server = BenchServer.shared
        let (info, _) = try await server.data("/Items/\(id)/PlaybackInfo")
        let response = try JSONDecoder().decode(PlaybackInfoResponse.self, from: info)
        let base = URL(string: server.address)!
        var failures: [String] = []
        for (flavour, profile) in [
            (PlayFlavour.aether, DeviceProfile.vlc(maxBitrate: 120_000_000)),
            (.avPlayer, DeviceProfile.airplay(maxBitrate: 120_000_000)),
            (.avPlayerAv1, DeviceProfile.airplay(maxBitrate: 120_000_000, av1: true)),
        ] {
            let (ready, answer) = try await Opened.plan(id, flavour: flavour)
            let old = try PlaybackPlan.make(
                from: response, itemID: id, profile: profile,
                streamURL: { item, source, session in
                    var parts = URLComponents(url: base.appendingPathComponent("Videos/\(item)/stream"), resolvingAgainstBaseURL: false)!
                    var query = [URLQueryItem(name: "static", value: "true"), URLQueryItem(name: "ApiKey", value: "TOKEN")]
                    if let source { query.append(.init(name: "mediaSourceId", value: source)) }
                    if let session { query.append(.init(name: "playSessionId", value: session)) }
                    parts.queryItems = query
                    return parts.url!
                }, serverBase: base, preferredSourceID: nil)
            guard let ready else { failures.append("\(flavour): core answered \(answer)"); continue }
            let method = switch ready.start.method {
            case .directPlay: "directPlay"
            case .directStream: "directStream"
            case .transcode: "transcode"
            }
            let new = Self.outcome(ready.start.url, method: method, source: ready.start.mediaSourceId, session: ready.start.playSessionId)
            let shipping = old.map { Self.outcome($0.url.absoluteString, method: String(describing: $0.method),
                                                  source: $0.mediaSourceID, session: $0.playSessionID) }
            if new != shipping { failures.append("\(flavour): core \(new) <> old \(shipping.map(\.description) ?? "nil")") }
        }
        Record.note(id, "plan", failures.isEmpty, failures.joined(separator: "; "))
        #expect(failures.isEmpty, "\(failures)")
    }

    /// A title the server only converts: the plan is a transcode with the server's own address, the same in both rules.
    @Test func serverThatOnlyConvertsGivesTranscodeInBothRules() async throws {
        let info = #"{"MediaSources":[{"Id":"s1","Container":"mkv","SupportsDirectPlay":false,"SupportsDirectStream":false,"SupportsTranscoding":true,"TranscodingUrl":"/videos/m1/master.m3u8?MediaSourceId=s1","TranscodingSubProtocol":"hls","TranscodingContainer":"ts","DefaultAudioStreamIndex":1,"MediaStreams":[{"Index":0,"Type":"Video","Codec":"hevc","Width":3840,"Height":2160},{"Index":1,"Type":"Audio","Codec":"truehd","Channels":8}]}],"PlaySessionId":"x"}"#
        let response = try JSONDecoder().decode(PlaybackInfoResponse.self, from: Data(info.utf8))
        let old = try PlaybackPlan.make(from: response, itemID: "m1", profile: .vlc(maxBitrate: 120_000_000),
                                        streamURL: { _, _, _ in URL(string: "http://x/stream")! },
                                        serverBase: URL(string: "http://srv.test")!, preferredSourceID: nil)
        let isTranscode = old.map { "\($0.method)" } == "transcode"
        Record.note("transcode-only", "plan", isTranscode, "old rule: \(old.map { "\($0.method)" } ?? "nil")")
        #expect(isTranscode)
    }
}
