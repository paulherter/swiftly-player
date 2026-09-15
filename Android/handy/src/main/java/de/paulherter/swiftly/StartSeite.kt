package de.paulherter.swiftly

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.filled.Bookmark
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Movie
import androidx.compose.material.icons.outlined.Tv
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
import org.json.JSONObject

data class Kachel(val id: String, val name: String, val typ: String, val unterzeile: String?,
                  val plakat: String?, val quer: String?, val fortschritt: Double?)
data class Reihe(val titel: String, val quer: Boolean, val kacheln: List<Kachel>)

/** Liest die Antwort von `Kern.startseite` — die Reihen stehen dort schon fertig. */
private fun reihenLesen(json: String): List<Reihe> {
    val reihen = JSONObject(json).getJSONArray("reihen")
    return (0 until reihen.length()).map { i ->
        val r = reihen.getJSONObject(i)
        val titel = if (r.isNull("titelSchluessel")) r.optString("name") else uebersetzt(r.getString("titelSchluessel"))
        val kacheln = r.getJSONArray("kacheln")
        Reihe(titel, r.getBoolean("quer"), (0 until kacheln.length()).map { k ->
            val o = kacheln.getJSONObject(k)
            Kachel(o.getString("id"), o.getString("name"), o.getString("typ"),
                   o.optString("unterzeile").takeIf { !o.isNull("unterzeile") },
                   o.optString("plakat").takeIf { !o.isNull("plakat") },
                   o.optString("quer").takeIf { !o.isNull("quer") },
                   if (o.isNull("fortschritt")) null else o.getDouble("fortschritt"))
        })
    }
}

/** Vorlage: `HomeView` in `Sources/Shared/HomeView.swift` (Kopf, Reihen, Kacheln). */
@Composable
fun StartSeite(app: SwiftlyAnwendung, oeffnen: (Ziel) -> Unit) {
    var reihen by remember { mutableStateOf(app.startReihen) }
    var fehler by remember { mutableStateOf<String?>(null) }
    val e = app.einstellungen
    // Neu laden, sobald sich Reihenfolge, ausgeblendete Reihen oder Genres aendern.
    LaunchedEffect(e.neuzugangGetrennt, e.startReihen, e.startAus, e.startGenres, e.genreChips) {
        try {
            val json = withContext(Dispatchers.IO) {
                app.kern.startseite(e.neuzugangGetrennt, e.startReihen.toTypedArray(), e.startAus.toTypedArray(),
                                    app.ablage.merkwert("bibliothek-movies").orEmpty(), app.ablage.merkwert("bibliothek-tvshows").orEmpty(),
                                    e.startGenres.toTypedArray(), e.genreChips).await()
            }
            reihen = reihenLesen(json).also { app.startReihen = it }
        } catch (e: Throwable) {
            fehler = e.message ?: e.toString()
        }
    }
    val liste = androidx.compose.foundation.lazy.rememberLazyListState()
    val dichte = androidx.compose.ui.platform.LocalDensity.current
    // Wie weit gescrollt ist — fuer Farbschein und Kopfverlauf, wie `versatz` auf dem iPhone.
    val versatz by remember {
        androidx.compose.runtime.derivedStateOf {
            if (liste.firstVisibleItemIndex > 0) 400f
            else liste.firstVisibleItemScrollOffset / dichte.density
        }
    }

    KopfUndInhalt(kopf = { StartKopf(app, oeffnen) }) { kopfDp ->
    Box(Modifier.fillMaxSize()) {
        // Unten: Farbschein, dann die Reihen — sie laufen **unter** dem Kopf durch,
        // statt an seiner Unterkante hart abgeschnitten zu werden.
        Farbschein(versatz, ausgespartOben = kopfDp)
        LazyColumn(state = liste, verticalArrangement = Arrangement.spacedBy(Stil.reihenAbstand),
                   contentPadding = PaddingValues(top = kopfDp + 8.dp, bottom = 24.dp),
                   modifier = Modifier.fillMaxSize().bereichsinhalt()) {
            fehler?.let { item { Text(it, color = Stil.warnung, style = Stil.klein, modifier = Modifier.padding(horizontal = Stil.randAbstand)) } }
            // Platzhalter in der Form der Reihen, dann eine Ueberblendung — kein Ring (`einblenden`).
            if (reihen == null) items(3, key = { "platzhalter$it" }) { i ->
                Reihenplatzhalter(quer = i == 0, Modifier.animateItem(fadeInSpec = null, placementSpec = null, fadeOutSpec = Bewegung.einblenden()))
            }
            // Genres entweder als Chips oder als Reihen, nie beides — die Fassade laesst die Reihen dann weg.
            if (e.genreChips && e.startGenres.isNotEmpty()) item(key = "gattungschips") {
                Gattungschips(e.startGenres) { g -> oeffnen(Ziel(g, g, "Genre")) }
            }
            items(reihen ?: emptyList(), key = { it.titel }) { reihe ->
                ReiheAnsicht(reihe, oeffnen, Modifier.animateItem(fadeInSpec = Bewegung.einblenden(), placementSpec = null, fadeOutSpec = null))
            }
        }
        // Oben: Kopfverlauf (zieht erst beim Scrollen auf), darueber der Farbschein auf
        // Kopfhoehe beschnitten — `Farbschein(fenster: .ueberDemVerlauf)` —, dann der Kopf.
        Box(Modifier.fillMaxWidth().height(kopfDp + 17.dp)
            .graphicsLayer { alpha = (versatz / 40f).coerceIn(0f, 1f) }
            .background(androidx.compose.ui.graphics.Brush.verticalGradient(
                0f to Stil.grund.copy(alpha = 0.98f), 0.30f to Stil.grund.copy(alpha = 0.94f),
                0.48f to Stil.grund.copy(alpha = 0.85f), 0.62f to Stil.grund.copy(alpha = 0.70f),
                0.73f to Stil.grund.copy(alpha = 0.52f), 0.82f to Stil.grund.copy(alpha = 0.34f),
                0.89f to Stil.grund.copy(alpha = 0.19f), 0.95f to Stil.grund.copy(alpha = 0.09f),
                1f to Color.Transparent)))
        Box(Modifier.fillMaxWidth().height(kopfDp).clipToBounds()) { Farbschein(versatz) }
    }
    }
}

/** Vorlage: Kopf in `HomeView` — Wortmarke links, `Kopfziele` rechts (Merkliste, Profil, je 44). */
@Composable
private fun StartKopf(app: SwiftlyAnwendung, oeffnen: (Ziel) -> Unit) {
    Row(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = Stil.randAbstand).padding(bottom = 12.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Wortmarke(hoehe = 30.dp)
        Spacer(Modifier.weight(1f))
        Kopfziele(app, oeffnen)
    }
}

/**
 * Vorlage: `Farbschein` in `HomeView.swift` — zwei weiche Kreise oben, Akzent links
 * (320, 28 %), Kuehl rechts (340, 24 %), 165 hoch nach unten ausgeblendet, wandert beim
 * Scrollen mit. Als radiale Verlaeufe statt `blur(60)`: der Weichzeichner kaeme erst ab Android 12.
 */
@Composable
private fun Farbschein(versatz: Float, ausgespartOben: Dp = 0.dp) {
    val dichte = androidx.compose.ui.platform.LocalDensity.current.density
    // **Die ganze Flaeche wandert, samt Maske** — wie `.offset(y: -versatz)` am
    // Ende von `gemalt` auf iOS. Vorher liefen nur die Kreise unter einer stehenden
    // Maske weg, und der Schein blendete aus, statt nach oben zu rutschen.
    //
    // `ausgespartOben` bleibt dagegen fest am Bildschirm: dort liegt die zweite
    // Kopie ueber dem Kopfverlauf (`hinterDemInhalt` spart auf iOS genau das aus).
    Box(Modifier.fillMaxWidth().height(260.dp).drawWithContent {
        clipRect(top = ausgespartOben.toPx()) { this@drawWithContent.drawContent() }
    }) {
    androidx.compose.foundation.Canvas(
        Modifier.fillMaxWidth().height(260.dp)
            .graphicsLayer { compositingStrategy = androidx.compose.ui.graphics.CompositingStrategy.Offscreen }
    ) {
        // **Verschoben wird die Zeichnung, nicht die Ebene.** Eine verschobene Ebene
        // riss in der auf Kopfhoehe beschnittenen Kopie unten auf — ein leerer
        // Streifen, durch den der dunkle Kopfverlauf als harte Kante zu sehen war.
        val oben = -versatz * dichte
        val mitte = size.width / 2
        fun kreis(farbe: Color, deckung: Float, durchmesser: Float, dx: Float, dy: Float) {
            val radius = (durchmesser / 2 + 60) * dichte
            val zentrum = androidx.compose.ui.geometry.Offset(mitte + dx * dichte, oben + (dy + durchmesser / 2) * dichte)
            drawCircle(
                brush = androidx.compose.ui.graphics.Brush.radialGradient(
                    listOf(farbe.copy(alpha = deckung), farbe.copy(alpha = deckung * 0.55f), Color.Transparent),
                    center = zentrum, radius = radius),
                radius = radius, center = zentrum)
        }
        kreis(Stil.akzent, 0.28f, 320f, -110f, -160f)
        kreis(Stil.kuehl, 0.24f, 340f, 130f, -180f)
        // Nach unten ausblenden, wie die Maske ueber 165 Punkt.
        drawRect(
            brush = androidx.compose.ui.graphics.Brush.verticalGradient(
                0f to Color.White, 0.34f to Color.White.copy(alpha = 0.94f), 0.58f to Color.White.copy(alpha = 0.72f),
                0.80f to Color.White.copy(alpha = 0.34f), 1f to Color.Transparent,
                // Die Maske wandert mit den Kreisen; ueber und unter ihr klemmt der
                // Verlauf auf Weiss bzw. Durchsichtig, also bleibt nichts unmaskiert.
                startY = oben, endY = oben + 205 * dichte),
            blendMode = androidx.compose.ui.graphics.BlendMode.DstIn)
    }
    }
}

@Composable
private fun ReiheAnsicht(reihe: Reihe, oeffnen: (Ziel) -> Unit, modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(11.dp)) {
        Text(reihe.titel, style = Stil.reihe.copy(letterSpacing = (-0.3).sp), color = Stil.schrift,
             modifier = Modifier.padding(horizontal = Stil.randAbstand))
        LazyRow(contentPadding = PaddingValues(horizontal = Stil.randAbstand),
                horizontalArrangement = Arrangement.spacedBy(Stil.kachelAbstand)) {
            items(reihe.kacheln, key = { it.id }) { KachelAnsicht(it, reihe.quer, oeffnen) }
        }
    }
}

/** Vorlage: `Kachel` in `HomeView.swift` — 112×168 hochkant, 236×133 quer, Ecke 10, Balken 4 unten. */
@Composable
private fun KachelAnsicht(k: Kachel, quer: Boolean, oeffnen: (Ziel) -> Unit) {
    val breite: Dp = if (quer) 236.dp else Stil.kachelBreite
    val hoehe: Dp = if (quer) 133.dp else Stil.kachelHoehe
    Column(Modifier.width(breite).einblenden().antippen { oeffnen(Ziel(k.id, k.name, k.typ)) }, verticalArrangement = Arrangement.spacedBy(7.dp)) {
        Box(Modifier.size(breite, hoehe).clip(RoundedCornerShape(Stil.eckeKachel)).background(Stil.flaeche)) {
            val adresse = if (quer) k.quer ?: k.plakat else k.plakat
            SubcomposeAsyncImage(
                model = adresse, contentDescription = k.name, contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
                error = { Ersatz(k) }, loading = { Box(Modifier.fillMaxSize().background(Stil.flaeche)) }
            )
            k.fortschritt?.takeIf { it > 0 && LocalFortschrittZeigen.current }?.let { Fortschrittsbalken(it, Modifier.align(Alignment.BottomStart)) }
        }
        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(k.name, style = Stil.kachel, color = Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis)
            k.unterzeile?.let { Text(it, style = Stil.klein, color = Stil.schriftLeise, maxLines = 1) }
        }
    }
}

@Composable
private fun Ersatz(k: Kachel) {
    Box(Modifier.fillMaxSize().background(Stil.flaeche), contentAlignment = Alignment.Center) {
        Icon(if (k.typ == "Episode" || k.typ == "Series") Icons.Outlined.Tv else Icons.Outlined.Movie,
             contentDescription = null, tint = Stil.schriftSehrLeise, modifier = Modifier.size(22.dp))
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
