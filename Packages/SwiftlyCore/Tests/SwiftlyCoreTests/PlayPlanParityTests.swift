import Foundation
import Synchronization
import Testing

import JellyfinKit
@testable import SwiftlyCore

/// **The old `PlaybackPlan.make` and the core's `playPlan` on the same PlaybackInfo answers**, for the
/// Aether (`vlc`) and the AVPlayer (`airplay`) profile. Real-shaped JSON of the awkward kinds: Dolby
/// Vision profile 5 with TrueHD/Atmos that the server direct plays, the same file that only
/// converts (`TranscodingUrl`), a title with a direct and a converting version (the cheaper one wins,
/// a picked one beats it). A difference here is a core bug: fix it in the crate with a Rust test.
@Suite struct PlayPlanParityTests {
    static let streams = """
        [
         {"Index":0,"Type":"Video","Codec":"hevc","Width":3840,"Height":2160,"VideoRangeType":"DOVI","DvProfile":5},
         {"Index":1,"Type":"Audio","Codec":"truehd","Language":"eng","Channels":8,"DisplayTitle":"English - TrueHD Atmos - 7.1","IsDefault":true},
         {"Index":2,"Type":"Audio","Codec":"ac3","Language":"ger","Channels":6},
         {"Index":3,"Type":"Subtitle","Codec":"subrip","Language":"ger"}
        ]
        """

    static func source(_ id: String, direct: Bool, transcodingUrl: String? = nil, name: String = "Fassung") -> String {
        let transcode = transcodingUrl.map { #","TranscodingUrl":"\#($0)","TranscodingSubProtocol":"hls","TranscodingContainer":"ts""# } ?? ""
        return """
            {"Id":"\(id)","Name":"\(name)","Container":"mkv","Size":18600000000,"RunTimeTicks":72000000000,
             "SupportsDirectPlay":\(direct),"SupportsDirectStream":\(direct),"SupportsTranscoding":true,
             "DefaultAudioStreamIndex":1,"DefaultSubtitleStreamIndex":-1,"MediaStreams":\(streams)\(transcode)}
            """
    }

    static func info(_ sources: [String], session: String = "ps-1") -> String {
        #"{"MediaSources":[\#(sources.joined(separator: ","))],"PlaySessionId":"\#(session)"}"#
    }

    /// Answers the core's requests: the title, its PlaybackInfo, empty everything else.
    final class Stub: HttpClient {
        let infoJSON: String
        let bodies = Mutex<[Data]>([])
        init(info: String) { infoJSON = info }
        func send(request: NetRequest) async throws -> NetResponse {
            let path = URL(string: request.url)?.path ?? ""
            let body: String
            if path.hasSuffix("/PlaybackInfo") {
                bodies.withLock { $0.append(request.body ?? Data()) }
                body = infoJSON
            } else if path.hasSuffix("/Items/m1") {
                body = #"{"Id":"m1","Name":"Film","Type":"Movie","RunTimeTicks":72000000000,"UserData":{"PlaybackPositionTicks":0}}"#
            } else {
                body = "{}"
            }
            return NetResponse(status: 200, headers: [NetHeader(name: "Content-Type", value: "application/json")],
                               body: Data(body.utf8), url: request.url)
        }
    }

    struct Outcome: Equatable {
        var method: String
        var source: String?
        var session: String?
        var path: String
        var query: [String: String]
    }

    private func new(_ info: String, flavour: PlayFlavour, picked: String?) async throws -> (Outcome?, Data?) {
        let stub = Stub(info: info)
        let core = Core(platform: FakePlatform(), secrets: FakeSecrets(), store: MemoryKeyValue(), http: stub)
        let account = AccountRef(baseUrl: "http://srv.test", userId: "u1", token: "TOKEN", serverKind: .jellyfin,
                                 deviceId: "test-device")
        let request = PlayPlanRequest(
            itemId: "m1", sourceId: picked, since: nil, flavour: flavour, hardwareAv1: false, askVersions: false, downloaded: nil,
            ordered: nil, accountKey: nil,
            settings: PlaySettings(audioLanguage: "ger", subtitleLanguage: "ger", automaticSubtitles: false,
                                   maxBitrate: 120_000_000, bufferLevel: .normal, frameRateMatch: false,
                                   serverExtractsText: false),
            next: .none)
        let answer = try await core.playPlan(account: account, locale: "de", request: request)
        let sent = stub.bodies.withLock { $0.first }
        guard case .ready(let ready) = answer else { return (nil, sent) }
        let url = URLComponents(string: ready.start.url)
        let query = Dictionary(uniqueKeysWithValues: (url?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let method = switch ready.start.method {
        case .directPlay: "directPlay"
        case .directStream: "directStream"
        case .transcode: "transcode"
        }
        return (Outcome(method: method, source: ready.start.mediaSourceId, session: ready.start.playSessionId,
                        path: url?.path ?? "", query: query), sent)
    }

    private func old(_ info: String, profile: DeviceProfile, picked: String?) throws -> Outcome? {
        let response = try JSONDecoder().decode(PlaybackInfoResponse.self, from: Data(info.utf8))
        let base = URL(string: "http://srv.test")!
        let plan = try PlaybackPlan.make(
            from: response, itemID: "m1", profile: profile,
            streamURL: { id, source, session in
                var parts = URLComponents(url: base.appendingPathComponent("Videos/\(id)/stream"),
                                          resolvingAgainstBaseURL: false)!
                var query = [URLQueryItem(name: "static", value: "true"), URLQueryItem(name: "ApiKey", value: "TOKEN")]
                if let source { query.append(.init(name: "mediaSourceId", value: source)) }
                if let session { query.append(.init(name: "playSessionId", value: session)) }
                parts.queryItems = query
                return parts.url!
            },
            serverBase: base, preferredSourceID: picked)
        guard let plan else { return nil }
        let url = URLComponents(url: plan.url, resolvingAgainstBaseURL: false)
        let query = Dictionary(uniqueKeysWithValues: (url?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        return Outcome(method: String(describing: plan.method), source: plan.mediaSourceID,
                       session: plan.playSessionID, path: url?.path ?? "", query: query)
    }

    private func same(_ info: String, picked: String? = nil) async throws {
        for (flavour, profile) in [
            (PlayFlavour.aether, DeviceProfile.vlc(maxBitrate: 120_000_000)),
            (.avPlayer, DeviceProfile.airplay(maxBitrate: 120_000_000)),
            (.avPlayerAv1, DeviceProfile.airplay(maxBitrate: 120_000_000, av1: true)),
        ] {
            let (core, sent) = try await new(info, flavour: flavour, picked: picked)
            let swift = try old(info, profile: profile, picked: picked)
            #expect(core != nil, "the core answered ready for \(flavour)")
            #expect(core == swift, "\(flavour)")
            // The profile the server is asked with is the old app's own, key for key.
            let body = try #require(sent.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
            let theirs = try #require(body["DeviceProfile"] as? NSDictionary)
            let mine = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? NSDictionary
            #expect(theirs == mine, "profile \(flavour)")
        }
    }

    @Test func dolbyVisionProfile5WithAtmosDirectPlays() async throws {
        try await same(Self.info([Self.source("s1", direct: true)]))
    }

    @Test func aFileThatOnlyConvertsTakesTheServersAddress() async throws {
        try await same(Self.info([Self.source("s1", direct: false, transcodingUrl: "/videos/m1/master.m3u8?MediaSourceId=s1")]))
    }

    @Test func theCheaperVersionWinsAndAPickedOneBeatsIt() async throws {
        let info = Self.info([
            Self.source("conv", direct: false, transcodingUrl: "/videos/m1/master.m3u8?MediaSourceId=conv", name: "Schnitt"),
            Self.source("direct", direct: true, name: "Original"),
        ])
        try await same(info)
        try await same(info, picked: "conv")
        try await same(info, picked: "gone")
    }
}
