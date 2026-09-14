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
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.SubcomposeAsyncImage
import de.paulherter.swiftly.gemeinsam.Stil
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
fun StartSeite(app: SwiftlyAnwendung) {
    var reihen by remember { mutableStateOf<List<Reihe>?>(null) }
    var fehler by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        try {
            val json = withContext(Dispatchers.IO) {
                app.kern.startseite(true, arrayOf(), arrayOf(), "", "", arrayOf(), false).await()
            }
            reihen = reihenLesen(json)
        } catch (e: Throwable) {
            fehler = e.message ?: e.toString()
        }
    }
    val liste = androidx.compose.foundation.lazy.rememberLazyListState()
    // Wie weit gescrollt ist — nur fuer den Farbschein, wie `versatz` auf dem iPhone.
    val versatz by androidx.compose.runtime.remember {
        androidx.compose.runtime.derivedStateOf {
            if (liste.firstVisibleItemIndex > 0) 400f else liste.firstVisibleItemScrollOffset.toFloat()
        }
    }
    Box(Modifier.fillMaxSize()) {
    Farbschein(versatz)
    Column(Modifier.fillMaxSize()) {
        // Vorlage: Kopf in `HomeView` — Wortmarke links, `Kopfziele` rechts (Merkliste, Profil, je 44).
        Row(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = Stil.randAbstand).padding(bottom = 12.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Wortmarke(hoehe = 30.dp)
            Spacer(Modifier.weight(1f))
            Box(Modifier.size(44.dp), contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.Bookmark, contentDescription = uebersetzt("Merkliste"), tint = Stil.schrift, modifier = Modifier.size(20.dp))
            }
            Box(Modifier.size(44.dp), contentAlignment = Alignment.Center) {
                // Das Bild, sonst der Buchstabe — erst, wenn klar ist, dass keins kommt.
                SubcomposeAsyncImage(
                    model = app.kern.benutzerbild(90), contentDescription = app.benutzername(),
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.size(32.dp).clip(CircleShape),
                    error = {
                        Box(Modifier.fillMaxSize().background(Stil.erhoeht), contentAlignment = Alignment.Center) {
                            Text(app.benutzername().take(1).uppercase(), color = Stil.schrift,
                                 style = Stil.klein.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold))
                        }
                    }
                )
            }
        }
        fehler?.let { Text(it, color = Stil.warnung, style = Stil.klein, modifier = Modifier.padding(Stil.randAbstand)) }
        LazyColumn(state = liste, verticalArrangement = Arrangement.spacedBy(Stil.reihenAbstand),
                   contentPadding = PaddingValues(top = 8.dp, bottom = 24.dp)) {
            items(reihen ?: emptyList(), key = { it.titel }) { reihe -> ReiheAnsicht(reihe) }
        }
    }
    }
}

/**
 * Vorlage: `Farbschein` in `HomeView.swift` — zwei weiche Kreise oben, Akzent links
 * (320, 28 %), Kuehl rechts (340, 24 %), 165 hoch nach unten ausgeblendet, wandert beim
 * Scrollen mit. Als radiale Verlaeufe statt `blur(60)`: der Weichzeichner kaeme erst ab Android 12.
 */
@Composable
private fun Farbschein(versatz: Float) {
    val dichte = androidx.compose.ui.platform.LocalDensity.current.density
    androidx.compose.foundation.Canvas(
        Modifier.fillMaxWidth().height(260.dp)
            .graphicsLayer { compositingStrategy = androidx.compose.ui.graphics.CompositingStrategy.Offscreen }
    ) {
        val oben = -versatz
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
                startY = 0f, endY = 165 * dichte + 40 * dichte),
            blendMode = androidx.compose.ui.graphics.BlendMode.DstIn)
    }
}

@Composable
private fun ReiheAnsicht(reihe: Reihe) {
    Column(verticalArrangement = Arrangement.spacedBy(11.dp)) {
        Text(reihe.titel, style = Stil.reihe.copy(letterSpacing = (-0.3).sp), color = Stil.schrift,
             modifier = Modifier.padding(horizontal = Stil.randAbstand))
        LazyRow(contentPadding = PaddingValues(horizontal = Stil.randAbstand),
                horizontalArrangement = Arrangement.spacedBy(Stil.kachelAbstand)) {
            items(reihe.kacheln, key = { it.id }) { KachelAnsicht(it, reihe.quer) }
        }
    }
}

/** Vorlage: `Kachel` in `HomeView.swift` — 112×168 hochkant, 236×133 quer, Ecke 10, Balken 4 unten. */
@Composable
private fun KachelAnsicht(k: Kachel, quer: Boolean) {
    val breite: Dp = if (quer) 236.dp else Stil.kachelBreite
    val hoehe: Dp = if (quer) 133.dp else Stil.kachelHoehe
    Column(Modifier.width(breite), verticalArrangement = Arrangement.spacedBy(7.dp)) {
        Box(Modifier.size(breite, hoehe).clip(RoundedCornerShape(Stil.eckeKachel)).background(Stil.flaeche)) {
            val adresse = if (quer) k.quer ?: k.plakat else k.plakat
            SubcomposeAsyncImage(
                model = adresse, contentDescription = k.name, contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
                error = { Ersatz(k) }, loading = { Box(Modifier.fillMaxSize().background(Stil.flaeche)) }
            )
            k.fortschritt?.takeIf { it > 0 }?.let { anteil ->
                Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(4.dp).background(Color.White.copy(alpha = 0.25f))) {
                    Box(Modifier.fillMaxHeight().fillMaxWidth(anteil.toFloat().coerceIn(0f, 1f)).background(Stil.akzent))
                }
            }
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
