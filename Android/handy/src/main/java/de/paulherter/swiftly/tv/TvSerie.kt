package de.paulherter.swiftly.tv

import androidx.compose.foundation.background
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
import androidx.compose.ui.focus.focusRequester
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
 * **Der erste Fokus gehoert dem Hauptknopf, nicht einer Folge.**
 */
@Composable
fun TvSerie(app: SwiftlyAnwendung, ziel: Ziel, oeffnen: (Ziel) -> Unit) {
    var s by remember(ziel.id) { mutableStateOf(app.serienSpeicher[ziel.id]) }
    val spielt = app.spiel.value != null
    val lauf = rememberCoroutineScope()
    LaunchedEffect(ziel.id, spielt) {
        if (spielt) return@LaunchedEffect
        try { s = serieLesen(withContext(Dispatchers.IO) { app.kern.serie(ziel.id).await() }).also { app.serienSpeicher[ziel.id] = it } }
        catch (e: CancellationException) { throw e } catch (_: Exception) {}
    }
    val serie = s
    var staffel by remember(ziel.id) { mutableStateOf<String?>(null) }
    LaunchedEffect(serie?.gewaehlt) { if (staffel == null) staffel = serie?.gewaehlt }
    var folgen by remember(ziel.id) { mutableStateOf<List<Folge>>(emptyList()) }
    LaunchedEffect(serie?.id, staffel, spielt) {
        val sid = serie?.id ?: return@LaunchedEffect
        if (spielt || (serie.staffeln.isNotEmpty() && staffel == null)) return@LaunchedEffect
        staffel?.let { app.folgenSpeicher[it] }?.let { folgen = it }
        try {
            folgen = folgenLesen(withContext(Dispatchers.IO) { app.kern.folgen(sid, staffel.orEmpty()).await() })
            staffel?.let { app.folgenSpeicher[it] = folgen }
        } catch (e: CancellationException) { throw e } catch (_: Exception) {}
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
    val name = serie?.name ?: ziel.name

    Box(Modifier.fillMaxSize().background(Stil.grund)) {
        Kulisse(serie?.kopfbild, Modifier.align(Alignment.TopEnd))
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            Column(Modifier.padding(start = TvStil.randSeite, top = 98.dp).height(TvStil.heldenHoehe + 20.dp - 98.dp)) {
                Kopfauskunft(name, serie?.nebenzeile, serie?.beschreibung)
                Row(Modifier.padding(top = 18.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    // Nie gesperrt, solange geladen wird: der Knopf muss ein Fokusziel bleiben.
                    TvKnopf(serie?.knopftext?.ifEmpty { null } ?: uebersetzt("Lädt…"), Icons.Filled.PlayArrow, Modifier.focusRequester(haupt)) {
                        serie?.stand?.let { app.spiel.value = Abspielwunsch(it.id, it.ab) }
                    }
                    serie?.stand?.takeIf { it.fortsetzen }?.let { st -> TvKnopf(null, Icons.Filled.Replay) { app.spiel.value = Abspielwunsch(st.id, null) } }
                    TvKnopf(null, if (serie?.gemerkt == true) Icons.Filled.Bookmark else Icons.Filled.BookmarkBorder) {
                        val alt = serie ?: return@TvKnopf
                        s = alt.copy(gemerkt = !alt.gemerkt)
                        lauf.launch { if (withContext(Dispatchers.IO) { app.kern.merken(alt.id, !alt.gemerkt).await() }.isNotEmpty()) s = alt }
                    }
                    TvKnopf(null, Icons.Filled.MoreHoriz) {
                        val alt = serie ?: return@TvKnopf
                        app.blatt.value = Blattwunsch(name, listOf(
                            Wahl("gesehen", uebersetzt(if (alt.gesehen) "Als ungesehen merken" else "Als gesehen merken")),
                            Wahl("metadaten", uebersetzt("Metadaten neu einlesen"))), null,
                            mapOf("gesehen" to Icons.Filled.CheckCircle, "metadaten" to Icons.Filled.Refresh)) { wahl ->
                            lauf.launch {
                                when (wahl) {
                                    "gesehen" -> if (withContext(Dispatchers.IO) { app.kern.gesehen(alt.id, !alt.gesehen).await() }.isEmpty()) s = alt.copy(gesehen = !alt.gesehen)
                                    "metadaten" -> withContext(Dispatchers.IO) { app.kern.metadatenAuffrischen(alt.id).await() }
                                }
                            }
                        }
                    }
                }
            }

            Column(Modifier.padding(top = TvStil.reihenAbstand - TvStil.reihenLuft)) {
                Row(Modifier.padding(start = TvStil.randSeite), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    Text(uebersetzt("Folgen"), style = TvStil.reihe, color = Stil.schrift)
                    val liste = serie?.staffeln.orEmpty()
                    if (liste.size > 1) {
                        TvKnopf(liste.firstOrNull { it.id == staffel }?.name ?: uebersetzt("Staffel"), Icons.Filled.KeyboardArrowDown, hoehe = 30.dp) {
                            app.blatt.value = Blattwunsch(uebersetzt("Staffel"), liste.map { Wahl(it.id, it.name) }, staffel) { staffel = it }
                        }
                    }
                }
                if (serie != null && folgen.isEmpty()) {
                    Text(uebersetzt("Keine Folgen in dieser Staffel"), style = TvStil.koerper, color = Stil.schriftLeise,
                         modifier = Modifier.padding(start = TvStil.randSeite, top = 16.dp).height(TvStil.querHoehe))
                } else {
                    LazyRow(state = streifen, contentPadding = PaddingValues(start = TvStil.randSeite, end = TvStil.randSeite, top = TvStil.titelAbstand, bottom = TvStil.reihenLuft),
                            horizontalArrangement = Arrangement.spacedBy(TvStil.kachelAbstand)) {
                        items(folgen, key = { it.id }) { f ->
                            TvKachel(f.bild, f.titel, f.unterzeile, quer = true, fortschritt = f.fortschritt) { app.spiel.value = Abspielwunsch(f.id, f.ab) }
                        }
                    }
                }
            }
            val leute = serie?.darsteller.orEmpty()
            if (leute.isNotEmpty()) TvStreifen(uebersetzt("Besetzung")) {
                items(leute, key = { it.id }) { p -> TvBesetzung(p) { oeffnen(Ziel(p.id, p.name, "Person", p.rolle, name)) } }
            }
            if (aehnliche.isNotEmpty()) TvStreifen(uebersetzt("Ähnliches")) {
                items(aehnliche, key = { it.id }) { k -> TvKachel(k.plakat, k.titel, k.unterzeile) { oeffnen(Ziel(k.id, k.titel, k.typ)) } }
            }
            Spacer(Modifier.height(40.dp))
        }
    }
}
