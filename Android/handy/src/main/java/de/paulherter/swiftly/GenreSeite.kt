package de.paulherter.swiftly

import androidx.compose.runtime.getValue
import androidx.compose.runtime.derivedStateOf
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import de.paulherter.swiftly.gemeinsam.Zeichen
import de.paulherter.swiftly.gemeinsam.Symbol
import de.paulherter.swiftly.gemeinsam.Staerke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.uebersetzt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.withContext
import org.json.JSONArray

/**
 * Vorlage: `gattungschips` in `HomeView.swift` — eine Reihe Genres ueber den Reihen, wenn
 * „Als Chips" gewaehlt ist. **Ecke wie ein Knopf, nicht rund:** rund ist, was ein Bild ist.
 * Die Namen kommen vom Server und werden nicht uebersetzt.
 */
@Composable
fun Gattungschips(genres: List<String>, waehlen: (String) -> Unit) {
    val form = RoundedCornerShape(Stil.ecke)
    LazyRow(contentPadding = PaddingValues(horizontal = Stil.randAbstand), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        items(genres) { g ->
            // **Kein Rand** (BRAND 4): die Flaeche sagt schon „hier kann man druecken". Und
            // 14 steht in keiner Leiter — ein Chip traegt 13 Medium, wie Wertpille und Wahlchip.
            Box(Modifier.antippen { waehlen(g) }.heightIn(min = 34.dp).clip(form).background(Stil.flaeche)
                    .padding(horizontal = 14.dp),
                contentAlignment = Alignment.Center) {
                Text(g, style = Stil.kachel, color = Stil.schrift)
            }
        }
    }
}

/**
 * Vorlage: `GenreView` in `Sources/Shared/GenreView.swift` — die Titel eines Genres, das
 * neueste zuerst (`JellyfinClient.titel(gattung:)`: wer ein Genre antippt, sucht meist, was neu ist).
 */
@Composable
fun GenreSeite(app: SwiftlyAnwendung, ziel: Ziel, oeffnen: (Ziel) -> Unit, zurueck: () -> Unit) {
    var titel by remember(ziel.id) { mutableStateOf<List<Rasterkachel>?>(null) }
    // **`gestoert` heisst gestoert, leer heisst leer.** Hier stand `catch { emptyList() }` —
    // damit wurde jeder Netzfehler zur Aussage „in diesem Genre gibt es nichts". Derselbe
    // Fehler stand in `GenreView` auf iOS als `?? []` und ist dort am 21.09. behoben.
    var gestoert by remember(ziel.id) { mutableStateOf(false) }
    var versuch by remember(ziel.id) { mutableIntStateOf(0) }
    LaunchedEffect(ziel.id, versuch) {
        gestoert = false
        try {
            titel = JSONArray(withContext(Dispatchers.IO) { app.kern.genre(ziel.id).await() })
                .let { a -> (0 until a.length()).map { rasterkachelLesen(a.getJSONObject(it)) } }
        } catch (e: CancellationException) { throw e } catch (_: Exception) {
            gestoert = true
            titel = emptyList()
        }
    }
    val raster = rememberLazyGridState()
    val dichte = LocalDensity.current
    val versatz by remember {
        derivedStateOf { if (raster.firstVisibleItemIndex > 0) 100f else raster.firstVisibleItemScrollOffset / dichte.density }
    }
    // **Der Kopf haengt im `Unschaerfekopf`**, nicht fest ueber dem Raster: sonst laufen die Plakate
    // an einer harten Kante vorbei. Rechts die Zaehlmarke — „bin ich hier durch?" gilt auch hier.
    KopfUndInhalt(kopf = {
        Wurzelkopf({ versatz }, rand = false) {
            Unterseitenkopf(ziel.name, zurueck, unten = 0.dp, oben = false) {
                titel?.takeIf { it.isNotEmpty() }?.let { Zaehlmarke(it.size) }
            }
        }
    }) { kopfDp ->
        BoxWithConstraints(Modifier.fillMaxSize().background(Stil.grund)) {
            val anzahl = Stil.spalten((maxWidth - Stil.randAbstand * 2).value)
            LazyVerticalGrid(GridCells.Fixed(anzahl), state = raster,
                contentPadding = PaddingValues(start = Stil.randAbstand, end = Stil.randAbstand, top = kopfDp + 8.dp, bottom = 40.dp),
                horizontalArrangement = Arrangement.spacedBy(Stil.kachelAbstand),
                verticalArrangement = Arrangement.spacedBy(20.dp),
                modifier = Modifier.fillMaxSize().navigationBarsPadding()) {
                val liste = titel
                if (liste == null) items(anzahl * 3, key = { "platzhalter$it" }) { Kachelplatzhalter() }
                else items(liste, key = { it.id }) { k -> RasterKachelAnsicht(k) { oeffnen(Ziel(k.id, k.titel, k.typ)) } }
            }
            if (gestoert) {
                Leerzustand(Zeichen.ServerWeg, uebersetzt("Server ist abgetaucht"),
                    uebersetzt("%@ antwortet nicht. Läuft er noch, oder hängt das WLAN?", app.serveradresse()),
                    hauptknopf = uebersetzt("Erneut versuchen") to { versuch++ })
            } else if (titel?.isEmpty() == true) {
                Leerzustand(Zeichen.Etikett, uebersetzt("Nichts in diesem Genre"),
                            uebersetzt("In diesem Genre gibt es auf deinem Server gerade keine Filme und Serien."))
            }
        }
    }
}
