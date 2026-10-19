import Foundation
import Testing
@testable import SupportKeyKit
#if canImport(CryptoKit)
import CryptoKit
#endif

func hex(_ s: String) -> [UInt8] {
    var out = [UInt8]()
    var chars = Array(s.utf8).makeIterator()
    while let a = chars.next(), let b = chars.next() {
        out.append(UInt8(String(decoding: [a, b], as: UTF8.self), radix: 16)!)
    }
    return out
}

func hexString(_ bytes: [UInt8]) -> String {
    bytes.map { $0 < 16 ? "0" + String($0, radix: 16) : String($0, radix: 16) }.joined()
}

@Suite("SHA-512")
struct SHA512Tests {
    @Test("abc and the empty message match FIPS 180-4")
    func knownAnswers() {
        #expect(hexString(SHA512.hash(Array("abc".utf8))) ==
            "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
        #expect(hexString(SHA512.hash([])) ==
            "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e")
    }

    @Test("Lengths around the padding and block edges", arguments: [
        (111, "fa9121c7b32b9e01733d034cfc78cbf67f926c7ed83e82200ef86818196921760b4beff48404df811b953828274461673c68d04e297b0eb7b2b4d60fc6b566a2"),
        (112, "c01d080efd492776a1c43bd23dd99d0a2e626d481e16782e75d54c2503b5dc32bd05f0f1ba33e568b88fd2d970929b719ecbb152f58f130a407c8830604b70ca"),
        (127, "828613968b501dc00a97e08c73b118aa8876c26b8aac93df128502ab360f91bab50a51e088769a5c1eff4782ace147dce3642554199876374291f5d921629502"),
        (128, "b73d1929aa615934e61a871596b3f3b33359f42b8175602e89f7e06e5f658a243667807ed300314b95cacdd579f3e33abdfbe351909519a846d465c59582f321"),
        (239, "52c853cb8d907f3d4d6b889beb027985d7c273486d75f8baf26f80d24e90c74c6c3de3e22131582380a7d14d43f2941a31385439cd6ddc469f628015e50bf286"),
        (1000, "67ba5535a46e3f86dbfbed8cbbaf0125c76ed549ff8b0b9e03e0c88cf90fa634fa7b12b47d77b694de488ace8d9a65967dc96df599727d3292a8d9d447709c97"),
    ])
    func blockEdges(length: Int, digest: String) {
        #expect(hexString(SHA512.hash([UInt8](repeating: UInt8(ascii: "a"), count: length))) == digest)
    }
}

// Serialized: verification is CPU-heavy in debug builds, and running every case at once
// starves timing-sensitive tests elsewhere in the package of the cooperative thread pool.
@Suite("Ed25519", .serialized)
struct Ed25519Tests {
    struct Vector: Sendable {
        let publicKey: String
        let message: String
        let signature: String
    }

    /// RFC 8032 section 7.1, tests 1 and 2, plus three signatures made with libsodium.
    static let vectors: [Vector] = [
        Vector(publicKey: "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", message: "",
               signature: "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"),
        Vector(publicKey: "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c", message: "72",
               signature: "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"),
        Vector(publicKey: "8f80338eef733ec67c601349c4a8251393b28deb722cfd0a91907744a26d3dab", message: "",
               signature: "dad88d9f735434282a6cc50924f71eb03f10acd0f4ea598f0c7f0842c74327ed62c52f2408c0ce65212c7153739ba3957eefbd11f63cc2968c04700bdb33370c"),
        Vector(publicKey: "cc1983469486418cd66dcdc8664677c263487b736840cfd1532e144386fa7610",
               message: String(repeating: "42", count: 37),
               signature: "070689e5006e53fa680ba222ae232579acfc8de3bae14c2ef6d81018d6c8cc760ee26819e17baabe073bfc8d21d17e7cce4a43d5fa429e24a53838971a70f203"),
        Vector(publicKey: "88166617f91bc145b243c2ae6e1088f1208bf17311cca74dbf032fee25b219e0",
               message: String(repeating: "43", count: 74),
               signature: "77b2ef3751db987a5b746a79654d5eecf03c544f32ac75b8a9c898d8aed1eec6d33a33d544272c877a65872f2dede7511bb6916a4726e1749b0cd488c3e00f00"),
    ]

    @Test("Derived constants: base point encoding and sqrt(-1)")
    func constants() {
        #expect(hexString(Point.base.encoded()) == "58" + String(repeating: "66", count: 31))
        let minusOne = FieldElement.normalized(-FieldElement.one)
        #expect((FieldElement.sqrtMinusOne * FieldElement.sqrtMinusOne).sameValue(as: minusOne))
        // d y^2 x^2 + 1 = y^2 - x^2 holds for the base point.
        let b = Point.base
        let x2 = b.x.squared, y2 = b.y.squared
        #expect((FieldElement.d * x2 * y2 + FieldElement.one).sameValue(as: y2 - x2))
    }

    @Test("Scalar reduction: L reduces to zero, L + 1 to one")
    func scalarReduction() {
        var l = Scalar.order.map { UInt8($0) } + [UInt8](repeating: 0, count: 32)
        #expect(Scalar.reduce(l) == [UInt8](repeating: 0, count: 32))
        l[0] += 1
        #expect(Scalar.reduce(l) == [1] + [UInt8](repeating: 0, count: 31))
    }

    @Test("Known signatures verify", arguments: vectors)
    func knownSignatures(_ v: Vector) {
        #expect(Ed25519.verify(signature: hex(v.signature), message: hex(v.message), publicKey: hex(v.publicKey)))
    }

    @Test("Any flipped bit in signature, message or key fails", arguments: vectors)
    func flippedBits(_ v: Vector) {
        let sig = hex(v.signature), msg = hex(v.message), key = hex(v.publicKey)
        for i in stride(from: 3, to: 512, by: 41) {
            var s = sig
            s[i / 8] ^= 1 << UInt8(i % 8)
            #expect(!Ed25519.verify(signature: s, message: msg, publicKey: key))
        }
        for i in stride(from: 1, to: 256, by: 29) {
            var k = key
            k[i / 8] ^= 1 << UInt8(i % 8)
            #expect(!Ed25519.verify(signature: sig, message: msg, publicKey: k))
        }
        #expect(!Ed25519.verify(signature: sig, message: msg + [0], publicKey: key))
        if !msg.isEmpty {
            var m = msg
            m[0] ^= 0x01
            #expect(!Ed25519.verify(signature: sig, message: m, publicKey: key))
        }
    }

    @Test("S + L (the malleable twin) is refused")
    func nonCanonicalS() {
        let v = Self.vectors[0]
        var sig = hex(v.signature)
        var carry = 0
        for i in 0..<32 {
            let sum = Int(sig[32 + i]) + Int(Scalar.order[i]) + carry
            sig[32 + i] = UInt8(sum & 0xff)
            carry = sum >> 8
        }
        #expect(!Ed25519.verify(signature: sig, message: hex(v.message), publicKey: hex(v.publicKey)))
    }

    @Test("Wrong lengths and a key off the curve fail")
    func malformed() {
        let v = Self.vectors[0]
        #expect(!Ed25519.verify(signature: Array(hex(v.signature).dropLast()), message: [], publicKey: hex(v.publicKey)))
        #expect(!Ed25519.verify(signature: hex(v.signature), message: [], publicKey: Array(hex(v.publicKey).dropLast())))
        // y = 2 is not on the curve.
        let offCurve = [2] + [UInt8](repeating: 0, count: 31)
        #expect(Point.decodeNegated(offCurve) == nil)
        #expect(!Ed25519.verify(signature: hex(v.signature), message: [], publicKey: offCurve))
    }

    #if canImport(CryptoKit)
    @Test("Agrees with CryptoKit on random keys and messages")
    func crossCheckWithCryptoKit() throws {
        var generator = SystemRandomNumberGenerator()
        for round in 0..<12 {
            let key = Curve25519.Signing.PrivateKey()
            let message = (0..<(round * 29 % 300)).map { _ in UInt8.random(in: 0...255, using: &generator) }
            let signature = [UInt8](try key.signature(for: message))
            let publicKey = [UInt8](key.publicKey.rawRepresentation)
            #expect(Ed25519.verify(signature: signature, message: message, publicKey: publicKey))
            var bad = signature
            bad[round % 64] ^= 0x10
            #expect(!Ed25519.verify(signature: bad, message: message, publicKey: publicKey))
        }
    }
    #endif
}
