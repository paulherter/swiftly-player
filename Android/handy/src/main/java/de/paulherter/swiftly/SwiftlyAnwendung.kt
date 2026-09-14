package de.paulherter.swiftly

import android.app.Application
import android.content.Context
import android.os.Build
import de.paulherter.swiftly.gemeinsam.Texte
import de.paulherter.swiftly.kern.Kern
import kotlinx.coroutines.future.await
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

    /**
     * **Die zuletzt geladenen Reihen der Startseite.** Compose baut eine Seite beim
     * Bereichswechsel ab; ohne diesen Stand stand die Startseite beim Zurueckkommen
     * eine Sekunde leer. Auf iOS haelt `HauptView` das `Startseitenmodell` genauso.
     */
    var startReihen: List<Reihe>? = null

    /** Je Gattung ein Stand — wie die Modelle in `HauptView`, die den Bereichswechsel ueberleben. */
    val bibliotheken = mutableMapOf<String, Bibliotheksstand>()

    /** Das offene Auswahlblatt. Es liegt ueber der Leiste, deshalb haelt es die App, nicht die Seite. */
    val blatt = androidx.compose.runtime.mutableStateOf<Blattwunsch?>(null)

    /**
     * **Der Servername, einmal fuer alle Seiten** — wie `AppModel.serverName`. `null` heisst
     * „noch nicht gefragt", leer heisst „der Server nennt keinen".
     *
     * Er stand in jeder Bibliothek einzeln und kam dort erst nach den Platzhaltern an; der Kopf
     * wuchs dann um eine Zeile und das ganze Raster rutschte herunter.
     */
    val servername = androidx.compose.runtime.mutableStateOf<String?>(null)

    suspend fun servernameLaden() {
        if (servername.value != null) return
        try {
            servername.value = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                kern.servername().await()
            }
        } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (_: Exception) {}
    }

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

    /** Der Name aus der gemerkten Sitzung — fuer das Profilzeichen. */
    fun benutzername(): String = ablage.sitzung?.let {
        runCatching { org.json.JSONObject(it).optString("userName") }.getOrNull()
    }.orEmpty().ifEmpty { "?" }

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

    /** Sortierung, Filter, gewaehlte Bibliothek — dieselben Schluessel wie in UserDefaults auf Apple. */
    fun merkwert(schluessel: String): String? = prefs.getString(schluessel, null)
    fun merken(schluessel: String, wert: String) { prefs.edit().putString(schluessel, wert).apply() }

    fun geraeteID(): String = prefs.getString("de.paulherter.swiftly.deviceID", null)
        ?: UUID.randomUUID().toString().also { prefs.edit().putString("de.paulherter.swiftly.deviceID", it).apply() }
}
