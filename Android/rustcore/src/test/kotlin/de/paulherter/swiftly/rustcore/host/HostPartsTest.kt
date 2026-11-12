package de.paulherter.swiftly.rustcore.host

import de.paulherter.swiftly.rustcore.SyncPlayStep
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Locale

class HostPartsTest {
    @Test fun longDateInGermanAndEnglish() {
        val de = AndroidDateText { Locale.GERMAN }
        assertEquals("1. Mai 1980", de.longDate("1980-05-01T00:00:00.0000000Z"))
        assertEquals("1. Mai 1980", de.longDate("1980-05-01T00:00:00Z"))
        assertEquals("1. Mai 1980", de.longDate("1980-05-01"))
        assertEquals("May 1, 1980", AndroidDateText { Locale.US }.longDate("1980-05-01T00:00:00Z"))
        assertNull(de.longDate("gestern"))
    }

    @Test fun cookieJarRemembersAndForgets() {
        val jar = AndroidSeerrCookieJar()
        assertNull(jar.sessionCookie("http://s"))
        jar.remember("http://s", "connect.sid=abc"); assertEquals("connect.sid=abc", jar.sessionCookie("http://s"))
        jar.forget("http://s"); assertNull(jar.sessionCookie("http://s"))
    }

    @Test fun forwardHostPortAndRandomness() {
        var port = 0
        val host = AndroidStreamForwardHost({ port })
        assertNull(host.listeningPort())
        port = 8123; assertEquals(8123.toUShort(), host.listeningPort())
        val a = host.randomBytes(); val b = host.randomBytes()
        assertEquals(16, a.size); assertTrue(!a.contentEquals(b))
    }

    @Test fun listenersForwardTheirCalls() {
        val seen = ArrayList<String>()
        LambdaQuickConnectListener { seen += "qc$it" }.rest(5)
        LambdaPlexPinListener { seen += "pin$it" }.rest(7)
        LambdaGroupHook({ seen += "toggle$it" }, { seen += "jump$it" }).apply { toggle(true); jump(3.5) }
        assertEquals(listOf("qc5", "pin7", "toggletrue", "jump3.5"), seen)
        assertEquals(SyncPlayStep.Jump(2.0), SyncPlayStep.Jump(2.0))
    }
}
