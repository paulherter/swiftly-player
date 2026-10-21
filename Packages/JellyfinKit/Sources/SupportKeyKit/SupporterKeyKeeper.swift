import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import JellyfinKit

/// Sends the licence request. Swappable for tests.
public protocol SupporterLicenseTransport: Sendable {
    /// Posts `body` (form-encoded) and returns status code and body.
    func post(_ url: URL, body: Data) async throws -> (status: Int, body: Data)
}

/// The real transport: one short POST, no cookies, no cache.
public struct URLSessionLicenseTransport: SupporterLicenseTransport {
    public init() {}

    public func post(_ url: URL, body: Data) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// **Keeps a supporter key and the status it grants up to date.** Direct builds only.
///
/// - `activate` checks a pasted key, stores it and sets the status and plan.
/// - `applyExpiry` (every app start) turns the status off when a monthly key ran out, and back
///   on when a stored key counts again. The key itself stays stored.
/// - `refreshIfDue` asks the shop, at most every 12 hours from the expiry day minus 10 days
///   (monthly) or every 30 days (lifetime, for refunds), whether the licence still runs. It
///   sends only the random licence number. A renewed monthly key replaces the stored one;
///   a refunded licence removes it. Network errors change nothing.
///
/// Renewal design: the shop signs each monthly key until the end of the paid period plus a
/// few days of grace, and signs a new one when the next payment arrives. The app fetches it
/// before the old one runs out. No account, and offline use keeps working until the expiry day.
public final class SupporterKeyKeeper {
    /// Storage keys. Changing one loses what devices have stored.
    public static let keyStorageKey = "support.key"
    public static let checkedStorageKey = "support.keyChecked"

    /// Monthly keys: start asking this long before the expiry day.
    static let renewWindow: TimeInterval = 10 * 86_400
    static let monthlyInterval: TimeInterval = 12 * 3_600
    static let lifetimeInterval: TimeInterval = 30 * 86_400

    public let store: SupportStore
    let publicKey: [UInt8]
    let app: SupporterKey.App
    let allowTestKeys: Bool
    let transport: any SupporterLicenseTransport
    let url: URL

    public init(store: SupportStore,
                publicKey: [UInt8] = SupporterKey.publicKey,
                app: SupporterKey.App = .swiftly,
                allowTestKeys: Bool = false,
                transport: any SupporterLicenseTransport = URLSessionLicenseTransport(),
                url: URL = URL(string: DirectSupport.licenseURL)!) {
        self.store = store
        self.publicKey = publicKey
        self.app = app
        self.allowTestKeys = allowTestKeys
        self.transport = transport
        self.url = url
    }

    /// The stored key text, if any.
    public var storedKey: String? {
        store.storage.data(forKey: Self.keyStorageKey).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The stored key, read without the expiry check.
    public var license: SupporterLicense? {
        guard let storedKey, case let .success(license) = read(storedKey) else { return nil }
        return license
    }

    /// Checks a pasted key. A valid one is stored and turns the status on.
    @discardableResult
    public func activate(_ text: String, now: Date = Date()) -> SupporterKeyResult {
        let result = SupporterKey.verify(text, publicKey: publicKey, app: app, allowTestKeys: allowTestKeys, now: now)
        guard result.isValid, case let .success(license) = read(text) else { return result }
        save(text.trimmingCharacters(in: .whitespacesAndNewlines), license: license, now: now)
        return result
    }

    /// Call at every app start (and after a refresh). Only touches statuses that came from a key.
    public func applyExpiry(now: Date = Date()) {
        guard let license else { return }
        let fromKey: Bool
        switch store.status {
        case .none: fromKey = true
        case let .supporter(source, _): fromKey = source == .key
        }
        guard fromKey else { return }
        if license.isActive(at: now) {
            store.status = .supporter(source: .key, since: license.issuedAt)
            store.plan = license.supportPlan
        } else {
            store.status = .none
        }
    }

    public enum Refresh: Equatable, Sendable {
        case notDue
        case unchanged
        case renewed
        case ended
        case revoked
        case failed
    }

    /// Asks the shop when due; see the type comment.
    @discardableResult
    public func refreshIfDue(now: Date = Date()) async -> Refresh {
        guard let current = license, isDue(current, now: now) else { return .notDue }
        let body = Data(("id=" + current.id).utf8)
        guard let (status, data) = try? await transport.post(url, body: body), status == 200,
              let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
            return .failed
        }
        markChecked(now)
        switch answer.state {
        case "active":
            guard let text = answer.key, case let .success(fresh) = read(text),
                  fresh.app == current.app, fresh.id == current.id,
                  (fresh.expiresAt ?? .distantFuture) >= (current.expiresAt ?? .distantFuture) else {
                return .unchanged
            }
            if text == storedKey { applyExpiry(now: now); return .unchanged }
            save(text, license: fresh, now: now)
            return .renewed
        case "ended":
            // The plan ended; the key runs out on its own expiry day.
            applyExpiry(now: now)
            return .ended
        case "revoked":
            store.storage.setData(nil, forKey: Self.keyStorageKey)
            if case .supporter(.key, _) = store.status { store.status = .none }
            return .revoked
        default:
            return .unchanged
        }
    }

    func isDue(_ license: SupporterLicense, now: Date) -> Bool {
        let last = lastChecked ?? .distantPast
        if let expiresAt = license.expiresAt {
            return now >= expiresAt.addingTimeInterval(-Self.renewWindow)
                && now.timeIntervalSince(last) >= Self.monthlyInterval
        }
        return now.timeIntervalSince(last) >= Self.lifetimeInterval
    }

    var lastChecked: Date? {
        store.storage.data(forKey: Self.checkedStorageKey)
            .flatMap { TimeInterval(String(decoding: $0, as: UTF8.self)) }
            .map { Date(timeIntervalSince1970: $0) }
    }

    private func markChecked(_ now: Date) {
        store.storage.setData(Data(String(Int(now.timeIntervalSince1970)).utf8), forKey: Self.checkedStorageKey)
    }

    private func read(_ text: String) -> Result<SupporterLicense, SupporterKey.Failure> {
        SupporterKey.read(text, publicKey: publicKey, app: app, allowTestKeys: allowTestKeys)
    }

    private func save(_ text: String, license: SupporterLicense, now: Date) {
        store.storage.setData(Data(text.utf8), forKey: Self.keyStorageKey)
        // A fresh key counts as checked: no request right after pasting.
        markChecked(now)
        store.status = license.isActive(at: now) ? .supporter(source: .key, since: license.issuedAt) : .none
        store.plan = license.supportPlan
    }

    private struct Answer: Decodable {
        let state: String
        let key: String?
    }
}
