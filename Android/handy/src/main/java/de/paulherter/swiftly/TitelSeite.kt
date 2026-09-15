package de.paulherter.swiftly

import android.content.Intent
import android.net.Uri
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.Movie
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import coil3.compose.SubcomposeAsyncImage
import de.paulherter.swiftly.gemeinsam.Stil
import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.ui.draw.drawBehind
import de.paulherter.swiftly.gemeinsam.Bewegung
import de.paulherter.swiftly.gemeinsam.uebersetzt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.util.Locale

data class Mitwirkender(val id: String, val name: String, val rolle: String?, val bild: String?)
data class Datei(val container: String?, val video: String?, val ton: List<String>, val untertitel: String, val hatUntertitel: Boolean)
data class Extra(val id: String, val name: String, val bild: String?, val laufzeit: String?)

/** Antwort von `Kern.titel` — die Zeilen stehen dort schon fertig. */
data class Titel(
    val id: String, val name: String, val typ: String, val nebenzeile: String, val kopfbild: String?,
    val bewertung: Double?, val freigabe: String?,
    /** Es gibt einen Abspielplan — ohne ihn bleiben die Knoepfe gesperrt. */
    val planDa: Boolean, val lossless: Boolean, val methode: String?,
    val fortsetzenAb: Double?, val fortsetzenText: String?,
    val beschreibung: String?, val regie: List<String>, val darsteller: List<Mitwirkender>,
    val gemerkt: Boolean, val gesehen: Boolean, val trailer: String?, val datei: Datei?,
)

internal fun JSONObject.feldText(feld: String): String? = if (isNull(feld)) null else getString(feld)
internal fun JSONObject.feldZahl(feld: String): Double? = if (isNull(feld)) null else getDouble(feld)
internal fun JSONObject.feldTexte(feld: String): List<String> =
    optJSONArray(feld)?.let { a -> (0 until a.length()).map { a.getString(it) } } ?: emptyList()
internal fun <T> JSONObject.feldListe(feld: String, lesen: (JSONObject) -> T): List<T> =
    optJSONArray(feld)?.let { a -> (0 until a.length()).map { lesen(a.getJSONObject(it)) } } ?: emptyList()

private fun titelLesen(json: String): Titel = JSONObject(json).let { o ->
    Titel(o.getString("id"), o.getString("name"), o.optString("typ"), o.optString("nebenzeile"), o.feldText("kopfbild"),
          o.feldZahl("bewertung"), o.feldText("freigabe"),
          o.optBoolean("planDa"), o.optBoolean("lossless"), o.feldText("methode"),
          o.feldZahl("fortsetzenAb"), o.feldText("fortsetzenText"),
          o.feldText("beschreibung"), o.feldTexte("regie"),
          o.feldListe("darsteller") { Mitwirkender(it.getString("id"), it.getString("name"), it.feldText("rolle"), it.feldText("bild")) },
          o.optBoolean("gemerkt"), o.optBoolean("gesehen"), o.feldText("trailer"),
          o.optJSONObject("datei")?.let { d ->
              Datei(d.feldText("container"), d.feldText("video"), d.feldTexte("ton"), d.optString("untertitel"), d.optBoolean("hatUntertitel"))
          })
}

/** Die Fassade meldet „nicht angemeldet" als Kennung, weil der Wortlaut im App-Katalog steht. */
internal fun fehlertext(grund: String) = if (grund == "nichtAngemeldet") uebersetzt("Nicht angemeldet.") else grund

/**
 * Vorlage: `ItemDetailView` in `Sources/Shared/BrowseViews.swift`, schmale Fassung.
 *
 * **Kein Ring, keine Fehlerseite** — wie auf iOS: die Seite steht sofort mit dem, was der
 * Tipp mitbrachte, und wird still vervollstaendigt. Gemerkt wird der letzte Stand in der App,
 * damit das Zurueckkehren aus einer tieferen Seite nicht erneut aufbaut.
 */
@Composable
fun TitelSeite(app: SwiftlyAnwendung, ziel: Ziel, oeffnen: (Ziel) -> Unit, zurueck: () -> Unit) {
    var titel by remember(ziel.id) { mutableStateOf(app.titelSpeicher[ziel.id]) }
    var aehnliche by remember(ziel.id) { mutableStateOf<List<Rasterkachel>>(emptyList()) }
    var extras by remember(ziel.id) { mutableStateOf<List<Extra>>(emptyList()) }
    var gemerkt by remember(ziel.id) { mutableStateOf(titel?.gemerkt ?: false) }
    var gesehen by remember(ziel.id) { mutableStateOf(titel?.gesehen ?: false) }
    var meldung by remember { mutableStateOf<String?>(null) }
    val bereich = rememberCoroutineScope()
    val kontext = LocalContext.current
    val ruck = rememberRuck()

    suspend fun auffrischen() {
        try {
            val neu = titelLesen(withContext(Dispatchers.IO) { app.kern.titel(ziel.id).await() })
            titel = neu
            app.titelSpeicher[ziel.id] = neu
            gemerkt = neu.gemerkt
            gesehen = neu.gesehen
        } catch (e: CancellationException) { throw e } catch (_: Exception) {}
    }

    LaunchedEffect(ziel.id) {
        auffrischen()
        try {
            val o = JSONObject(withContext(Dispatchers.IO) { app.kern.titelUmfeld(ziel.id).await() })
            aehnliche = o.feldListe("aehnliche") { rasterkachelLesen(it) }
            extras = o.feldListe("extras") { Extra(it.getString("id"), it.getString("name"), it.feldText("bild"), it.feldText("laufzeit")) }
        } catch (e: CancellationException) { throw e } catch (_: Exception) {}
    }

    // Nach dem Schauen neu laden: Fortschritt, Gesehen und Plan haben sich geaendert.
    val spielt = app.spiel.value != null
    var hatGespielt by remember { mutableStateOf(false) }
    LaunchedEffect(spielt) { if (spielt) hatGespielt = true else if (hatGespielt) { hatGespielt = false; auffrischen() } }

    /** Erst umschalten, dann fragen; sagt der Server nein, zurueck und melden — wie auf iOS. */
    fun umschalten(an: Boolean, setzen: (Boolean) -> Unit, frage: suspend (Boolean) -> String, merken: (Titel, Boolean) -> Titel) {
        ruck(Ruck.Leicht)
        setzen(an)
        bereich.launch {
            val grund = withContext(Dispatchers.IO) { frage(an) }
            if (grund.isNotEmpty()) { setzen(!an); meldung = fehlertext(grund) }
            else app.titelSpeicher[ziel.id]?.let { app.titelSpeicher[ziel.id] = merken(it, an) }
        }
    }

    val scroll = rememberScrollState()
    val dichte = LocalDensity.current.density
    val t = titel
    val name = t?.name ?: ziel.name

    Box(Modifier.fillMaxSize().background(Stil.grund)) {
        Column(Modifier.fillMaxSize().verticalScroll(scroll)) {
            Held(t?.kopfbild, name, t?.nebenzeile.orEmpty())

            Column(Modifier.padding(horizontal = Stil.randAbstand).padding(top = 14.dp),
                   verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Belegzeile(t)
                Spielknoepfe(t) { ab -> ruck(Ruck.Mittel); app.spiel.value = Abspielwunsch(ziel.id, ab) }
                Row(Modifier.padding(bottom = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Aktionsknopf(if (gemerkt) Icons.Filled.Bookmark else Icons.Filled.BookmarkBorder, uebersetzt("Merkliste"), gemerkt) {
                        umschalten(!gemerkt, { gemerkt = it }, { app.kern.merken(ziel.id, it).await() }) { alt, an -> alt.copy(gemerkt = an) }
                    }
                    // Das fuenfte Feld, nur wenn die Funktion an ist — neben der Merkliste: das Paar „fuer spaeter".
                    if (app.einstellungen.downloadsAn && t?.typ != "Series") Downloadfeld(app, ziel.id, name)
                    // Der Trailer vom Server laeuft auf iOS im eigenen Player — der folgt; bis dahin der fremde.
                    Aktionsknopf(Icons.Outlined.Movie, uebersetzt("Trailer"), false) {
                        val adresse = t?.trailer
                        val ging = adresse != null && runCatching {
                            kontext.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(adresse)))
                        }.isSuccess
                        if (!ging) meldung = uebersetzt("Für diesen Titel liegt kein Trailer vor.")
                    }
                    Aktionsknopf(if (gesehen) Icons.Filled.CheckCircle else Icons.Filled.CheckCircleOutline, uebersetzt("Gesehen"), gesehen) {
                        umschalten(!gesehen, { gesehen = it }, { app.kern.gesehen(ziel.id, it).await() }) { alt, an -> alt.copy(gesehen = an) }
                    }
                    Aktionsknopf(Icons.Filled.MoreHoriz, uebersetzt("Mehr"), false) {
                        // `Titelhandlungen.fuerFilm`.
                        val eintraege = buildList {
                            if (t != null && t.planDa && t.fortsetzenAb != null) {
                                add(Wahl("vonvorn", uebersetzt("Von vorn abspielen")))
                                add(Wahl("zuruecksetzen", uebersetzt("Fortschritt zurücksetzen")))
                            }
                            add(Wahl("metadaten", uebersetzt("Metadaten neu einlesen")))
                        }
                        app.blatt.value = Blattwunsch(name, eintraege, null,
                            mapOf("vonvorn" to Icons.Filled.Replay, "zuruecksetzen" to Icons.Filled.RestartAlt, "metadaten" to Icons.Filled.Refresh)) { wahl ->
                            bereich.launch {
                                when (wahl) {
                                    "vonvorn" -> app.spiel.value = Abspielwunsch(ziel.id, null)
                                    "zuruecksetzen" -> {
                                        val grund = withContext(Dispatchers.IO) { app.kern.gesehen(ziel.id, false).await() }
                                        if (grund.isNotEmpty()) meldung = fehlertext(grund)
                                        else { meldung = uebersetzt("Der Fortschritt ist zurückgesetzt."); auffrischen() }
                                    }
                                    "metadaten" -> {
                                        val grund = withContext(Dispatchers.IO) { app.kern.metadatenAuffrischen(ziel.id).await() }
                                        meldung = if (grund.isEmpty()) uebersetzt("Der Server liest die Metadaten neu ein.") else fehlertext(grund)
                                    }
                                }
                            }
                        }
                    }
                }
                t?.beschreibung?.let { Klapptext(it) }
                if (t != null && t.regie.isNotEmpty()) {
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(uebersetzt("Regie"), style = TextStyle(fontSize = 13.sp), color = Stil.schriftLeise)
                        Text(t.regie.joinToString(", "), style = TextStyle(fontSize = 13.sp), color = Stil.schrift)
                    }
                }
            }

            if (t != null && t.darsteller.isNotEmpty()) Abschnitt(uebersetzt("Besetzung"), 14.dp) {
                // Ohne Schluessel: dieselbe Person kann zweimal mitspielen.
                items(t.darsteller) { p -> Besetzungskachel(p) { oeffnen(Ziel(p.id, p.name, "Person", p.rolle, name)) } }
            }
            if (extras.isNotEmpty()) Abschnitt(uebersetzt("Extras"), 12.dp) {
                items(extras) { e -> Extrakachel(e) }
            }
            if (aehnliche.isNotEmpty()) Abschnitt(uebersetzt("Ähnliche Titel"), Stil.kachelAbstand) {
                items(aehnliche) { k -> RasterKachelAnsicht(k, Modifier.width(Stil.kachelBreite)) { oeffnen(Ziel(k.id, k.titel, k.typ)) } }
            }
            t?.datei?.let { Dateiauszug(it) }
            Spacer(Modifier.navigationBarsPadding().height(24.dp))
        }

        Detailkopf(name, { ((scroll.value / dichte - 150f) / 70f).coerceIn(0f, 1f) }, zurueck)
        Hinweisstreifen(meldung, Modifier.align(Alignment.BottomCenter)) { meldung = null }
    }
}

/** Vorlage: `Heldbild` + `Heldauslauf` — 300 hoch, Verlauf 190, Titel und Nebenzeile unten links. */
@Composable
internal fun Held(bild: String?, name: String, nebenzeile: String) {
    Box(Modifier.fillMaxWidth().height(Stil.heldHoehe)) {
        AsyncImage(model = bild, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        Heldauslauf(Modifier.align(Alignment.BottomStart))
        Column(Modifier.align(Alignment.BottomStart).padding(horizontal = Stil.randAbstand).padding(bottom = 16.dp)) {
            Text(name, style = Stil.titel.copy(letterSpacing = (-0.6).sp), color = Stil.schrift)
            if (nebenzeile.isNotEmpty()) {
                Text(nebenzeile, style = TextStyle(fontSize = 14.sp), color = Stil.schriftLeise, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

/** Vorlage: `Heldauslauf` — 190 hoch, damit der Titel auch auf hellen Plakaten nicht blank steht (war 130). */
@Composable
internal fun Heldauslauf(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().height(190.dp).background(Brush.verticalGradient(
        0f to Stil.grund.copy(alpha = 0f), 0.32f to Stil.grund.copy(alpha = 0.28f), 0.56f to Stil.grund.copy(alpha = 0.58f),
        0.78f to Stil.grund.copy(alpha = 0.85f), 1f to Stil.grund)))
}

/**
 * Vorlage: `Belegzeile` — Direct Play oder der Grund, Bewertung, Freigabe. **Mindesthoehe 26 und
 * als Ganzes eingeblendet**, damit der Knopf darunter nicht nachrutscht.
 */
@Composable
private fun Belegzeile(t: Titel?) =
    Belegzeile(t != null, t?.planDa == true, t?.lossless == true, t?.methode, t?.bewertung, t?.freigabe)

@Composable
internal fun Belegzeile(geladen: Boolean, planDa: Boolean, lossless: Boolean, methode: String?, bewertung: Double?, freigabe: String?) {
    val sichtbar by animateFloatAsState(if (geladen) 1f else 0f, Bewegung.einblenden(), label = "beleg")
    Row(Modifier.heightIn(min = 26.dp).alpha(sichtbar), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        if (planDa) {
            val farbe = if (lossless) Stil.akzent else Stil.warnung
            Row(Modifier.clip(RoundedCornerShape(8.dp)).background(farbe.copy(alpha = 0.15f))
                    .padding(start = 8.dp, end = 10.dp, top = 4.dp, bottom = 4.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(if (lossless) Icons.Filled.Check else Icons.Filled.Warning, contentDescription = null, tint = farbe, modifier = Modifier.size(12.dp))
                Text(if (lossless) "Direct Play" else methode.orEmpty(),
                     style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium), color = farbe)
            }
        }
        bewertung?.let { b ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Icon(Icons.Filled.Star, contentDescription = null, tint = Color.White.copy(alpha = 0.8f), modifier = Modifier.size(12.dp))
                Text(String.format(Locale.getDefault(), "%.1f", b), style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium),
                     color = Color.White.copy(alpha = 0.8f))
            }
        }
        freigabe?.takeIf { it.isNotBlank() }?.let {
            Text(it, style = Stil.plakette, color = Stil.schriftLeise,
                 modifier = Modifier.border(1.dp, Stil.rand, RoundedCornerShape(8.dp)).padding(horizontal = 5.dp, vertical = 2.dp))
        }
    }
}

/** Vorlage: `hauptknopf` — Fortsetzen und „Von vorn" untereinander, sonst „Abspielen". Ohne Plan gesperrt. */
@Composable
private fun Spielknoepfe(t: Titel?, spielen: (Double?) -> Unit) {
    val bereit = t?.planDa == true
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        val ab = t?.fortsetzenText
        if (ab != null) {
            Spielknopf(Icons.Filled.PlayArrow, uebersetzt("Fortsetzen ab %@", ab), bereit, haupt = true) { spielen(t?.fortsetzenAb) }
            Spielknopf(Icons.Filled.Replay, uebersetzt("Von vorn"), bereit, haupt = false) { spielen(null) }
        } else {
            Spielknopf(Icons.Filled.PlayArrow, uebersetzt("Abspielen"), bereit, haupt = true) { spielen(null) }
        }
    }
}

/**
 * Vorlage: `HauptknopfStil` / `NebenknopfStil` — 48 hoch, Ecke 10. **Weiss, nie Akzent**: der
 * Akzent traegt Zustand (E2), keine Knopffarbe.
 */
@Composable
internal fun Spielknopf(symbol: ImageVector, text: String, an: Boolean, haupt: Boolean, tun: () -> Unit) {
    val quelle = remember { MutableInteractionSource() }
    val gedrueckt by quelle.collectIsPressedAsState()
    // `HauptknopfStil`: weiss, gedrueckt 75 %; `NebenknopfStil`: 10 %, gedrueckt 16 %. Sofort an, 120 ms aus.
    val druck = remember { Animatable(0f) }
    LaunchedEffect(gedrueckt) { if (gedrueckt) druck.snapTo(1f) else druck.animateTo(0f, Bewegung.loslassen()) }
    val farbe = when { !an -> Stil.schriftSehrLeise; haupt -> Stil.grund; else -> Stil.schrift }
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).clip(RoundedCornerShape(Stil.ecke))
            .drawBehind {
                drawRect(when {
                    !an -> Stil.flaeche
                    haupt -> Color.White.copy(alpha = 1f - 0.25f * druck.value)
                    else -> Color.White.copy(alpha = 0.10f + 0.06f * druck.value)
                })
            }
            .then(if (an) Modifier.clickable(quelle, null, onClick = tun) else Modifier),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically) {
        Icon(symbol, contentDescription = null, tint = farbe, modifier = Modifier.size(18.dp))
        Text(text, style = TextStyle(fontSize = if (haupt) 16.sp else 15.sp,
                                     fontWeight = if (haupt) FontWeight.SemiBold else FontWeight.Medium), color = farbe)
    }
}

/** Vorlage: `Aktionsknopf` — 44 hoch, Flaeche, Ecke 10, aktiv im Akzent. */
@Composable
internal fun RowScope.Aktionsknopf(symbol: ImageVector, beschreibung: String, aktiv: Boolean, tun: () -> Unit) {
    Box(Modifier.weight(1f).height(44.dp).clip(RoundedCornerShape(Stil.ecke)).background(Stil.flaeche).antippen(tun),
        contentAlignment = Alignment.Center) {
        Icon(symbol, contentDescription = beschreibung, tint = if (aktiv) Stil.akzent else Stil.schrift, modifier = Modifier.size(24.dp))
    }
}

/** Vorlage: `Klapptext` — eine Zeile mit Pfeil, aufgeklappt ganz. Der volle Text war zu schwer fuer die Seite. */
@Composable
internal fun Klapptext(text: String) {
    var offen by remember { mutableStateOf(false) }
    val drehung by animateFloatAsState(if (offen) 180f else 0f, Bewegung.sprung(), label = "pfeil")
    Row(Modifier.fillMaxWidth().animateContentSize(Bewegung.sprung()).antippen { offen = !offen },
        horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(text, style = TextStyle(fontSize = 16.sp, lineHeight = 22.sp), color = Color.White.copy(alpha = 0.78f),
             maxLines = if (offen) Int.MAX_VALUE else 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        Icon(Icons.Filled.KeyboardArrowDown, contentDescription = null, tint = Color.White.copy(alpha = 0.45f),
             modifier = Modifier.padding(top = 2.dp).size(18.dp).graphicsLayer { rotationZ = drehung })
    }
}

/** Vorlage: `Abschnitt` — 26 Abstand oben, Reihentitel, waagerechte Reihe. */
@Composable
internal fun Abschnitt(titel: String, abstand: Dp, inhalt: LazyListScope.() -> Unit) {
    Column(Modifier.padding(top = 26.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(titel, style = Stil.reihe.copy(letterSpacing = (-0.3).sp), color = Stil.schrift,
             modifier = Modifier.padding(horizontal = Stil.randAbstand))
        LazyRow(contentPadding = PaddingValues(horizontal = Stil.randAbstand),
                horizontalArrangement = Arrangement.spacedBy(abstand), content = inhalt)
    }
}

/** Vorlage: `Besetzungskachel` — Kreis 76, Name zweizeilig, Rolle, 84 breit. */
@Composable
internal fun Besetzungskachel(p: Mitwirkender, tun: () -> Unit = {}) {
    Column(Modifier.width(84.dp).antippen(tun), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        SubcomposeAsyncImage(model = p.bild, contentDescription = null, contentScale = ContentScale.Crop,
            modifier = Modifier.size(76.dp).clip(CircleShape).background(Stil.flaeche),
            error = {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Icon(Icons.Filled.Person, contentDescription = null, tint = Stil.schriftSehrLeise, modifier = Modifier.size(28.dp))
                }
            })
        Text(p.name, style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Medium, textAlign = TextAlign.Center),
             color = Stil.schrift, maxLines = 2, overflow = TextOverflow.Ellipsis)
        p.rolle?.let {
            Text(it, style = Stil.klein.copy(textAlign = TextAlign.Center), color = Stil.schriftLeise, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** Vorlage: `extrasreihe` — 210 × 118, Titel, Laufzeit nur wenn bekannt. */
@Composable
private fun Extrakachel(e: Extra) {
    Column(Modifier.width(210.dp), verticalArrangement = Arrangement.spacedBy(7.dp)) {
        AsyncImage(model = e.bild, contentDescription = null, contentScale = ContentScale.Crop,
                   modifier = Modifier.size(210.dp, 118.dp).clip(RoundedCornerShape(Stil.ecke)).background(Stil.flaeche))
        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(e.name, style = Stil.kachel, color = Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis)
            e.laufzeit?.let { Text(it, style = Stil.klein, color = Stil.schriftLeise, maxLines = 1) }
        }
    }
}

/** Vorlage: `dateiauszug` — Container, Video, bis zu zwei Tonspuren, Untertitel; Ton im Akzent. */
@Composable
private fun Dateiauszug(d: Datei) {
    Column(Modifier.padding(horizontal = Stil.randAbstand).padding(top = 22.dp)) {
        Text(uebersetzt("Datei").uppercase(), style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.2.sp),
             color = Stil.schriftSehrLeise, modifier = Modifier.padding(bottom = 8.dp))
        val zeilen = buildList {
            d.container?.let { add(Triple(uebersetzt("Container"), it, false)) }
            d.video?.let { add(Triple(uebersetzt("Video"), it, false)) }
            // Die zweite Tonzeile wiederholt die Beschriftung nicht.
            d.ton.forEachIndexed { i, ton -> add(Triple(if (i == 0) uebersetzt("Ton") else " ", ton, true)) }
            add(Triple(uebersetzt("Untertitel"), d.untertitel, d.hatUntertitel))
        }
        zeilen.forEachIndexed { i, (name, wert, hervor) ->
            if (i > 0) Box(Modifier.fillMaxWidth().height(1.dp).background(Stil.linie))
            Row(Modifier.fillMaxWidth().padding(vertical = 9.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Text(name, style = TextStyle(fontSize = 12.sp), color = Stil.schriftLeise)
                Spacer(Modifier.weight(1f))
                Text(wert, style = TextStyle(fontSize = 12.sp, textAlign = TextAlign.End), color = if (hervor) Stil.akzent else Stil.schrift)
            }
        }
    }
}

/**
 * Vorlage: `Detailkopf` — Zurueck links, Titel blendet ab 150 ueber 70 Punkt ein, der Verlauf
 * ueber dem Bild geht dabei in den Grund ueber, die Haarlinie kommt mit. Die Staerke wird nur
 * in der Zeichenphase gelesen: so zeichnet Scrollen die Seite nicht neu.
 */
@Composable
internal fun Detailkopf(titel: String, staerke: () -> Float, zurueck: () -> Unit) {
    Box(Modifier.fillMaxWidth()) {
        Box(Modifier.matchParentSize().graphicsLayer { alpha = 1f - staerke() }
            .background(Brush.verticalGradient(listOf(Stil.grund.copy(alpha = 0.7f), Stil.grund.copy(alpha = 0f)))))
        Box(Modifier.matchParentSize().graphicsLayer { alpha = staerke() }.background(Stil.grund))
        Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(1.dp).graphicsLayer { alpha = staerke() }.background(Stil.linie))
        Row(Modifier.fillMaxWidth().statusBarsPadding().padding(start = 6.dp, end = Stil.randAbstand, bottom = 6.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(44.dp).antippen(zurueck), contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.ArrowBackIosNew, contentDescription = uebersetzt("Zurück"), tint = Stil.schrift, modifier = Modifier.size(22.dp))
            }
            Text(titel, style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold), color = Stil.schrift,
                 maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.graphicsLayer { alpha = staerke() })
        }
    }
}

/** Vorlage: `Hinweisstreifen` — Kapsel unten, geht nach drei Sekunden von selbst. */
@Composable
internal fun Hinweisstreifen(text: String?, modifier: Modifier, schliessen: () -> Unit) {
    LaunchedEffect(text) { if (text != null) { delay(3000); schliessen() } }
    val gemerkt = remember { arrayOfNulls<String>(1) }
    if (text != null) gemerkt[0] = text
    // Mit einem Viertel der eigenen Hoehe Weg — eine reine Ueberblendung tauchte aus dem Nichts auf.
    AnimatedVisibility(text != null, modifier,
        enter = fadeIn(tween(200, easing = Bewegung.weich)) + slideInVertically(tween(200, easing = Bewegung.weich)) { it / 4 },
        exit = fadeOut(tween(150, easing = Bewegung.weich)) + slideOutVertically(tween(150, easing = Bewegung.weich)) { it / 4 }) {
        Text(gemerkt[0].orEmpty(), style = TextStyle(fontSize = 14.sp, textAlign = TextAlign.Center), color = Stil.schrift,
             modifier = Modifier.navigationBarsPadding().padding(start = 24.dp, end = 24.dp, bottom = 34.dp).clip(CircleShape).background(Stil.erhoeht)
                 .border(1.dp, Stil.rand, CircleShape).padding(horizontal = 18.dp, vertical = 12.dp))
    }
}
