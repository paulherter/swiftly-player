package de.paulherter.swiftly.support

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** The renewal rules of `SupporterKeyKeeper`, the same cases as the package's `SupporterKeyKeeperTests`. */
class SupporterKeyKeeperTest {
    private val testKey = SupporterKeyCheck.decodePublicKey(SupporterKeyCheck.TEST_PUBLIC_KEY_BASE64)!!
    private val v2: Map<String, String> = Regex("""static let (\w+) = "(SS2-[A-Z2-7]+)"""")
        .findAll(File("../../Packages/JellyfinKit/Tests/SupportKeyKitTests/SupporterKeyV2Tests.swift").readText())
        .associate { it.groupValues[1] to it.groupValues[2] }
    private val monthly get() = v2.getValue("monthly")
    private val monthlyLater get() = v2.getValue("monthlyLater")
    private val lifetime get() = v2.getValue("lifetime")
    private val purchased = 1_792_281_600_000L
    private val expires = 1_794_960_000_000L
    private val expiresLater = 1_797_638_400_000L
    private val day = 86_400_000L
    private val monthlyId = "00112233445566778899aabbccddeeff"

    private class Memory : SupporterKeyKeeper.Storage {
        val map = mutableMapOf<String, String>()
        override fun get(key: String) = map[key]
        override fun set(key: String, value: String?) { if (value == null) map.remove(key) else map[key] = value }
    }

    private class Recorder : SupporterKeyKeeper.Sink {
        /** null = none; otherwise (plan, issued). */
        var status: Pair<String, Long>? = null
        var fromStore = false
        var thanks = 0
        override fun grant(license: SupporterKeyCheck.License, fresh: Boolean) { status = license.plan to license.issuedAtMs; if (fresh) thanks++ }
        override fun withdraw() { status = null }
        override fun mayTouchStatus() = !fromStore
    }

    private fun keeper(memory: Memory, sink: Recorder, sent: MutableList<String> = mutableListOf(), answer: (String) -> Pair<Int, String>?) =
        SupporterKeyKeeper(memory, sink, testKey, post = { body -> sent += body; answer(body) })

    @Test fun activateStoresKeyAndStatusWithoutARequest() {
        val m = Memory(); val s = Recorder(); val sent = mutableListOf<String>()
        val k = keeper(m, s, sent) { 200 to """{"state":"active"}""" }
        assertTrue(k.activate(monthly, purchased) is SupporterKeyCheck.Result.Valid)
        assertEquals(monthly, k.storedKey)
        assertEquals("monthly" to purchased, s.status)
        assertEquals(1, s.thanks)
        assertEquals(SupporterKeyKeeper.Refresh.NotDue, k.refreshIfDue(purchased + 3_600_000))
        assertTrue(sent.isEmpty())
        assertFalse(k.activate("SS2-AAAA", purchased) is SupporterKeyCheck.Result.Valid)
        assertEquals(monthly, k.storedKey)
    }

    @Test fun renewalNearTheExpiryDayReplacesTheKey() {
        val m = Memory(); val s = Recorder(); val sent = mutableListOf<String>()
        val k = keeper(m, s, sent) { 200 to """{"state":"active","key":"$monthlyLater"}""" }
        k.activate(monthly, purchased)
        val soon = expires - 5 * day
        assertEquals(SupporterKeyKeeper.Refresh.Renewed, k.refreshIfDue(soon))
        assertEquals(listOf("id=$monthlyId"), sent)
        assertEquals(monthlyLater, k.storedKey)
        assertEquals(expiresLater, k.license?.expiresAtMs)
        assertEquals(SupporterKeyKeeper.Refresh.NotDue, k.refreshIfDue(soon + 3_600_000))
        // Far from the expiry day nothing is asked.
        val m2 = Memory(); val k2 = keeper(m2, Recorder()) { null }
        k2.activate(monthly, purchased)
        assertEquals(SupporterKeyKeeper.Refresh.NotDue, k2.refreshIfDue(purchased + 5 * day))
    }

    @Test fun expiredKeyTurnsTheStatusOffAndALateRenewalBack() {
        val m = Memory(); val s = Recorder()
        val offline = keeper(m, s) { null }
        offline.activate(monthly, purchased)
        offline.applyExpiry(expires)
        assertNull(s.status)
        assertEquals(monthly, offline.storedKey)
        assertEquals(SupporterKeyKeeper.Refresh.Failed, offline.refreshIfDue(expires))
        assertNull(s.status)
        val online = keeper(m, s) { 200 to """{"state":"active","key":"$monthlyLater"}""" }
        assertEquals(SupporterKeyKeeper.Refresh.Renewed, online.refreshIfDue(expires + day))
        assertEquals("monthly" to purchased, s.status)
    }

    @Test fun refundsRemoveTheKeyForeignAndOlderKeysAreIgnored() {
        val m = Memory(); val s = Recorder()
        val k = keeper(m, s) { 200 to """{"state":"revoked"}""" }
        k.activate(lifetime, purchased)
        assertEquals(SupporterKeyKeeper.Refresh.NotDue, k.refreshIfDue(purchased + 10 * day))
        assertEquals(SupporterKeyKeeper.Refresh.Revoked, k.refreshIfDue(purchased + 31 * day))
        assertNull(k.storedKey); assertNull(s.status)

        val m2 = Memory(); val k2 = keeper(m2, Recorder()) { 200 to """{"state":"active","key":"$lifetime"}""" }
        k2.activate(monthly, purchased)
        assertEquals(SupporterKeyKeeper.Refresh.Unchanged, k2.refreshIfDue(expires - day))
        assertEquals(monthly, k2.storedKey)

        val m3 = Memory(); val k3 = keeper(m3, Recorder()) { 200 to """{"state":"active","key":"$monthly"}""" }
        k3.activate(monthlyLater, purchased)
        assertEquals(SupporterKeyKeeper.Refresh.Unchanged, k3.refreshIfDue(expiresLater - day))
        assertEquals(monthlyLater, k3.storedKey)
    }

    @Test fun errorsAndUnknownAnswersChangeNothing() {
        for (answer in listOf(500 to "oops", 200 to "not json", 200 to """{"state":"unknown"}""")) {
            val s = Recorder(); val k = keeper(Memory(), s) { answer }
            k.activate(lifetime, purchased)
            k.refreshIfDue(purchased + 40 * day)
            assertEquals(lifetime, k.storedKey)
            assertEquals("lifetime" to purchased, s.status)
        }
    }

    @Test fun aStorePurchaseIsNeverTouchedByKeyExpiry() {
        val s = Recorder(); val k = keeper(Memory(), s) { null }
        k.activate(monthly, purchased)
        s.fromStore = true; s.status = "lifetime" to 1L
        k.applyExpiry(expiresLater)
        assertEquals("lifetime" to 1L, s.status)
    }
}
