package de.paulherter.swiftly

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.security.KeyChain
import android.system.Os
import android.util.Log
import java.io.File
import java.security.KeyStore

/**
 * **Eigene Zertifizierungsstellen auch für den Kern und für VLC.**
 *
 * `netz_vertrauen.xml` lässt Android den Zertifikaten vertrauen, die der Nutzer selbst eingetragen
 * hat — das wirkt aber nur für Kotlin (Coil, Downloads). Anmeldung und alle Anfragen an Jellyfin
 * laufen durch den Swift-Kern: `URLSession` aus swift-corelibs-foundation, darunter libcurl mit
 * BoringSSL. Das liest auf Android nur `/apex/com.android.conscrypt/cacerts` (ab Android 14, davor
 * `/system/etc/security/cacerts`) — die eigenen Zertifikate des Nutzers liegen woanders, und eine App
 * darf dort nicht lesen. Folge: „SSL certificate problem: unable to get local issuer certificate",
 * auf dem Schirm „Dem Zertifikat des Servers wird nicht vertraut", obwohl Chrome auf demselben Gerät
 * aufmacht. Belegt am 22.09.2026 im Emulator mit einer eigenen Zertifizierungsstelle.
 *
 * Deshalb: **beim Start den ganzen Android-Speicher** (System und Nutzer, `AndroidCAStore`) als
 * PEM-Bündel ablegen und Foundation darauf zeigen lassen. Foundation liest dafür
 * `URLSessionCertificateAuthorityInfoFile` bei jeder neuen Verbindung (`EasyHandle.setCARootBundlePath`)
 * und setzt es als `CURLOPT_CAINFO`. VLC bekommt denselben Ordner als `--gnutls-dir-trust`; GnuTLS
 * findet dort sonst nur den Systemspeicher.
 *
 * **Nur, wenn der Nutzer eigene Zertifikate eingetragen hat.** Ohne bleibt alles bei der Vorgabe —
 * die ist erprobt. *Verworfen:* die Variable auf den Ordner `/system/etc/security/cacerts` zu setzen;
 * sie erwartet eine Datei, und jede Verbindung brach ab (Spike, 14.09.2026).
 *
 * **Auch waehrend die App laeuft.** Wer die Zertifizierungsstelle erst nach dem Start eintraegt
 * (Einstellungen, zurueck in die App, „Verbinden"), bekam bisher denselben Fehler, bis die App
 * einmal ganz beendet war. `KeyChain.ACTION_TRUST_STORE_CHANGED` legt das Buendel darum neu an;
 * Foundation liest die Variable bei jeder neuen Verbindung (`getenv`). Faellt das letzte eigene
 * Zertifikat weg, wird die Variable **entfernt** — sie zeigte sonst auf eine geloeschte Datei, und
 * curl lehnte jede https-Verbindung ab.
 */
object Zertifikate {
    /** Ordner mit dem Bündel — für VLC. `null` ohne eigene Zertifikate. */
    @Volatile var ordner: String? = null
        private set

    private const val VARIABLE = "URLSessionCertificateAuthorityInfoFile"

    /** Einmal beim Start: bei jeder Aenderung am Zertifikatsspeicher das Buendel neu anlegen. */
    fun beobachten(kontext: Context) {
        val app = kontext.applicationContext
        val empfaenger = object : BroadcastReceiver() {
            override fun onReceive(c: Context, intent: Intent) {
                // Aus dem Hauptfaden: der Speicher liest Dateien.
                Thread { bereitstellen(app) }.start()
            }
        }
        val filter = IntentFilter(KeyChain.ACTION_TRUST_STORE_CHANGED)
        // Systemmeldung, kommt nur vom System — nicht exportiert reicht. Lebt so lange wie der Prozess.
        androidx.core.content.ContextCompat.registerReceiver(app, empfaenger, filter,
            androidx.core.content.ContextCompat.RECEIVER_NOT_EXPORTED)
    }

    /** **Vor der ersten Anfrage des Kerns** aufrufen — beim Start der App. */
    @Synchronized
    fun bereitstellen(kontext: Context) {
        val ablage = File(kontext.filesDir, "zertifikate")
        try {
            val speicher = KeyStore.getInstance("AndroidCAStore").apply { load(null) }
            val namen = speicher.aliases().toList()
            val eigene = namen.count { it.startsWith("user:") }
            if (eigene == 0) {
                // Erst die Variable, dann die Datei — sonst zeigt sie kurz ins Leere.
                Os.unsetenv(VARIABLE)
                ordner = null
                if (ablage.exists()) ablage.deleteRecursively()
                Log.i("Swiftly", "Zertifikate: keine eigenen, der Kern nimmt den Systemspeicher")
                return
            }
            val kodierer = java.util.Base64.getMimeEncoder(64, "\n".toByteArray())
            val text = StringBuilder()
            for (name in namen) {
                val zertifikat = speicher.getCertificate(name) ?: continue
                text.append("-----BEGIN CERTIFICATE-----\n")
                    .append(kodierer.encodeToString(zertifikat.encoded))
                    .append("\n-----END CERTIFICATE-----\n")
            }
            ablage.mkdirs()
            val ziel = File(ablage, "alle.pem")
            val neu = File(ablage, "alle.pem.neu")
            neu.writeText(text.toString())
            if (!neu.renameTo(ziel)) { neu.copyTo(ziel, overwrite = true); neu.delete() }
            Os.setenv(VARIABLE, ziel.absolutePath, true)
            ordner = ablage.absolutePath
            Log.i("Swiftly", "Zertifikate: ${namen.size - eigene} System, $eigene eigene — Bündel für Kern und VLC")
        } catch (e: Exception) {
            Log.w("Swiftly", "Zertifikate: Bündel nicht angelegt, der Kern nimmt den Systemspeicher", e)
        }
    }
}
