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
 * **Eigene Zertifizierungsstellen erreichen den Swift-Kern** (Liste 20.09./23.09.).
 *
 * Laeuft auf einem Emulator/Geraet: `./gradlew :handy:connectedDebugAndroidTest`.
 * Der Verbindungstest braucht eine eigene Test-CA im Nutzerspeicher und einen https-Server mit
 * einem Zertifikat dieser CA; seine Adresse kommt als Instrumentierungsargument
 * `-Pandroid.testInstrumentationRunnerArguments.zertifikatServer=https://10.0.2.2:8443`.
 * Ohne das Argument wird er uebersprungen.
 *
 * Geht die CA nicht in den Nutzerspeicher (Play-Abbild ohne root, Eintrag nur ueber die
 * Einstellungen), prueft `kernLiestDasBuendel` den entscheidenden Schritt allein: dieselbe
 * Variable, die `Zertifikate` setzt, auf ein Buendel mit der Test-CA (`zertifikatCA`, PEM in
 * Base64) — ohne sie lehnt der Kern ab, mit ihr verbindet er.
 */
@RunWith(AndroidJUnit4::class)
class ZertifikateTest {
    private val VARIABLE = "URLSessionCertificateAuthorityInfoFile"
    private val app get() = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SwiftlyAnwendung

    private fun eigeneZertifikate(): List<ByteArray> {
        val speicher = KeyStore.getInstance("AndroidCAStore").apply { load(null) }
        return speicher.aliases().toList().filter { it.startsWith("user:") }.map { speicher.getCertificate(it).encoded }
    }

    @Test
    fun buendelEnthaeltJedesEigeneZertifikat() {
        Zertifikate.bereitstellen(app)
        val eigene = eigeneZertifikate()
        val variable = Os.getenv("URLSessionCertificateAuthorityInfoFile")
        if (eigene.isEmpty()) {
            assertNull("ohne eigene Zertifikate bleibt der Kern bei der Vorgabe", variable)
            assertNull(Zertifikate.ordner)
            return
        }
        assertNotNull(variable)
        val text = File(variable!!).readText()
        val kodierer = java.util.Base64.getMimeEncoder(64, "\n".toByteArray())
        for (der in eigene) assertTrue("eigenes Zertifikat fehlt im Buendel", text.contains(kodierer.encodeToString(der)))
        assertEquals(File(variable).parent, Zertifikate.ordner)
    }

    @Test
    fun kernLiestDasBuendel() {
        val args = InstrumentationRegistry.getArguments()
        val adresse = args.getString("zertifikatServer")
        val ca = args.getString("zertifikatCA")
        assumeTrue("kein Testserver angegeben", adresse != null && ca != null)
        val vorher = Os.getenv(VARIABLE)
        try {
            // Ohne Buendel: nur der Systemspeicher — die Test-CA kennt er nicht.
            Os.unsetenv(VARIABLE)
            val abgelehnt = runCatching { app.kern.verbinden(adresse!!, "[]").get(30, TimeUnit.SECONDS) }
            assertTrue("ohne Buendel darf der Kern der Test-CA nicht trauen", abgelehnt.isFailure)
            val datei = File(app.cacheDir, "test-ca.pem").apply { writeBytes(java.util.Base64.getDecoder().decode(ca)) }
            Os.setenv(VARIABLE, datei.absolutePath, true)
            val antwort = app.kern.verbinden(adresse!!, "[]").get(30, TimeUnit.SECONDS)
            assertTrue(antwort, antwort.contains("Zertifikatstest"))
        } finally {
            if (vorher != null) Os.setenv(VARIABLE, vorher, true) else Os.unsetenv(VARIABLE)
        }
    }

    @Test
    fun kernVertrautDerEigenenZertifizierungsstelle() {
        val adresse = InstrumentationRegistry.getArguments().getString("zertifikatServer")
        assumeTrue("kein Testserver angegeben", adresse != null)
        assumeTrue("keine eigene Zertifizierungsstelle eingetragen", eigeneZertifikate().isNotEmpty())
        Zertifikate.bereitstellen(app)
        val antwort = app.kern.verbinden(adresse!!, "[]").get(30, TimeUnit.SECONDS)
        assertTrue(antwort, antwort.contains("Zertifikatstest"))
    }
}
