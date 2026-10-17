import Foundation
// On Linux, URLSession is in a separate module, not in Foundation. Apple
// platforms have no such module, so the import is conditional and does nothing there.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// **One running check of a typed server address.**
///
/// Carries a sequence number and the address it was started for. Whoever handles the
/// answer first asks ``Pruefstand/gilt(_:)``; an answer for older input is discarded.
public struct CheckMark: Sendable, Equatable {
    public let number: Int
    public let address: String
}

/// **Only the latest address check may take effect.**
///
/// An address that nobody answers takes until its timeout to fail. If the user corrects
/// the address and submits again in the meantime, a second check starts, and the first
/// can still finish later: its error reset the app to the address form while the user
/// was already typing name and password for the right server.
///
/// Each check takes a ``Pruefmarke`` here; a new check or a discard (address changed)
/// invalidates the previous one. The value belongs to whoever drives the UI and is only
/// changed from there.
public struct CheckState: Sendable {
    public private(set) var ongoing: CheckMark?
    private var counter = 0

    public init() {}

    /// Starts a check; the previous one is no longer valid.
    public mutating func begin(_ address: String) -> CheckMark {
        counter += 1
        let mark = CheckMark(number: counter, address: address)
        ongoing = mark
        return mark
    }

    /// May the answer for `mark` still change anything?
    public func applies(_ mark: CheckMark) -> Bool { ongoing == mark }

    /// Ends the check for `mark`. `false` if it was already superseded;
    /// the caller must then touch nothing.
    @discardableResult
    public mutating func complete(_ mark: CheckMark) -> Bool {
        guard applies(mark) else { return false }
        ongoing = nil
        return true
    }

    /// The address changed: anything still running is no longer valid.
    public mutating func discard() { ongoing = nil }
}

/// **How long a typed address is checked, and over which session.**
///
/// The ordinary session (``Foundation/URLSession/ortsnetzfaehig``) waits for a
/// connection with `waitsForConnectivity`, even if the name does not exist at all.
/// Measured on a Mac: an unknown name only failed at the timeout after 20.8 seconds
/// instead of immediately with “name not found”. The app then also tried `http`,
/// so the message took over 40 seconds.
public enum AddressCheck {

    /// **Eight seconds for the whole check.** `System/Info/Public` is a tiny response; a
    /// server that does not answer within eight seconds is not usable for sign-in.
    public static let deadline: TimeInterval = 8

    /// **At home, it keeps waiting for the connection**, just for less time: iOS asks for
    /// local-network permission the first time, and the request should continue after the
    /// user allows it instead of failing. Outside there is no such prompt, so an unknown
    /// name fails immediately.
    public static func session(for address: URL) -> URLSession {
        AppModelURLNormalizer.isHomeNetwork(address.host() ?? "") ? homeNetwork : outside
    }

    /// **Is it worth retrying with `http` after this error?**
    ///
    /// Not if the name does not exist; the scheme changes nothing. Not after the timeout,
    /// or it would be waited out twice. Not without a network, and not for a cancelled check.
    /// Everything else (certificate, rejected, a foreign page) arrives quickly and may
    /// depend on the scheme.
    public static func fallbackPaysOff(to error: any Error) -> Bool {
        if error is CancellationError { return false }
        let code: Int
        if let j = error as? JellyfinError {
            guard case let .network(c) = j else { return true }
            code = c
        } else {
            let ns = error as NSError
            guard ns.domain == NSURLErrorDomain else { return true }
            code = ns.code
        }
        switch URLError.Code(rawValue: code) {
        case .cannotFindHost, .dnsLookupFailed, .timedOut, .cancelled,
             .notConnectedToInternet:
            return false
        default:
            return true
        }
    }

    private static func settingsConfig(wait: Bool) -> URLSessionConfiguration {
        let k = URLSessionConfiguration.default
        #if canImport(Darwin)
        k.waitsForConnectivity = wait
        #endif
        k.timeoutIntervalForRequest = deadline
        k.timeoutIntervalForResource = deadline
        return k
    }

    private static let homeNetwork = URLSession(configuration: settingsConfig(wait: true))
    private static let outside = URLSession(configuration: settingsConfig(wait: false))
}
