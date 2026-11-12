package de.paulherter.swiftly

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DebugSessionExtraTest {
    private val json = """{"accessToken":"tok","userID":"u1","userName":"demo","serverURL":"http://10.0.2.2:8299"}"""

    @Test fun plainJsonPasses() = assertEquals(json, DebugSessionExtra.read(json, null).getOrThrow())

    @Test fun base64Passes() {
        val b64 = java.util.Base64.getEncoder().encodeToString(json.toByteArray())
        assertEquals(json, DebugSessionExtra.read(null, b64).getOrThrow())
    }

    @Test fun shellStrippedQuotesGiveAClearError() {
        val e = DebugSessionExtra.read("{accessToken:tok,userID:u1}", null).exceptionOrNull()
        assertTrue(e?.message.orEmpty().contains("testSessionB64"))
    }

    @Test fun brokenBase64AndMissingFail() {
        assertTrue(DebugSessionExtra.read(null, "%%%").isFailure)
        assertTrue(DebugSessionExtra.read(null, null).isFailure)
    }
}
