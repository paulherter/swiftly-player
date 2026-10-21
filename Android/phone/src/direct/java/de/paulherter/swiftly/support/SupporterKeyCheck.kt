package de.paulherter.swiftly.support

import java.math.BigInteger
import java.security.MessageDigest

/**
 * **Supporter keys `SS2-…` (and the older `SS1-…`), checked offline.** Only in the direct build.
 *
 * The same rules as `SupporterKey.read` / `verify` in `Packages/JellyfinKit/Sources/SupportKeyKit`,
 * and the same tests (its vectors, `SupporterKeyCheckTest`). Why Kotlin and not the Swift core: the
 * core is one binary for both flavors, and the Play build must not contain the key check at all.
 * The test compares the public key and the rules against the Swift source, so the two cannot drift.
 *
 * `SS2` before Base32 (RFC 4648, no padding): version (2), flags (bit 0 test), app (1 Swiftly),
 * plan (1 monthly, 2 lifetime), purchase day (2 bytes, days since 1970, big endian), expiry day
 * (2 bytes, 0 = never; monthly keys only), licence ID (16 random bytes), name (UTF-8, 0 to 48
 * bytes), then 64 bytes Ed25519 signature over "SS2" + everything before it.
 * `SS1` (still accepted, counts as lifetime): version (1), flags, app, issue day (2), order id
 * (8 bytes), name, signature over "SS1" + payload.
 */
object SupporterKeyCheck {
    /** What a key says once its signature is checked (`SupporterLicense`). `plan` is "monthly" or "lifetime". */
    data class License(val app: Int, val plan: String, val issuedAtMs: Long, val expiresAtMs: Long?, val id: String,
                       val name: String?, val isTest: Boolean, val isLegacy: Boolean) {
        fun isActive(nowMs: Long): Boolean = expiresAtMs == null || nowMs < expiresAtMs
    }

    sealed interface Result {
        data class Valid(val app: Int, val issuedAtMs: Long, val orderId: String, val name: String?,
                         val plan: String = "lifetime", val expiresAtMs: Long? = null) : Result
        data class Invalid(val failure: String) : Result
    }

    /** `SupporterKey.publicKeyBase64` in the package (production). The test fails if they differ. */
    const val PUBLIC_KEY_BASE64 = "90hxOk72gFaCS0s3n2OxKoTYBUGvrzw3liCshhfRU2o="
    /** `SupporterKey.testPublicKeyBase64`: only for tests. */
    const val TEST_PUBLIC_KEY_BASE64 = "iojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1w="
    val usesTestPublicKey: Boolean get() = PUBLIC_KEY_BASE64 == TEST_PUBLIC_KEY_BASE64

    const val APP_SWIFTLY = 1
    private const val SIGNATURE = 64
    private const val MAX_NAME = 48
    private const val MAX_TEXT = 400

    fun decodePublicKey(base64: String): ByteArray? =
        runCatching { java.util.Base64.getDecoder().decode(base64) }.getOrNull()?.takeIf { it.size == 32 }

    val publicKey: ByteArray = decodePublicKey(PUBLIC_KEY_BASE64) ?: ByteArray(0)

    /** Checks a pasted key, including the expiry of monthly keys. */
    fun verify(text: String, publicKey: ByteArray = this.publicKey, app: Int = APP_SWIFTLY,
               allowTestKeys: Boolean = false, nowMs: Long = System.currentTimeMillis()): Result {
        val license = when (val r = read(text, publicKey, app, allowTestKeys)) {
            is Read.Failed -> return Result.Invalid(r.failure)
            is Read.Ok -> r.license
        }
        if (!license.isActive(nowMs)) return Result.Invalid("expired")
        return Result.Valid(license.app, license.issuedAtMs, license.id, license.name, license.plan, license.expiresAtMs)
    }

    sealed interface Read {
        data class Ok(val license: License) : Read
        data class Failed(val failure: String) : Read
    }

    /** Signature and layout, but not the expiry: an expired monthly key is still read, so it can be renewed. */
    fun read(text: String, publicKey: ByteArray = this.publicKey, app: Int = APP_SWIFTLY,
             allowTestKeys: Boolean = false): Read {
        fun fail(f: String) = Read.Failed(f)
        if (publicKey.size != 32) return fail("badPublicKey")
        // Exactly what PHP's trim() removes, so app and shop accept the same input.
        val trimmed = text.trim { it == ' ' || it == '\t' || it == '\n' || it == '\r' || it == '\u0000' || it == '\u000B' }
        if (trimmed.isEmpty()) return fail("empty")
        val bytes = trimmed.toByteArray(Charsets.UTF_8)
        if (bytes.size > MAX_TEXT) return fail("tooLong")
        val prefix = if (bytes.size >= 4) String(ByteArray(4) { asciiUpper(bytes[it]) }, Charsets.ISO_8859_1) else ""
        val version = when (prefix) { "SS1-" -> 1; "SS2-" -> 2; else -> return fail("wrongPrefix") }
        val head = if (version == 1) 13 else 24
        val raw = base32Decode(bytes.copyOfRange(4, bytes.size)) ?: return fail("badEncoding")
        if (raw.size < head + SIGNATURE) return fail("tooShort")
        val payload = raw.copyOfRange(0, raw.size - SIGNATURE)
        val signature = raw.copyOfRange(raw.size - SIGNATURE, raw.size)
        val domain = (if (version == 1) "SS1" else "SS2").toByteArray()
        if (!Ed25519.verify(signature, domain + payload, publicKey)) return fail("badSignature")
        if ((payload[0].toInt() and 0xff) != version) return fail("unsupportedVersion")
        val keyApp = payload[2].toInt() and 0xff
        if (keyApp != 1 && keyApp != 2) return fail("unknownApp")
        if (keyApp != app) return fail("wrongApp")
        val isTest = payload[1].toInt() and 1 != 0
        if (isTest && !allowTestKeys) return fail("testKey")
        val nameBytes = payload.copyOfRange(head, payload.size)
        val name = runCatching {
            Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(nameBytes)).toString()
        }.getOrNull()
        if (nameBytes.size > MAX_NAME || name == null) return fail("badName")
        fun day(at: Int) = ((payload[at].toInt() and 0xff) shl 8) or (payload[at + 1].toInt() and 0xff)
        fun hex(range: IntRange) = range.joinToString("") { "%02x".format(payload[it].toInt() and 0xff) }
        if (version == 1) {
            return Read.Ok(License(keyApp, "lifetime", day(3) * 86_400_000L, null, hex(5 until 13), name.ifEmpty { null },
                                   isTest, isLegacy = true))
        }
        val plan = when (payload[3].toInt() and 0xff) { 1 -> "monthly"; 2 -> "lifetime"; else -> return fail("unknownPlan") }
        val expiryDay = day(6)
        // Monthly keys always expire, lifetime keys never; anything else is not a shop key.
        if ((plan == "monthly") != (expiryDay > 0)) return fail("unknownPlan")
        return Read.Ok(License(keyApp, plan, day(4) * 86_400_000L, if (expiryDay > 0) expiryDay * 86_400_000L else null,
                               hex(8 until 24), name.ifEmpty { null }, isTest, isLegacy = false))
    }

    private fun asciiUpper(c: Byte): Byte = if (c in 97..122) (c - 32).toByte() else c

    /** RFC 4648 Base32 without padding; skips dashes and whitespace, refuses non-zero trailing bits. */
    fun base32Decode(text: ByteArray): ByteArray? {
        val out = java.io.ByteArrayOutputStream()
        var buffer = 0
        var bits = 0
        for (b in text) {
            if (b == '-'.code.toByte() || b == ' '.code.toByte() || b == '\n'.code.toByte() ||
                b == '\r'.code.toByte() || b == '\t'.code.toByte()) continue
            val u = asciiUpper(b).toInt()
            val value = when (u) {
                in 'A'.code..'Z'.code -> u - 'A'.code
                in '2'.code..'7'.code -> u - '2'.code + 26
                else -> return null
            }
            buffer = (buffer shl 5) or value
            bits += 5
            if (bits >= 8) {
                bits -= 8
                out.write((buffer shr bits) and 0xff)
            }
            buffer = buffer and ((1 shl bits) - 1)
        }
        if (bits >= 5 || buffer != 0) return null
        return out.toByteArray()
    }
}

/**
 * Ed25519 verification (RFC 8032), the textbook form with `BigInteger`: slow next to TweetNaCl,
 * but a key is checked once, by hand. Verification only; no secret passes through here.
 * Same acceptance as the Swift code: `S` must be canonical, `A` must be on the curve, and
 * `[S]B - [k]A` must encode to exactly `R`.
 */
internal object Ed25519 {
    /** `BigInteger.TWO` exists only from API 33. */
    private val TWO: BigInteger = BigInteger.valueOf(2)
    private val P: BigInteger = TWO.pow(255) - BigInteger.valueOf(19)
    private val L: BigInteger = TWO.pow(252) + BigInteger("27742317777372353535851937790883648493")
    private val D: BigInteger = BigInteger.valueOf(-121665).mod(P) * BigInteger.valueOf(121666).modInverse(P) % P
    private val I: BigInteger = TWO.modPow((P - BigInteger.ONE) / BigInteger.valueOf(4), P)

    private class Point(val x: BigInteger, val y: BigInteger, val z: BigInteger, val t: BigInteger)

    private val identity = Point(BigInteger.ZERO, BigInteger.ONE, BigInteger.ONE, BigInteger.ZERO)
    private val base: Point = run {
        val y = BigInteger.valueOf(4) * BigInteger.valueOf(5).modInverse(P) % P
        val x = recoverX(y, 0)!!
        Point(x, y, BigInteger.ONE, x * y % P)
    }

    private fun add(a: Point, b: Point): Point {
        val aa = (a.y - a.x) * (b.y - b.x) % P
        val bb = (a.y + a.x) * (b.y + b.x) % P
        val c = a.t * TWO * D * b.t % P
        val d = a.z * TWO * b.z % P
        val e = bb - aa; val f = d - c; val g = d + c; val h = bb + aa
        return Point((e * f).mod(P), (g * h).mod(P), (f * g).mod(P), (e * h).mod(P))
    }

    private fun times(s: BigInteger, p: Point): Point {
        var q = identity
        var addend = p
        var k = s
        while (k.signum() > 0) {
            if (k.testBit(0)) q = add(q, addend)
            addend = add(addend, addend)
            k = k.shiftRight(1)
        }
        return q
    }

    private fun recoverX(y: BigInteger, sign: Int): BigInteger? {
        val y2 = y * y % P
        val x2 = (y2 - BigInteger.ONE) * (D * y2 + BigInteger.ONE).modInverse(P) % P
        if (x2.signum() == 0) return if (sign == 0) BigInteger.ZERO else null
        var x = x2.mod(P).modPow((P + BigInteger.valueOf(3)) / BigInteger.valueOf(8), P)
        if ((x * x - x2).mod(P).signum() != 0) x = x * I % P
        if ((x * x - x2).mod(P).signum() != 0) return null
        if (x.testBit(0) != (sign == 1)) x = P - x
        return x
    }

    private fun littleEndian(b: ByteArray): BigInteger = BigInteger(1, b.reversedArray())

    private fun decode(bytes: ByteArray): Point? {
        val sign = (bytes[31].toInt() shr 7) and 1
        val copy = bytes.copyOf(); copy[31] = (copy[31].toInt() and 0x7f).toByte()
        val y = littleEndian(copy).mod(P)
        val x = recoverX(y, sign) ?: return null
        return Point(x, y, BigInteger.ONE, x * y % P)
    }

    private fun encode(p: Point): ByteArray {
        val zi = p.z.modInverse(P)
        val x = p.x * zi % P
        val y = p.y * zi % P
        val out = ByteArray(32)
        val be = y.toByteArray().reversedArray()
        for (i in 0 until minOf(32, be.size)) out[i] = be[i]
        if (x.testBit(0)) out[31] = (out[31].toInt() or 0x80).toByte()
        return out
    }

    fun verify(signature: ByteArray, message: ByteArray, publicKey: ByteArray): Boolean {
        if (signature.size != 64 || publicKey.size != 32) return false
        val r = signature.copyOfRange(0, 32)
        val s = littleEndian(signature.copyOfRange(32, 64))
        if (s >= L) return false
        val a = decode(publicKey) ?: return false
        val digest = MessageDigest.getInstance("SHA-512").digest(r + publicKey + message)
        val k = littleEndian(digest).mod(L)
        val negA = Point((P - a.x).mod(P), a.y, a.z, (P - a.t).mod(P))
        val check = add(times(s, base), times(k, negA))
        return encode(check).contentEquals(r)
    }
}
