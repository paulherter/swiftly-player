package de.paulherter.swiftly

import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.IntrinsicSize
import de.paulherter.swiftly.gemeinsam.Zeichen
import de.paulherter.swiftly.gemeinsam.Symbol
import de.paulherter.swiftly.gemeinsam.Staerke
import android.content.Intent
import android.net.Uri
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.window.PopupProperties
import androidx.compose.ui.window.Popup
import androidx.compose.animation.core.MutableTransitionState
import coil3.compose.AsyncImage
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.Bewegung
import de.paulherter.swiftly.gemeinsam.uebersetzt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

data class Staffel(val id: String, val name: String)
data class Folgenstand(val id: String, val fortsetzen: Boolean, val restzeit: String?, val fortschritt: Double?,
                       val staffel: Int?, val folge: Int?, val ab: Double? = null)
data class Folge(val id: String, val titel: String, val unterzeile: String?, val bild: String?,
                 val fortschritt: Double?, val gesehen: Boolean, val ab: Double? = null,
                 /** Roh, fuer den Fernseher — `TvSerie` baut daraus das Katalogformat „F2 · Titel". */
                 val name: String = "", val nummer: Int? = null,
                 val laufzeitMin: Int? = null, val restzeit: String? = null)

/** Antwort von `Kern.serie` — Knopftext, Vorwahl der Staffel und Besetzung stehen dort schon fest. */
data class Serie(
    val id: String, val name: String, val jahr: String?, val staffelzeile: String?, val staffelzahl: Int?,
    val gattungen: String?, val kopfbild: String?, val bewertung: Double?, val freigabe: String?,
    val beschreibung: String?, val gemerkt: Boolean, val gesehen: Boolean, val trailer: String?,
    val planDa: Boolean, val lossless: Boolean, val methode: String?,
    val stand: Folgenstand?, val knopftext: String, val staffeln: List<Staffel>, val gewaehlt: String?,
    val darsteller: List<Mitwirkender>,
    /** Nur fuer den Fernseher — siehe `Kachel.kulisse`. */
    val kulisse: String? = null,
) {
    /**
     * Jahr · Staffeln · Gattungen. **Eine einzige Staffel steht mit ihrem Namen da**, nicht als
     * „1 Staffel" — neben „Abspielen S2 · E1" las sich das wie ein Widerspruch.
     */
    val nebenzeile: String
        get() = listOfNotNull(jahr, staffelzeile ?: staffelzahl?.let { uebersetzt("%lld Staffeln", it) }, gattungen)
            .joinToString(" · ")
}

internal fun serieLesen(json: String): Serie = JSONObject(json).let { o ->
    Serie(o.getString("id"), o.getString("name"), o.feldText("jahr"), o.feldText("staffelzeile"),
          if (o.isNull("staffelzahl")) null else o.getInt("staffelzahl"),
          o.feldText("gattungen"), o.feldText("kopfbild"), o.feldZahl("bewertung"), o.feldText("freigabe"),
          o.feldText("beschreibung"), o.optBoolean("gemerkt"), o.optBoolean("gesehen"), o.feldText("trailer"),
          o.optBoolean("planDa"), o.optBoolean("lossless"), o.feldText("methode"),
          o.optJSONObject("stand")?.let { s ->
              Folgenstand(s.getString("id"), s.optBoolean("fortsetzen"), s.feldText("restzeit"), s.feldZahl("fortschritt"),
                          if (s.isNull("staffel")) null else s.getInt("staffel"), if (s.isNull("folge")) null else s.getInt("folge"), s.feldZahl("ab"))
          },
          o.optString("knopftext"),
          o.feldListe("staffeln") { Staffel(it.getString("id"), it.getString("name")) },
          o.feldText("gewaehlt"),
          o.feldListe("darsteller") { Mitwirkender(it.getString("id"), it.getString("name"), it.feldText("rolle"), it.feldText("bild")) },
          if (o.has("kulisse")) o.feldText("kulisse") else null)
}

internal fun folgenLesen(json: String): List<Folge> = JSONArray(json).let { a ->
    (0 until a.length()).map { i ->
        a.getJSONObject(i).let { f ->
            Folge(f.getString("id"), f.getString("titel"), f.feldText("unterzeile"), f.feldText("bild"), f.feldZahl("fortschritt"), f.optBoolean("gesehen"), f.feldZahl("ab"),
                  f.optString("name"), if (f.isNull("nummer")) null else f.getInt("nummer"),
                  if (f.isNull("laufzeitMin")) null else f.getInt("laufzeitMin"), f.feldText("restzeit"))
        }
    }
}

/**
 * Vorlage: `SeriesDetailView` in `Sources/Shared/SeriesView.swift`, schmale Fassung — und
 * `StaffelZiel`: kommt eine Folge herein, sucht die Fassade ihre Serie und waehlt ihre Staffel vor.
 *
 * **Der Kern der Seite ist der eine Knopf** — Jellyfins NextUp beantwortet „angefangene Folge"
 * und „naechste ungesehene" in einem Zug. Aus dem Zwischenspeicher steht die Seite sofort da.
 */
@Composable
fun SerienSeite(app: SwiftlyAnwendung, ziel: Ziel, oeffnen: (Ziel) -> Unit, zurueck: () -> Unit) {
    var serie by remember(ziel.id) { mutableStateOf(app.serienSpeicher[ziel.id]) }
    var staffel by remember(ziel.id) { mutableStateOf(serie?.gewaehlt) }
    var folgen by remember(ziel.id) { mutableStateOf(staffel?.let { app.folgenSpeicher[it] }.orEmpty()) }
    /** Von Hand gewaehlt — dann korrigiert kein Neuladen die Staffel mehr. */
    var selbstGewaehlt by remember(ziel.id) { mutableStateOf(false) }
    var aehnliche by remember(ziel.id) { mutableStateOf<List<Rasterkachel>?>(null) }
    var aehnlicheGestoert by remember(ziel.id) { mutableStateOf(false) }
    // Ohne gemerkte Folgen stehen die Platzhalter vom ersten Bild an da, nicht erst mit dem Abruf.
    var folgenLaedt by remember(ziel.id) { mutableStateOf(folgen.isEmpty()) }
    var folgenGestoert by remember(ziel.id) { mutableStateOf(false) }
    var gemerkt by remember(ziel.id) { mutableStateOf(serie?.gemerkt ?: false) }
    var gesehen by remember(ziel.id) { mutableStateOf(serie?.gesehen ?: false) }
    var reiter by rememberSaveable(ziel.id) { mutableIntStateOf(0) }
    var listeOffen by remember { mutableStateOf(false) }
    var meldung by remember { mutableStateOf<String?>(null) }
    /** Der Plan kommt nach der Seite — bis dahin haelt die Belegzeile ihren Platz. */
    var planGeladen by remember(ziel.id) { mutableStateOf(serie?.planDa == true) }
    val bereich = rememberCoroutineScope()
    val kontext = LocalContext.current
    val ruck = rememberRuck()

    suspend fun folgenLaden(serieId: String, staffelId: String) {
        folgenLaedt = true
        try {
            val neu = folgenLesen(withContext(Dispatchers.IO) { app.kern.folgen(serieId, staffelId).await() })
            app.folgenSpeicher[staffelId] = neu
            if (staffel == staffelId) folgen = neu
            folgenGestoert = false
        } catch (e: CancellationException) { throw e } catch (_: Exception) {
            if (staffel == staffelId) folgenGestoert = true
        } finally { folgenLaedt = false }
    }

    suspend fun planLaden(folgeId: String) {
        try {
            val o = JSONObject(withContext(Dispatchers.IO) { app.kern.plan(folgeId).await() })
            val neu = serie?.copy(planDa = o.has("methode"), lossless = o.optBoolean("lossless"), methode = o.feldText("methode"))
            if (neu != null) { serie = neu; app.serienSpeicher[ziel.id] = neu }
            planGeladen = true
        } catch (e: CancellationException) { throw e } catch (_: Exception) { planGeladen = true }
    }

    /** **Ein Laden fuer alles**, auch nach „Staffel als gesehen" — ein eigenes Auffrischen vergass auf iOS einmal den Plan. */
    suspend fun laden() {
        try {
            val gelesen = serieLesen(withContext(Dispatchers.IO) { app.kern.serie(ziel.id).await() })
            // Den schon bekannten Plan behalten, bis der neue da ist — sonst flackert die Belegzeile.
            val alt = serie
            val neu = if (alt != null && alt.stand?.id == gelesen.stand?.id)
                gelesen.copy(planDa = alt.planDa, lossless = alt.lossless, methode = alt.methode) else gelesen
            neu.stand?.let { st -> bereich.launch { planLaden(st.id) } } ?: run { planGeladen = true }
            val wahl = if (!selbstGewaehlt || staffel == null) neu.gewaehlt else staffel
            // **Ein Einblenden, nicht zwei.** Steht noch keine Folge da, kommen Serie und Folgen im selben
            // Bild: bis zum 23.09.2026 stand erst die Serie mit Platzhaltern, dann schrumpfte die Liste auf
            // die Folgen. Scheitert der Vorababruf, laedt `folgenLaden` wie bisher nach.
            val vorab = if (folgen.isEmpty() && wahl != null && app.folgenSpeicher[wahl] == null) try {
                folgenLesen(withContext(Dispatchers.IO) { app.kern.folgen(neu.id, wahl).await() })
            } catch (e: CancellationException) { throw e } catch (_: Exception) { null } else null
            serie = neu
            app.serienSpeicher[ziel.id] = neu
            gemerkt = neu.gemerkt
            gesehen = neu.gesehen
            if (!selbstGewaehlt || staffel == null) staffel = wahl
            if (vorab != null && wahl != null && staffel == wahl) {
                app.folgenSpeicher[wahl] = vorab
                folgen = vorab
                folgenGestoert = false
                folgenLaedt = false
            } else staffel?.let { s -> if (folgen.isEmpty()) app.folgenSpeicher[s]?.let { folgen = it }; folgenLaden(neu.id, s) }
        } catch (e: CancellationException) { throw e } catch (_: Exception) {}
    }

    /** Erst umschalten, dann fragen — sagt der Server nein, zurueck und melden. Danach neu laden: der Knopf zeigt eine andere Folge. */
    fun folgeUmschalten(f: Folge) {
        val an = !f.gesehen
        ruck(Ruck.Leicht)
        folgen = folgen.map { if (it.id == f.id) it.copy(gesehen = an, fortschritt = if (an) null else it.fortschritt) else it }
        bereich.launch {
            val grund = withContext(Dispatchers.IO) { app.kern.gesehen(f.id, an).await() }
            if (grund.isNotEmpty()) {
                meldung = fehlertext(grund)
                folgen = folgen.map { if (it.id == f.id) f else it }
            } else laden()
        }
    }

    // Nach dem Schauen neu laden: der Knopf zeigt jetzt eine andere Folge.
    val spielt = app.spiel.value != null
    var hatGespielt by remember { mutableStateOf(false) }
    LaunchedEffect(spielt) { if (spielt) hatGespielt = true else if (hatGespielt) { hatGespielt = false; laden() } }
    // Und noch einmal, wenn die Endmeldung durch ist — erst dann kennt der Server die Stelle.
    val beendet = app.wiedergabeBeendet.intValue
    val beendetAnfangs = remember { beendet }
    LaunchedEffect(beendet) { if (beendet != beendetAnfangs) laden() }

    LaunchedEffect(ziel.id) {
        laden()
        val id = serie?.id ?: return@LaunchedEffect
        try {
            val o = JSONObject(withContext(Dispatchers.IO) { app.kern.titelUmfeld(id).await() })
            aehnliche = o.feldListe("aehnliche") { rasterkachelLesen(it) }
            aehnlicheGestoert = false
        } catch (e: CancellationException) { throw e } catch (_: Exception) { aehnlicheGestoert = true }
    }

    val scroll = rememberScrollState()
    // Scrollen schliesst die Staffelliste — ein Tipp auf die Pille selbst nicht.
    LaunchedEffect(scroll) { snapshotFlow { scroll.isScrollInProgress }.collect { if (it) listeOffen = false } }
    val dichte = LocalDensity.current.density
    val s = serie
    val name = s?.name ?: ziel.name

    fun umschalten(an: Boolean, setzen: (Boolean) -> Unit, frage: suspend (String, Boolean) -> String) {
        val id = s?.id ?: return
        ruck(Ruck.Leicht)
        setzen(an)
        bereich.launch {
            val grund = withContext(Dispatchers.IO) { frage(id, an) }
            if (grund.isNotEmpty()) { setzen(!an); meldung = fehlertext(grund) }
            else app.serienSpeicher.remove(ziel.id)
        }
    }

    fun trailerStarten() {
        val adresse = s?.trailer
        val ging = adresse != null && runCatching {
            kontext.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(adresse)))
        }.isSuccess
        if (!ging) meldung = uebersetzt("Für diesen Titel liegt kein Trailer vor.")
    }

    Box(Modifier.fillMaxSize().background(Stil.grund)) {
        Column(Modifier.fillMaxSize().verticalScroll(scroll)) {
            Held(s?.kopfbild, name, s?.nebenzeile.orEmpty())

            Column(Modifier.padding(horizontal = Stil.randAbstand).padding(top = 14.dp),
                   verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Belegzeile(s != null && planGeladen, s?.planDa == true, s?.lossless == true, s?.methode, s?.bewertung, s?.freigabe)

                // Immer genau ein Knopf. Waehrend des Ladens sieht er bereit aus und sagt „Lädt…";
                // gesperrt erst, wenn feststeht, dass es keine Folge gibt. Der Player folgt.
                // Knopf und Aktionsreihe als ein Block: 8 zwischen ihnen, 14 zu allem anderen.
                Column(Modifier.padding(bottom = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Column(verticalArrangement = Arrangement.spacedBy(9.dp)) {
                    Spielknopf(Zeichen.Abspielen, s?.knopftext ?: uebersetzt("Lädt…"),
                               an = s == null || s.stand != null, haupt = true) {
                        s?.stand?.let { st -> ruck(Ruck.Mittel); app.spiel.value = Abspielwunsch(st.id, st.ab) }
                    }
                    s?.stand?.restzeit?.let { Text(it, style = Stil.klein, color = Stil.schriftLeise) }
                    s?.stand?.fortschritt?.takeIf { it > 0 }?.let { Fortschrittsbalken(it, Modifier.clip(RoundedCornerShape(2.dp))) }
                }

                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Aktionsknopf(if (gemerkt) Zeichen.LesezeichenVoll else Zeichen.Lesezeichen, uebersetzt("Merkliste"), gemerkt) {
                        umschalten(!gemerkt, { gemerkt = it }) { id, an -> app.kern.merken(id, an).await() }
                    }
                    // **Laden steht in der Reihe, nicht in einem versteckten Chip** — zwischen Merken
                    // und Gesehen, und immer ueber die Ladeauswahl, auch bei einer Staffel: einzelne
                    // Folgen waehlen soll man immer koennen. Der Trailer weicht dafuer ins Mehr-Blatt.
                    // Sind Downloads aus, behaelt er seinen Platz.
                    if (app.einstellungen.downloadKnopfZeigen) {
                        Aktionsknopf(Zeichen.PfeilRunter, uebersetzt("Laden"), false) {
                            s?.let { ladeauswahlZeigen(app, it.id, it.name, it.staffeln) }
                        }
                    } else {
                        Aktionsknopf(Zeichen.Film, uebersetzt("Trailer"), false) { trailerStarten() }
                    }
                    Aktionsknopf(if (gesehen) Zeichen.HakenKreisVoll else Zeichen.HakenKreis, uebersetzt("Gesehen"), gesehen) {
                        umschalten(!gesehen, { gesehen = it }) { id, an -> app.kern.gesehen(id, an).await() }
                    }
                    Aktionsknopf(Zeichen.Mehr, uebersetzt("Mehr"), false) {
                        val gewaehlteStaffel = s?.staffeln?.firstOrNull { it.id == staffel }
                        // `Titelhandlungen.fuerSerie`.
                        val eintraege = buildList {
                            // Der Trailer, wenn Laden seinen Platz in der Reihe hat — nicht zweimal.
                            if (app.einstellungen.downloadKnopfZeigen) add(Wahl("trailer", uebersetzt("Trailer")))
                            s?.stand?.let {
                                add(Wahl("vonvorn", uebersetzt("Folge von vorn abspielen")))
                                add(Wahl("naechste", uebersetzt("Nächste Folge abspielen")))
                            }
                            gewaehlteStaffel?.let { add(Wahl("staffel", uebersetzt("%@ als gesehen", it.name))) }
                            add(Wahl("metadaten", uebersetzt("Metadaten neu einlesen")))
                        }
                        val kuerzel = s?.stand?.let { st -> if (st.staffel != null && st.folge != null) " · S${st.staffel} E${st.folge}" else "" }.orEmpty()
                        app.blatt.value = Blattwunsch(name + kuerzel, eintraege, null,
                            mapOf("trailer" to Zeichen.Film, "vonvorn" to Zeichen.Zurueckspulen, "naechste" to Zeichen.Ueberspringen, "staffel" to Zeichen.HakenKreis,
                                  "metadaten" to Zeichen.Neuladen)) { wahl ->
                            bereich.launch {
                                when (wahl) {
                                    "trailer" -> trailerStarten()
                                    "vonvorn" -> s?.stand?.let { st -> app.spiel.value = Abspielwunsch(st.id, null) }
                                    // Ohne naechste Folge wird gemeldet, nicht still nichts getan.
                                    "naechste" -> s?.stand?.let { st ->
                                        val danach = withContext(Dispatchers.IO) { app.kern.folgeDanach(st.id, s.id).await() }
                                        if (danach.isNotEmpty()) app.spiel.value = Abspielwunsch(danach, null)
                                        else meldung = uebersetzt("Danach kommt nichts mehr.")
                                    }
                                    "staffel" -> gewaehlteStaffel?.let { st ->
                                        val grund = withContext(Dispatchers.IO) { app.kern.gesehen(st.id, true).await() }
                                        if (grund.isNotEmpty()) meldung = fehlertext(grund)
                                        else { meldung = uebersetzt("%@ ist als gesehen vermerkt.", st.name); laden() }
                                    }
                                    "metadaten" -> {
                                        val id = s?.id ?: return@launch
                                        val grund = withContext(Dispatchers.IO) { app.kern.metadatenAuffrischen(id).await() }
                                        meldung = if (grund.isEmpty()) uebersetzt("Der Server liest die Metadaten neu ein.") else fehlertext(grund)
                                    }
                                }
                            }
                        }
                    }
                }
                }
                s?.beschreibung?.let { Klapptext(it) }
            }

            Spacer(Modifier.height(22.dp))
            Reiter(listOf(uebersetzt("Folgen"), uebersetzt("Besetzung"), uebersetzt("Ähnliches")), reiter) { reiter = it }

            Crossfade(reiter, animationSpec = tween(160), label = "reiter") { r ->
                when (r) {
                    0 -> Column {
                        // **Keine Platzhalter** (Vorlage iOS, 23.09.2026): solange die Serie laedt, steht der
                        // Staffelknopf unsichtbar da und haelt seine Hoehe; er blendet an seinem Platz ein.
                        val kopfDa = s?.staffeln?.isNotEmpty() == true
                        val kopfSicht by animateFloatAsState(if (kopfDa) 1f else 0f, Bewegung.einblenden(), label = "staffelkopf")
                        if (kopfDa || s == null) Box(Modifier.alpha(kopfSicht)) {
                            Staffelkopf(s?.staffeln.orEmpty(), staffel, listeOffen, { listeOffen = it }) { neu ->
                                selbstGewaehlt = true
                                if (neu != staffel) {
                                    staffel = neu
                                    folgen = app.folgenSpeicher[neu].orEmpty()
                                    s?.id?.let { id -> bereich.launch { folgenLaden(id, neu) } }
                                }
                            }
                        }
                        // Keine Linien zwischen den Folgen: das Bild traegt die Zeile, 12 oben und unten.
                        // Waehrend des Ladens bleibt die Flaeche leer — nie „Keine Folgen", nie Platzhalter.
                        if (folgenGestoert) Stoerhinweis(app.serveradresse(), erneut = { s?.id?.let { id -> staffel?.let { st -> bereich.launch { folgenLaden(id, st) } } } })
                        else if (folgen.isEmpty() && !folgenLaedt && s != null && s.staffeln.isNotEmpty()) Leerhinweis(uebersetzt("Keine Folgen in dieser Staffel"))
                        val folgenSicht by animateFloatAsState(if (folgen.isNotEmpty()) 1f else 0f, Bewegung.einblenden(), label = "folgen")
                        Column(Modifier.alpha(folgenSicht)) { folgen.forEachIndexed { i, f ->
                            // Wischen schaltet gesehen — `Wischzeile` mit Haken oder Rueckpfeil.
                            key(f.id) {
                                Wischzeile(if (f.gesehen) Zeichen.Rueckgaengig else Zeichen.Haken,
                                           uebersetzt(if (f.gesehen) "Ungesehen" else "Gesehen"), tun = { folgeUmschalten(f) }) {
                                    Folgenzeile(f) { app.spiel.value = Abspielwunsch(f.id, f.ab) }
                                }
                            }
                        } }
                    }
                    1 -> {
                        val leute = s?.darsteller.orEmpty()
                        if (s != null && leute.isEmpty()) Leerhinweis(uebersetzt("Keine Besetzung hinterlegt."))
                        else Raster(leute, spalten = { breite -> maxOf(1, ((breite + 14f) / (84f + 14f)).toInt()) }, abstand = 14) { p ->
                            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
                                Besetzungskachel(p) { oeffnen(Ziel(p.id, p.name, "Person", p.rolle, name)) }
                            }
                        }
                    }
                    else -> {
                        val liste = aehnliche
                        if (aehnlicheGestoert && liste.isNullOrEmpty()) Stoerhinweis(app.serveradresse())
                        else if (liste != null && liste.isEmpty()) Leerhinweis(uebersetzt("Nichts Ähnliches gefunden."))
                        else Raster(liste.orEmpty(), spalten = { Stil.spalten(it) }, abstand = 12) { k ->
                            RasterKachelAnsicht(k) { oeffnen(Ziel(k.id, k.titel, k.typ)) }
                        }
                    }
                }
            }
            Spacer(Modifier.navigationBarsPadding().height(24.dp))
        }

        Detailkopf(name, { ((scroll.value / dichte - 150f) / 70f).coerceIn(0f, 1f) }, zurueck)
        Hinweisstreifen(meldung, Modifier.align(Alignment.BottomCenter)) { meldung = null }
    }
}

/** Vorlage: `Reiter` in `Stil.swift` — 26 Abstand, 15 pt, aktiv halbfett mit 2 Punkt Akzent darunter, Haarlinie unten. */
@Composable
private fun Reiter(titel: List<String>, gewaehlt: Int, waehlen: (Int) -> Unit) {
    Box(Modifier.fillMaxWidth().drawBehind {
        drawRect(Stil.linie, topLeft = Offset(0f, size.height - 1.dp.toPx()), size = Size(size.width, 1.dp.toPx()))
    }) {
        Row(Modifier.padding(horizontal = Stil.randAbstand), horizontalArrangement = Arrangement.spacedBy(26.dp)) {
            titel.forEachIndexed { i, t ->
                val an = i == gewaehlt
                // **Gewaehlt heisst Weiss, kein Gewichtswechsel** (BRAND 5): Semibold ist breiter
                // als Regular, und in einer **waagerechten** Reihe verschiebt sich dadurch jeder
                // Nachbar rechts davon. Der Akzentstrich darunter bleibt — er traegt Zustand.
                Text(t, style = Stil.listentitel,
                     color = if (an) Stil.schrift else Stil.schriftLeise,
                     modifier = Modifier.antippen { waehlen(i) }
                         .drawBehind {
                             // Weiss, nicht Akzent: gewaehlt ist Rangfolge, kein Zustand.
                             if (an) drawRect(Stil.schrift, topLeft = Offset(0f, size.height - 2.dp.toPx()), size = Size(size.width, 2.dp.toPx()))
                         }
                         .padding(bottom = 11.dp))
            }
        }
    }
}

/**
 * Vorlage: `Aufklappliste` — Staffelname in Reihenschrift, Pfeil nur ab zwei Staffeln. Die Liste
 * waechst von oben links, 200 breit, 44 unter der Pille, und liegt ueber den Folgen.
 */
@Composable
internal fun Staffelkopf(staffeln: List<Staffel>, gewaehlt: String?, offen: Boolean, setzeOffen: (Boolean) -> Unit,
                         kompakt: Boolean = false, waehlen: (String) -> Unit) {
    val mehrere = staffeln.size > 1
    val drehung by animateFloatAsState(if (offen) 180f else 0f, Bewegung.sprung(), label = "pfeil")
    // **Ein Tipp auf die Pille schliesst die offene Liste nur.** Er kam doppelt an: erst schloss das
    // Popup sie als Tipp daneben, dann oeffnete die Pille sie im selben Zug wieder — auf iOS behoben.
    val geschlossenUm = remember { longArrayOf(0L) }
    // **Kompakt** in der Folgenebene des Players (Vorlage `Aufklappliste(schrift: meta + 1, hoehe: 28)`):
    // an Stelle der Metazeile, ohne eigenen Rand — den gibt der Ebenenkopf.
    // `Aufklappliste(alsFeld:)`: auf der Serienseite ein Feld — 34 hoch, `flaeche`, Ecke 8, 11 innen,
    // 15 Semibold; im Player ohne Flaeche, 28 hoch, in der Metaschrift.
    val hoehe = if (kompakt) 28.dp else 34.dp
    Box(if (kompakt) Modifier.zIndex(10f) else Modifier.fillMaxWidth().zIndex(10f).padding(start = Stil.randAbstand, top = 14.dp, bottom = 14.dp)) {
        Row(Modifier.antippen { if (mehrere && android.os.SystemClock.uptimeMillis() - geschlossenUm[0] > 300) setzeOffen(!offen) }
                .height(hoehe)
                .then(if (kompakt) Modifier else Modifier.clip(RoundedCornerShape(Stil.eckeKlein)).background(Stil.flaeche).padding(horizontal = 11.dp)),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
            Text(staffeln.firstOrNull { it.id == gewaehlt }?.name ?: uebersetzt("Staffel"),
                 style = if (kompakt) Stil.klein.copy(fontSize = 13.sp, fontWeight = FontWeight.SemiBold) else Stil.listentitel,
                 color = Stil.schrift)
            if (mehrere) Symbol(Zeichen.WinkelRunter, 11.dp, Modifier.graphicsLayer { rotationZ = drehung },
                                farbe = Stil.schriftSehrLeise, staerke = Staerke.Halbfett, beschreibung = uebersetzt("Öffnet die Auswahl"))
        }
        // **Ueber den Folgen, nicht zwischen ihnen.** Ein Popup hat in der Seite keine Hoehe und bleibt
        // antippbar; eine Zeichnung ausserhalb der Kopfzeile bekaeme keine Tipps.
        val zustand = remember { MutableTransitionState(false) }
        zustand.targetState = offen
        if (zustand.currentState || zustand.targetState) {
            val dichte = LocalDensity.current
            // 16 Rand im Popup fuer die Bewegung; die Liste sitzt 6 unter dem Feld.
            val rand = with(dichte) { 16.dp.roundToPx() }
            val unten = with(dichte) { (hoehe + 6.dp).roundToPx() }
            Popup(offset = IntOffset(-rand, unten - rand), onDismissRequest = { geschlossenUm[0] = android.os.SystemClock.uptimeMillis(); setzeOffen(false) },
                  properties = PopupProperties(focusable = false)) {
                AnimatedVisibility(zustand, Modifier.padding(16.dp),
                    enter = fadeIn(Bewegung.sprung()) + scaleIn(Bewegung.sprung(), initialScale = 0.94f, transformOrigin = TransformOrigin(0f, 0f)),
                    exit = fadeOut(Bewegung.sprung()) + scaleOut(Bewegung.sprung(), targetScale = 0.94f, transformOrigin = TransformOrigin(0f, 0f))) {
                // **So breit wie der laengste Name, mindestens 180** — fest 200 liess rechts eine Luecke.
                // Ecke 10, keine Schatten.
                Column(Modifier.width(IntrinsicSize.Max).widthIn(min = 180.dp).clip(RoundedCornerShape(Stil.ecke)).background(Stil.flaeche)) {
                    staffeln.forEach { st ->
                        val an = st.id == gewaehlt
                        // Haken links, immer als Platz da; gewaehlt Weiss, sonst leise — 15 Semibold, 14/9 innen.
                        Row(Modifier.fillMaxWidth().druckzeile { setzeOffen(false); waehlen(st.id) }.padding(horizontal = 14.dp, vertical = 9.dp),
                            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            Box(Modifier.width(18.dp), contentAlignment = Alignment.Center) {
                                if (an) Symbol(Zeichen.Haken, 15.dp, farbe = Stil.schrift, staerke = Staerke.Halbfett)
                            }
                            Text(st.name, style = Stil.listentitel, color = if (an) Stil.schrift else Stil.schriftLeise, maxLines = 1)
                        }
                    }
                }
                }
            }
        }
    }
}

/**
 * Vorlage: `Folgenzeile` — Bild 116 × 65, Titel „3. Name" zweizeilig, darunter Restzeit oder Laufzeit.
 * **Gesehen tritt zurueck**, statt zu verschwinden: Bild und Titel gedaempft, Haken auf dem Bild.
 * Balken und Haken zugleich waeren dieselbe Auskunft zweimal.
 */
@Composable
internal fun Folgenzeile(f: Folge, ende: (@Composable () -> Unit)? = null, tun: () -> Unit) {
    Folgenzeilenaufbau(Modifier.druckzeile(tun), f.titel, f.unterzeile, if (f.gesehen) Stil.schriftLeise else Stil.schrift, ende = ende) {
        Box(Modifier.size(116.dp, 65.dp).clip(RoundedCornerShape(Stil.eckeKachel)).background(Stil.flaeche)
                .alpha(if (f.gesehen) 0.45f else 1f)) {
            AsyncImage(model = f.bild, contentDescription = null, contentScale = ContentScale.Crop,
                       modifier = Modifier.fillMaxSize())
            // Balken und Haken zugleich waeren dieselbe Auskunft zweimal.
            if (!f.gesehen) f.fortschritt?.takeIf { it > 0 }?.let { Fortschrittsbalken(it, Modifier.align(Alignment.BottomStart)) }
            if (f.gesehen) {
                // 0,78 wie jede andere dunkle Scheibe auf einem Bild.
                Box(Modifier.align(Alignment.TopEnd).padding(5.dp).size(18.dp).clip(CircleShape).background(Stil.grund.copy(alpha = 0.78f)),
                    contentAlignment = Alignment.Center) {
                    Symbol(Zeichen.Haken, 10.dp, farbe = Stil.schrift, staerke = Staerke.Halbfett, beschreibung = uebersetzt("Gesehen"))
                }
            }
        }
    }
}

/** Vorlage: `Folgenzeilenaufbau` (iOS) — der Aufbau einer Folgenzeile; auf iOS teilt ihn der Platzhalter der Staffelansicht. */
@Composable
private fun Folgenzeilenaufbau(modifier: Modifier, titel: String, unterzeile: String?, titelfarbe: Color,
                               ende: (@Composable () -> Unit)? = null, bild: @Composable () -> Unit) {
    Row(Modifier.fillMaxWidth().then(modifier).padding(horizontal = Stil.randAbstand, vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        bild()
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            // Zeile mit Bild: Titel 15 Semibold, Unterzeile 12 (BAUTEILE 6).
            // **Einzeilig** — zwei Zeilen liessen die Zeilen einer Staffel verschieden hoch enden.
            Text(titel, style = Stil.listentitel, color = titelfarbe, maxLines = 1, overflow = TextOverflow.Ellipsis)
            unterzeile?.let { Text(it, style = Stil.klein, color = Stil.schriftSehrLeise, maxLines = 1) }
        }
        ende?.let { Box(Modifier.align(Alignment.CenterVertically)) { it() } }
    }
}

/** Raster in einer scrollenden Seite — ohne eigene Scrollflaeche, die Spalten aus der Breite. */
@Composable
private fun <T> Raster(eintraege: List<T>, spalten: (Float) -> Int, abstand: Int, zelle: @Composable (T) -> Unit) {
    BoxWithConstraints(Modifier.fillMaxWidth().padding(horizontal = Stil.randAbstand).padding(top = 20.dp)) {
        val anzahl = spalten(maxWidth.value)
        Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {
            eintraege.chunked(anzahl).forEach { reihe ->
                Row(horizontalArrangement = Arrangement.spacedBy(abstand.dp)) {
                    reihe.forEach { Box(Modifier.weight(1f)) { zelle(it) } }
                    repeat(anzahl - reihe.size) { Spacer(Modifier.weight(1f)) }
                }
            }
        }
    }
}

@Composable
private fun Leerhinweis(text: String) {
    Text(text, style = Stil.koerper.copy(textAlign = TextAlign.Center), color = Stil.schriftSehrLeise,
         modifier = Modifier.fillMaxWidth().padding(top = 40.dp, start = Stil.randAbstand, end = Stil.randAbstand))
}
