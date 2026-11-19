// The rebuild of the video pipeline after the background, as ONE state. The engine releases the pipeline of a paused title
// that stayed in the background (`needsForegroundVideoRestore`); the host rebuilds it before it sends play(). While the rebuild
// runs, a press of Play must not be lost: the engine has already cleared its flag when the rebuild begins, so "does the engine
// still ask for a rebuild" cannot tell the press where it belongs. The state does.
public struct ForegroundRestore: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        /// The rebuild runs. `playAfter`: it ends in play (a Play press came), otherwise in pause.
        case restoring(playAfter: Bool)
    }

    public enum Answer: Equatable, Sendable {
        /// Begin the rebuild now.
        case start
        /// A rebuild is running already; the wish was noted in its state.
        case noted
        /// Nothing to rebuild.
        case nothing
    }

    public private(set) var phase = Phase.idle

    public init() {}

    public var isRestoring: Bool { if case .restoring = phase { return true } else { return false } }

    /// Whether the rebuild is to end in play.
    public var playsAfter: Bool { if case .restoring(let play) = phase { return play } else { return false } }

    /// Someone asks for the rebuild: the app is active again (`thenPlay` false) or Play was pressed (`thenPlay` true).
    /// `engineNeedsRestore` is the engine's own flag. A running rebuild takes the wish whatever the flag says
    /// (the engine clears it at the start of the rebuild).
    public mutating func ask(engineNeedsRestore: Bool, thenPlay: Bool) -> Answer {
        switch phase {
        case .restoring(let play):
            phase = .restoring(playAfter: play || thenPlay)
            return .noted
        case .idle:
            guard engineNeedsRestore else { return .nothing }
            phase = .restoring(playAfter: thenPlay)
            return .start
        }
    }

    /// Pause pressed while the rebuild runs: it ends in pause.
    public mutating func pausePressed() {
        if case .restoring = phase { phase = .restoring(playAfter: false) }
    }

    /// The rebuild is over (done or failed). Returns whether it ends in play.
    @discardableResult
    public mutating func finished() -> Bool {
        let play = playsAfter
        phase = .idle
        return play
    }
}
