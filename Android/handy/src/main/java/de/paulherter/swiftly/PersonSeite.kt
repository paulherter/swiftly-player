package de.paulherter.swiftly

import androidx.compose.animation.Crossfade
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import coil3.compose.SubcomposeAsyncImage
import de.paulherter.swiftly.gemeinsam.Bewegung
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.uebersetzt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.future.await
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/** Antwort von `Kern.person` — Querbilder und Titel stehen dort schon fest. */
data class Personenstand(val beschreibung: String?, val geboren: String?, val ort: String?, val bild: String?,
                         val banner: List<String>, val titel: List<Rasterkachel>, val tmdb: Int? = null)

internal fun personLesen(json: String): Personenstand = JSONObject(json).let { o ->
    Personenstand(o.feldText("beschreibung"), o.feldText("geboren"), o.feldText("ort"), o.feldText("bild"),
                  o.feldTexte("banner"), o.feldListe("titel") { rasterkachelLesen(it) },
                  if (o.isNull("tmdb")) null else o.getInt("tmdb"))
}

/** „24. Juni 1962" in der Sprache des Geraets — `Text(datum, format: .date(.long))`. */
private fun langesDatum(iso: String): String? =
    runCatching { LocalDate.parse(iso).format(DateTimeFormatter.ofLocalizedDate(FormatStyle.LONG)) }.getOrNull()

/**
 * Vorlage: `PersonView` in `Sources/Shared/PersonView.swift`, schmale Fassung.
 *
 * **Nichts springt nach.** Bild, Name und Rolle stehen mit dem Tipp da; Geburtstag, Ort,
 * Biografie und Titel blenden zusammen ein, sobald der Server geantwortet hat. Die zwei Zeilen
 * unter dem Namen halten ihren Platz von Anfang an — kamen sie spaeter, schoben sie den Namen hoch.
 * „Kann angefragt werden" steht darunter, sobald Seerr verbunden ist — nie darueber, sonst rutscht es nach.
 */
@Composable
fun PersonSeite(app: SwiftlyAnwendung, ziel: Ziel, oeffnen: (Ziel) -> Unit, zurueck: () -> Unit) {
    var stand by remember(ziel.id) { mutableStateOf(app.personenSpeicher[ziel.id]) }
    LaunchedEffect(ziel.id) {
        try {
            val neu = personLesen(withContext(Dispatchers.IO) { app.kern.person(ziel.id).await() })
            stand = neu
            app.personenSpeicher[ziel.id] = neu
        } catch (e: CancellationException) { throw e } catch (_: Exception) {}
    }
    val s = stand
    // Seerrs Filmografie kommt nach — ohne das, was unter anderem Namen schon auf dem Server liegt.
    var anfragbar by remember(ziel.id) { mutableStateOf<List<Seerrkachel>?>(null) }
    val tmdb = s?.tmdb
    val seerrDa = app.seerrVerbunden.value
    LaunchedEffect(tmdb, seerrDa) {
        if (tmdb == null || !seerrDa) return@LaunchedEffect
        val eigene = s?.titel.orEmpty().mapTo(HashSet()) { it.titel.lowercase() }
        anfragbar = seerrkachelnLesen(withContext(Dispatchers.IO) { app.kern.seerrFilmografie(tmdb.toLong()).await() })
            .filter { it.titel.lowercase() !in eigene }
    }
    val seerrFertig = anfragbar != null || !seerrDa || (s != null && tmdb == null)
    val ein by animateFloatAsState(if (s != null) 1f else 0f, Bewegung.einblenden(), label = "person")

    // Das Banner wechselt weich und langsam zwischen den Querbildern der Titel; eines bleibt stehen.
    val banner = s?.banner.orEmpty()
    var stelle by remember(ziel.id) { mutableIntStateOf(0) }
    LaunchedEffect(banner.size) { if (banner.size > 1) while (true) { delay(6000); stelle++ } }
    var ganzeBiografie by remember { mutableStateOf(false) }

    val scroll = rememberScrollState()
    val dichte = LocalDensity.current.density

    Box(Modifier.fillMaxSize().background(Stil.grund)) {
        Column(Modifier.fillMaxSize().verticalScroll(scroll)) {
            Box(Modifier.fillMaxWidth().height(Stil.heldHoehe)) {
                Crossfade(banner.getOrNull(if (banner.isEmpty()) 0 else stelle % banner.size),
                          animationSpec = tween(1200, easing = EaseInOut), label = "banner") { url ->
                    AsyncImage(model = url, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
                }
                Heldauslauf(Modifier.align(Alignment.BottomStart))
                // **Ein Aufbau, nicht zwei:** ein runder Kopf wie die Besetzungskachel.
                Row(Modifier.align(Alignment.BottomStart).padding(horizontal = Stil.randAbstand).padding(bottom = 16.dp),
                    horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
                    SubcomposeAsyncImage(model = s?.bild, contentDescription = null, contentScale = ContentScale.Crop,
                        modifier = Modifier.size(76.dp).clip(CircleShape).background(Stil.flaeche),
                        error = {
                            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                                Icon(Icons.Filled.Person, contentDescription = null, tint = Stil.schriftSehrLeise, modifier = Modifier.size(30.dp))
                            }
                        })
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(ziel.name, style = Stil.titel.copy(letterSpacing = (-0.6).sp), color = Stil.schrift,
                             maxLines = 2, overflow = TextOverflow.Ellipsis)
                        Column(Modifier.alpha(ein), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                            val zeile = TextStyle(fontSize = 14.sp)
                            Text(s?.geboren?.let(::langesDatum)?.let { uebersetzt("Geboren %@", it) } ?: " ",
                                 style = zeile, color = Stil.schriftLeise, maxLines = 1)
                            Text(s?.ort ?: " ", style = zeile, color = Stil.schriftLeise, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    }
                }
            }

            // Die Rolle kommt mit dem Tipp — sie wartet auf nichts.
            val rolle = ziel.rolle
            val herkunft = ziel.herkunft
            if (!rolle.isNullOrEmpty() && herkunft != null) {
                Text(uebersetzt("%@ in %@", rolle, herkunft),
                     style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.Medium), color = Stil.akzent, maxLines = 2,
                     modifier = Modifier.padding(horizontal = Stil.randAbstand).padding(top = 14.dp))
            }

            // Vier Zeilen, dann „Mehr" — die Biografie soll die Titel nicht wegschieben, bevor man sie will.
            s?.beschreibung?.let { text ->
                Column(Modifier.padding(horizontal = Stil.randAbstand).padding(top = 14.dp).alpha(ein),
                       verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(text, style = Stil.koerper.copy(lineHeight = 21.sp), color = Stil.schriftLeise,
                         maxLines = if (ganzeBiografie) Int.MAX_VALUE else 4, overflow = TextOverflow.Ellipsis,
                         modifier = Modifier.animateContentSize(tween(200, easing = EaseInOut)))
                    Text(uebersetzt(if (ganzeBiografie) "Weniger" else "Mehr"),
                         style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.SemiBold), color = Stil.schrift,
                         modifier = Modifier.antippen { ganzeBiografie = !ganzeBiografie })
                }
            }

            if (s != null) {
                if (s.titel.isNotEmpty()) {
                    Box(Modifier.alpha(ein)) {
                        Abschnitt(uebersetzt("Auf deinem Server"), Stil.kachelAbstand) {
                            items(s.titel) { k -> RasterKachelAnsicht(k, Modifier.width(Stil.kachelBreite)) { oeffnen(Ziel(k.id, k.titel, k.typ)) } }
                        }
                    }
                }
                // Unter dem eigenen Server, damit darueber nichts nachrutscht.
                anfragbar?.takeIf { it.isNotEmpty() }?.let { liste ->
                    Abschnitt(uebersetzt("Kann angefragt werden"), Stil.kachelAbstand) {
                        items(liste) { t ->
                            SeerrkachelAnsicht(t, Modifier.width(Stil.kachelBreite)) {
                                app.seerrTreffer[t.schluessel] = t
                                oeffnen(Ziel(t.schluessel, t.titel, "Seerrtitel"))
                            }
                        }
                    }
                }
                if (s.titel.isEmpty() && anfragbar.isNullOrEmpty() && seerrFertig) {
                    Text(uebersetzt("Auf deinem Server gibt es sonst nichts mit %@.", ziel.name),
                         style = Stil.koerper, color = Stil.schriftLeise,
                         modifier = Modifier.padding(horizontal = Stil.randAbstand).padding(top = 26.dp).alpha(ein))
                }
            }
            Spacer(Modifier.navigationBarsPadding().height(30.dp))
        }

        Detailkopf(ziel.name, { ((scroll.value / dichte - 150f) / 70f).coerceIn(0f, 1f) }, zurueck)
    }
}
