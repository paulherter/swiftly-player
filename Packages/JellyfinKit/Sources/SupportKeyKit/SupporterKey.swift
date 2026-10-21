import Foundation
import JellyfinKit

/// The outcome of checking a supporter key.
public enum SupporterKeyResult: Sendable, Equatable {
    /// `name` is `nil` when the buyer left it empty. `issuedAt` is the purchase day, 00:00 UTC.
    /// `orderID` is the licence number: 16 hex digits for `SS1` keys, 32 for `SS2` keys.
    case valid(app: SupporterKey.App, issuedAt: Date, orderID: String, name: String?)
    case invalid(SupporterKey.Failure)

    public var isValid: Bool {
        if case .valid = self { true } else { false }
    }
}

/// **What a supporter key says**, after its signature was checked.
public struct SupporterLicense: Sendable, Equatable {
    public enum Plan: UInt8, Sendable {
        case monthly = 1
        case lifetime = 2
    }

    public let app: SupporterKey.App
    public let plan: Plan
    /// The purchase day, 00:00 UTC. Stays the same when a monthly key is renewed.
    public let issuedAt: Date
    /// When a monthly key stops counting; `nil` for lifetime keys.
    public let expiresAt: Date?
    /// Random licence number (hex). The only thing the app ever sends to the shop.
    public let id: String
    public let name: String?
    public let isTest: Bool
    /// `SS1` keys from before plans existed; they count as lifetime keys.
    public let isLegacy: Bool

    public func isActive(at now: Date) -> Bool {
        guard let expiresAt else { return true }
        return now < expiresAt
    }

    /// The plan as the support status shows it.
    public var supportPlan: SupportPlan {
        plan == .monthly ? .monthly : .lifetime
    }
}

/// **Supporter keys, verified offline.**
///
/// The website sells a key, signs it with Ed25519 and shows it on the thank-you page and in
/// the email. The app checks the signature against the public key below. Monthly keys carry
/// an expiry day; `SupporterKeyKeeper` fetches the renewed key from the shop before it.
///
/// `SS2-…` (current), byte layout before Base32 (RFC 4648 alphabet, no padding):
///
///     0      version (2)
///     1      flags (bit 0 = test mode)
///     2      app (1 = Swiftly, 2 = Sequence Studio)
///     3      plan (1 = monthly, 2 = lifetime)
///     4..5   purchase day, days since 1970-01-01 UTC, big endian
///     6..7   expiry day (0 = never); valid while now < day x 86400. Monthly keys only.
///     8..23  licence ID, 16 random bytes
///     24..   name, UTF-8, 0 to 48 bytes
///     last 64 bytes: Ed25519 signature over "SS2" + the bytes above
///
/// `SS1-…` (first format, still accepted as a lifetime key):
///
///     0      version (1)
///     1      flags (bit 0 = test mode)
///     2      app
///     3..4   issue day
///     5..12  order ID (8 bytes, shown as 16 hex digits)
///     13..   name, UTF-8, 0 to 48 bytes
///     last 64 bytes: Ed25519 signature over "SS1" + the bytes above
///
/// Pasting is forgiving: surrounding whitespace, lowercase letters, dashes and spaces between
/// groups are fine. Anything else is not.
public enum SupporterKey {
    public enum App: UInt8, Sendable {
        case swiftly = 1
        case sequenceStudio = 2
    }

    /// Why a key was refused. Raw values are stable for logs.
    public enum Failure: String, Error, Sendable, Equatable {
        case empty = "empty"
        case wrongPrefix = "wrongPrefix"
        case tooLong = "tooLong"
        case badEncoding = "badEncoding"
        case tooShort = "tooShort"
        case badSignature = "badSignature"
        case unsupportedVersion = "unsupportedVersion"
        case unknownApp = "unknownApp"
        case wrongApp = "wrongApp"
        case testKey = "testKey"
        case badName = "badName"
        case badPublicKey = "badPublicKey"
        case unknownPlan = "unknownPlan"
        /// A monthly key past its expiry day. Renewal fetches a new one while the plan runs.
        case expired = "expired"
    }

    // MARK: The public key

    /// **The one public key the apps check against (Ed25519, 32 bytes, Base64).**
    ///
    /// The public half of the shop's production signing pair. The private half lives only on
    /// the shop's server. Never change this value: every key sold so far is signed for it.
    public static let publicKeyBase64 = "90hxOk72gFaCS0s3n2OxKoTYBUGvrzw3liCshhfRU2o="

    /// The test key from the shop's test vectors. Only for tests.
    public static let testPublicKeyBase64 = "iojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1w="

    /// True while `publicKeyBase64` is still the test key. A release check can refuse to ship
    /// a direct build with this set.
    public static var usesTestPublicKey: Bool {
        publicKeyBase64 == testPublicKeyBase64
    }

    /// The decoded key; empty if the Base64 above were broken (then every key is refused).
    public static let publicKey: [UInt8] = decodePublicKey(publicKeyBase64) ?? []

    public static func decodePublicKey(_ base64: String) -> [UInt8]? {
        guard let data = Data(base64Encoded: base64), data.count == 32 else { return nil }
        return [UInt8](data)
    }

    // MARK: Checking

    static let signatureLength = 64
    static let maxNameBytes = 48
    static let maxTextLength = 400

    /// Checks a pasted key, including the expiry of monthly keys.
    ///
    /// - Parameters:
    ///   - app: the only app a key may be for; Swiftly unless a test says otherwise.
    ///   - allowTestKeys: keys from the shop's test mode. Release builds leave this false.
    public static func verify(_ text: String,
                              publicKey: [UInt8] = SupporterKey.publicKey,
                              app expectedApp: App = .swiftly,
                              allowTestKeys: Bool = false,
                              now: Date = Date()) -> SupporterKeyResult {
        switch read(text, publicKey: publicKey, app: expectedApp, allowTestKeys: allowTestKeys) {
        case let .failure(failure):
            return .invalid(failure)
        case let .success(license):
            guard license.isActive(at: now) else { return .invalid(.expired) }
            return .valid(app: license.app, issuedAt: license.issuedAt, orderID: license.id, name: license.name)
        }
    }

    /// Checks signature and layout, but not the expiry: an expired monthly key is still read,
    /// so the app can ask the shop for its renewal.
    public static func read(_ text: String,
                            publicKey: [UInt8] = SupporterKey.publicKey,
                            app expectedApp: App = .swiftly,
                            allowTestKeys: Bool = false) -> Result<SupporterLicense, Failure> {
        guard publicKey.count == 32 else { return .failure(.badPublicKey) }
        // Exactly the characters PHP's trim() removes, so app and shop accept the same input.
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r\0\u{0B}"))
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard trimmed.utf8.count <= maxTextLength else { return .failure(.tooLong) }
        let prefix = trimmed.utf8.prefix(4).map(asciiUppercased)
        let version: UInt8
        switch prefix {
        case Array("SS1-".utf8): version = 1
        case Array("SS2-".utf8): version = 2
        default: return .failure(.wrongPrefix)
        }
        let headLength = version == 1 ? 13 : 24
        guard let raw = base32Decode(Array(trimmed.utf8.dropFirst(4))) else { return .failure(.badEncoding) }
        guard raw.count >= headLength + signatureLength else { return .failure(.tooShort) }

        let payload = Array(raw[..<(raw.count - signatureLength)])
        let signature = Array(raw[(raw.count - signatureLength)...])
        let domain = Array((version == 1 ? "SS1" : "SS2").utf8)
        guard Ed25519.verify(signature: signature, message: domain + payload, publicKey: publicKey) else {
            return .failure(.badSignature)
        }

        guard payload[0] == version else { return .failure(.unsupportedVersion) }
        guard let app = App(rawValue: payload[2]) else { return .failure(.unknownApp) }
        guard app == expectedApp else { return .failure(.wrongApp) }
        let isTest = payload[1] & 1 != 0
        if isTest && !allowTestKeys { return .failure(.testKey) }

        let nameBytes = payload[headLength...]
        // Decoding repairs broken UTF-8; if the bytes changed, they were not valid UTF-8.
        let name = String(decoding: nameBytes, as: UTF8.self)
        guard nameBytes.count <= maxNameBytes, Array(name.utf8) == Array(nameBytes) else {
            return .failure(.badName)
        }

        func day(_ at: Int) -> Int { Int(payload[at]) << 8 | Int(payload[at + 1]) }
        func date(_ day: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(day) * 86_400) }

        if version == 1 {
            return .success(SupporterLicense(app: app, plan: .lifetime, issuedAt: date(day(3)), expiresAt: nil,
                                             id: hex(payload[5..<13]), name: name.isEmpty ? nil : name,
                                             isTest: isTest, isLegacy: true))
        }
        guard let plan = SupporterLicense.Plan(rawValue: payload[3]) else { return .failure(.unknownPlan) }
        let expiryDay = day(6)
        // Monthly keys always expire, lifetime keys never; anything else is not a shop key.
        guard (plan == .monthly) == (expiryDay > 0) else { return .failure(.unknownPlan) }
        return .success(SupporterLicense(app: app, plan: plan, issuedAt: date(day(4)),
                                         expiresAt: expiryDay > 0 ? date(expiryDay) : nil,
                                         id: hex(payload[8..<24]), name: name.isEmpty ? nil : name,
                                         isTest: isTest, isLegacy: false))
    }

    static func hex(_ bytes: ArraySlice<UInt8>) -> String {
        bytes.map { byte in
            let hex = String(byte, radix: 16)
            return byte < 16 ? "0" + hex : hex
        }.joined()
    }

    /// The status a valid key grants, dated by its issue day.
    public static func status(for result: SupporterKeyResult) -> SupportStatus {
        guard case let .valid(_, issuedAt, _, _) = result else { return .none }
        return .supporter(source: .key, since: issuedAt)
    }

    /// Only a to z, like the shop's `strtoupper`: `uppercased()` would also turn letters such
    /// as "ſ" into ASCII and accept spellings the shop refuses.
    static func asciiUppercased(_ c: UInt8) -> UInt8 {
        c >= 97 && c <= 122 ? c - 32 : c
    }

    /// RFC 4648 Base32 without padding. Skips dashes and whitespace, refuses other characters
    /// and non-zero trailing bits (so each key has exactly one spelling).
    static func base32Decode(_ text: [UInt8]) -> [UInt8]? {
        let skipped: Set<UInt8> = [UInt8(ascii: "-"), UInt8(ascii: " "), UInt8(ascii: "\n"),
                                   UInt8(ascii: "\r"), UInt8(ascii: "\t")]
        var out = [UInt8]()
        var buffer: UInt32 = 0
        var bits = 0
        for c in text where !skipped.contains(c) {
            let u = asciiUppercased(c)
            let value: UInt32
            switch u {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): value = UInt32(u - UInt8(ascii: "A"))
            case UInt8(ascii: "2")...UInt8(ascii: "7"): value = UInt32(u - UInt8(ascii: "2")) + 26
            default: return nil
            }
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> UInt32(bits)) & 0xff))
            }
            buffer &= (1 << UInt32(bits)) - 1
        }
        guard bits < 5, buffer == 0 else { return nil }
        return out
    }
}
