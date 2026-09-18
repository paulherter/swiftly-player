package de.paulherter.swiftly

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.ActivityInfo
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.net.Uri
import android.os.SystemClock
import android.view.WindowManager
import androidx.activity.compose.BackHandler
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.animation.core.LinearEasing
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.VisibilityThreshold
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeOut
import androidx.compose.animation.fadeIn
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import de.paulherter.swiftly.gemeinsam.Bewegung
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.uebersetzt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import de.paulherter.swiftly.kern.Kern
import android.content.pm.PackageManager
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import coil3.SingletonImageLoader
import coil3.request.ImageRequest
import coil3.request.SuccessResult
import coil3.request.allowHardware
import coil3.toBitmap
import org.videolan.libvlc.LibVLC
import org.videolan.libvlc.Media
import org.videolan.libvlc.MediaPlayer
import org.videolan.libvlc.interfaces.IMedia
import org.videolan.libvlc.util.VLCVideoLayout
import java.text.NumberFormat
import android.content.Intent
import androidx.core.content.ContextCompat
import androidx.compose.foundation.border
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.text.font.FontFamily
import java.util.Locale
import kotlin.math.roundToInt

/** Was abgespielt werden soll und ab wo — `Abspielwunsch` auf iOS. `ab == null` heisst: von vorn. */
data class Abspielwunsch(val id: String, val ab: Double?)

/** Antwort von `Kern.wiedergabeOeffnen` — Adresse und die Zeilen fuer den Fuss. */
data class Spielplan(val url: String, val lossless: Boolean, val methode: String, val titel: String,
                     val untertitel: String, val naechste: Boolean,
                     val serie: String? = null, val kuerzel: String? = null, val bild: String? = null,
                     val dateizeile: String? = null)

/** Handwahl je Serie oder Film — dieselben Schluessel wie `Spurgedaechtnis` im Paket. */
private const val TON_JE_TITEL = "tonJeTitel"
private const val UT_JE_TITEL = "utJeTitel"

internal fun spielplanLesen(json: String) = JSONObject(json).let { o ->
    Spielplan(o.getString("url"), o.optBoolean("lossless"), o.optString("methode"), o.optString("titel"),
              o.optString("untertitel"), o.optBoolean("naechste"),
              o.optString("serie").takeIf { !o.isNull("serie") }, o.optString("kuerzel").takeIf { !o.isNull("kuerzel") },
              o.optString("bild").takeIf { !o.isNull("bild") },
              o.optString("dateizeile").takeIf { !o.isNull("dateizeile") })
}

/** 1:23:45 oder 23:45 — Ziffern gleich breit, damit die Zeile beim Laufen nicht zittert. Auch von `tv/TvPlayer.kt` benutzt. */
internal fun zeitText(sekunden: Double): String {
    val s = sekunden.coerceAtLeast(0.0).toLong()
    val h = s / 3600
    val m = (s % 3600) / 60
    val r = s % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, r) else "%d:%02d".format(m, r)
}

/** Das Spulzeichen zur eingestellten Spanne — fuer 15 und 60 gibt es kein eigenes. */
private fun spulzeichen(zurueck: Boolean, sekunden: Int): ImageVector = when (sekunden) {
    5 -> if (zurueck) Icons.Filled.Replay5 else Icons.Filled.Forward5
    10 -> if (zurueck) Icons.Filled.Replay10 else Icons.Filled.Forward10
    30 -> if (zurueck) Icons.Filled.Replay30 else Icons.Filled.Forward30
    else -> if (zurueck) Icons.Filled.Replay else Icons.Filled.FastForward
}

/** Auch von `tv/TvPlayer.kt` benutzt (Tempokarten im Wiedergabeblatt-Gegenstueck). */
internal fun tempoText(wert: Float) = NumberFormat.getInstance().format(wert) + "×"

internal tailrec fun Context.aktivitaet(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.aktivitaet()
    else -> null
}

/**
 * Die Wiedergabe-**Mechanik** ohne Bild: VLC aufbauen, oeffnen, den Takt fragen (`Kern.wiedergabeTakt`),
 * Fernbefehle anwenden, Spuren setzen, an den Server melden, die Mediensitzung fuehren.
 *
 * **Herausgezogen aus dem, was vorher als Closures ueber `remember`-Zustand in `PlayerSeite` lag** —
 * derselbe Umbau wie tvOS' `Schaltwerk`, nur weiter gefasst: dort blieb nur das Umschalten in der
 * Klasse, hier auch VLC-Aufbau, Takt und Meldungen, weil sowohl `PlayerSeite` (Telefon) als auch
 * `tv/TvPlayer.kt` (Fernseher, Vorlage `PlayerScreen` in `Sources/tvOS/PlayerScreen.swift`) sie
 * brauchen und die Regeln nicht zweimal stehen sollen. Reine Bildschirm-Angelegenheiten — Sichtbarkeit
 * der Steuerung, Wischgesten, welches Blatt gerade offen ist — bleiben in den Composables: das ist
 * genau der Teil, in dem sich Telefon und Fernseher unterscheiden duerfen (Eingabeart, VERHALTEN F).
 */
class Spielwerk(
    private val app: SwiftlyAnwendung,
    private val kontext: Context,
    private val lauf: CoroutineScope,
    private val ruck: (Ruck) -> Unit = {},
) {
    val vlc = LibVLC(kontext, arrayListOf("--no-drop-late-frames", "--no-skip-frames"))
    val spieler = MediaPlayer(vlc)
    val sitzung = MediaSession(kontext, "Swiftly")

    var plan by mutableStateOf<Spielplan?>(null); private set
    var laeuft by mutableStateOf(false); private set
    var position by mutableDoubleStateOf(0.0); private set
    var dauer by mutableDoubleStateOf(0.0); private set
    var bildFrei by mutableStateOf(false); private set
    var angebotArt by mutableStateOf("keiner"); private set
    var angebotNach by mutableStateOf<Double?>(null); private set
    var angebotText by mutableStateOf(""); private set
    /**
     * **Die Einblendung ohne Steuerung** (`Angebotsebene` im Paket, Stufe 3): `nichts`, `knopf` oder
     * `karte` — bei `karte` laeuft der Countdown, `countdown` von 0 bis 1.
     */
    var einblendung by mutableStateOf("nichts"); private set
    var countdown by mutableDoubleStateOf(0.0); private set
    var countdownRest by mutableIntStateOf(0); private set
    var countdownLaenge by mutableDoubleStateOf(7.0); private set
    /**
     * Setzt die Oberflaeche mit der **gewollten** Sichtbarkeit der Steuerung (`Angebotsebene.steuerung`):
     * Oeffnen sagt die Karte „Naechste Folge" ab, Auf und Zu schickt den Ueberspringen-Knopf in die Steuerung.
     */
    fun steuerungGeaendert(offen: Boolean) {
        app.kern.steuerungGeaendert(offen)
        if (offen && einblendung == "karte") einblendung = "nichts"
    }
    var hinweis by mutableStateOf<String?>(null)
    var technikFest by mutableStateOf<List<Pair<String, String>>>(emptyList()); private set
    var technikLive by mutableStateOf<JSONObject?>(null); private set
    var bildfuellend by mutableStateOf(app.ablage.merkwert("bildfuellend") == "1"); private set
    /**
     * **Ob VLC gerade nachlaedt, obwohl es laufen sollte** — Gegenstueck zu `stockt` in
     * `Sources/tvOS/PlayerScreen.swift`. Dort fehlt libVLCs `Buffering`-Ereignis (VLCKit auf Apple
     * hat es nicht), deshalb misst tvOS die stehende Uhr; hier meldet der Player den Fuellstand
     * selbst (`MediaPlayer.Event.Buffering`, 0…100), das ist genauer und braucht keine Kern-Daten.
     */
    var puffert by mutableStateOf(false); private set
    /**
     * **Ein Folgenwechsel laeuft** — der Riegel aus `Folgenwechsel` im Paket, hier gespiegelt fuer den
     * Ladering und damit ein zweiter Druck gar nicht erst in den Kern geht (Audit T2-M1).
     */
    var wechselt by mutableStateOf(false); private set
    var tempo by mutableFloatStateOf(1f); private set
    var schlafzeit by mutableIntStateOf(0); private set
    /** Waehrend am Regler gezogen wird, ueberschreibt der Takt die Stelle nicht — nur das Telefon kennt das. */
    var amSchieben = false

    private val zeigtBild = booleanArrayOf(false)
    private val ende = booleanArrayOf(false)
    /** Schon mit „gestoppt" gemeldet — sonst meldet das Abraeumen es (weggewischtes kleines Fenster). */
    private val beendet = booleanArrayOf(false)
    private var schlafJob: kotlinx.coroutines.Job? = null
    private val debugBau = (kontext.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0

    val zurueckS: Int get() = app.einstellungen.zurueckSekunden
    val vorS: Int get() = app.einstellungen.vorSekunden

    fun installiereEreignisListener() {
        spieler.setEventListener { e ->
            when (e.type) {
                // **Pause und Weiter melden, wenn VLC sie meldet** — nicht im Druck, da stand noch der
                // Zustand von davor (Audit T1-N1, wie `VLCPlayerView.laeuftGemeldet`). Einmal je Wechsel
                // und nur fuer einen gestarteten Titel entscheidet der Kern; `Stopped` meldet nichts,
                // das Ende geht ueber `wiedergabeBeenden`.
                MediaPlayer.Event.Playing -> { laeuft = true; app.kern.laufzustandGemeldet(true, stelleJetzt()) }
                MediaPlayer.Event.Paused -> { laeuft = false; app.kern.laufzustandGemeldet(false, stelleJetzt()) }
                MediaPlayer.Event.Stopped -> laeuft = false
                MediaPlayer.Event.Vout -> if (e.voutCount > 0) zeigtBild[0] = true
                MediaPlayer.Event.Buffering -> puffert = e.buffering < 100f
                MediaPlayer.Event.EndReached -> { laeuft = false; ende[0] = true }
                MediaPlayer.Event.EncounteredError -> hinweis = uebersetzt("Die Folge konnte nicht geladen werden.")
                MediaPlayer.Event.ESAdded -> if (e.esChangedType == IMedia.Track.Type.Text) untertitelspurNeu(e.esChangedID)
            }
        }
    }

    private fun stelleJetzt(): Double = (spieler.time / 1000.0).takeIf { it > 0 } ?: position

    /**
     * **Die Activity geht in den Hintergrund** (Audit T3 #5) — den Stand sofort melden, mit dem
     * wirklichen Laufzustand: Android haelt die Wiedergabe dabei nicht an (Bild im Bild, Dienst).
     */
    fun hintergrundMelden() = app.kern.hintergrundMelden(stelleJetzt(), !spieler.isPlaying)

    /** VLC und die Zeichenflaeche abbauen — Gegenstueck zu `installiereEreignisListener`. */
    fun aufraeumen() {
        if (!beendet[0]) app.wiedergabeBeenden((spieler.time / 1000.0).coerceAtLeast(0.0))
        spieler.stop()
        spieler.detachViews()
        spieler.release()
        vlc.release()
    }

    fun installiereSitzung() {
        sitzung.setCallback(object : MediaSession.Callback() {
            override fun onPlay() { if (!spieler.isPlaying) umschalten() }
            override fun onPause() { if (spieler.isPlaying) umschalten() }
            override fun onSeekTo(pos: Long) { springe(pos / 1000.0) }
            override fun onFastForward() { springe(position + vorS) }
            override fun onRewind() { springe(position - zurueckS) }
            override fun onSkipToNext() { if (plan?.naechste == true) lauf.launch { naechsteFolge() } }
        })
        sitzung.isActive = true
    }

    fun sitzungAufraeumen() {
        kontext.stopService(Intent(kontext, WiedergabeDienst::class.java))
        app.medienToken = null
        sitzung.isActive = false
        sitzung.release()
    }

    private fun sitzungMelden() {
        var aktionen = PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_PLAY_PAUSE or
            PlaybackState.ACTION_SEEK_TO or PlaybackState.ACTION_FAST_FORWARD or PlaybackState.ACTION_REWIND
        // „Nächste" nur, wenn es eine gibt; „vorige" nie — grau ist ehrlicher als ins Leere.
        if (plan?.naechste == true) aktionen = aktionen or PlaybackState.ACTION_SKIP_TO_NEXT
        sitzung.setPlaybackState(PlaybackState.Builder().setActions(aktionen)
            .setState(if (laeuft) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED, (position * 1000).toLong(),
                      if (laeuft) tempo else 0f).build())
    }

    /** Titel, Serie, Folge, Laenge und das Standbild fuer Benachrichtigung und Sperrbildschirm. */
    suspend fun metadatenAktualisieren() {
        val p = plan ?: return
        fun metadaten(bild: android.graphics.Bitmap?) = MediaMetadata.Builder().apply {
            putString(MediaMetadata.METADATA_KEY_TITLE, p.titel)
            p.serie?.let { putString(MediaMetadata.METADATA_KEY_ALBUM, it); p.kuerzel?.let { k -> putString(MediaMetadata.METADATA_KEY_ARTIST, k) } }
            if (dauer > 0) putLong(MediaMetadata.METADATA_KEY_DURATION, (dauer * 1000).toLong())
            bild?.let { putBitmap(MediaMetadata.METADATA_KEY_ART, it) }
        }.build()
        sitzung.setMetadata(metadaten(null))
        // Benachrichtigung und Sperrbildschirm — der Dienst liest Titel und Knoepfe aus der Sitzung.
        app.medienToken = sitzung.sessionToken
        runCatching {
            ContextCompat.startForegroundService(kontext, Intent(kontext, WiedergabeDienst::class.java)
                .putExtra("titel", p.titel).putExtra("untertitel", p.untertitel))
        }
        val adresse = p.bild ?: return
        val bild = runCatching {
            (SingletonImageLoader.get(kontext).execute(ImageRequest.Builder(kontext).data(adresse).size(600).allowHardware(false).build())
                as? SuccessResult)?.image?.toBitmap()
        }.getOrNull()
        sitzung.setMetadata(metadaten(bild))
    }

    fun starte(neu: Spielplan, ab: Double?) {
        plan = neu
        bildFrei = false
        zeigtBild[0] = false
        puffert = false
        ende[0] = false
        position = ab ?: 0.0
        ab?.takeIf { it > 1 }?.let { app.kern.wiedergabeStelle(it) }
        dateienVorbereiten()
        val media = Media(vlc, Uri.parse(neu.url))
        // Faellt die Verbindung kurz aus, faengt VLC sie wieder auf, statt das Ende zu melden.
        media.addOption(":http-reconnect")
        // **Einsteigen mit `:start-time`.** Auf iOS verworfen, weil VLCKit 4 damit die Zeitleiste
        // verschob und ein falsches Ende meldete; libVLC 3 kennt das nicht, und die `anlaufruhe`
        // aus `Folgenende` faengt ein falsches Ende in den ersten Sekunden ohnehin ab.
        ab?.takeIf { it > 1 }?.let { media.addOption(":start-time=$it") }
        // Der Puffer aus den Einstellungen; „Normal" laesst VLCs Vorgabe stehen.
        JSONArray(Kern.pufferstufen()).let { a -> (0 until a.length()).map { a.getJSONObject(it) } }
            .firstOrNull { it.getString("wert") == app.einstellungen.pufferstufe }
            ?.takeIf { !it.isNull("netz") }?.let { media.addOption(":network-caching=${it.getInt("netz")}") }
        spieler.media = media
        media.release()
        spieler.videoScale = if (bildfuellend) MediaPlayer.ScaleType.SURFACE_FIT_SCREEN else MediaPlayer.ScaleType.SURFACE_BEST_FIT
        digitalenTonAnwenden()
        spieler.play()
    }

    /**
     * **Bitstream-Passthrough, wenn der Ausgang es meldet.** Vorlage: der Auszug in
     * `Sources/Shared/VLCPlayer.swift` (`sitzung.currentRoute.outputs`, `maximumOutputNumberOfChannels`)
     * — dort wird beim Oeffnen nur protokolliert, wieviele Kanaele der Ausgang fuehrt, weil
     * `AVAudioSession` die Weiterleitung an HDMI/AirPlay von selbst uebernimmt. libVLC fuer Android
     * tut das nicht von selbst: `forceAudioDigitalEncodings` muss ausdruecklich sagen, welche Formate
     * der angeschlossene Fernseher oder AVR roh durchreichen kann (`AudioDeviceInfo.encodings`),
     * sonst mischt VLC AC3/DTS/TrueHD im Client auf PCM herunter, obwohl die Gegenstelle es koennte.
     *
     * Ohne passenden Ausgang (Telefonlautsprecher, die meisten Bluetooth-Kopfhoerer) liefert die
     * Geraeteliste keine der gesuchten Kodierungen — dann bleibt es unveraendert beim bisherigen
     * Downmix, das Handy-Verhalten aendert sich also nicht.
     */
    private fun digitalenTonAnwenden() {
        val manager = kontext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        val bekannt = buildSet {
            add(AudioFormat.ENCODING_AC3); add(AudioFormat.ENCODING_E_AC3)
            add(AudioFormat.ENCODING_DTS); add(AudioFormat.ENCODING_DTS_HD)
            if (android.os.Build.VERSION.SDK_INT >= 32) add(AudioFormat.ENCODING_DOLBY_TRUEHD)
        }
        val digitaleAusgaenge = buildSet {
            add(AudioDeviceInfo.TYPE_HDMI); add(AudioDeviceInfo.TYPE_HDMI_ARC); add(AudioDeviceInfo.TYPE_LINE_DIGITAL)
            if (android.os.Build.VERSION.SDK_INT >= 33) add(AudioDeviceInfo.TYPE_HDMI_EARC)
        }
        val kodierungen = manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            .filter { it.type in digitaleAusgaenge }
            .flatMap { it.encodings.toList() }
            .filter { it in bekannt }
            .distinct()
        if (kodierungen.isEmpty()) return
        spieler.setAudioDigitalOutputEnabled(true)
        spieler.forceAudioDigitalEncodings(kodierungen.toIntArray())
    }

    fun beenden(schliessen: () -> Unit) {
        // Die Stelle vor dem Anhalten lesen — VLC setzt seine Uhr beim Anhalten zurueck.
        val stelle = (spieler.time / 1000.0).coerceAtLeast(0.0)
        beendet[0] = true
        app.fertigGeschaut(stelle, dauer)
        app.wiedergabeBeenden(stelle)
        spieler.stop()
        schliessen()
    }

    suspend fun naechsteFolge() = wechsle("", "Nächste Folge konnte nicht geladen werden.")

    /**
     * **Der Angebotsknopf wurde gedrueckt** — in der Einblendung oder in der Steuerung. Springen hinter
     * den Abschnitt oder zur naechsten Folge ueber den Stufe-1-Wechsel. `false`, wenn nichts angeboten ist.
     */
    fun angebotAusfuehren(): Boolean {
        if (angebotArt == "keiner" || angebotText.isEmpty()) return false
        app.kern.angebotGedrueckt()
        einblendung = "nichts"
        val nach = angebotNach
        if (angebotArt == "ueberspringen" && nach != null) springe(nach) else lauf.launch { naechsteFolge() }
        return true
    }

    /** Zurueck oder eine Richtungstaste: nur die Einblendung zu, ein Countdown ist abgesagt. `true`, wenn etwas offen war. */
    fun angebotSchliessen(): Boolean {
        if (einblendung == "nichts") return false
        val zu = app.kern.angebotSchliessen()
        einblendung = "nichts"
        return zu
    }

    /**
     * Im laufenden Player zu einer selbst gewaehlten Folge wechseln — Vorlage `wechsleZu` in
     * `Sources/tvOS/PlayerScreen.swift` (aus dem `Folgenblatt`). Derselbe Ablauf wie `naechsteFolge`,
     * nur mit einer freien Kennung statt der vorgemerkten naechsten Folge.
     */
    suspend fun wechsleZu(id: String) = wechsle(id, "Die Folge konnte nicht geladen werden.")

    /**
     * **Der Ablauf steht im Paket** (`Folgenwechsel`, ueber `Kern.folgeWechseln`): Riegel, Stopp und
     * Plan nebeneinander, Abbruch beim Schliessen, Stopp genau einmal — wie iOS, tvOS und macOS.
     *
     * - **Die alte Folge laeuft weiter, bis die neue da ist.** Vorher hielt `spieler.stop()` sie vor
     *   dem Abruf an; scheiterte er, stand der Player schwarz und ohne Ausweg (Audit T2-M2). Jetzt
     *   kommt der Hinweis ueber `fehlertext`, und die alte Folge bleibt.
     * - Geschlossen, waehrend der Kern plante: `abgebrochen`, nichts startet. Kam `gewechselt` erst
     *   nach dem Schliessen an, startet ebenfalls nichts — den Stopp der neuen Folge hat das
     *   Schliessen schon gemeldet.
     */
    private suspend fun wechsle(id: String, fehlschlag: String) {
        if (wechselt || beendet[0]) return
        wechselt = true
        angebotArt = "keiner"
        einblendung = "nichts"
        val stelle = (spieler.time / 1000.0).coerceAtLeast(0.0)
        app.fertigGeschaut(stelle, dauer)
        try {
            val antwort = JSONObject(withContext(Dispatchers.IO) { app.kern.folgeWechseln(id, stelle).await() })
            antwort.feldText("nachmeldung")?.let { app.nachmeldungAblegen(it) }
            app.protokollSchreiben()
            when (antwort.optString("ergebnis")) {
                "gewechselt" -> {
                    val neu = antwort.feldText("spielplan")
                    if (neu != null && !beendet[0]) {
                        spieler.stop()
                        starte(spielplanLesen(neu), null)
                    }
                }
                "gescheitert" -> hinweis = fehlertext(kontext, Exception(antwort.feldText("fehler") ?: uebersetzt(fehlschlag)))
            }
        } catch (e: CancellationException) { throw e } catch (e: Exception) {
            hinweis = fehlertext(kontext, e)
        } finally {
            wechselt = false
        }
    }

    fun springe(ziel: Double) {
        val z = if (dauer > 0) ziel.coerceIn(0.0, dauer) else ziel.coerceAtLeast(0.0)
        spieler.time = (z * 1000).toLong()
        position = z
        // Sofort mit der Zielstelle, eingereiht und nicht abgewartet — auch „Springen auf" vom Dashboard.
        // Der Kern haelt die Zielstelle, bis VLC dort ist, und das Angebot folgt ihr sofort (Bug 17.09.2026).
        val antwort = JSONObject(app.kern.sprungGemeldet(z))
        if (antwort.has("position")) {
            position = antwort.getDouble("position")
            angebotUebernehmen(antwort)
        }
    }

    private fun angebotUebernehmen(antwort: JSONObject) {
        angebotArt = antwort.optString("angebot", "keiner")
        angebotNach = if (antwort.isNull("nach")) null else antwort.getDouble("nach")
        angebotText = antwort.optString("angebotstext")
        einblendung = antwort.optString("einblendung", "nichts")
        countdown = antwort.optDouble("countdown", 0.0)
        countdownRest = antwort.optInt("countdownRest", 0)
        countdownLaenge = antwort.optDouble("countdownLaenge", 7.0)
    }

    fun umschalten() {
        ruck(Ruck.Mittel)
        // Gemeldet wird aus VLCs `Playing`/`Paused` (`installiereEreignisListener`).
        if (spieler.isPlaying) spieler.pause() else spieler.play()
    }

    fun tempoSetzen(neu: Float) {
        tempo = neu
        spieler.rate = neu
    }

    fun bildfuellendSetzen(neu: Boolean) {
        bildfuellend = neu
        spieler.videoScale = if (neu) MediaPlayer.ScaleType.SURFACE_FIT_SCREEN else MediaPlayer.ScaleType.SURFACE_BEST_FIT
        app.ablage.merken("bildfuellend", if (neu) "1" else "0")
    }

    fun schlafzeitSetzen(minuten: Int) {
        schlafzeit = minuten
        schlafJob?.cancel()
        if (minuten <= 0) return
        schlafJob = lauf.launch {
            delay(minuten * 60_000L)
            spieler.pause()
            schlafzeit = 0
            hinweis = uebersetzt("Schlafzeit abgelaufen.")
        }
    }

    // Spuren (Audit 16.09., Stufe 4) — Vorlage `VLCPlayerView` in `Sources/Shared/VLCPlayer.swift`.
    // Entschieden wird im Kern ueber `Spurregel`/`Spurzuordnung`; hier nur libVLC.

    /** Eine externe Untertiteldatei der Folge: Jellyfin-Index, Adresse, MD5 der Adresse. */
    private class Untertiteldatei(val index: Long, val adresse: String, val merkmal: String)
    private val dateien = ArrayDeque<Untertiteldatei>()
    /** Die Datei, deren Spur gerade erwartet wird, seit wann, und welche Untertitelspuren es davor gab. */
    private var dateiLaedt: Untertiteldatei? = null
    private var dateiSeit = 0L
    private var spurenVorDatei: Set<Int> = emptySet()
    /**
     * **VLC-Spur-id → Kennung wie in libVLC 4** (`<md5 der Adresse>/spu/<n>`). libVLC 3 setzt den MD5
     * nicht vor die Spur; die Spur, die nach dem Anhaengen einer Datei neu auftaucht, ist ihre.
     */
    private val dateispuren = HashMap<Int, String>()
    private var spurenGewaehlt = false

    /** Je Folge neu: die Dateien aus dem Plan holen und ihr Merkmal an den Kern geben. Von der Platte keine. */
    private fun dateienVorbereiten() {
        dateien.clear(); dateiLaedt = null; dateispuren.clear(); spurenGewaehlt = false
        val liste = runCatching { JSONArray(app.kern.untertiteldateien()) }.getOrNull() ?: return
        for (i in 0 until liste.length()) {
            val o = liste.getJSONObject(i)
            val adresse = o.getString("adresse")
            val merkmal = java.security.MessageDigest.getInstance("MD5").digest(adresse.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }
            app.kern.untertitelmerkmalSetzen(o.getLong("index"), merkmal)
            dateien.addLast(Untertiteldatei(o.getLong("index"), adresse, merkmal))
        }
    }

    /**
     * **Externe Untertitel als Slave** (T1-H4), eine nach der anderen, erst nachdem die Spuren der Datei
     * gewaehlt sind — so ist die neue Spur eindeutig die der angehaengten Datei. `select = false`: ob
     * sie an ist, entscheidet `Spurregel`. Auf Apple haengen sie vor dem Oeffnen (VLCKit 4 kennt den MD5).
     */
    private fun naechsteDatei() {
        val d = dateien.removeFirstOrNull()
        dateiLaedt = d
        if (d == null) return
        spurenVorDatei = spieler.spuTracks?.map { it.id }?.toSet().orEmpty()
        dateiSeit = SystemClock.elapsedRealtime()
        val gehaengt = spieler.addSlave(IMedia.Slave.Type.Subtitle, Uri.parse(d.adresse), false)
        android.util.Log.i("Swiftly", "[Spuren] Datei ${d.index} angehaengt $gehaengt, Merkmal ${d.merkmal}")
        if (!gehaengt) naechsteDatei()
    }

    private fun untertitelspurNeu(id: Int) {
        val d = dateiLaedt
        if (d != null && id >= 0 && id !in spurenVorDatei && id !in dateispuren) {
            dateispuren[id] = "${d.merkmal}/spu/${dateispuren.values.count { it.startsWith(d.merkmal) }}"
            android.util.Log.i("Swiftly", "[Spuren] Datei ${d.index} ist Spur $id")
            naechsteDatei()
        }
        if (!spurenGewaehlt) return
        val gewaehlt = app.kern.offenenUntertitel(spurenJson(false)).toInt()
        if (gewaehlt >= 0) spieler.spuTrack = gewaehlt
        app.protokollSchreiben()
    }

    /** Kommt die Spur einer Datei nicht (Datei kaputt, Server weg), die naechste versuchen. */
    private fun dateiFrist() {
        if (dateiLaedt != null && SystemClock.elapsedRealtime() - dateiSeit > 8000) {
            android.util.Log.i("Swiftly", "[Spuren] Datei ${dateiLaedt?.index} kam nicht")
            naechsteDatei()
        }
    }

    /** Die Spuren einer Art als JSON fuer den Kern — mit Sprache, Codec und Kanaelen aus dem Medium, wo bekannt. */
    private fun spurenJson(ton: Boolean): String {
        val liste = (if (ton) spieler.audioTracks else spieler.spuTracks)?.filter { it.id >= 0 }.orEmpty()
        val angaben = spieler.media?.let { m ->
            try { (0 until m.trackCount).mapNotNull { m.getTrack(it) }.associateBy { it.id } } finally { m.release() }
        }.orEmpty()
        val a = JSONArray()
        for (t in liste) {
            val datei = dateispuren[t.id]
            val m = if (datei == null) angaben[t.id] else null
            a.put(JSONObject().apply {
                put("id", t.id)
                put("kennung", datei ?: ((if (ton) "audio/" else "spu/") + t.id))
                put("name", t.name.orEmpty())
                m?.language?.takeIf { it.isNotEmpty() }?.let { put("sprache", it) }
                m?.fourcc?.takeIf { it != 0 }?.let { put("fourcc", it) }
                (m as? IMedia.AudioTrack)?.channels?.takeIf { it > 0 }?.let { put("kanaele", it) }
            })
        }
        return a.toString()
    }

    /**
     * Ton und Untertitel nach `Spurregel`, einmal je Titel, sobald die Spuren bekannt sind: Handwahl je
     * Serie oder Film, Einstellungen, Server-Vorgaben, erzwungene Untertitel, sonst aus.
     */
    private fun sprachenAnwenden() {
        val e = app.einstellungen
        val antwort = JSONObject(app.kern.spurenWaehlen(
            spurenJson(true), spurenJson(false), spieler.audioTrack.toLong(), e.tonSprache, e.untertitelSprache,
            e.untertitelAutomatisch, app.ablage.merkwert(TON_JE_TITEL) ?: "{}", app.ablage.merkwert(UT_JE_TITEL) ?: "{}"))
        if (antwort.has("ton") && !antwort.isNull("ton")) spieler.audioTrack = antwort.getInt("ton")
        // Aktiv abschalten: die Datei bringt oft eine eigene Vorauswahl mit.
        spieler.spuTrack = antwort.optInt("untertitel", -1)
        spurenGewaehlt = true
        app.protokollSchreiben()
        naechsteDatei()
    }

    /** Von Hand gewaehlt: gilt sofort und fuer die ganze Serie (T1-M1). */
    fun tonVonHand(id: Int) {
        spieler.audioTrack = id
        app.ablage.merken(TON_JE_TITEL, app.kern.tonVonHand(spurenJson(true), id.toLong(), app.ablage.merkwert(TON_JE_TITEL) ?: "{}"))
    }

    /** `-1` heisst aus — auch das gilt fuer die ganze Serie, die naechste Folge bleibt ohne. */
    fun untertitelVonHand(id: Int) {
        spieler.spuTrack = id
        app.ablage.merken(UT_JE_TITEL, app.kern.untertitelVonHand(spurenJson(false), id.toLong(), app.ablage.merkwert(UT_JE_TITEL) ?: "{}"))
    }

    /** Ton „Deutsch · AAC · 5.1", Untertitel mit Format, „Erzwungen", „Datei" — statt libVLCs „Track 1 - [English]". */
    fun spurliste(ton: Boolean): List<Pair<Int, String>> {
        val namen = runCatching { JSONObject(app.kern.spurnamen(spurenJson(true), spurenJson(false))) }.getOrNull() ?: return emptyList()
        val a = namen.optJSONArray(if (ton) "ton" else "untertitel") ?: return emptyList()
        return (0 until a.length()).map { a.getJSONObject(it) }.map { o ->
            val teile = listOfNotNull(o.getString("text"),
                uebersetzt("Erzwungen").takeIf { o.optBoolean("erzwungen") },
                uebersetzt("Datei").takeIf { o.optBoolean("datei") })
            o.getInt("id") to teile.joinToString(" · ")
        }
    }

    /** Nur zaehlen, solange jemand hinsieht — derselbe Takt wie `Wiedergabetakt`, aus demselben Grund. */
    suspend fun technikschildTakt(aktiv: Boolean) {
        if (!aktiv || plan == null) { technikLive = null; return }
        technikFest = JSONArray(app.kern.technikFest()).let { a ->
            (0 until a.length()).map { a.getJSONObject(it).let { o ->
                (o.feldText("schluessel")?.let { k -> uebersetzt(k) + " " }.orEmpty() + o.getString("text")) to o.getString("art")
            } }
        }
        while (true) {
            val medium = spieler.media
            val werte = medium?.stats
            medium?.release()
            if (werte != null) {
                // VLC zaehlt in `int` — ueber 2 GB laeuft das ueber; vorzeichenlos gelesen stimmt es wieder.
                fun roh(x: Int) = x.toLong() and 0xFFFFFFFFL
                technikLive = JSONObject(app.kern.technikTakt(
                    roh(werte.readBytes), roh(werte.demuxReadBytes), roh(werte.displayedPictures), roh(werte.lostPictures),
                    roh(werte.decodedVideo), roh(werte.decodedAudio), roh(werte.playedAbuffers), roh(werte.lostAbuffers),
                    roh(werte.demuxCorrupted), roh(werte.demuxDiscontinuity), position, spieler.isPlaying))
            }
            delay(2000)
        }
    }

    /**
     * Oeffnen, dann der Takt — Vorlage `beobachten()` in `Sources/tvOS/PlayerScreen.swift`, hier mit
     * der Adressenwahl (Platte vor Server) und den Fernbefehlen aus `PlayerSeite`, die es davor schon gab.
     */
    suspend fun oeffnenUndTakt(wunsch: Abspielwunsch, schliessen: () -> Unit) {
        try {
            // **Von der Platte vor jedem Server** — im Flugzeug wartet sonst ein Zeitlimit.
            val platte = app.downloads.datei(wunsch.id)
            val posten = app.downloads.posten(wunsch.id)
            val antwort = if (platte != null && posten != null) {
                val bild = app.downloads.bildDatei(posten.id).takeIf { it.exists() }?.let { "file://" + it.absolutePath }.orEmpty()
                app.kern.wiedergabeVonDerPlatte(posten.json().toString(), platte.absolutePath, bild)
            } else withContext(Dispatchers.IO) { app.kern.wiedergabeOeffnen(wunsch.id).await() }
            starte(spielplanLesen(antwort), wunsch.ab)
        } catch (e: CancellationException) { throw e } catch (_: Exception) {
            hinweis = uebersetzt("Die Folge konnte nicht geladen werden.")
            return
        }
        var nurZeit = false
        while (true) {
            delay(250)
            // **Dazwischen nur die Zeit** (Vorlage iOS `beobachten`, Paul 17.09.2026): im halben Sekundentakt lief
            // sie nach dem Abspielen verzoegert an und zaehlte ungleichmaessig.
            nurZeit = !nurZeit
            if (nurZeit) {
                if (!wechselt && bildFrei) {
                    val z = app.kern.anzeigeZeit((spieler.time / 1000.0).coerceAtLeast(0.0), amSchieben)
                    if (z >= 0 && !amSchieben) position = z
                }
                continue
            }
            // **Befehle aus dem Dashboard oder von einem anderen Geraet** — der Socket legt sie ab.
            runCatching { JSONArray(app.kern.fernbefehle()) }.getOrNull()?.let { a ->
                for (i in 0 until a.length()) {
                    val b = a.getJSONObject(i)
                    when (b.optString("art")) {
                        "pause" -> if (spieler.isPlaying) umschalten()
                        "weiter" -> if (!spieler.isPlaying) umschalten()
                        "umschalten" -> umschalten()
                        "stopp" -> { beenden(schliessen); return }
                        "springen" -> springe(b.optDouble("wert", position))
                        "vor" -> springe(position + vorS)
                        "zurueck" -> springe(position - zurueckS)
                        "naechste" -> if (plan?.naechste == true) naechsteFolge()
                        // Vorlage: `case .vorige: break` in `PlayerScreen.swift` (tvOS/iOS) — ohne Wirkung.
                    }
                }
            }
            // Nur im Debug-Bau: `adb shell run-as de.paulherter.swiftly touch files/meldungen-haengen`
            // laesst jede Meldung 60 s haengen — ein Server, der nicht antwortet.
            if (debugBau) app.kern.meldungenHaengen(java.io.File(kontext.filesDir, "meldungen-haengen").exists())
            app.protokollSchreiben()
            // Waehrend des Wechsels schweigt der Takt; die Zeit des alten Stroms gehoerte sonst schon der neuen Folge.
            if (wechselt) continue
            val laenge = (spieler.length / 1000.0).coerceAtLeast(0.0)
            val antwort = JSONObject(app.kern.wiedergabeTakt(
                laenge, (spieler.time / 1000.0).coerceAtLeast(0.0), zeigtBild[0], spieler.isPlaying,
                spieler.audioTracksCount > 0, amSchieben))
            if (antwort.optBoolean("ladeschirmWeg")) bildFrei = true
            if (antwort.optBoolean("spurenAnwenden")) sprachenAnwenden()
            dateiFrist()
            // Nach einem Sprung liefert der Kern die Zielstelle, bis VLC dort ist.
            if (!amSchieben && antwort.has("position")) position = antwort.getDouble("position")
            dauer = laenge
            sitzungMelden()
            if (antwort.has("angebot")) angebotUebernehmen(antwort)
            // Ob automatisch, entscheidet der Kern (Karte mit Abspann, nicht abgesagt).
            if (antwort.optBoolean("weiterschalten")) naechsteFolge()
            else if (ende[0] && plan?.naechste != true) { beenden(schliessen); break }
        }
    }
}

/**
 * Vorlage: `PlayerScreen` in `Sources/iOS/PlayerScreen.swift`.
 *
 * **Die Entscheidungen stehen im Paket, hier nur Bild und Finger.** `Spielwerk` (oben) haelt VLC,
 * den Takt und die Meldungen — dasselbe Stueck, das auch der Fernseher benutzt (`tv/TvPlayer.kt`).
 *
 * - Die Steuerung kommt schnell (180 ms) und geht langsam (340 ms), nach 4 s Ruhe — nicht, wenn
 *   angehalten ist, geschoben wird oder ein Blatt offen ist.
 * - **Ein Tipp schaltet nach 260 ms**, ein zweiter davor springt und laesst die Steuerung, wie sie war
 *   (Paul, 17.09.2026: sofort schalten und zuruecknehmen blitzte bei jedem Doppeltipp).
 * - Die Mitte haelt an, auch bei ausgeblendeter Steuerung — wer dorthin tippt, meint den Knopf.
 * - Zwei Finger schalten hart zwischen ganzem und formatfuellendem Bild; ein weiches Zoomen, das
 *   falsch landet, wirkte auf iOS kaputter als ein Schalter.
 * - Die Stelle wird **vor** dem Anhalten gelesen: VLC setzt seine Uhr beim Anhalten zurueck.
 */
@Composable
fun PlayerSeite(app: SwiftlyAnwendung, wunsch: Abspielwunsch, imKleinenFenster: Boolean, bildImBild: () -> Boolean, schliessen: () -> Unit) {
    val kontext = LocalContext.current
    val aktivitaet = remember(kontext) { kontext.aktivitaet() }
    val lauf = rememberCoroutineScope()
    val ruck = rememberRuck()

    // Querformat, ohne Systemleisten, und der Bildschirm bleibt an — solange der Player offen ist.
    DisposableEffect(aktivitaet) {
        val fenster = aktivitaet?.window
        val vorher = aktivitaet?.requestedOrientation ?: ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        // „Querformat im Player sperren" — sonst darf das Telefon auch hochkant.
        aktivitaet?.requestedOrientation = if (app.einstellungen.querformatFest) ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                                           else ActivityInfo.SCREEN_ORIENTATION_FULL_USER
        val leisten = fenster?.let { WindowCompat.getInsetsController(it, it.decorView) }
        leisten?.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        leisten?.hide(WindowInsetsCompat.Type.systemBars())
        fenster?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        onDispose {
            leisten?.show(WindowInsetsCompat.Type.systemBars())
            fenster?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            aktivitaet?.requestedOrientation = vorher
        }
    }

    val werk = remember { Spielwerk(app, kontext, lauf, ruck) }
    // **Die Videoflaeche wieder anhaengen**, wenn Android sie beim Wechsel in den Hintergrund
    // abgebaut hat — sonst lief der Ton weiter, und das Bild blieb schwarz, bis zum Neustart.
    val flaeche = remember { arrayOfNulls<VLCVideoLayout>(1) }
    @Suppress("DEPRECATION")
    val lebenslauf = androidx.compose.ui.platform.LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lebenslauf) {
        val beobachter = androidx.lifecycle.LifecycleEventObserver { _, ereignis ->
            if (ereignis == androidx.lifecycle.Lifecycle.Event.ON_PAUSE) werk.hintergrundMelden()
            if (ereignis == androidx.lifecycle.Lifecycle.Event.ON_START && !werk.spieler.vlcVout.areViewsAttached()) {
                flaeche[0]?.let { werk.spieler.attachViews(it, null, true, false) }
            }
        }
        lebenslauf.addObserver(beobachter)
        onDispose { lebenslauf.removeObserver(beobachter) }
    }
    var sichtbar by remember { mutableStateOf(true) }
    var beruehrt by remember { mutableIntStateOf(0) }
    var sprungblase by remember { mutableStateOf<String?>(null) }
    /** Die Einstellungskarte oben rechts (`PlayerSettingsSheet`) — auf dem Fernseher bleibt die Tafel. */
    var tafelOffen by remember { mutableStateOf(false) }

    DisposableEffect(werk) {
        werk.installiereEreignisListener()
        onDispose { werk.aufraeumen() }
    }

    DisposableEffect(werk.sitzung) {
        werk.installiereSitzung()
        onDispose { werk.sitzungAufraeumen() }
    }
    // Titel, Serie, Folge, Laenge und das Standbild; das Bild kommt nach, der Rest steht sofort.
    LaunchedEffect(werk.plan, werk.dauer > 0) { werk.metadatenAktualisieren() }
    val kannKlein = remember { kontext.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE) }

    // Technikschild: die festen Zeilen einmal je Titel, die gezaehlten alle zwei Sekunden — schnell genug,
    // um einem Ruckler zuzusehen, langsam genug, dass die Zahlen lesbar stehen. Laeuft nur, solange es
    // sichtbar ist: ein vergessener Zaehler waere selbst die Last, die er misst.
    LaunchedEffect(app.einstellungen.technikschild, werk.plan) { werk.technikschildTakt(app.einstellungen.technikschild) }

    BackHandler { werk.beenden(schliessen) }

    // Oeffnen, dann der Takt.
    LaunchedEffect(wunsch) { werk.oeffnenUndTakt(wunsch, schliessen) }

    val blattOffen = app.blatt.value != null
    // Die Einblendung hoert auf die gewollte Steuerung (Vorlage `onChange(of: steuerungSichtbar)` auf iOS):
    // beim Oeffnen steht sie schon auf „an", ihr erstes Ausblenden schickt „Rückblick überspringen" nicht weg.
    LaunchedEffect(sichtbar) { werk.steuerungGeaendert(sichtbar) }
    LaunchedEffect(sichtbar, werk.laeuft, werk.amSchieben, blattOffen, beruehrt) {
        if (sichtbar && werk.laeuft && !werk.amSchieben && !blattOffen) { delay(4000); sichtbar = false }
    }
    LaunchedEffect(werk.hinweis) { if (werk.hinweis != null) { delay(5000); werk.hinweis = null } }
    LaunchedEffect(sprungblase) { if (sprungblase != null) { delay(700); sprungblase = null } }

    val deckung by animateFloatAsState(
        if (sichtbar || !werk.bildFrei) 1f else 0f,
        if (sichtbar || !werk.bildFrei) tween(180, easing = Bewegung.weich) else tween(340, easing = Bewegung.weich),
        label = "steuerung")
    // Nur beim Ueberschreiten neu komponieren — die Deckkraft selbst liest die Grafikebene.
    val steuerungDa by remember { derivedStateOf { deckung > 0.01f } }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        AndroidView(factory = { ctx -> VLCVideoLayout(ctx).also { flaeche[0] = it; werk.spieler.attachViews(it, null, true, false) } },
                    modifier = Modifier.fillMaxSize())

        // Gesten ueber dem Bild, unter der Steuerung.
        Box(Modifier.fillMaxSize()
            .pointerInput(Unit) {
                var letzter = 0L
                // **Der Einzeltipp wartet 260 ms auf einen zweiten** (Paul, 17.09.2026, iPhone): schaltete er
                // sofort und nahm der zweite es zurueck, ging bei jedem Doppeltipp die Steuerung einmal auf
                // und zu. Vorlage `tippen(richtung:)` in `Sources/iOS/PlayerScreen.swift`.
                var schalter: kotlinx.coroutines.Job? = null
                detectTapGestures(onTap = { stelle ->
                    val jetzt = SystemClock.elapsedRealtime()
                    if (jetzt - letzter < 260) {
                        schalter?.cancel()
                        val links = stelle.x < size.width / 2
                        werk.springe(werk.position + if (links) -werk.zurueckS.toDouble() else werk.vorS.toDouble())
                        sprungblase = if (links) "−${werk.zurueckS}" else "+${werk.vorS}"
                        if (sichtbar) beruehrt++
                        letzter = 0L
                    } else {
                        letzter = jetzt
                        schalter?.cancel()
                        schalter = lauf.launch {
                            delay(260)
                            sichtbar = !sichtbar
                            beruehrt++
                        }
                    }
                })
            }
            .pointerInput(Unit) {
                awaitEachGesture {
                    awaitFirstDown(requireUnconsumed = false)
                    var mass = 1f
                    var geschaltet = false
                    do {
                        val ereignis = awaitPointerEvent()
                        if (ereignis.changes.size >= 2) {
                            mass *= ereignis.calculateZoom()
                            if (!geschaltet && mass > 1.15f) { werk.bildfuellendSetzen(true); geschaltet = true }
                            if (!geschaltet && mass < 0.85f) { werk.bildfuellendSetzen(false); geschaltet = true }
                        }
                    } while (ereignis.changes.any { it.pressed })
                }
            })

        if (!werk.bildFrei) {
            Box(Modifier.fillMaxSize().background(Color.Black), contentAlignment = Alignment.Center) {
                if (werk.hinweis == null) CircularProgressIndicator(color = Stil.schrift, strokeWidth = 2.5.dp, modifier = Modifier.size(30.dp))
            }
        }

        // Waehrend des Folgenwechsels laeuft die alte Folge weiter — der Ring sagt, dass etwas kommt.
        if (werk.bildFrei && werk.wechselt) {
            Box(Modifier.align(Alignment.Center)) {
                CircularProgressIndicator(color = Stil.schrift, strokeWidth = 2.5.dp, modifier = Modifier.size(30.dp))
            }
        }

        sprungblase?.let { text ->
            Box(Modifier.align(if (text.startsWith("+")) Alignment.CenterEnd else Alignment.CenterStart).padding(horizontal = 96.dp)
                    .size(72.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.45f)),
                contentAlignment = Alignment.Center) {
                Text(text, style = TextStyle(fontSize = 20.sp, fontWeight = FontWeight.SemiBold, fontFeatureSettings = "tnum"), color = Stil.schrift)
            }
        }

        if (app.einstellungen.technikschild && !imKleinenFenster && werk.technikFest.isNotEmpty()) {
            Technikschild(werk.technikFest, werk.technikLive, werk.position, werk.dauer,
                Modifier.align(Alignment.TopStart).windowInsetsPadding(WindowInsets.displayCutout).padding(start = 18.dp, top = 70.dp))
        }

        // Ausgeblendet haelt die Mitte trotzdem an.
        if (werk.bildFrei && !steuerungDa && !imKleinenFenster) Box(Modifier.align(Alignment.Center).size(108.dp, 132.dp).antippen { werk.umschalten() })

        // Im kleinen Fenster nur das Bild — die Steuerung bringt das System mit.
        if (steuerungDa && !imKleinenFenster && !tafelOffen) Box(Modifier.fillMaxSize().graphicsLayer { alpha = deckung }) {
            // `Playerschleier` — ohne ihn verschwinden weisse Zeichen ueber hellen Szenen.
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.28f)))
            Box(Modifier.fillMaxWidth().height(140.dp).background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.6f), Color.Transparent))))
            Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(180.dp)
                .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.7f)))))

            Row(Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.displayCutout).padding(horizontal = 16.dp).padding(top = 18.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Rundknopf(Icons.Filled.KeyboardArrowDown, uebersetzt("Player schließen"), 32.dp) { werk.beenden(schliessen) }
                Spacer(Modifier.weight(1f))
                // Gedimmt, nicht weg, wenn das Geraet es nicht kann.
                Rundknopf(Icons.Filled.PictureInPictureAlt, uebersetzt("Bild im Bild"), 24.dp, deckkraft = if (kannKlein) 1f else 0.4f) {
                    if (kannKlein) bildImBild()
                }
                Rundknopf(Icons.Filled.Tune, uebersetzt("Wiedergabeeinstellungen"), 24.dp) { tafelOffen = true }
            }

            // Mittig, nicht oben oder unten angeklebt — so bleibt sie in beiden Lagen mit dem Daumen erreichbar.
            if (werk.bildFrei) Row(Modifier.align(Alignment.Center), horizontalArrangement = Arrangement.spacedBy(56.dp),
                              verticalAlignment = Alignment.CenterVertically) {
                Rundknopf(spulzeichen(true, werk.zurueckS), uebersetzt("%lld Sekunden zurück", werk.zurueckS), 46.dp) { werk.springe(werk.position - werk.zurueckS) }
                Rundknopf(if (werk.laeuft) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                          uebersetzt(if (werk.laeuft) "Anhalten" else "Abspielen"), 78.dp) { werk.umschalten() }
                Rundknopf(spulzeichen(false, werk.vorS), uebersetzt("%lld Sekunden vor", werk.vorS), 46.dp) { werk.springe(werk.position + werk.vorS) }
            }

            werk.hinweis?.let {
                Text(it, style = TextStyle(fontSize = 13.sp, textAlign = TextAlign.Center), color = Stil.schrift,
                     modifier = Modifier.align(Alignment.TopCenter).padding(top = 72.dp, start = 48.dp, end = 48.dp))
            }

            Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().windowInsetsPadding(WindowInsets.displayCutout)
                       .padding(horizontal = 24.dp).padding(bottom = 18.dp)) {
                Row(verticalAlignment = Alignment.Bottom) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(werk.plan?.titel.orEmpty(), style = TextStyle(fontSize = 19.sp, fontWeight = FontWeight.SemiBold),
                             color = Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                            werk.plan?.untertitel?.takeIf { it.isNotEmpty() }?.let {
                                Text(it, style = TextStyle(fontSize = 14.sp), color = Stil.schriftLeise, maxLines = 1)
                            }
                            val p = werk.plan
                            if (p != null && !p.lossless) Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Filled.Warning, contentDescription = null, tint = Stil.warnung, modifier = Modifier.size(13.dp))
                                Text(p.methode, style = TextStyle(fontSize = 14.sp), color = Stil.warnung)
                            }
                        }
                    }
                    // Nur der Platz: die Pille selbst steht in der Einblendung darueber, an derselben
                    // Stelle wie ohne Steuerung (Vorlage iOS, Paul 17.09.2026).
                    if (werk.angebotArt != "keiner" && werk.angebotText.isNotEmpty()) {
                        Box(Modifier.alpha(0f).clearAndSetSemantics {}) {
                            Angebotspille(werk.angebotArt, werk.angebotText, null, null, werk) {}
                        }
                    }
                }
                Spacer(Modifier.height(10.dp))
                Zeitzeile(werk.position, werk.dauer, { werk.amSchieben = it; beruehrt++ }) { werk.springe(it) }
            }
        }

        // **Der Angebotsknopf** — „Intro überspringen" / „Nächste Folge", wie bei Netflix (Vorlage `angebotDa` in
        // `Sources/iOS/PlayerScreen.swift`). Unten rechts, **an einer Stelle, egal ob die Steuerung offen ist**:
        // Ueberspringen, solange der Abschnitt laeuft; die Karte bei geschlossener Steuerung, bei offener der normale
        // Knopf „Nächste Folge". Ein Tipp fuehrt aus, das Kreuz daneben oder Zurueck schliesst nur die Einblendung.
        val karteDa = werk.einblendung != "nichts" && werk.bildFrei && !steuerungDa && !tafelOffen && !blattOffen
            && !imKleinenFenster && !werk.wechselt
        val angebotDa = werk.angebotArt != "keiner" && werk.angebotText.isNotEmpty() && werk.bildFrei && !tafelOffen
            && !blattOffen && !imKleinenFenster && !werk.wechselt
            && (werk.einblendung != "nichts" || (steuerungDa && werk.angebotArt == "naechste"))
        BackHandler(enabled = karteDa) { werk.angebotSchliessen() }
        // Dieselben Kurven wie die Steuerung (`deckung`: 180 ms auf, 340 ms zu), Paul 17.09.2026.
        androidx.compose.animation.AnimatedVisibility(visible = angebotDa, modifier = Modifier.align(Alignment.BottomEnd),
            enter = fadeIn(tween(180, easing = Bewegung.weich)), exit = fadeOut(tween(340, easing = Bewegung.weich))) {
            Row(Modifier.windowInsetsPadding(WindowInsets.displayCutout)
                    .padding(horizontal = 24.dp).padding(bottom = 18.dp + 44.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                if (werk.einblendung != "nichts") Box(Modifier.size(40.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.45f))
                        .antippen { werk.angebotSchliessen() }
                        .semantics { contentDescription = uebersetzt(if (werk.einblendung == "karte") "Abbrechen" else "Schließen"); role = Role.Button },
                    contentAlignment = Alignment.Center) {
                    Icon(Icons.Filled.Close, contentDescription = null, tint = Stil.schrift, modifier = Modifier.size(20.dp))
                }
                Angebotspille(werk.angebotArt, werk.angebotText, werk.countdown.takeIf { werk.einblendung == "karte" },
                                      werk.countdownRest.takeIf { werk.einblendung == "karte" }, werk) {
                    werk.angebotAusfuehren()
                }
            }
        }

        // **Die Karte liegt ueber allem**, das Bild laeuft darunter weiter — nur zurueckgenommen.
        if (!imKleinenFenster) {
            BackHandler(enabled = tafelOffen) { tafelOffen = false; sichtbar = true; beruehrt++ }
            Wiedergabetafel(
                offen = tafelOffen, schliessen = { tafelOffen = false; sichtbar = true; beruehrt++ },
                auslieferung = werk.technikFest.firstOrNull()?.first,
                tonspuren = { werk.spurliste(ton = true) },
                ton = { werk.spieler.audioTrack }, tonWaehlen = { werk.tonVonHand(it) },
                untertitel = { werk.spurliste(ton = false) },
                spur = { werk.spieler.spuTrack }, spurWaehlen = { werk.untertitelVonHand(it) },
                bildfuellend = werk.bildfuellend, bildWaehlen = { werk.bildfuellendSetzen(it) },
                tempo = werk.tempo, tempoWaehlen = { werk.tempoSetzen(it) },
                schlafzeit = werk.schlafzeit, schlafWaehlen = { werk.schlafzeitSetzen(it) },
                technik = app.einstellungen.technikschild, technikSetzen = { app.einstellungen.technikschild = it },
                querformat = app.einstellungen.querformatFest, querformatSetzen = {
                    app.einstellungen.querformatFest = it
                    aktivitaet?.requestedOrientation = if (it) ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE else ActivityInfo.SCREEN_ORIENTATION_FULL_USER
                })
        }
}
}

@Composable
private fun Rundknopf(symbol: ImageVector, beschreibung: String, groesse: Dp, deckkraft: Float = 1f, tun: () -> Unit) {
    Box(Modifier.size(if (groesse < 44.dp) 44.dp else groesse).graphicsLayer { alpha = deckkraft }.antippen(tun), contentAlignment = Alignment.Center) {
        Icon(symbol, contentDescription = beschreibung, tint = Color.White, modifier = Modifier.size(groesse))
    }
}

/**
 * Vorlage: `Zeitzeile` + `Zeitregler` — vergangen, Regler, verbleibend mit Minus. Beim Schieben
 * wird die Spur 6 statt 3 dick und der Knauf 18 statt 13 (`Stil.umschalten`); gesprungen wird
 * erst beim Loslassen.
 */
@Composable
private fun Zeitzeile(position: Double, dauer: Double, schieben: (Boolean) -> Unit, springen: (Double) -> Unit) {
    var ziel by remember { mutableStateOf<Double?>(null) }
    val gezeigt = ziel ?: position
    val ziffern = TextStyle(fontSize = 13.sp, fontFeatureSettings = "tnum")
    // Feste Masse, skaliert in der Grafikebene — Spur 3 → 6, Knauf 13 → 18, ohne Layout je Bild.
    val gross by animateFloatAsState(if (ziel != null) 1f else 0f, Bewegung.umschalten(), label = "regler")
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(zeitText(gezeigt), style = ziffern, color = Stil.schrift)
        BoxWithConstraints(Modifier.weight(1f).height(32.dp)
            .pointerInput(dauer) {
                detectHorizontalDragGestures(
                    onDragStart = { o -> ziel = (o.x / size.width).coerceIn(0f, 1f).toDouble() * dauer; schieben(true) },
                    onDragEnd = { ziel?.let(springen); ziel = null; schieben(false) },
                    onDragCancel = { ziel = null; schieben(false) },
                    onHorizontalDrag = { aenderung, _ -> ziel = (aenderung.position.x / size.width).coerceIn(0f, 1f).toDouble() * dauer })
            }
            .pointerInput(dauer) { detectTapGestures { o -> springen((o.x / size.width).coerceIn(0f, 1f).toDouble() * dauer) } }
            // TalkBack liest die Stelle vor und kann sie verstellen — wie `accessibilityAdjustableAction`.
            .semantics {
                stateDescription = zeitText(gezeigt) + " / " + zeitText(dauer)
                if (dauer > 0) progressBarRangeInfo = ProgressBarRangeInfo(gezeigt.toFloat().coerceIn(0f, dauer.toFloat()), 0f..dauer.toFloat())
                setProgress { wert -> springen(wert.toDouble()); true }
            },
            contentAlignment = Alignment.CenterStart) {
            val anteil = if (dauer > 0) (gezeigt / dauer).toFloat().coerceIn(0f, 1f) else 0f
            val spur = Modifier.height(6.dp).graphicsLayer { scaleY = 0.5f + 0.5f * gross }.clip(CircleShape)
            Box(Modifier.fillMaxWidth().then(spur).background(Color.White.copy(alpha = 0.25f)))
            Box(Modifier.fillMaxWidth(anteil).then(spur).background(Color.White))
            Box(Modifier.offset(x = maxWidth * anteil - 9.dp).size(18.dp)
                .graphicsLayer { val m = (13f + 5f * gross) / 18f; scaleX = m; scaleY = m }.clip(CircleShape).background(Color.White))
        }
        Text("−" + zeitText((dauer - gezeigt).coerceAtLeast(0.0)), style = ziffern, color = Stil.schrift)
    }
}

/**
 * Vorlage: `Technikschild` — oben links, unter dem Kopf, nie antippbar. Fast deckend statt
 * durchscheinend: lesbar ueber bewegtem Bild geht vor. Die Schwellen sind die von iOS: Bildrate
 * mehr als zwei unter Soll, Lauf unter 97 %, Vorrat unter zwei Sekunden, jeder Verlust.
 * „zu spät" fehlt — libVLC fuer Android zaehlt verspaetete Bilder nicht; eine Null waere gelogen.
 *
 * Nicht `private`: `tv/TvPlayer.kt` zeigt dasselbe Schild an derselben Stelle.
 */
/**
 * **Der Angebotsknopf** — in der Steuerung und in der Einblendung derselbe (`Angebotsknopf` auf iOS).
 * `anteil` (0…1): der Countdown zur naechsten Folge, als Fuellung von links. TalkBack liest Beschriftung
 * und, waehrend des Countdowns, die Sekunden bis zum Start.
 */
@Composable
fun Angebotspille(art: String, text: String, anteil: Double?, sekunden: Int?, werk: Spielwerk, aktion: () -> Unit) {
    val fuellung = durchgehendeFuellung(anteil, werk.laeuft, werk.countdownLaenge)
    Row(Modifier.clip(CircleShape)
            .background(Color.White)
            // Akzent als Fortschritt (Paul, 17.09.2026: vorher zu dunkel); die dunkle Schrift bleibt darauf lesbar.
            .drawBehind { if (anteil != null) drawRect(Stil.akzent, size = size.copy(width = size.width * fuellung)) }
            .antippen(aktion)
            .semantics(mergeDescendants = true) {
                role = Role.Button
                if (sekunden != null) stateDescription = uebersetzt("Startet in %lld Sekunden", sekunden)
            }
            .padding(horizontal = 16.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(if (art == "naechste") Icons.Filled.SkipNext else Icons.Filled.FastForward,
             contentDescription = null, tint = Stil.grund, modifier = Modifier.size(18.dp))
        Text(text, style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold), color = Stil.grund)
    }
}

/**
 * **Die Fuellung der Karte als eine durchgehende Bewegung** (Paul, 17.09.2026: im Takt nachgezogen ruckelte sie) —
 * Gegenstueck zu `Fuellungsuhr` im Paket. Laeuft: linear vom jetzigen Stand bis voll ueber die Restdauer. Steht:
 * haelt genau dort an. Weiter: von dort, nie zurueck. Ohne Karte null.
 */
@Composable
fun durchgehendeFuellung(anteil: Double?, laeuft: Boolean, laenge: Double): Float {
    val wert = remember { androidx.compose.animation.core.Animatable(0f) }
    val da = anteil != null
    LaunchedEffect(da, laeuft) {
        if (!da) { wert.snapTo(0f); return@LaunchedEffect }
        if (!laeuft) { wert.stop(); return@LaunchedEffect }
        val ab = maxOf(wert.value, (anteil ?: 0.0).toFloat())
        wert.snapTo(ab)
        val rest = ((1f - ab) * laenge * 1000).toInt().coerceAtLeast(1)
        wert.animateTo(1f, tween(rest, easing = LinearEasing))
    }
    return wert.value
}

@Composable
fun Technikschild(fest: List<Pair<String, String>>, live: JSONObject?, position: Double, dauer: Double, modifier: Modifier) {
    val schrift = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Medium, fontFamily = FontFamily.Monospace)
    val form = RoundedCornerShape(Stil.ecke)
    fun komma(x: Double, stellen: Int = 1) = String.format(Locale.getDefault(), "%.${stellen}f", x)
    Column(modifier.width(260.dp).clip(form).background(Stil.grund.copy(alpha = 0.82f)).border(1.dp, Stil.rand, form)
               .padding(horizontal = 12.dp, vertical = 10.dp),
           verticalArrangement = Arrangement.spacedBy(4.dp)) {
        fest.forEachIndexed { i, (text, art) ->
            Text(text, style = if (i == 0) schrift.copy(fontSize = 14.sp, fontWeight = FontWeight.Bold) else schrift,
                 color = when (art) { "gut" -> Stil.akzent; "warnend" -> Stil.warnung; else -> if (i == 0) Stil.schrift else Stil.schriftLeise })
        }
        Text("${uebersetzt("Stelle")} ${zeitText(position)} / ${zeitText(dauer)}", style = schrift, color = Stil.schriftLeise)
        live?.let { w ->
            Box(Modifier.padding(vertical = 2.dp).width(150.dp).height(1.dp).background(Stil.rand))
            @Composable fun zeile(text: String, warnend: Boolean) =
                Text(text, style = schrift, color = if (warnend) Stil.warnung else Stil.schriftLeise)
            val soll = w.feldZahl("soll")
            w.feldText("eingang")?.let { zeile("${uebersetzt("Eingang")} $it", false) }
            w.feldText("demuxer")?.let { zeile("${uebersetzt("Demuxer")} $it", false) }
            w.feldZahl("zeigt")?.let { ist ->
                zeile("${uebersetzt("Zeigt Ø")} ${komma(ist)} fps · ${uebersetzt("Gezeigt")} ${w.optLong("gezeigt")}", soll != null && ist < soll - 2)
            }
            w.feldZahl("lauf")?.let { anteil -> zeile("${uebersetzt("Lauf")} ${(anteil * 100).roundToInt()} %", anteil < 0.97) }
            w.feldZahl("dekodiert")?.let { ist -> zeile("${uebersetzt("Dekodiert Ø")} ${komma(ist)} fps", soll != null && ist < soll - 2) }
            val kib = w.optLong("vorratKiB")
            val sekunden = w.feldZahl("vorratSekunden")
            zeile("${uebersetzt("Vorrat")} ${sekunden?.let { "${komma(it, 0)} s · " }.orEmpty()}$kib KiB", sekunden != null && sekunden < 2)
            val verworfen = w.optLong("verworfen"); val tonWeg = w.optLong("tonVerloren")
            zeile("${uebersetzt("Verworfen")} $verworfen · ${uebersetzt("Ton weg")} $tonWeg", verworfen > 0 || tonWeg > 0)
            val kaputt = w.optLong("beschaedigt"); val spruenge = w.optLong("spruenge")
            zeile("${uebersetzt("Beschädigt")} $kaputt · ${uebersetzt("Sprünge")} $spruenge", kaputt > 0 || spruenge > 0)
        }
    }
}

private val tafelFeder = spring(dampingRatio = 0.86f, stiffness = 322f, visibilityThreshold = IntOffset.VisibilityThreshold)

/**
 * Vorlage: `PlayerSettingsSheet` in `Sources/iOS/PlayerSettings.swift`.
 *
 * - **Eine Karte oben rechts, kein Blatt von unten.** Der Film laeuft weiter; man stellt ein,
 *   waehrend man schaut — also bleibt er sichtbar, nur zurueckgenommen (55 % Grund).
 * - **Eine Ebene tief**: Ton und Untertitel greift man mitten im Film, sie sollen nicht hinter
 *   zwei Ebenen liegen. Eine Wahl greift sofort, **die Liste bleibt offen** — Spuren vergleicht man.
 * - Die Karte legt sich an ihren Inhalt an, statt sich auszudehnen; wird er zu hoch, scrollt sie.
 * - Ein- und Ausblenden als reine Deckkraft (180 ms), der Wechsel der Ebene als Schub mit der
 *   Blattfeder — die Richtung zeigt, ob es hinein oder zurueck geht.
 * - Die eigene Wahl gilt vor VLCs Auskunft: VLC zieht die Auswahl erst einen Takt spaeter nach.
 */
@Composable
private fun Wiedergabetafel(
    offen: Boolean, schliessen: () -> Unit, auslieferung: String?,
    tonspuren: () -> List<Pair<Int, String>>, ton: () -> Int, tonWaehlen: (Int) -> Unit,
    untertitel: () -> List<Pair<Int, String>>, spur: () -> Int, spurWaehlen: (Int) -> Unit,
    bildfuellend: Boolean, bildWaehlen: (Boolean) -> Unit,
    tempo: Float, tempoWaehlen: (Float) -> Unit,
    schlafzeit: Int, schlafWaehlen: (Int) -> Unit,
    technik: Boolean, technikSetzen: (Boolean) -> Unit,
    querformat: Boolean, querformatSetzen: (Boolean) -> Unit,
) {
    val deckung by animateFloatAsState(if (offen) 1f else 0f, tween(180, easing = EaseInOut), label = "tafel")
    if (deckung < 0.01f && !offen) return
    var ebene by remember { mutableStateOf("wurzel") }
    LaunchedEffect(offen) { if (offen) ebene = "wurzel" }
    val spurenTon = remember(offen, ebene) { tonspuren() }
    val spurenText = remember(offen, ebene) { untertitel() }
    var tonWahl by remember(offen) { mutableIntStateOf(ton()) }
    var spurWahl by remember(offen) { mutableIntStateOf(spur()) }
    val form = RoundedCornerShape(Stil.eckeFlaeche)

    BoxWithConstraints(Modifier.fillMaxSize().graphicsLayer { alpha = deckung }) {
        val hoechstens = maxHeight - 60.dp
        Box(Modifier.fillMaxSize().background(Stil.grund.copy(alpha = 0.55f)).antippen(schliessen))
        Box(Modifier.align(Alignment.TopEnd).windowInsetsPadding(WindowInsets.safeDrawing).padding(14.dp)
                .width(356.dp).shadow(24.dp, form, ambientColor = Color.Black, spotColor = Color.Black)
                .clip(form).background(Stil.flaeche).border(1.dp, Stil.rand, form)
                .pointerInput(Unit) { detectTapGestures { } }) {
            AnimatedContent(ebene, label = "ebene", transitionSpec = {
                val hinein = if (targetState != "wurzel") 1 else -1
                (slideInHorizontally(tafelFeder) { it * hinein } + fadeIn(tween(150))) togetherWith
                    (slideOutHorizontally(tafelFeder) { -it * hinein } + fadeOut(tween(150))) using SizeTransform(clip = true)
            }) { e ->
                Column(Modifier.heightIn(max = hoechstens).verticalScroll(rememberScrollState()).padding(bottom = 12.dp)) {
                    if (e == "wurzel") {
                        Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 12.dp, top = 14.dp, bottom = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text(uebersetzt("Wiedergabe"), style = TextStyle(fontSize = 19.sp, fontWeight = FontWeight.SemiBold), color = Stil.schrift)
                                auslieferung?.let { Text(it, style = TextStyle(fontSize = 12.sp), color = Stil.schriftSehrLeise, maxLines = 1) }
                            }
                            Box(Modifier.size(28.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.1f)).antippen(schliessen), contentAlignment = Alignment.Center) {
                                Icon(Icons.Filled.Close, contentDescription = uebersetzt("Schließen"), tint = Stil.schrift, modifier = Modifier.size(14.dp))
                            }
                        }
                        Tafelgruppe {
                            Navzeile(Icons.AutoMirrored.Filled.VolumeUp, uebersetzt("Ton"), spurenTon.firstOrNull { it.first == tonWahl }?.second ?: uebersetzt("Keine")) { ebene = "ton" }
                            Tafeltrenner()
                            Navzeile(Icons.Filled.ClosedCaption, uebersetzt("Untertitel"), spurenText.firstOrNull { it.first == spurWahl }?.second ?: uebersetzt("Aus")) { ebene = "untertitel" }
                            Tafeltrenner()
                            Navzeile(Icons.Filled.AspectRatio, uebersetzt("Bildformat"), uebersetzt(if (bildfuellend) "Formatfüllend" else "Ganzes Bild")) { ebene = "bild" }
                            Tafeltrenner()
                            Navzeile(Icons.Filled.Speed, uebersetzt("Tempo"), tempoText(tempo)) { ebene = "tempo" }
                            Tafeltrenner()
                            Navzeile(Icons.Filled.Bedtime, uebersetzt("Schlafzeit"), if (schlafzeit == 0) uebersetzt("Aus") else "$schlafzeit") { ebene = "schlaf" }
                        }
                        Spacer(Modifier.height(10.dp))
                        Tafelgruppe {
                            Schalterzeile(Icons.Filled.BarChart, uebersetzt("Technikschild"), technik, technikSetzen)
                            Tafeltrenner()
                            Schalterzeile(Icons.Filled.ScreenLockRotation, uebersetzt("Querformat fest"), querformat, querformatSetzen)
                        }
                    } else {
                        Row(Modifier.fillMaxWidth().padding(start = 8.dp, end = 16.dp, top = 12.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                            Row(Modifier.antippen { ebene = "wurzel" }.padding(4.dp), verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.AutoMirrored.Filled.KeyboardArrowLeft, contentDescription = null, tint = Stil.akzent, modifier = Modifier.size(22.dp))
                                Text(uebersetzt("Wiedergabe"), style = TextStyle(fontSize = 16.sp), color = Stil.akzent)
                            }
                            Spacer(Modifier.weight(1f))
                            Text(uebersetzt(when (e) { "ton" -> "Ton"; "untertitel" -> "Untertitel"; "bild" -> "Bildformat"; "tempo" -> "Tempo"; else -> "Schlafzeit" }),
                                 style = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.SemiBold), color = Stil.schrift)
                        }
                        when (e) {
                            "ton" -> {
                                Spaltentitel(uebersetzt("In dieser Datei"))
                                Tafelgruppe { spurenTon.forEachIndexed { i, (id, name) ->
                                    if (i > 0) Tafeltrenner(0.dp)
                                    Auswahlzeile(name, id == tonWahl) { tonWahl = id; tonWaehlen(id) }
                                } }
                            }
                            "untertitel" -> {
                                Spaltentitel(uebersetzt("In dieser Datei"))
                                Tafelgruppe {
                                    Auswahlzeile(uebersetzt("Aus"), spurWahl == -1) { spurWahl = -1; spurWaehlen(-1) }
                                    spurenText.forEach { (id, name) -> Tafeltrenner(0.dp); Auswahlzeile(name, id == spurWahl) { spurWahl = id; spurWaehlen(id) } }
                                }
                            }
                            "bild" -> {
                                Tafelgruppe {
                                    Auswahlzeile(uebersetzt("Ganzes Bild"), !bildfuellend) { bildWaehlen(false) }
                                    Tafeltrenner(0.dp)
                                    Auswahlzeile(uebersetzt("Formatfüllend"), bildfuellend) { bildWaehlen(true) }
                                }
                                Text(uebersetzt("Formatfüllend schneidet links und rechts ab, damit keine Balken bleiben. Geht auch mit zwei Fingern im Bild."),
                                     style = TextStyle(fontSize = 12.sp, lineHeight = 16.sp), color = Stil.schriftSehrLeise,
                                     modifier = Modifier.padding(horizontal = 16.dp).padding(top = 8.dp))
                            }
                            "tempo" -> Tafelgruppe {
                                listOf(0.75f, 1f, 1.25f, 1.5f, 2f).forEachIndexed { i, w ->
                                    if (i > 0) Tafeltrenner(0.dp)
                                    Auswahlzeile(tempoText(w), w == tempo) { tempoWaehlen(w) }
                                }
                            }
                            else -> Tafelgruppe {
                                Auswahlzeile(uebersetzt("Aus"), schlafzeit == 0) { schlafWaehlen(0) }
                                listOf(15, 30, 45, 60, 90).forEach { m -> Tafeltrenner(0.dp); Auswahlzeile("$m", m == schlafzeit) { schlafWaehlen(m) } }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun Tafelgruppe(inhalt: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.padding(horizontal = 12.dp).fillMaxWidth().clip(RoundedCornerShape(Stil.eckeFeld)).background(Stil.erhoeht), content = inhalt)
}

@Composable
private fun Tafeltrenner(einzug: Dp = 46.dp) {
    Box(Modifier.padding(start = einzug).fillMaxWidth().height(1.dp).background(Stil.linie))
}

@Composable
private fun Spaltentitel(text: String) {
    Text(text.uppercase(), style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.Medium, letterSpacing = 1.2.sp),
         color = Color.White.copy(alpha = 0.4f), modifier = Modifier.padding(start = 28.dp, top = 6.dp, bottom = 6.dp))
}

@Composable
private fun Navzeile(symbol: ImageVector, titel: String, wert: String, tun: () -> Unit) {
    Row(Modifier.fillMaxWidth().height(44.dp).druckzeile(tun).padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(symbol, contentDescription = null, tint = Stil.schrift, modifier = Modifier.width(22.dp).height(18.dp))
        Spacer(Modifier.width(12.dp))
        Text(titel, style = TextStyle(fontSize = 16.sp), color = Stil.schrift, modifier = Modifier.weight(1f))
        Text(wert, style = TextStyle(fontSize = 15.sp), color = Stil.schriftLeise, maxLines = 1, overflow = TextOverflow.Ellipsis,
             modifier = Modifier.widthIn(max = 150.dp).padding(start = 8.dp))
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = Stil.schriftSehrLeise, modifier = Modifier.padding(start = 4.dp).size(16.dp))
    }
}

/** Nur der Schalter nimmt den Tipp, nicht die Zeile — wie auf iOS. */
@Composable
private fun Schalterzeile(symbol: ImageVector, titel: String, an: Boolean, setzen: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().height(44.dp).padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(symbol, contentDescription = null, tint = Stil.schrift, modifier = Modifier.width(22.dp).height(18.dp))
        Spacer(Modifier.width(12.dp))
        Text(titel, style = TextStyle(fontSize = 16.sp), color = Stil.schrift, modifier = Modifier.weight(1f))
        Schalter(an, setzen)
    }
}

/** Gewaehlt im Akzent mit Haken dahinter — keine Kreise, keine Kaestchen. */
@Composable
private fun Auswahlzeile(text: String, gewaehlt: Boolean, tun: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 44.dp).druckzeile(tun).padding(horizontal = 12.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(text, style = TextStyle(fontSize = 16.sp), color = if (gewaehlt) Stil.akzent else Stil.schrift, modifier = Modifier.weight(1f))
        if (gewaehlt) Icon(Icons.Filled.Check, contentDescription = null, tint = Stil.akzent, modifier = Modifier.size(15.dp))
    }
}
