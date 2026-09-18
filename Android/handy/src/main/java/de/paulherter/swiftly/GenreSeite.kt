package de.paulherter.swiftly

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Tag
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
            Box(Modifier.height(34.dp).clip(form).background(Stil.flaeche).border(1.dp, Stil.rand, form)
                    .druckzeile { waehlen(g) }.padding(horizontal = 14.dp),
                contentAlignment = Alignment.Center) {
                Text(g, style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.Medium), color = Stil.schrift)
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
    LaunchedEffect(ziel.id) {
        titel = try {
            JSONArray(withContext(Dispatchers.IO) { app.kern.genre(ziel.id).await() })
                .let { a -> (0 until a.length()).map { rasterkachelLesen(a.getJSONObject(it)) } }
        } catch (e: CancellationException) { throw e } catch (_: Exception) { emptyList() }
    }
    Column(Modifier.fillMaxSize().background(Stil.grund)) {
        Unterseitenkopf(ziel.name, zurueck)
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val anzahl = Stil.spalten((maxWidth - Stil.randAbstand * 2).value)
            LazyVerticalGrid(GridCells.Fixed(anzahl),
                contentPadding = PaddingValues(start = Stil.randAbstand, end = Stil.randAbstand, top = 8.dp, bottom = 12.dp),
                horizontalArrangement = Arrangement.spacedBy(Stil.kachelAbstand),
                verticalArrangement = Arrangement.spacedBy(20.dp),
                modifier = Modifier.fillMaxSize().navigationBarsPadding()) {
                val liste = titel
                if (liste == null) items(anzahl * 3, key = { "platzhalter$it" }) { Kachelplatzhalter() }
                else items(liste, key = { it.id }) { k -> RasterKachelAnsicht(k) { oeffnen(Ziel(k.id, k.titel, k.typ)) } }
            }
            if (titel?.isEmpty() == true) {
                Leerzustand(Icons.Filled.Tag, uebersetzt("Nichts in diesem Genre"),
                            uebersetzt("Auf deinem Server steht gerade kein Film und keine Serie darin."))
            }
        }
    }
}
