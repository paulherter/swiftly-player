import Foundation
// On Linux, URLSession is in a separate module, not in Foundation. Apple
// platforms have no such module, so the import is conditional and does nothing there.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Who is visible on this server before anyone is signed in.
public struct PublicUser: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let imageMark: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name"
        case imageMark = "PrimaryImageTag"
    }
}

/// A started Quick Connect process.
public struct LoginCode: Sendable, Equatable {
    public let code: String
    /// The secret stays with the device; only the code is read out.
    public let confidential: String
}

extension JellyfinClient {

    /// The server's public users.
    ///
    /// Jellyfin hands them out without sign-in so a login screen can show who could sign in
    /// here at all. Ignoring this makes the user type a name the server already knows.
    public func publicUser() async throws -> [PublicUser] {
        let req = try rawRequest("Users/Public", method: "GET")
        let (data, answer) = try await rawSession.data(for: req)
        guard let http = answer as? HTTPURLResponse, http.statusCode == 200 else {
            // The server may turn the list off. That is not an error; it only means: type it
            // instead.
            return []
        }
        do {
            return try JSONDecoder().decode([PublicUser].self, from: data)
        } catch {
            // Empty stays correct: then the user types. But not silently: a list the server
            // sends and the app cannot read is a bug on our side and belongs in the log.
            TrackSupport.sag("[Anmeldung] Users/Public nicht lesbar: \(error)")
            return []
        }
    }

    /// URL of the user image on the login page, without sign-in, so no token in the URL.
    public func userImage(_ user: PublicUser, border: Int = 180) -> URL? {
        guard let mark = user.imageMark else { return nil }
        var parts = URLComponents(url: baseURL.appendingPathComponent("Users/\(user.id)/Images/Primary"),
                                  resolvingAgainstBaseURL: false)
        parts?.queryItems = [.init(name: "tag", value: mark),
                             .init(name: "fillWidth", value: String(border)),
                             .init(name: "quality", value: "90")]
        return parts?.url
    }

    // MARK: - Quick Connect as sign-in method

    /// Starts a process and returns the code to enter elsewhere.
    ///
    /// The opposite of `quickConnectShare`: that authorizes a foreign code on this
    /// device, this one lets itself be authorized. On a phone this is the more convenient
    /// way, since a password with special characters is hard to type on glass.
    public func quickConnectStart() async throws -> LoginCode {
        struct Reply: Decodable {
            let Secret: String
            let Code: String
        }
        let req = try rawRequest("QuickConnect/Initiate", method: "POST")
        let (data, answer) = try await rawSession.data(for: req)
        guard let http = answer as? HTTPURLResponse else {
            throw JellyfinError.transport("Keine Antwort vom Server.")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 503 {
                throw JellyfinError.transport(translated("Der Server hat Quick Connect abgeschaltet."))
            }
            throw JellyfinError.http(status: http.statusCode,
                                     body: String(data: data.prefix(200), encoding: .utf8))
        }
        let a = try JSONDecoder().decode(Reply.self, from: data)
        return LoginCode(code: a.Code, confidential: a.Secret)
    }

    /// Whether the code has been authorized meanwhile.
    ///
    /// If the server answers 404, the process has expired. That is its own case
    /// (``Quickconnectabgelaufen``), not a network problem: then request a new code.
    /// Callers that poll use ``quickConnectAskAgain(_:)``, where the distinction is
    /// already made.
    public func quickConnectReleased(_ preGait: LoginCode) async throws -> Bool {
        struct Reply: Decodable { let Authenticated: Bool }
        let req = try rawRequest("QuickConnect/Connect", method: "GET",
                                 query: [.init(name: "secret", value: preGait.confidential)])
        let (data, answer) = try await rawSession.data(for: req)
        guard let http = answer as? HTTPURLResponse else { return false }
        if http.statusCode == 404 { throw QuickConnectExpired() }
        guard http.statusCode == 200 else { return false }
        do {
            return try JSONDecoder().decode(Reply.self, from: data).Authenticated
        } catch {
            TrackSupport.sag("[Anmeldung] QuickConnect/Connect nicht lesbar: \(error)")
            return false
        }
    }

    /// **Poll once without a network error ending the wait.**
    ///
    /// While waiting, the user almost always switches apps to enter the code in the browser.
    /// Android and iOS then suspend the app; the running request aborts (“Software caused
    /// connection abort”, timeout, name resolution). That says nothing about the code.
    /// Previously exactly such an error ended the wait and showed raw on screen although
    /// the code was still valid.
    public func quickConnectAskAgain(_ preGait: LoginCode) async -> QuickConnectState {
        do {
            return try await quickConnectReleased(preGait) ? .released : .opened
        } catch {
            return QuickConnectState(error: error)
        }
    }

    /// Fetches the access token after the code was authorized.
    public func signInWithQuickConnect(_ preGait: LoginCode) async throws -> Session {
        struct BodyShell: Encodable { let Secret: String }
        return try await signInWith(shell: BodyShell(Secret: preGait.confidential),
                                     an: "Users/AuthenticateWithQuickConnect")
    }
}

/// **How long to wait for a Quick Connect authorization, and at what interval.**
///
/// These numbers used to exist three times: in `QuickConnectModel` on Apple and
/// **twice** on Linux, once for first sign-in and once for adding an account. Three
/// places for the same deadline drift apart as soon as someone changes one.
public enum QuickConnectDeadline {

    /// **Five minutes.** Jellyfin keeps the code that long; waiting longer would mean
    /// waiting for something that no longer exists.
    public static let seconds = 300

    /// **Ask every two seconds.** Faster loads the server for no gain: authorization is
    /// manual, and nobody types a six-digit code in under two seconds.
    public static let tick = 2

    /// How many polls follow from that.
    public static var attempts: Int { seconds / tick }

    /// **What is shown at the end of the deadline.** If even the last poll failed, the
    /// cause was the connection, not the code, and the message says so.
    public static func endText(last: QuickConnectState) -> String {
        last == .failed ? translated("Der Server hat nicht geantwortet.")
                               : translated("Der Code ist abgelaufen. Hol dir einen neuen.")
    }
}

/// The server no longer knows the Quick Connect process (404).
public struct QuickConnectExpired: LocalizedError, Equatable, Sendable {
    public init() {}
    public var errorDescription: String? {
        translated("Der Code ist abgelaufen. Hol dir einen neuen.")
    }
}

/// **The result of a poll while waiting for authorization.**
///
/// Only `released` and `expired` end the wait. `failed` means this one poll
/// did not get through: keep asking, the code is still valid.
public enum QuickConnectState: String, Sendable, Equatable {
    case opened = "offen", released = "freigegeben", expired = "abgelaufen", failed = "gescheitert"

    public init(error: any Error) {
        self = error is QuickConnectExpired ? .expired : .failed
    }

    /// Whether the wait ends here.
    public var endedWait: Bool { self == .released || self == .expired }
}
