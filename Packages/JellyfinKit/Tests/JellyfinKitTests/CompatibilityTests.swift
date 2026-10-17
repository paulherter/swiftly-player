import Foundation
import Testing
@testable import JellyfinKit

/// Findings from the test files of the compatibility rounds.
@Suite("Kompatibilität: Anamorph, Laufzeit, Ablehnung, Container")
struct CompatibilityTests {

    // MARK: Anamorphic

    @Test("Verdrehtes Pixelverhältnis von VLC 4 wird erkannt (PAL 16:9, gemessen 45:64)")
    func twisted() {
        #expect(PagesRatio.correction(sar: (45, 64), width: 720, height: 576, display: "16:9") == "16:9")
    }

    @Test("Richtig gelesenes Bild bleibt unangetastet — VLC 3 und MP4 melden 64:45")
    func correct() {
        #expect(PagesRatio.correction(sar: (64, 45), width: 720, height: 576, display: "16:9") == nil)
        // VLC 3 does not reduce: 9216:6480 is the same.
        #expect(PagesRatio.correction(sar: (9216, 6480), width: 720, height: 576, display: "16:9") == nil)
    }

    @Test("Quadratische Pixel, fehlende oder unlesbare Angaben: nichts tun")
    func notDo() {
        #expect(PagesRatio.correction(sar: (1, 1), width: 1920, height: 1080, display: "16:9") == nil)
        #expect(PagesRatio.correction(sar: (45, 64), width: 720, height: 576, display: nil) == nil)
        #expect(PagesRatio.correction(sar: (45, 64), width: 720, height: 576, display: "breit") == nil)
        #expect(PagesRatio.correction(sar: (0, 0), width: 720, height: 576, display: "16:9") == nil)
        // A different ratio that is not twisted is not this bug.
        #expect(PagesRatio.correction(sar: (16, 15), width: 720, height: 576, display: "16:9") == nil)
    }

    // MARK: Runtime

    @Test("RunTimeTicks der Quelle wird gelesen — Ersatz, wenn VLC bei TS keine Länge nennt")
    func runtime() throws {
        let json = #"{"Id":"a","Container":"ts","RunTimeTicks":606580000,"SupportsDirectPlay":true}"#
        let source = try JSONDecoder().decode(MediaSource.self, from: Data(json.utf8))
        #expect(source.runtimeSeconds == 60.658)
        let without = try JSONDecoder().decode(MediaSource.self, from: Data(#"{"Id":"a"}"#.utf8))
        #expect(without.runtimeSeconds == nil)
    }

    // MARK: Rejection

    private func plan(_ json: String) throws -> PlaybackPlan? {
        let answer = try JSONDecoder().decode(PlaybackInfoResponse.self, from: Data(json.utf8))
        return try PlaybackPlan.make(from: answer, itemID: "x", profile: .vlc(),
                                     streamURL: { _, _, _ in URL(string: "http://s/x")! },
                                     serverBase: URL(string: "http://s")!)
    }

    @Test("Lehnt der Server mit Grund ab, kommt der Grund an — kein leerer Plan")
    func rejected() throws {
        #expect(throws: JellyfinError.self) { try plan(#"{"MediaSources":[],"ErrorCode":"NoCompatibleStream"}"#) }
        // Even without a source list: it used to be "response not understandable".
        #expect(throws: JellyfinError.self) { try plan(#"{"ErrorCode":"NotAllowed"}"#) }
        // Without a reason the empty plan stays as before.
        #expect(try plan(#"{"MediaSources":[]}"#) == nil)
        for reason in ["NotAllowed", "NoCompatibleStream", "RateLimitExceeded", "Neu"] {
            #expect(!readableError(JellyfinError.playbackRejected(reason)).isEmpty)
        }
    }

    /// Transcoding forbidden for the account, file not directly playable: the
    /// server names the source but no `TranscodingUrl`
    /// (`MediaInfoHelper`: `SupportsTranscoding = false`). For libVLC the
    /// original file is the right way; it plays instead of a black picture.
    @Test("Umwandeln verboten: die Originaldatei wird gespielt")
    func convertForbidden() throws {
        let p = try #require(try plan(#"{"MediaSources":[{"Id":"q","Container":"ogg","SupportsDirectPlay":false,"SupportsDirectStream":false,"SupportsTranscoding":false}],"PlaySessionId":"s"}"#))
        #expect(p.method == .directPlay)
        #expect(p.url.absoluteString == "http://s/x")
    }

    @Test("Mit TranscodingUrl spielt die Umwandlung — der Rückfall aus „Immer Direct Play“ heraus")
    func conversion() throws {
        let p = try #require(try plan(#"{"MediaSources":[{"Id":"q","Container":"mkv","SupportsDirectPlay":false,"SupportsTranscoding":true,"TranscodingUrl":"/videos/x/master.m3u8?MediaSourceId=q"}],"PlaySessionId":"s"}"#))
        #expect(p.method == .transcode)
        #expect(p.url.absoluteString == "http://s/videos/x/master.m3u8?MediaSourceId=q")
    }

    // MARK: Container

    @Test("Ogg-Video (Jellyfin: „ogg“) ist Direct Play")
    func ogg() {
        #expect(DeviceProfile.vlc().directPlayProfiles.contains { $0.container == "ogg" && $0.type == "Video" })
    }
}
