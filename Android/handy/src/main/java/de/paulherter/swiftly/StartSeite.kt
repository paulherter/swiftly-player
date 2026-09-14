package de.paulherter.swiftly

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
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
    Column(Modifier.fillMaxSize()) {
        Box(Modifier.statusBarsPadding().padding(horizontal = Stil.randAbstand).padding(bottom = 12.dp)) {
            Wortmarke(hoehe = 30.dp)
        }
        fehler?.let { Text(it, color = Stil.warnung, style = Stil.klein, modifier = Modifier.padding(Stil.randAbstand)) }
        LazyColumn(verticalArrangement = Arrangement.spacedBy(Stil.reihenAbstand),
                   contentPadding = PaddingValues(top = 8.dp, bottom = 24.dp)) {
            items(reihen ?: emptyList(), key = { it.titel }) { reihe -> ReiheAnsicht(reihe) }
        }
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
