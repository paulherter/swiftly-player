package de.paulherter.swiftly

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.util.Log
import androidx.core.content.FileProvider
import de.paulherter.swiftly.kern.Kern
import java.io.File
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URI
import java.time.Instant
import kotlin.concurrent.thread

/**
 * **Das Protokoll der App** — logcat unter „Swiftly" und der Speicher, aus dem der Nutzer es teilt
 * (`Protokollring` im Paket, Vorlage 40cb4ae9). Jede Zeile, die bisher nur ins logcat ging, geht hier durch;
 * geschwaerzt wird im Kern beim Eintragen.
 */
object Protokoll {
    fun schreib(text: String) {
        Log.i("Swiftly", text)
        runCatching { Kern.protokollAnhaengen(text) }
    }
}

/**
 * **„Protokoll teilen" — die letzte Stunde als Textdatei.** Vorlage `Protokolldatei` (Sources/Shared/
 * Protokollteilen.swift): Kopf mit Fassung, System und Zeit, dann die Zeilen aus dem Speicher. Fuer Fehler,
 * die nur beim Nutzer auftreten: nachstellen, teilen, meist in den Discord. Die Serveradresse bleibt stehen —
 * ohne sie laesst sich ein Netzfehler nicht lesen.
 *
 * **VLCs Warnungen** holt die Datei aus dem eigenen logcat (libVLC schreibt dort unter „VLC"; eine App liest
 * nur ihre eigenen Zeilen) und schwaerzt sie mit derselben Regel — Gegenstueck zu `VLCLogLevel.warning` auf Apple.
 */
object Protokolldatei {
    fun teilen(kontext: Context) {
        val zeilen = mutableListOf(
            "Swiftly ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",
            "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT}) · ${Build.MANUFACTURER} ${Build.MODEL}",
            "Stand ${Instant.now()}",
            "",
        )
        val auszug = runCatching { Kern.protokollAuszug(3600.0) }.getOrDefault("")
        zeilen += if (auszug.isBlank())
            listOf("(no lines in the last hour — reproduce the problem first, then share without closing the app)")
        else auszug.lines()
        val vlc = vlcZeilen()
        if (vlc.isNotEmpty()) { zeilen += ""; zeilen += "--- VLC ---"; zeilen += vlc }
        val ordner = File(kontext.cacheDir, "protokoll").apply { mkdirs() }
        val datei = File(ordner, "Swiftly-Protokoll.txt")
        try {
            datei.writeText(zeilen.joinToString("\n"))
        } catch (e: Exception) {
            Protokoll.schreib("[Protokoll] Datei ließ sich nicht schreiben: ${e.message}")
            return
        }
        val adresse = FileProvider.getUriForFile(kontext, "${kontext.packageName}.protokoll", datei)
        val absicht = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_STREAM, adresse)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        kontext.startActivity(Intent.createChooser(absicht, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    /** VLCs Warnungen und Fehler der letzten Stunde aus dem eigenen logcat, geschwaerzt. */
    private fun vlcZeilen(): List<String> = runCatching {
        val seit = System.currentTimeMillis() - 3600_000
        val p = ProcessBuilder("logcat", "-d", "-v", "time", "-T", "%.3f".format(java.util.Locale.ROOT, seit / 1000.0), "VLC:W", "*:S")
            .redirectErrorStream(true).start()
        val text = p.inputStream.bufferedReader().readText()
        p.waitFor()
        text.lines().filter { it.isNotBlank() && !it.startsWith("-----") }.takeLast(2000)
            .map { Kern.protokollSchwaerzen(it) }
    }.getOrDefault(emptyList())
}

/**
 * **Wie das Geraet die Serveradresse sieht — ins Protokoll, bei jedem Start.** Vorlage `Netzprobe`
 * (Sources/Shared): Bilder laden ueber OkHttp, der Strom ueber VLCs eigene Sockets. Geht das eine und das
 * andere nicht, liegt der Unterschied dazwischen — und zeigt sich nur im Netz des Nutzers. Die Probe schreibt,
 * **welche Adressen** herauskommen, **was der Socket sagt** (mit eigener Frist; VLC wartet ohne) und **ueber
 * welche Strecke** das Geraet gerade geht (VPN, WLAN, Mobilfunk).
 */
object Netzprobe {
    fun starten(kontext: Context, adresse: String) {
        val u = runCatching { URI(adresse) }.getOrNull() ?: return
        val schema = u.scheme?.lowercase() ?: return
        if (schema != "http" && schema != "https") return
        val host = u.host ?: return
        val port = if (u.port > 0) u.port else if (schema == "https") 443 else 80
        Protokoll.schreib("[Netzprobe] Strom: ${Kern.protokollSchwaerzen(adresse)}")
        thread(name = "Netzprobe", isDaemon = true) {
            strecke(kontext)
            val adressen = try { InetAddress.getAllByName(host).toList() } catch (e: Exception) {
                Protokoll.schreib("[Netzprobe] $host: nicht aufgelöst (${e.javaClass.simpleName}: ${e.message})"); return@thread
            }
            Protokoll.schreib("[Netzprobe] $host → ${adressen.joinToString { it.hostAddress ?: "?" }}")
            val erste = adressen.firstOrNull() ?: return@thread
            val start = System.nanoTime()
            try {
                Socket().use { it.connect(InetSocketAddress(erste, port), 8000) }
                Protokoll.schreib("[Netzprobe] ${erste.hostAddress}:$port verbunden in ${(System.nanoTime() - start) / 1_000_000} ms")
            } catch (e: Exception) {
                Protokoll.schreib("[Netzprobe] ${erste.hostAddress}:$port: ${e.javaClass.simpleName}: ${e.message} nach ${(System.nanoTime() - start) / 1_000_000} ms")
            }
        }
    }

    private fun strecke(kontext: Context) {
        val cm = kontext.getSystemService(ConnectivityManager::class.java) ?: return
        val netz = cm.activeNetwork
        val f = netz?.let { cm.getNetworkCapabilities(it) }
        if (f == null) { Protokoll.schreib("[Netzprobe] Strecke: kein Netz"); return }
        val arten = buildList {
            if (f.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) add("VPN")
            if (f.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) add("WLAN")
            if (f.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) add("Ethernet")
            if (f.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) add("Mobilfunk")
        }
        val schnitt = cm.getLinkProperties(netz)?.interfaceName ?: "?"
        Protokoll.schreib("[Netzprobe] Strecke: ${arten.joinToString("+").ifEmpty { "?" }} über $schnitt")
    }
}
