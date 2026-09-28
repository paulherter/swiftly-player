package de.paulherter.swiftly.tv

import de.paulherter.swiftly.gemeinsam.Zeichen
import de.paulherter.swiftly.gemeinsam.Symbol
import de.paulherter.swiftly.gemeinsam.Staerke
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.LocalBringIntoViewSpec
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.unit.dp
import de.paulherter.swiftly.*
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.uebersetzt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * Vorlage: `SerienView` auf tvOS. **Keine Reiter mehr**: Folgen, Besetzung und Aehnliches stehen
 * untereinander wie die Reihen der Startseite. Die Folgen sind ein waagerechter Streifen mit
 * Querkacheln wie „Weiterschauen"; die Staffel wechselt ueber eine Pille neben dem Reihentitel.
 * **Der erste Fokus gehoert dem Hauptknopf, nicht einer Folge.** Der Kopf ist derselbe wie auf der
 * Filmseite — `TvDetailkopf` in `TvTitel.kt` —, sonst laufen die beiden Seiten wieder auseinander.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun TvSerie(app: SwiftlyAnwendung, ziel: Ziel, oeffnen: (Ziel) -> Unit) {
    var s by remember(ziel.id) { mutableStateOf(app.serienSpeicher[ziel.id]) }
    val spielt = app.spiel.value != null
    val lauf = rememberCoroutineScope()
    var staffel by remember(ziel.id) { mutableStateOf(s?.gewaehlt) }
    /** Von Hand gewaehlt — dann korrigiert kein Neuladen die Staffel mehr (wie `SerienSeite`). */
    var selbstGewaehlt by remember(ziel.id) { mutableStateOf(false) }
    var folgen by remember(ziel.id) { mutableStateOf(staffel?.let { app.folgenSpeicher[it] }.orEmpty()) }
    // Getrennt von der Leere: „Keine Folgen in dieser Staffel" gilt erst, wenn der Server
    // wirklich geantwortet hat — sonst blitzt der Hinweis auf, bevor die erste Antwort da ist
    // (`SerienView.laedtFolgen` auf tvOS). Ohne gemerkte Folgen steht der Platz vom ersten Bild an.
    var laedtFolgen by remember(ziel.id) { mutableStateOf(folgen.isEmpty()) }
    /** Die Serie kam beim ersten Laden nicht (Audit 27.09.) — vorher „Lädt…" ohne Ende. */
    var gestoert by remember(ziel.id) { mutableStateOf(false) }
    var aehnliche by remember(ziel.id) { mutableStateOf<List<Rasterkachel>>(emptyList()) }

    // **Der Plan kommt nach, wie auf dem Telefon** (`SerienSeite.planLaden`) — `Kern.serie` liefert
    // ihn nicht mit, weil `PlaybackInfo` bei einer frisch vermessenen Datei Sekunden braucht und
    // sonst die ganze Seite darauf wartet. Ohne diesen Nachtrag war die Direct-Play-Marke im Kopf
    // auf dem Fernseher immer aus (`planDa` blieb `false`).
    fun planAnnehmen(json: String?) {
        val o = json?.let { runCatching { JSONObject(it) }.getOrNull() } ?: return
        s?.let { alt ->
            val neu = alt.copy(planDa = o.has("methode"), lossless = o.optBoolean("lossless"), methode = o.feldText("methode"))
            s = neu; app.serienSpeicher[ziel.id] = neu
        }
    }
    /** Nur fuer den Staffelwechsel von Hand — das erste Laden holt die Folgen in `laden` mit. */
    suspend fun folgenLaden(sid: String, stf: String) {
        if (folgen.isEmpty()) laedtFolgen = true
        try {
            val neu = folgenLesen(withContext(Dispatchers.IO) { app.kern.folgen(sid, stf).await() })
            app.folgenSpeicher[stf] = neu
            if (staffel == stf) folgen = neu
        } catch (e: CancellationException) { throw e } catch (_: Exception) {}
        finally { laedtFolgen = false }
    }
    /**
     * **Ein Laden, ein Einblenden** — Vorlage `SeriesDetailView.laden` (iOS, fcd0d890) und
     * `SerienSeite.laden` (Telefon, 87c926dc). Serie mit Stand und Staffeln, Aehnliches und die
     * Folgen der gewaehlten Staffel kommen zusammen und im selben Bild auf die Seite. Bis zum
     * 24.09.2026 setzte die Seite jede Antwort einzeln: erst Kopf und Besetzung, dann die Folgen,
     * zuletzt rutschte „Aehnliches" darunter nach. Der Plan laeuft daneben und setzt nur die Marke
     * im Kopf, deren Platz schon steht. Scheitert ein Teil, bleibt dessen alter Stand stehen.
     */
    suspend fun laden() {
        try {
            val (gelesen, umfeld) = coroutineScope {
                val a = async(Dispatchers.IO) { app.kern.serie(ziel.id).await() }
                val b = async(Dispatchers.IO) {
                    try { app.kern.titelUmfeld(ziel.id).await() } catch (e: CancellationException) { throw e } catch (_: Exception) { null }
                }
                serieLesen(a.await()) to b.await()
            }
            val alt = s
            // Den schon bekannten Plan behalten, bis der neue da ist — sonst flackert die Marke.
            val neu = if (alt != null && alt.stand?.id == gelesen.stand?.id)
                gelesen.copy(planDa = alt.planDa, lossless = alt.lossless, methode = alt.methode) else gelesen
            val plan = neu.stand?.let { st ->
                lauf.async(Dispatchers.IO) { try { app.kern.plan(st.id).await() } catch (e: CancellationException) { throw e } catch (_: Exception) { null } }
            }
            val wahl = if (selbstGewaehlt && staffel != null) staffel else neu.gewaehlt
            val geholt = wahl?.let { w ->
                try { folgenLesen(withContext(Dispatchers.IO) { app.kern.folgen(neu.id, w).await() }) }
                catch (e: CancellationException) { throw e } catch (_: Exception) { null }
            }
            val neueAehnliche = umfeld?.let { runCatching { JSONObject(it).feldListe("aehnliche") { k -> rasterkachelLesen(k) } }.getOrNull() }
            // Ab hier ohne Unterbrechung: alles landet im selben Bild.
            s = neu
            app.serienSpeicher[ziel.id] = neu
            neueAehnliche?.let { aehnliche = it }
            // Hat der Nutzer waehrenddessen selbst eine Staffel gewaehlt, gehoert die Liste seiner Wahl.
            if (!selbstGewaehlt || staffel == null || staffel == wahl) {
                staffel = wahl
                if (geholt != null && wahl != null) { app.folgenSpeicher[wahl] = geholt; folgen = geholt }
                laedtFolgen = false
            }
            plan?.let { p -> lauf.launch { planAnnehmen(p.await()) } }
            gestoert = false
        } catch (e: CancellationException) { throw e } catch (_: Exception) {
            if (s != null) laedtFolgen = false
            gestoert = s == null
        }
    }
    // Auch nach der Endmeldung: erst dann kennt der Server die Stelle (`wiedergabeBeendet`).
    LaunchedEffect(ziel.id, spielt, app.wiedergabeBeendet.intValue, app.sehstandGeaendert.intValue) {
        if (!spielt) laden()
    }
    val serie = s
    // Die laufende Folge nach vorn — wer weiterschaut, soll sie nicht suchen.
    val streifen = rememberLazyListState()
    LaunchedEffect(folgen, serie?.stand?.id) {
        val i = folgen.indexOfFirst { it.id == serie?.stand?.id }
        if (i > 0) streifen.scrollToItem(i)
    }
    val haupt = ersterFokus()
    // Wie `TvDetail`: bis `Kern.serie` antwortet, der Kopf aus der Startseite (`TvVorab`).
    val vorab = remember(ziel.id) { TvUebergabe.fuer(ziel.id) }
    val name = serie?.name ?: vorab?.titel ?: ziel.name
    // Kulisse und Grund zeichnet `TvHaupt` (`TvKulissenebene`) — dieselbe Adresse wie auf Start.
    TvKulisseMelden(serie?.let { it.kulisse ?: it.kopfbild }, bereit = serie != null)

    // Vorlage: `SerienView.eingeblendet` auf tvOS — derselbe Griff wie `TvDetail`: Kulisse und
    // Kopfauskunft (Titel/Angaben/Beschreibung) stehen sofort, Knopfreihe und Reihen blenden ein.
    // Warum `rememberTvEinblendung` und nicht `animateFloatAsState`: siehe dort (TvStil.kt).
    val eingeblendet = rememberTvEinblendung(ziel.id)
    val einblendAlpha = { eingeblendet.value }
    // Vorlage: `HauptView.errorMessage`-Band, angebunden wie am Handy (`SerienSeite.meldung`) —
    // Android hat keine geteilte Fehlerquelle wie `AppModel.errorMessage`, deshalb eigener Zustand.
    var meldung by remember { mutableStateOf<String?>(null) }

    Box(Modifier.fillMaxSize()) {
        TvAbschnittsseite { a ->
                TvDetailkopf(name, if (serie != null) serie.jahr.orEmpty() else vorab?.angaben.orEmpty(),
                             if (serie != null) serie.bewertung else vorab?.bewertung,
                             if (serie != null) serie.freigabe else vorab?.freigabe,
                             if (serie != null) serie.beschreibung else vorab?.beschreibung,
                             direktplay = serie?.planDa == true && serie.lossless,
                             hinweis = if (serie?.planDa == true && !serie.lossless) serie.methode else null,
                             knopfAlpha = einblendAlpha, modifier = Modifier.tvAbschnitt(a, "kopf", TvAbschnittsart.Kopf)) {
                    // Nie gesperrt, solange geladen wird: der Knopf muss ein Fokusziel bleiben.
                    // Vorlage: `SerienView.starte` — ohne Plan wird gemeldet statt schweigend nichts zu tun.
                    val menue = de.paulherter.swiftly.LocalKachelmenue.current
                    TvKnopf(serie?.knopftext?.ifEmpty { null } ?: uebersetzt(if (gestoert) "Erneut versuchen" else "Lädt…"), Zeichen.Abspielen, Modifier.focusRequester(haupt),
                            // Langes OK oder die Menue-Taste: das Kachelmenue der Serie, wie an ihrer Kachel.
                            lange = menue?.let { m -> {
                                m(de.paulherter.swiftly.Kachelmenuewunsch(ziel.id, name, "Series", serie?.let { it.kulisse ?: it.kopfbild },
                                    true, serie?.nebenzeile, nachher = { lauf.launch { laden() } }))
                            } }) {
                        if (serie == null && gestoert) { gestoert = false; lauf.launch { laden() }; return@TvKnopf }
                        val st = serie?.stand
                        if (st != null && serie?.planDa == true) app.spiel.value = Abspielwunsch(st.id, st.ab)
                        else if (st != null) meldung = uebersetzt("Der Server hat keine Datei zu dieser Folge.")
                    }
                    serie?.stand?.takeIf { it.fortsetzen }?.let { st -> TvKnopf(null, Zeichen.Zurueckspulen, beschreibung = uebersetzt("Von vorn abspielen")) {
                        if (serie?.planDa == true) app.spiel.value = Abspielwunsch(st.id, null)
                        else meldung = uebersetzt("Der Server hat keine Datei zu dieser Folge.")
                    } }
                    TvKnopf(null, if (serie?.gemerkt == true) Zeichen.LesezeichenVoll else Zeichen.Lesezeichen,
                            beschreibung = uebersetzt("Merkliste"), aktiv = serie?.gemerkt == true) {
                        val alt = serie ?: return@TvKnopf
                        s = alt.copy(gemerkt = !alt.gemerkt)
                        // Wie „Gesehen": zurueckdrehen **und melden**.
                        lauf.launch {
                            val grund = withContext(Dispatchers.IO) { app.kern.merken(alt.id, !alt.gemerkt).await() }
                            if (grund.isNotEmpty()) { s = alt; meldung = fehlertext(grund) }
                        }
                    }
                    // **`TvMehrknopf` statt `app.blatt`** — auf tvOS klappt das Menue direkt unter dem
                    // Knopf auf, nicht als Tafel am rechten Rand (siehe Doc-Kommentar in `TvTitel.kt`).
                    val alt = serie
                    if (alt != null) {
                        val gewaehlteStaffel = alt.staffeln.firstOrNull { it.id == staffel }
                        // `Titelhandlungen.fuerSerie`: „Gesehen" vorn (aus der Knopfreihe heraus,
                        // siehe `gesehenHandlung`), dann Folge/Staffel-Aktionen, zuletzt Metadaten.
                        val eintraege = buildList {
                            add(Wahl("gesehen", uebersetzt(if (alt.gesehen) "Als ungesehen merken" else "Als gesehen merken")))
                            alt.stand?.let {
                                add(Wahl("vonvorn", uebersetzt("Folge von vorn abspielen")))
                                // **„Nächste Folge" weicht für „Gemeinsam schauen"** (Entwurf A, iOS 1.0.5).
                                if (app.gemeinsam.value.darfAnlegen) add(Wahl("gemeinsam", uebersetzt("Gemeinsam schauen")))
                                else add(Wahl("naechste", uebersetzt("Nächste Folge abspielen")))
                            }
                            gewaehlteStaffel?.let { add(Wahl("staffel", uebersetzt("%@ als gesehen", it.name))) }
                            add(Wahl("metadaten", uebersetzt("Metadaten neu einlesen")))
                        }
                        TvMehrknopf(eintraege,
                            mapOf("gesehen" to Zeichen.HakenKreisVoll, "vonvorn" to Zeichen.Zurueckspulen,
                                  "naechste" to Zeichen.Ueberspringen, "staffel" to Zeichen.HakenKreis,
                                  "gemeinsam" to Zeichen.Gruppe, "metadaten" to Zeichen.Neuladen)) { wahl ->
                            if (wahl == "gemeinsam") {
                                alt.stand?.let { st -> tvAnlegenOeffnen(app, st.id,
                                    if (st.staffel != null && st.folge != null) gemeinsamTitelzeile("", alt.name, st.staffel, st.folge) else alt.name) }
                                return@TvMehrknopf
                            }
                            lauf.launch {
                                when (wahl) {
                                    // Vorlage: `gesehenHandlung`/`DetailView.swift:189-194` (VERHALTEN D6) —
                                    // sofort umschalten, bei Fehler zurueckdrehen und melden.
                                    "gesehen" -> {
                                        s = alt.copy(gesehen = !alt.gesehen)
                                        val grund = withContext(Dispatchers.IO) { app.kern.gesehen(alt.id, !alt.gesehen).await() }
                                        if (grund.isNotEmpty()) { s = alt.copy(gesehen = alt.gesehen); meldung = fehlertext(grund) }
                                    }
                                    "vonvorn" -> alt.stand?.let { st ->
                                        if (serie?.planDa == true) app.spiel.value = Abspielwunsch(st.id, null)
                                        else meldung = uebersetzt("Der Server hat keine Datei zu dieser Folge.")
                                    }
                                    // Vorlage: `Titelhandlungen.fuerSerie` — ohne naechste Folge wird gemeldet.
                                    "naechste" -> alt.stand?.let { st ->
                                        val danach = withContext(Dispatchers.IO) { app.kern.folgeDanach(st.id, alt.id).await() }
                                        if (danach.isNotEmpty()) app.spiel.value = Abspielwunsch(danach, null)
                                        else meldung = uebersetzt("Danach kommt nichts mehr.")
                                    }
                                    "staffel" -> gewaehlteStaffel?.let { st ->
                                        val grund = withContext(Dispatchers.IO) { app.kern.gesehen(st.id, true).await() }
                                        if (grund.isNotEmpty()) meldung = fehlertext(grund)
                                        else {
                                            meldung = uebersetzt("%@ ist als gesehen vermerkt.", st.name)
                                            laden()
                                        }
                                    }
                                    "metadaten" -> {
                                        val grund = withContext(Dispatchers.IO) { app.kern.metadatenAuffrischen(alt.id).await() }
                                        meldung = if (grund.isEmpty()) uebersetzt("Der Server liest die Metadaten neu ein.") else fehlertext(grund)
                                    }
                                }
                            }
                        }
                    } else {
                        TvKnopf(null, Zeichen.Mehr, beschreibung = uebersetzt("Mehr")) {}
                    }
                }

                Column(Modifier.tvAbschnitt(a, "folgen").padding(top = TvStil.reihenAbstand - TvStil.reihenLuft).tvEingeblendet(einblendAlpha)) {
                    Row(Modifier.padding(start = TvStil.randSeite), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                        Text(uebersetzt("Folgen"), style = TvStil.reihe, color = Stil.schrift)
                        val liste = serie?.staffeln.orEmpty()
                        if (liste.size > 1) {
                            TvKnopf(liste.firstOrNull { it.id == staffel }?.name ?: uebersetzt("Staffel"), Zeichen.WinkelRunter, hoehe = 30.dp) {
                                app.blatt.value = Blattwunsch(uebersetzt("Staffel"), liste.map { Wahl(it.id, it.name) }, staffel) { w ->
                                    staffel = w; selbstGewaehlt = true
                                    app.folgenSpeicher[w]?.let { folgen = it }
                                    serie?.id?.let { sid -> lauf.launch { folgenLaden(sid, w) } }
                                }
                            }
                        }
                    }
                    // Ein Stapel wie auf tvOS: laedt / leer / Streifen teilen sich dieselbe Hoehe,
                    // damit die Besetzung darunter beim Staffelwechsel nicht hin- und herspringt.
                    val platzHoehe = TvStil.querHoehe + TvStil.reihenLuft * 2 + 40.dp
                    when {
                        gestoert && serie == null -> TvStoerung(app)
                        laedtFolgen -> Box(Modifier.padding(start = TvStil.randSeite, top = TvStil.titelAbstand).height(platzHoehe))
                        folgen.isEmpty() -> Text(uebersetzt("Keine Folgen in dieser Staffel"), style = TvStil.koerper, color = Stil.schriftLeise,
                             modifier = Modifier.padding(start = TvStil.randSeite, top = 16.dp).height(platzHoehe))
                        // Eigenes waagerechtes Bring-into-View (die Seite schaltet das senkrechte ab):
                        // `TvStehendeReihe` — eine ganz sichtbare Folge bewegt die Reihe nicht, sonst
                        // wanderte sie bei jedem Runter aus der Kopfzeile eine Folge weiter.
                        else -> CompositionLocalProvider(LocalBringIntoViewSpec provides TvStehendeReihe) {
                            LazyRow(state = streifen, contentPadding = PaddingValues(start = TvStil.randSeite, end = TvStil.randSeite, top = TvStil.titelAbstand, bottom = TvStil.reihenLuft),
                                    horizontalArrangement = Arrangement.spacedBy(TvStil.kachelAbstand)) {
                                items(folgen, key = { it.id }) { f ->
                                    // Langes OK oder die Menue-Taste: das Kachelmenue, wie an jeder anderen Folge.
                                    val menue = de.paulherter.swiftly.LocalKachelmenue.current
                                    val lange: (() -> Unit)? = menue?.let { m -> {
                                        m(de.paulherter.swiftly.Kachelmenuewunsch(f.id, f.name.ifEmpty { f.titel }, "Episode",
                                            f.bild, true, f.unterzeile,
                                            nachher = { serie?.id?.let { sid -> staffel?.let { st -> lauf.launch { folgenLaden(sid, st) } } } }))
                                    } }
                                    TvFolgenkachel(f, lange = lange) { app.spiel.value = Abspielwunsch(f.id, f.ab) }
                                }
                            }
                        }
                    }
                }
                val leute = serie?.darsteller.orEmpty()
                if (leute.isNotEmpty()) TvStreifen(uebersetzt("Besetzung"), Modifier.tvEingeblendet(einblendAlpha).tvAbschnitt(a, "besetzung")) {
                    items(leute, key = { it.id }) { p -> TvBesetzung(p) { oeffnen(Ziel(p.id, p.name, "Person", p.rolle, name)) } }
                }
                if (aehnliche.isNotEmpty()) TvStreifen(uebersetzt("Ähnliches"), Modifier.tvEingeblendet(einblendAlpha).tvAbschnitt(a, "aehnliche")) {
                    items(aehnliche, key = { it.id }) { k -> TvKachel(k.plakat, k.titel, k.unterzeile) { oeffnen(Ziel(k.id, k.titel, k.typ)) } }
                }
                Spacer(Modifier.height(40.dp))
        }
        meldung?.let { text ->
            TvHinweisstreifen(text, Modifier.align(Alignment.TopCenter).padding(top = 74.dp)) { meldung = null }
        }
    }
}

/**
 * Eine Folge im Streifen — Serienseite und Folgenebene des Players teilen sie (Vorlage
 * `Folgenstreifen` auf tvOS). **Dasselbe Katalogformat wie tvOS** (`kopfzeile`/`dauerzeile`):
 * „F2 · Titel", darunter die Laufzeit und eine Restzeit. **Gesehen steht als Haken im Bild, nicht
 * als Wort** — Bild abgedunkelt, Titel leise; ein voller Balken und ein Haken waeren dieselbe
 * Auskunft zweimal (tvOS 78a81e0). `titel`/`unterzeile` bleiben fuers Telefon unveraendert — die
 * rohen Teile kommen eigens aus `Kern.folgen`.
 */
@Composable
fun TvFolgenkachel(f: Folge, modifier: Modifier = Modifier, lange: (() -> Unit)? = null, tun: () -> Unit) {
    // Übersetzt: Deutsch „F" wie Folge, Englisch „E" wie Episode — stand hier
    // fest als „F", auch auf Englisch (gemeldet 27.09.2026).
    val titel = f.nummer?.let { "${uebersetzt("F%d", it)} · ${f.name}" } ?: f.name
    val unterzeile = buildList {
        f.laufzeitMin?.let { add(uebersetzt("%lld Min", it)) }
        f.restzeit?.let { add(it) }
    }.joinToString(" · ").ifEmpty { null }
    TvKachel(f.bild, titel, unterzeile, quer = true, fortschritt = if (f.gesehen) null else f.fortschritt,
             marke = if (f.gesehen) "gesehen" else null, modifier = modifier, lange = lange,
             abgedunkelt = f.gesehen, titelLeise = f.gesehen, tun = tun)
}
