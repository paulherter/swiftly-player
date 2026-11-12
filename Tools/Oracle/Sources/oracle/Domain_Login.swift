import Foundation
@testable import JellyfinKit

// Login / Quick Connect / accounts: login_error, login_quick, login_http, login_accounts, login_kind.
// Cases: crates/swiftly-hardening/src/inputs/login.rs, tests/oracle_login.rs.
// The HTTP domain runs the REAL JellyfinClient over a URLProtocol stub (canned answer, request recorded).

private func lgDict(_ raw: Any) throws -> [String: Any] {
    guard let d = raw as? [String: Any] else { throw OracleError("case is not an object") }
    return d
}

private func lgSync<T>(_ work: @escaping @Sendable () async -> T) -> T {
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var out: T?
    Task.detached {
        out = await work()
        sem.signal()
    }
    sem.wait()
    return out!
}

// MARK: - login_error

private func lgJellyfinError(_ e: [String: Any]) throws -> any Error {
    switch srStr(e["t"]) ?? "" {
    case "network": return JellyfinError.network(code: srInt(e["code"]) ?? 0)
    case "certificate":
        let reason = srStr(e["reason"]) ?? ""
        let r: CertificateReason = switch reason {
        case "not_trusted": .notTrusted
        case "expired": .expired
        case "not_yet": .appliesNotYet
        case "other_address": .otherAddress
        default: .otherwise
        }
        return JellyfinError.certificate(r)
    case "transport": return JellyfinError.transport(srStr(e["text"]) ?? "")
    case "transport_special":
        switch srStr(e["which"]) ?? "" {
        case "no_http": return JellyfinError.transport("Keine HTTP-Antwort.")
        case "login_page": return JellyfinError.transport(OwnHeaders.loginPageText)
        case "qc_disabled": return JellyfinError.transport(translated("Der Server hat Quick Connect abgeschaltet."))
        case "refresh": return JellyfinError.transport("Der Server hat die Auffrischung abgelehnt.")
        default: return JellyfinError.transport(translated("Das andere Gerät hat nicht reagiert."))
        }
    case "not_auth": return JellyfinError.notAuthenticated
    case "two_factor": return JellyfinError.twoFactor
    case "invalid_url": return JellyfinError.invalidServerURL
    case "http": return JellyfinError.http(status: srInt(e["status"]) ?? 0, body: srStr(e["body"]))
    case "decoding": return JellyfinError.decoding(srStr(e["text"]) ?? "")
    case "no_source": return JellyfinError.noPlayableSource
    case "rejected": return JellyfinError.playbackRejected(srStr(e["reason"]) ?? "")
    case "url":
        return NSError(domain: NSURLErrorDomain, code: srInt(e["code"]) ?? 0,
                       userInfo: [NSLocalizedDescriptionKey: srStr(e["desc"]) ?? ""])
    default: throw OracleError("bad error kind")
    }
}

let domainLoginError = Domain("login_error") { raw in
    let c = try lgDict(raw)
    if srStr(c["op"]) == "lang" { return translated("Keine Verbindung.") }
    let error = try lgJellyfinError(try lgDict(c["e"] as Any))
    return readableError(error)
}

// MARK: - login_quick

private final class LgScript: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    let states: [QuickConnectState]
    init(_ s: [QuickConnectState]) { states = s }
    func next() -> QuickConnectState {
        lock.lock(); defer { lock.unlock() }
        let s = states[min(n, states.count - 1)]
        n += 1
        return s
    }
}

private func lgState(_ s: String) -> QuickConnectState {
    switch s {
    case "released": .released
    case "expired": .expired
    case "failed": .failed
    default: .opened
    }
}

private func lgStateName(_ s: QuickConnectState) -> String {
    switch s {
    case .opened: "opened"
    case .released: "released"
    case .expired: "expired"
    case .failed: "failed"
    }
}

let domainLoginQuick = Domain("login_quick") { raw in
    let c = try lgDict(raw)
    switch srStr(c["op"]) ?? "" {
    case "from_error":
        let s = QuickConnectState(error: srBool(c["expired"]) == true ? QuickConnectExpired() : JellyfinError.network(code: -1001))
        return [lgStateName(s), s.endedWait] as [Any]
    case "ended":
        let s = lgState(srStr(c["state"]) ?? "")
        return [lgStateName(s), s.endedWait] as [Any]
    case "consts":
        return [QuickConnectDeadline.seconds, QuickConnectDeadline.tick, QuickConnectDeadline.attempts]
    case "end_text":
        return QuickConnectDeadline.endText(last: lgState(srStr(c["state"]) ?? ""))
    case "expired_text":
        return QuickConnectExpired().errorDescription ?? ""
    case "remaining":
        let ms = srInt64(c["ms"]) ?? 0
        return QuickConnectWait.remainingSecondsOf(.milliseconds(ms))
    case "outcome":
        let script = LgScript(((c["script"] as? [String]) ?? ["opened"]).map(lgState))
        let deadline = Double(srInt(c["deadline_ms"]) ?? 300) / 1000
        let tick = Double(srInt(c["tick_ms"]) ?? 50) / 1000
        let poll = Double(srInt(c["poll_ms"]) ?? 100) / 1000
        return lgSync {
            let feed = QuickConnectWait.flow(deadline: .seconds(deadline), pollInterval: .seconds(poll), tick: .seconds(tick)) {
                script.next()
            }
            var out = "none"
            var first: Int?
            for await ev in feed {
                switch ev {
                case let .rest(s): if first == nil { first = s }
                case .released: out = "released"
                case let .end(last): out = "end:" + lgStateName(last)
                }
            }
            return [out, first as Any] as [Any]
        }
    default: throw OracleError("bad op")
    }
}

// MARK: - login_http (real client over a URLProtocol stub)

final class LgStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var netCode: Int?
    nonisolated(unsafe) static var seen: [[Any]] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var bodyData = request.httpBody
        if bodyData == nil, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            var all = Data()
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                all.append(contentsOf: buf[0..<n])
            }
            stream.close()
            bodyData = all
        }
        let url = request.url
        let query = (URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { "\($0.name)=\($0.value ?? "")" }.sorted().joined(separator: "&")
        let bodyJSON = bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
        LgStub.seen.append([request.httpMethod ?? "", url!.path, query, bodyJSON ?? NSNull()])
        if let code = LgStub.netCode {
            client?.urlProtocol(self, didFailWithError: URLError(URLError.Code(rawValue: code)))
            return
        }
        let response = HTTPURLResponse(url: url!, statusCode: LgStub.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: LgStub.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func lgText(_ error: any Error) -> String { readableError(error) }

let domainLoginHttp = Domain("login_http") { raw in
    let c = try lgDict(raw)
    let reply = (c["reply"] as? [String: Any]) ?? [:]
    LgStub.seen = []
    LgStub.netCode = srInt(reply["net"])
    LgStub.status = srInt(reply["status"]) ?? 200
    LgStub.body = Data((srStr(reply["body"]) ?? "").utf8)
    guard let base = URL(string: srStr(c["base"]) ?? "http://example.test:8096") else { throw OracleError("bad base") }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [LgStub.self]
    let session = srBool(c["no_session"]) == true ? nil
        : Session(accessToken: "tok", userID: "uid", userName: "nm", serverURL: base)
    let client = JellyfinClient(baseURL: base, deviceID: "dev", deviceName: "dn", clientVersion: "1.0",
                                program: "Swiftly Player", session: session, urlSession: URLSession(configuration: config))
    let code = LoginCode(code: srStr(c["code"]) ?? "", confidential: srStr(c["secret"]) ?? "")
    let op = srStr(c["op"]) ?? ""
    let result: Any = lgSync {
        switch op {
        case "start":
            do {
                let l = try await client.quickConnectStart()
                return ["ok", l.code, l.confidential] as [Any]
            } catch { return ["err", lgText(error)] as [Any] }
        case "released":
            do { return ["ok", try await client.quickConnectReleased(code)] as [Any] }
            catch is QuickConnectExpired { return ["expired"] as [Any] }
            catch { return ["err", lgText(error)] as [Any] }
        case "ask":
            return [lgStateName(await client.quickConnectAskAgain(code))] as [Any]
        case "enabled":
            return [await client.quickConnectAddBar()] as [Any]
        case "share":
            do { try await client.quickConnectShare(code: srStr(c["code"]) ?? ""); return ["ok"] as [Any] }
            catch { return ["err", lgText(error)] as [Any] }
        case "public":
            let users = (try? await client.publicUser()) ?? []
            return users.map { [$0.id, $0.name, nsnull($0.imageMark)] as [Any] }
        case "signin":
            do {
                let s = try await client.signInWithQuickConnect(code)
                return ["ok", s.accessToken, s.userID, s.userName, s.serverURL.absoluteString] as [Any]
            } catch { return ["err", lgText(error)] as [Any] }
        case "image":
            let u = PublicUser(id: srStr(c["id"]) ?? "", name: "n", imageMark: srStr(c["mark"]))
            return [nsnull(await client.userImage(u, border: srInt(c["border"]) ?? 180)?.absoluteString)] as [Any]
        default: return ["bad op"] as [Any]
        }
    }
    // Requests the real client made (method, path, sorted query, JSON body).
    return ["result": result, "seen": LgStub.seen] as [String: Any]
}

// MARK: - login_accounts

private func lgSession(_ x: Any?) throws -> Session {
    guard let s = x as? String else { throw OracleError("session is not a JSON text") }
    return try JSONDecoder().decode(Session.self, from: Data(s.utf8))
}

private func lgSnapshot(_ b: AccountBundle?) -> Any {
    guard let b else { return NSNull() }
    return ["active": b.activeOne.accountKey, "keys": b.accounts.map(\.accountKey),
            "servers": b.server.map(\.absoluteString), "url": b.serverURL.absoluteString,
            "tokens": b.accounts.map(\.accessToken)] as [String: Any]
}

private func lgData(_ x: Any?) -> Data? { (x as? String).map { Data($0.utf8) } }

let domainLoginAccounts = Domain("login_accounts") { raw in
    let c = try lgDict(raw)
    switch srStr(c["op"]) ?? "" {
    case "key":
        guard let s = try? lgSession(c["session"]) else { return NSNull() }
        return [s.accountKey, s.serverIdentity, s.kind.accountKeyPrefix, s.kind.bundleStorageKey] as [Any]
    case "bundle":
        let sessions = try ((c["sessions"] as? [Any]) ?? []).map { try lgSession($0) }
        var bundle = AccountBundle(accounts: sessions, active: srStr(c["active"]))
        var out: [Any] = [lgSnapshot(bundle)]
        for step in (c["steps"] as? [Any]) ?? [] {
            let st = try lgDict(step)
            guard var b = bundle else { break }
            switch srStr(st["op"]) ?? "" {
            case "record": b.record(try lgSession(st["session"])); bundle = b
            case "switch": b.switchTo(toward: srStr(st["id"]) ?? ""); bundle = b
            case "remove": bundle = b.removed(srStr(st["id"]) ?? "")
            case "record_in":
                let r = AccountBundle.record(try lgSession(st["session"]), in: bundle)
                bundle = r.bundle
                out.append(r.wasChange)
            case "on":
                let url = URL(string: srStr(st["server"]) ?? "")
                out.append(url.map { b.accounts(on: $0).map(\.accountKey) } ?? [] as [String])
            case "account":
                out.append(nsnull(b.account(srStr(st["id"]) ?? "")?.accountKey))
            case "fits":
                out.append(b.fitsServer(try lgSession(st["session"])))
            default: throw OracleError("bad step")
            }
            out.append(lgSnapshot(bundle))
        }
        return out
    case "single":
        return lgSnapshot(AccountBundle(try lgSession(c["session"])))
    case "from_store":
        return lgSnapshot(AccountBundle.outStore(bundle: lgData(c["bundle"]), individual: lgData(c["individual"])))
    case "old_gtk":
        guard let d = lgData(c["data"]), let s = AccountBundle.outOldGtkStore(d) else { return NSNull() }
        return [s.accountKey, s.userName, s.accessToken, s.serverURL.absoluteString]
    case "bundles_load":
        let map = (c["store"] as? [String: String]) ?? [:]
        let b = ServerBundles.load { map[$0].map { Data($0.utf8) } }
        return ["active_kind": b.activeKind.rawValue, "kinds": b.kinds.map(\.rawValue),
                "active": lgSnapshot(b.active)] as [String: Any]
    case "bundles_ops":
        let sessions = try ((c["sessions"] as? [Any]) ?? []).map { try lgSession($0) }
        var b = ServerBundles()
        for s in sessions {
            let ex = b.bundle(for: s.kind)
            b.set(AccountBundle.record(s, in: ex).bundle, for: s.kind)
        }
        var out: [Any] = []
        for step in (c["steps"] as? [Any]) ?? [] {
            let st = try lgDict(step)
            let kind = ServerKind(rawValue: srStr(st["kind"]) ?? "jellyfin") ?? .jellyfin
            switch srStr(st["op"]) ?? "" {
            case "switch": b.switchTo(kind)
            case "clear": b.set(nil, for: kind)
            default: throw OracleError("bad step")
            }
            out.append(["active_kind": b.activeKind.rawValue, "kinds": b.kinds.map(\.rawValue)] as [String: Any])
        }
        var written: [String: Any] = [:]
        try b.save { key, data in
            written[key] = data.flatMap { d in
                (try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])) ?? String(data: d, encoding: .utf8)
            } ?? NSNull()
        }
        out.append(written)
        return out
    default: throw OracleError("bad op")
    }
}

// MARK: - login_kind (server kind detection, Emby quirks, address check)

private let lgBasicCheck = NSLock()
nonisolated(unsafe) private var lgState_: CheckState = CheckState()
nonisolated(unsafe) private var lgMarks: [CheckMark] = []

let domainLoginKind = Domain("login_kind") { raw in
    let c = try lgDict(raw)
    switch srStr(c["op"]) ?? "" {
    case "looks_jellyfin":
        var o: [String: Any] = [:]
        if let p = srStr(c["product"]) { o["ProductName"] = p }
        if let v = srStr(c["version"]) { o["Version"] = v }
        let data = try JSONSerialization.data(withJSONObject: o)
        let info = try JSONDecoder().decode(PublicSystemInfo.self, from: data)
        return info.looksLikeJellyfin
    case "rewrite":
        return EmbyPaths.rewrite(srStr(c["path"]) ?? "", userID: srStr(c["user"]))
    case "token_name":
        return EmbyPaths.tokenName(for: ServerKind(rawValue: srStr(c["kind"]) ?? "") ?? .jellyfin)
    case "fallback":
        let e = (c["e"] as? [String: Any]) ?? [:]
        switch srStr(e["t"]) ?? "" {
        case "cancel": return AddressCheck.fallbackPaysOff(to: CancellationError())
        case "ns": return AddressCheck.fallbackPaysOff(to: NSError(domain: NSURLErrorDomain, code: srInt(e["code"]) ?? 0))
        case "ns_other": return AddressCheck.fallbackPaysOff(to: NSError(domain: "other", code: srInt(e["code"]) ?? 0))
        default: return AddressCheck.fallbackPaysOff(to: try lgJellyfinError(e))
        }
    case "deadline":
        return AddressCheck.deadline
    case "check":
        var state = CheckState()
        var marks: [CheckMark] = []
        var out: [Any] = []
        for step in (c["steps"] as? [Any]) ?? [] {
            let st = try lgDict(step)
            switch srStr(st["op"]) ?? "" {
            case "begin":
                let m = state.begin(srStr(st["address"]) ?? "")
                marks.append(m)
                out.append([m.number, m.address])
            case "applies":
                let i = srInt(st["i"]) ?? 0
                out.append(i < marks.count ? state.applies(marks[i]) : NSNull())
            case "complete":
                let i = srInt(st["i"]) ?? 0
                out.append(i < marks.count ? state.complete(marks[i]) : NSNull())
            case "discard": state.discard(); out.append("discard")
            default: throw OracleError("bad step")
            }
            out.append(nsnull(state.ongoing.map { [$0.number, $0.address] as [Any] }))
        }
        return out
    default: throw OracleError("bad op")
    }
}
