import Foundation
import Testing

@testable import SwiftlyCore

/// **Stage (f): the picture's surface (screen, small window, AirPlay) and the AirPlay start are the core's.**
/// Scripted with the fake engine of ``CorePlayerDecisionTests``.
@Suite(.serialized) struct CorePlayerSurfaceTests {
    @MainActor func make() throws -> CorePlayerDecisionTests.Run {
        try CorePlayerDecisionTests().run(
            CorePlayerDecisionTests.Server(), startAt: 600, autoSkip: false, next: false, sections: [])
    }

    private func source(video: String, audio: String) -> String {
        """
        {"Id":"s","MediaStreams":[{"Type":"Video","Codec":"\(video)","Index":0},\
        {"Type":"Audio","Codec":"\(audio)","Index":1,"IsDefault":true}]}
        """
    }

    @Test @MainActor func airPlayStartsOnlyForALiveTitleOnThisScreenAndAFittingFile() async throws {
        var r = try make()
        defer { r.observing.cancel() }
        #expect(r.model.surface == .inline)
        // No picture yet.
        #expect(r.model.airplayStart(sourceJSON: source(video: "h264", audio: "aac")) == .ignore)
        await r.play(from: 600, seconds: 2)
        // A file the TV cannot take is refused with its sentences and the surface stays.
        guard case let .refused(verdict) = r.model.airplayStart(sourceJSON: source(video: "av1", audio: "aac")) else {
            Issue.record("expected a refusal"); return
        }
        #expect(verdict.obstacles.first?.kind == .video && verdict.obstacles.first?.codecShown == "AV1")
        #expect(r.model.surface == .inline)
        // A fitting file moves to "asking" once; a second ask is ignored.
        #expect(r.model.airplayStart(sourceJSON: source(video: "h264", audio: "aac")) == .go(audioTrack: 1))
        #expect(r.model.surface == .airPlayAsking)
        #expect(r.model.airplayStart(sourceJSON: source(video: "h264", audio: "aac")) == .ignore)
        #expect(r.model.surfaceEvent(.airPlayTaken) == .airPlay)
        #expect(r.model.surfaceEvent(.airPlayBack) == .inline)
    }

    @Test @MainActor func theSmallWindowBlocksAirPlayAndIllegalEventsChangeNothing() async throws {
        var r = try make()
        defer { r.observing.cancel() }
        await r.play(from: 600, seconds: 2)
        #expect(r.model.surfaceEvent(.pip(on: true)) == .pip)
        #expect(r.model.airplayStart(sourceJSON: source(video: "h264", audio: "aac")) == .ignore)
        #expect(r.model.surfaceEvent(.airPlayTaken) == .pip)
        #expect(r.model.surfaceEvent(.pip(on: false)) == .inline)
    }

    @Test @MainActor func aRefusedFetchGoesBackToTheScreen() async throws {
        var r = try make()
        defer { r.observing.cancel() }
        await r.play(from: 600, seconds: 2)
        _ = r.model.airplayStart(sourceJSON: source(video: "hevc", audio: "eac3"))
        #expect(r.model.surfaceEvent(.airPlayRefused) == .inline)
    }
}
