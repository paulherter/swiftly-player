import CoreGraphics
import JellyfinKit

/// **What the player facade needs from the engine** (Aether). The engine lists the server's
/// streams (`request.source`) as its tracks, so the panels and the track memory work from them.
@MainActor
protocol PlaybackBackend: AnyObject {
    /// Short name for the log lines.
    var label: String { get }
    var request: EngineRequest { get }

    /// The server's audio track that plays (`Index`), `nil` = the source's default.
    var audioIndex: Int? { get }
    /// The server's subtitle track that shows; `-1` = none.
    var subtitleIndex: Int { get }

    var position: Double { get }
    var durationSeconds: Double { get }
    var isPlaying: Bool { get }
    /// The start seek has landed (or there was none).
    var startSettled: Bool { get }
    var pictureShown: Bool { get }
    var videoSize: CGSize { get }
    /// The last position the clock reported before a seek or a failure.
    var lastGood: Double { get }

    var tempo: Float { get set }
    var subtitleDelay: Delay { get set }
    var audioDelay: Delay { get set }

    func move(to seconds: Double)
    func pause()
    func resume()
    func volume(_ percent: Int)
    func fill(_ on: Bool)
    func place(in bounds: CGRect)
    func switchAudio(to index: Int)
    /// `-1` turns the subtitles off. `false` = this engine cannot show the track (it stays off).
    @discardableResult func selectSubtitle(_ index: Int) -> Bool
    func stop(resetDisplay: Bool)

    #if os(iOS)
    var pipPossible: Bool { get }
    func startPiP()
    func stopPiP()
    func refreshPiP()
    #endif
}
