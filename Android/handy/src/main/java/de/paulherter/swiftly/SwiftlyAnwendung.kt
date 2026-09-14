package de.paulherter.swiftly

import android.app.Application
import android.content.Context
import android.os.Build
import de.paulherter.swiftly.gemeinsam.Texte
import de.paulherter.swiftly.kern.Kern
import org.swift.swiftkit.core.SwiftArena
import java.io.File
import java.util.Locale
import java.util.UUID

/**
 * **Was die App einmal beim Start braucht:** Texte, die Uebersetzungen des Pakets,
 * und den Kern. Der Kern lebt so lange wie die App — wie `AppModel` auf Apple.
 */
class SwiftlyAnwendung : Application() {
    lateinit var kern: Kern
        private set
    lateinit var ablage: Ablage
        private set

    override fun onCreate() {
        super.onCreate()
        ablage = Ablage(this)
        Texte.laden(this)
        val sprache = if (Locale.getDefault().language == "de") "de" else "en"
        // Vor dem ersten Text aus dem Paket — sonst stehen dort die Schluessel.
        Kern.paketspracheSetzen(paketspracheEntpacken().absolutePath, sprache)
        kern = Kern.init(ablage.geraeteID(), Build.MODEL ?: "Android", BuildConfigFassung, SwiftArena.ofAuto())
    }

    /** Stellt die gemerkte Sitzung wieder her. `false`, wenn es keine gibt oder sie nicht lesbar ist. */
    fun sitzungWiederherstellen(): Boolean {
        val json = ablage.sitzung ?: return false
        return try { kern.sitzungSetzen(json); true } catch (e: Exception) { ablage.sitzung = null; false }
    }

    /** Assets koennen keinen Dateipfad nennen; `Bundle(path:)` braucht einen. Also einmal entpacken. */
    private fun paketspracheEntpacken(): File {
        val ziel = File(filesDir, "paketsprache")
        ziel.deleteRecursively()
        kopieren("paketsprache", ziel)
        return ziel
    }

    private fun kopieren(pfad: String, ziel: File) {
        val kinder = assets.list(pfad) ?: emptyArray()
        if (kinder.isEmpty()) {
            ziel.parentFile?.mkdirs()
            assets.open(pfad).use { ein -> ziel.outputStream().use { ein.copyTo(it) } }
        } else {
            ziel.mkdirs()
            kinder.forEach { kopieren("$pfad/$it", File(ziel, it)) }
        }
    }

    companion object {
        const val BuildConfigFassung = "1.0.3"
    }
}

/**
 * **Plattformablage** — das Gegenstueck zu Keychain und UserDefaults auf Apple.
 * Das Format der Sitzung kommt aus dem Paket; hier wird nur abgelegt.
 * Offen (PLAN): Sitzung im Android Keystore verschluesseln.
 */
class Ablage(context: Context) {
    private val prefs = context.getSharedPreferences("swiftly", Context.MODE_PRIVATE)

    var sitzung: String?
        get() = prefs.getString("sitzung", null)
        set(wert) { prefs.edit().putString("sitzung", wert).apply() }

    var letzterServer: String?
        get() = prefs.getString("letzterServer", null)
        set(wert) { prefs.edit().putString("letzterServer", wert).apply() }

    fun geraeteID(): String = prefs.getString("de.paulherter.swiftly.deviceID", null)
        ?: UUID.randomUUID().toString().also { prefs.edit().putString("de.paulherter.swiftly.deviceID", it).apply() }
}
