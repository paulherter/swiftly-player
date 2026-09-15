package de.paulherter.swiftly

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.EaseOut
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyGridScope
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.gemeinsam.Bewegung
import de.paulherter.swiftly.gemeinsam.Stil
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.expandHorizontally
import androidx.compose.animation.shrinkHorizontally
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.onSizeChanged
import de.paulherter.swiftly.gemeinsam.uebersetzt
import de.paulherter.swiftly.kern.Kern
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.future.await
import kotlinx.coroutines.withContext
import org.json.JSONArray

/**
 * **Der Stand der Suche lebt in der App**, nicht in der Seite: wer den Bereich verlaesst und
 * zurueckkommt, findet Begriff, Treffer und Suchzustand, wie er sie liess (iOS, `aktiv`).
 */
class Suchstand {
    var begriff by mutableStateOf("")
    var treffer by mutableStateOf<List<Rasterkachel>>(emptyList())
    var sucht by mutableStateOf(false)
    /** Im Suchzustand — geht erst mit dem Kreuz neben dem Feld zurueck, nicht mit der Tastatur. */
    var suchmodus by mutableStateOf(false)
    /** Ein zweiter Tipp auf den Reiter — der oeffnet die Tastatur (`reiterNochmal`). */
    var nochmal by mutableIntStateOf(0)
    internal var gesucht = ""
}

/**
 * Vorlage: `SucheView` in `Sources/Shared/SucheView.swift`, schmale Fassung.
 *
 * - **Der Reiter oeffnet die Tastatur nicht.** Sonst sah man nie, was die Seite selbst zeigt
 *   (Verlauf, Hinweis); erst ein zweiter Tipp auf den Reiter holt sie.
 * - **Der Suchzustand ist nicht die Tastatur:** wer sie nach dem Tippen schliesst, will die
 *   Treffer lesen — wuerde die Seite dann zurueckspringen, rutschte alles unter dem Daumen weg.
 * - Gemerkt wird ein Begriff beim Abschicken, nicht bei jedem Tastendruck.
 * - Mindestlaenge, Verlauf und Trefferzeile stehen im Paket.
 */
@Composable
fun SuchSeite(app: SwiftlyAnwendung, oeffnen: (Ziel) -> Unit) {
    val st = app.suche
    val fokus = remember { FocusRequester() }
    val fokusVerwalter = LocalFocusManager.current
    var verlaufRoh by remember { mutableStateOf(app.ablage.merkwert(Kern.suchverlaufSchluessel()).orEmpty()) }
    val verlauf = remember(verlaufRoh) {
        JSONArray(Kern.suchverlaufListe(verlaufRoh)).let { a -> (0 until a.length()).map { a.getString(it) } }
    }
    fun merken() {
        verlaufRoh = Kern.suchverlaufMerken(st.begriff, verlaufRoh)
        app.ablage.merken(Kern.suchverlaufSchluessel(), verlaufRoh)
    }

    // Der zweite Tipp auf den Reiter — nur neue Tipps zaehlen, nicht der Stand beim Wiederkommen.
    var gesehen by rememberSaveable { mutableIntStateOf(st.nochmal) }
    LaunchedEffect(st.nochmal) { if (st.nochmal != gesehen) { gesehen = st.nochmal; fokus.requestFocus() } }

    // Mit Verzoegerung, damit nicht jeder Tastendruck eine Anfrage ausloest.
    LaunchedEffect(st.begriff) {
        val sauber = st.begriff.trim()
        if (sauber == st.gesucht) return@LaunchedEffect
        if (!Kern.suchbegriffTaugt(sauber)) { st.treffer = emptyList(); st.sucht = false; st.gesucht = sauber; return@LaunchedEffect }
        st.sucht = true
        delay(300)
        try {
            val json = withContext(Dispatchers.IO) { app.kern.suche(sauber).await() }
            st.treffer = JSONArray(json).let { a -> (0 until a.length()).map { rasterkachelLesen(a.getJSONObject(it)) } }
            st.gesucht = sauber
        } catch (e: CancellationException) { throw e } catch (_: Exception) {}
        st.sucht = false
    }

    val raster = rememberLazyGridState()
    // Scrollen schliesst die Tastatur — das Gegenstueck zum Tipp ins Leere auf iOS.
    LaunchedEffect(raster) { snapshotFlow { raster.isScrollInProgress }.collect { if (it) fokusVerwalter.clearFocus() } }

    // **Die Bewegung liegt an der ganzen Spalte, nicht am Feld** — sonst sprang eine dunkle Kante.
    //
    // Nur Deckkraft und Verschieben, keine Hoehenanimation: die liess das Raster darunter bei jedem
    // Bild neu aufbauen. Der Kopf bleibt im Layout, bis er ganz ausgeblendet ist; der Rest ruckt so
    // lange um seine Hoehe nach oben und ist dafuer um genau diese Hoehe laenger.
    val kopfweg = remember { Animatable(if (st.suchmodus) 1f else 0f) }
    LaunchedEffect(st.suchmodus) { kopfweg.animateTo(if (st.suchmodus) 1f else 0f, Bewegung.blatt()) }
    val kopfDa by remember { derivedStateOf { kopfweg.value < 1f } }
    var kopfHoehe by remember { mutableIntStateOf(0) }
    Column(Modifier.fillMaxSize().background(Stil.grund).statusBarsPadding()) {
        if (kopfDa) {
            Row(Modifier.fillMaxWidth().onSizeChanged { kopfHoehe = it.height }.graphicsLayer { alpha = 1f - kopfweg.value }
                    .padding(horizontal = Stil.randAbstand).padding(bottom = 12.dp),
                verticalAlignment = Alignment.Top) {
                Text(uebersetzt("Suchen"), style = Stil.titelGross.copy(letterSpacing = (-0.6).sp), color = Stil.schrift,
                     modifier = Modifier.weight(1f))
                Kopfziele(app, oeffnen)
            }
        }
        Column(Modifier.fillMaxWidth().weight(1f)
            .layout { messbar, grenzen ->
                val mehr = if (kopfDa) kopfHoehe else 0
                val platz = messbar.measure(grenzen.copy(minHeight = grenzen.maxHeight + mehr, maxHeight = grenzen.maxHeight + mehr))
                layout(platz.width, grenzen.maxHeight) { platz.place(0, 0) }
            }
            .graphicsLayer { translationY = if (kopfDa) -kopfHoehe * kopfweg.value else 0f }) {

        Row(Modifier.fillMaxWidth().padding(horizontal = Stil.randAbstand)
                .padding(top = if (st.suchmodus) 8.dp else 4.dp, bottom = 16.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Suchfeld(st.begriff, { st.begriff = it }, fokus, Modifier.weight(1f),
                     amTippen = { drin -> if (drin) st.suchmodus = true }, abschicken = ::merken)
            // **Der Ausweg steht neben dem Feld, nicht darin:** das Kreuz im Feld leert nur.
            // Die Zeile oeffnet ihm federnd Platz, statt das Feld springen zu lassen; es blendet
            // danach ein und geht zuerst — sonst stiess es mit dem Profilbild zusammen.
            AnimatedVisibility(st.suchmodus,
                enter = expandHorizontally(Bewegung.blatt(), expandFrom = Alignment.Start) +
                        fadeIn(tween(150, delayMillis = 100, easing = Bewegung.weich)),
                exit = shrinkHorizontally(Bewegung.blatt(), shrinkTowards = Alignment.Start) +
                       fadeOut(tween(90, easing = Bewegung.weich))) {
                Box(Modifier.padding(start = 12.dp).size(44.dp).antippen { st.begriff = ""; fokusVerwalter.clearFocus(); st.suchmodus = false },
                    contentAlignment = Alignment.Center) {
                    Box(Modifier.size(36.dp).clip(CircleShape).background(Stil.erhoeht), contentAlignment = Alignment.Center) {
                        Icon(Icons.Filled.Close, contentDescription = uebersetzt("Suche schließen"), tint = Stil.schriftLeise,
                             modifier = Modifier.size(18.dp))
                    }
                }
            }
        }

        BoxWithConstraints(Modifier.fillMaxSize()) {
            val anzahl = Stil.spalten((maxWidth - Stil.randAbstand * 2).value)
            val sauber = st.begriff.trim()
            LazyVerticalGrid(GridCells.Fixed(anzahl), state = raster,
                contentPadding = PaddingValues(start = Stil.randAbstand, end = Stil.randAbstand, bottom = 12.dp),
                horizontalArrangement = Arrangement.spacedBy(Stil.kachelAbstand),
                modifier = Modifier.fillMaxSize().bereichsinhalt()) {
                when {
                    sauber.isEmpty() && verlauf.isEmpty() -> ganz("hinweis") { Leerhinweis() }
                    sauber.isEmpty() -> ganz("verlauf") {
                        Verlauf(verlauf, loeschen = { verlaufRoh = ""; app.ablage.merken(Kern.suchverlaufSchluessel(), "") }) { wort ->
                            // Fuellt das Feld und sucht — die Tastatur bleibt zu.
                            st.begriff = wort
                            fokusVerwalter.clearFocus()
                        }
                    }
                    // **Kein Ring:** stehen schon Treffer da, bleiben sie, bis neue kommen.
                    st.sucht && st.treffer.isEmpty() -> {
                        ganz("abstand") { Spacer(Modifier.height(12.dp)) }
                        items(anzahl * 2, key = { "platzhalter$it" }) { Box(Modifier.padding(bottom = 16.dp)) { Kachelplatzhalter() } }
                    }
                    st.treffer.isEmpty() -> ganz("keine") {
                        Text(uebersetzt("Keine Treffer für „%@“", sauber), style = Stil.koerper.copy(textAlign = TextAlign.Center),
                             color = Stil.schriftLeise, modifier = Modifier.fillMaxWidth().padding(top = 40.dp))
                    }
                    // **Nach Art gruppiert, wie bei Plex.** Folgen fragt der Server gar nicht erst ab.
                    else -> listOf(
                        "Serien" to { k: Rasterkachel -> k.typ == "Series" },
                        "Filme" to { k: Rasterkachel -> k.typ == "Movie" },
                        "Folgen" to { k: Rasterkachel -> k.typ == "Episode" },
                        "Weiteres" to { k: Rasterkachel -> k.typ !in setOf("Series", "Movie", "Episode") },
                    ).forEach { (titel, passt) ->
                        val gruppe = st.treffer.filter(passt)
                        if (gruppe.isNotEmpty()) {
                            ganz("titel-$titel") {
                                Text(uebersetzt(titel), style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold),
                                     color = Stil.schriftLeise, modifier = Modifier.padding(top = 14.dp, bottom = 6.dp))
                            }
                            // Jeder Treffer fuehrt auf seine Seite — nichts spielt direkt aus der Suche (A7).
                            items(gruppe, key = { it.id }) { k ->
                                RasterKachelAnsicht(k, Modifier.padding(bottom = 16.dp)) { oeffnen(Ziel(k.id, k.titel, k.typ)) }
                            }
                        }
                    }
                }
            }
        }
        }
    }
}

private fun LazyGridScope.ganz(schluessel: String, inhalt: @Composable () -> Unit) =
    item(key = schluessel, span = { GridItemSpan(maxLineSpan) }) { inhalt() }

/** Vorlage: `Suchfeld` in `Stil.swift` — 44 hoch, Lupe, Platzhalter, Kreuz nur mit Text. */
@Composable
private fun Suchfeld(text: String, aendern: (String) -> Unit, fokus: FocusRequester, modifier: Modifier,
                     amTippen: (Boolean) -> Unit, abschicken: () -> Unit) {
    Row(modifier.height(44.dp).clip(RoundedCornerShape(Stil.eckeFeld)).background(Stil.flaeche)
            .clickable(remember { MutableInteractionSource() }, null) { fokus.requestFocus() }
            .padding(start = 14.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Icon(Icons.Filled.Search, contentDescription = null, tint = Color.White.copy(alpha = 0.45f), modifier = Modifier.size(20.dp))
        Box(Modifier.weight(1f)) {
            if (text.isEmpty()) Text(uebersetzt("Filme, Serien, Folgen"), style = TextStyle(fontSize = 16.sp), color = Color.White.copy(alpha = 0.38f))
            BasicTextField(value = text, onValueChange = aendern, singleLine = true,
                textStyle = TextStyle(fontSize = 16.sp, color = Stil.schrift), cursorBrush = SolidColor(Stil.akzent),
                keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, imeAction = ImeAction.Search),
                keyboardActions = KeyboardActions(onSearch = { abschicken() }),
                modifier = Modifier.fillMaxWidth().focusRequester(fokus).onFocusChanged { amTippen(it.isFocused) })
        }
        if (text.isNotEmpty()) {
            Box(Modifier.size(44.dp).antippen { aendern("") }, contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.Close, contentDescription = uebersetzt("Eingabe löschen"), tint = Stil.schriftLeise, modifier = Modifier.size(18.dp))
            }
        } else Spacer(Modifier.width(4.dp))
    }
}

@Composable
private fun Leerhinweis() {
    Column(Modifier.fillMaxWidth().padding(top = 70.dp), horizontalAlignment = Alignment.CenterHorizontally,
           verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Icon(Icons.Filled.Search, contentDescription = null, tint = Stil.schriftSehrLeise, modifier = Modifier.size(38.dp))
        Text(uebersetzt("Filme, Serien und Folgen durchsuchen"), style = Stil.koerper, color = Stil.schriftLeise)
    }
}

/** „Zuletzt gesucht" — ein Tipp sucht erneut; „Löschen" leert den ganzen Verlauf. */
@Composable
private fun Verlauf(woerter: List<String>, loeschen: () -> Unit, waehlen: (String) -> Unit) {
    Column {
        Row(Modifier.fillMaxWidth().padding(top = 18.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(uebersetzt("Zuletzt gesucht").uppercase(),
                 style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.2.sp),
                 color = Stil.schriftSehrLeise, modifier = Modifier.weight(1f))
            Text(uebersetzt("Löschen"), style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium), color = Stil.schriftSehrLeise,
                 modifier = Modifier.antippen(loeschen))
        }
        woerter.forEachIndexed { i, wort ->
            if (i > 0) Box(Modifier.padding(start = 34.dp).fillMaxWidth().height(1.dp).background(Stil.linie))
            Row(Modifier.fillMaxWidth().height(44.dp).druckzeile { waehlen(wort) },
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Icon(Icons.Filled.History, contentDescription = null, tint = Stil.schriftSehrLeise, modifier = Modifier.width(20.dp).height(17.dp))
                Text(wort, style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold), color = Stil.schrift,
                     maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}
