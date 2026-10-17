import Foundation
// On Linux, URLSession is in a separate module, not in Foundation. Apple
// platforms have no such module, so the import is conditional and does nothing there.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Quick Connect: authorize a code shown on another device.
///
/// The flow is the reverse of what the name suggests. This device does not sign in;
/// the TV shows a six-digit code and this already signed-in device authorizes it.
/// That is why it sits in the profile menu and not on the sign-in page.
extension JellyfinClient {

    /// Whether the server offers Quick Connect at all. It can be turned off,
    /// then it answers 503 instead of `false`.
    public func quickConnectAddBar() async -> Bool {
        guard let req = try? rawRequest("QuickConnect/Enabled", method: "GET"),
              let (data, answer) = try? await rawSession.data(for: req),
              let http = answer as? HTTPURLResponse, http.statusCode == 200 else {
            return false
        }
        return String(data: data, encoding: .utf8)?.lowercased().contains("true") ?? false
    }

    /// Authorizes the code. Throws with a readable reason so the UI does not have to
    /// show a generic “Error”.
    public func quickConnectShare(code: String) async throws {
        let session = try requireSessionForReporting()
        let clean = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 4 else { throw JellyfinError.transport("Der Code ist zu kurz.") }

        // **No `userId`.** The parameter is optional, and setting it asks the server for access
        // to *that* user; for the 403 the 10.11.11 spec literally says “Unknown user id”.
        //
        // Without the parameter the signed-in user applies, which is always the right one:
        // only someone signed in here can authorize anyway.
        // The session is still required: without a token the call has no sender.
        _ = session
        let req = try rawRequest(
            "QuickConnect/Authorize", method: "POST",
            query: [URLQueryItem(name: "code", value: clean)])

        let (data, answer) = try await rawSession.data(for: req)
        guard let http = answer as? HTTPURLResponse else {
            throw JellyfinError.transport("Keine Antwort vom Server.")
        }
        switch http.statusCode {
        case 200:
            // The server answers with true or false, not with an error.
            let text = String(data: data, encoding: .utf8)?.lowercased() ?? ""
            if text.contains("false") {
                throw JellyfinError.transport(translated("Der Code ist abgelaufen oder falsch."))
            }
        case 403:
            throw JellyfinError.transport("Der Server hat die Freigabe abgelehnt.")
        case 503:
            throw JellyfinError.transport(translated("Der Server hat Quick Connect abgeschaltet."))
        default:
            throw JellyfinError.http(status: http.statusCode,
                                     body: String(data: data.prefix(200), encoding: .utf8))
        }
    }
}
