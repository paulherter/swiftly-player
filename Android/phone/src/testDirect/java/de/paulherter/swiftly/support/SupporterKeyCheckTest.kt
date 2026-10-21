package de.paulherter.swiftly.support

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The key check of the direct build against the package's own vectors
 * (`Packages/JellyfinKit/Tests/SupportKeyKitTests/SupporterKeyTests.swift`), and against the Swift
 * source for everything that must not drift: public key, website, contact.
 */
class SupporterKeyCheckTest {
    private val testKey = SupporterKeyCheck.decodePublicKey(SupporterKeyCheck.TEST_PUBLIC_KEY_BASE64)!!
    private val issued = 1_792_281_600_000L // 2026-10-18 UTC

    /**
     * The vectors are read from the Swift test file itself, not copied: a hand copy of a 200-character
     * key is how a test ends up checking a key nobody issued.
     */
    private val vectors: Map<String, String> = Regex("""static let (\w+) = "(SS1-[A-Z2-7]+)"""")
        .findAll(File("../../Packages/JellyfinKit/Tests/SupportKeyKitTests/SupporterKeyTests.swift").readText())
        .associate { it.groupValues[1] to it.groupValues[2] }
    private val vectorSequenceStudio get() = vectors.getValue("vectorSequenceStudio")
    private val vectorTestNoName get() = vectors.getValue("vectorTestNoName")
    private val swiftlyNamed get() = vectors.getValue("swiftlyNamed")
    private val swiftlyNoName get() = vectors.getValue("swiftlyNoName")
    private val swiftlyTest get() = vectors.getValue("swiftlyTest")
    private val swiftlyDayZero get() = vectors.getValue("swiftlyDayZero")
    private val swiftlyLongName get() = vectors.getValue("swiftlyLongName")
    private val sequenceStudio get() = vectors.getValue("sequenceStudio")
    private val version2 get() = vectors.getValue("version2")
    private val unknownApp get() = vectors.getValue("unknownApp")
    private val badUTF8Name get() = vectors.getValue("badUTF8Name")
    private val nameTooLong get() = vectors.getValue("nameTooLong")
    private val headOnly get() = vectors.getValue("headOnly")

    private fun check(text: String, app: Int = 1, allowTest: Boolean = false) =
        SupporterKeyCheck.verify(text, testKey, app, allowTest)
    private fun valid(app: Int, at: Long, order: String, name: String?) = SupporterKeyCheck.Result.Valid(app, at, order, name)
    private fun invalid(f: String) = SupporterKeyCheck.Result.Invalid(f)
    private fun isValid(r: SupporterKeyCheck.Result) = r is SupporterKeyCheck.Result.Valid

    @Test fun validNamed() = assertEquals(valid(1, issued, "0123456789abcdef", "Zoë M."), check(swiftlyNamed))
    @Test fun validWithoutName() = assertEquals(valid(1, issued, "fedcba9876543210", null), check(swiftlyNoName))
    @Test fun dayZero() = assertEquals(valid(1, 0, "ffffffffffffffff", null), check(swiftlyDayZero))
    @Test fun longestName() = assertEquals(valid(1, issued, "0123456789abcdef", "é".repeat(24)), check(swiftlyLongName))

    @Test fun shopVector() {
        assertEquals(invalid("wrongApp"), check(vectorSequenceStudio))
        assertEquals(valid(2, issued, "0123456789abcdef", "Zoë M."), check(vectorSequenceStudio, app = 2))
        assertEquals(invalid("wrongApp"), check(sequenceStudio))
    }

    @Test fun testKeys() {
        assertEquals(invalid("testKey"), check(swiftlyTest))
        assertEquals(invalid("testKey"), check(vectorTestNoName))
        assertEquals(valid(1, issued, "00000000000000ff", null), check(swiftlyTest, allowTest = true))
    }

    @Test fun signedButMalformed() {
        assertEquals(invalid("unsupportedVersion"), check(version2))
        assertEquals(invalid("unknownApp"), check(unknownApp))
        assertEquals(invalid("badName"), check(badUTF8Name))
        assertEquals(invalid("badName"), check(nameTooLong))
        assertEquals(invalid("tooShort"), check(headOnly))
    }

    @Test fun forgivingPaste() {
        val groups = swiftlyNamed.drop(4).chunked(5)
        val expected = check(swiftlyNamed)
        assertTrue(isValid(expected))
        assertEquals(expected, check("  ss1-" + groups.joinToString("-").lowercase() + "\n"))
        assertEquals(expected, check("\tSS1-" + groups.joinToString(" ") + "  "))
        assertEquals(expected, check("Ss1-" + groups.joinToString("\n")))
        assertEquals(expected, check(swiftlyNamed.lowercase()))
        assertEquals(expected, check(swiftlyNamed + "\u0000"))
        assertFalse(isValid(check(swiftlyNamed + " ")))
    }

    @Test fun tampered() {
        val chars = swiftlyNamed.toCharArray()
        for (i in 4 until chars.size - 1 step 23) {
            val c = chars.copyOf()
            c[i] = if (c[i] == 'A') 'B' else 'A'
            assertFalse("position $i", isValid(check(String(c))))
        }
    }

    @Test fun truncatedAndForeign() {
        val key = swiftlyNamed
        assertFalse(isValid(check(key.dropLast(1))))
        assertFalse(isValid(check(key.dropLast(8))))
        assertFalse(isValid(check(key.take(40))))
        assertFalse(isValid(check(key + "A")))
        assertFalse(isValid(check(key + "AAAAAAAA")))
        assertEquals(invalid("empty"), check(""))
        assertEquals(invalid("empty"), check("   \n "))
        assertEquals(invalid("tooShort"), check("SS1-"))
        assertEquals(invalid("tooShort"), check("SS1-AAAA"))
        assertFalse(isValid(check("SS2-" + key.drop(4))))
        assertEquals(invalid("wrongPrefix"), check("SS1" + key.drop(4)))
        assertEquals(invalid("badEncoding"), check("SS1-" + key.drop(4) + "0"))
        assertEquals(invalid("badEncoding"), check("SS1-" + key.drop(4) + "!"))
        assertEquals(invalid("tooLong"), check("SS1-" + "A".repeat(500)))
        assertEquals(invalid("wrongPrefix"), check("ſs1-" + key.drop(4)))
        assertEquals(invalid("badEncoding"), check("SS1-" + key.drop(4).replace("A", "Ａ")))
    }

    // MARK: SS2 (vectors from SupporterKeyV2Tests.swift)

    private val v2: Map<String, String> = Regex("""static let (\w+) = "(SS2-[A-Z2-7]+)"""")
        .findAll(File("../../Packages/JellyfinKit/Tests/SupportKeyKitTests/SupporterKeyV2Tests.swift").readText())
        .associate { it.groupValues[1] to it.groupValues[2] }
    private val purchased = 1_792_281_600_000L   // 2026-10-18
    private val expires = 1_794_960_000_000L     // 2026-11-18
    private val expiresLater = 1_797_638_400_000L // 2026-12-18

    private fun read(text: String, allowTest: Boolean = false) = SupporterKeyCheck.read(text, testKey, 1, allowTest)
    private fun license(text: String, allowTest: Boolean = false) = (read(text, allowTest) as SupporterKeyCheck.Read.Ok).license

    @Test fun monthlyKeyReadsPlanExpiryAndId() {
        assertEquals(SupporterKeyCheck.License(1, "monthly", purchased, expires, "00112233445566778899aabbccddeeff", "Zoë M.",
                                               isTest = false, isLegacy = false), license(v2.getValue("monthly")))
        val l = license(v2.getValue("monthly"))
        assertTrue(l.isActive(expires - 1)); assertFalse(l.isActive(expires))
    }

    @Test fun verifyRefusesMonthlyFromItsExpiryDay() {
        val key = v2.getValue("monthly")
        val ok = SupporterKeyCheck.verify(key, testKey, 1, false, expires - 60_000)
        assertEquals(SupporterKeyCheck.Result.Valid(1, purchased, "00112233445566778899aabbccddeeff", "Zoë M.", "monthly", expires), ok)
        assertEquals(invalid("expired"), SupporterKeyCheck.verify(key, testKey, 1, false, expires))
    }

    @Test fun lifetimeNeverExpiresAndTestOrForeignAreRefused() {
        val l = license(v2.getValue("lifetime"))
        assertTrue(l.plan == "lifetime" && l.expiresAtMs == null && l.name == null && l.id == "ffeeddccbbaa99887766554433221100")
        assertTrue(isValid(SupporterKeyCheck.verify(v2.getValue("lifetime"), testKey, 1, false, Long.MAX_VALUE / 2)))
        assertEquals(SupporterKeyCheck.Read.Failed("testKey"), read(v2.getValue("lifetimeTest")))
        assertTrue(license(v2.getValue("lifetimeTest"), allowTest = true).isTest)
        assertEquals(SupporterKeyCheck.Read.Failed("wrongApp"), read(v2.getValue("otherApp")))
    }

    @Test fun ss1CountsAsLifetime() {
        val l = license(swiftlyNamed)
        assertTrue(l.isLegacy && l.plan == "lifetime" && l.expiresAtMs == null && l.id == "0123456789abcdef")
    }

    @Test fun ss2Tampering() {
        val chars = v2.getValue("monthly").toCharArray()
        for (i in 4 until chars.size - 1 step 17) {
            val c = chars.copyOf(); c[i] = if (c[i] == 'A') 'B' else 'A'
            assertFalse("position $i", isValid(SupporterKeyCheck.verify(String(c), testKey, 1, false, purchased)))
        }
        assertTrue(read("SS1-" + v2.getValue("monthly").drop(4)) != read(v2.getValue("monthly")))
        assertFalse(isValid(SupporterKeyCheck.verify(v2.getValue("monthly"), nowMs = purchased)))  // production key
        assertEquals("ffeeddccbbaa99887766554433221100", license("  " + v2.getValue("lifetime").lowercase() + "\n").id)
    }

    @Test fun wrongPublicKey() {
        assertFalse(isValid(SupporterKeyCheck.verify(swiftlyNamed, ByteArray(32) { 7 })))
        assertEquals(invalid("badPublicKey"), SupporterKeyCheck.verify(swiftlyNamed, ByteArray(0)))
        assertNull(SupporterKeyCheck.decodePublicKey("broken"))
        assertNull(SupporterKeyCheck.decodePublicKey(java.util.Base64.getEncoder().encodeToString(ByteArray(31))))
    }

    @Test fun base32Canonical() {
        assertTrue(SupporterKeyCheck.base32Decode("MY".toByteArray())!!.contentEquals(byteArrayOf(0x66)))
        assertNull(SupporterKeyCheck.base32Decode("MZ".toByteArray()))
        assertNull(SupporterKeyCheck.base32Decode("M".toByteArray()))
        assertTrue(SupporterKeyCheck.base32Decode("my-".toByteArray())!!.contentEquals(byteArrayOf(0x66)))
    }

    // MARK: Same values as the package

    private val kit = File("../../Packages/JellyfinKit/Sources/SupportKeyKit")

    private fun swiftString(file: String, name: String): String {
        val text = File(kit, file).readText()
        val m = Regex("""static let $name\s*=\s*(?:"([^"]*)"|(\w+))""").find(text) ?: error("$name not in $file")
        return m.groupValues[1].ifEmpty { swiftString(file, m.groupValues[2]) }
    }

    @Test fun publicKeyMatchesThePackage() {
        assertEquals(swiftString("SupporterKey.swift", "testPublicKeyBase64"), SupporterKeyCheck.TEST_PUBLIC_KEY_BASE64)
        assertEquals(swiftString("SupporterKey.swift", "publicKeyBase64"), SupporterKeyCheck.PUBLIC_KEY_BASE64)
        assertEquals(32, SupporterKeyCheck.publicKey.size)
    }

    @Test fun addressesMatchThePackage() {
        assertEquals(swiftString("DirectSupportCopy.swift", "websiteURL"), FlavorSupport.WEBSITE.removeSuffix("/"))
        assertEquals(swiftString("DirectSupportCopy.swift", "contactEmail"), FlavorSupport.CONTACT)
    }
}
