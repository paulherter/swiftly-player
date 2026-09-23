package de.paulherter.swiftly

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.IBinder
import android.os.StatFs
import android.os.SystemClock
import androidx.compose.runtime.mutableStateOf
import de.paulherter.swiftly.gemeinsam.uebersetzt
import de.paulherter.swiftly.kern.Kern
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import kotlin.coroutines.coroutineContext

/**
 * Gegenstueck zu `Downloadposten` im Paket — **dasselbe JSON**, damit die Regeln dort rechnen.
 * `angelegt` bleibt die Zahl, die Swift schreibt (Sekunden seit 2001); hier wird sie nur weitergereicht.
 */
data class Downloadposten(
    val id: String, val konto: String, val art: String, val titel: String,
    val serie: String?, val serienId: String?, val staffel: Int?, val folge: Int?,
    val laufzeitTicks: Long?, val container: String?, val quelle: String?, val bytes: Long,
    val geladen: Long, val stand: String, val grund: String?, val gesehen: Boolean,
    val angelegt: Double, val nochAufDemServer: Boolean,
) {
    /** Konto und Kennung (H11), die Endung des Containers, damit VLC den Demuxer erraet. */
    val dateiname: String get() = "$konto-$id" + (container?.lowercase()?.let { ".$it" } ?: "")
    val anteil: Double? get() = if (bytes > 0) (geladen.toDouble() / bytes).coerceIn(0.0, 1.0) else null

    fun json(): JSONObject = JSONObject().apply {
        put("id", id); put("konto", konto); put("art", art); put("titel", titel)
        putOpt("serie", serie); putOpt("serienId", serienId); putOpt("staffel", staffel); putOpt("folge", folge)
        putOpt("laufzeitTicks", laufzeitTicks); putOpt("container", container); putOpt("quelle", quelle)
        put("bytes", bytes); put("geladen", geladen); put("stand", stand); putOpt("grund", grund)
        put("gesehen", gesehen); put("angelegt", angelegt); put("nochAufDemServer", nochAufDemServer)
    }

    companion object {
        fun lesen(o: JSONObject) = Downloadposten(
            o.getString("id"), o.getString("konto"), o.getString("art"), o.getString("titel"),
            o.feldText("serie"), o.feldText("serienId"), o.optInt("staffel").takeIf { o.has("staffel") && !o.isNull("staffel") },
            o.optInt("folge").takeIf { o.has("folge") && !o.isNull("folge") },
            o.optLong("laufzeitTicks").takeIf { o.has("laufzeitTicks") && !o.isNull("laufzeitTicks") },
            o.optString("container").takeIf { o.has("container") && !o.isNull("container") },
            o.optString("quelle").takeIf { o.has("quelle") && !o.isNull("quelle") },
            o.optLong("bytes"), o.optLong("geladen"), o.getString("stand"),
            o.optString("grund").takeIf { o.has("grund") && !o.isNull("grund") },
            o.optBoolean("gesehen"), o.optDouble("angelegt", 0.0), o.optBoolean("nochAufDemServer", true))

        fun liste(posten: List<Downloadposten>): String = JSONArray().apply { posten.forEach { put(it.json()) } }.toString()
    }
}

/** Die Nachricht ist schon der Satz fuer den Schirm — nie ein Code, nie ein Typname. */
private class Ladefehler(grund: String) : Exception(grund)

/**
 * Vorlage: `Downloadverwaltung` in `Sources/Shared/Downloadverwaltung.swift`.
 *
 * **Es laedt immer nur einer** (H4), und `takt()` ist die **einzige** Stelle, die einen Download
 * startet — nach jeder Aenderung, jedem Netzwechsel und beim Start. Die Liste enthaelt alle Konten,
 * sichtbar ist nur das geltende (H11). Fortschritt wird nicht bei jedem Stueck geschrieben, sondern
 * beim Anhalten und am Ende. Wiederaufnahme mit `Range` auf die angefangene `.teil`-Datei.
 */
class Downloadverwaltung(private val app: SwiftlyAnwendung) {
    val ordner = File(app.filesDir, "Downloads").apply { mkdirs() }
    private val listeDatei = File(ordner, "liste.json")
    private var alle: List<Downloadposten> = lesen()

    /** Die Posten des geltenden Kontos. */
    val posten = mutableStateOf<List<Downloadposten>>(emptyList())
    /** Ueberhaupt Netz — fuer „Wartet auf Netz" und „Kein Netz". */
    val netz = mutableStateOf(true)
    private var imWLAN = true
    private var konto = ""

    private val lauf = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var aufgabe: Job? = null
    private var laufend: String? = null
    private var gemeldetUm = 0L

    init {
        val verbindung = app.getSystemService(ConnectivityManager::class.java)
        runCatching {
            verbindung.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
                override fun onCapabilitiesChanged(n: Network, c: NetworkCapabilities) {
                    // Ethernet zaehlt wie WLAN — beides kostet nichts.
                    val wlan = c.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) || c.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
                    lauf.launch { netz.value = true; imWLAN = wlan; takt() }
                }
                override fun onLost(n: Network) { lauf.launch { netz.value = false; imWLAN = false; takt() } }
            })
        }
    }

    private fun lesen(): List<Downloadposten> = runCatching {
        JSONArray(listeDatei.readText()).let { a -> (0 until a.length()).map { Downloadposten.lesen(a.getJSONObject(it)) } }
    }.getOrDefault(emptyList())
        // Wer beim Beenden der App lud, wartet jetzt — geladen wird, was auf der Platte liegt.
        .map { if (it.stand == "laedt") it.copy(stand = "wartet", geladen = teil(it).length()) else it }

    private fun speichern() {
        val neu = File(ordner, "liste.json.neu")
        neu.writeText(Downloadposten.liste(alle))
        neu.renameTo(listeDatei)
    }

    private fun zeigen() { posten.value = alle.filter { it.konto == konto } }

    private fun teil(p: Downloadposten) = File(ordner, p.dateiname + ".teil")
    fun bildDatei(kennung: String) = File(ordner, "$konto-$kennung.jpg")

    fun darfLaden(): Boolean = Kern.downloadDarfLaden(imWLAN, app.einstellungen.nurUeberWLAN)

    fun frei(): Long = runCatching { StatFs(ordner.path).availableBytes }.getOrDefault(0L)
    fun gesamt(): Long = runCatching { StatFs(ordner.path).totalBytes }.getOrDefault(0L)

    /** H11 — nach dem Anmelden gilt, was diesem Konto gehoert. Laeuft einer des alten, haelt er an. */
    fun kontoSetzen(neu: String) {
        if (neu == konto) return
        laufend?.let { id -> if (alle.any { it.id == id && it.konto != neu }) anhalten(id) }
        konto = neu
        zeigen()
        takt()
    }

    fun posten(id: String): Downloadposten? = posten.value.firstOrNull { it.id == id }

    fun datei(id: String): File? = posten(id)?.takeIf { it.stand == "fertig" }?.let { File(ordner, it.dateiname) }?.takeIf { it.exists() }

    private fun aendern(id: String, schreiben: Boolean = true, neu: (Downloadposten) -> Downloadposten) {
        alle = alle.map { if (it.id == id && it.konto == konto) neu(it) else it }
        zeigen()
        if (schreiben) speichern()
    }

    /** Neue Posten in die Schlange; was schon da ist, kommt nicht noch einmal. Die Bilder laden mit. */
    fun hinzufuegen(neue: List<Downloadposten>, bilder: Map<String, String>) {
        val frisch = neue.filter { n -> alle.none { it.id == n.id && it.konto == n.konto } }
        if (frisch.isEmpty()) return
        alle = alle + frisch
        zeigen(); speichern()
        lauf.launch(Dispatchers.IO) { bilder.forEach { (kennung, adresse) -> bildSichern(bildDatei(kennung), adresse) } }
        takt()
    }

    /** Laedt nicht, was schon liegt; erst ganz geladen wird die Datei an ihren Platz gelegt. */
    private fun bildSichern(ziel: File, adresse: String): Boolean {
        if (ziel.exists()) return true
        return runCatching {
            val v = URL(adresse).openConnection() as HttpURLConnection
            v.connectTimeout = 15000; v.readTimeout = 30000
            eigenkoepfeFelder(adresse).forEach { (name, wert) -> v.setRequestProperty(name, wert) }
            val neu = File(ziel.path + ".neu")
            val ging = v.responseCode in 200..299 && v.inputStream.use { ein -> neu.outputStream().use { ein.copyTo(it) } } > 0
            v.disconnect()
            ging && neu.renameTo(ziel)
        }.getOrDefault(false)
    }

    /** Unter diesem Schluessel reicht die Serienseite das grosse Kopfbild in `hinzufuegen` herein. */
    fun kopfkennung(serienId: String) = "$serienId-kopf"

    /**
     * **Das Kopfbild der Serie in Bildschirmaufloesung** — Vorlage `Downloadverwaltung.kopfbild`.
     * Plakat und Querbilder sind fuer Zeilen gemessen und standen im Kopf gestreckt und weich da.
     */
    fun kopfbild(serienId: String): File? = bildDatei(kopfkennung(serienId)).takeIf { it.exists() }

    /** Fuer Downloads von vorher, die es noch nicht haben: beim naechsten Oeffnen mit Netz nachholen. */
    suspend fun kopfbildNachholen(serienId: String, adresse: String): File? = withContext(Dispatchers.IO) {
        val ziel = bildDatei(kopfkennung(serienId))
        if (bildSichern(ziel, adresse)) ziel else null
    }

    /** `ringGetippt` — ein Ring, eine Regel. Geladenes entfernt nur die Liste. */
    fun ringTippen(p: Downloadposten?, anlegen: () -> Unit) {
        when (p?.stand) {
            null -> anlegen()
            "laedt" -> anhalten(p.id)
            "angehalten", "fehler", "wartet" -> fortsetzen(p.id)
        }
    }

    fun anhalten(id: String) {
        if (laufend == id) { aufgabe?.cancel(); aufgabe = null; laufend = null }
        // Pause steht sofort — der Schaetzer zaehlt nicht ueber die Pause weiter.
        Kern.downloadSchaetzerAnhalten(id)
        val p = alle.firstOrNull { it.id == id } ?: return
        aendern(id) { it.copy(stand = "angehalten", geladen = teil(p).length(), grund = null) }
        takt()
    }

    fun fortsetzen(id: String) {
        aendern(id) { if (it.stand == "fertig" || it.stand == "laedt") it else it.copy(stand = "wartet", grund = null) }
        takt()
    }

    /** Laufende brechen ab, Datei und eigenes Bild gehen; das Serienplakat erst mit der letzten Folge. */
    fun entfernen(ids: Collection<String>) {
        val weg = alle.filter { it.konto == konto && it.id in ids }
        if (laufend in ids) { aufgabe?.cancel(); aufgabe = null; laufend = null }
        alle = alle - weg.toSet()
        weg.forEach { p ->
            File(ordner, p.dateiname).delete(); teil(p).delete(); bildDatei(p.id).delete()
            Kern.downloadSchaetzerVergessen(p.id)
            val sid = p.serienId
            if (sid != null && alle.none { it.konto == konto && it.serienId == sid }) {
                bildDatei(sid).delete(); bildDatei(kopfkennung(sid)).delete()
            }
        }
        zeigen(); speichern()
        takt()
    }

    fun allesEntfernen() = entfernen(posten.value.map { it.id })

    /** Die einzige Stelle, die startet. Fehlt WLAN und gilt „Nur ueber WLAN", haelt der laufende an und wartet. */
    fun takt() {
        val nurWLAN = app.einstellungen.nurUeberWLAN
        val darf = Kern.downloadDarfLaden(imWLAN, nurWLAN)
        laufend?.let { id ->
            if (!darf) {
                aufgabe?.cancel(); aufgabe = null; laufend = null
                val p = alle.firstOrNull { it.id == id }
                Kern.downloadSchaetzerAnhalten(id)
                if (p != null) aendern(id) { it.copy(stand = "wartet", geladen = teil(p).length()) }
            }
        }
        if (laufend == null && konto.isNotEmpty()) {
            val id = Kern.downloadNaechster(Downloadposten.liste(posten.value), imWLAN, nurWLAN)
            posten.value.firstOrNull { it.id == id }?.let { starten(it) }
        }
        if (laufend == null) DownloadDienst.aus(app)
    }

    private fun starten(p: Downloadposten) {
        laufend = p.id
        aendern(p.id) { it.copy(stand = "laedt", grund = null) }
        DownloadDienst.an(app, p.titel, p.anteil)
        aufgabe = lauf.launch {
            val ergebnis = withContext(Dispatchers.IO) { runCatching { laden(p) } }
            // Abgebrochen kommt hier nicht an — wer abbricht, setzt den Stand selbst.
            laufend = null; aufgabe = null
            val fehler = ergebnis.exceptionOrNull()
            if (fehler == null) Kern.downloadSchaetzerVergessen(p.id) else Kern.downloadSchaetzerAnhalten(p.id)
            when {
                fehler == null -> aendern(p.id) { it.copy(stand = "fertig", geladen = ergebnis.getOrDefault(it.bytes), grund = null) }
                // Ohne Netz mit angefangener Datei: angehalten, kein Fehlertext — es geht dort weiter.
                fehler is IOException && fehler !is Ladefehler && teil(p).length() > 0 ->
                    aendern(p.id) { it.copy(stand = "angehalten", geladen = teil(p).length()) }
                else -> aendern(p.id) { it.copy(stand = "fehler", grund = if (fehler is Ladefehler) fehler.message else fehlertext(app, fehler), geladen = teil(p).length()) }
            }
            takt()
        }
    }

    private suspend fun laden(p: Downloadposten): Long {
        val adresse = app.kern.downloadAdresse(p.id, p.quelle.orEmpty()).await()
        val teil = teil(p)
        val schon = if (teil.exists()) teil.length() else 0L
        val v = URL(adresse).openConnection() as HttpURLConnection
        v.connectTimeout = 15000; v.readTimeout = 30000
        // Mit den eigenen Headern des Servers (Issue #4); ohne Eintrag dieselbe Anfrage wie vorher.
        eigenkoepfeFelder(adresse).forEach { (name, wert) -> v.setRequestProperty(name, wert) }
        if (schon > 0) v.setRequestProperty("Range", "bytes=$schon-")
        try {
            val code = v.responseCode
            // Eine Fehlerseite ist keine fertige Datei.
            if (code !in 200..299) throw Ladefehler(Kern.downloadFehlertext(code.toLong()))
            val anhaengen = code == 206
            var geladen = if (anhaengen) schon else 0L
            val gesamt = if (p.bytes > 0) p.bytes else v.contentLengthLong.takeIf { it > 0 }?.plus(geladen) ?: 0L
            // **Hoechstens einmal je Sekunde** (`Downloadregeln.fortschrittZeigen`). Das halbe
            // Prozent allein liess bei schneller Leitung fuenf und mehr Zahlen je Sekunde durch —
            // die Unterzeile zitterte, statt zu zaehlen. Dazwischen zaehlt der Schaetzer weiter.
            var gemeldet = -1L
            var gemeldetZeit = 0L
            v.inputStream.use { ein ->
                FileOutputStream(teil, anhaengen).use { aus ->
                    val puffer = ByteArray(256 * 1024)
                    while (true) {
                        coroutineContext.ensureActive()
                        val n = ein.read(puffer)
                        if (n < 0) break
                        aus.write(puffer, 0, n)
                        geladen += n
                        val jetzt = SystemClock.elapsedRealtime()
                        if (Kern.downloadFortschrittZeigen(geladen, gesamt, gemeldet,
                                                           if (gemeldet < 0) -1.0 else (jetzt - gemeldetZeit) / 1000.0)) {
                            gemeldet = geladen
                            gemeldetZeit = jetzt
                            val stand = geladen
                            withContext(Dispatchers.Main) { fortschritt(p, stand, gesamt) }
                        }
                    }
                }
            }
            coroutineContext.ensureActive()
            if (!teil.renameTo(File(ordner, p.dateiname))) throw Ladefehler(uebersetzt("Die Datei liess sich nicht ablegen."))
            return geladen
        } finally { v.disconnect() }
    }

    private fun fortschritt(p: Downloadposten, geladen: Long, gesamt: Long) {
        if (laufend != p.id) return
        Kern.downloadSchaetzerMelden(p.id, geladen, if (gesamt > 0) gesamt else p.bytes)
        aendern(p.id, schreiben = false) { it.copy(geladen = geladen) }
        val jetzt = SystemClock.elapsedRealtime()
        if (jetzt - gemeldetUm > 1500) { gemeldetUm = jetzt; DownloadDienst.melden(app, p.titel, posten(p.id)?.anteil) }
    }

    /** Gesehen und „noch auf dem Server" — einmal nach dem Start, nur mit Antwort. */
    suspend fun nachziehen() {
        val eigene = posten.value
        if (eigene.isEmpty()) return
        val neu = runCatching {
            JSONArray(app.kern.downloadsNachziehen(Downloadposten.liste(eigene)).await())
                .let { a -> (0 until a.length()).map { Downloadposten.lesen(a.getJSONObject(it)) } }
        }.getOrNull() ?: return
        val karte = neu.associateBy { it.id }
        alle = alle.map { p ->
            if (p.konto != konto) p
            else karte[p.id]?.let { p.copy(gesehen = it.gesehen, nochAufDemServer = it.nochAufDemServer) } ?: p
        }
        zeigen(); speichern()
    }
}

/**
 * **Haelt den Download am Leben**, wenn die App im Hintergrund ist — das Gegenstueck zur
 * Hintergrundsitzung von `URLSession`. Der Download selbst laeuft in `Downloadverwaltung`.
 */
class DownloadDienst : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val n = nachricht(this, intent?.getStringExtra("titel").orEmpty(), intent?.getDoubleExtra("anteil", -1.0) ?: -1.0)
        if (Build.VERSION.SDK_INT >= 29) startForeground(NUMMER, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        else startForeground(NUMMER, n)
        return START_NOT_STICKY
    }

    companion object {
        private const val KANAL = "downloads"
        private const val NUMMER = 2
        private var laeuft = false

        private fun nachricht(k: Context, titel: String, anteil: Double): Notification {
            val verwalter = k.getSystemService(NotificationManager::class.java)
            if (verwalter.getNotificationChannel(KANAL) == null) {
                verwalter.createNotificationChannel(NotificationChannel(KANAL, "Downloads", NotificationManager.IMPORTANCE_LOW))
            }
            val oeffnen = PendingIntent.getActivity(k, 1, Intent(k, MainActivity::class.java),
                                                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            return Notification.Builder(k, KANAL)
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle(titel)
                .setProgress(1000, (anteil.coerceAtLeast(0.0) * 1000).toInt(), anteil < 0)
                .setContentIntent(oeffnen)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .build()
        }

        fun an(k: Context, titel: String, anteil: Double?) {
            // Aus dem Hintergrund darf ein Vordergrunddienst nicht immer starten; dann laeuft der Download trotzdem.
            runCatching {
                k.startForegroundService(Intent(k, DownloadDienst::class.java)
                    .putExtra("titel", titel).putExtra("anteil", anteil ?: -1.0))
                laeuft = true
            }
        }

        fun melden(k: Context, titel: String, anteil: Double?) {
            if (!laeuft) return
            runCatching { k.getSystemService(NotificationManager::class.java).notify(NUMMER, nachricht(k, titel, anteil ?: -1.0)) }
        }

        fun aus(k: Context) {
            if (!laeuft) return
            laeuft = false
            runCatching { k.stopService(Intent(k, DownloadDienst::class.java)) }
        }
    }
}
