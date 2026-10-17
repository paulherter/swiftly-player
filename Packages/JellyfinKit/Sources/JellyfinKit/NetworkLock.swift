#if DEBUG && canImport(Darwin)
import Foundation

/// **For self-tests only: no network, without switching the network off.**
///
/// The offline self-test (`-offlinelauf`) must check what an app does without a
/// server, in the simulator, without airplane mode and without anyone pulling a cable.
/// This protocol hooks into ``Foundation/URLSession/ortsnetzfaehig`` and, while
/// ``an`` is set, fails every request immediately with `notConnectedToInternet`, the
/// exact error a device gives in flight mode. Everything else (images via
/// `URLSession.shared`, the downloads' background session) stays untouched.
///
/// Release builds do not contain this class.
public final class NetworkLock: URLProtocol, @unchecked Sendable {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var toward = false

    /// Toggling in the middle of a run is intended: that way the self-test also measures
    /// reconnecting.
    public static var an: Bool {
        get { lock.lock(); defer { lock.unlock() }; return toward }
        set { lock.lock(); toward = newValue; lock.unlock() }
    }

    override public class func canInit(with request: URLRequest) -> Bool { an }
    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override public func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override public func stopLoading() {}
}
#endif
