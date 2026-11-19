// The pause the app puts on a playing title when it leaves the foreground, as ONE state.
//
// iOS reports three different things: the app is only INACTIVE (Notification Center, Control Center, a system alert, the app
// switcher peek: `willResignActive`), it is in the BACKGROUND (`didEnterBackground`), or it is ACTIVE again. A pulled-down
// Notification Center can arrive as a real background transition on current iOS, so "paused" must never be a one-way trip:
// what the app paused itself is played again when the app returns. What the user paused stays paused.
import Foundation

public struct LifecyclePause: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case none
        /// The app paused a playing title on leaving the foreground; it plays again on the return.
        case autoPaused
    }

    public enum Action: Equatable, Sendable {
        case nothing
        case pause
        case resume
    }

    public private(set) var phase = Phase.none

    public init() {}

    /// The app is only inactive: nothing is paused, nothing is remembered.
    public func becameInactive() -> Action { .nothing }

    /// The app entered the background. A title that plays is paused, unless a window or a route keeps it running there:
    /// Picture in Picture, or AirPlay (external playback).
    public mutating func enteredBackground(playing: Bool, pictureInPicture: Bool, externalPlayback: Bool) -> Action {
        guard phase == .none, playing, !pictureInPicture, !externalPlayback else { return .nothing }
        phase = .autoPaused
        return .pause
    }

    /// The system opened the Picture in Picture window after the app left: the title plays on in it.
    public mutating func pictureStarted() -> Action {
        guard phase == .autoPaused else { return .nothing }
        phase = .none
        return .resume
    }

    /// The app is active again: a pause the app made itself ends.
    public mutating func becameActive() -> Action {
        guard phase == .autoPaused else { return .nothing }
        phase = .none
        return .resume
    }

    /// The user pressed Play or Pause (or another title was opened): their choice stands, nothing is resumed for them.
    public mutating func userChose() { phase = .none }
}
