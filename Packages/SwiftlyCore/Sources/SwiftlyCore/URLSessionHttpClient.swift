import Foundation

/// The core's HTTP on Apple platforms: `URLSession`, so the app carries no TLS stack of its own and
/// gets the system's trust (user-installed CAs, profiles), proxies, gzip, HTTP/2 and the local
/// network prompt (`waitsForConnectivity`) for free.
///
/// Behaves like the old reqwest transport: 15 s without data, 20 s for the whole call, a request's
/// own timeout replaces both, redirects are followed and keep the token on the server it was meant
/// for (see ``RedirectGuard``), no response cache. Cookies use the shared jar, as the Swift app
/// always did; the clients the core has so far use header authentication and need none.
/// Header order cannot be kept (`URLRequest` holds a dictionary); servers do not depend on it.
public final class URLSessionHttpClient: HttpClient {
    private let session: URLSession
    private let prepare: (@Sendable (inout URLRequest) -> Void)?
    private let observe: (@Sendable (URL, Data) -> Void)?

    /// - Parameter observe: sees every answer (address, body) before the core does; diagnostics only (the
    ///   shadow comparison of the home page), `nil` in a normal build.
    /// - Parameter prepare: runs on every request before it goes out; the app adds the user's own
    ///   gateway headers for the own server here (`OwnHeaders`, Cloudflare Access and the like).
    public init(
        configuration: URLSessionConfiguration = URLSessionHttpClient.defaultConfiguration(),
        prepare: (@Sendable (inout URLRequest) -> Void)? = nil,
        observe: (@Sendable (URL, Data) -> Void)? = nil
    ) {
        session = URLSession(configuration: configuration)
        self.prepare = prepare
        self.observe = observe
    }

    /// 15 s / 20 s, waits for connectivity (local network permission), no cache.
    public static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    public func send(request: NetRequest) async throws -> NetResponse {
        guard let url = URL(string: request.url) else { throw HttpFailure.Other(message: "bad address") }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod =
            switch request.method {
            case .get: "GET"
            case .post: "POST"
            case .put: "PUT"
            case .delete: "DELETE"
            }
        for header in request.headers { urlRequest.setValue(header.value, forHTTPHeaderField: header.name) }
        urlRequest.httpBody = request.body
        prepare?(&urlRequest)
        if let ms = request.timeoutMs {
            // The per-request timeout also ends the wait for connectivity.
            urlRequest.timeoutInterval = Double(ms) / 1000
        }
        do {
            let (data, response) = try await session.data(for: urlRequest, delegate: RedirectGuard(keepMethod: request.keepMethod))
            guard let http = response as? HTTPURLResponse else {
                throw HttpFailure.Other(message: "no HTTP response")
            }
            observe?(url, data)
            var headers: [NetHeader] = []
            for (name, value) in http.allHeaderFields {
                if let name = name as? String, let value = value as? String {
                    headers.append(NetHeader(name: name, value: value))
                }
            }
            return NetResponse(
                status: UInt16(clamping: http.statusCode), headers: headers, body: data,
                url: http.url?.absoluteString)
        } catch let failure as HttpFailure {
            throw failure
        } catch {
            throw Self.failure(error)
        }
    }

    /// `NSURLErrorDomain` code and text, sorted the way `JellyfinError(petition:)` sorts them.
    static func failure(_ error: Error) -> HttpFailure {
        if error is CancellationError { return .Cancelled }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return .Other(message: "\(ns.domain) \(ns.code)") }
        if ns.code == NSURLErrorCancelled { return .Cancelled }
        if (-1206 ... -1200).contains(ns.code) {
            return .Certificate(code: Int32(ns.code), text: ns.localizedDescription)
        }
        NetworkMemory.shared.set(code: Int32(clamping: ns.code), text: ns.localizedDescription)
        return .Network(code: Int32(clamping: ns.code))
    }
}

/// The system's own sentence of the last network failure. The core knows only the code, but on
/// Apple the app shows `localizedDescription` for a code it has no sentence for; a host that
/// shows a failed call asks ``take()`` and hands both to `AccountsModel.failureTextSystem`.
public final class NetworkMemory: @unchecked Sendable {
    public static let shared = NetworkMemory()
    private let lock = NSLock()
    private var last: (code: Int32, text: String)?

    /// A new call starts: what was left from an earlier one does not count.
    public func clear() {
        lock.lock()
        last = nil
        lock.unlock()
    }

    func set(code: Int32, text: String) {
        lock.lock()
        last = (code, text)
        lock.unlock()
    }

    /// The last failure since ``clear()``.
    public func take() -> (code: Int32, text: String)? {
        lock.lock()
        defer { lock.unlock() }
        return last
    }
}

/// Follows redirects like `URLSession` does, but a target on another origin (scheme, host, port)
/// gets only `Accept`, `User-Agent` and (with a body) `Content-Type`: the token and the user's own
/// gateway headers never leave the server they were meant for.
///
/// With `keepMethod` (the Seerr sign-in, `KeepPostRedirects` in the old code) a redirect that would turn the
/// POST into a GET is refused: the 3xx answer comes back as the result instead of a misleading 405.
final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    private let keepMethod: Bool

    init(keepMethod: Bool = false) { self.keepMethod = keepMethod }

    /// `KeepPostRedirects.keepsMethod`: a missing method counts as GET.
    static func keepsMethod(original: String?, redirected: String?) -> Bool {
        (original ?? "GET").uppercased() == (redirected ?? "GET").uppercased()
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        if keepMethod,
            !Self.keepsMethod(original: task.originalRequest?.httpMethod, redirected: request.httpMethod)
        {
            return nil
        }
        var next = request
        let from = task.originalRequest?.url
        let hasBody = next.httpBody != nil || next.httpBodyStream != nil
        if let from, let to = next.url, !Self.sameOrigin(from, to) {
            let kept = ["accept", "user-agent"] + (hasBody ? ["content-type"] : [])
            next.allHTTPHeaderFields = (next.allHTTPHeaderFields ?? [:]).filter { kept.contains($0.key.lowercased()) }
        } else if !hasBody {
            next.setValue(nil, forHTTPHeaderField: "Content-Type")
        }
        return next
    }

    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        func port(_ u: URL) -> Int { u.port ?? (u.scheme?.lowercased() == "https" ? 443 : 80) }
        return a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased()
            && port(a) == port(b)
    }
}
