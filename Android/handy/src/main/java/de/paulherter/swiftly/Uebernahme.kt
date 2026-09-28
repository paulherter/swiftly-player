package de.paulherter.swiftly

import de.paulherter.swiftly.gemeinsam.Zeichen
import de.paulherter.swiftly.gemeinsam.Symbol
import de.paulherter.swiftly.gemeinsam.Staerke
import android.widget.Toast
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.widthIn
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.uebersetzt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray

/** Ein Angebot aus `Kern.uebernahmeAngebote` — die Stelle stammt aus der Abfrage, nicht aus einer spaeteren. */
data class Angebot(val sitzung: String, val itemID: String, val geraet: String?, val art: String,
                   val titelzeile: String, val stelle: Double, val stelleText: String,
                   /** Fuer die Uebergabe-Karte (`Uebergabe.kt`): ihr Bild und die Zeilen darunter. */
                   val bild: String? = null, val name: String = "", val serie: String? = null,
                   val staffelNr: Int? = null, val folgeNr: Int? = null)

/** Vorlage: `Uebernahmemodell.einmalFragen`. Solange hier etwas laeuft, wird nicht gefragt — wer zusieht, fragt nicht. */
suspend fun SwiftlyAnwendung.angeboteHolen() {
    if (spiel.value != null) return
    // Im selben Takt nach Gruppen fragen (`Gemeinsammodell.starten`) — die Lage kommt ueber `gemeinsamZuhoeren`.
    runCatching { withContext(Dispatchers.IO) { kern.syncPlayAngeboteFragen().await() } }
    angebote.value = runCatching {
        JSONArray(withContext(Dispatchers.IO) { kern.uebernahmeAngebote().await() }).let { a ->
            (0 until a.length()).map { a.getJSONObject(it) }.map {
                Angebot(it.getString("id"), it.getString("itemID"), it.feldText("geraet"), it.getString("art"),
                        it.getString("titelzeile"), it.optDouble("stelle", 0.0), it.optString("stelleText"),
                        it.feldText("bild"), it.optString("name"), it.feldText("serie"),
                        if (it.isNull("staffelNr")) null else it.optInt("staffelNr"),
                        if (it.isNull("folgeNr")) null else it.optInt("folgeNr"))
            }
        }
    }.getOrDefault(emptyList())
}

/**
 * Vorlage: `Angebotsabzeichen` in `Sources/iOS/Gemeinsamansichten.swift` (Entwurf A) — **ein Abzeichen
 * fuer alles, was gerade woanders laeuft**, an der Stelle von „Hier weiterschauen" in `Kopfziele`,
 * auf jeder Wurzelseite. Laeuft woanders etwas **und** gibt es eine Gruppe, steht ein Zaehler daran,
 * und ein Tipp oeffnet die Auswahl mit beidem — nicht zwei Zeichen, die Merkliste und Profil verschieben.
 *
 * Nur Uebernahme: wie bisher (ein Geraet uebernimmt sofort, mehrere: erst waehlen). Nur eine Gruppe:
 * das Blatt „Beitreten". **Kuehl, nicht Akzent** gilt fuer die Kopfzeichen; das Abzeichen selbst
 * traegt den Akzent wie auf iOS.
 */
@Composable
fun Uebernahmezeichen(app: SwiftlyAnwendung) {
    val angebote = app.angebote.value
    val gruppen = app.gemeinsam.value.offeneGruppen
    val anzahl = angebote.size + gruppen.size
    val kontext = LocalContext.current
    val lauf = rememberCoroutineScope()
    var uebernimmt by remember { mutableStateOf(false) }
    val mitte = remember { arrayOf(androidx.compose.ui.geometry.Offset.Zero) }
    val dichte = androidx.compose.ui.platform.LocalDensity.current.density
    val ruhig = de.paulherter.swiftly.gemeinsam.bewegungReduziert()
    fun uebernehmen(a: Angebot) {
        if (uebernimmt) return
        uebernimmt = true
        lauf.launch { hierWeiterschauen(app, kontext, a, mitte[0], dichte, ruhig); uebernimmt = false }
    }
    AnimatedVisibility(anzahl > 0,
        enter = fadeIn(tween(220, easing = EaseInOut)) + scaleIn(tween(220, easing = EaseInOut), initialScale = 0.85f),
        exit = fadeOut(tween(220, easing = EaseInOut)) + scaleOut(tween(220, easing = EaseInOut), targetScale = 0.85f)) {
        val erstes = angebote.firstOrNull()
        val beschriftung = when {
            anzahl > 1 -> uebersetzt("Läuft gerade")
            angebote.isEmpty() -> uebersetzt("Gemeinsam schauen")
            else -> uebersetzt("Hier weiterschauen")
        }
        Box(Modifier.size(44.dp).onGloballyPositioned { mitte[0] = it.boundsInRoot().center }.antippen {
                when {
                    // **Die Karte waechst aus dem Abzeichen** (Versuch `experiment-glas`): statt eines Blatts
                    // von unten kommt sie aus dem Zeichen, das man angetippt hat, und schrumpft dorthin zurueck.
                    gruppen.isEmpty() -> if (angebote.size == 1) erstes?.let { uebernehmen(it) }
                        else app.uebernahmeauswahl.value = Uebernahmeauswahl(angebote, mitte[0]) { uebernehmen(it) }
                    angebote.isEmpty() && gruppen.size == 1 -> gemeinsamBeitretenOeffnen(app, gruppen.first())
                    else -> gemeinsamAuswahlOeffnen(app, ::uebernehmen)
                }
            }.semantics { contentDescription = beschriftung; stateDescription = (angebote.map { it.titelzeile } + gruppen.map { it.name }).joinToString(", ") },
            contentAlignment = Alignment.Center) {
            Symbol(erstes?.let { zeichen(it.art) } ?: Zeichen.GruppeVoll, 20.dp, farbe = Stil.akzent)
            if (anzahl > 1) Box(Modifier.align(Alignment.TopEnd).offset(x = (-2).dp, y = 4.dp).defaultMinSize(16.dp, 16.dp)
                    .background(Stil.akzent, CircleShape).padding(horizontal = 4.dp), contentAlignment = Alignment.Center) {
                Text("$anzahl", style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.SemiBold, fontFeatureSettings = "tnum"),
                     color = Stil.aufAkzent)
            }
        }
    }
}

private fun zeichen(art: String): Zeichen = uebernahmesymbol(art)

/**
 * **Drueben beenden, hier an derselben Stelle weitermachen** — Vorlage `hierWeiterschauen` in
 * `Sources/Shared/HauptView.swift` / `Sources/tvOS/HauptView.swift`. Die Karte waechst sofort aus dem
 * Abzeichen (`Uebergabe.empfangen`, Entwurf B) und laeuft neben dem Netz her; der Player geht ohne eigene
 * Blende unter ihr auf und wird sichtbar, wenn sie auf sein erstes Bild gezoomt hat. Telefon und Fernseher.
 * `ursprung`: Mitte des Abzeichens in Wurzelpixeln.
 */
suspend fun hierWeiterschauen(app: SwiftlyAnwendung, kontext: android.content.Context, a: Angebot,
                              ursprung: androidx.compose.ui.geometry.Offset, dichte: Float, ruhig: Boolean) {
    Uebergabe.empfangen(app, a, ursprung, dichte, ruhig)
    val antwort = runCatching {
        org.json.JSONObject(withContext(Dispatchers.IO) { app.kern.uebergeben(a.sitzung, a.itemID, a.stelle, Uebergabe.eigenerName(app)).await() })
    }.getOrNull()
    val grund = antwort?.optString("grund") ?: "nichtVerbunden"
    if (grund.isEmpty()) {
        app.angebote.value = emptyList()
        Uebergabe.vorDemPlayer()
        Uebergabe.spielerKommt(app, a.itemID)
        app.spiel.value = Abspielwunsch(a.itemID, antwort?.optDouble("ab", a.stelle) ?: a.stelle)
    } else {
        Uebergabe.abbrechen(app, "Stopp abgelehnt")
        Toast.makeText(kontext, fehlertext(grund), Toast.LENGTH_LONG).show()
    }
}

/** „Wo weiterschauen?" — die Sitzungen, und wo das Abzeichen steht (Wurzelkoordinaten). */
class Uebernahmeauswahl(val angebote: List<Angebot>, val ursprung: androidx.compose.ui.geometry.Offset, val waehlen: (Angebot) -> Unit)

/**
 * Vorlage: `Uebernahmeauswahl.schleier` + `Uebernahmekarte` mit `.transition(.ausDemPunkt(...))` in
 * `Sources/Shared/Bausteine.swift` / `Sources/iOS/Uebergaenge.swift`. **Der Schleier blendet, die Karte waechst
 * aus dem Abzeichen** (Masstab ab 12 %, Deckung schneller als der Masstab) und schrumpft beim Schliessen
 * dorthin zurueck. Feder `Stil.feder` (0,35/0,9); Bewegung reduzieren: nur Ueberblenden.
 */
@Composable
fun Uebernahmeauflage(app: SwiftlyAnwendung) {
    val offen = app.uebernahmeauswahl.value
    val gemerkt = remember { arrayOfNulls<Uebernahmeauswahl>(1) }
    offen?.let { gemerkt[0] = it }
    val w = gemerkt[0] ?: return
    val ruhig = de.paulherter.swiftly.gemeinsam.bewegungReduziert()
    val auf = remember { androidx.compose.animation.core.Animatable(0f) }
    androidx.compose.runtime.LaunchedEffect(offen != null) {
        auf.animateTo(if (offen != null) 1f else 0f,
            if (ruhig) de.paulherter.swiftly.gemeinsam.Bewegung.blendeReduziert()
            else androidx.compose.animation.core.spring(dampingRatio = 0.9f, stiffness = 322f))
        if (offen == null) gemerkt[0] = null
    }
    if (offen == null && auf.value <= 0.001f) return
    fun zu() { app.uebernahmeauswahl.value = null }
    androidx.activity.compose.BackHandler(enabled = offen != null) { zu() }
    Box(Modifier.fillMaxSize()) {
        // `grund` 62 %, nicht Schwarz — der Schleier ist die Seite, die durchscheint. Faengt den Druck ab.
        Box(Modifier.fillMaxSize().graphicsLayer { alpha = auf.value.coerceIn(0f, 1f) }.background(Stil.grund.copy(alpha = 0.62f)).tippen { zu() })
        val rahmen = remember { arrayOf(androidx.compose.ui.geometry.Rect.Zero) }
        androidx.compose.foundation.layout.Column(Modifier.align(Alignment.Center).padding(horizontal = 24.dp)
                .widthIn(max = 420.dp)
                .onGloballyPositioned { rahmen[0] = it.boundsInRoot() }
                .graphicsLayer {
                    val a = auf.value
                    if (!ruhig && rahmen[0].width > 0) {
                        val r = rahmen[0]
                        transformOrigin = androidx.compose.ui.graphics.TransformOrigin(
                            ((w.ursprung.x - r.left) / r.width).coerceIn(-2f, 3f), ((w.ursprung.y - r.top) / r.height).coerceIn(-2f, 3f))
                        val m = 0.12f + 0.88f * a
                        scaleX = m; scaleY = m
                    }
                    // Die Deckung laeuft schneller als der Masstab: ganz klein ist die Karte fast unsichtbar.
                    alpha = (a * 1.6f).coerceIn(0f, 1f)
                }
                .clip(androidx.compose.foundation.shape.RoundedCornerShape(Stil.eckeFlaeche)).background(Stil.flaeche)) {
            androidx.compose.foundation.layout.Column(Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, top = 20.dp, bottom = 16.dp),
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp)) {
                Text(uebersetzt("Wo weiterschauen?"), style = Stil.listentitel, color = Stil.schrift)
                Text(uebersetzt("Auf dem anderen Gerät hört die Wiedergabe auf. Hier läuft sie an derselben Stelle weiter."),
                     style = Stil.klein.copy(textAlign = androidx.compose.ui.text.style.TextAlign.Center), color = Stil.schriftSehrLeise)
            }
            w.angebote.forEach { a ->
                Blattlinie()
                androidx.compose.foundation.layout.Row(Modifier.fillMaxWidth().defaultMinSize(minHeight = 58.dp)
                        .druckzeile { zu(); w.waehlen(a) }.padding(horizontal = 20.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(14.dp)) {
                    Box(Modifier.size(26.dp), contentAlignment = Alignment.Center) { Symbol(zeichen(a.art), 17.dp, farbe = Stil.akzent, staerke = Staerke.Mittel) }
                    androidx.compose.foundation.layout.Column(Modifier.weight(1f), verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(1.dp)) {
                        Text(a.geraet ?: uebersetzt("Gerät"), style = Stil.listentitel, color = Stil.schrift, maxLines = 1)
                        Text(a.titelzeile, style = Stil.klein, color = Stil.schriftLeise, maxLines = 1,
                             overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
                    }
                    Text(a.stelleText, style = Stil.klein.copy(fontFeatureSettings = "tnum"), color = Stil.schriftSehrLeise)
                }
            }
            Box(Modifier.fillMaxWidth().height(1.dp).background(Stil.rand))
            Box(Modifier.fillMaxWidth().defaultMinSize(minHeight = 58.dp).druckzeile { zu() }, contentAlignment = Alignment.Center) {
                Text(uebersetzt("Abbrechen"), style = Stil.knopftext, color = Stil.schrift)
            }
        }
    }
}
