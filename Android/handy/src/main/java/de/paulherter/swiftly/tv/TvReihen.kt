package de.paulherter.swiftly.tv

import de.paulherter.swiftly.gemeinsam.Zeichen
import de.paulherter.swiftly.gemeinsam.Symbol
import de.paulherter.swiftly.gemeinsam.Staerke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import de.paulherter.swiftly.Extra
import de.paulherter.swiftly.Folge
import de.paulherter.swiftly.Mitwirkender
import de.paulherter.swiftly.Rasterkachel
import de.paulherter.swiftly.Ziel
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.uebersetzt

/**
 * Vorlage: `Titelreihen.swift` (`reihenabschnitt`+`streifen`, `Besetzungsstreifen`,
 * `Titelstreifen`, `Folgenstreifen`) — die Startseite, die Titel- und die Serienseite teilen sich
 * diese Reihen. **Oeffentlich, nicht kopiert:** dieselbe Reihe an drei Stellen einzeln nachgebaut
 * lief auf iOS/tvOS schon einmal auseinander (`nachladen()`, in `CLAUDE.md` genannt) — hier soll es
 * gar nicht erst dazu kommen.
 *
 * **Anders als auf tvOS: der Titel steckt in jedem Streifen selbst**, nicht in einem getrennten
 * `reihenabschnitt`. Diese Kotlin-Bausteine (`TvStreifen` in `TvSeiten.kt`, die Reihen der
 * Startseite) machen es schon so — ein zweites, entkoppeltes Muster nur fuer diese Datei haette
 * nichts gewonnen. Einzige Ausnahme ist `TvFolgenstreifen`: die Serienseite braucht dort einen
 * eigenen Kopf mit Staffelpille, wie auf tvOS auch — deshalb bleibt er dort ohne eigenen Titel.
 */

/** Kopf und waagerechter Streifen einer Reihe. */
@Composable
fun TvReihenstreifen(titel: String, modifier: Modifier = Modifier, inhalt: LazyListScope.() -> Unit) {
    Column(modifier.padding(top = TvStil.reihenAbstand - TvStil.reihenLuft)) {
        TvReihentitel(titel)
        LazyRow(contentPadding = PaddingValues(horizontal = TvStil.randSeite, vertical = TvStil.reihenLuft),
                horizontalArrangement = Arrangement.spacedBy(TvStil.kachelAbstand), content = inhalt)
    }
}

/**
 * Vorlage: `Besetzungsstreifen` — die Besetzung, mit Ziel auf die Personenseite. **Jede Kachel
 * fuehrt irgendwohin**, auch wenn sie hier eine Sackgasse waere: tvOS haette sonst einen
 * `focusSection` ohne Ziel, in den der Fokus faellt und dort haengen bleibt.
 */
@Composable
fun TvBesetzungsstreifen(leute: List<Mitwirkender>, herkunft: String? = null,
                         titel: String = uebersetzt("Besetzung"), oeffnen: (Ziel) -> Unit) {
    if (leute.isEmpty()) return
    TvReihenstreifen(titel) {
        items(leute, key = { it.id }) { p ->
            Column(Modifier.width(TvStil.posterBreite), horizontalAlignment = Alignment.CenterHorizontally) {
                Fokusflaeche(tun = { oeffnen(Ziel(p.id, p.name, "Person", p.rolle, herkunft)) }) {
                    Box(Modifier.size(TvStil.posterBreite).clip(CircleShape).background(Stil.flaeche),
                        contentAlignment = Alignment.Center) {
                        Symbol(Zeichen.PersonVoll, 30.dp, farbe = Stil.schriftSehrLeise)
                        AsyncImage(model = p.bild, contentDescription = p.name, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
                    }
                }
                Text(p.name, style = TvStil.kachel, color = Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis,
                     modifier = Modifier.padding(top = 7.dp))
                p.rolle?.let { Text(it, style = TvStil.klein, color = Stil.schriftLeise, maxLines = 1, overflow = TextOverflow.Ellipsis) }
            }
        }
    }
}

/** Vorlage: `Titelstreifen` (ohne `starten`) — Titel zum Weiterspringen, hochkant wie ueberall. */
@Composable
fun TvTitelstreifen(titel: String, items: List<Rasterkachel>, oeffnen: (Ziel) -> Unit) {
    if (items.isEmpty()) return
    TvReihenstreifen(titel) {
        items(items, key = { it.id }) { k ->
            TvKachel(k.plakat, k.titel, k.unterzeile) { oeffnen(Ziel(k.id, k.titel, k.typ)) }
        }
    }
}

/**
 * Vorlage: `Titelstreifen` mit `starten` — Extras laufen sofort, ohne Zwischenseite, deshalb quer
 * wie eine Folge und ohne eigenes Ziel.
 */
@Composable
fun TvExtrastreifen(titel: String = uebersetzt("Extras"), extras: List<Extra>, starten: (Extra) -> Unit) {
    if (extras.isEmpty()) return
    TvReihenstreifen(titel) {
        items(extras, key = { it.id }) { x -> TvKachel(x.bild, x.name, x.laufzeit, quer = true) { starten(x) } }
    }
}

/**
 * Vorlage: `Folgenstreifen` — die Folgen einer Staffel als Querkacheln, vorgescrollt zu der, bei
 * der es weitergeht. **Ohne eigenen Titel**, anders als die drei Streifen oben: die Serienseite
 * setzt den Kopf selbst, mit der Staffelpille daneben — ein Titel hier wuerde ihn verdoppeln.
 */
@Composable
fun TvFolgenstreifen(folgen: List<Folge>, weiterMit: String?, starten: (Folge) -> Unit, modifier: Modifier = Modifier) {
    if (folgen.isEmpty()) return
    val zustand = rememberLazyListState()
    LaunchedEffect(folgen, weiterMit) {
        val i = folgen.indexOfFirst { it.id == weiterMit }
        if (i > 0) zustand.scrollToItem(i)
    }
    LazyRow(modifier, state = zustand,
            contentPadding = PaddingValues(horizontal = TvStil.randSeite, vertical = TvStil.reihenLuft),
            horizontalArrangement = Arrangement.spacedBy(TvStil.kachelAbstand)) {
        items(folgen, key = { it.id }) { f ->
            TvKachel(f.bild, f.titel, f.unterzeile, quer = true, fortschritt = f.fortschritt) { starten(f) }
        }
    }
}
