import Foundation
import JellyfinKit
import Observation
import StoreKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// **The key for the direct apps (Windows, Linux, Android), fetched on demand.**
//
// Whoever supports Swiftly through the App Store gets a key here that unlocks the same
// thing in the direct apps. Nothing is unlocked on Apple, and nothing is stored on this
// device: the key is asked for each time (the same purchase gives the same key). The
// purchase record goes to the payment server once per tap; the server checks Apple's
// signature. Included in all three Apple targets.

/// Why there is no key. One word per cause, so the page can say what to do.
enum SupportKeyFailure: Equatable, Sendable {
    /// No connection to the server.
    case offline
    /// This Apple Account has no active plan to send.
    case noPurchase
    /// A test purchase (TestFlight, Xcode): the server does not give keys for those.
    case sandbox
    /// The monthly plan has run out.
    case expired
    /// The purchase was refunded.
    case revoked
    /// Too many tries from one address.
    case tooMany
    /// Anything else the server said no to.
    case server
}

/// The whole state of the key row. A key exists only in `.key`.
enum SupportKeyState: Equatable, Sendable {
    case idle
    case loading
    /// `expires` is `nil` for the lifetime plan.
    case key(String, plan: SupportPlan, expires: Date?)
    case failed(SupportKeyFailure)
}

/// What the server's answer means. Pure, so it is tested without a network.
enum SupportKeyReply {
    static func state(status: Int, body: Data) -> SupportKeyState {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        if status == 200 {
            guard let key = object?["key"] as? String, key.hasPrefix("SS2-"),
                  let planName = object?["plan"] as? String,
                  let plan = SupportPlan(rawValue: planName), plan != .tip else { return .failed(.server) }
            let expires = (object?["expires"] as? Double).map { Date(timeIntervalSince1970: $0) }
            return .key(key, plan: plan, expires: expires)
        }
        switch object?["error"] as? String {
        case "sandbox": return .failed(.sandbox)
        case "expired": return .failed(.expired)
        case "revoked": return .failed(.revoked)
        case "rate_limited": return .failed(.tooMany)
        default: return .failed(.server)
        }
    }
}

/// The one holder of the row's state. Not persisted.
@MainActor
@Observable
final class SupportKeyModel {
    static let shared = SupportKeyModel()

    private(set) var state: SupportKeyState = .idle
    private var running = false

    private static let endpoint = URL(string: "https://pay.paulherter.de/apple-key")!

    /// The address to ask. Debug builds can point it at a local stand-in
    /// (`-SupportKeyStub http://127.0.0.1:8765/apple-key`) for the proof run.
    private static var url: URL {
        #if DEBUG
        if let text = UserDefaults.standard.string(forKey: "SupportKeyStub"), let stub = URL(string: text) { return stub }
        #endif
        return endpoint
    }

    /// Back to the quiet row (the sheet closes, the key goes with it).
    func reset() {
        guard !running else { return }
        state = .idle
    }

    /// Asks for the key with the current plan's signed purchase record.
    func fetch() {
        guard !running else { return }
        running = true
        state = .loading
        Task {
            let result = await Self.request()
            state = result
            running = false
        }
    }

    private static func request() async -> SupportKeyState {
        guard let jws = await currentRecord() else { return .failed(.noPurchase) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["transaction": jws])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return SupportKeyReply.state(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        } catch {
            return .failed(.offline)
        }
    }

    /// The signed record (JWS) of the plan that is active now: lifetime first, else the
    /// newest monthly one. Sent as it is; the server checks it.
    private static func currentRecord() async -> String? {
        var best: (transaction: Transaction, jws: String)?
        for await entry in Transaction.currentEntitlements {
            guard case let .verified(transaction) = entry,
                  let plan = SupportProductID.plan(for: transaction.productID), plan != .tip,
                  transaction.revocationDate == nil else { continue }
            if best == nil || plan == .lifetime
                || transaction.purchaseDate > best!.transaction.purchaseDate {
                best = (transaction, entry.jwsRepresentation)
            }
        }
        #if DEBUG
        if best == nil, UserDefaults.standard.string(forKey: "SupportKeyStub") != nil { return "debug.stub.record" }
        #endif
        return best?.jws
    }

    func copy(_ key: String) {
        #if os(tvOS)
        // The Apple TV has no pasteboard.
        _ = key
        #elseif canImport(UIKit)
        UIPasteboard.general.string = key
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
        #endif
    }
}

/// The texts of the row, in the app's language (catalog keys are the German sentences).
enum SupportKeyText {
    static var title: String { String(localized: "Schlüssel für Windows, Linux und Android") }
    static var detail: String { String(localized: "Damit schaltest du Swiftly dort frei.") }
    static var loading: String { String(localized: "Schlüssel wird geholt …") }
    static var copy: String { String(localized: "Kopieren") }
    static var copied: String { String(localized: "Kopiert") }
    static var retry: String { String(localized: "Noch mal") }
    static var paste: String {
        String(localized: "Einfügen: In Swiftly für Windows, Linux oder Android unter Swiftly unterstützen › Ich habe einen Unterstützer-Schlüssel.")
    }

    static func validity(plan: SupportPlan, expires: Date?) -> String {
        guard plan == .monthly, let expires else { return String(localized: "Gilt für immer.") }
        return String(localized: "Gilt bis \(expires.formatted(date: .long, time: .omitted)).")
    }

    static func failure(_ reason: SupportKeyFailure) -> String {
        switch reason {
        case .offline: String(localized: "Keine Verbindung. Versuch es gleich noch mal.")
        case .noPurchase: String(localized: "Auf diesem Apple Account ist kein Plan aktiv.")
        case .sandbox: String(localized: "Im TestFlight-Test gibt es keinen Schlüssel.")
        case .expired: String(localized: "Dein Monatsabo ist abgelaufen. Mit der Verlängerung gibts wieder einen Schlüssel.")
        case .revoked: String(localized: "Dieser Kauf wurde erstattet. Dafür gibt es keinen Schlüssel.")
        case .tooMany: String(localized: "Zu viele Versuche. Probier es in ein paar Minuten noch mal.")
        case .server: String(localized: "Das hat nicht geklappt. Versuch es später noch mal.")
        }
    }
}
