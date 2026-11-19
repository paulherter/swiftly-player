import Testing
@testable import SwiftlyAether

@Suite struct LifecyclePauseTests {
    /// Notification Center pulled down and pushed back where iOS reports only "inactive": nothing happens at all.
    @Test func inactiveOnlyDoesNothing() {
        var p = LifecyclePause()
        #expect(p.becameInactive() == .nothing)
        #expect(p.phase == .none)
        // The return after a mere resign has nothing to resume.
        #expect(p.becameActive() == .nothing)
    }

    @Test func backgroundPausesAPlayingTitleAndTheReturnPlaysIt() {
        var p = LifecyclePause()
        #expect(p.enteredBackground(playing: true, pictureInPicture: false, externalPlayback: false) == .pause)
        #expect(p.phase == .autoPaused)
        #expect(p.becameActive() == .resume)
        #expect(p.phase == .none)
    }

    @Test func pictureInPictureAndAirPlayKeepPlaying() {
        var p = LifecyclePause()
        #expect(p.enteredBackground(playing: true, pictureInPicture: true, externalPlayback: false) == .nothing)
        #expect(p.enteredBackground(playing: true, pictureInPicture: false, externalPlayback: true) == .nothing)
        #expect(p.becameActive() == .nothing)
    }

    /// A title the user paused is not touched, and not resumed on the return.
    @Test func aPausedTitleStaysPaused() {
        var p = LifecyclePause()
        #expect(p.enteredBackground(playing: false, pictureInPicture: false, externalPlayback: false) == .nothing)
        #expect(p.becameActive() == .nothing)
    }

    /// A press during the absence is the user's choice: the return does not undo it.
    @Test func aPressWhileAwayCancelsTheResume() {
        var p = LifecyclePause()
        _ = p.enteredBackground(playing: true, pictureInPicture: false, externalPlayback: false)
        p.userChose()
        #expect(p.becameActive() == .nothing)
    }

    /// The system opens the PiP window after the app left: the paused title plays on in it, and the later return adds nothing.
    @Test func pictureStartingAfterTheBackgroundResumes() {
        var p = LifecyclePause()
        _ = p.enteredBackground(playing: true, pictureInPicture: false, externalPlayback: false)
        #expect(p.pictureStarted() == .resume)
        #expect(p.becameActive() == .nothing)
    }

    @Test func aSecondBackgroundWhileAutoPausedDoesNotPauseTwice() {
        var p = LifecyclePause()
        #expect(p.enteredBackground(playing: true, pictureInPicture: false, externalPlayback: false) == .pause)
        #expect(p.enteredBackground(playing: true, pictureInPicture: false, externalPlayback: false) == .nothing)
        #expect(p.becameActive() == .resume)
    }
}
