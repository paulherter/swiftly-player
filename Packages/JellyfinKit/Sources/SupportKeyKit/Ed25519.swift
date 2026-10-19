// Ed25519 signature verification (RFC 8032), without any dependency, so the same code runs
// on Apple platforms, Linux, Windows and Android.
//
// Verification only: no secret ever passes through here, so constant-time arithmetic is not
// needed. The field and group arithmetic follows TweetNaCl (public domain): field elements
// are 16 signed 64-bit limbs of 16 bits each, points use extended coordinates (X, Y, Z, T)
// with the unified addition formula, which also doubles and handles the identity.
// The curve constants are derived at first use from their definitions instead of being
// copied as magic numbers.

enum Ed25519 {
    /// True when `signature` is a valid signature of `message` under `publicKey`.
    /// Rejects non-canonical `S` (as libsodium does) and public keys that are not on the curve.
    static func verify(signature: [UInt8], message: [UInt8], publicKey: [UInt8]) -> Bool {
        guard signature.count == 64, publicKey.count == 32 else { return false }
        let r = Array(signature[0..<32])
        let s = Array(signature[32..<64])
        guard isCanonicalScalar(s), let negatedA = Point.decodeNegated(publicKey) else { return false }

        let k = Scalar.reduce(SHA512.hash(r + publicKey + message))
        // [S]B - [k]A must equal R.
        let check = Point.sum(negatedA, times: k, Point.base, times: s)
        return check.encoded() == r
    }

    /// S < L, read little-endian.
    static func isCanonicalScalar(_ s: [UInt8]) -> Bool {
        for i in stride(from: 31, through: 0, by: -1) {
            let limb = UInt8(Scalar.order[i])
            if s[i] < limb { return true }
            if s[i] > limb { return false }
        }
        return false // equal to L
    }
}

// MARK: - Field arithmetic modulo p = 2^255 - 19

struct FieldElement: Equatable {
    var limbs: [Int64]

    init(_ limbs: [Int64]) {
        var l = limbs
        l += [Int64](repeating: 0, count: 16 - l.count)
        self.limbs = l
    }

    static let zero = FieldElement([])
    static let one = FieldElement([1])

    init(bytes n: [UInt8]) {
        var o = [Int64](repeating: 0, count: 16)
        for i in 0..<16 { o[i] = Int64(n[2 * i]) + (Int64(n[2 * i + 1]) << 8) }
        o[15] &= 0x7fff
        limbs = o
    }

    private static func carry(_ o: inout [Int64]) {
        for i in 0..<16 {
            o[i] &+= 1 << 16
            let c = o[i] >> 16
            if i < 15 {
                o[i + 1] &+= c &- 1
            } else {
                o[0] &+= 38 &* (c &- 1)
            }
            o[i] &-= c << 16
        }
    }

    /// Canonical little-endian encoding (fully reduced).
    var bytes: [UInt8] {
        var t = limbs
        Self.carry(&t); Self.carry(&t); Self.carry(&t)
        var m = [Int64](repeating: 0, count: 16)
        for _ in 0..<2 {
            m[0] = t[0] &- 0xffed
            for i in 1..<15 {
                m[i] = t[i] &- 0xffff &- ((m[i - 1] >> 16) & 1)
                m[i - 1] &= 0xffff
            }
            m[15] = t[15] &- 0x7fff &- ((m[14] >> 16) & 1)
            let borrow = (m[15] >> 16) & 1
            m[14] &= 0xffff
            if borrow == 0 { t = m } // t >= p: take t - p
        }
        var out = [UInt8](repeating: 0, count: 32)
        for i in 0..<16 {
            out[2 * i] = UInt8(truncatingIfNeeded: t[i])
            out[2 * i + 1] = UInt8(truncatingIfNeeded: t[i] >> 8)
        }
        return out
    }

    /// The low bit of the canonical value ("negative" in RFC 8032 terms).
    var isOdd: Bool { bytes[0] & 1 == 1 }

    static func + (a: FieldElement, b: FieldElement) -> FieldElement {
        var o = a.limbs
        for i in 0..<16 { o[i] &+= b.limbs[i] }
        return FieldElement(o)
    }

    static func - (a: FieldElement, b: FieldElement) -> FieldElement {
        var o = a.limbs
        for i in 0..<16 { o[i] &-= b.limbs[i] }
        return FieldElement(o)
    }

    /// The hot path of verification; raw buffers keep it fast in unoptimized test builds too.
    static func * (a: FieldElement, b: FieldElement) -> FieldElement {
        var t = [Int64](repeating: 0, count: 31)
        a.limbs.withUnsafeBufferPointer { a in
            b.limbs.withUnsafeBufferPointer { b in
                t.withUnsafeMutableBufferPointer { t in
                    for i in 0..<16 {
                        let ai = a[i]
                        for j in 0..<16 { t[i + j] &+= ai &* b[j] }
                    }
                    for i in 0..<15 { t[i] &+= 38 &* t[i + 16] }
                }
            }
        }
        t.removeLast(15)
        carry(&t); carry(&t)
        return FieldElement(limbs: t)
    }

    private init(limbs: [Int64]) {
        self.limbs = limbs
    }

    var squared: FieldElement { self * self }

    static prefix func - (a: FieldElement) -> FieldElement { zero - a }

    /// a^(p-2) = 1/a.
    var inverse: FieldElement {
        var c = self
        for a in stride(from: 253, through: 0, by: -1) {
            c = c.squared
            if a != 2 && a != 4 { c = c * self }
        }
        return c
    }

    /// a^((p-5)/8) = a^(2^252 - 3), the core of the square root.
    var powP58: FieldElement {
        var c = self
        for a in stride(from: 250, through: 0, by: -1) {
            c = c.squared
            if a != 1 { c = c * self }
        }
        return c
    }

    /// Equality of the represented values, not of the limbs.
    func sameValue(as other: FieldElement) -> Bool { bytes == other.bytes }

    // Curve constants, computed from their definitions.

    /// d = -121665 / 121666.
    static let d: FieldElement = normalized(-(FieldElement([121_665]) * FieldElement([121_666]).inverse))
    static let d2: FieldElement = normalized(d + d)

    /// sqrt(-1) = 2^((p-1)/4); (p-1)/4 = 2^253 - 5 has every bit set below 253 except bit 2.
    static let sqrtMinusOne: FieldElement = {
        let two = FieldElement([2])
        var c = one
        for a in stride(from: 252, through: 0, by: -1) {
            c = c.squared
            if a != 2 { c = c * two }
        }
        return normalized(c)
    }()

    static func normalized(_ a: FieldElement) -> FieldElement { FieldElement(bytes: a.bytes) }
}

// MARK: - Points on the twisted Edwards curve

struct Point {
    var x, y, z, t: FieldElement

    static let identity = Point(x: .zero, y: .one, z: .one, t: .zero)

    /// The base point: y = 4/5, x even.
    static let base: Point = {
        let y = FieldElement.normalized(FieldElement([4]) * FieldElement([5]).inverse)
        // decodeNegated returns -B for an encoding with the sign bit clear.
        let negated = decodeNegated(y.bytes)!
        return Point(x: FieldElement.normalized(-negated.x), y: negated.y, z: negated.z,
                     t: FieldElement.normalized(-negated.t))
    }()

    func adding(_ q: Point) -> Point {
        let a = (y - x) * (q.y - q.x)
        let b = (x + y) * (q.x + q.y)
        let c = t * q.t * FieldElement.d2
        let dd = z * q.z
        let d = dd + dd
        let e = b - a, f = d - c, g = d + c, h = b + a
        return Point(x: e * f, y: h * g, z: g * f, t: e * h)
    }

    /// [a]P + [b]Q for 32-byte little-endian scalars, in one pass over the bits
    /// (Straus/Shamir): one doubling per bit and at most one addition.
    static func sum(_ p: Point, times a: [UInt8], _ q: Point, times b: [UInt8]) -> Point {
        let both = p.adding(q)
        var r = Point.identity
        for i in stride(from: 255, through: 0, by: -1) {
            r = r.adding(r)
            let bitA = (a[i / 8] >> UInt8(i & 7)) & 1 == 1
            let bitB = (b[i / 8] >> UInt8(i & 7)) & 1 == 1
            switch (bitA, bitB) {
            case (true, true): r = r.adding(both)
            case (true, false): r = r.adding(p)
            case (false, true): r = r.adding(q)
            case (false, false): break
            }
        }
        return r
    }

    func encoded() -> [UInt8] {
        let zi = z.inverse
        var out = (y * zi).bytes
        if (x * zi).isOdd { out[31] ^= 0x80 }
        return out
    }

    /// Decodes a point and returns its negation (what verification needs); `nil` when the
    /// bytes are not a point on the curve.
    static func decodeNegated(_ p: [UInt8]) -> Point? {
        guard p.count == 32 else { return nil }
        let y = FieldElement(bytes: p)
        let z = FieldElement.one
        let y2 = y.squared
        let u = y2 - z                   // y^2 - 1
        let v = z + y2 * FieldElement.d  // d y^2 + 1

        // x = u v^3 (u v^7)^((p-5)/8)
        let v2 = v.squared
        let v4 = v2.squared
        let v6 = v4 * v2
        var x = (v6 * u * v).powP58 * u * v * v * v

        if !(x.squared * v).sameValue(as: u) { x = x * FieldElement.sqrtMinusOne }
        guard (x.squared * v).sameValue(as: u) else { return nil }

        let signBit = p[31] >> 7
        if x.isOdd == (signBit == 1) { x = -x }
        return Point(x: x, y: y, z: z, t: x * y)
    }
}

// MARK: - Scalars modulo L = 2^252 + 27742317777372353535851937790883648493

enum Scalar {
    static let order: [Int64] = [
        0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10,
    ]

    /// A 64-byte little-endian number reduced modulo L, as 32 bytes.
    static func reduce(_ bytes: [UInt8]) -> [UInt8] {
        var x = bytes.map { Int64($0) }
        for i in stride(from: 63, through: 32, by: -1) {
            var carry: Int64 = 0
            var j = i - 32
            while j < i - 12 {
                x[j] &+= carry &- 16 &* x[i] &* order[j - (i - 32)]
                carry = (x[j] &+ 128) >> 8
                x[j] &-= carry << 8
                j += 1
            }
            x[j] &+= carry
            x[i] = 0
        }
        var carry: Int64 = 0
        for j in 0..<32 {
            x[j] &+= carry &- (x[31] >> 4) &* order[j]
            carry = x[j] >> 8
            x[j] &= 255
        }
        for j in 0..<32 { x[j] &-= carry &* order[j] }
        var out = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 {
            x[i + 1] &+= x[i] >> 8
            out[i] = UInt8(truncatingIfNeeded: x[i] & 255)
        }
        return out
    }
}
