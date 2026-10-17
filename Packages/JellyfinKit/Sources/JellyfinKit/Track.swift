import Foundation

/// **A thread through which the package can talk to the outside.**
///
/// The package does not know `AppLog`: it lives in the app because it writes
/// to a file in the app container, which does not exist that way on Linux and
/// Windows. Yet the quietest spots in the whole app are in here: a socket
/// that does not connect, a body the server cannot read, a response nobody
/// looks at.
///
/// That once cost half a night: a handover failed, and in three places in a row
/// a failure was silently turned into "nothing there". What you cannot see you
/// look for in the wrong place.
///
/// The app hooks its log in here; if nothing is hooked in, nothing is lost and
/// it costs a test for `nil`.
public enum TrackSupport {

    /// **`nonisolated(unsafe)` and set once at startup.**
    ///
    /// It is a hook point, not state: the app sets it before anything runs, and
    /// afterwards it is only read. A lock for it would cost more than what it
    /// protects.
    nonisolated(unsafe) public static var write: (@Sendable (String) -> Void)?

    /// The text is only built if someone is listening.
    public static func sag(_ text: @autoclosure () -> String) {
        guard let write else { return }
        write(text())
    }
}
