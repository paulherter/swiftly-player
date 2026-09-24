package de.paulherter.swiftly

import de.paulherter.swiftly.gemeinsam.Zeichen
import de.paulherter.swiftly.gemeinsam.Symbol
import de.paulherter.swiftly.gemeinsam.Staerke
import android.app.Activity
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.EaseOut
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.snap
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.ui.composed
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.zIndex
import kotlinx.coroutines.flow.first
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
import androidx.compose.animation.Crossfade
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
import de.paulherter.swiftly.gemeinsam.bewegungReduziert
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
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.layout.Layout
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.graphics.asImageBitmap
import android.content.res.Configuration
import androidx.compose.ui.layout.ContentScale
import androidx.compose.foundation.Image

/** Was abgespielt werden soll und ab wo — `Abspielwunsch` auf iOS. `ab == null` heisst: von vorn. */
data class Abspielwunsch(val id: String, val ab: Double?)

/** Antwort von `Kern.wiedergabeOeffnen` — Adresse und die Zeilen fuer den Fuss. */
data class Spielplan(val url: String, val lossless: Boolean, val methode: String, val titel: String,
                     val untertitel: String, val naechste: Boolean,
                     val serie: String? = null, val kuerzel: String? = null, val bild: String? = null,
                     val dateizeile: String? = null,
                     // Fuer den Kopf des Players (Vorlage iOS `titelzeile`/`metatext`) und die Folgenebene.
                     val itemId: String = "", val episode: Boolean = false, val serieId: String? = null,
                     val staffelId: String? = null,
                     val kopfzeile: String = "", val staffelNr: Int? = null, val folgeNr: Int? = null,
                     val nebenzeile: String? = null,
                     /** Abschnittsgrenzen in Sekunden — Kerben im Zeitregler. */
                     val marken: List<Double> = emptyList())

/** Handwahl je Serie oder Film — dieselben Schluessel wie `Spurgedaechtnis` im Paket. */
private const val TON_JE_TITEL = "tonJeTitel"
private const val UT_JE_TITEL = "utJeTitel"

internal fun spielplanLesen(json: String) = JSONObject(json).let { o ->
    Spielplan(o.getString("url"), o.optBoolean("lossless"), o.optString("methode"), o.optString("titel"),
              o.optString("untertitel"), o.optBoolean("naechste"),
              o.optString("serie").takeIf { !o.isNull("serie") }, o.optString("kuerzel").takeIf { !o.isNull("kuerzel") },
              o.optString("bild").takeIf { !o.isNull("bild") },
              o.optString("dateizeile").takeIf { !o.isNull("dateizeile") },
              o.optString("itemId"), o.optBoolean("episode"), o.optString("serieId").takeIf { !o.isNull("serieId") },
              o.optString("staffelId").takeIf { !o.isNull("staffelId") },
              o.optString("kopfzeile"),
              if (o.isNull("staffelNr")) null else o.optInt("staffelNr"),
              if (o.isNull("folgeNr")) null else o.optInt("folgeNr"),
              o.optString("nebenzeile").takeIf { !o.isNull("nebenzeile") },
              o.optJSONArray("marken")?.let { a -> (0 until a.length()).map { a.getDouble(it) } }.orEmpty())
}

/** Trickplay-Angaben zur laufenden Wiedergabe — Rechnung wie `Trickplay` im Paket (Vorlage iOS). */
data class Trickplayangabe(val breite: Int, val hoehe: Int, val kachelnBreit: Int, val kachelnHoch: Int,
                           val anzahl: Int, val intervall: Int) {
    data class Kachel(val blatt: Int, val x: Int, val y: Int, val breite: Int, val hoehe: Int)

    /** n = ms / Intervall, Blatt = n / (Spalten × Zeilen) — siehe `Trickplay.kachel(sekunden:)`. */
    fun kachel(sekunden: Double): Kachel? {
        val jeBlatt = kachelnBreit * kachelnHoch
        if (intervall <= 0 || jeBlatt <= 0 || anzahl <= 0 || breite <= 0 || hoehe <= 0 || !sekunden.isFinite()) return null
        val ms = maxOf(sekunden, 0.0) * 1000
        val n = minOf((ms / intervall).toInt(), anzahl - 1)
        val platz = n % jeBlatt
        return Kachel(n / jeBlatt, (platz % kachelnBreit) * breite, (platz / kachelnBreit) * hoehe, breite, hoehe)
    }
}

private fun trickplayangabeLesen(json: String): Trickplayangabe? = JSONObject(json).let { o ->
    if (!o.has("breite")) return null
    Trickplayangabe(o.getInt("breite"), o.getInt("hoehe"), o.getInt("kachelnBreit"), o.getInt("kachelnHoch"),
                    o.getInt("anzahl"), o.getInt("intervall"))
}

/**
 * Staffeln und die Folgen der laufenden Staffel in den Speicher der Serienseite — Vorlage
 * `FolgenEbene.vorladen` auf iOS. Steht die Folgenebene beim Oeffnen schon parat, statt erst
 * nachzuladen. Dieselben Speicher wie `SerienSeite.kt` (`app.serienSpeicher`/`app.folgenSpeicher`),
 * damit ein Sprung von hier auf die Serienseite nichts doppelt holt.
 */
internal suspend fun folgenVorladen(app: SwiftlyAnwendung, serieId: String, staffelId: String?) {
    try {
        val serie = serieLesen(withContext(Dispatchers.IO) { app.kern.serie(serieId).await() })
        app.serienSpeicher[serieId] = serie
        if (serie.staffeln.isEmpty()) return
        val staffel = serie.staffeln.firstOrNull { it.id == staffelId } ?: serie.staffeln.firstOrNull { it.id == serie.gewaehlt } ?: serie.staffeln.first()
        val folgen = folgenLesen(withContext(Dispatchers.IO) { app.kern.folgen(serieId, staffel.id).await() })
        app.folgenSpeicher[staffel.id] = folgen
    } catch (e: CancellationException) { throw e } catch (_: Exception) {}
}

/** 1:23:45 oder 23:45 — Ziffern gleich breit, damit die Zeile beim Laufen nicht zittert. Auch von `tv/TvPlayer.kt` benutzt. */
internal fun zeitText(sekunden: Double): String {
    val s = sekunden.coerceAtLeast(0.0).toLong()
    val h = s / 3600
    val m = (s % 3600) / 60
    val r = s % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, r) else "%d:%02d".format(m, r)
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
    // Eigene Zertifizierungsstellen des Nutzers: GnuTLS liest sonst nur den Systemspeicher (`Zertifikate`).
    // **`--stereo-mode=1`: dekodierter Ton als Stereo, solange `mehrkanalTon` aus ist.** Meldet der
    // HDMI-Ausgang Bitstream-Formate, oeffnet libVLCs AudioTrack-Ausgabe (Geraet `encoded:`/`pcm`)
    // Mehrkanal-PCM mit bis zu acht Kanaelen — AAC 5.1 ging so als 6-Kanal-Strom hinaus, und manche
    // Boxen (Mi Box S) geben den stumm wieder, statt ihn herunterzumischen. Die Option wirkt in libVLC
    // nur auf lineares PCM (`aout_OutputNew`), AC3/E-AC3/DTS/TrueHD gehen weiter roh durch
    // (`digitalenTonAnwenden`).
    val vlc = LibVLC(kontext, ArrayList(listOf("--no-drop-late-frames", "--no-skip-frames") +
        listOfNotNull("--stereo-mode=1".takeUnless { app.einstellungen.mehrkanalTon }) +
        listOfNotNull(Zertifikate.ordner?.let { "--gnutls-dir-trust=$it" })))
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
     * Oeffnen sagt die Karte „Naechste Folge" ab. „Intro ueberspringen" steht sechs Sekunden Laufzeit ohne
     * Steuerung da, danach nur noch mit ihr (VERHALTEN B6a) — die Einblendung kommt deshalb sofort zurueck,
     * nicht erst mit dem naechsten Takt. Auf dem Fernseher geht der Fokus dann an die Ruheflaeche (`TvPlayer`).
     */
    fun steuerungGeaendert(offen: Boolean) {
        einblendung = app.kern.steuerungGeaendert(offen)
    }
    var hinweis by mutableStateOf<String?>(null)
    var technikFest by mutableStateOf<List<Technikzeile>>(emptyList()); private set
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
    /**
     * Waehrend am Regler gezogen wird, ueberschreibt der Takt die Stelle nicht — nur das Telefon kennt das.
     * **Beobachtbar**: Symbole und Mitte weichen beim Spulen. Als einfaches Feld sah Compose die Aenderung
     * nicht — sie verschwanden erst, wenn zufaellig der Takt neu zeichnete, und kamen ebenso zufaellig wieder.
     */
    var amSchieben by mutableStateOf(false)

    // MARK: Trickplay — Vorschau beim Spulen, Vorlage `Trickplaybilder` im Paket.
    var trickplayAngabe by mutableStateOf<Trickplayangabe?>(null); private set
    /** Entschluesselte Kachelblaetter, hoechstens sechs — wie auf iOS wird nur eine Handvoll behalten. */
    private val trickplayBlaetter = LinkedHashMap<Int, android.graphics.Bitmap>()
    private val trickplayUnterwegs = mutableSetOf<Int>()
    /** Zaehlt eintreffende Blaetter hoch, damit die Vorschau neu zeichnet. */
    var trickplayStand by mutableIntStateOf(0); private set

    suspend fun trickplayLaden() {
        trickplayAngabe = null
        trickplayBlaetter.clear()
        trickplayUnterwegs.clear()
        val roh = withContext(Dispatchers.IO) { app.kern.trickplayAngabe().await() }
        val gelesen = trickplayangabeLesen(roh)
        // Wie `Trickplaybilder.laden` auf iOS: eine Zeile je Titel — ohne sie war auf dem Geraet nicht
        // zu sagen, ob der Server keins hat oder die Vorschau nur nicht ankommt.
        Protokoll.schreib("[Trickplay] " + (gelesen?.let { "${it.breite}px, ${it.anzahl} Bilder, alle ${it.intervall} ms" } ?: "keins"))
        trickplayAngabe = gelesen
    }

    /** Das Bild zur Stelle, ausgeschnitten aus seinem Blatt — `null`, solange das Blatt noch unterwegs ist. */
    fun trickplayBild(sekunden: Double): android.graphics.Bitmap? {
        @Suppress("UNUSED_EXPRESSION") trickplayStand
        val angabe = trickplayAngabe ?: return null
        val kachel = angabe.kachel(sekunden) ?: return null
        val blatt = trickplayBlaetter[kachel.blatt] ?: run { trickplayAnfordern(kachel.blatt, angabe); return null }
        return runCatching { android.graphics.Bitmap.createBitmap(blatt, kachel.x, kachel.y, kachel.breite, kachel.hoehe) }.getOrNull()
    }

    private fun trickplayAnfordern(nummer: Int, angabe: Trickplayangabe) {
        if (!trickplayUnterwegs.add(nummer)) return
        lauf.launch {
            val adresse = withContext(Dispatchers.IO) { app.kern.trickplayAdresse(angabe.breite.toLong(), nummer.toLong()).await() }
            val bild = if (adresse.isEmpty()) null else runCatching {
                (SingletonImageLoader.get(kontext).execute(ImageRequest.Builder(kontext).data(adresse).allowHardware(false).build())
                    as? SuccessResult)?.image?.toBitmap()
            }.getOrNull()
            trickplayUnterwegs.remove(nummer)
            if (bild == null) Protokoll.schreib("[Trickplay] Blatt $nummer kam nicht (Adresse ${adresse.isNotEmpty()})")
            if (bild != null) {
                trickplayBlaetter[nummer] = bild
                if (trickplayBlaetter.size > 6) trickplayBlaetter.remove(trickplayBlaetter.keys.first())
                trickplayStand++
            }
        }
    }

    private val zeigtBild = booleanArrayOf(false)
    private val ende = booleanArrayOf(false)
    /** Schon mit „gestoppt" gemeldet — sonst meldet das Abraeumen es (weggewischtes kleines Fenster). */
    private val beendet = booleanArrayOf(false)
    private var schlafJob: kotlinx.coroutines.Job? = null
    private val debugBau = (kontext.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0

    val zurueckS: Int get() = app.einstellungen.zurueckSekunden
    val vorS: Int get() = app.einstellungen.vorSekunden

    fun installiereEreignisListener() {
        netzBeobachten()
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
                // **Ein Abriss sieht aus wie ein Filmende** (Vorlage `zustandGewechselt` auf iOS): liegt die
                // letzte gute Stelle deutlich vor dem Schluss, war es kein Ende, sondern ein toter Strom.
                MediaPlayer.Event.EndReached -> { laeuft = false; if (!abriss("Ende")) ende[0] = true }
                MediaPlayer.Event.EncounteredError -> {
                    // Vor dem ersten Bild zeigt die Oberflaeche weiter „laedt" — wenigstens das Protokoll soll es sagen.
                    if (!bildFrei) Protokoll.schreib("[VLC] Fehler vor dem ersten Bild")
                    if (!abriss("Fehler")) hinweis = uebersetzt("Die Folge konnte nicht geladen werden.")
                }
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
        netzAbmelden()
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
        lauf.launch { trickplayLaden() }
        bildFrei = false
        zeigtBild[0] = false
        puffert = false
        ende[0] = false
        position = ab ?: 0.0
        ab?.takeIf { it > 1 }?.let { app.kern.wiedergabeStelle(it) }
        stromwachtZuruecksetzen()
        stelltWiederHer = false
        wartetAufNetz = false
        letzteGuteStelle = ab ?: 0.0
        medienOeffnen(neu.url, ab)
    }

    /** Das Medium bauen und abspielen — beim Start und beim Neuaufbau nach einem Abriss (`neuVerbinden`). */
    private fun medienOeffnen(url: String, ab: Double?) {
        dateienVorbereiten()
        // Hinter einem Vorposten holt der Weiterleiter (OkHttp) den Strom mit den eigenen Headern
        // (Issue #4); libVLC kann keine senden. Ohne Header bleibt die Adresse, wie sie ist.
        val vlcAdresse = Stromweiterleiter.gemeinsam.adresse(url)
        if (vlcAdresse != url) Protokoll.schreib("[VLC] Strom ueber den Weiterleiter")
        // Nebenher, ohne darauf zu warten: wie das Geraet den Server erreicht. Nur fuers Protokoll (`Netzprobe`).
        Netzprobe.starten(kontext, url)
        val media = Media(vlc, Uri.parse(vlcAdresse))
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
        val ausgaenge = manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).filter { it.type in digitaleAusgaenge }
        // Fuers Protokoll: was der Ausgang an PCM-Kanaelen meldet (leer heisst „beliebig").
        ausgaenge.forEach { Protokoll.schreib("[VLC] Ausgang ${it.type}: Kanaele ${it.channelCounts.toList()}, " +
            "Mehrkanal-Ton ${if (app.einstellungen.mehrkanalTon) "an" else "aus"}") }
        val kodierungen = ausgaenge
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
     * **Qualität geändert — derselbe Titel, an derselben Stelle neu geladen.** Vorlage: die
     * Qualitätswahl im Player auf iOS/tvOS/macOS. Anders als `wechsle`: kein anderer Titel, und
     * die Stelle bleibt die Fortsetzstelle statt null.
     */
    suspend fun qualitaetWechseln() {
        if (wechselt || beendet[0]) return
        wechselt = true
        val stelle = (spieler.time / 1000.0).coerceAtLeast(0.0)
        try {
            val antwort = JSONObject(withContext(Dispatchers.IO) { app.kern.qualitaetWechseln(stelle).await() })
            antwort.feldText("nachmeldung")?.let { app.nachmeldungAblegen(it) }
            app.protokollSchreiben()
            when (antwort.optString("ergebnis")) {
                "gewechselt" -> {
                    val neu = antwort.feldText("spielplan")
                    if (neu != null && !beendet[0]) {
                        val neuerPlan = spielplanLesen(neu)
                        // Grenze gewählt, aber es läuft das Original: entweder reicht die Datei
                        // schon, oder der Server wandelt nicht um. Sagen statt schweigen.
                        if (!app.einstellungen.immerDirectPlay && neuerPlan.methode == "Direct Play") {
                            hinweis = uebersetzt("Läuft in Originalqualität. Der Server wandelt nichts um.")
                        }
                        spieler.stop()
                        starte(neuerPlan, stelle)
                    }
                }
                "gescheitert" -> hinweis = fehlertext(kontext, Exception(antwort.feldText("fehler")
                    ?: uebersetzt("Nächste Folge konnte nicht geladen werden.")))
            }
        } catch (e: CancellationException) { throw e } catch (e: Exception) {
            hinweis = fehlertext(kontext, e)
        } finally {
            wechselt = false
        }
    }

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

    // MARK: Stromwacht — Vorlage `VLCPlayer.swift` (iOS/tvOS): Netzwechsel und Haenger.
    // `:http-reconnect` greift nur, wenn die Verbindung abbricht. Steht sie, und es kommt nur nichts mehr,
    // wartet libVLC beliebig lange; reisst sie ab, meldet es ein Filmende, und der Player ging zu oder
    // schaltete in die naechste Folge. Die Schwellen entscheidet `Stromwacht` im Paket (ueber den Kern).

    /**
     * **Der Strom wird gerade neu aufgebaut** (iOS `stelltWiederHer`). Die Oberflaeche zeigt dann
     * „Verbindung unterbrochen", und der Takt meldet die letzte gute Stelle statt VLCs Zeit — die steht
     * nach einem Abriss auf dem Filmende.
     */
    var stelltWiederHer by mutableStateOf(false); private set
    private var letzteGuteStelle = 0.0
    private var stromStehtSeit: Long? = null
    private var stromLetzteZeit = -1L
    private var stromGelesen = 0L
    private var stromPufferWuchs = 0L
    private var letzteBilder = -1L
    private var bilderStehenSeit: Long? = null
    private var letzterSprung = 0L
    private var letzterNeuaufbau = 0L
    private var letzterRat = ""
    private var spurenNachAufbau = false
    private var netzErreichbar = true
    private var wartetAufNetz = false
    private var netzwechselSeit: Long? = null
    private var letztesNetz: android.net.Network? = null
    private var netzRueckruf: android.net.ConnectivityManager.NetworkCallback? = null

    private fun stromwachtZuruecksetzen() {
        stromStehtSeit = null; stromLetzteZeit = -1; stromGelesen = 0; stromPufferWuchs = SystemClock.elapsedRealtime()
        letzteBilder = -1; bilderStehenSeit = null; letzterRat = ""
    }

    private fun vonDerPlatte() = plan?.url?.startsWith("file:") != false

    /**
     * **Wohin das Netz geht** (iOS `NWPathMonitor` → `streckeGewechselt`). Ein Wechsel wird nur vermerkt:
     * ein voller Puffer spielt weiter, eingegriffen wird erst, wenn das Bild wirklich steht. War die
     * Wiedergabe schon ohne Netz stehen geblieben, wird sofort nachgeholt.
     */
    private fun netzBeobachten() {
        if (netzRueckruf != null) return
        val verwaltung = kontext.getSystemService(Context.CONNECTIVITY_SERVICE) as? android.net.ConnectivityManager ?: return
        val rueckruf = object : android.net.ConnectivityManager.NetworkCallback() {
            override fun onAvailable(netz: android.net.Network) { lauf.launch { netzDa(netz) } }
            override fun onLost(netz: android.net.Network) { lauf.launch { netzWeg(netz) } }
        }
        if (runCatching { verwaltung.registerDefaultNetworkCallback(rueckruf) }.isSuccess) netzRueckruf = rueckruf
    }

    private fun netzAbmelden() {
        val rueckruf = netzRueckruf ?: return
        netzRueckruf = null
        runCatching { (kontext.getSystemService(Context.CONNECTIVITY_SERVICE) as? android.net.ConnectivityManager)?.unregisterNetworkCallback(rueckruf) }
    }

    private fun netzDa(netz: android.net.Network) {
        val vorher = letztesNetz
        letztesNetz = netz
        netzErreichbar = true
        if (wartetAufNetz) {
            Protokoll.schreib("[Netz] wieder da → nachholen")
            wartetAufNetz = false
            neuVerbinden("Netz zurueck")
            return
        }
        if (vorher == null || vorher == netz) return
        netzwechselSeit = SystemClock.elapsedRealtime()
        Protokoll.schreib("[Netz] Wechsel — Puffer laeuft weiter")
    }

    private fun netzWeg(netz: android.net.Network) {
        if (letztesNetz != null && netz != letztesNetz) return
        netzErreichbar = false
        if (letzteGuteStelle > 1 && !vonDerPlatte()) wartetAufNetz = true
        Protokoll.schreib("[Netz] kein Weg mehr — vorgemerkt bei ${letzteGuteStelle.toInt()} s")
    }

    private fun rat(stillstand: Long, jetzt: Long) = Kern.stromwachtRat(stillstand / 1000.0,
        netzwechselSeit?.let { (jetzt - it) / 1000.0 } ?: -1.0, false,
        (jetzt - letzterSprung) / 1000.0, (jetzt - stromPufferWuchs) / 1000.0)

    /**
     * Einmal je Takt (iOS `stillstandPruefen` + `bildfluss`): steht die Uhr, obwohl VLC spielt — oder
     * laeuft sie, aber es kommt kein neues Bild —, fragt es `Stromwacht`, ob neu aufgebaut wird.
     */
    private fun stromPruefen() {
        // Vor dem ersten Bild steuert der Strom noch seine Startstelle an — das ist kein Haenger (iOS `erstStelle`).
        if (beendet[0] || wechselt || vonDerPlatte() || !bildFrei || !spieler.isPlaying) { stromStehtSeit = null; return }
        val t = spieler.time
        val jetzt = SystemClock.elapsedRealtime()
        val medium = spieler.media
        val werte = medium?.stats
        medium?.release()
        // Waechst der Puffer, lebt der Strom. VLC zaehlt in `int`; vorzeichenlos gelesen.
        val gelesen = werte?.let { it.readBytes.toLong() and 0xFFFFFFFFL } ?: 0L
        if (gelesen > stromGelesen) stromPufferWuchs = jetzt
        stromGelesen = gelesen

        if (t == stromLetzteZeit || t <= 0) {
            val seit = stromStehtSeit ?: jetzt.also { stromStehtSeit = it }
            val r = rat(jetzt - seit, jetzt)
            if (r != letzterRat && r != "nochNicht") Protokoll.schreib("[Netz] Bild steht seit ${(jetzt - seit) / 1000} s → $r")
            letzterRat = r
            if (r == "neuVerbinden") neuVerbinden("Bild steht seit ${(jetzt - seit) / 1000} s")
            return
        }
        // Die Uhr laeuft wieder: ein Neuaufbau ist geglueckt.
        if (stelltWiederHer && stromLetzteZeit > 0) {
            stelltWiederHer = false
            Protokoll.schreib("[Netz] wiederhergestellt bei ${t / 1000} s")
            if (spurenNachAufbau && spieler.audioTracksCount > 0) { spurenNachAufbau = false; sprachenAnwenden() }
        }
        stromLetzteZeit = t
        stromStehtSeit = null
        letzterRat = ""
        // **Die Uhr laeuft — aber kommt auch ein Bild?** (iOS `bildfluss`, am 05.09.2026 gemessen: 76 s
        // eingefrorenes Bild bei laufender Uhr.)
        val bilder = werte?.let { it.displayedPictures.toLong() and 0xFFFFFFFFL } ?: -1L
        if (Kern.stromwachtBilderStehen(letzteBilder, bilder)) { if (bilderStehenSeit == null) bilderStehenSeit = jetzt } else bilderStehenSeit = null
        letzteBilder = bilder
        bilderStehenSeit?.let { seit ->
            if (rat(jetzt - seit, jetzt) == "neuVerbinden") {
                bilderStehenSeit = null
                neuVerbinden("kein neues Bild seit ${(jetzt - seit) / 1000} s, Uhr laeuft weiter")
                return
            }
        }
        // Nur mitschreiben, was plausibel ist: nach einem Abriss stuende hier sonst das Filmende.
        val stelle = t / 1000.0
        if (!stelltWiederHer && (dauer <= 0 || stelle < dauer - 1)) letzteGuteStelle = stelle
    }

    /** VLC meldet Ende oder Fehler — `true`, wenn es ein Abriss war und neu aufgebaut wird. */
    private fun abriss(zustand: String): Boolean {
        if (beendet[0] || wechselt || vonDerPlatte() || !bildFrei || letzteGuteStelle <= 1) return false
        val frisch = netzwechselSeit?.let { SystemClock.elapsedRealtime() - it < Kern.stromwachtNetzwechselFrist() * 1000 } ?: false
        if (!(if (dauer > 0) letzteGuteStelle < dauer - 10 else frisch)) return false
        Protokoll.schreib("[Netz] Zustand $zustand: Strom tot bei ${letzteGuteStelle.toInt()} s von ${dauer.toInt()} s")
        lauf.launch { neuVerbinden("Strom abgerissen") }
        return true
    }

    /**
     * **Strom neu aufmachen und an die letzte gute Stelle springen** (iOS `neuVerbinden`). Ohne Netz nur
     * vormerken — `netzDa` holt es nach. Nach einem Wechsel meldet Android mehrfach; die Sperrfrist von
     * 5 s verhindert, dass der Strom in Schleife neu aufgebaut wird und nie fertig.
     */
    private fun neuVerbinden(grund: String) {
        val p = plan ?: return
        if (beendet[0] || wechselt || vonDerPlatte() || letzteGuteStelle <= 1) return
        // Schon hier: die Oberflaeche sagt, was los ist, und der Takt haelt die gute Stelle.
        stelltWiederHer = true
        if (!netzErreichbar) {
            wartetAufNetz = true
            Protokoll.schreib("[Netz] $grund, aber kein Netz — vorgemerkt bei ${letzteGuteStelle.toInt()} s")
            return
        }
        val jetzt = SystemClock.elapsedRealtime()
        val warten = 5000 - (jetzt - letzterNeuaufbau)
        if (warten > 0) {
            // Nach einem Ende oder Fehler spielt VLC nicht mehr, die Wacht schlaegt also nicht noch einmal
            // an — ohne diesen zweiten Anlauf bliebe der Hinweis fuer immer stehen.
            if (!spieler.isPlaying) lauf.launch { delay(warten); if (stelltWiederHer && !spieler.isPlaying) neuVerbinden(grund) }
            return
        }
        letzterNeuaufbau = jetzt
        Protokoll.schreib("[Netz] $grund → Strom neu aufbauen bei ${letzteGuteStelle.toInt()} s")
        stromwachtZuruecksetzen()
        ende[0] = false
        // Die Spurwahl nach `Spurregel` noch einmal, sobald der neue Strom laeuft — sonst bringt er VLCs
        // eigene Vorauswahl mit, und abgeschaltete Untertitel gingen von selbst wieder an (iOS 18.09.2026).
        spurenNachAufbau = true
        spieler.stop()
        app.kern.wiedergabeStelle(letzteGuteStelle)
        medienOeffnen(p.url, letzteGuteStelle)
    }

    fun springe(ziel: Double) {
        letzterSprung = SystemClock.elapsedRealtime()
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
        val gehaengt = spieler.addSlave(IMedia.Slave.Type.Subtitle, Uri.parse(Stromweiterleiter.gemeinsam.adresse(d.adresse)), false)
        Protokoll.schreib("[Spuren] Datei ${d.index} angehaengt $gehaengt, Merkmal ${d.merkmal}")
        if (!gehaengt) naechsteDatei()
    }

    private fun untertitelspurNeu(id: Int) {
        val d = dateiLaedt
        if (d != null && id >= 0 && id !in spurenVorDatei && id !in dateispuren) {
            dateispuren[id] = "${d.merkmal}/spu/${dateispuren.values.count { it.startsWith(d.merkmal) }}"
            Protokoll.schreib("[Spuren] Datei ${d.index} ist Spur $id")
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
            Protokoll.schreib("[Spuren] Datei ${dateiLaedt?.index} kam nicht")
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
        technikFest = JSONArray(app.kern.technikFest(app.einstellungen.technikschildMessen)).let { a ->
            (0 until a.length()).map { a.getJSONObject(it).let { o ->
                Technikzeile(o.feldText("schluessel")?.let { k -> uebersetzt(k) }, o.getString("text"), o.getString("art"), o.optBoolean("kopf"))
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
            // **Dazwischen nur die Zeit** (Vorlage iOS `beobachten`, 17.09.2026): im halben Sekundentakt lief
            // sie nach dem Abspielen verzoegert an und zaehlte ungleichmaessig.
            nurZeit = !nurZeit
            if (nurZeit) {
                if (!wechselt && bildFrei && !stelltWiederHer) {
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
            stromPruefen()
            val laenge = (spieler.length / 1000.0).coerceAtLeast(0.0)
            // Waehrend des Neuaufbaus die letzte gute Stelle, nicht VLCs Zeit: beim Abriss springt die aufs Ende.
            val gemeldet = if (stelltWiederHer) letzteGuteStelle else (spieler.time / 1000.0).coerceAtLeast(0.0)
            val antwort = JSONObject(app.kern.wiedergabeTakt(
                if (stelltWiederHer) maxOf(laenge, dauer) else laenge, gemeldet, zeigtBild[0], spieler.isPlaying,
                spieler.audioTracksCount > 0, amSchieben))
            if (antwort.optBoolean("ladeschirmWeg")) bildFrei = true
            if (antwort.optBoolean("spurenAnwenden")) sprachenAnwenden()
            dateiFrist()
            // Nach einem Sprung liefert der Kern die Zielstelle, bis VLC dort ist.
            if (!amSchieben && antwort.has("position")) position = antwort.getDouble("position")
            if (!stelltWiederHer || laenge > 0) dauer = laenge
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
 *   (17.09.2026: sofort schalten und zuruecknehmen blitzte bei jedem Doppeltipp).
 * - Die Mitte haelt an, auch bei ausgeblendeter Steuerung — wer dorthin tippt, meint den Knopf.
 * - Zwei Finger schalten hart zwischen ganzem und formatfuellendem Bild; ein weiches Zoomen, das
 *   falsch landet, wirkte auf iOS kaputter als ein Schalter.
 * - Die Stelle wird **vor** dem Anhalten gelesen: VLC setzt seine Uhr beim Anhalten zurueck.
 */
@Composable
fun PlayerSeite(app: SwiftlyAnwendung, wunsch: Abspielwunsch, imKleinenFenster: Boolean, bildImBild: () -> Boolean, schliessen: () -> Unit) {
    val kontext = LocalContext.current
    val lauf = rememberCoroutineScope()
    val ruck = rememberRuck()
    // Querformat, versteckte Systemleisten und „Bildschirm bleibt an" stellt `PlayerAktivitaet` ein, bevor das
    // erste Bild steht (Vorlage `Playerrahmen` auf iOS). Hier gesetzt, drehte der Player erst nach dem Oeffnen
    // ins Querformat, beim Schliessen noch einmal zurueck, und die Leisten blitzten beim Abbau auf.

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
    var sprung by remember { mutableStateOf<Sprung?>(null) }
    var taktZurueck by remember { mutableIntStateOf(0) }
    var taktVor by remember { mutableIntStateOf(0) }
    /**
     * **Eine der drei Ebenen** — Audio & Untertitel, Folgen, Einstellungen (Vorlage `Playerebene`
     * auf iOS). Vollbild ueber dem Video, die Steuerung darunter weicht.
     */
    var offeneEbene by remember { mutableStateOf<String?>(null) }
    /** Die zuletzt geoeffnete Ebene — bleibt beim Schliessen stehen, damit der Titel auch waehrend der Ausblende der Folgen ueber ihnen liegt (iOS c496f53). */
    var zuletztGeoeffnet by remember { mutableStateOf<String?>(null) }
    val konfiguration = LocalConfiguration.current
    val hochkant = konfiguration.orientation == Configuration.ORIENTATION_PORTRAIT
    // iOS `schmal`: Fenster unter 500 breit — hochkant auf dem Telefon.
    val schmal = konfiguration.screenWidthDp < 500
    val rand = playerRand(hochkant)

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

    // Technikschild: die festen Zeilen einmal je Titel, die gezaehlten alle zwei Sekunden — schnell genug,
    // um einem Ruckler zuzusehen, langsam genug, dass die Zahlen lesbar stehen. Laeuft nur, solange es
    // sichtbar ist: ein vergessener Zaehler waere selbst die Last, die er misst.
    LaunchedEffect(app.einstellungen.technikschild, werk.plan) { werk.technikschildTakt(app.einstellungen.technikschild) }

    // Serie und laufende Staffel vorladen, sobald der Player eine Folge zeigt — die Folgenebene
    // steht damit beim ersten Oeffnen schon da (Vorlage `FolgenEbene.vorladen` auf iOS).
    LaunchedEffect(werk.plan?.itemId) {
        val p = werk.plan
        if (p != null && p.episode && p.serieId != null) folgenVorladen(app, p.serieId, p.staffelId)
    }

    val ebeneOeffnen: (String) -> Unit = { welche -> beruehrt++; zuletztGeoeffnet = welche; offeneEbene = welche }
    val ebeneSchliessen: () -> Unit = { offeneEbene = null; sichtbar = true; beruehrt++ }

    BackHandler(enabled = offeneEbene != null) { ebeneSchliessen() }
    BackHandler(enabled = offeneEbene == null) { werk.beenden(schliessen) }

    // Oeffnen, dann der Takt.
    LaunchedEffect(wunsch) { werk.oeffnenUndTakt(wunsch, schliessen) }

    val blattOffen = app.blatt.value != null
    // Die Einblendung hoert auf die gewollte Steuerung (Vorlage `onChange(of: steuerungSichtbar)` auf iOS):
    // beim Oeffnen steht sie schon auf „an", ihr erstes Ausblenden schickt „Rückblick überspringen" nicht weg.
    LaunchedEffect(sichtbar) { werk.steuerungGeaendert(sichtbar) }
    // Im Stehen nichts wegnehmen, beim Spulen nicht, und nicht, solange eine Ebene offen ist (iOS `!ebeneOffen`).
    LaunchedEffect(sichtbar, werk.laeuft, werk.amSchieben, blattOffen, beruehrt, offeneEbene) {
        if (sichtbar && werk.laeuft && !werk.amSchieben && !blattOffen && offeneEbene == null) { delay(4000); sichtbar = false }
    }
    LaunchedEffect(werk.hinweis) { if (werk.hinweis != null) { delay(5000); werk.hinweis = null } }
    LaunchedEffect(sprung) { if (sprung != null) { delay(700); sprung = null } }

    /** Vorlage `spulen` auf iOS: Knopf und Doppeltipp springen gleich, beide mit Rueckmeldung am Rand. */
    val spulen: (Int) -> Unit = { richtung ->
        val sekunden = if (richtung < 0) werk.zurueckS else werk.vorS
        werk.springe(werk.position + richtung * sekunden.toDouble())
        if (richtung < 0) taktZurueck++ else taktVor++
        sprung = Sprung(richtung, sekunden, if (richtung < 0) taktZurueck else taktVor)
        if (sichtbar) beruehrt++
    }

    // **Wann was zu sehen ist** — dieselben drei Fragen wie auf iOS:
    // `schleierDa` (Steuerung gewollt, Bild steht, nicht im kleinen Fenster), `steuerungDa` (dazu keine
    // Ebene offen) und der stehende Titel (Steuerung oder Folgenebene). Vor dem ersten Bild keine
    // Steuerung — sonst lag sie ueber dem Ladeschirm, und beim Folgenwechsel tauchte der Titel auf und ab.
    val ebeneOffen = offeneEbene != null
    val schleierDa = sichtbar && werk.bildFrei && !imKleinenFenster
    val steuerungDa = schleierDa && !ebeneOffen
    val titelDa = (steuerungDa || offeneEbene == "folgen") && !imKleinenFenster
    val schleierDeckung by animateFloatAsState(if (schleierDa) 1f else 0f, blendkurve(schleierDa, false), label = "schleier")
    val steuerungDeckung by animateFloatAsState(if (steuerungDa) 1f else 0f, blendkurve(steuerungDa, ebeneOffen), label = "steuerung")
    val titelDeckung by animateFloatAsState(if (titelDa) 1f else 0f, blendkurve(titelDa, ebeneOffen), label = "titel")

    val plan = werk.plan
    val hatFolgen = plan?.episode == true && plan.serieId != null
    val titel = plan?.kopfzeile?.takeIf { it.isNotEmpty() } ?: plan?.titel.orEmpty()
    val meta = plan?.let {
        if (it.episode && it.staffelNr != null && it.folgeNr != null) uebersetzt("Staffel %lld · Folge %lld", it.staffelNr, it.folgeNr)
        else if (it.episode) it.untertitel.takeIf { u -> u.isNotEmpty() }
        else it.nebenzeile?.takeIf { n -> n.isNotEmpty() }
    }
    // iOS `unten = -10`: die Trefferflaeche der Leiste ragt etwas in den sicheren Bereich, die sichtbare
    // Leiste sitzt so knapp ueber dem Gestenbalken (iOS cb6af09).
    val fussUnten = (rand.unten + Playermass.unten).coerceAtLeast(0.dp)

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        AndroidView(factory = { ctx -> VLCVideoLayout(ctx).also { flaeche[0] = it; werk.spieler.attachViews(it, null, true, false) } },
                    modifier = Modifier.fillMaxSize())

        // **Tippflaechen** — ueber dem Bild, unter der Steuerung. Vorlage `tippflaechen` + `tippen(richtung:)`:
        // **der erste Tipp schaltet sofort, nichts wird zurueckgenommen** (17.09.2026). Ein zweiter auf
        // derselben Seite binnen 260 ms spult und laesst die Steuerung, wie der erste sie gestellt hat.
        Box(Modifier.fillMaxSize()
            .pointerInput(Unit) {
                var letzter = 0L
                var letzteSeite = 0
                detectTapGestures(onTap = { stelle ->
                    val seite = if (stelle.x < size.width / 2) -1 else 1
                    val jetzt = SystemClock.elapsedRealtime()
                    if (jetzt - letzter < 260 && seite == letzteSeite) {
                        letzter = 0L
                        spulen(seite)
                    } else {
                        letzter = jetzt
                        letzteSeite = seite
                        sichtbar = !sichtbar
                        beruehrt++
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
            }) {
            // Wo der Pause-Knopf sitzt, haelt ein Tipp auch dann an, wenn er ausgeblendet ist. Liegt unter der
            // Steuerung: ist die sichtbar, faengt der echte Knopf den Tipp ab.
            if (werk.bildFrei && !imKleinenFenster) Box(Modifier.align(Alignment.Center).size(108.dp, 132.dp).tippen { werk.umschalten() })
        }

        // **Startschleier** — schwarz, bis VLC das erste Bild hat; Schliessen geht schon vorher, an der Stelle
        // des X der Steuerung (Vorlage `startschleier`). Geht mit 0,3 s easeOut, wie `erstesBildDa` auf iOS.
        AnimatedVisibility(!werk.bildFrei, enter = EnterTransition.None, exit = fadeOut(tween(300, easing = EaseOut))) {
            Box(Modifier.fillMaxSize().background(Color.Black)) {
                val h = werk.hinweis
                if (h == null) Lader(Modifier.align(Alignment.Center))
                else Text(h, style = Stil.koerper.copy(textAlign = TextAlign.Center), color = Stil.schriftLeise,
                          modifier = Modifier.align(Alignment.Center).padding(horizontal = 48.dp))
                Row(Modifier.fillMaxWidth().padding(start = rand.seite, end = rand.seite, top = rand.oben)
                        .padding(horizontal = Playermass.seite).padding(top = Playermass.oben),
                    horizontalArrangement = Arrangement.End) {
                    Symbolknopf(Zeichen.Kreuz, uebersetzt("Player schließen")) { werk.beenden(schliessen) }
                }
            }
        }

        // **Verbindung unterbrochen** (Vorlage `verbindungsHinweis` auf iOS) — kein Fehler, sondern ein
        // Zwischenstand, deshalb ruhig und ohne Knopf. Sobald der Strom wieder laeuft, geht er von selbst.
        AnimatedVisibility(werk.stelltWiederHer && werk.bildFrei && !imKleinenFenster, Modifier.align(Alignment.Center),
                           enter = fadeIn(tween(200)), exit = fadeOut(tween(200))) {
            Column(Modifier.clip(RoundedCornerShape(Stil.ecke)).background(Color.Black.copy(alpha = 0.7f))
                    .padding(horizontal = 22.dp, vertical = 18.dp).clearAndSetSemantics {},
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Lader(groesse = 26.dp, staerke = 2.5.dp)
                Text(uebersetzt("Verbindung unterbrochen"), style = Stil.listentitel, color = Stil.schrift)
                Text(uebersetzt("Läuft weiter, sobald das Netz zurück ist."), style = Stil.klein, color = Stil.schriftLeise)
            }
        }

        // `Playerschleier` — flach, reines Schwarz 42 % (iOS d75c1c7: `Stil.grund` hob HDR-Video an).
        Box(Modifier.fillMaxSize().graphicsLayer { alpha = schleierDeckung.coerceIn(0f, 1f) }.background(Color.Black.copy(alpha = 0.42f)))

        // **Das Technikschild.** Eine Auskunft, kein Bedienteil. **Direkt auf dem Film** (Vorlage c85ea8bf):
        // ueber dem Schleier, damit es lesbar bleibt, aber unter Titel, Knoepfen und Leiste — und damit auch
        // unter den Ebenen. **Es gleitet mit der Steuerung** (71832e36): offen steht es unter der Titelzeile,
        // zu rueckt es an den oberen Rand, wo sie stand. Bewegung statt Blende, dieselbe Kurve wie die
        // Steuerung; mit reduzierter Bewegung springt es.
        if (app.einstellungen.technikschild && !imKleinenFenster && werk.technikFest.isNotEmpty()) {
            val reduziert = bewegungReduziert()
            val hoch by animateFloatAsState(if (steuerungDa) 0f else 1f,
                if (reduziert) snap() else blendkurve(steuerungDa, ebeneOffen), label = "technikschild")
            val weg = with(LocalDensity.current) { (Playermass.knopf + Stil.kachelAbstand).toPx() }
            Box(Modifier.fillMaxSize()
                    .padding(start = rand.seite + Playermass.seite, top = rand.oben + Playermass.oben + Playermass.knopf + Stil.kachelAbstand)
                    .offset { IntOffset(0, -(hoch * weg).roundToInt()) }) {
                Technikschild(werk.technikFest, werk.technikLive, werk.position, werk.dauer,
                              app.einstellungen.technikschildMessen, fern = false)
            }
        }

        // **Die Steuerung bleibt stehen und blendet nur ihre Deckkraft** — Vorlage `.opacity(steuerungDa ? 1 : 0)`
        // statt `if`. Vorher wurde sie bei jedem Tipp ein- und ausgehaengt; der Titel darueber sprang hart,
        // waehrend der Rest noch blendete. Ausgeblendet nimmt sie keinen Tipp an.
        val aktiv = steuerungDa
        val symboleDa = aktiv && !werk.amSchieben
        Box(Modifier.fillMaxSize().graphicsLayer { alpha = steuerungDeckung.coerceIn(0f, 1f) }) {
            // **Mitte des Bildschirms, nicht des sicheren Bereichs** (iOS cb6af09): quer ist unten mehr frei als oben.
            // Beim Spulen zaehlt nur die Leiste — die Mitte weicht.
            Mittelsteuerung(werk.laeuft, werk.zurueckS, werk.vorS, taktZurueck, taktVor, schmal, symboleDa,
                Modifier.align(Alignment.Center).graphicsLayer { alpha = if (werk.amSchieben) 0f else 1f },
                zurueck = { spulen(-1) }, umschalten = { werk.umschalten() }, vor = { spulen(1) })

            Column(Modifier.fillMaxSize().padding(start = rand.seite, end = rand.seite, top = rand.oben, bottom = fussUnten)) {
                // **Kopf:** Titel-Platzhalter (gezeigt wird `stehenderTitel` darueber), darunter leise die
                // Metazeile; rechts nur Symbole — beim Spulen weichen sie, der Titel bleibt.
                Row(Modifier.fillMaxWidth().padding(horizontal = Playermass.seite).padding(top = Playermass.oben),
                    verticalAlignment = Alignment.Top) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        Text(titel, style = titelStil, maxLines = 1, modifier = Modifier.alpha(0f).clearAndSetSemantics {})
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                            meta?.let { Text(it, style = metaStil, color = Stil.schriftLeise, maxLines = 1, overflow = TextOverflow.Ellipsis,
                                              modifier = Modifier.weight(1f, fill = false)) }
                            if (plan != null && !plan.lossless) Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
                                Symbol(Zeichen.Warnung, 12.dp, farbe = Stil.warnung)
                                Text(plan.methode, style = metaStil, color = Stil.warnung, maxLines = 1)
                            }
                        }
                    }
                    Spacer(Modifier.width(12.dp))
                    Symbolreihe(hatFolgen, symboleDa, Modifier.graphicsLayer { alpha = if (werk.amSchieben) 0f else 1f },
                                ebeneOeffnen) { werk.beenden(schliessen) }
                }
                werk.hinweis?.let {
                    Text(it, style = Stil.klein.copy(textAlign = TextAlign.Center), color = Stil.schriftLeise,
                         modifier = Modifier.fillMaxWidth().padding(horizontal = Playermass.seite).padding(top = 10.dp))
                }
                Spacer(Modifier.weight(1f))
                // **Die Leiste ueber die volle Breite**, Zeit links, Restzeit rechts (Vorlage `fuss`).
                Box(Modifier.fillMaxWidth().height(Playermass.leiste).padding(horizontal = Playermass.seite)) {
                    Zeitzeile(werk.position, werk.dauer, werk.amSchieben, aktiv, werk.plan?.marken.orEmpty(), { werk.trickplayBild(it) },
                              { werk.amSchieben = it; beruehrt++ }) { werk.springe(it) }
                }
            }
        }

        // **Der Angebotsknopf** — „Intro überspringen" / „Nächste Folge" (Vorlage `angebotDa` in
        // `Sources/iOS/PlayerScreen.swift`). **An einer Stelle, egal ob die Steuerung offen ist**: rechts direkt
        // ueber der Leiste, mit denselben Massen wie der Fuss. Weg beim Spulen oder waehrend eine Ebene offen ist.
        // Absagen: Zurueck (iOS: Wischen mit zwei Fingern) — kein eigenes X, wie auf iOS.
        val karteDa = werk.einblendung != "nichts" && werk.bildFrei && !steuerungDa && offeneEbene == null && !blattOffen
            && !imKleinenFenster && !werk.wechselt && !werk.amSchieben
        val angebotDa = werk.angebotArt != "keiner" && werk.angebotText.isNotEmpty() && werk.bildFrei && offeneEbene == null
            && !blattOffen && !imKleinenFenster && !werk.wechselt && !werk.amSchieben
            && (werk.einblendung != "nichts" || (steuerungDa && werk.angebotArt == "naechste"))
        BackHandler(enabled = karteDa) { werk.angebotSchliessen() }
        Box(Modifier.fillMaxSize().padding(start = rand.seite, end = rand.seite, bottom = fussUnten + Playermass.leiste + Playermass.ueberLeiste)
                .padding(horizontal = Playermass.seite),
            contentAlignment = Alignment.BottomEnd) {
            AnimatedVisibility(visible = angebotDa, enter = fadeIn(aufblenden), exit = fadeOut(zublenden)) {
                Angebotspille(werk.angebotArt, werk.angebotText, werk.countdown.takeIf { werk.einblendung == "karte" },
                              werk.countdownRest.takeIf { werk.einblendung == "karte" }, werk) {
                    werk.angebotAusfuehren()
                }
            }
        }

        // Rueckmeldung beim Spulen — dieselbe Drehung wie auf den Knoepfen (Vorlage `sprungRueckmeldung`).
        val gemerkterSprung = remember { arrayOfNulls<Sprung>(1) }
        sprung?.let { gemerkterSprung[0] = it }
        AnimatedVisibility(sprung != null, enter = fadeIn(tween(150, easing = EaseInOut)), exit = fadeOut(tween(150, easing = EaseInOut))) {
            gemerkterSprung[0]?.let { s ->
                Box(Modifier.fillMaxSize().padding(horizontal = rand.seite).padding(horizontal = 44.dp),
                    contentAlignment = if (s.richtung < 0) Alignment.CenterStart else Alignment.CenterEnd) {
                    key(s.richtung, s.takt) { Sprungmarke(s.richtung, s.sekunden) }
                }
            }
        }

        // Waehrend des Folgenwechsels laeuft die alte Folge weiter — der Ring sagt, dass etwas kommt.
        if (werk.bildFrei && werk.wechselt) Lader(Modifier.align(Alignment.Center))

        // **Die drei Ebenen** — Vollbild ueber dem Video, blenden 0,2 s easeOut; die Steuerung darunter weicht
        // im selben Takt (`blendkurve`, iOS cb6af09).
        AnimatedContent(targetState = if (imKleinenFenster) null else offeneEbene, modifier = Modifier.fillMaxSize().zIndex(5f),
            transitionSpec = { fadeIn(ebenenKurve) togetherWith fadeOut(ebenenKurve) }, label = "ebene") { ebene ->
            when (ebene) {
                "spuren" -> SpurenEbene(werk, rand, hochkant, ebeneSchliessen)
                "einstellungen" -> EinstellungenEbene(app, werk, rand, hochkant, ebeneSchliessen)
                "folgen" -> {
                    val p = werk.plan
                    if (p != null && p.serieId != null) FolgenEbene(app, p.serieId, p.itemId, p.staffelId, titel, rand,
                        schliessen = ebeneSchliessen,
                        starten = { id -> ebeneSchliessen(); if (id != p.itemId) lauf.launch { werk.wechsleZu(id) } })
                }
                else -> Box(Modifier.fillMaxSize())
            }
        }

        // **Der stehende Titel** (Vorlage `stehenderTitel`). Bei der Folgenebene liegt er ueber ihr und bleibt
        // stehen — auch waehrend ihrer Ausblende (`zuletztGeoeffnet`). Bei den anderen Ebenen liegt er darunter
        // und verschwindet zusammen mit der Metazeile (iOS e77b86a, c496f53). Eine Zeile, gekuerzt mit „…".
        Row(Modifier.fillMaxWidth().zIndex(if (zuletztGeoeffnet == "folgen") 6f else 3f)
                .padding(start = rand.seite, end = rand.seite, top = rand.oben)
                .padding(horizontal = Playermass.seite).padding(top = Playermass.oben)
                .graphicsLayer { alpha = titelDeckung.coerceIn(0f, 1f) }) {
            Text(titel, style = titelStil, color = Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis,
                 modifier = Modifier.weight(1f))
            // Platz der Symbolreihe, damit der Titel genauso breit wird wie im Kopf.
            Spacer(Modifier.width(12.dp + symbolreihenBreite(hatFolgen)))
        }
    }
}

// MARK: Masse und Kurven — Vorlage `Playermass` in `Sources/iOS/PlayerEbenen.swift` (iPhone-Werte).

/** Alle Masse des Players an einer Stelle — geteilt mit den Ebenen, damit deren X genau auf dem X des Players liegt. */
private object Playermass {
    /** Rand links und rechts, innerhalb des sicheren Bereichs — `Stil.rand(breit: false)`. */
    val seite = Stil.randAbstand
    val oben = 16.dp
    /** Ueber dem sicheren Bereich unten; negativ: die Trefferflaeche ragt hinein (iOS cb6af09). */
    val unten = (-10).dp
    /** Trefferflaeche der Symbolknoepfe. */
    val knopf = 44.dp
    /** Abstand der Ueberspringen-Pille ueber der Leiste. */
    val ueberLeiste = 20.dp
    /** Hoehe der Zeitzeile — die Trefferflaeche des Reglers. */
    val leiste = 44.dp
}

/**
 * **Der Player steht auf derselben Leiter wie der Rest.** Er fuehrte eine zweite (19 Bold /
 * 14 / 13) — auf Apple ist die am 21.09. eingesammelt worden, hier bis jetzt nicht. Titel 20,
 * Angabe 12, Zeit 13 (BAUTEILE 8). **Bold gibt es nur am Seitentitel**, und der Titel im
 * Player ist eine Leistenzeile, kein Seitentitel.
 */
private val titelStil = Stil.reihe
private val metaStil = Stil.klein

/**
 * **Der sichere Bereich des Players** — was auf iOS nach `.ignoresSafeArea(edges: mass.obenUebergehen)` bleibt.
 * Waagerecht die Aussparung, **auf beiden Seiten gleich** (quer ist der sichere Bereich des iPhones symmetrisch;
 * nur eine Seite eingerueckt stand der Kopf schief). Oben nur hochkant, unten der Gestenbalken.
 *
 * Immer die Werte **ohne Sichtbarkeit**: die Systemleisten sind im Player versteckt und kommen beim Wischen
 * kurz herein. Mit den sichtbaren Werten sprangen Kopf und Leiste dabei jedes Mal.
 */
private data class Rand(val seite: Dp, val oben: Dp, val unten: Dp)

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun playerRand(hochkant: Boolean): Rand {
    val dichte = LocalDensity.current
    val richtung = LocalLayoutDirection.current
    val aussparung = WindowInsets.displayCutout
    val seite = maxOf(aussparung.getLeft(dichte, richtung), aussparung.getRight(dichte, richtung))
    val oben = if (hochkant) maxOf(aussparung.getTop(dichte), WindowInsets.statusBarsIgnoringVisibility.getTop(dichte)) else 0
    val unten = WindowInsets.navigationBarsIgnoringVisibility.getBottom(dichte)
    return with(dichte) { Rand(seite.toDp(), oben.toDp(), unten.toDp()) }
}

/** `.snappy(duration: 0.18, extraBounce: 0)` — eine Feder (Antwortzeit 0,18 s, bounce 0,15): ein zweiter Tipp muss nicht warten. */
private val aufblenden: FiniteAnimationSpec<Float> = spring(dampingRatio = 0.85f, stiffness = 1218f, visibilityThreshold = 0.001f)
/** `.smooth(duration: 0.34)` — gemaechlich, ohne Nachfedern. */
private val zublenden: FiniteAnimationSpec<Float> = spring(dampingRatio = 1f, stiffness = 341f, visibilityThreshold = 0.001f)
/** `PlayerScreen.ebenenKurve` — `.easeOut(duration: 0.2)`: die Ebenen und, waehrend eine aufgeht, die Steuerung. */
private val ebenenKurve: FiniteAnimationSpec<Float> = tween(200, easing = EaseOut)

/** `PlayerScreen.kurve(da:ebene:)` — schnell auf, gemaechlich zu; nimmt eine Ebene den Platz ein, im Takt der Ebene. */
private fun blendkurve(da: Boolean, ebene: Boolean) = if (da) aufblenden else if (ebene) ebenenKurve else zublenden

/** Ein Sprung zum Anzeigen: Richtung, Sekunden und ein Takt, damit zwei Spruenge hintereinander neu drehen. */
private data class Sprung(val richtung: Int, val sekunden: Int, val takt: Int)

// MARK: Bausteine

/**
 * **Druecken wie ein iOS-Knopf** — keine Welle, kein Schatten: das Zeichen wird beim Aufsetzen blass und
 * blendet beim Loslassen zurueck. Ausgeblendet (`aktiv == false`) nimmt der Knopf keinen Tipp an; der geht
 * dann an die Tippflaechen darunter (iOS `allowsHitTesting`).
 */
private fun Modifier.symboldruck(aktiv: Boolean, beschreibung: String, tun: () -> Unit): Modifier = composed {
    val quelle = remember { MutableInteractionSource() }
    val gedrueckt by quelle.collectIsPressedAsState()
    val deckung by animateFloatAsState(if (gedrueckt) 0.35f else 1f,
        if (gedrueckt) snap() else tween(200, easing = EaseOut), label = "druck")
    val klick = if (aktiv) Modifier.clickable(interactionSource = quelle, indication = null, role = Role.Button, onClick = tun)
                    .semantics { contentDescription = beschreibung }
                else Modifier
    this.then(klick).graphicsLayer { alpha = deckung }
}

/**
 * `.symbolEffect(.bounce, options: .speed(1.7))` — spielt einmal ab und kehrt von selbst in die Ruhelage
 * zurueck. Kurz groesser, dann federnd zurueck.
 */
private fun Modifier.huepfen(takt: Int): Modifier = composed {
    val skala = remember { Animatable(1f) }
    LaunchedEffect(takt) {
        if (takt == 0) return@LaunchedEffect
        skala.animateTo(1.16f, tween(80, easing = EaseOut))
        skala.animateTo(1f, spring(dampingRatio = 0.5f, stiffness = 700f))
    }
    graphicsLayer { scaleX = skala.value; scaleY = skala.value }
}

/** Einer der Symbolknoepfe oben rechts — im Player wie auf den Ebenen (`Symbolknopf`): 44 Trefferflaeche, weiss. */
@Composable
private fun Symbolknopf(symbol: Zeichen, beschreibung: String, aktiv: Boolean = true, tun: () -> Unit) {
    Box(Modifier.size(Playermass.knopf).symboldruck(aktiv, beschreibung, tun), contentAlignment = Alignment.Center) {
        // `mass.symbol`: 19 Medium, weiss.
        Symbol(symbol, 19.dp, farbe = Color.White, staerke = Staerke.Mittel)
    }
}

/** Die Knoepfe oben rechts — Abstand 2 wie `symbolreihe` auf dem iPhone. */
@Composable
private fun Symbolreihe(hatFolgen: Boolean, aktiv: Boolean, modifier: Modifier, oeffnen: (String) -> Unit, schliessen: () -> Unit) {
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        Symbolknopf(Zeichen.Untertitel, uebersetzt("Audio & Untertitel"), aktiv) { oeffnen("spuren") }
        if (hatFolgen) Symbolknopf(Zeichen.Stapel, uebersetzt("Folgen"), aktiv) { oeffnen("folgen") }
        Symbolknopf(Zeichen.Regler, uebersetzt("Einstellungen"), aktiv) { oeffnen("einstellungen") }
        Symbolknopf(Zeichen.Kreuz, uebersetzt("Player schließen"), aktiv) { schliessen() }
    }
}

private fun symbolreihenBreite(hatFolgen: Boolean): Dp {
    val anzahl = if (hatFolgen) 4 else 3
    return Playermass.knopf * anzahl + 2.dp * (anzahl - 1)
}

/**
 * Mittig im Bild — Vorlage `mittelsteuerung`: Kante 46 (schmal 40) fuer die Spulknoepfe, 78 (60) fuer
 * Pause, Abstand 52 (34). Vorwaerts und rueckwaerts dasselbe Zeichen, gespiegelt, mit der Spanne darin.
 */
@Composable
private fun Mittelsteuerung(laeuft: Boolean, zurueckS: Int, vorS: Int, taktZurueck: Int, taktVor: Int, schmal: Boolean,
                            aktiv: Boolean, modifier: Modifier, zurueck: () -> Unit, umschalten: () -> Unit, vor: () -> Unit) {
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(if (schmal) 34.dp else 52.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Spulknopf(true, zurueckS, taktZurueck, schmal, aktiv, uebersetzt("%lld Sekunden zurück", zurueckS), zurueck)
        Pauseknopf(laeuft, schmal, aktiv, umschalten)
        Spulknopf(false, vorS, taktVor, schmal, aktiv, uebersetzt("%lld Sekunden vor", vorS), vor)
    }
}

@Composable
private fun Spulknopf(zurueck: Boolean, sekunden: Int, takt: Int, schmal: Boolean, aktiv: Boolean, beschreibung: String, tun: () -> Unit) {
    // `gobackward.10` bei 30 pt (schmal 24), Medium. Material hat den Pfeilkreis mit Zahl nur fuer 5, 10
    // und 30 Sekunden — deshalb fuer jede Spanne derselbe leere Kreis mit eigener Ziffer darin, damit
    // 15 nicht anders aussieht als 10.
    val glyphe = if (schmal) 24.dp else 30.dp
    val ziffer = with(LocalDensity.current) { (glyphe * 0.37f).toSp() }
    Box(Modifier.size(if (schmal) 40.dp else 46.dp).symboldruck(aktiv, beschreibung, tun), contentAlignment = Alignment.Center) {
        Box(Modifier.huepfen(takt), contentAlignment = Alignment.Center) {
            Symbol(if (zurueck) Zeichen.Zurueckspulen else Zeichen.Vorspulen, glyphe, farbe = Color.White, staerke = Staerke.Mittel)
            // Der Kreis sitzt 4 % unter der Mitte des Zeichens (Pfeilspitze oben).
            Text("$sekunden", style = TextStyle(fontSize = ziffer, fontWeight = FontWeight.SemiBold, fontFeatureSettings = "tnum",
                                                letterSpacing = (-0.2).sp),
                 color = Color.White, maxLines = 1, modifier = Modifier.offset(y = glyphe * 0.04f))
        }
    }
}

/** `pause.fill` / `play.fill` bei 48 pt (schmal 36) — Austausch ohne Vorbeischieben (`.replace.offUp`): muss sofort umspringen. */
@Composable
private fun Pauseknopf(laeuft: Boolean, schmal: Boolean, aktiv: Boolean, tun: () -> Unit) {
    val skala = if (schmal) 0.75f else 1f
    Box(Modifier.size(if (schmal) 60.dp else 78.dp).symboldruck(aktiv, uebersetzt(if (laeuft) "Anhalten" else "Abspielen"), tun),
        contentAlignment = Alignment.Center) {
        AnimatedContent(laeuft, contentAlignment = Alignment.Center, label = "pause",
            transitionSpec = {
                (fadeIn(tween(90)) + scaleIn(spring(dampingRatio = 0.8f, stiffness = 900f), initialScale = 0.5f)) togetherWith
                    (fadeOut(tween(60)) + scaleOut(tween(60), targetScale = 0.5f)) using SizeTransform(clip = false)
            }) { an ->
            // `pause.fill` / `play.fill`, 48 (schmal 36) Medium.
            Symbol(if (an) Zeichen.Pause else Zeichen.Abspielen, 48.dp * skala, farbe = Color.White, staerke = Staerke.Mittel)
        }
    }
}

/** Rueckmeldung beim Spulen (Vorlage `Sprungmarke`): 108 rund, schwarz 45 %, Zeichen 32, darunter „10 s". */
@Composable
private fun Sprungmarke(richtung: Int, sekunden: Int) {
    var gedreht by remember { mutableIntStateOf(0) }
    LaunchedEffect(Unit) { gedreht = 1 }
    Column(Modifier.size(108.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.45f)),
        verticalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterVertically), horizontalAlignment = Alignment.CenterHorizontally) {
        Symbol(if (richtung > 0) Zeichen.Vorspulen else Zeichen.Zurueckspulen, 32.dp, Modifier.huepfen(gedreht),
               farbe = Color.White, staerke = Staerke.Mittel)
        Text(uebersetzt("%lld s", sekunden), style = Stil.kachel, color = Color.White)
    }
}

/** Vorlage `Lader`: ein Bogen in Akzentfarbe, 0,7 s je Umdrehung, linear. */
@Composable
private fun Lader(modifier: Modifier = Modifier, groesse: Dp = 34.dp, staerke: Dp = 3.dp) {
    val drehung by rememberInfiniteTransition(label = "lader")
        .animateFloat(0f, 360f, infiniteRepeatable(tween(700, easing = LinearEasing)), label = "drehung")
    Canvas(modifier.size(groesse).graphicsLayer { rotationZ = drehung }) {
        val s = staerke.toPx()
        drawArc(Stil.akzent, 0f, 0.22f * 360f, useCenter = false, topLeft = Offset(s / 2, s / 2),
                size = Size(size.width - s, size.height - s), style = Stroke(s, cap = StrokeCap.Round))
    }
}

/**
 * Vorlage: `Zeitzeile` + `Zeitregler` auf iOS. Zeit links, Restzeit rechts, 13 mit gleich breiten Ziffern,
 * leise. **Im Stehen nur der Strich** (4 dick), **beim Spulen 6 und ein Griff in Akzentfarbe** — die einzige
 * Akzentstelle im Player; der gespielte Teil bleibt weiss. Darueber, nur beim Spulen, die Trickplay-Vorschau
 * mit Zeit, knapp ueber der Trefferflaeche und ueber dem Griff.
 */
@Composable
private fun Zeitzeile(position: Double, dauer: Double, amSchieben: Boolean, aktiv: Boolean, marken: List<Double>,
                      vorschau: (Double) -> android.graphics.Bitmap?,
                      schieben: (Boolean) -> Unit, springen: (Double) -> Unit) {
    var ziel by remember { mutableStateOf<Double?>(null) }
    val gezeigt = ziel ?: position
    val ziffern = Stil.kachel.copy(fontWeight = FontWeight.Normal, fontFeatureSettings = "tnum")
    val dicke by animateDpAsState(if (amSchieben) 6.dp else 4.dp, Bewegung.umschalten(), label = "spur")
    val griffSkala by animateFloatAsState(if (amSchieben) 1f else 0.4f, Bewegung.umschalten(), label = "griffSkala")
    val griffDeckung by animateFloatAsState(if (amSchieben) 1f else 0f, Bewegung.umschalten(), label = "griffDeckung")
    val laenge by rememberUpdatedState(dauer)
    val schiebenJetzt by rememberUpdatedState(schieben)
    val springenJetzt by rememberUpdatedState(springen)
    Row(Modifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Text(zeitText(gezeigt), style = ziffern, color = Stil.schriftLeise)
        BoxWithConstraints(Modifier.weight(1f).fillMaxHeight()
            // **Greift sofort, ohne Schwelle** — wie `DragGesture(minimumDistance: 0)`: schon das Aufsetzen
            // macht die Leiste dick, zeigt den Griff und stellt die Stelle. Loslassen springt.
            .then(if (aktiv) Modifier.pointerInput(Unit) {
                awaitEachGesture {
                    val runter = awaitFirstDown()
                    runter.consume()
                    fun stelle(x: Float) = (x / size.width).coerceIn(0f, 1f).toDouble() * laenge
                    ziel = stelle(runter.position.x)
                    schiebenJetzt(true)
                    // Auch bei Abbruch (Leiste ausgeblendet, zweiter Finger) nicht im Spulen haengen bleiben.
                    var losgelassen = false
                    try {
                        while (true) {
                            val ereignis = awaitPointerEvent()
                            val finger = ereignis.changes.firstOrNull { it.id == runter.id } ?: break
                            if (!finger.pressed) break
                            ziel = stelle(finger.position.x)
                            finger.consume()
                        }
                        losgelassen = true
                    } finally {
                        if (losgelassen) ziel?.let { springenJetzt(it) }
                        ziel = null
                        schiebenJetzt(false)
                    }
                }
            } else Modifier)
            // TalkBack liest die Stelle vor und kann sie verstellen — wie `accessibilityAdjustableAction`.
            .semantics {
                stateDescription = zeitText(gezeigt) + " / " + zeitText(dauer)
                if (dauer > 0) progressBarRangeInfo = ProgressBarRangeInfo(gezeigt.toFloat().coerceIn(0f, dauer.toFloat()), 0f..dauer.toFloat())
                setProgress { wert -> springen(wert.toDouble()); true }
            },
            contentAlignment = Alignment.CenterStart) {
            val anteil = if (dauer > 0) (gezeigt / dauer).toFloat().coerceIn(0f, 1f) else 0f
            val breite = maxWidth
            val spur = Modifier.height(dicke).clip(CircleShape)
            // Spur weiss 18 %.
            Box(Modifier.fillMaxWidth().then(spur).background(Color.White.copy(alpha = 0.18f)))
            Box(Modifier.width(breite * anteil).then(spur).background(Color.White))
            // **Kerben an den Abschnittsgrenzen**, 2 breit in `grund` — wo der Vorspann anfaengt, sagt
            // allein noch nicht, wo er aufhoert, und genau das will man sehen, bevor man greift.
            if (dauer > 0) marken.map { (it / dauer).toFloat() }.filter { it > 0.01f && it < 0.99f }.forEach { stelle ->
                Box(Modifier.offset(x = breite * stelle - 1.dp).width(2.dp).height(dicke).background(Stil.grund))
            }
            Box(Modifier.offset(x = breite * anteil - 9.dp).size(18.dp)
                .graphicsLayer { scaleX = griffSkala; scaleY = griffSkala; alpha = griffDeckung }
                .clip(CircleShape).background(Stil.akzent))
            if (amSchieben) {
                val bild = vorschau(gezeigt)
                // Unterkante 2 ueber der Trefferflaeche, waagerecht ueber dem Griff; am Rand bleibt der Kasten
                // ganz auf der Leiste stehen.
                Column(Modifier.align(Alignment.TopStart).layout { messbar, _ ->
                        val p = messbar.measure(Constraints())
                        layout(0, 0) {
                            val gesamt = breite.roundToPx()
                            val halb = p.width / 2
                            val x = (gesamt * anteil).roundToInt().coerceIn(halb, maxOf(gesamt - halb, halb)) - halb
                            p.place(x, -p.height - 2.dp.roundToPx())
                        }
                    },
                    horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    bild?.let {
                        Image(it.asImageBitmap(), contentDescription = null, contentScale = ContentScale.Crop,
                            modifier = Modifier.size(160.dp, 90.dp).clip(RoundedCornerShape(Stil.ecke))
                                .border(1.dp, Stil.rand, RoundedCornerShape(Stil.ecke)))
                    }
                    // Semibold, nicht Bold; auf eigener Kapsel, weil hier kein Schleier liegt.
                    Text(zeitText(gezeigt), style = ziffern.copy(fontWeight = FontWeight.SemiBold), color = Stil.schrift,
                         modifier = Modifier.clip(CircleShape).background(Stil.grund.copy(alpha = 0.82f)).padding(horizontal = 8.dp, vertical = 3.dp))
                }
            }
        }
        Text("−" + zeitText((dauer - gezeigt).coerceAtLeast(0.0)), style = ziffern, color = Stil.schriftLeise)
    }
}

// MARK: Die drei Ebenen — Vorlage `PlayerEbenen.swift` auf iOS.

/**
 * **Grund jeder Ebene:** reines Schwarz, nimmt jeden Tipp an (tut nichts damit), damit darunter nichts spult.
 *
 * **Ohne Weichzeichner.** iOS legt `.ultraThinMaterial` unter 72 % Schwarz. VLC zeichnet hier in eine
 * `SurfaceView` (`attachViews(…, useTextureView = false)`); deren Bild setzt das System getrennt zusammen,
 * ein `RenderEffect` auf der Ansicht erreicht es nicht — der Weichzeichner, der dort stand, lief ins Leere.
 * Ersatz: etwas mehr Schwarz, damit das scharfe Bild darunter so ruhig wirkt wie das weiche auf iOS.
 */
@Composable
private fun Ebenengrund() {
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.8f)).pointerInput(Unit) { detectTapGestures { } })
}

/** Kopfzeile einer Ebene: links, was die Ebene dort zeigt, rechts das X — genau auf dem X des Players. */
@Composable
private fun Ebenenkopf(schliessen: () -> Unit, links: @Composable () -> Unit = {}) {
    Row(Modifier.fillMaxWidth().padding(horizontal = Playermass.seite).padding(top = Playermass.oben), verticalAlignment = Alignment.Top) {
        Box(Modifier.weight(1f)) { links() }
        Spacer(Modifier.width(12.dp))
        Symbolknopf(Zeichen.Kreuz, uebersetzt("Schließen"), tun = schliessen)
    }
}

/**
 * Spalten nebeneinander, **mittig**, unter der Zeile des X (`oben + knopf + 6`). Je Spalte hoechstens 210,
 * Abstand 40 (hochkant 16) — reicht die Breite nicht, werden alle gleich schmaler.
 */
@Composable
private fun Spaltenreihe(rand: Rand, hochkant: Boolean, anzahl: Int, inhalt: @Composable (Dp) -> Unit) {
    BoxWithConstraints(Modifier.fillMaxSize().padding(start = rand.seite, end = rand.seite, top = rand.oben, bottom = rand.unten)
            .padding(horizontal = Playermass.seite).padding(top = Playermass.oben + Playermass.knopf + 6.dp)) {
        val abstand = if (hochkant) 16.dp else 40.dp
        val breite = minOf(210.dp, (maxWidth - abstand * (anzahl - 1)) / anzahl)
        Row(Modifier.fillMaxSize(), horizontalArrangement = Arrangement.spacedBy(abstand, Alignment.CenterHorizontally)) { inhalt(breite) }
    }
}

/** Eine Spalte mit fester Ueberschrift; nur die Zeilen darunter scrollen, jede Spalte fuer sich. */
@Composable
private fun Wahlspalte(titel: String, breite: Dp, inhalt: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.width(breite).fillMaxHeight()) {
        Text(titel, style = titelStil, color = Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis,
             modifier = Modifier.padding(horizontal = 10.dp).padding(bottom = 8.dp).semantics { heading() })
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(bottom = 12.dp),
               verticalArrangement = Arrangement.spacedBy(2.dp), content = inhalt)
    }
}

/** Haken und Name — gewaehlt weiss und halbfett, sonst 62 % Weiss (Vorlage `Ebenenzeile`). */
@Composable
private fun Ebenenzeile(text: String, gewaehlt: Boolean, tun: () -> Unit) {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(Stil.eckeFeld)).druckzeile(tun)
            .semantics { selected = gewaehlt }.padding(horizontal = 10.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(Modifier.width(18.dp), contentAlignment = Alignment.CenterStart) {
            Symbol(Zeichen.Haken, 14.dp, Modifier.alpha(if (gewaehlt) 1f else 0f), farbe = Stil.schrift, staerke = Staerke.Halbfett)
        }
        // **Gewaehlt heisst Weiss, kein Gewichtswechsel** (BRAND 5) — der Haken links sagt
        // es schon, und in einer Spalte mit `maxLines(1)` kuerzte Semibold sogar mehr als Regular.
        Text(text, style = Stil.koerper,
             color = if (gewaehlt) Stil.schrift else Stil.schriftLeise, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** Audio & Untertitel — zwei Spalten, jede scrollt fuer sich. */
@Composable
private fun SpurenEbene(werk: Spielwerk, rand: Rand, hochkant: Boolean, schliessen: () -> Unit) {
    var tonWahl by remember { mutableIntStateOf(werk.spieler.audioTrack) }
    var utWahl by remember { mutableIntStateOf(werk.spieler.spuTrack) }
    val ton = remember { werk.spurliste(ton = true) }
    val ut = remember { werk.spurliste(ton = false) }
    Box(Modifier.fillMaxSize()) {
        Ebenengrund()
        Spaltenreihe(rand, hochkant, 2) { breite ->
            Wahlspalte(uebersetzt("Audio"), breite) {
                ton.forEach { (id, name) -> Ebenenzeile(name, id == tonWahl) { tonWahl = id; werk.tonVonHand(id) } }
            }
            Wahlspalte(uebersetzt("Untertitel"), breite) {
                Ebenenzeile(uebersetzt("Aus"), utWahl == -1) { utWahl = -1; werk.untertitelVonHand(-1) }
                ut.forEach { (id, name) -> Ebenenzeile(name, id == utWahl) { utWahl = id; werk.untertitelVonHand(id) } }
            }
        }
        Box(Modifier.padding(start = rand.seite, end = rand.seite, top = rand.oben)) { Ebenenkopf(schliessen) }
    }
}

/** Bild / Schlafzeit / Technikschild / Qualität — wie auf iOS, ohne Tempo. */
@Composable
private fun EinstellungenEbene(app: SwiftlyAnwendung, werk: Spielwerk, rand: Rand, hochkant: Boolean, schliessen: () -> Unit) {
    val e = app.einstellungen
    // Nur bei Wiedergabe vom Server, und nur, wenn das Konto umwandeln darf.
    val qualitaetZeigen = e.umwandelnErlaubt && werk.plan?.url?.startsWith("file") != true
    val lauf = rememberCoroutineScope()
    Box(Modifier.fillMaxSize()) {
        Ebenengrund()
        Spaltenreihe(rand, hochkant, if (qualitaetZeigen) 4 else 3) { breite ->
            Wahlspalte(uebersetzt("Bild"), breite) {
                Ebenenzeile(uebersetzt("Original"), !werk.bildfuellend) { werk.bildfuellendSetzen(false) }
                Ebenenzeile(uebersetzt("Füllen"), werk.bildfuellend) { werk.bildfuellendSetzen(true) }
            }
            Wahlspalte(uebersetzt("Schlafzeit"), breite) {
                Ebenenzeile(uebersetzt("Aus"), werk.schlafzeit == 0) { werk.schlafzeitSetzen(0) }
                listOf(15, 30, 45, 60, 90).forEach { m ->
                    Ebenenzeile(uebersetzt("%lld Min.", m), werk.schlafzeit == m) { werk.schlafzeitSetzen(m) }
                }
            }
            Wahlspalte(uebersetzt("Technikschild"), breite) {
                Ebenenzeile(uebersetzt("Aus"), !app.einstellungen.technikschild) { app.einstellungen.technikschild = false }
                Ebenenzeile(uebersetzt("An"), app.einstellungen.technikschild) { app.einstellungen.technikschild = true }
            }
            // **Qualität: Direct Play oder eine Obergrenze.** Eine Obergrenze heißt,
            // der Server darf umwandeln — Direct Play ist dann aus. Gilt wie die
            // Einstellung in der App und lädt den Film an derselben Stelle neu.
            if (qualitaetZeigen) {
                val bitraten = remember { wahlenLesen(Kern.bitratenstufen()) }
                // `-1`: Direct Play. Sonst eine Bitratengrenze, `0` heißt unbegrenzt.
                fun waehlen(megabit: Int) {
                    val vorher = e.immerDirectPlay to e.bitratenGrenze
                    if (megabit < 0) e.immerDirectPlay = true
                    else { e.immerDirectPlay = false; e.bitratenGrenze = megabit }
                    if (vorher == (e.immerDirectPlay to e.bitratenGrenze)) return
                    app.qualitaetMelden()
                    schliessen()
                    lauf.launch { werk.qualitaetWechseln() }
                }
                Wahlspalte(uebersetzt("Qualität"), breite) {
                    Ebenenzeile(uebersetzt("Direct Play"), e.immerDirectPlay) { waehlen(-1) }
                    bitraten.forEach { b ->
                        val wert = b.wert.toIntOrNull() ?: 0
                        Ebenenzeile(b.text, !e.immerDirectPlay && e.bitratenGrenze == wert) { waehlen(wert) }
                    }
                }
            }
        }
        Box(Modifier.padding(start = rand.seite, end = rand.seite, top = rand.oben)) { Ebenenkopf(schliessen) }
    }
}

/**
 * Die Folgen der Serie — dieselben Zeilen wie auf der Serienseite (`Folgenzeile`, `Staffelkopf`).
 * Der Titel steht genau dort, wo er im Player stand (`stehenderTitel`, blendet nicht mit); an Stelle der
 * Metazeile sitzt die Staffelwahl. Liste vorgeladen (`folgenVorladen`) — beim Oeffnen steht sie schon da,
 * mit der laufenden Folge in der Mitte; nur beim Staffelwechsel blendet sie neu ein.
 */
@Composable
private fun FolgenEbene(app: SwiftlyAnwendung, serieId: String, laufendeId: String, staffelId: String?, titel: String, rand: Rand,
                        schliessen: () -> Unit, starten: (String) -> Unit) {
    // Vorlage `passendeStaffel(zu:)`: die Staffel der laufenden Folge, nicht die zuletzt auf der Serienseite gewaehlte.
    fun passend(liste: List<Staffel>, gemerkt: String?) =
        liste.firstOrNull { it.id == staffelId }?.id ?: liste.firstOrNull { it.id == gemerkt }?.id ?: liste.firstOrNull()?.id
    val vorgeladen = remember(serieId) { app.serienSpeicher[serieId] }
    var staffeln by remember(serieId) { mutableStateOf(vorgeladen?.staffeln.orEmpty()) }
    var gewaehlt by remember(serieId) { mutableStateOf(vorgeladen?.let { passend(it.staffeln, it.gewaehlt) }) }
    var folgen by remember(serieId) { mutableStateOf(gewaehlt?.let { app.folgenSpeicher[it] }.orEmpty()) }
    var staffellisteOffen by remember { mutableStateOf(false) }
    var staffelGewechselt by remember { mutableStateOf(false) }
    val einblenden = remember { Animatable(1f) }
    val lauf = rememberCoroutineScope()
    // Schon im ersten Bild ungefaehr dort, wo die laufende Folge steht — danach genau mittig.
    val listState = rememberLazyListState(initialFirstVisibleItemIndex = (folgen.indexOfFirst { it.id == laufendeId } - 1).coerceAtLeast(0))

    LaunchedEffect(serieId) {
        try {
            val s = serieLesen(withContext(Dispatchers.IO) { app.kern.serie(serieId).await() })
            app.serienSpeicher[serieId] = s
            staffeln = s.staffeln
            if (gewaehlt == null || staffeln.none { it.id == gewaehlt }) gewaehlt = passend(staffeln, s.gewaehlt)
            val g = gewaehlt ?: return@LaunchedEffect
            if (folgen.isEmpty()) app.folgenSpeicher[g]?.let { folgen = it }
            val f = folgenLesen(withContext(Dispatchers.IO) { app.kern.folgen(serieId, g).await() })
            if (gewaehlt == g) { folgen = f; app.folgenSpeicher[g] = f }
        } catch (e: CancellationException) { throw e } catch (_: Exception) {}
    }

    // **Die laufende Folge in Sicht, mittig** (Vorlage `scrollTo(item.id, anchor: .center)`).
    LaunchedEffect(folgen) {
        if (staffelGewechselt) {
            // Die neue Staffel blendet ein, statt hart dazustehen (`easeOut(duration: 0.25)`).
            staffelGewechselt = false
            einblenden.snapTo(0f)
            launch { einblenden.animateTo(1f, tween(250, easing = EaseOut)) }
        }
        val index = folgen.indexOfFirst { it.id == laufendeId }
        if (index < 0) return@LaunchedEffect
        listState.scrollToItem(index)
        val eintrag = snapshotFlow { listState.layoutInfo.visibleItemsInfo.firstOrNull { it.index == index } }.first { it != null }
            ?: return@LaunchedEffect
        val info = listState.layoutInfo
        listState.scrollBy(-((info.viewportEndOffset - info.viewportStartOffset) / 2f - eintrag.size / 2f))
    }

    Box(Modifier.fillMaxSize()) {
        Ebenengrund()
        Column(Modifier.fillMaxSize().padding(start = rand.seite, end = rand.seite, top = rand.oben)) {
            // Die aufgeklappte Staffelliste liegt ueber den Folgen.
            Box(Modifier.zIndex(1f)) {
                Ebenenkopf(schliessen) {
                    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        // Platzhalter: der Titel selbst steht im Player (`stehenderTitel`) und blendet nicht mit.
                        Text(titel, style = titelStil, maxLines = 1, modifier = Modifier.alpha(0f).clearAndSetSemantics {})
                        if (staffeln.isNotEmpty()) Staffelkopf(staffeln, gewaehlt, staffellisteOffen, { staffellisteOffen = it }, kompakt = true) { neu ->
                            if (neu != gewaehlt) {
                                gewaehlt = neu
                                staffelGewechselt = true
                                app.folgenSpeicher[neu]?.let { folgen = it }
                                lauf.launch {
                                    try {
                                        val f = folgenLesen(withContext(Dispatchers.IO) { app.kern.folgen(serieId, neu).await() })
                                        if (gewaehlt == neu) { folgen = f; app.folgenSpeicher[neu] = f }
                                    } catch (e: CancellationException) { throw e } catch (_: Exception) {}
                                }
                            }
                        }
                    }
                }
            }
            LazyColumn(state = listState, contentPadding = PaddingValues(bottom = 12.dp + rand.unten),
                       modifier = Modifier.weight(1f).padding(top = 10.dp).graphicsLayer { alpha = einblenden.value }) {
                itemsIndexed(folgen, key = { _, f -> f.id }) { i, f ->
                    if (i > 0) Box(Modifier.padding(start = Stil.randAbstand).fillMaxWidth().height(1.dp).background(Stil.linie))
                    Box(Modifier.background(if (f.id == laufendeId) Color.White.copy(alpha = 0.08f) else Color.Transparent)
                            .semantics { selected = f.id == laufendeId }) {
                        Folgenzeile(f) { starten(f.id) }
                    }
                }
            }
        }
    }
}

/**
 * **Der Angebotsknopf** — in der Steuerung und in der Einblendung derselbe (`Angebotsknopf` auf iOS):
 * weisse Pille, Ecke 12, 40 hoch, Ueberspringen-Zeichen und fette 15. `anteil` (0…1): der Countdown zur
 * naechsten Folge als Fuellung von links — **dunkel auf Weiss**, nicht in Akzentfarbe: die gehoert im Player
 * allein dem Griff der Leiste beim Spulen. TalkBack liest Beschriftung und, waehrend des Countdowns, die
 * Sekunden bis zum Start.
 */
@Composable
fun Angebotspille(art: String, text: String, anteil: Double?, sekunden: Int?, werk: Spielwerk, aktion: () -> Unit) {
    val fuellung = durchgehendeFuellung(anteil, werk.laeuft, werk.countdownLaenge)
    Row(Modifier.height(40.dp).clip(RoundedCornerShape(Stil.eckeFeld))
            .background(Color.White)
            .drawBehind { if (anteil != null) drawRect(Stil.grund.copy(alpha = 0.16f), size = size.copy(width = size.width * fuellung)) }
            .symboldruck(true, text, aktion)
            .semantics(mergeDescendants = true) {
                if (sekunden != null) stateDescription = uebersetzt("Startet in %lld Sekunden", sekunden)
            }
            .padding(horizontal = 18.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        Symbol(Zeichen.Ueberspringen, 15.dp, farbe = Stil.grund, staerke = Staerke.Halbfett)
        // Halbfett, nicht fett: drei Schnitte, und Bold steht nur am Seitentitel (BRAND 2).
        Text(text, style = Stil.listentitel, color = Stil.grund, maxLines = 1)
    }
}

/**
 * **Die Fuellung der Karte als eine durchgehende Bewegung** (17.09.2026: im Takt nachgezogen ruckelte sie) —
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

/** Eine feste Zeile des Technikschilds aus `Kern.technikFest` — Name leise, Wert hell; `kopf` ist die Auslieferung. */
data class Technikzeile(val name: String?, val text: String, val art: String, val kopf: Boolean)

/**
 * **Das Technikschild** — Vorlage `Technikschild` in Sources/Shared. Oben links, nimmt nichts an.
 *
 * **Nur, was ein Zuschauer wissen will** (22.09.2026, „viel zu riesig"): Auslieferung, Grund, Bild, Ton,
 * Untertitel, Datei und Puffer sind Kernzeilen und stehen immer; die Verlustzeile nur, wenn etwas verloren
 * ging. Stelle, Demuxer, Zeige-, Lauf-, Dekoder- und Stromzaehler stehen nur im Messmodus
 * (`technikschildMessen`, per Startextra). Ueber die Kernzeilen hinaus nimmt [Kappliste] Zeilen nur,
 * solange 55 % der angebotenen Hoehe reichen — weglassen statt scrollen, das Schild nimmt keine Eingaben.
 *
 * Schrift der Leiter (`klein`, gleich breite Ziffern) statt Monospace; Grund `grund` zu 0,78, kein Rand.
 * `fern`: der Fernseher — 420 breit, 7 Abstand, Innenabstand 20/16, Ecke `eckeKlein`.
 * „zu spät" fehlt — libVLC fuer Android zaehlt verspaetete Bilder nicht; eine Null waere gelogen.
 *
 * Nicht `private`: `tv/TvPlayer.kt` zeigt dasselbe Schild an derselben Stelle.
 */
@Composable
fun Technikschild(fest: List<Technikzeile>, live: JSONObject?, position: Double, dauer: Double, messen: Boolean, fern: Boolean,
                  modifier: Modifier = Modifier) {
    val ziffern = "tnum"
    val schrift = Stil.klein.copy(fontFeatureSettings = ziffern)
    val kopfschrift = Stil.kachel.copy(fontWeight = FontWeight.SemiBold, fontFeatureSettings = ziffern)
    val abstand = if (fern) 7.dp else 4.dp
    fun komma(x: Double, stellen: Int = 1) = String.format(Locale.getDefault(), "%.${stellen}f", x)
    val zeilen = mutableListOf<Pair<Boolean, @Composable () -> Unit>>()
    fun kern(z: @Composable () -> Unit) { zeilen += true to z }
    fun rest(z: @Composable () -> Unit) { zeilen += false to z }
    @Composable fun messzeile(text: String, auffaellig: Boolean) {
        if (auffaellig) Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
            Symbol(Zeichen.Warnung, 10.dp, farbe = Stil.warnung)
            Text(text, style = schrift, color = Stil.warnung)
        } else Text(text, style = schrift, color = Stil.schriftLeise)
    }
    @Composable fun angabe(name: String, wert: String, auffaellig: Boolean = false) {
        if (auffaellig) messzeile("$name $wert", true)
        else Text(buildAnnotatedString {
            withStyle(SpanStyle(color = Stil.schriftLeise)) { append(name) }
            withStyle(SpanStyle(color = Stil.schrift)) { append(" $wert") }
        }, style = schrift)
    }
    fest.forEach { z ->
        when {
            z.kopf -> kern { Text(z.text, style = kopfschrift, color = if (z.art == "gut") Stil.akzent else Stil.warnung) }
            z.name == null -> kern { Text(z.text, style = schrift, color = Stil.warnung, maxLines = if (messen) Int.MAX_VALUE else 2,
                                          overflow = TextOverflow.Ellipsis) }
            else -> kern { angabe(z.name, z.text) }
        }
    }
    live?.let { w ->
        // **Puffer: Sekunden Vorrat und was ankommt**, eine Zeile. KiB nur beim Messen.
        val sekunden = w.feldZahl("vorratSekunden")
        val teile = buildList {
            sekunden?.let { add("${komma(it)} s") }
            if (messen) add("${w.optLong("vorratKiB")} KiB")
            w.feldText("eingang")?.let { add("${uebersetzt("Eingang")} $it") }
        }
        if (teile.isNotEmpty()) kern { angabe(uebersetzt("Puffer"), teile.joinToString(" · "), (sekunden ?: Double.MAX_VALUE) < 2) }
        val verworfen = w.optLong("verworfen"); val tonWeg = w.optLong("tonVerloren")
        val verlust = verworfen > 0 || tonWeg > 0
        if (messen || verlust) rest { messzeile("${uebersetzt("Verworfen")} $verworfen · ${uebersetzt("Ton weg")} $tonWeg", verlust) }
    }
    if (messen) {
        if (dauer > 1) rest { messzeile("${uebersetzt("Stelle")} ${zeitText(position)} / ${zeitText(dauer)}", false) }
        live?.let { w ->
            // Eine Haarlinie: darueber die Datei, darunter, was beim Laufen hochzaehlt.
            rest { Box(Modifier.padding(vertical = abstand / 2).width(if (fern) 260.dp else 150.dp).height(1.dp).background(Stil.rand)) }
            val soll = w.feldZahl("soll")
            w.feldText("demuxer")?.let { rest { messzeile("${uebersetzt("Demuxer")} $it", false) } }
            val zeigt = w.feldZahl("zeigt")
            rest { messzeile("${uebersetzt("Zeigt Ø")} ${zeigt?.let { komma(it) } ?: "—"} fps · ${uebersetzt("Gezeigt")} ${w.optLong("gezeigt")}",
                             zeigt != null && soll != null && zeigt < soll - 2) }
            val lauf = w.feldZahl("lauf")
            rest { messzeile("${uebersetzt("Lauf")} ${lauf?.let { "${(it * 100).roundToInt()} %" } ?: "—"}", (lauf ?: 1.0) < 0.97) }
            val dekodiert = w.feldZahl("dekodiert")
            rest { messzeile("${uebersetzt("Dekodiert Ø")} ${dekodiert?.let { komma(it) } ?: "—"} fps",
                             dekodiert != null && soll != null && dekodiert < soll - 2) }
            val kaputt = w.optLong("beschaedigt"); val spruenge = w.optLong("spruenge")
            rest { messzeile("${uebersetzt("Beschädigt")} $kaputt · ${uebersetzt("Sprünge")} $spruenge", kaputt > 0 || spruenge > 0) }
        }
    }
    val form = RoundedCornerShape(if (fern) Stil.eckeKlein else Stil.ecke)
    Box(modifier.clip(form).background(Stil.grund.copy(alpha = 0.78f))
            .padding(horizontal = if (fern) 20.dp else 12.dp, vertical = if (fern) 16.dp else 10.dp)
            .width(if (fern) 420.dp else 260.dp)
            .clearAndSetSemantics { contentDescription = fest.joinToString(", ") { listOfNotNull(it.name, it.text).joinToString(" ") } }) {
        Kappliste(abstand, if (messen) null else 0.55f, zeilen.map { it.first }) { zeilen.forEach { it.second() } }
    }
}

/**
 * **Eine Spalte mit Hoechsthoehe, die weglaesst statt zu scrollen** — Vorlage `Kappliste`. Kernzeilen stehen
 * immer; die uebrigen nimmt sie von oben, solange sie in `anteil` der angebotenen Hoehe passen, und hoert bei
 * der ersten auf, die nicht mehr passt. Die Reihenfolge ist die Rangfolge.
 */
@Composable
private fun Kappliste(abstand: Dp, anteil: Float?, kern: List<Boolean>, inhalt: @Composable () -> Unit) {
    Layout(inhalt) { teile, schranken ->
        val grenze = if (anteil != null && schranken.hasBoundedHeight) schranken.maxHeight * anteil else Float.POSITIVE_INFINITY
        val luft = abstand.roundToPx()
        val frei = schranken.copy(minWidth = 0, minHeight = 0, maxHeight = Constraints.Infinity)
        var summe = 0; var voll = false
        val stehen = teile.mapIndexed { i, t ->
            val g = t.measure(frei)
            val neu = summe + (if (summe == 0) 0 else luft) + g.height
            if (!kern.getOrElse(i) { false } && (voll || neu > grenze)) { voll = true; null } else { summe = neu; g }
        }
        val breite = if (schranken.hasBoundedWidth) schranken.maxWidth else stehen.maxOfOrNull { it?.width ?: 0 } ?: 0
        layout(breite, summe) {
            var y = 0
            stehen.forEach { g -> if (g != null) { g.place(0, y); y += g.height + luft } }
        }
    }
}

