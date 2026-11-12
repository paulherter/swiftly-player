import Foundation
import Security
import UIKit

/// The platform pieces of the real app that Rust calls through the C table: HTTP over `URLSession` (the same
/// configuration and redirect rule as `Packages/SwiftlyCore/.../URLSessionHttpClient.swift`, so system trust, user CAs,
/// proxy and the local network prompt behave as in the real app) and the Keychain under this app's own service.
enum HostPlatform {
    /// Whether the real app runs (registered at launch); false with `--demo`.
    nonisolated(unsafe) static var isLive = false

    static let service = "de.paulherter.swiftly.rustui.secrets"

    nonisolated(unsafe) private static var table = SwiftlyPlatform(
        ctx: nil, http: httpCall, secret_get: secretGet, secret_set: secretSet, secret_remove: secretRemove, release: releaseBuffer)

    /// Registers everything with the Rust core. Call once, before the first `RustView` lays out.
    static func register() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Swiftly", isDirectory: true)
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Swiftly", isDirectory: true)
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        try? fm.createDirectory(at: caches, withIntermediateDirectories: true)
        isLive = true
        swiftly_rust_init_live(&table, support.path, caches.path, UIDevice.current.name)
    }

    // MARK: HTTP

    /// 15 s / 20 s, waits for connectivity (local network permission), no cache: as `URLSessionHttpClient`.
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.waitsForConnectivity = true
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 20
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c, delegate: RedirectGuard(), delegateQueue: nil)
    }()

    private static let httpCall: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<UInt8>?, Int, Int32, UnsafeMutablePointer<Int>?) -> UnsafeMutablePointer<UInt8>? = { _, method, url, headers, body, bodyLen, timeoutMs, outLen in
        guard let method, let url, let u = URL(string: String(cString: url)) else { return nil }
        var request = URLRequest(url: u)
        request.httpMethod = String(cString: method)
        if let headers {
            for line in String(cString: headers).split(separator: "\n") {
                guard let sep = line.range(of: ": ") else { continue }
                request.setValue(String(line[sep.upperBound...]), forHTTPHeaderField: String(line[..<sep.lowerBound]))
            }
        }
        if let body, bodyLen > 0 { request.httpBody = Data(bytes: body, count: bodyLen) }
        if timeoutMs > 0 { request.timeoutInterval = Double(timeoutMs) / 1000 }
        let wait = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var answer = Data()
        session.dataTask(with: request) { data, response, error in
            answer = encode(data: data, response: response, error: error, fallback: u)
            wait.signal()
        }.resume()
        wait.wait()
        guard let out = malloc(answer.count)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        answer.copyBytes(to: out, count: answer.count)
        outLen?.pointee = answer.count
        return out
    }

    private static func encode(data: Data?, response: URLResponse?, error: Error?, fallback: URL) -> Data {
        if let error {
            let ns = error as NSError
            guard ns.domain == NSURLErrorDomain else { return Data("Enet:-1005\n\(ns.domain) \(ns.code)".utf8) }
            if ns.code == NSURLErrorCancelled { return Data("Ecancelled\n".utf8) }
            if (-1206 ... -1200).contains(ns.code) { return Data("Ecert\n\(ns.localizedDescription)".utf8) }
            return Data("Enet:\(ns.code)\n\(ns.localizedDescription)".utf8)
        }
        guard let http = response as? HTTPURLResponse else { return Data("Enet:-1005\nno HTTP response".utf8) }
        var out = Data("S\(http.statusCode)\n".utf8)
        for (k, v) in http.allHeaderFields {
            if let k = k as? String, let v = v as? String { out.append(Data("\(k): \(v.replacingOccurrences(of: "\n", with: " "))\n".utf8)) }
        }
        out.append(Data("x-final-url: \((http.url ?? fallback).absoluteString)\n\n".utf8))
        out.append(data ?? Data())
        return out
    }

    // MARK: Keychain (own service; the default access group of this app id, never the real app's items)

    private static func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name]
    }

    private static let secretGet: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? = { _, name in
        guard let name else { return nil }
        var q = query(String(cString: name))
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return strdup(text)
    }

    private static let secretSet: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void = { _, name, value in
        guard let name, let value else { return }
        let q = query(String(cString: name))
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = Data(String(cString: value).utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    private static let secretRemove: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void = { _, name in
        guard let name else { return }
        SecItemDelete(query(String(cString: name)) as CFDictionary)
    }

    private static let releaseBuffer: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, ptr in free(ptr) }
}

/// As `RedirectGuard` of the real app: a redirect to another origin keeps only Accept, User-Agent and (with a body)
/// Content-Type, so the token never leaves its server.
final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
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
