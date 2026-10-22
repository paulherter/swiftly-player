import Foundation
// On Linux URLSession is not in Foundation but in its own module. On Apple platforms that
// module does not exist, so the import is conditional and has no effect there.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public extension URLSession {

    /// The session Swiftly uses to reach servers on the home network.
    ///
    /// **`waitsForConnectivity` matters because of a system prompt.** Since iOS 14 the
    /// system asks for permission before an app talks to devices on the local network, even
    /// for a direct IP, not only `.local`. The prompt appears on the **first** attempt,
    /// which fails while the user is still reading it. With `waitsForConnectivity` the
    /// request waits until permission is granted and then continues.
    ///
    /// Without it: enter address, "Connect", immediate error, then the prompt, and after
    /// allowing it the user had to tap again.
    ///
    /// **Hence the timeout.** `waitsForConnectivity` waits indefinitely, and a server that
    /// is simply not there would hang the login instead of showing an error.
    /// `timeoutIntervalForResource` limits the whole operation to 20 seconds. Checking a
    /// typed address does not use this session but ``Adresspruefung`` with a shorter
    /// timeout, so a typo does not take this long to fail.
    static let localNetworkCapable: URLSession = URLSession(configuration: localNetworkConfiguration())

    /// The configuration behind ``localNetworkCapable``, for sessions that need a delegate
    /// on top of the same behavior.
    static func localNetworkConfiguration() -> URLSessionConfiguration {
        let k = URLSessionConfiguration.default
        // **Read-only on Linux.** swift-corelibs-foundation knows the property but does not
        // implement it, so there is no waiting for a connection. The two timeouts below
        // still apply and are what makes a typo in the address fail.
        #if canImport(Darwin)
        k.waitsForConnectivity = true
        #endif
        k.timeoutIntervalForRequest = 15
        k.timeoutIntervalForResource = 20
        #if DEBUG && canImport(Darwin)
        // Offline self-test via ``Netzsperre``. While it is off, it accepts no request.
        k.protocolClasses = [NetworkLock.self] + (k.protocolClasses ?? [])
        #endif
        return k
    }
}
