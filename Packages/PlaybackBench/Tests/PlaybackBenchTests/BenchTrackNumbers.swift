import Foundation
import JellyfinKit

/// The engine's track numbers for the server's `Index` of a stream, through the app's own rule
/// (`MediaSource.engineTrackIndex`). Kept apart from `BenchPort` because `JellyfinKit` and `AetherEngine` both name a `SubtitleCue`.
struct BenchTrackNumbers {
    let source: MediaSource?

    init(sourceJson: String?) {
        source = sourceJson.flatMap { try? JSONDecoder().decode(MediaSource.self, from: Data($0.utf8)) }
    }

    func engine(forServer index: Int) -> Int { source?.engineTrackIndex(forServerIndex: index) ?? index }

    /// The reverse; numbers it does not know pass through.
    func server(forEngine id: Int, type: String) -> Int {
        (source?.mediaStreams ?? []).first { $0.type == type && $0.engineIndex == id }?.index ?? id
    }
}
