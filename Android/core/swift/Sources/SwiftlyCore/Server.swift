import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import JellyfinKit

/// **Can the app reach the server?** The first call from Kotlin into the package.
///
/// Queries `System/Info/Public`, which needs no sign-in, and returns a finished line. The facade
/// speaks in answers, not in parts: Kotlin assembles nothing here.
///
/// `clientVersion` is explicit on purpose. The default reads the version from the app bundle,
/// which an Android library does not have.
public func serverCheck(address: String) async throws -> String {
    guard let url = URL(string: address) else {
        throw CoreError.address(address)
    }
    let client = JellyfinClient(baseURL: url, deviceID: "swiftly-android",
                                deviceName: "Android", clientVersion: "1.0.3")
    let info = try await client.publicSystemInfo()
    return "\(info.serverName ?? "?") · Jellyfin \(info.version ?? "?")"
}

public enum CoreError: Error {
    case address(String)
    case notConnected
}

/// **An error whose message is already fit for the user.** swift-java passes
/// `String(describing:)` on as the Java exception's message; here that is the text itself.
public struct CoreText: Error, CustomStringConvertible {
    public let description: String
    public init(_ text: String) { description = text }
}

/// **The sentence for the user, from any error of the facade.** Via `readableError` from the
/// package, so Android shows the same words as iOS and Linux.
///
/// Otherwise swift-java passes `String(describing:)` on, and the connection screen showed
/// `transport("Could not resolve host: …")` verbatim for a wrong address. Network errors now come
/// from the package as `JellyfinError.network(code:)`; nobody has to translate the curl sentences back.
func coreErrorText(_ error: any Error) -> String {
    switch error {
    case let k as CoreText: return k.description
    case CoreError.address: return readableError(JellyfinError.invalidServerURL)
    case CoreError.notConnected: return readableError(JellyfinError.notAuthenticated)
    default: return readableError(error)
    }
}

/// For every throwing function whose error Kotlin shows: the Java exception then carries the sentence.
func throwReadable<T>(_ perform: () async throws -> T) async throws -> T {
    do { return try await perform() }
    catch is CancellationError { throw CancellationError() }
    catch { throw CoreText(coreErrorText(error)) }
}
