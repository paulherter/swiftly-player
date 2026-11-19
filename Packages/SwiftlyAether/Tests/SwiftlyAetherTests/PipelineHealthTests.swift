import Foundation
import Testing
@testable import SwiftlyAether

@Suite struct PipelineHealthTests {
    private let t0 = Date(timeIntervalSince1970: 1000)

    /// The device case: paused in Picture in Picture, a long stay in the background, the engine says "no rebuild needed".
    @Test func aPausedTitleHeldByPictureInPictureIsStaleAfterALongBackground() {
        var h = PipelineHealth()
        h.enteredBackground(at: t0, playing: false, pictureInPicture: true, externalPlayback: false)
        let result1 = h.returned(at: t0 + 600)
        #expect(result1)
        #expect(h.stale)
    }

    @Test func aPlayingTitleCarriedByPictureInPictureStaysHealthy() {
        var h = PipelineHealth()
        h.enteredBackground(at: t0, playing: true, pictureInPicture: true, externalPlayback: false)
        let result2 = h.returned(at: t0 + 600)
        #expect(!result2)
    }

    @Test func aShortGlanceIsNeverStale() {
        var h = PipelineHealth()
        h.enteredBackground(at: t0, playing: false, pictureInPicture: false, externalPlayback: false)
        let result3 = h.returned(at: t0 + 5)
        #expect(!result3)
    }

    @Test func aPlayingTitleWithoutAWindowIsStaleAfterALongBackground() {
        var h = PipelineHealth()
        h.enteredBackground(at: t0, playing: true, pictureInPicture: false, externalPlayback: false)
        let result4 = h.returned(at: t0 + 60)
        #expect(result4)
    }

    /// Error state + Play must rebuild first, whatever the engine's own flag says.
    @Test func playOnAFailedPipelineRebuildsFirst() {
        #expect(PipelineHealth.needsRebuild(engineFlag: false, stale: false, errored: true))
        var r = ForegroundRestore()
        let need = PipelineHealth.needsRebuild(engineFlag: false, stale: false, errored: true)
        #expect(r.ask(engineNeedsRestore: need, thenPlay: true) == .start)
        #expect(r.finished() == true)
    }

    @Test func playOnAStalePipelineRebuildsFirst() {
        var h = PipelineHealth()
        h.markStale()
        var r = ForegroundRestore()
        #expect(r.ask(engineNeedsRestore: PipelineHealth.needsRebuild(engineFlag: false, stale: h.stale, errored: false), thenPlay: true) == .start)
    }

    @Test func aHealthyPipelineIsLeftAlone() {
        #expect(!PipelineHealth.needsRebuild(engineFlag: false, stale: false, errored: false))
    }

    @Test func aFailureIsRebuiltOnceUntilTheTitleMovesOn() {
        var h = PipelineHealth()
        let result5 = h.errorArrived()
        #expect(result5)
        h.rebuilt(at: 830)
        let result6 = h.errorArrived()
        #expect(!result6)          // the rebuild failed too: the user hears of it
        h.progressed(to: 831)                // not yet proven
        let result7 = h.errorArrived()
        #expect(!result7)
        h.progressed(to: 833)                // moved on: proven
        let result8 = h.errorArrived()
        #expect(result8)
    }

    @Test func aRebuildClearsStale() {
        var h = PipelineHealth()
        h.markStale()
        h.rebuilt(at: 10)
        #expect(!h.stale)
    }
}
