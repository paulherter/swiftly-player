package de.paulherter.swiftly.tv

import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import de.paulherter.swiftly.*
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.uebersetzt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Vorlage: `Kulisse` und `Kulissenblende` — das Querbild rechts oben, zum Text hin und nach unten
 * in den Grund auslaufend. Startseite, Titel, Serie und Person teilen sich dieselbe.
 */
@Composable
fun Kulisse(bild: String?, modifier: Modifier = Modifier, dauer: Int = 300) {
    Crossfade(bild, animationSpec = tween(dauer), label = "kulisse", modifier = modifier.size(590.dp, 350.dp)) { url ->
        Box(Modifier.fillMaxSize().drawWithContent {
            drawContent()
            drawRect(Brush.horizontalGradient(0f to Stil.grund, 0.45f to Stil.grund.copy(alpha = 0.55f), 1f to Color.Transparent))
            drawRect(Brush.verticalGradient(0.45f to Color.Transparent, 1f to Stil.grund))
        }) {
            AsyncImage(model = url, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        }
    }
}

/**
 * Vorlage: `Kopfauskunft` — **eine Quelle** fuer Startseite und Detailseiten, sonst laufen sie
 * auseinander. Feste Hoehen: wechselt der Fokus, springt darunter nichts.
 */
@Composable
fun Kopfauskunft(titel: String, zweitzeile: String?, text: String?, modifier: Modifier = Modifier) {
    Column(modifier.width(500.dp)) {
        Text(titel, style = TvStil.auskunftTitel, color = Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis,
             modifier = Modifier.height(34.dp))
        Text(zweitzeile.orEmpty(), style = TvStil.koerper, color = Stil.schrift.copy(alpha = 0.68f), maxLines = 1,
             overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 7.dp).height(20.dp))
        text?.let {
            Text(it, style = TvStil.koerper, color = Stil.schriftLeise, maxLines = 3, overflow = TextOverflow.Ellipsis,
                 modifier = Modifier.padding(top = 11.dp))
        }
    }
}

/**
 * Vorlage: `HomeView` auf tvOS — **eine feste Kopfzone, darunter die Reihen.** Die Kopfzone zeigt,
 * was gerade den Fokus hat; das Bild wechselt erst nach 250 ms und blendet 300 ms, der Text sofort.
 * Die Reihen und ihre Reihenfolge kommen aus dem Paket wie auf dem Telefon.
 */
@Composable
fun TvStartSeite(app: SwiftlyAnwendung, oeffnen: (Ziel) -> Unit) {
    val e = app.einstellungen
    var reihen by remember { mutableStateOf(app.startReihen) }
    LaunchedEffect(e.neuzugangGetrennt, e.startReihen, e.startAus, e.startGenres, e.genreChips) {
        runCatching {
            val json = withContext(Dispatchers.IO) {
                app.kern.startseite(e.neuzugangGetrennt, e.startReihen.toTypedArray(), e.startAus.toTypedArray(),
                                    app.ablage.merkwert("bibliothek-movies").orEmpty(), app.ablage.merkwert("bibliothek-tvshows").orEmpty(),
                                    e.startGenres.toTypedArray(), e.genreChips).await()
            }
            reihen = reihenLesen(json).also { app.startReihen = it }
        }
    }
    var aktuell by remember { mutableStateOf<Kachel?>(null) }
    val liste = reihen
    LaunchedEffect(liste) { if (aktuell == null) aktuell = liste?.firstOrNull()?.kacheln?.firstOrNull() }
    var bild by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(aktuell) { delay(250); bild = aktuell?.let { it.quer ?: it.plakat } }
    val lauf = rememberCoroutineScope()
    val erster = remember { FocusRequester() }
    LaunchedEffect(liste != null) { if (liste != null) { delay(60); runCatching { erster.requestFocus() } } }

    Box(Modifier.fillMaxSize()) {
        Kulisse(bild, Modifier.align(Alignment.TopEnd))
        Column(Modifier.fillMaxSize()) {
            Box(Modifier.fillMaxWidth().height(TvStil.heldenHoehe)) {
                aktuell?.let { k ->
                    Kopfauskunft(k.name, k.unterzeile, null, Modifier.padding(start = TvStil.randSeite, top = kopfUnten + 34.dp))
                }
            }
            LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(bottom = 40.dp),
                       verticalArrangement = Arrangement.spacedBy(TvStil.reihenAbstand - TvStil.reihenLuft * 2)) {
                if (e.genreChips && e.startGenres.isNotEmpty()) item(key = "genres") {
                    LazyRow(contentPadding = PaddingValues(horizontal = TvStil.randSeite, vertical = TvStil.reihenLuft),
                            horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        items(e.startGenres) { g -> TvChip(g, false) { oeffnen(Ziel(g, g, "Genre")) } }
                    }
                }
                if (liste == null) item(key = "platzhalter") {
                    Column { TvReihentitel(" ")
                        Row(Modifier.padding(horizontal = TvStil.randSeite, vertical = TvStil.reihenLuft), horizontalArrangement = Arrangement.spacedBy(TvStil.kachelAbstand)) {
                            repeat(7) { Box(Modifier.size(TvStil.posterBreite, TvStil.posterHoehe).background(Stil.flaeche)) }
                        }
                    }
                }
                itemsIndexed(liste.orEmpty(), key = { i, r -> "$i-${r.titel}" }) { i, r ->
                    Column {
                        TvReihentitel(r.titel)
                        LazyRow(contentPadding = PaddingValues(horizontal = TvStil.randSeite, vertical = TvStil.reihenLuft),
                                horizontalArrangement = Arrangement.spacedBy(TvStil.kachelAbstand)) {
                            itemsIndexed(r.kacheln, key = { _, k -> k.id }) { j, k ->
                                TvKachel(if (r.quer) k.quer ?: k.plakat else k.plakat, k.name, k.unterzeile, r.quer,
                                         if (r.quer) k.fortschritt else null,
                                         modifier = if (i == 0 && j == 0) Modifier.focusRequester(erster) else Modifier,
                                         fokusGeaendert = { if (it) aktuell = k }) {
                                    // „Weiterschauen" spielt direkt ab, wie auf tvOS.
                                    if (r.quer) lauf.launch { weiterschauenWunsch(app, k.id)?.let { app.spiel.value = it } ?: oeffnen(Ziel(k.id, k.name, k.typ)) }
                                    else oeffnen(Ziel(k.id, k.name, k.typ))
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
