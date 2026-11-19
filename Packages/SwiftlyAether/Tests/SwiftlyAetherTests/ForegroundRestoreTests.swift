import Testing
@testable import SwiftlyAether

@Suite struct ForegroundRestoreTests {
    @Test func theAppBecomingActiveStartsTheRebuildAndItEndsInPause() {
        var r = ForegroundRestore()
        #expect(r.ask(engineNeedsRestore: true, thenPlay: false) == .start)
        #expect(r.isRestoring)
        #expect(!r.playsAfter)
        #expect(r.finished() == false)
        #expect(r.phase == .idle)
    }

    @Test func nothingToRebuildMeansNothing() {
        var r = ForegroundRestore()
        #expect(r.ask(engineNeedsRestore: false, thenPlay: true) == .nothing)
        #expect(r.phase == .idle)
    }

    /// The reviewer's finding: the engine clears `needsForegroundVideoRestore` when the rebuild begins, so a Play press during
    /// the rebuild arrives with `engineNeedsRestore == false` and used to be dropped; the rebuild then ended in pause.
    @Test func aPlayPressDuringTheRebuildIsRememberedAndPlaysAfterIt() {
        var r = ForegroundRestore()
        #expect(r.ask(engineNeedsRestore: true, thenPlay: false) == .start)
        #expect(r.ask(engineNeedsRestore: false, thenPlay: true) == .noted)
        #expect(r.playsAfter)
        #expect(r.finished() == true)
        #expect(r.phase == .idle)
    }

    @Test func aPlayPressBeforeTheRebuildStartsItAndPlaysAfter() {
        var r = ForegroundRestore()
        #expect(r.ask(engineNeedsRestore: true, thenPlay: true) == .start)
        #expect(r.finished() == true)
    }

    @Test func theAppBecomingActiveDuringARebuildDoesNotTakeBackAPlayPress() {
        var r = ForegroundRestore()
        _ = r.ask(engineNeedsRestore: true, thenPlay: true)
        #expect(r.ask(engineNeedsRestore: false, thenPlay: false) == .noted)
        #expect(r.playsAfter)
    }

    @Test func aPauseDuringTheRebuildTakesBackTheEarlierPlay() {
        var r = ForegroundRestore()
        _ = r.ask(engineNeedsRestore: true, thenPlay: true)
        r.pausePressed()
        #expect(r.finished() == false)
        // A pause outside a rebuild changes nothing.
        r.pausePressed()
        #expect(r.phase == .idle)
    }

    @Test func aSecondRebuildCanFollowTheFirst() {
        var r = ForegroundRestore()
        _ = r.ask(engineNeedsRestore: true, thenPlay: false)
        _ = r.finished()
        #expect(r.ask(engineNeedsRestore: true, thenPlay: true) == .start)
    }
}
