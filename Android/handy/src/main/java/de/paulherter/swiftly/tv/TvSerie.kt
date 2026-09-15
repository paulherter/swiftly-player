package de.paulherter.swiftly.tv

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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import de.paulherter.swiftly.*
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.uebersetzt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
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

    suspend fun neuLaden() {
        try { s = serieLesen(withContext(Dispatchers.IO) { app.kern.serie(ziel.id).await() }).also { app.serienSpeicher[ziel.id] = it } }
        catch (e: CancellationException) { throw e } catch (_: Exception) {}
    }
    // **Der Plan kommt nach, wie auf dem Telefon** (`SerienSeite.planLaden`) — `Kern.serie` liefert
    // ihn nicht mit, weil `PlaybackInfo` bei einer frisch vermessenen Datei Sekunden braucht und
    // sonst die ganze Seite darauf wartet. Ohne diesen Nachtrag war die Direct-Play-Marke im Kopf
    // auf dem Fernseher immer aus (`planDa` blieb `false`).
    suspend fun planLaden(folgeId: String) {
        try {
            val o = JSONObject(withContext(Dispatchers.IO) { app.kern.plan(folgeId).await() })
            s?.let { alt ->
                val neu = alt.copy(planDa = o.has("methode"), lossless = o.optBoolean("lossless"), methode = o.feldText("methode"))
                s = neu; app.serienSpeicher[ziel.id] = neu
            }
        } catch (e: CancellationException) { throw e } catch (_: Exception) {}
    }
    LaunchedEffect(ziel.id, spielt) {
        if (!spielt) {
            neuLaden()
            s?.stand?.let { st -> lauf.launch { planLaden(st.id) } }
        }
    }
    val serie = s
    var staffel by remember(ziel.id) { mutableStateOf<String?>(null) }
    LaunchedEffect(serie?.gewaehlt) { if (staffel == null) staffel = serie?.gewaehlt }

    var folgen by remember(ziel.id) { mutableStateOf<List<Folge>>(emptyList()) }
    // Getrennt von der Leere: „Keine Folgen in dieser Staffel" gilt erst, wenn der Server
    // wirklich geantwortet hat — sonst blitzt der Hinweis auf, bevor die erste Antwort da ist
    // (`SerienView.laedtFolgen` auf tvOS).
    var laedtFolgen by remember(ziel.id) { mutableStateOf(true) }
    suspend fun folgenLaden(sid: String, stf: String?) {
        if (folgen.isEmpty()) laedtFolgen = true
        try {
            folgen = folgenLesen(withContext(Dispatchers.IO) { app.kern.folgen(sid, stf.orEmpty()).await() })
            stf?.let { app.folgenSpeicher[it] = folgen }
        } catch (e: CancellationException) { throw e } catch (_: Exception) {}
        finally { laedtFolgen = false }
    }
    LaunchedEffect(serie?.id, staffel, spielt) {
        val sid = serie?.id ?: return@LaunchedEffect
        if (spielt || (serie.staffeln.isNotEmpty() && staffel == null)) return@LaunchedEffect
        staffel?.let { app.folgenSpeicher[it] }?.let { folgen = it }
        folgenLaden(sid, staffel)
    }
    var aehnliche by remember(ziel.id) { mutableStateOf<List<Rasterkachel>>(emptyList()) }
    LaunchedEffect(serie?.id) {
        val sid = serie?.id ?: return@LaunchedEffect
        try { aehnliche = JSONObject(withContext(Dispatchers.IO) { app.kern.titelUmfeld(sid).await() }).feldListe("aehnliche") { rasterkachelLesen(it) } }
        catch (e: CancellationException) { throw e } catch (_: Exception) {}
    }
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
                    TvKnopf(serie?.knopftext?.ifEmpty { null } ?: uebersetzt("Lädt…"), Icons.Filled.PlayArrow, Modifier.focusRequester(haupt)) {
                        val st = serie?.stand
                        if (st != null && serie?.planDa == true) app.spiel.value = Abspielwunsch(st.id, st.ab)
                        else if (st != null) meldung = uebersetzt("Der Server nennt keine Quelle für diese Folge.")
                    }
                    serie?.stand?.takeIf { it.fortsetzen }?.let { st -> TvKnopf(null, Icons.Filled.Replay) {
                        if (serie?.planDa == true) app.spiel.value = Abspielwunsch(st.id, null)
                        else meldung = uebersetzt("Der Server nennt keine Quelle für diese Folge.")
                    } }
                    TvKnopf(null, if (serie?.gemerkt == true) Icons.Filled.Bookmark else Icons.Filled.BookmarkBorder) {
                        val alt = serie ?: return@TvKnopf
                        s = alt.copy(gemerkt = !alt.gemerkt)
                        lauf.launch { if (withContext(Dispatchers.IO) { app.kern.merken(alt.id, !alt.gemerkt).await() }.isNotEmpty()) s = alt }
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
                                add(Wahl("naechste", uebersetzt("Nächste Folge abspielen")))
                            }
                            gewaehlteStaffel?.let { add(Wahl("staffel", uebersetzt("%@ als gesehen", it.name))) }
                            add(Wahl("metadaten", uebersetzt("Metadaten neu einlesen")))
                        }
                        TvMehrknopf(eintraege,
                            mapOf("gesehen" to Icons.Filled.CheckCircle, "vonvorn" to Icons.Filled.Replay,
                                  "naechste" to Icons.Filled.SkipNext, "staffel" to Icons.Filled.CheckCircleOutline,
                                  "metadaten" to Icons.Filled.Refresh)) { wahl ->
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
                                        else meldung = uebersetzt("Der Server nennt keine Quelle für diese Folge.")
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
                                            neuLaden()
                                            serie?.id?.let { sid -> folgenLaden(sid, staffel) }
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
                        TvKnopf(null, Icons.Filled.MoreHoriz) {}
                    }
                }

                Column(Modifier.tvAbschnitt(a, "folgen").padding(top = TvStil.reihenAbstand - TvStil.reihenLuft).tvEingeblendet(einblendAlpha)) {
                    Row(Modifier.padding(start = TvStil.randSeite), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                        Text(uebersetzt("Folgen"), style = TvStil.reihe, color = Stil.schrift)
                        val liste = serie?.staffeln.orEmpty()
                        if (liste.size > 1) {
                            TvKnopf(liste.firstOrNull { it.id == staffel }?.name ?: uebersetzt("Staffel"), Icons.Filled.KeyboardArrowDown, hoehe = 30.dp) {
                                app.blatt.value = Blattwunsch(uebersetzt("Staffel"), liste.map { Wahl(it.id, it.name) }, staffel) { staffel = it }
                            }
                        }
                    }
                    // Ein Stapel wie auf tvOS: laedt / leer / Streifen teilen sich dieselbe Hoehe,
                    // damit die Besetzung darunter beim Staffelwechsel nicht hin- und herspringt.
                    val platzHoehe = TvStil.querHoehe + TvStil.reihenLuft * 2 + 40.dp
                    when {
                        laedtFolgen -> Box(Modifier.padding(start = TvStil.randSeite, top = TvStil.titelAbstand).height(platzHoehe))
                        folgen.isEmpty() -> Text(uebersetzt("Keine Folgen in dieser Staffel"), style = TvStil.koerper, color = Stil.schriftLeise,
                             modifier = Modifier.padding(start = TvStil.randSeite, top = 16.dp).height(platzHoehe))
                        // `TvReihenBringIntoView` ausdruecklich wieder eingesetzt, wie in `TvStreifen`
                        // (`TvTitel.kt`) — dieser Streifen nutzt `TvStreifen` nicht (eigener `state`
                        // fuer die laufende Folge), braucht also seine eigene Wiederherstellung.
                        else -> CompositionLocalProvider(LocalBringIntoViewSpec provides TvReihenBringIntoView) {
                            LazyRow(state = streifen, contentPadding = PaddingValues(start = TvStil.randSeite, end = TvStil.randSeite, top = TvStil.titelAbstand, bottom = TvStil.reihenLuft),
                                    horizontalArrangement = Arrangement.spacedBy(TvStil.kachelAbstand)) {
                                items(folgen, key = { it.id }) { f ->
                                    // **Dasselbe Katalogformat wie tvOS** (`Folgenstreifen.kopfzeile`/
                                    // `dauerzeile`): „F2 · Titel", darunter „24 min" und bei einer gesehenen
                                    // Folge „Gesehen" dahinter. `titel`/`unterzeile` bleiben fuers Telefon
                                    // unveraendert — die rohen Teile kommen eigens aus `Kern.folgen`.
                                    val titel = f.nummer?.let { "F$it · ${f.name}" } ?: f.name
                                    val unterzeile = buildList {
                                        f.laufzeitMin?.let { add(uebersetzt("%lld Min", it)) }
                                        if (f.restzeit != null) add(f.restzeit) else if (f.gesehen) add(uebersetzt("Gesehen"))
                                    }.joinToString(" · ").ifEmpty { null }
                                    TvKachel(f.bild, titel, unterzeile, quer = true, fortschritt = f.fortschritt) { app.spiel.value = Abspielwunsch(f.id, f.ab) }
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
