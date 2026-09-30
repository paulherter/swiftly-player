package de.paulherter.swiftly

import de.paulherter.swiftly.gemeinsam.Zeichen
import de.paulherter.swiftly.gemeinsam.Symbol
import de.paulherter.swiftly.gemeinsam.Staerke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.SubcomposeAsyncImage
import de.paulherter.swiftly.gemeinsam.Stil
import androidx.compose.foundation.layout.wrapContentWidth
import de.paulherter.swiftly.gemeinsam.Bewegung
import de.paulherter.swiftly.gemeinsam.Wortmarke
import de.paulherter.swiftly.gemeinsam.uebersetzt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.withContext
import androidx.compose.foundation.combinedClickable
import de.paulherter.swiftly.kern.Kern
import androidx.lifecycle.repeatOnLifecycle
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.launch
import org.json.JSONObject

data class Kachel(val id: String, val name: String, val typ: String, val unterzeile: String?,
                  val plakat: String?, val quer: String?, val fortschritt: Double?,
                  val marke: String? = null, val markenzahl: Int = 0,
                  val angabenzeile: String? = null, val restzeit: String? = null,
                  val gesehen: Boolean = false, val folgenname: String? = null,
                  /** Nur fuers Watch-Next-Regal auf dem Fernseher (`TvWeiterschauenRegal.kt`). */
                  val laufzeitSekunden: Double? = null, val positionSekunden: Double? = null,
                  /** Nur fuer den Fernseher-Kopf (`Kopfauskunft` in `tv/TvStart.kt`) — Bewertung,
                   *  Freigabe und Beschreibung des Titels unter dem Fokus, wie `Kopfauskunft` sie
                   *  auf tvOS aus dem vollen `Item` liest. Das Telefon liest sie nicht. */
                  val bewertung: Double? = null, val freigabe: String? = null, val beschreibung: String? = null,
                  /** Nur fuer den Fernseher: die Kulisse, dieselbe Adresse wie `Titel.kulisse`/`Serie.kulisse`
                   *  (`Kern.kulisse`) — damit Start und Detailseite dasselbe Bild und denselben Ton zeigen. */
                  val kulisse: String? = null,
                  /** „S2 · F5 · noch 12 Min." — die Zeile unter einer Weiterschauen-Kachel (Entwurf D, `weiterschauenzeile`). */
                  val weiterschauenzeile: String? = null)
/**
 * `schluessel` ist der rohe, unuebersetzte Reihenname aus dem Paket (`Startreihe.reihentitel`
 * in `Startreihen.swift`, z. B. „Weiterschauen" oder „Zuletzt hinzugefügt") — `null` bei
 * Genre-Reihen. `titel` ist dagegen schon uebersetzt und dient nur der Anzeige. Das
 * Watch-Next-Regal braucht den rohen Schluessel: er bleibt in jeder Spracheinstellung
 * derselbe, der uebersetzte Titel nicht.
 */
data class Reihe(val titel: String, val schluessel: String?, val quer: Boolean, val kacheln: List<Kachel>)

/** Liest die Antwort von `Kern.startseite` — die Reihen stehen dort schon fertig. */
internal fun reihenLesen(json: String): List<Reihe> {
    val reihen = JSONObject(json).getJSONArray("reihen")
    return (0 until reihen.length()).map { i ->
        val r = reihen.getJSONObject(i)
        val schluessel = if (r.isNull("titelSchluessel")) null else r.getString("titelSchluessel")
        val titel = schluessel?.let { uebersetzt(it) } ?: r.optString("name")
        val kacheln = r.getJSONArray("kacheln")
        Reihe(titel, schluessel, r.getBoolean("quer"), (0 until kacheln.length()).map { k ->
            val o = kacheln.getJSONObject(k)
            Kachel(o.getString("id"), o.getString("name"), o.getString("typ"),
                   o.optString("unterzeile").takeIf { !o.isNull("unterzeile") },
                   o.optString("plakat").takeIf { !o.isNull("plakat") },
                   o.optString("quer").takeIf { !o.isNull("quer") },
                   if (o.isNull("fortschritt")) null else o.getDouble("fortschritt"),
                   o.optString("marke").takeIf { !o.isNull("marke") }, o.optInt("markenzahl"),
                   o.optString("angabenzeile").takeIf { !o.isNull("angabenzeile") },
                   o.optString("restzeit").takeIf { !o.isNull("restzeit") },
                   o.optBoolean("gesehen"),
                   o.optString("folgenname").takeIf { !o.isNull("folgenname") },
                   if (o.isNull("laufzeitSekunden")) null else o.getDouble("laufzeitSekunden"),
                   if (o.isNull("positionSekunden")) null else o.getDouble("positionSekunden"),
                   if (o.isNull("bewertung")) null else o.getDouble("bewertung"),
                   o.optString("freigabe").takeIf { !o.isNull("freigabe") },
                   o.optString("beschreibung").takeIf { !o.isNull("beschreibung") },
                   o.optString("kulisse").takeIf { o.has("kulisse") && !o.isNull("kulisse") },
                   o.optString("weiterschauenzeile").takeIf { o.has("weiterschauenzeile") && !o.isNull("weiterschauenzeile") })
        })
    }
}

/**
 * **Aus „Weiterschauen" direkt in die Wiedergabe** — `starte` in `HomeView`: die Stelle frisch holen,
 * die aus der Liste ist oft veraltet. Gibt es keinen Plan, fuehrt der Tipp auf die Seite.
 */
internal suspend fun weiterschauenWunsch(app: SwiftlyAnwendung, id: String): Abspielwunsch? = runCatching {
    titelLesen(withContext(Dispatchers.IO) { app.kern.titel(id).await() }).takeIf { it.planDa }?.let { Abspielwunsch(id, it.fortsetzenAb) }
}.getOrNull()

/** Vorlage: `HomeView` in `Sources/Shared/HomeView.swift` (Kopf, Reihen, Kacheln). */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun StartSeite(app: SwiftlyAnwendung, oeffnen: (Ziel) -> Unit) {
    var reihen by remember { mutableStateOf(app.startReihen) }
    val lauf = rememberCoroutineScope()
    var startet by remember { mutableStateOf(false) }
    fun weiterschauen(k: Kachel) {
        if (startet) return
        startet = true
        lauf.launch {
            val wunsch = weiterschauenWunsch(app, k.id)
            if (wunsch != null) app.spiel.value = wunsch else oeffnen(Ziel(k.id, k.name, k.typ))
            startet = false
        }
    }
    var fehler by remember { mutableStateOf<String?>(null) }
    val e = app.einstellungen
    suspend fun laden() {
        // Laeuft ein Kontowechsel, laedt der — nicht die Rueckkehr auf die Seite, die mit ihm zusammenfaellt.
        if (Kontowechselflug.wartet && !Kontowechselflug.gewechselt) return
        try {
            val json = withContext(Dispatchers.IO) {
                app.kern.startseite(e.neuzugangGetrennt, e.startReihen.toTypedArray(), e.startAus.toTypedArray(),
                                    app.ablage.merkwert("bibliothek-movies").orEmpty(), app.ablage.merkwert("bibliothek-tvshows").orEmpty(),
                                    e.startGenres.toTypedArray(), e.genreChips).await()
            }
            reihen = reihenLesen(json).also { app.startReihen = it }
            app.startGeladenUm = System.currentTimeMillis()
            fehler = null
        } catch (e: Throwable) {
            fehler = fehlertext(app, e)
        }
    }
    // Neu laden, sobald sich Reihenfolge, ausgeblendete Reihen oder Genres aendern.
    LaunchedEffect(e.neuzugangGetrennt, e.startReihen, e.startAus, e.startGenres, e.genreChips) { laden() }
    // **Nach dem Zusehen neu holen, ohne Frist** (D8): „Weiterschauen" ist dann sicher veraltet.
    val spielt = app.spiel.value != null
    var hatGespielt by remember { mutableStateOf(false) }
    LaunchedEffect(spielt) { if (spielt) hatGespielt = true else if (hatGespielt) { hatGespielt = false; laden() } }
    // Und noch einmal, wenn die Endmeldung durch ist — erst dann kennt der Server die Stelle.
    // Auch nach einer Aenderung am Sehstand (Kachelmenue) — `seitenAuffrischen` auf iOS.
    val beendet = app.wiedergabeBeendet.intValue + app.sehstandGeaendert.intValue
    val beendetAnfangs = remember { beendet }
    LaunchedEffect(beendet) { if (beendet != beendetAnfangs) laden() }
    // Zurueck in die App: neu, wenn der Stand aelter als die Frist aus dem Paket ist.
    @Suppress("DEPRECATION")
    val lebenszyklus = androidx.compose.ui.platform.LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(lebenszyklus) {
        lebenszyklus.repeatOnLifecycle(androidx.lifecycle.Lifecycle.State.STARTED) {
            if (Kern.auffrischungFaellig(app.startGeladenUm)) laden()
        }
    }
    var zieht by remember { mutableStateOf(false) }
    val ziehstand = androidx.compose.material3.pulltorefresh.rememberPullToRefreshState()
    // Langer Druck auf jede Kachel: das Kachelmenue mit Vorschau (`Kachelmenue`) — bei „Weiterschauen" mit
    // „Zur Uebersicht" und „Aus Weiterschauen entfernen". Danach zieht die Seite nach.
    val nachher: () -> Unit = { lauf.launch { laden() } }
    val liste = androidx.compose.foundation.lazy.rememberLazyListState()
    val dichte = androidx.compose.ui.platform.LocalDensity.current
    // Wie weit gescrollt ist — daran zieht der Kopfverlauf auf, wie `weg.wert` auf dem iPhone.
    val versatz by remember {
        androidx.compose.runtime.derivedStateOf {
            if (liste.firstVisibleItemIndex > 0) 400f
            else liste.firstVisibleItemScrollOffset / dichte.density
        }
    }

    // **Kein Schein.** Hier lag ein farbiger Schein hinter dem Kopf; auf dem iPhone ist er gefallen,
    // die Startseite traegt denselben dunklen Kopfverlauf wie jede andere Seite — und der zieht erst
    // auf, wenn darunter etwas durchlaeuft.
    KopfUndInhalt(kopf = { StartKopf(app, oeffnen) { versatz } }) { kopfDp ->
    Box(Modifier.fillMaxSize()) {
        // **Ziehen laedt neu** (`.refreshable`). Der Kreis erscheint unter dem Kopf, nicht dahinter.
        androidx.compose.material3.pulltorefresh.PullToRefreshBox(zieht, onRefresh = { lauf.launch { zieht = true; laden(); zieht = false } },
            state = ziehstand, modifier = Modifier.fillMaxSize(),
            indicator = {
                androidx.compose.material3.pulltorefresh.PullToRefreshDefaults.Indicator(ziehstand, zieht,
                    Modifier.align(Alignment.TopCenter).padding(top = kopfDp), containerColor = Stil.erhoeht, color = Stil.akzent)
            }) {
        LazyColumn(state = liste, verticalArrangement = Arrangement.spacedBy(Stil.reihenAbstand),
                   // `contentMargins(.top, 58)` plus 8: 66 unter dem Statusbereich, der Kopf endet bei 42.
                   contentPadding = PaddingValues(top = kopfDp + 24.dp, bottom = 12.dp),
                   modifier = Modifier.fillMaxSize().bereichsinhalt()) {
            // **Ein Serverfehler ist kein „hier ist nichts", und auch keine Fussnote.**
            //
            // Hier stand der Fehlertext als eine leise Zeile in `warnung` ueber einer sonst
            // leeren Seite: die Startseite sah aus, als waere der Server leer. Vorlage ist
            // `HomeView.nichtsDa` — die ganze Fläche, die Serverformel, und **zwei** Auswege:
            // erneut versuchen und den Server wechseln. `warnung` heisst „etwas wartet auf
            // jemanden"; hier ist etwas schiefgegangen, und das ist `fehler`.
            //
            // Stehen schon Reihen da, bleibt es bei der leisen Zeile — dann ist der Inhalt da
            // und nur das Auffrischen misslungen.
            if (fehler != null && reihen.isNullOrEmpty() && !Kontowechselflug.wartet) item(key = "gestoert") {
                Box(Modifier.fillMaxWidth().height(420.dp)) {
                    Leerzustand(Zeichen.ServerWeg, uebersetzt("Server ist abgetaucht"),
                        uebersetzt("%@ antwortet nicht. Läuft er noch, oder hängt das WLAN?", app.serveradresse()),
                        hauptknopf = uebersetzt("Erneut versuchen") to { lauf.launch { laden() } },
                        stillerKnopf = uebersetzt("Server wechseln") to { app.abmelden() })
                }
            } else fehler?.let { item { Text(it, color = Stil.fehler, style = Stil.klein, modifier = Modifier.padding(horizontal = Stil.randAbstand)) } }
            // Platzhalter in der Form der Reihen, dann eine Ueberblendung — kein Ring (`einblenden`).
            // **Waehrend eines Kontowechsels gar nicht gebaut** (Entwurf D): beim Tipp sind die Reihen des alten
            // Kontos sofort weg, und was mitten im Flug ankommt, wird erst nach der Landung gesetzt — dann
            // gestaffelt (`reihenauftritt`).
            val wechselt = Kontowechselflug.wartet
            if (reihen == null && !wechselt) items(3, key = { "platzhalter$it" }) { i ->
                Reihenplatzhalter(quer = i == 0, Modifier.animateItem(fadeInSpec = null, placementSpec = null, fadeOutSpec = Bewegung.einblenden()))
            }
            // Genres entweder als Chips oder als Reihen, nie beides — die Fassade laesst die Reihen dann weg.
            if (e.genreChips && e.startGenres.isNotEmpty() && !wechselt) item(key = "gattungschips") {
                Box(Modifier.reihenauftritt(0)) { Gattungschips(e.startGenres) { g -> oeffnen(Ziel(g, g, "Genre")) } }
            }
            val sichtbar = if (wechselt) emptyList() else reihen ?: emptyList()
            itemsIndexed(sichtbar, key = { _, r -> r.titel }) { i, reihe ->
                ReiheAnsicht(reihe, oeffnen, if (reihe.quer) { k -> weiterschauen(k) } else null, nachher,
                             Modifier.animateItem(fadeInSpec = Bewegung.einblenden(), placementSpec = null, fadeOutSpec = null).reihenauftritt(i + 1))
            }
        }
        }
    }
    }
}

/** Vorlage: Kopf in `HomeView` — Wortmarke 30 links, `Kopfziele` rechts, im `Unschaerfekopf`. */
@Composable
private fun StartKopf(app: SwiftlyAnwendung, oeffnen: (Ziel) -> Unit, versatz: () -> Float) {
    Wurzelkopf(versatz) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Wortmarke(hoehe = 30.dp)
            Spacer(Modifier.weight(1f))
            Kopfziele(app, oeffnen)
        }
    }
}

@Composable
private fun ReiheAnsicht(reihe: Reihe, oeffnen: (Ziel) -> Unit, direkt: ((Kachel) -> Unit)?, nachher: () -> Unit, modifier: Modifier = Modifier) {
    // 12 zwischen Titel und Reihe; der Titel traegt die Sperrung seiner Stufe (−0,24).
    Column(modifier, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(reihe.titel, style = Stil.reihe, color = Stil.schrift,
             modifier = Modifier.padding(horizontal = Stil.randAbstand))
        LazyRow(contentPadding = PaddingValues(horizontal = Stil.randAbstand),
                horizontalArrangement = Arrangement.spacedBy(Stil.kachelAbstand)) {
            items(reihe.kacheln, key = { it.id }) { k -> KachelAnsicht(k, reihe.quer, weiterschauen = reihe.quer, nachher) { direkt?.invoke(k) ?: oeffnen(Ziel(k.id, k.name, k.typ)) } }
        }
    }
}

/** Vorlage: `Kachel` in `HomeView.swift` — 112×168 hochkant, 236×133 quer, Ecke 10, Balken 4 unten. */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun KachelAnsicht(k: Kachel, quer: Boolean, weiterschauen: Boolean, nachher: () -> Unit, tun: () -> Unit) {
    val breite: Dp = if (quer) 236.dp else Stil.kachelBreite
    val hoehe: Dp = if (quer) 133.dp else Stil.kachelHoehe
    // Die leise Zeile unter dem Namen: bei „Weiterschauen" mit der Restzeit — „S2 · F5 · noch 12 Min."
    // (Entwurf D). Das Bild bleibt frei; die Angabe steht, wo das Kuerzel ohnehin stand.
    val unterzeile = (if (weiterschauen) k.weiterschauenzeile else null) ?: k.unterzeile
    val beruehrung = Modifier.kachelDruck({
        Kachelmenuewunsch(k.id, k.name, k.typ, if (quer) k.quer ?: k.plakat else k.plakat, quer, k.angabenzeile,
                          weiterschauen = weiterschauen, nachher = nachher)
    }, tun)
    // **Eine Kachel ist EIN Element fuer TalkBack**, nicht Bild plus zwei Textzeilen einzeln —
    // sonst muesste man dreimal wischen, um an die naechste zu kommen.
    val anteil = k.fortschritt?.takeIf { it > 0.0 && it < 1.0 }
    val beschreibung = listOfNotNull(
        k.name, unterzeile,
        anteil?.let { uebersetzt("%lld Prozent gesehen", (it * 100).toInt()) } ?: if (k.gesehen) uebersetzt("Gesehen") else null
    ).joinToString(", ")
    Column(Modifier.width(breite).einblenden().then(beruehrung)
            .semantics(mergeDescendants = true) { contentDescription = beschreibung },
        verticalArrangement = Arrangement.spacedBy(7.dp)) {
        Box(Modifier.size(breite, hoehe).clip(RoundedCornerShape(Stil.eckeKachel)).background(Stil.flaeche)) {
            val adresse = if (quer) k.quer ?: k.plakat else k.plakat
            // **Kein `SubcomposeAsyncImage` in Reihen**: es komponiert je Kachel nach und kostete beim
            // schnellen Scrollen ganze Bilder (gemessen: 99. Perzentil 81 ms auf dem Pixel 10 Pro).
            var fehlt by remember(adresse) { mutableStateOf(adresse == null) }
            if (fehlt) Ersatz(k)
            // Das Bild ist dekorativ: die Kachel spricht ihre Beschreibung schon als Ganzes.
            coil3.compose.AsyncImage(model = adresse, contentDescription = null, contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(), onError = { fehlt = true })
            k.fortschritt?.takeIf { it > 0 && LocalFortschrittZeigen.current }?.let { Fortschrittsbalken(it, Modifier.align(Alignment.BottomStart)) }
        }
        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(k.name, style = Stil.kachel, color = Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis)
            unterzeile?.let { Text(it, style = Stil.klein.copy(fontFeatureSettings = "tnum"), color = Stil.schriftSehrLeise, maxLines = 1) }
        }
    }
}

@Composable
private fun Ersatz(k: Kachel) {
    Box(Modifier.fillMaxSize().background(Stil.flaeche), contentAlignment = Alignment.Center) {
        Symbol(if (k.typ == "Episode" || k.typ == "Series") Zeichen.Fernseher else Zeichen.Film, 22.dp, farbe = Stil.schriftSehrLeise)
    }
}

/** Vorlage: `Reihenplatzhalter` — Titelbalken 148 × 18, darunter vier Kacheln in der Form, die kommt. */
@Composable
private fun Reihenplatzhalter(quer: Boolean, modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(11.dp)) {
        Ladefeld(Modifier.padding(horizontal = Stil.randAbstand).size(148.dp, 18.dp), 4.dp)
        Row(Modifier.padding(horizontal = Stil.randAbstand).wrapContentWidth(Alignment.Start, unbounded = true),
            horizontalArrangement = Arrangement.spacedBy(Stil.kachelAbstand)) {
            repeat(4) { Ladefeld(if (quer) Modifier.size(236.dp, 133.dp) else Modifier.size(Stil.kachelBreite, Stil.kachelHoehe)) }
        }
    }
}
