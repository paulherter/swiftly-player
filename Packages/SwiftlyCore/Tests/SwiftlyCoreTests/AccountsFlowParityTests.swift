import Foundation
import JellyfinKit
import Synchronization
import Testing

@testable import SwiftlyCore

/// Both sides talk to the same canned server: the old Swift code (`JellyfinClient`, `AccountBundle`,
/// `ServerBundles`, `QuickConnectDeadline`, `readableError`) and the core's `AccountsModel` through the
/// real `URLSessionHttpClient`. What the old code did is the oracle.
private final class CannedServer: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable {
        let method: String
        let path: String
        let authorization: String?
        let gateway: String?
        let body: String
    }
    typealias Answer = @Sendable (Seen) -> Result<(Int, String), URLError>

    private static let routes = Mutex<[String: Answer]>([:])
    private static let log = Mutex<[String: [Seen]]>([:])

    static func serve(_ host: String, _ answer: @escaping Answer) {
        routes.withLock { $0[host] = answer }
        log.withLock { $0[host] = [] }
    }
    static func seen(_ host: String) -> [Seen] { log.withLock { $0[host] ?? [] } }
    static func forget(_ host: String) { log.withLock { $0[host] = [] } }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CannedServer.self]
        configuration.timeoutIntervalForRequest = 5
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let host = url.host ?? ""
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        let seen = Seen(
            method: request.httpMethod ?? "GET", path: url.path,
            authorization: request.value(forHTTPHeaderField: "Authorization")
                ?? request.value(forHTTPHeaderField: "X-Emby-Authorization"),
            gateway: request.value(forHTTPHeaderField: "X-Gateway"),
            body: String(decoding: body, as: UTF8.self))
        Self.log.withLock { $0[host, default: []].append(seen) }
        guard let answer = Self.routes.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        switch answer(seen) {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .success(let (status, text)):
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

/// A Jellyfin that signs everyone in; `connect` is the status of the Quick Connect poll.
private func jellyfin(connect: Int = 200, authenticate: Int = 200) -> CannedServer.Answer {
    { seen in
        func user(from body: String) -> String {
            (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])?["Username"] as? String
                ?? "quick"
        }
        switch seen.path {
        case "/System/Info/Public":
            return .success((200, #"{"ServerName":"Home","Version":"10.10.7","Id":"srv1","ProductName":"Jellyfin Server"}"#))
        case "/Users/AuthenticateByName", "/Users/AuthenticateWithQuickConnect":
            guard authenticate == 200 else { return .success((authenticate, "")) }
            let name = user(from: seen.body)
            return .success((200, #"{"AccessToken":"tok-\#(name)","User":{"Id":"id-\#(name)","Name":"\#(name)"}}"#))
        case "/QuickConnect/Initiate":
            return .success((200, #"{"Secret":"secret-1","Code":"123456"}"#))
        case "/QuickConnect/Connect":
            return connect == 200 ? .success((200, #"{"Authenticated":true}"#)) : .success((connect, ""))
        default:
            return .success((404, ""))
        }
    }
}

/// Everything fails with this URL error.
private func broken(_ code: URLError.Code) -> CannedServer.Answer { { _ in .failure(URLError(code)) } }

private final class Counting: QuickConnectListener {
    func rest(seconds: Int64) {}
}

@Suite("Accounts: sign-in, switch, remove, texts (the old Swift code as oracle)", .serialized)
struct AccountsFlowParityTests {
    private static let deviceID = "test-device"

    /// The language the old package text comes in on this machine; the core is told the same.
    private static var language: String {
        readableError(JellyfinError.notAuthenticated) == "Nicht angemeldet." ? "de" : "en"
    }

    private func oldClient(_ host: String) -> JellyfinClient {
        JellyfinClient(
            baseURL: URL(string: "https://\(host)")!, deviceID: Self.deviceID, deviceName: "Test Mac",
            urlSession: URLSession(configuration: CannedServer.configuration()))
    }

    private func newModel(_ secrets: FakeSecrets, prepare: (@Sendable (inout URLRequest) -> Void)? = nil) throws
        -> AccountsModel
    {
        let http = URLSessionHttpClient(configuration: CannedServer.configuration(), prepare: prepare)
        let core = Core(platform: FakePlatform(), secrets: secrets, store: MemoryKeyValue(), http: http)
        core.setClientVersion(version: VersionNumber.outBundle)
        return try core.accountsModel(deviceId: Self.deviceID, locale: Self.language)
    }

    /// What the app shows for a failed call of the core (`AccountsHost.failure`).
    private func shown(_ error: any Error, _ model: AccountsModel) -> String {
        guard case CoreError.Failed(let message) = error else { return "\(error)" }
        guard let last = NetworkMemory.shared.take() else { return message }
        return model.failureTextSystem(message: message, code: last.code, systemText: last.text)
    }

    private func object(_ text: String?) throws -> NSDictionary? {
        try text.map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? NSDictionary) }
    }

    /// The old app's writing of the bundles (`ServerBundles.save`) into a plain dictionary.
    private func oldStored(_ bundles: ServerBundles) throws -> [String: String] {
        var out: [String: String] = [:]
        try bundles.save { key, data in
            if let data { out[key] = String(decoding: data, as: UTF8.self) }
        }
        return out
    }

    private func signedOld(_ host: String, _ users: [String]) async throws -> ServerBundles {
        var bundles = ServerBundles()
        for name in users {
            let session = try await oldClient(host).authenticate(username: name, password: "pw")
            if var bundle = bundles.bundle(for: .jellyfin) {
                bundle.record(session)
                bundles.set(bundle, for: .jellyfin)
            } else {
                bundles.set(AccountBundle(session), for: .jellyfin)
            }
        }
        return bundles
    }

    // MARK: Sign-in

    @Test func signInSavesTheSameBundleAndSendsTheSameRequest() async throws {
        let host = "sign-in.example"
        CannedServer.serve(host, jellyfin())
        let old = try await signedOld(host, ["paul"])
        let oldSeen = CannedServer.seen(host).first { $0.path == "/Users/AuthenticateByName" }
        CannedServer.forget(host)

        let secrets = FakeSecrets()
        let model = try newModel(secrets)
        _ = try await model.signIn(address: "https://\(host)", kind: .jellyfin, user: "paul", password: "pw")
        let newSeen = CannedServer.seen(host).first { $0.path == "/Users/AuthenticateByName" }

        let expected = try oldStored(old)
        #expect(try object(secrets.get(name: "konten")) == (try object(expected["konten"])))
        #expect(secrets.get(name: "aktiveArt") == expected["aktiveArt"])
        #expect(oldSeen?.method == newSeen?.method)
        #expect(try object(oldSeen?.body) == (try object(newSeen?.body)), "same body")
        #expect(oldSeen?.authorization != nil)
        #expect(oldSeen?.authorization == newSeen?.authorization, "same Authorization header")
    }

    @Test func aSecondAccountSwitchAndRemoveFollowTheOldRules() async throws {
        let host = "accounts.example"
        CannedServer.serve(host, jellyfin())
        var old = try await signedOld(host, ["paul", "anna", "eva"])

        let secrets = FakeSecrets()
        let model = try newModel(secrets)
        for name in ["paul", "anna", "eva"] {
            _ = try await model.signIn(address: "https://\(host)", kind: .jellyfin, user: name, password: "pw")
        }
        func same(_ step: String) throws {
            let expected = try oldStored(old)
            #expect(try object(secrets.get(name: "konten")) == (try object(expected["konten"])), "\(step)")
            #expect(secrets.get(name: "aktiveArt") == expected["aktiveArt"], "\(step)")
        }
        try same("three accounts, the last one active")

        // Switch to the first one.
        let first = try #require(old.bundle(for: .jellyfin)?.accounts.first?.accountKey)
        #expect(model.accounts().map(\.key).contains(first))
        var bundle = try #require(old.bundle(for: .jellyfin))
        bundle.switchTo(toward: first)
        old.set(bundle, for: .jellyfin)
        _ = model.switchTo(key: first)
        try same("switched to the first")

        // An unknown key changes nothing.
        _ = model.switchTo(key: "https://nowhere|x")
        try same("unknown key")

        // Remove the active one: the next in line takes over.
        let afterFirst = try #require(old.bundle(for: .jellyfin)?.removed(first))
        old.set(afterFirst, for: .jellyfin)
        _ = model.remove(key: first)
        try same("removed the active one")

        // One after the other until nobody is left: every stored trace goes.
        for account in afterFirst.accounts {
            old.set(old.bundle(for: .jellyfin)?.removed(account.accountKey), for: .jellyfin)
            _ = model.remove(key: account.accountKey)
        }
        #expect(secrets.get(name: "konten") == nil)
        #expect(secrets.get(name: "aktiveArt") == nil)
        #expect(model.accounts().isEmpty)
    }

    @Test func theSameAccountSigningInAgainReplacesItInPlace() async throws {
        let host = "again.example"
        CannedServer.serve(host, jellyfin())
        let old = try await signedOld(host, ["paul", "anna", "paul"])
        let secrets = FakeSecrets()
        let model = try newModel(secrets)
        for name in ["paul", "anna", "paul"] {
            _ = try await model.signIn(address: "https://\(host)", kind: .jellyfin, user: name, password: "pw")
        }
        #expect(try object(secrets.get(name: "konten")) == (try object(try oldStored(old)["konten"])))
        #expect(model.accounts().count == 2)
    }

    @Test func theLegacySingleSessionKeyIsLeftAloneByTheCore() throws {
        // The app moves it into `konten` before the core runs (`AccountsHost.adoptSingleSession`); the
        // core itself neither reads nor deletes it.
        let secrets = FakeSecrets()
        let legacy = #"{"accessToken":"t","userID":"1","userName":"paul","serverURL":"https://x.example"}"#
        secrets.set(name: "session", value: legacy)
        let model = try newModel(secrets)
        #expect(model.accounts().isEmpty)
        #expect(secrets.get(name: "session") == legacy)
        #expect(AccountBundle.outStore(bundle: nil, individual: Data(legacy.utf8))?.accounts.count == 1)
    }

    // MARK: Error texts

    @Test func everyFailureOfASignInReadsTheSame() async throws {
        let cases: [(String, CannedServer.Answer)] = [
            ("no internet -1009", broken(.notConnectedToInternet)),
            ("timeout -1001", broken(.timedOut)),
            ("no host -1003", broken(.cannotFindHost)),
            ("no connection -1004", broken(.cannotConnectToHost)),
            ("dropped -1005", broken(.networkConnectionLost)),
            // No sentence of its own: Apple shows the system's text.
            ("DNS -1006", broken(.dnsLookupFailed)),
            ("bad server answer -1011", broken(.badServerResponse)),
            ("unsupported URL -1002", broken(.unsupportedURL)),
            ("certificate untrusted -1202", broken(.serverCertificateUntrusted)),
            ("certificate expired -1201", broken(.serverCertificateHasBadDate)),
            ("tls -1200", broken(.secureConnectionFailed)),
            ("401", jellyfin(authenticate: 401)),
            ("403", jellyfin(authenticate: 403)),
            ("500", jellyfin(authenticate: 500)),
            ("418", jellyfin(authenticate: 418)),
        ]
        for (index, (name, answer)) in cases.enumerated() {
            let host = "texts\(index).example"
            CannedServer.serve(host, answer)
            let oldText: String
            do {
                _ = try await oldClient(host).authenticate(username: "paul", password: "pw")
                Issue.record("\(name): the old code did not fail")
                continue
            } catch { oldText = readableError(error) }

            let model = try newModel(FakeSecrets())
            NetworkMemory.shared.clear()
            let newText: String
            do {
                _ = try await model.signIn(address: "https://\(host)", kind: .jellyfin, user: "paul", password: "pw")
                Issue.record("\(name): the core did not fail")
                continue
            } catch { newText = shown(error, model) }
            #expect(newText == oldText, "\(name)")
        }
    }

    // MARK: Quick Connect

    @Test func quickConnectStartsAndSignsInLikeTheOldClient() async throws {
        let host = "quick.example"
        CannedServer.serve(host, jellyfin())
        let client = oldClient(host)
        let oldCode = try await client.quickConnectStart()
        let session = try await client.signInWithQuickConnect(oldCode)
        var bundles = ServerBundles()
        bundles.set(AccountBundle(session), for: .jellyfin)

        let secrets = FakeSecrets()
        let model = try newModel(secrets)
        let code = try await model.quickConnectStart(address: "https://\(host)")
        #expect(code.code == oldCode.code)
        #expect(code.confidential == oldCode.confidential)
        let end = try await model.quickConnectWait(address: "https://\(host)", code: code, listener: Counting())
        #expect(end.signedIn != nil)
        #expect(try object(secrets.get(name: "konten")) == (try object(try oldStored(bundles)["konten"])))
    }

    @Test func anExpiredQuickConnectCodeEndsWithTheOldText() async throws {
        let host = "expired.example"
        CannedServer.serve(host, jellyfin(connect: 404))
        let client = oldClient(host)
        let oldCode = try await client.quickConnectStart()
        #expect(await client.quickConnectAskAgain(oldCode) == .expired)
        let oldText = QuickConnectDeadline.endText(last: .expired)

        let model = try newModel(FakeSecrets())
        let code = try await model.quickConnectStart(address: "https://\(host)")
        let end = try await model.quickConnectWait(address: "https://\(host)", code: code, listener: Counting())
        #expect(end.signedIn == nil)
        #expect(end.message == oldText)
    }

    @Test func quickConnectSwitchedOffReadsLikeTheOldText() async throws {
        let host = "quick-off.example"
        CannedServer.serve(host) { seen in
            seen.path == "/QuickConnect/Initiate" ? .success((503, "")) : jellyfin()(seen)
        }
        let oldText: String
        do {
            _ = try await oldClient(host).quickConnectStart()
            Issue.record("the old code did not fail")
            return
        } catch { oldText = readableError(error) }
        let model = try newModel(FakeSecrets())
        NetworkMemory.shared.clear()
        do {
            _ = try await model.quickConnectStart(address: "https://\(host)")
            Issue.record("the core did not fail")
        } catch { #expect(shown(error, model) == oldText) }
    }

    // MARK: Plex address

    @Test func theNewPlexAddressKeepsTheOldRecord() throws {
        func details(local: Bool, relay: Bool) -> PlexSessionDetails {
            PlexSessionDetails(
                machineIdentifier: "MACHINE1", serverName: "Plex", accountToken: "ACCOUNT", isLocal: local,
                isRelay: relay, homeUserUUID: "uuid", userImage: nil)
        }
        let session = Session(
            accessToken: "SERVERTOKEN", userID: "42", userName: "paul",
            serverURL: URL(string: "http://192.168.1.5:32400")!, kind: .plex, plex: details(local: true, relay: false))
        let moved = Session(
            accessToken: "OTHERTOKEN", userID: "42", userName: "paul",
            serverURL: URL(string: "https://relay.plex.direct:443")!, kind: .plex,
            plex: details(local: false, relay: true))
        var old = ServerBundles()
        old.set(AccountBundle(session), for: .plex)
        let seed = try oldStored(old)

        // The old `plexRouteMoved`.
        var bundle = try #require(old.bundle(for: .plex))
        bundle.record(moved)
        old.set(bundle, for: .plex)
        let expected = try oldStored(old)

        let secrets = FakeSecrets()
        for (key, value) in seed { secrets.set(name: key, value: value) }
        let model = try newModel(secrets)
        let route = PlexRouteInfo(uri: "https://relay.plex.direct:443", isLocal: false, isRelay: true, token: "OTHERTOKEN")
        #expect(model.movePlexRoute(key: session.accountKey, route: route))
        #expect(try object(secrets.get(name: "konten.plex")) == (try object(expected["konten.plex"])))
        #expect(secrets.get(name: "aktiveArt") == expected["aktiveArt"])
        let none = PlexRouteInfo(uri: "", isLocal: false, isRelay: false, token: "")
        #expect(!model.movePlexRoute(key: "plex:NOPE|1", route: none))
    }

    // MARK: Own headers

    @Test func aRegisteredOwnHeaderReachesTheServerThroughTheCoreClient() async throws {
        let host = "headers.example"
        CannedServer.serve(host, jellyfin())
        let url = URL(string: "https://\(host)")!
        OwnHeaders.setDown([JellyfinKit.OwnHeader(name: "X-Gateway", value: "secret")], for: url)
        defer { OwnHeaders.setDown([], for: url) }
        let model = try newModel(FakeSecrets(), prepare: { $0.ownHeadersSet() })
        _ = try await model.signIn(address: url.absoluteString, kind: .jellyfin, user: "paul", password: "pw")
        let seen = CannedServer.seen(host)
        #expect(!seen.isEmpty)
        #expect(seen.allSatisfy { $0.gateway == "secret" })
    }
}
