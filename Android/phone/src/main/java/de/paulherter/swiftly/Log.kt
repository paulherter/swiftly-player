package de.paulherter.swiftly

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.util.Log
import androidx.core.content.FileProvider
import de.paulherter.swiftly.core.Kern
import java.io.File
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URI
import java.time.Instant
import kotlin.concurrent.thread

/**
 * The app log: logcat under "Swiftly" plus the buffer the user shares from (`LogRing` in
 * the package, mirrors iOS). Every line that used to go only to logcat goes through here;
 * redaction happens in the core when a line is added.
 */
object AppLog {
    fun writeOut(text: String) {
        Log.i("Swiftly", text)
        runCatching { Kern.logAppend(text) }
    }
}

/**
 * "Share log": the last hour as a text file. Mirrors `LogFile`
 * (Sources/Shared/LogShare.swift): header with version, system and time, then the lines
 * from the buffer. For errors that only occur on a user's device. The server address stays in,
 * since a network error is unreadable without it.
 *
 * VLC warnings come from the app's own logcat (libVLC writes there under "VLC"; an app can
 * only read its own lines) and are redacted with the same rule. Counterpart of
 * `VLCLogLevel.warning` on Apple.
 */
object LogFile {
    fun distribute(context: Context) {
        val rows = mutableListOf(
            "Swiftly ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",
            "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT}) · ${Build.MANUFACTURER} ${Build.MODEL}",
            "Stand ${Instant.now()}",
            "",
        )
        val excerpt = runCatching { Kern.logExcerpt(3600.0) }.getOrDefault("")
        rows += if (excerpt.isBlank())
            listOf("(no lines in the last hour — reproduce the problem first, then share without closing the app)")
        else excerpt.lines()
        val vlc = vlcRows()
        if (vlc.isNotEmpty()) { rows += ""; rows += "--- VLC ---"; rows += vlc }
        val folder = File(context.cacheDir, "protokoll").apply { mkdirs() }
        val file = File(folder, "Swiftly-Protokoll.txt")
        try {
            file.writeText(rows.joinToString("\n"))
        } catch (e: Exception) {
            AppLog.writeOut("[Protokoll] Datei ließ sich nicht schreiben: ${e.message}")
            return
        }
        val address = FileProvider.getUriForFile(context, "${context.packageName}.protokoll", file)
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_STREAM, address)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(Intent.createChooser(intent, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    /** VLC warnings and errors of the last hour from the app's own logcat, redacted. */
    private fun vlcRows(): List<String> = runCatching {
        val since = System.currentTimeMillis() - 3600_000
        val p = ProcessBuilder("logcat", "-d", "-v", "time", "-T", "%.3f".format(java.util.Locale.ROOT, since / 1000.0), "VLC:W", "*:S")
            .redirectErrorStream(true).start()
        val text = p.inputStream.bufferedReader().readText()
        p.waitFor()
        text.lines().filter { it.isNotBlank() && !it.startsWith("-----") }.takeLast(2000)
            .map { Kern.logRedact(it) }
    }.getOrDefault(emptyList())
}

/**
 * How the device sees the server address, logged at every start. Mirrors `NetworkProbe`
 * (Sources/Shared): images load through OkHttp, the stream through VLC's own sockets. If one
 * works and the other does not, the difference lies in between, and it only shows on the user's
 * network. The probe logs which addresses resolve, what the socket says (with its own timeout;
 * VLC waits without one) and which route the device is on (VPN, Wi-Fi, mobile).
 */
object NetworkProbe {
    fun start(context: Context, address: String) {
        val u = runCatching { URI(address) }.getOrNull() ?: return
        val schema = u.scheme?.lowercase() ?: return
        if (schema != "http" && schema != "https") return
        val host = u.host ?: return
        val port = if (u.port > 0) u.port else if (schema == "https") 443 else 80
        AppLog.writeOut("[Netzprobe] Strom: ${Kern.logRedact(address)}")
        thread(name = "Netzprobe", isDaemon = true) {
            leg(context)
            val addresses = try { InetAddress.getAllByName(host).toList() } catch (e: Exception) {
                AppLog.writeOut("[Netzprobe] $host: nicht aufgelöst (${e.javaClass.simpleName}: ${e.message})"); return@thread
            }
            AppLog.writeOut("[Netzprobe] $host → ${addresses.joinToString { it.hostAddress ?: "?" }}")
            val first = addresses.firstOrNull() ?: return@thread
            val start = System.nanoTime()
            try {
                Socket().use { it.connect(InetSocketAddress(first, port), 8000) }
                AppLog.writeOut("[Netzprobe] ${first.hostAddress}:$port verbunden in ${(System.nanoTime() - start) / 1_000_000} ms")
            } catch (e: Exception) {
                AppLog.writeOut("[Netzprobe] ${first.hostAddress}:$port: ${e.javaClass.simpleName}: ${e.message} nach ${(System.nanoTime() - start) / 1_000_000} ms")
            }
        }
    }

    private fun leg(context: Context) {
        val cm = context.getSystemService(ConnectivityManager::class.java) ?: return
        val network = cm.activeNetwork
        val f = network?.let { cm.getNetworkCapabilities(it) }
        if (f == null) { AppLog.writeOut("[Netzprobe] Strecke: kein Netz"); return }
        val kinds = buildList {
            if (f.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) add("VPN")
            if (f.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) add("WLAN")
            if (f.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) add("Ethernet")
            if (f.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) add("Mobilfunk")
        }
        val cut = cm.getLinkProperties(network)?.interfaceName ?: "?"
        AppLog.writeOut("[Netzprobe] Strecke: ${kinds.joinToString("+").ifEmpty { "?" }} über $cut")
    }
}
