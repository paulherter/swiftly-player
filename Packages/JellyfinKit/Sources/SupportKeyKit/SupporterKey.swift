import Foundation
import JellyfinKit

/// The outcome of checking a supporter key.
public enum SupporterKeyResult: Sendable, Equatable {
    /// `name` is `nil` when the buyer left it empty. `issuedAt` is the issue day, 00:00 UTC.
    case valid(app: SupporterKey.App, issuedAt: Date, orderID: String, name: String?)
    case invalid(SupporterKey.Failure)

    public var isValid: Bool {
        if case .valid = self { true } else { false }
    }
}

/// **Supporter keys `SS1-…`, verified offline.**
///
/// The website sells a key, signs it with Ed25519 and shows it on the thank-you page and in
/// the email. The app checks the signature against the public key below; there is no
/// account and no network request.
///
/// Byte layout before Base32 (RFC 4648 alphabet, no padding):
///
///     0      version (1)
///     1      flags (bit 0 = test mode)
///     2      app (1 = Swiftly, 2 = Sequence Studio)
///     3..4   issue day, days since 1970-01-01 UTC, big endian
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
    public enum Failure: String, Sendable, Equatable {
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
    }

    // MARK: The public key

    /// **The one public key the apps check against (Ed25519, 32 bytes, Base64).**
    ///
    /// This is still the published TEST key (its private half derives from a seed of 32 bytes
    /// 0x01, so anyone can sign with it). Before direct builds ship, replace it with the public
    /// half of the production signing pair:
    ///
    /// 1. Take the Base64 value the shop's key generator printed for the production pair
    ///    (only the public half; the private half never enters this repository).
    /// 2. Paste it here and run the tests: `usesTestPublicKey` turns false, and the test
    ///    vectors switch to their own explicit test key, so they keep passing.
    /// 3. Never change it again: every key sold so far is signed for this value.
    public static let publicKeyBase64 = testPublicKeyBase64

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

    static let prefix = "SS1-"
    static let signedDomain = Array("SS1".utf8)
    static let headLength = 13
    static let signatureLength = 64
    static let maxNameBytes = 48
    static let maxTextLength = 400

    /// Checks a pasted key.
    ///
    /// - Parameters:
    ///   - app: the only app a key may be for; Swiftly unless a test says otherwise.
    ///   - allowTestKeys: keys from the shop's test mode. Release builds leave this false.
    public static func verify(_ text: String,
                              publicKey: [UInt8] = SupporterKey.publicKey,
                              app expectedApp: App = .swiftly,
                              allowTestKeys: Bool = false) -> SupporterKeyResult {
        guard publicKey.count == 32 else { return .invalid(.badPublicKey) }
        // Exactly the characters PHP's trim() removes, so app and shop accept the same input.
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r\0\u{0B}"))
        guard !trimmed.isEmpty else { return .invalid(.empty) }
        guard trimmed.utf8.count <= maxTextLength else { return .invalid(.tooLong) }
        guard trimmed.utf8.prefix(4).map(asciiUppercased) == Array(prefix.utf8) else {
            return .invalid(.wrongPrefix)
        }
        guard let raw = base32Decode(Array(trimmed.utf8.dropFirst(4))) else { return .invalid(.badEncoding) }
        guard raw.count >= headLength + signatureLength else { return .invalid(.tooShort) }

        let payload = Array(raw[..<(raw.count - signatureLength)])
        let signature = Array(raw[(raw.count - signatureLength)...])
        guard Ed25519.verify(signature: signature, message: signedDomain + payload, publicKey: publicKey) else {
            return .invalid(.badSignature)
        }

        guard payload[0] == 1 else { return .invalid(.unsupportedVersion) }
        guard let app = App(rawValue: payload[2]) else { return .invalid(.unknownApp) }
        guard app == expectedApp else { return .invalid(.wrongApp) }
        if payload[1] & 1 != 0 && !allowTestKeys { return .invalid(.testKey) }

        let nameBytes = payload[headLength...]
        // Decoding repairs broken UTF-8; if the bytes changed, they were not valid UTF-8.
        let name = String(decoding: nameBytes, as: UTF8.self)
        guard nameBytes.count <= maxNameBytes, Array(name.utf8) == Array(nameBytes) else {
            return .invalid(.badName)
        }

        let day = Int(payload[3]) << 8 | Int(payload[4])
        let order = payload[5..<13].map { byte in
            let hex = String(byte, radix: 16)
            return byte < 16 ? "0" + hex : hex
        }.joined()
        return .valid(app: app, issuedAt: Date(timeIntervalSince1970: TimeInterval(day) * 86_400),
                      orderID: order, name: name.isEmpty ? nil : name)
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
