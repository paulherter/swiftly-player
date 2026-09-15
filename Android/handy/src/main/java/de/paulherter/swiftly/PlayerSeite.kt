package de.paulherter.swiftly

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.ActivityInfo
import android.net.Uri
import android.os.SystemClock
import android.view.WindowManager
import androidx.activity.compose.BackHandler
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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import de.paulherter.swiftly.kern.Kern
import org.videolan.libvlc.LibVLC
import org.videolan.libvlc.Media
import org.videolan.libvlc.MediaPlayer
import org.videolan.libvlc.util.VLCVideoLayout
import java.text.NumberFormat

/** Was abgespielt werden soll und ab wo — `Abspielwunsch` auf iOS. `ab == null` heisst: von vorn. */
data class Abspielwunsch(val id: String, val ab: Double?)

/** Antwort von `Kern.wiedergabeOeffnen` — Adresse und die Zeilen fuer den Fuss. */
data class Spielplan(val url: String, val lossless: Boolean, val methode: String, val titel: String,
                     val untertitel: String, val naechste: Boolean)

private fun spielplanLesen(json: String) = JSONObject(json).let { o ->
    Spielplan(o.getString("url"), o.optBoolean("lossless"), o.optString("methode"), o.optString("titel"),
              o.optString("untertitel"), o.optBoolean("naechste"))
}

/** 1:23:45 oder 23:45 — Ziffern gleich breit, damit die Zeile beim Laufen nicht zittert. */
private fun zeitText(sekunden: Double): String {
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

private fun tempoText(wert: Float) = NumberFormat.getInstance().format(wert) + "×"

private tailrec fun Context.aktivitaet(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.aktivitaet()
    else -> null
}

/**
 * Vorlage: `PlayerScreen` in `Sources/iOS/PlayerScreen.swift`.
 *
 * **Die Entscheidungen stehen im Paket, hier nur Bild und Finger.** Alle 500 ms meldet der Takt,
 * was VLC sieht, an `Kern.wiedergabeTakt` — dort rechnet `Wiedergabetakt` wie auf iOS, meldet
 * Start und Fortschritt an den Server, und `Abschnittslogik`/`Folgenende` sagen, ob ein Knopf zum
 * Ueberspringen dasteht und ob weitergeschaltet wird.
 *
 * - Die Steuerung kommt schnell (180 ms) und geht langsam (340 ms), nach 4 s Ruhe — nicht, wenn
 *   angehalten ist, geschoben wird oder ein Blatt offen ist.
 * - **Ein Tipp schaltet sofort**, ein zweiter binnen 300 ms nimmt das zurueck und springt. So
 *   wartet der einfache Tipp nicht darauf, ob noch einer kommt.
 * - Die Mitte haelt an, auch bei ausgeblendeter Steuerung — wer dorthin tippt, meint den Knopf.
 * - Zwei Finger schalten hart zwischen ganzem und formatfuellendem Bild; ein weiches Zoomen, das
 *   falsch landet, wirkte auf iOS kaputter als ein Schalter.
 * - Die Stelle wird **vor** dem Anhalten gelesen: VLC setzt seine Uhr beim Anhalten zurueck.
 */
@Composable
fun PlayerSeite(app: SwiftlyAnwendung, wunsch: Abspielwunsch, schliessen: () -> Unit) {
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

    val vlc = remember { LibVLC(kontext, arrayListOf("--no-drop-late-frames", "--no-skip-frames")) }
    val spieler = remember { MediaPlayer(vlc) }
    var plan by remember { mutableStateOf<Spielplan?>(null) }
    var bildFrei by remember { mutableStateOf(false) }
    var laeuft by remember { mutableStateOf(false) }
    var position by remember { mutableDoubleStateOf(0.0) }
    var dauer by remember { mutableDoubleStateOf(0.0) }
    var sichtbar by remember { mutableStateOf(true) }
    var beruehrt by remember { mutableIntStateOf(0) }
    var amSchieben by remember { mutableStateOf(false) }
    var angebotArt by remember { mutableStateOf("keiner") }
    var angebotNach by remember { mutableStateOf<Double?>(null) }
    var angebotText by remember { mutableStateOf("") }
    var hinweis by remember { mutableStateOf<String?>(null) }
    var sprungblase by remember { mutableStateOf<String?>(null) }
    var bildfuellend by remember { mutableStateOf(app.ablage.merkwert("bildfuellend") == "1") }
    var tempo by remember { mutableFloatStateOf(1f) }
    var schlafzeit by remember { mutableIntStateOf(0) }
    val zeigtBild = remember { booleanArrayOf(false) }
    val ende = remember { booleanArrayOf(false) }
    val sprungBis = remember { longArrayOf(0L) }

    DisposableEffect(spieler) {
        spieler.setEventListener { e ->
            when (e.type) {
                MediaPlayer.Event.Playing -> laeuft = true
                MediaPlayer.Event.Paused, MediaPlayer.Event.Stopped -> laeuft = false
                MediaPlayer.Event.Vout -> if (e.voutCount > 0) zeigtBild[0] = true
                MediaPlayer.Event.EndReached -> { laeuft = false; ende[0] = true }
                MediaPlayer.Event.EncounteredError -> hinweis = uebersetzt("Die Folge konnte nicht geladen werden.")
            }
        }
        onDispose {
            spieler.stop()
            spieler.detachViews()
            spieler.release()
            vlc.release()
        }
    }

    fun starte(neu: Spielplan, ab: Double?) {
        plan = neu
        bildFrei = false
        zeigtBild[0] = false
        ende[0] = false
        position = ab ?: 0.0
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
        spieler.play()
    }

    fun beenden() {
        // Die Stelle vor dem Anhalten lesen — VLC setzt seine Uhr beim Anhalten zurueck.
        val stelle = (spieler.time / 1000.0).coerceAtLeast(0.0)
        app.kern.wiedergabeBeenden(stelle)
        spieler.stop()
        schliessen()
    }

    suspend fun naechsteFolge() {
        val stelle = (spieler.time / 1000.0).coerceAtLeast(0.0)
        spieler.stop()
        try {
            starte(spielplanLesen(withContext(Dispatchers.IO) { app.kern.naechsteFolgeOeffnen(stelle).await() }), null)
        } catch (e: CancellationException) { throw e } catch (_: Exception) {
            hinweis = uebersetzt("Nächste Folge konnte nicht geladen werden.")
        }
    }

    fun springe(ziel: Double) {
        val z = if (dauer > 0) ziel.coerceIn(0.0, dauer) else ziel.coerceAtLeast(0.0)
        spieler.time = (z * 1000).toLong()
        position = z
        // Zwei Sekunden lang zaehlt die Stelle, nicht VLCs alte Uhr — `Zeitannahme.sprungriegel`.
        sprungBis[0] = SystemClock.elapsedRealtime() + 2000
        app.kern.wiedergabeMelden(z, !laeuft)
        beruehrt++
    }

    fun umschalten() {
        ruck(Ruck.Mittel)
        val spielteGerade = spieler.isPlaying
        if (spielteGerade) spieler.pause() else spieler.play()
        app.kern.wiedergabeMelden(position, spielteGerade)
        beruehrt++
    }

    val zurueckS = app.einstellungen.zurueckSekunden
    val vorS = app.einstellungen.vorSekunden

    /**
     * Ton und Untertitel nach den Einstellungen, einmal je Titel, sobald die Spuren bekannt sind.
     * **Ueber den Namen, den VLC nennt** (`Sprache.passt`) — Sprachkuerzel liefert VLC nicht. Passt
     * keine Tonspur, bleibt die der Datei: eine falsche ist schlimmer als ihre eigene Wahl.
     */
    fun sprachenAnwenden() {
        val e = app.einstellungen
        val ton = spieler.audioTracks?.filter { it.id >= 0 }.orEmpty()
        var tonPasst = false
        if (e.tonSprache.isNotEmpty()) {
            val i = Kern.spurWaehlen(ton.map { it.name }.toTypedArray(), e.tonSprache).toInt()
            if (i >= 0) { spieler.audioTrack = ton[i].id; tonPasst = true }
        }
        val spuren = spieler.spuTracks?.filter { it.id >= 0 }.orEmpty()
        // „Untertitel automatisch": nur, wenn der Ton nicht in der gewaehlten Sprache laeuft.
        val wollen = e.untertitelSprache.isNotEmpty() && !(e.untertitelAutomatisch && tonPasst)
        val i = if (wollen) Kern.spurWaehlen(spuren.map { it.name }.toTypedArray(), e.untertitelSprache).toInt() else -1
        spieler.spuTrack = if (i >= 0) spuren[i].id else -1
    }

    BackHandler { beenden() }

    // Oeffnen, dann der Takt.
    LaunchedEffect(wunsch) {
        try {
            starte(spielplanLesen(withContext(Dispatchers.IO) { app.kern.wiedergabeOeffnen(wunsch.id).await() }), wunsch.ab)
        } catch (e: CancellationException) { throw e } catch (_: Exception) {
            hinweis = uebersetzt("Die Folge konnte nicht geladen werden.")
            return@LaunchedEffect
        }
        while (true) {
            delay(500)
            val laenge = (spieler.length / 1000.0).coerceAtLeast(0.0)
            val antwort = JSONObject(app.kern.wiedergabeTakt(
                laenge, (spieler.time / 1000.0).coerceAtLeast(0.0), zeigtBild[0], spieler.isPlaying,
                spieler.audioTracksCount > 0, amSchieben, SystemClock.elapsedRealtime() < sprungBis[0]))
            if (antwort.optBoolean("ladeschirmWeg")) bildFrei = true
            if (antwort.optBoolean("spurenAnwenden")) sprachenAnwenden()
            if (!amSchieben && SystemClock.elapsedRealtime() >= sprungBis[0] && antwort.has("position")) {
                position = antwort.getDouble("position")
            }
            dauer = laenge
            angebotArt = antwort.optString("angebot", "keiner")
            angebotNach = if (antwort.isNull("nach")) null else antwort.getDouble("nach")
            angebotText = antwort.optString("angebotstext")
            if (antwort.optBoolean("weiterschalten") && app.einstellungen.naechsteAutomatisch) naechsteFolge()
            else if (ende[0] && plan?.naechste != true) { beenden(); break }
        }
    }

    val blattOffen = app.blatt.value != null
    LaunchedEffect(sichtbar, laeuft, amSchieben, blattOffen, beruehrt) {
        if (sichtbar && laeuft && !amSchieben && !blattOffen) { delay(4000); sichtbar = false }
    }
    LaunchedEffect(tempo) { spieler.rate = tempo }
    LaunchedEffect(bildfuellend) {
        spieler.videoScale = if (bildfuellend) MediaPlayer.ScaleType.SURFACE_FIT_SCREEN else MediaPlayer.ScaleType.SURFACE_BEST_FIT
        app.ablage.merken("bildfuellend", if (bildfuellend) "1" else "0")
    }
    LaunchedEffect(schlafzeit) {
        if (schlafzeit > 0) { delay(schlafzeit * 60_000L); spieler.pause(); schlafzeit = 0; hinweis = uebersetzt("Schlafzeit abgelaufen.") }
    }
    LaunchedEffect(hinweis) { if (hinweis != null) { delay(5000); hinweis = null } }
    LaunchedEffect(sprungblase) { if (sprungblase != null) { delay(700); sprungblase = null } }

    fun einstellungen() {
        beruehrt++
        val ton = spieler.audioTracks?.filter { it.id >= 0 }.orEmpty()
        val spuren = spieler.spuTracks?.filter { it.id >= 0 }.orEmpty()
        val tonName = ton.firstOrNull { it.id == spieler.audioTrack }?.name ?: uebersetzt("Keine")
        val spurName = spuren.firstOrNull { it.id == spieler.spuTrack }?.name ?: uebersetzt("Aus")
        val minuten: (Int) -> String = { if (it == 0) uebersetzt("Aus") else "$it min" }
        app.blatt.value = Blattwunsch(uebersetzt("Wiedergabe"), listOf(
            Wahl("ton", "${uebersetzt("Ton")} · $tonName"),
            Wahl("untertitel", "${uebersetzt("Untertitel")} · $spurName"),
            Wahl("bild", "${uebersetzt("Bildformat")} · ${uebersetzt(if (bildfuellend) "Formatfüllend" else "Ganzes Bild")}"),
            Wahl("tempo", "${uebersetzt("Tempo")} · ${tempoText(tempo)}"),
            Wahl("schlaf", "${uebersetzt("Schlafzeit")} · ${minuten(schlafzeit)}"),
        ), null) { wahl ->
            app.blatt.value = when (wahl) {
                "ton" -> Blattwunsch(uebersetzt("Ton"), ton.map { Wahl(it.id.toString(), it.name) }, spieler.audioTrack.toString()) {
                    spieler.audioTrack = it.toInt()
                }
                "untertitel" -> Blattwunsch(uebersetzt("Untertitel"),
                    listOf(Wahl("-1", uebersetzt("Aus"))) + spuren.map { Wahl(it.id.toString(), it.name) },
                    spieler.spuTrack.toString()) { spieler.spuTrack = it.toInt() }
                "bild" -> Blattwunsch(uebersetzt("Bildformat"),
                    listOf(Wahl("ganz", uebersetzt("Ganzes Bild")), Wahl("fuellend", uebersetzt("Formatfüllend"))),
                    if (bildfuellend) "fuellend" else "ganz") { bildfuellend = it == "fuellend" }
                "tempo" -> Blattwunsch(uebersetzt("Tempo"), listOf(0.75f, 1f, 1.25f, 1.5f, 2f).map { Wahl(it.toString(), tempoText(it)) },
                    tempo.toString()) { tempo = it.toFloat() }
                else -> Blattwunsch(uebersetzt("Schlafzeit"), listOf(0, 15, 30, 45, 60, 90).map { Wahl(it.toString(), minuten(it)) },
                    schlafzeit.toString()) { schlafzeit = it.toInt() }
            }
        }
    }

    val deckung by animateFloatAsState(
        if (sichtbar || !bildFrei) 1f else 0f,
        if (sichtbar || !bildFrei) tween(180, easing = Bewegung.weich) else tween(340, easing = Bewegung.weich),
        label = "steuerung")

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        AndroidView(factory = { ctx -> VLCVideoLayout(ctx).also { spieler.attachViews(it, null, true, false) } },
                    modifier = Modifier.fillMaxSize())

        // Gesten ueber dem Bild, unter der Steuerung.
        Box(Modifier.fillMaxSize()
            .pointerInput(Unit) {
                var letzter = 0L
                detectTapGestures(onTap = { stelle ->
                    val jetzt = SystemClock.elapsedRealtime()
                    if (jetzt - letzter < 300) {
                        sichtbar = !sichtbar
                        val links = stelle.x < size.width / 2
                        springe(position + if (links) -zurueckS.toDouble() else vorS.toDouble())
                        sprungblase = if (links) "−$zurueckS" else "+$vorS"
                        letzter = 0L
                    } else {
                        sichtbar = !sichtbar
                        beruehrt++
                        letzter = jetzt
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
                            if (!geschaltet && mass > 1.15f) { bildfuellend = true; geschaltet = true }
                            if (!geschaltet && mass < 0.85f) { bildfuellend = false; geschaltet = true }
                        }
                    } while (ereignis.changes.any { it.pressed })
                }
            })

        if (!bildFrei) {
            Box(Modifier.fillMaxSize().background(Color.Black), contentAlignment = Alignment.Center) {
                if (hinweis == null) CircularProgressIndicator(color = Stil.schrift, strokeWidth = 2.5.dp, modifier = Modifier.size(30.dp))
            }
        }

        sprungblase?.let { text ->
            Box(Modifier.align(if (text.startsWith("+")) Alignment.CenterEnd else Alignment.CenterStart).padding(horizontal = 96.dp)
                    .size(72.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.45f)),
                contentAlignment = Alignment.Center) {
                Text(text, style = TextStyle(fontSize = 20.sp, fontWeight = FontWeight.SemiBold, fontFeatureSettings = "tnum"), color = Stil.schrift)
            }
        }

        // Ausgeblendet haelt die Mitte trotzdem an.
        if (bildFrei && deckung < 0.01f) Box(Modifier.align(Alignment.Center).size(108.dp, 132.dp).antippen { umschalten() })

        if (deckung > 0.01f) Box(Modifier.fillMaxSize().graphicsLayer { alpha = deckung }) {
            // `Playerschleier` — ohne ihn verschwinden weisse Zeichen ueber hellen Szenen.
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.28f)))
            Box(Modifier.fillMaxWidth().height(140.dp).background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.6f), Color.Transparent))))
            Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(180.dp)
                .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.7f)))))

            Row(Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.displayCutout).padding(horizontal = 16.dp).padding(top = 18.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Rundknopf(Icons.Filled.KeyboardArrowDown, uebersetzt("Player schließen"), 32.dp) { beenden() }
                Spacer(Modifier.weight(1f))
                Rundknopf(Icons.Filled.Tune, uebersetzt("Wiedergabeeinstellungen"), 24.dp) { einstellungen() }
            }

            // Mittig, nicht oben oder unten angeklebt — so bleibt sie in beiden Lagen mit dem Daumen erreichbar.
            if (bildFrei) Row(Modifier.align(Alignment.Center), horizontalArrangement = Arrangement.spacedBy(56.dp),
                              verticalAlignment = Alignment.CenterVertically) {
                Rundknopf(spulzeichen(true, zurueckS), uebersetzt("%lld Sekunden zurück", zurueckS), 46.dp) { springe(position - zurueckS) }
                Rundknopf(if (laeuft) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                          uebersetzt(if (laeuft) "Anhalten" else "Abspielen"), 78.dp) { umschalten() }
                Rundknopf(spulzeichen(false, vorS), uebersetzt("%lld Sekunden vor", vorS), 46.dp) { springe(position + vorS) }
            }

            hinweis?.let {
                Text(it, style = TextStyle(fontSize = 13.sp, textAlign = TextAlign.Center), color = Stil.schrift,
                     modifier = Modifier.align(Alignment.TopCenter).padding(top = 72.dp, start = 48.dp, end = 48.dp))
            }

            Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().windowInsetsPadding(WindowInsets.displayCutout)
                       .padding(horizontal = 24.dp).padding(bottom = 18.dp)) {
                Row(verticalAlignment = Alignment.Bottom) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(plan?.titel.orEmpty(), style = TextStyle(fontSize = 19.sp, fontWeight = FontWeight.SemiBold),
                             color = Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                            plan?.untertitel?.takeIf { it.isNotEmpty() }?.let {
                                Text(it, style = TextStyle(fontSize = 14.sp), color = Stil.schriftLeise, maxLines = 1)
                            }
                            val p = plan
                            if (p != null && !p.lossless) Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Filled.Warning, contentDescription = null, tint = Stil.warnung, modifier = Modifier.size(13.dp))
                                Text(p.methode, style = TextStyle(fontSize = 14.sp), color = Stil.warnung)
                            }
                        }
                    }
                    if (angebotArt != "keiner" && angebotText.isNotEmpty()) {
                        Row(Modifier.clip(CircleShape).background(Color.White)
                                .antippen {
                                    val nach = angebotNach
                                    if (angebotArt == "ueberspringen" && nach != null) springe(nach) else lauf.launch { naechsteFolge() }
                                }
                                .padding(horizontal = 16.dp, vertical = 10.dp),
                            horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(if (angebotArt == "naechste") Icons.Filled.SkipNext else Icons.Filled.FastForward,
                                 contentDescription = null, tint = Stil.grund, modifier = Modifier.size(18.dp))
                            Text(angebotText, style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold), color = Stil.grund)
                        }
                    }
                }
                Spacer(Modifier.height(10.dp))
                Zeitzeile(position, dauer, { amSchieben = it; beruehrt++ }) { springe(it) }
            }
        }
    }
}

@Composable
private fun Rundknopf(symbol: ImageVector, beschreibung: String, groesse: Dp, tun: () -> Unit) {
    Box(Modifier.size(if (groesse < 44.dp) 44.dp else groesse).antippen(tun), contentAlignment = Alignment.Center) {
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
    val dicke by animateDpAsState(if (ziel != null) 6.dp else 3.dp, Bewegung.umschalten(), label = "spur")
    val knauf by animateDpAsState(if (ziel != null) 18.dp else 13.dp, Bewegung.umschalten(), label = "knauf")
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
            .pointerInput(dauer) { detectTapGestures { o -> springen((o.x / size.width).coerceIn(0f, 1f).toDouble() * dauer) } },
            contentAlignment = Alignment.CenterStart) {
            val anteil = if (dauer > 0) (gezeigt / dauer).toFloat().coerceIn(0f, 1f) else 0f
            Box(Modifier.fillMaxWidth().height(dicke).clip(CircleShape).background(Color.White.copy(alpha = 0.25f)))
            Box(Modifier.fillMaxWidth(anteil).height(dicke).clip(CircleShape).background(Color.White))
            Box(Modifier.offset(x = maxWidth * anteil - knauf / 2).size(knauf).clip(CircleShape).background(Color.White))
        }
        Text("−" + zeitText((dauer - gezeigt).coerceAtLeast(0.0)), style = ziffern, color = Stil.schrift)
    }
}
