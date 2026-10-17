package de.paulherter.swiftly

import android.system.Os
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.security.KeyStore
import java.util.concurrent.TimeUnit

/**
 * **Custom certificate authorities reach the Swift core.**
 *
 * Runs on an emulator/device: `./gradlew :phone:connectedDebugAndroidTest`.
 * The connection test needs its own test CA in the user store and an https server with a
 * certificate from that CA; its address comes as an instrumentation argument
 * `-Pandroid.testInstrumentationRunnerArguments.zertifikatServer=https://10.0.2.2:8443`.
 * Without the argument it is skipped.
 *
 * If the CA cannot go into the user store (Play image without root, entry only via settings),
 * `coreReadsBundle` checks the decisive step alone: the same variable that `Certificates` sets,
 * pointing at a bundle with the test CA (`zertifikatCA`, PEM in Base64). Without it the core
 * rejects, with it the core connects.
 */
@RunWith(AndroidJUnit4::class)
class CertificatesTest {
    private val VARIABLE = "URLSessionCertificateAuthorityInfoFile"
    private val app get() = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SwiftlyApplication

    private fun ownCertificates(): List<ByteArray> {
        val cache = KeyStore.getInstance("AndroidCAStore").apply { load(null) }
        return cache.aliases().toList().filter { it.startsWith("user:") }.map { cache.getCertificate(it).encoded }
    }

    @Test
    fun bundleContainsEachOwnCertificate() {
        Certificates.readySet(app)
        val ownOnes = ownCertificates()
        val variable = Os.getenv("URLSessionCertificateAuthorityInfoFile")
        if (ownOnes.isEmpty()) {
            assertNull("ohne eigene Zertifikate bleibt der Kern bei der Vorgabe", variable)
            assertNull(Certificates.folder)
            return
        }
        assertNotNull(variable)
        val text = File(variable!!).readText()
        val encoder = java.util.Base64.getMimeEncoder(64, "\n".toByteArray())
        for (the in ownOnes) assertTrue("eigenes Zertifikat fehlt im Buendel", text.contains(encoder.encodeToString(the)))
        assertEquals(File(variable).parent, Certificates.folder)
    }

    @Test
    fun coreReadsBundle() {
        val args = InstrumentationRegistry.getArguments()
        val address = args.getString("zertifikatServer")
        val ca = args.getString("zertifikatCA")
        assumeTrue("kein Testserver angegeben", address != null && ca != null)
        val before = Os.getenv(VARIABLE)
        try {
            // Without a bundle: system store only; it does not know the test CA.
            Os.unsetenv(VARIABLE)
            val rejected = runCatching { app.kern.linkUp(address!!, "[]").get(30, TimeUnit.SECONDS) }
            assertTrue("ohne Buendel darf der Kern der Test-CA nicht trauen", rejected.isFailure)
            val file = File(app.cacheDir, "test-ca.pem").apply { writeBytes(java.util.Base64.getDecoder().decode(ca)) }
            Os.setenv(VARIABLE, file.absolutePath, true)
            val answer = app.kern.linkUp(address!!, "[]").get(30, TimeUnit.SECONDS)
            assertTrue(answer, answer.contains("Zertifikatstest"))
        } finally {
            if (before != null) Os.setenv(VARIABLE, before, true) else Os.unsetenv(VARIABLE)
        }
    }

    @Test
    fun coreTrustsOwnCertificateAuthority() {
        val address = InstrumentationRegistry.getArguments().getString("zertifikatServer")
        assumeTrue("kein Testserver angegeben", address != null)
        assumeTrue("keine eigene Zertifizierungsstelle eingetragen", ownCertificates().isNotEmpty())
        Certificates.readySet(app)
        val answer = app.kern.linkUp(address!!, "[]").get(30, TimeUnit.SECONDS)
        assertTrue(answer, answer.contains("Zertifikatstest"))
    }
}
