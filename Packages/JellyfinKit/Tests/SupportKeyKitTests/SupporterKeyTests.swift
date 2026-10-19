import Foundation
import Testing
import JellyfinKit
@testable import SupportKeyKit

/// Keys issued by the shop's own code (`SupporterKey::issue`) with its published test pair
/// (seed 32 × 0x01). Payloads the shop refuses to issue were signed by hand with the same pair.
// Serialized for the same reason as the Ed25519 suite.
@Suite("Supporter key", .serialized)
struct SupporterKeyTests {
    static let testKey = SupporterKey.decodePublicKey(SupporterKey.testPublicKeyBase64)!
    static let issued = Date(timeIntervalSince1970: 1_792_281_600) // 2026-10-18 UTC

    // From the shop's test vector file (swift/Tests/SupporterKeyTests/vector.json).
    static let vectorSequenceStudio = "SS1-AEAAEUIIAERUKZ4JVPG66WTPYOVSATJOII2WK2NMFNM37V6KE4X4YMOOISMZS6NKFSRIJOM6SYNN34YKVYCUQA4GWIHGKYC4YE7ZPGJT2QTAWYGPZTBZFW2X5537IMULGSYGUCQ"
    static let vectorTestNoName = "SS1-AEAQCUII73OLVGDWKQZBBJP7SXWSHCM5FD24Z52JS344LP2I7IDQ4BSWAUFQ5I5H37GMARLXTSJWOTHCWQ2MXYWXVVRELN7J2GVKWHFIR77CCPNHJTX2AELO3ECA"

    static let swiftlyNamed = "SS1-AEAACUIIAERUKZ4JVPG66WTPYOVSATJOHT74FE6ZQWPVOTNBNRAGYEYWF3FYDXEAILFQHKMFHXC4FJM6UR7GZE7RD5EXKJAWARVEV3WB7NO3QHNLW3RMZ6WG6FPGJE3G2D7CUDY"
    static let swiftlyNoName = "SS1-AEAACUII73OLVGDWKQZBADOQ45NZ2ZMFV5WXBR2ATF4RDQZ76ELHWKSRRBY27BTOXLHVLCVWCEUNKLWGMBXXY4FMHYY5EHMZZPGOAQ5PWEZNVV674XKP26UWMAGQ"
    static let swiftlyTest = "SS1-AEAQCUIIAAAAAAAAAAAP7PN7NFXJNTY6XH2E7HVUU7XJEG3RRKDN6LNYO64UY4XCPN5TDQCZUTACXRCVL6CFN4DCU3FRANOK6F2CGOOZKNLW6JCPTNHDG5EHX4DQ"
    static let swiftlyDayZero = "SS1-AEAACAAA7777777777776MIT5BJNB5POZ5EHNXMZ3LAXULVFU2OKWPOKCBAUKF4GIWONQ5GOEJ2SFUI6IEQ3U2LMWO2RF2XFIQYTNYZM5RVIMU62XHOAED44GAFQ"
    static let swiftlyLongName = "SS1-AEAACUIIAERUKZ4JVPG67Q5JYOU4HKODVHB2TQ5JYOU4HKODVHB2TQ5JYOU4HKODVHB2TQ5JYOU4HKODVHB2TQ5JYOU4HKODVFNMZCVNJTHY4HCU7GNHM7MRTRERWWGMPPLUCXFCC6KU77GGOPQ3RJZ5RGVQDBV3MFDGBT64VS5Z64BQDFAQP24NABENTXPFLWWK2MIB"
    static let sequenceStudio = "SS1-AEAAEUIIAERUKZ4JVPG66QLON36ICZIEVBI2ZSG3TWDIGAM3F674LN32XVPLS4MRXKV5UXT6D2Q2FECX4HSYBYPA6P6V6RXTUK2H4JYVQ3URDQU7YFJ5GOLO5HYDHVAI"
    static let version2 = "SS1-AIAACUIIAERUKZ4JVPG67CYL7MW6SX7VV6TRTBETNXVADAWF44UDCB52ZBBGLCAIJ76Q6XI56RNDJSO5PZEIFTZUQGQFRIL4QGPKITIXSDZGCIH6SGFMMPNNEQDQ"
    static let unknownApp = "SS1-AEAASUIIAERUKZ4JVPG674UWNT3YOQTW4JWS7CFGIL5UMGAGXZ4PLARVXFTMTKDOZ3O4ST22H723L6PFH2WSZF6GNSXQV4GUO2P362YPUUAHAJ46E4CSJBYRNQAA"
    static let badUTF8Name = "SS1-AEAACUIIAERUKZ4JVPG67776AXSI4PE6Z6WO3I3QY2SGEU5JFHEB7X47MFJI3KIDULB6D426IGCN4ZJUM5Q43COCK2K2TIXG33U4H6GCV4TC5KAXDAMISBEE34GZSDI"
    static let nameTooLong = "SS1-AEAACUIIAERUKZ4JVPG666DYPB4HQ6DYPB4HQ6DYPB4HQ6DYPB4HQ6DYPB4HQ6DYPB4HQ6DYPB4HQ6DYPB4HQ6DYPB4HQ6DYPB4MQRXNEZYOIMXNBQFAXSZTTAVP2KHMJP3KENMS6QQUGOBSC6QQPSVJ6METPVH6GWQMDK7SLT2B7RZLSZTKCSCMRFXF3KLQ6D5MDXCRBY"
    static let headOnly = "SS1-AEAACUIIAERUKZ4JVPGTSS75FL3JWBFD2SXL7K3BU22X63RFUV7U55FYGQFFRG6GIPKX6KKFYJOVZHP6YFOL3HNGCKTSORJ7CQX6NXXRGN2S2BB3BVJUZS4LBM"

    func check(_ text: String, app: SupporterKey.App = .swiftly, allowTest: Bool = false) -> SupporterKeyResult {
        SupporterKey.verify(text, publicKey: Self.testKey, app: app, allowTestKeys: allowTest)
    }

    @Test("A Swiftly key with a name")
    func validNamed() {
        #expect(check(Self.swiftlyNamed) ==
            .valid(app: .swiftly, issuedAt: Self.issued, orderID: "0123456789abcdef", name: "Zoë M."))
    }

    @Test("A Swiftly key without a name reads name as nil")
    func validWithoutName() {
        #expect(check(Self.swiftlyNoName) ==
            .valid(app: .swiftly, issuedAt: Self.issued, orderID: "fedcba9876543210", name: nil))
    }

    @Test("Day zero and an all-ones order ID")
    func dayZero() {
        #expect(check(Self.swiftlyDayZero) ==
            .valid(app: .swiftly, issuedAt: Date(timeIntervalSince1970: 0), orderID: "ffffffffffffffff", name: nil))
    }

    @Test("A 48-byte name is the limit and still valid")
    func longestName() {
        #expect(check(Self.swiftlyLongName) ==
            .valid(app: .swiftly, issuedAt: Self.issued, orderID: "0123456789abcdef",
                   name: String(repeating: "é", count: 24)))
    }

    @Test("The shop's own vector: valid for Sequence Studio, refused for Swiftly")
    func shopVector() {
        #expect(check(Self.vectorSequenceStudio) == .invalid(.wrongApp))
        #expect(check(Self.vectorSequenceStudio, app: .sequenceStudio) ==
            .valid(app: .sequenceStudio, issuedAt: Self.issued, orderID: "0123456789abcdef", name: "Zoë M."))
        #expect(check(Self.sequenceStudio) == .invalid(.wrongApp))
    }

    @Test("Test-mode keys only when allowed")
    func testKeys() {
        #expect(check(Self.swiftlyTest) == .invalid(.testKey))
        #expect(check(Self.vectorTestNoName) == .invalid(.testKey))
        #expect(check(Self.swiftlyTest, allowTest: true) ==
            .valid(app: .swiftly, issuedAt: Self.issued, orderID: "00000000000000ff", name: nil))
    }

    @Test("Correctly signed but malformed payloads are refused")
    func signedButMalformed() {
        #expect(check(Self.version2) == .invalid(.unsupportedVersion))
        #expect(check(Self.unknownApp) == .invalid(.unknownApp))
        #expect(check(Self.badUTF8Name) == .invalid(.badName))
        #expect(check(Self.nameTooLong) == .invalid(.badName))
        #expect(check(Self.headOnly) == .invalid(.tooShort))
    }

    @Test("Pasting: lowercase, spaces, dashes, line breaks, surrounding whitespace")
    func forgivingPaste() {
        let body = Self.swiftlyNamed.dropFirst(4)
        var groups = [String]()
        var rest = Substring(body)
        while !rest.isEmpty {
            groups.append(String(rest.prefix(5)))
            rest = rest.dropFirst(5)
        }
        let expected = check(Self.swiftlyNamed)
        #expect(expected.isValid)
        #expect(check("  ss1-" + groups.joined(separator: "-").lowercased() + "\n") == expected)
        #expect(check("\tSS1-" + groups.joined(separator: " ") + "  ") == expected)
        #expect(check("Ss1-" + groups.joined(separator: "\n")) == expected)
        #expect(check(Self.swiftlyNamed.lowercased()) == expected)
        #expect(check(Self.swiftlyNamed + "\0") == expected)
        // Unicode spaces are not trimmed by the shop either.
        #expect(!check(Self.swiftlyNamed + "\u{00A0}").isValid)
    }

    @Test("Tampered keys fail the signature")
    func tampered() {
        let chars = Array(Self.swiftlyNamed)
        for i in stride(from: 4, to: chars.count - 1, by: 23) {
            var c = chars
            c[i] = c[i] == "A" ? "B" : "A"
            let result = check(String(c))
            #expect(!result.isValid, "position \(i)")
        }
    }

    @Test("Truncated, extended and foreign input")
    func truncatedAndForeign() {
        let key = Self.swiftlyNamed
        #expect(check(String(key.dropLast())) == .invalid(.badEncoding) || check(String(key.dropLast())) == .invalid(.badSignature))
        #expect(!check(String(key.dropLast(8))).isValid)
        #expect(!check(String(key.prefix(40))).isValid)
        #expect(!check(key + "A").isValid)
        #expect(!check(key + "AAAAAAAA").isValid)
        #expect(check("") == .invalid(.empty))
        #expect(check("   \n ") == .invalid(.empty))
        #expect(check("SS1-") == .invalid(.tooShort))
        #expect(check("SS1-AAAA") == .invalid(.tooShort))
        #expect(check("SS2-" + key.dropFirst(4)) == .invalid(.wrongPrefix))
        #expect(check("SS1" + key.dropFirst(4)) == .invalid(.wrongPrefix))
        #expect(check("SS1-" + key.dropFirst(4) + "0") == .invalid(.badEncoding))
        #expect(check("SS1-" + key.dropFirst(4) + "!") == .invalid(.badEncoding))
        #expect(check("SS1-" + String(repeating: "A", count: 500)) == .invalid(.tooLong))
        // Non-ASCII letters that Unicode would uppercase to ASCII do not count, as in the shop.
        #expect(check("ſs1-" + key.dropFirst(4)) == .invalid(.wrongPrefix))
        #expect(check("SS1-" + key.dropFirst(4).replacingOccurrences(of: "A", with: "Ａ")) == .invalid(.badEncoding))
    }

    @Test("A different public key refuses every key")
    func wrongPublicKey() {
        let other = [UInt8](repeating: 7, count: 32)
        #expect(!SupporterKey.verify(Self.swiftlyNamed, publicKey: other).isValid)
        #expect(SupporterKey.verify(Self.swiftlyNamed, publicKey: []) == .invalid(.badPublicKey))
        #expect(SupporterKey.decodePublicKey("broken") == nil)
        #expect(SupporterKey.decodePublicKey(Data(count: 31).base64EncodedString()) == nil)
    }

    @Test("Base32 refuses non-zero trailing bits, so a key has one spelling")
    func base32Canonical() {
        #expect(SupporterKey.base32Decode(Array("MY".utf8)) == [0x66])
        #expect(SupporterKey.base32Decode(Array("MZ".utf8)) == nil)
        #expect(SupporterKey.base32Decode(Array("M".utf8)) == nil)
        #expect(SupporterKey.base32Decode(Array("my-".utf8)) == [0x66])
    }

    @Test("A valid key grants the key status from its issue day")
    func statusFromKey() {
        #expect(SupporterKey.status(for: check(Self.swiftlyNamed)) == .supporter(source: .key, since: Self.issued))
        #expect(SupporterKey.status(for: check(Self.swiftlyTest)) == .none)
    }

    @Test("The shipped public key decodes; the test key is flagged as such")
    func shippedKey() {
        #expect(SupporterKey.publicKey.count == 32)
        #expect(SupporterKey.usesTestPublicKey == (SupporterKey.publicKeyBase64 == SupporterKey.testPublicKeyBase64))
    }

    @Test("Direct-only texts: unique keys, not in the shared list, no exclamation marks")
    func directCopy() {
        let keys = SupportCopy.directOnly.map(\.key)
        #expect(Set(keys).count == keys.count)
        #expect(Set(keys).isDisjoint(with: SupportCopy.all.map(\.key)))
        for text in SupportCopy.directOnly {
            #expect(!text.de.contains("!") && !text.en.contains("!"))
        }
        // Store builds must never carry these; the shared list must not either.
        for text in SupportCopy.all {
            #expect(!text.en.contains("swiftlyplayer.com") && !text.en.lowercased().contains("supporter key"))
            #expect(!text.de.contains("swiftlyplayer.com") && !text.de.contains("Schlüssel"))
        }
    }
}
