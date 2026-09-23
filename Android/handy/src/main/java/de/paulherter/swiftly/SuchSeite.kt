package de.paulherter.swiftly

import de.paulherter.swiftly.gemeinsam.Zeichen
import de.paulherter.swiftly.gemeinsam.Symbol
import de.paulherter.swiftly.gemeinsam.Staerke
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
    /** Was Seerr kennt und der eigene Server nicht — erst, wenn der eigene Server geantwortet hat. */
    var seerr by mutableStateOf<List<Seerrkachel>>(emptyList())
    var sucht by mutableStateOf(false)
    /**
     * **Der Server hat nicht geantwortet.** Der Fehler wurde verschluckt, und die leere
     * Trefferliste sagte danach „Keine Treffer fuer …" — die Suche log damit bei jedem
     * Netzfehler. Vorlage: `SucheView`, die dafuer den `Leerzustand` mit der Serverformel setzt.
     */
    var gestoert by mutableStateOf(false)
    /** Im Suchzustand — geht erst mit dem Kreuz neben dem Feld zurueck, nicht mit der Tastatur. */
    var suchmodus by mutableStateOf(false)
    /** Ein zweiter Tipp auf den Reiter — der oeffnet die Tastatur (`reiterNochmal`). */
    var nochmal by mutableIntStateOf(0)
    internal var gesucht = ""

    /** Suchen wie `SucheView.suchen` — Telefon und Fernseher rufen beide hierher. */
    suspend fun suchen(app: SwiftlyAnwendung, sauber: String) {
            if (!Kern.suchbegriffTaugt(sauber)) { treffer = emptyList(); seerr = emptyList(); sucht = false; gesucht = sauber; return }
            sucht = true
            gestoert = false
            delay(300)
            try {
                val json = withContext(Dispatchers.IO) { app.kern.suche(sauber).await() }
                treffer = JSONArray(json).let { a -> (0 until a.length()).map { rasterkachelLesen(a.getJSONObject(it)) } }
                gesucht = sauber
                // **Nebeneinander, nicht nacheinander** fuer den Nutzer: die eigenen Treffer stehen schon.
                seerr = if (app.seerrVerbunden.value) seerrkachelnLesen(withContext(Dispatchers.IO) { app.kern.seerrSuchen(sauber).await() })
                           else emptyList()
            } catch (e: CancellationException) { throw e } catch (_: Exception) {
                gestoert = true
                treffer = emptyList()
                seerr = emptyList()
            }
            sucht = false
    }
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
    // `wiederholen` ist der Knopf im Stoerhinweis: derselbe Begriff, neuer Versuch — der
    // Vergleich mit `gesucht` allein wuerde ihn wegwerfen.
    var wiederholen by remember { mutableIntStateOf(0) }
    LaunchedEffect(st.begriff, wiederholen) {
        val sauber = st.begriff.trim()
        if (sauber == st.gesucht && !st.gestoert) return@LaunchedEffect
        st.suchen(app, sauber)
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
            // `Unschaerfekopf` ohne Versatz: die Suche scrollt nicht unter ihm durch. Titel und Zeichen mittig.
            Row(Modifier.fillMaxWidth().onSizeChanged { kopfHoehe = it.height }.graphicsLayer { alpha = 1f - kopfweg.value }
                    .padding(horizontal = Stil.randAbstand).padding(bottom = 12.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Text(uebersetzt("Suchen"), style = Stil.titelGross, color = Stil.schrift,
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
                    Box(Modifier.size(36.dp).clip(CircleShape).background(Stil.flaeche), contentAlignment = Alignment.Center) {
                        Symbol(Zeichen.Kreuz, 15.dp, farbe = Stil.schriftLeise, staerke = Staerke.Halbfett, beschreibung = uebersetzt("Suche schließen"))
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
                    st.sucht && st.treffer.isEmpty() && st.seerr.isEmpty() -> {
                        ganz("abstand") { Spacer(Modifier.height(12.dp)) }
                        items(anzahl * 2, key = { "platzhalter$it" }) { Box(Modifier.padding(bottom = 20.dp)) { Kachelplatzhalter() } }
                    }
                    // **Gestoert ist nicht leer.** Vorher stand hier auch bei einem Netzfehler
                    // „Keine Treffer fuer …" — eine Aussage ueber den Bestand, die niemand
                    // geprueft hat.
                    st.gestoert && st.treffer.isEmpty() && st.seerr.isEmpty() -> ganz("gestoert") {
                        // Die ganze Serverformel, wie auf jeder anderen Seite — oben 24.
                        Box(Modifier.fillMaxWidth().padding(top = 24.dp).height(360.dp)) {
                            Leerzustand(Zeichen.ServerWeg, uebersetzt("Server ist abgetaucht"),
                                uebersetzt("%@ antwortet nicht. Läuft er noch, oder hängt das WLAN?", app.serveradresse()),
                                hauptknopf = uebersetzt("Erneut versuchen") to { wiederholen++ })
                        }
                    }
                    // Beide leer, nicht nur die Bibliothek — ein Leerzustand, darunter der Verlauf.
                    st.treffer.isEmpty() && st.seerr.isEmpty() -> {
                        ganz("keine") {
                            Box(Modifier.fillMaxWidth().padding(top = 24.dp).height(300.dp)) {
                                Leerzustand(Zeichen.Lupe, uebersetzt("Nichts gefunden zu „%@“", sauber),
                                    uebersetzt("Auf deinem Server steht dazu nichts. Manchmal ist es nur ein Buchstabe."))
                            }
                        }
                        if (verlauf.isNotEmpty()) ganz("verlauf-leer") {
                            Verlauf(verlauf, loeschen = { verlaufRoh = ""; app.ablage.merken(Kern.suchverlaufSchluessel(), "") }) { wort ->
                                st.begriff = wort
                                fokusVerwalter.clearFocus()
                            }
                        }
                    }
                    // **Nach Art gruppiert, wie bei Plex.** Folgen fragt der Server gar nicht erst ab.
                    else -> {
                    // Ohne Seerr keine Ueberschrift — sie kuendigte sonst einen Block an, dem keiner folgt.
                    if (st.seerr.isNotEmpty() && st.treffer.isNotEmpty()) ganz("block-server") { Blocktitel(uebersetzt("Auf deinem Server"), st.treffer.size) }
                    listOf(
                        "Serien" to { k: Rasterkachel -> k.typ == "Series" },
                        "Filme" to { k: Rasterkachel -> k.typ == "Movie" },
                        "Folgen" to { k: Rasterkachel -> k.typ == "Episode" },
                        "Weiteres" to { k: Rasterkachel -> k.typ !in setOf("Series", "Movie", "Episode") },
                    ).filter { (_, passt) -> st.treffer.any(passt) }.forEachIndexed { stelle, (titel, passt) ->
                        val gruppe = st.treffer.filter(passt)
                        val ersteGruppe = stelle == 0 && !(st.seerr.isNotEmpty() && st.treffer.isNotEmpty())
                        if (gruppe.isNotEmpty()) {
                            ganz("titel-$titel") {
                                // Listenzeile, nicht `Stil.gruppe`: darunter stehen Kacheln,
                                // und eine Versalienzeile waere dort eine dritte Bauart.
                                // Oben 14 — bei allen ausser der ersten Gruppe stehen davon schon 10 unter
                                // dem Raster darueber (20 Zeilenabstand statt 10 Rasterende).
                                Text(uebersetzt(titel), style = Stil.listentitel,
                                     color = Stil.schriftLeise, modifier = Modifier.padding(top = if (ersteGruppe) 14.dp else 4.dp, bottom = 6.dp))
                            }
                            // Jeder Treffer fuehrt auf seine Seite — nichts spielt direkt aus der Suche (A7).
                            items(gruppe, key = { it.id }) { k ->
                                // 20 wie in Bibliothek, Merkliste und Genre — die schmale Suche stand als einzige auf 16.
                                RasterKachelAnsicht(k, Modifier.padding(bottom = 20.dp)) { oeffnen(Ziel(k.id, k.titel, k.typ)) }
                            }
                        }
                    }
                    if (st.seerr.isNotEmpty()) {
                        ganz("block-seerr") { Blocktitel(uebersetzt("Über Seerr anfragen"), st.seerr.size, Modifier.padding(top = 8.dp)) }
                        items(st.seerr, key = { "seerr-" + it.schluessel }) { t ->
                            SeerrkachelAnsicht(t, Modifier.padding(bottom = 20.dp)) {
                                app.seerrTreffer[t.schluessel] = t
                                oeffnen(Ziel(t.schluessel, t.titel, "Seerrtitel"))
                            }
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
    val tastatur = androidx.compose.ui.platform.LocalSoftwareKeyboardController.current
    // 48 wie jedes andere Feld — es stand als einziges auf 44.
    Row(modifier.heightIn(min = Stil.knopfHoehe).clip(RoundedCornerShape(Stil.eckeFeld)).background(Stil.flaeche)
            .clickable(remember { MutableInteractionSource() }, null) { fokus.requestFocus() }
            .padding(start = 14.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Symbol(Zeichen.Lupe, 17.dp, farbe = Stil.schriftSehrLeise)
        Box(Modifier.weight(1f)) {
            if (text.isEmpty()) Text(uebersetzt("Filme, Serien, Folgen"), style = Stil.koerper, color = Stil.schriftSehrLeise)
            BasicTextField(value = text, onValueChange = aendern, singleLine = true,
                textStyle = Stil.koerper.copy(color = Stil.schrift), cursorBrush = SolidColor(Stil.akzent),
                keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, imeAction = ImeAction.Search),
                // Wie iOS: Suchen schickt ab **und** schliesst die Tastatur — die Treffer stehen ja schon.
                keyboardActions = KeyboardActions(onSearch = { abschicken(); tastatur?.hide() }),
                modifier = Modifier.fillMaxWidth().focusRequester(fokus).onFocusChanged { amTippen(it.isFocused) })
        }
        if (text.isNotEmpty()) {
            // `xmark.circle.fill` mit Palette: Kreis `schriftSehrLeise`, Kreuz ausgestanzt in `flaeche`.
            Box(Modifier.size(44.dp).antippen { aendern("") }, contentAlignment = Alignment.Center) {
                Symbol(Zeichen.KreuzKreisVoll, 17.dp, farbe = Stil.schriftSehrLeise, beschreibung = uebersetzt("Eingabe löschen"))
            }
        } else Spacer(Modifier.width(14.dp))
    }
}

@Composable
private fun Leerhinweis() {
    Column(Modifier.fillMaxWidth().padding(top = 70.dp), horizontalAlignment = Alignment.CenterHorizontally,
           verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Symbol(Zeichen.Lupe, 44.dp, farbe = Stil.schriftSehrLeise)
        Text(uebersetzt("Filme, Serien und Folgen durchsuchen"), style = Stil.koerper, color = Stil.schriftLeise)
    }
}

/** „Zuletzt gesucht" — ein Tipp sucht erneut; „Löschen" leert den ganzen Verlauf. */
@Composable
private fun Verlauf(woerter: List<String>, loeschen: () -> Unit, waehlen: (String) -> Unit) {
    Column {
        Row(Modifier.fillMaxWidth().padding(top = 18.dp), verticalAlignment = Alignment.Bottom) {
            // Rubrik: 20 Semibold in Normalschreibung, `schriftLeise` (BRAND 2). Eine
            // Suchrubrik hat keine andere Rolle als eine Einstellungsrubrik.
            Text(uebersetzt("Zuletzt gesucht"),
                 style = Stil.reihe,
                 color = Stil.schriftLeise, modifier = Modifier.weight(1f))
            Text(uebersetzt("Löschen"), style = Stil.kachel, color = Stil.schriftSehrLeise,
                 modifier = Modifier.antippen(loeschen))
        }
        woerter.forEachIndexed { i, wort ->
            if (i > 0) Box(Modifier.padding(start = 34.dp).fillMaxWidth().height(1.dp).background(Stil.linie))
            Row(Modifier.fillMaxWidth().heightIn(min = 44.dp).druckzeile { waehlen(wort) },
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(Modifier.width(20.dp), contentAlignment = Alignment.Center) { Symbol(Zeichen.Verlauf, 15.dp, farbe = Stil.schriftSehrLeise) }
                Text(wort, style = Stil.listentitel, color = Stil.schrift,
                     maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}
