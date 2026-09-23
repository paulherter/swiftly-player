package de.paulherter.swiftly

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandHorizontally
import androidx.compose.animation.shrinkHorizontally
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.ui.composed
import androidx.compose.ui.graphics.graphicsLayer
import de.paulherter.swiftly.gemeinsam.Bewegung
import de.paulherter.swiftly.gemeinsam.bewegungReduziert
import kotlinx.coroutines.delay
import kotlinx.coroutines.future.await
import android.net.Uri
import de.paulherter.swiftly.gemeinsam.Hauptknopf
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.runtime.getValue
import androidx.compose.runtime.derivedStateOf
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import de.paulherter.swiftly.gemeinsam.Zeichen
import de.paulherter.swiftly.gemeinsam.Symbol
import de.paulherter.swiftly.gemeinsam.Staerke
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.uebersetzt
import de.paulherter.swiftly.kern.Kern
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

private fun groesse(bytes: Long) = Kern.downloadGroesse(bytes)

/**
 * Vorlage: `Downloadring` in `Sources/Shared/DownloadsView.swift` — **ein Zeichen fuer alle Staende.**
 * Laedt: ein Bogen mit Quadrat — Quadrat heisst Halt, kein Kreuz, weggeworfen wird hier nichts.
 * Fertig: gefuellter Kreis mit **Pfeil, nicht Haken** — der Haken gehoert „gesehen".
 */
@Composable
fun Downloadring(p: Downloadposten?, mass: Dp = 28.dp,
                 /** Der geschaetzte Stand zwischen zwei Meldungen — derselbe Wert wie Zahl und Balken daneben. */
                 anteilJetzt: Double? = null) {
    val roh = if (p?.stand == "laedt") anteilJetzt ?: p.anteil else p?.anteil
    val anteil by animateFloatAsState((roh ?: 0.0).toFloat().coerceAtLeast(0.02f), tween(400, easing = LinearEasing), label = "ring")
    Box(Modifier.size(mass), contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            val duenn = 1.5.dp.toPx()
            val dick = 2.dp.toPx()
            val r = size.minDimension / 2
            when (p?.stand) {
                null -> drawCircle(Stil.schriftLeise, r - duenn / 2, style = Stroke(duenn))
                "wartet" -> drawCircle(Stil.schriftSehrLeise, r - dick / 2,
                    style = Stroke(dick, pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 4.dp.toPx()))))
                "laedt", "angehalten" -> {
                    // Dieselbe Spur wie der `Fortschrittsbalken`: weiss 30 % — die Laenge des Ganzen.
                    drawCircle(Color.White.copy(alpha = 0.30f), r - dick / 2, style = Stroke(dick))
                    drawArc(if (p.stand == "laedt") Stil.akzent else Stil.schriftLeise, -90f, 360f * anteil, false,
                            topLeft = Offset(dick / 2, dick / 2), size = Size(size.width - dick, size.height - dick),
                            style = Stroke(dick, cap = StrokeCap.Round))
                    if (p.stand == "laedt") {
                        val k = size.minDimension * 0.32f
                        // Das Quadrat ist Halt, nicht Abbruch — im Akzent wie der Bogen.
                        drawRoundRect(Stil.akzent, Offset((size.width - k) / 2, (size.height - k) / 2), Size(k, k), CornerRadius(1.5.dp.toPx()))
                    }
                }
                "fertig" -> drawCircle(Stil.akzent, r)
                // `fehler`, nicht `warnung`: ein abgebrochener Download ist schiefgegangen.
                "fehler" -> drawCircle(Stil.fehler, r - dick / 2, style = Stroke(dick))
            }
        }
        when (p?.stand) {
            // `bild(...)` am iPhone: Semibold, Pfeil und Ausrufezeichen 13, Pause und Play 11.
            null -> Symbol(Zeichen.PfeilRunter, 13.dp, farbe = Stil.schrift, staerke = Staerke.Halbfett, beschreibung = uebersetzt("Laden"))
            "wartet" -> Symbol(Zeichen.Pause, 11.dp, farbe = Stil.schriftSehrLeise, staerke = Staerke.Halbfett, beschreibung = uebersetzt("Wartet"))
            "laedt" -> Box(Modifier.semantics { contentDescription = uebersetzt("Lädt, anhalten") })
            "angehalten" -> Symbol(Zeichen.Abspielen, 11.dp, farbe = Stil.schrift, staerke = Staerke.Halbfett, beschreibung = uebersetzt("Angehalten, fortsetzen"))
            "fertig" -> Symbol(Zeichen.PfeilRunter, 13.dp, farbe = Stil.grund, staerke = Staerke.Halbfett, beschreibung = uebersetzt("Geladen, entfernen"))
            "fehler" -> Symbol(Zeichen.Ausrufezeichen, 13.dp, farbe = Stil.fehler, staerke = Staerke.Halbfett, beschreibung = uebersetzt("Fehlgeschlagen, erneut versuchen"))
        }
    }
}

/** Der Ring mit 44 Trefferflaeche — kleiner ist nicht tippbar. */
@Composable
private fun Ringknopf(app: SwiftlyAnwendung, p: Downloadposten?, mass: Dp = 28.dp, anteilJetzt: Double? = null, anlegen: () -> Unit = {}) {
    Box(Modifier.size(44.dp).antippen { app.downloads.ringTippen(p, anlegen) }, contentAlignment = Alignment.Center) {
        Downloadring(p, mass, anteilJetzt)
    }
}

/**
 * Vorlage: `Downloadfeld` — das fuenfte Feld der Aktionsreihe, **neben der Merkliste**: beide sind
 * das Paar „fuer spaeter". Wer Downloads nie einschaltet, sieht die Reihe mit vier Feldern.
 */
@Composable
internal fun RowScope.Downloadfeld(app: SwiftlyAnwendung, id: String, titel: String) {
    val p = app.downloads.posten(id)
    // 48 × 48 wie jedes andere Feld der Aktionsreihe (BRAND 7) — es stand als einziges auf 44.
    // **Die Ladeauswahl dahinter bleibt unangetastet**, hier geht es nur um das Feld.
    Box(Modifier.weight(1f).height(Stil.knopfHoehe).clip(RoundedCornerShape(Stil.ecke)).background(Stil.flaeche)
            .antippen { app.downloads.ringTippen(p) { app.downloadsAnlegen(listOf(id), titel) } },
        contentAlignment = Alignment.Center) {
        // Ohne Download ein blanker Pfeil, geladen der gefuellte Kreis — beide 17 Semibold wie der
        // Nachbar; nur waehrend es laeuft, wartet oder haengt, steht der Ring (22) im Feld.
        when (p?.stand) {
            null -> Symbol(Zeichen.PfeilRunter, 17.dp, farbe = Stil.schrift, staerke = Staerke.Halbfett, beschreibung = uebersetzt("Laden"))
            "fertig" -> Symbol(Zeichen.LadenKreisVoll, 17.dp, farbe = Stil.akzent, staerke = Staerke.Halbfett, beschreibung = uebersetzt("Geladen, entfernen"))
            else -> Downloadring(p, 22.dp)
        }
    }
}

/**
 * Vorlage: `Ladeblatt` — **vor jedem Start**, und nie eine Qualitaetswahl: geladen wird die
 * Originaldatei. Welcher der drei Aufbauten gilt, entscheiden `Downloadregeln.platz` und
 * `darfLaden`, nicht das Blatt.
 */
fun ladeblattZeigen(app: SwiftlyAnwendung, neue: List<Downloadposten>, bilder: Map<String, String>, titel: String) {
    val v = app.downloads
    val bytes = neue.sumOf { it.bytes }
    val frei = v.frei()
    val platz = JSONObject(Kern.downloadPlatz(bytes, frei, Downloadposten.liste(v.posten.value)))
    val kopf = if (platz.getBoolean("reicht")) uebersetzt("%@ laden", titel) else uebersetzt("Nicht genug Platz")
    app.blatt.value = Blattwunsch(kopf, emptyList(), null, inhalt = { schliessen ->
        Ladeinhalt(app, neue, bilder, bytes, frei, platz, schliessen)
    }) {}
}

@Composable
private fun Ladeinhalt(app: SwiftlyAnwendung, neue: List<Downloadposten>, bilder: Map<String, String>,
                       bytes: Long, frei: Long, platz: JSONObject, schliessen: () -> Unit) {
    val v = app.downloads
    val laden = { v.hinzufuegen(neue, bilder) }
    Column(Modifier.padding(horizontal = Stil.randAbstand).padding(top = 4.dp, bottom = 16.dp)) {
        when {
            !platz.getBoolean("reicht") -> {
                Blattzeile(uebersetzt("Diese Datei"), groesse(bytes))
                Blattzeile(uebersetzt("Frei auf dem Gerät"), groesse(frei), warnend = true)
                if (platz.getBoolean("reichtNachAufraeumen")) {
                    Blattzeile(uebersetzt("Gesehene Titel"), groesse(platz.getLong("entbehrlichBytes")))
                    Knopfreihe {
                        Spielknopf(Zeichen.Papierkorb, uebersetzt("Gesehene entfernen und laden"), true, haupt = true) {
                            schliessen()
                            val weg = platz.getJSONArray("entbehrlich").let { a -> (0 until a.length()).map { a.getString(it) } }
                            v.entfernen(weg)
                            laden()
                        }
                        Spielknopf(Zeichen.Kreuz, uebersetzt("Abbrechen"), true, haupt = false, tun = schliessen)
                    }
                } else {
                    Blatthinweis(uebersetzt("Auch nach dem Entfernen der gesehenen Titel reicht der Platz nicht. In den Einstellungen unter Offline steht, was belegt ist."))
                    Knopfreihe { Spielknopf(Zeichen.Haken, uebersetzt("Verstanden"), true, haupt = false, tun = schliessen) }
                }
            }
            !v.darfLaden() -> {
                Blattzeile(uebersetzt("Größe"), groesse(bytes))
                Blattzeile(uebersetzt("Kein WLAN"), uebersetzt("Mobilfunk"), warnend = true)
                Knopfreihe {
                    Spielknopf(Zeichen.Uhr, uebersetzt("In die Warteschlange"), true, haupt = true) { schliessen(); laden() }
                    Spielknopf(Zeichen.Balkenempfang, uebersetzt("Jetzt über Mobilfunk laden"), true, haupt = false) {
                        schliessen(); app.einstellungen.nurUeberWLAN = false; laden()
                    }
                }
                Blatthinweis(uebersetzt("Der Download startet von selbst, sobald WLAN da ist."))
            }
            else -> {
                Blattzeile(uebersetzt("Größe"), groesse(bytes))
                neue.singleOrNull()?.container?.let { Blattzeile(uebersetzt("Qualität"), it.uppercase()) }
                Blattzeile(uebersetzt("Danach frei"), groesse(platz.getLong("freiDanach")))
                Knopfreihe { Spielknopf(Zeichen.PfeilRunter, uebersetzt("Laden"), true, haupt = true) { schliessen(); laden() } }
                Blatthinweis(uebersetzt("Swiftly lädt die Originaldatei, in derselben Qualität wie beim Streamen."))
            }
        }
    }
}

@Composable
private fun Blattzeile(titel: String, wert: String, warnend: Boolean = false) {
    Row(Modifier.fillMaxWidth().height(44.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(titel, style = TextStyle(fontSize = 15.sp), color = Stil.schriftLeise, modifier = Modifier.weight(1f))
        Text(wert, style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.Medium, fontFeatureSettings = "tnum"),
             color = if (warnend) Stil.warnung else Stil.schrift)
    }
    Box(Modifier.fillMaxWidth().height(1.dp).background(Stil.linie))
}

@Composable
private fun Knopfreihe(inhalt: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.padding(top = 18.dp), verticalArrangement = Arrangement.spacedBy(10.dp), content = inhalt)
}

@Composable
private fun Blatthinweis(text: String) {
    Text(text, style = TextStyle(fontSize = 13.sp, lineHeight = 18.sp), color = Stil.schriftSehrLeise, modifier = Modifier.padding(top = 12.dp))
}

private data class Downloadgruppe(val id: String, val titel: String, val bytes: Long, val serienId: String?, val folgen: List<String>)

private fun gruppenLesen(json: String): List<Downloadgruppe> = JSONArray(json).let { a ->
    (0 until a.length()).map { i ->
        val o = a.getJSONObject(i)
        Downloadgruppe(o.getString("id"), o.getString("titel"), o.optLong("bytes"), o.feldText("serienId"),
                       o.getJSONArray("folgen").let { f -> (0 until f.length()).map { f.getString(it) } })
    }
}

/** Wie `Downloadzeile.unterzeile`: Folge oder Laufzeit, dann der Stand. Laedt und Fehler ersetzen alles. */
private fun unterzeile(p: Downloadposten, geladen: Long = p.geladen): String {
    val teile = mutableListOf<String>()
    if (p.staffel != null && p.folge != null) teile += "S${p.staffel} F${p.folge}"
    else p.laufzeitTicks?.takeIf { it > 0 }?.let { teile += uebersetzt("%lld Min.", (it / 600_000_000L).toInt()) }
    when (p.stand) {
        // **Feste Einheit, feste Stellen** (`Downloadregeln.fortschritt`): `groesse` wechselte mitten im
        // Laden von „845 MB" auf „1 GB" und „1,01 GB", und die Zeile wurde bei jedem Schritt anders breit.
        "laedt" -> return JSONArray(Kern.downloadFortschritt(geladen, p.bytes)).let { f ->
            uebersetzt("%@ von %@", f.getString(0), f.getString(1))
        }
        "wartet" -> teile += uebersetzt("wartet")
        "angehalten" -> teile += uebersetzt("angehalten")
        "fehler" -> return p.grund ?: uebersetzt("Fehlgeschlagen")
        else -> {
            teile += groesse(p.bytes)
            p.container?.let { teile += it.uppercase() }
            // H9: leise, keine Fehlerfarbe — die Datei laeuft ja.
            if (!p.nochAufDemServer) teile += uebersetzt("nicht mehr auf dem Server")
        }
    }
    return teile.joinToString(" · ")
}


/**
 * Vorlage: `DownloadsView`. Oben, was noch laeuft; darunter, was auf dem Geraet liegt — **eine Serie
 * ist eine Zeile** (H12). Entfernt wird ueber „Bearbeiten", nicht per Wischen: auch Laufendes ist
 * waehlbar, und eine Serie als Ganzes. Der Speicherbalken hat bewusst keine feste Obergrenze (H7).
 */
@Composable
fun DownloadsSeite(app: SwiftlyAnwendung, oeffnen: (Ziel) -> Unit) {
    val v = app.downloads
    val alle = v.posten.value
    val laufend = alle.filter { it.stand != "fertig" }.sortedBy { it.angelegt }
    val fertige = alle.filter { it.stand == "fertig" }
    val gruppen = remember(fertige) { gruppenLesen(Kern.downloadGruppen(Downloadposten.liste(fertige))) }
    var bearbeiten by remember { mutableStateOf(false) }
    var gewaehlt by remember { mutableStateOf(emptySet<String>()) }
    LaunchedEffect(alle.isEmpty()) { if (alle.isEmpty()) { bearbeiten = false; gewaehlt = emptySet() } }
    val netz = v.netz.value
    fun umschalten(ids: List<String>) { gewaehlt = if (ids.all { it in gewaehlt }) gewaehlt - ids.toSet() else gewaehlt + ids }

    val liste = rememberLazyListState()
    val dichte = LocalDensity.current
    val versatz by remember {
        derivedStateOf { if (liste.firstVisibleItemIndex > 0) 100f else liste.firstVisibleItemScrollOffset / dichte.density }
    }

    Box(Modifier.fillMaxSize().background(Stil.grund)) {
    KopfUndInhalt(kopf = {
        Wurzelkopf({ versatz }) {
            // Mittig, nicht oben: ohne Zeile unter dem Titel liegt oben daneben. **Keine Belegung
            // unter dem Titel** — dieselbe Auskunft steht am Speicherbalken, und ein Seitentitel mit
            // Unterbau saehe anders aus als jede andere Wurzelseite.
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(uebersetzt("Downloads"), style = Stil.titelGross, color = Stil.schrift, modifier = Modifier.weight(1f))
                Kopfziele(app, oeffnen) {
                    if (alle.isNotEmpty()) Bearbeitenknopf(bearbeiten) { bearbeiten = it; if (!it) gewaehlt = emptySet() }
                }
            }
            if (alle.isNotEmpty()) Box(Modifier.padding(top = 12.dp)) { Speicherbalken(alle.sumOf { it.bytes }, remember(alle) { v.frei() }) }
        }
    }) { kopfDp ->
        LazyColumn(Modifier.fillMaxSize().bereichsinhalt(), state = liste,
                   contentPadding = PaddingValues(top = kopfDp, bottom = if (bearbeiten) 84.dp else 24.dp)) {
            if (laufend.isNotEmpty()) {
                item(key = "kopf-laufend") {
                    Gruppentitel(uebersetzt(if (netz) "Lädt gerade" else "Wartet auf Netz"), Modifier.padding(top = 4.dp))
                }
                items(laufend, key = { "l-" + it.id }) { p ->
                    Downloadzeile(app, p, v.bildDatei(p.id), p.art == "folge", bearbeiten, p.id in gewaehlt,
                        tun = if (bearbeiten) { { umschalten(listOf(p.id)) } } else null,
                        modifier = Modifier.animateItem())
                }
            }
            if (gruppen.isNotEmpty()) {
                // **Keine Ueberschrift ueber dem Geladenen.** Hier stand „Auf dem Gerät" — auf der
                // Downloadseite ist alles auf dem Geraet, der Satz sagte nichts. Der Abstand zu
                // „Lädt gerade" darueber bleibt.
                item(key = "abstand-geraet") { Spacer(Modifier.height(if (laufend.isEmpty()) 4.dp else 26.dp)) }
                items(gruppen, key = { "g-" + it.id }) { g ->
                    val sid = g.serienId
                    val erste = alle.firstOrNull { it.id == g.folgen.firstOrNull() }
                    if (sid != null && erste != null) {
                        // **Eine Zeile in beiden Lagen, kein Tausch** — so gleitet sie mit den anderen.
                        Downloadzeile(app, erste, v.bildDatei(sid), false, bearbeiten, g.folgen.all { it in gewaehlt },
                            tun = { if (bearbeiten) umschalten(g.folgen) else oeffnen(Ziel(sid, g.titel, "Downloadserie")) },
                            gruppe = g.titel to (uebersetzt("%lld Folgen", g.folgen.size) + " · " + groesse(g.bytes)),
                            modifier = Modifier.animateItem())
                    } else if (erste != null) {
                        Downloadzeile(app, erste, v.bildDatei(erste.id), erste.art == "folge", bearbeiten, erste.id in gewaehlt,
                            tun = { if (bearbeiten) umschalten(listOf(erste.id)) else app.spiel.value = Abspielwunsch(erste.id, null) },
                            modifier = Modifier.animateItem())
                    }
                }
            }
        }
    }
    if (alle.isEmpty()) {
        Leerzustand(Zeichen.LadenKreis, uebersetzt("Noch nichts geladen"),
            uebersetzt("Lad was runter, bevor der Zug ins Funkloch fährt."))
    }
    if (bearbeiten) {
        Loeschleiste(app, gewaehlt, Modifier.align(Alignment.BottomCenter)) {
            v.entfernen(gewaehlt)
            gewaehlt = emptySet()
            bearbeiten = false
        }
    }
    }
}

/**
 * Vorlage: `Bearbeitenknopf` — Stift und Kreuz oben rechts, auf der Downloadliste und auf der Seite
 * einer geladenen Serie derselbe Knopf. 17 Semibold, im Bearbeiten das Kreuz im Akzent.
 */
@Composable
internal fun Bearbeitenknopf(bearbeiten: Boolean, setzen: (Boolean) -> Unit) {
    Box(Modifier.size(44.dp).antippen { setzen(!bearbeiten) }, contentAlignment = Alignment.Center) {
        Symbol(if (bearbeiten) Zeichen.Kreuz else Zeichen.Stift, 17.dp,
               farbe = if (bearbeiten) Stil.akzent else Stil.schrift, staerke = Staerke.Halbfett,
               beschreibung = uebersetzt("Bearbeiten"))
    }
}

/**
 * Vorlage: `Loeschleiste` — der Hauptknopf ueber die volle Breite, gesperrt, solange nichts gewaehlt
 * ist; davor das Blatt mit „Entfernen". „3 entfernen · 7,42 GB".
 */
@Composable
internal fun Loeschleiste(app: SwiftlyAnwendung, gewaehlt: Set<String>, modifier: Modifier, entfernen: () -> Unit) {
    val bytes = app.downloads.posten.value.filter { it.id in gewaehlt }.sumOf { it.bytes }
    val titel = uebersetzt("%lld entfernen", gewaehlt.size) + " · " + groesse(bytes)
    Box(modifier.fillMaxWidth().background(Stil.grund)
            .padding(horizontal = Stil.randAbstand).padding(top = 8.dp, bottom = 8.dp)) {
        Hauptknopf(titel, freigegeben = gewaehlt.isNotEmpty()) {
            app.blatt.value = Blattwunsch(titel, listOf(Wahl("weg", uebersetzt("Entfernen"))), null,
                                          mapOf("weg" to Zeichen.Papierkorb), warnend = setOf("weg")) { entfernen() }
        }
    }
}

/**
 * Vorlage: `speicherbalken` — **statt einer Obergrenze** (H7): unser Anteil im Akzent, der freie
 * Platz in `erhoeht`, zusammen die ganze Kapsel. 6 hoch.
 */
@Composable
private fun Speicherbalken(belegt: Long, frei: Long) {
    val ganz = (belegt + frei.coerceAtLeast(0)).coerceAtLeast(1).toFloat()
    val eigen = (belegt / ganz).coerceIn(0f, 1f)
    Row(Modifier.fillMaxWidth().height(6.dp).clip(CircleShape).clearAndSetSemantics {}) {
        if (eigen > 0f) Box(Modifier.weight(eigen).fillMaxHeight().background(Stil.akzent))
        if (eigen < 1f) Box(Modifier.weight(1f - eigen).fillMaxHeight().background(Stil.erhoeht))
    }
}

/** Wie `Downloadzeile.unterfarbe`: laedt im Akzent, Fehler in `fehler`, sonst sehr leise. */
private fun unterfarbe(p: Downloadposten) = when (p.stand) {
    "laedt" -> Stil.akzent
    "fehler" -> Stil.fehler
    else -> Stil.schriftSehrLeise
}

/**
 * Vorlage: `Downloadzeile` — Standbild 116 × 65 (quer) oder Plakat 64 × 96, 12 Abstand, Titel 15
 * Semibold **einzeilig**, Unterzeile 12 mit tabellarischen Ziffern in der Farbe des Stands, darunter
 * der geteilte `Fortschrittsbalken` als Kapsel. Senkrecht 10.
 *
 * **Waehrend geladen wird, zaehlt die Zeile je Bild weiter** (30 je Sekunde). Die Verwaltung meldet
 * hoechstens einmal je Sekunde; dazwischen rechnet der `Fortschrittsschaetzer` im Kern weiter. Zahl,
 * Balken und Ring lesen **denselben** Wert. Geschaetzt wird nur, solange wirklich Byte kommen:
 * angehalten, wartend, fehlgeschlagen oder ohne Netz steht die Zahl sofort.
 *
 * **Im Bearbeiten kommt der Kreis von links herein und schiebt die Zeile vor sich her**, in der
 * Blattkurve und fuer alle Zeilen zugleich; bei reduzierter Bewegung bleibt es eine Blende.
 */
@Composable
private fun Downloadzeile(app: SwiftlyAnwendung, p: Downloadposten, bild: File, quer: Boolean,
                          bearbeiten: Boolean, gewaehlt: Boolean, tun: (() -> Unit)?, lange: (() -> Unit)? = null,
                          /** Titel und Unterzeile, wenn die Zeile fuer eine ganze Serie steht (H12). */
                          gruppe: Pair<String, String>? = null, modifier: Modifier = Modifier) {
    val kommtWas = gruppe == null && p.stand == "laedt" && app.downloads.netz.value
    val aktuell by rememberUpdatedState(p)
    var schaetzung by remember(p.id) { mutableLongStateOf(p.geladen) }
    LaunchedEffect(p.id, kommtWas) {
        if (!kommtWas) { Kern.downloadSchaetzerAnhalten(p.id); return@LaunchedEffect }
        while (true) {
            schaetzung = Kern.downloadSchaetzerWert(p.id, aktuell.geladen)
            delay(33)
        }
    }
    val geladen = when {
        kommtWas -> schaetzung
        gruppe == null && (p.stand == "angehalten" || p.stand == "laedt") -> maxOf(Kern.downloadSchaetzerWert(p.id, p.geladen), p.geladen)
        else -> p.geladen
    }
    val anteil = if (p.bytes > 0) (geladen.toDouble() / p.bytes).coerceIn(0.0, 1.0) else p.anteil
    val ruhig = bewegungReduziert()

    Row(modifier.fillMaxWidth().abdunkeln(tun, lange).padding(horizontal = Stil.randAbstand, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically) {
        AnimatedVisibility(bearbeiten,
            enter = if (ruhig) fadeIn(Bewegung.blendeReduziert())
                    else expandHorizontally(Bewegung.blatt(), Alignment.Start) + slideInHorizontally(Bewegung.blatt()) { -it } + fadeIn(Bewegung.blatt()),
            exit = if (ruhig) fadeOut(Bewegung.blendeReduziert())
                   else shrinkHorizontally(Bewegung.blatt(), Alignment.Start) + slideOutHorizontally(Bewegung.blatt()) { -it } + fadeOut(Bewegung.blatt())) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                // 20 Semibold — die Reihenueberschrift und damit die naechste echte Stufe.
                Symbol(if (gewaehlt) Zeichen.HakenKreisVoll else Zeichen.Kreis, 20.dp, farbe = if (gewaehlt) Stil.akzent else Stil.schriftSehrLeise,
                       staerke = Staerke.Halbfett)
                Spacer(Modifier.width(12.dp))
            }
        }
        Box(Modifier.size(if (quer) 116.dp else 64.dp, if (quer) 65.dp else 96.dp).clip(RoundedCornerShape(Stil.eckeKachel)).background(Stil.flaeche)) {
            AsyncImage(model = bild, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(gruppe?.first ?: p.titel, style = Stil.listentitel, color = Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(gruppe?.second ?: unterzeile(p, geladen), style = Stil.klein.copy(fontFeatureSettings = "tnum"),
                 color = if (gruppe != null) Stil.schriftSehrLeise else unterfarbe(p), maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (gruppe == null && (p.stand == "laedt" || p.stand == "angehalten")) {
                anteil?.let { Fortschrittsbalken(it, Modifier.padding(top = 5.dp), rund = true) }
            }
        }
        if (gruppe != null) {
            Spacer(Modifier.width(12.dp))
            Symbol(Zeichen.WinkelRechts, 13.dp, farbe = Stil.schriftSehrLeise, staerke = Staerke.Halbfett)
        } else {
            AnimatedVisibility(!bearbeiten,
                enter = if (ruhig) fadeIn(Bewegung.blendeReduziert()) else expandHorizontally(Bewegung.blatt(), Alignment.End) + fadeIn(Bewegung.blatt()),
                exit = if (ruhig) fadeOut(Bewegung.blendeReduziert()) else shrinkHorizontally(Bewegung.blatt(), Alignment.End) + fadeOut(Bewegung.blatt())) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Spacer(Modifier.width(12.dp))
                    Ringknopf(app, p, anteilJetzt = anteil)
                }
            }
        }
    }
}

/**
 * Vorlage: `Auswahltipp` + `Abdunkeln` — **ohne graue Flaeche.** Hier tippt man nur, um zu waehlen
 * oder abzuspielen; der Inhalt dunkelt kurz ab (0,6), das reicht als Antwort. Der Druck kommt
 * sofort, das Loslassen klingt 120 ms nach. Ohne Handlung bleibt die Zeile still.
 */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
private fun Modifier.abdunkeln(tun: (() -> Unit)?, lange: (() -> Unit)?): Modifier = composed {
    val quelle = remember { MutableInteractionSource() }
    val gedrueckt by quelle.collectIsPressedAsState()
    val an = tun != null
    val druck = remember { Animatable(0f) }
    LaunchedEffect(gedrueckt, an) { if (gedrueckt && an) druck.snapTo(1f) else druck.animateTo(0f, Bewegung.loslassen()) }
    graphicsLayer { alpha = 1f - 0.4f * druck.value }
        .combinedClickable(quelle, null, enabled = an || lange != null, onLongClick = lange, onClick = { tun?.invoke() })
}

/**
 * Vorlage: `DownloadserieView` — **die Serie auf dem Geraet, als Detailseite.** Oben das grosse Bild
 * mit Name und „N Folgen · X GB", ein Abspielknopf, darunter die Folgen nach Staffel. Gebaut aus den
 * Bausteinen der Serienseite (`Held`, `Spielknopf`, `Detailkopf`) — keine eigene Gestaltung.
 *
 * **Alles von der Platte.** Wer hier steht, hat womoeglich kein Netz: das Bild ist das gesicherte
 * Kopfbild der Serie, sonst das Querbild der naechsten Folge, sonst das Plakat. Fehlt das Kopfbild
 * bei aelteren Downloads, wird es mit Netz einmal nachgeholt.
 *
 * **Drei Wege zum Entfernen:** nach links wischen, lange druecken („Download entfernen"), oder oben
 * Bearbeiten mit Auswahlkreisen und dem Knopf unten, wie in der Liste. Ist die letzte Folge weg,
 * geht die Seite zurueck.
 */
@Composable
fun DownloadserieSeite(app: SwiftlyAnwendung, ziel: Ziel, zurueck: () -> Unit) {
    val v = app.downloads
    val folgen = v.posten.value.filter { it.serienId == ziel.id }.sortedWith(compareBy({ it.staffel ?: 0 }, { it.folge ?: 0 }))
    LaunchedEffect(folgen.isEmpty()) { if (folgen.isEmpty()) zurueck() }
    var bearbeiten by remember { mutableStateOf(false) }
    var gewaehlt by remember { mutableStateOf(emptySet<String>()) }
    var nachgeholt by remember { mutableStateOf<File?>(null) }

    // `Downloadregeln.naechsteFolge`: die erste ungesehene fertige, sonst von vorn.
    val naechste = remember(folgen) { JSONObject(Kern.downloadNaechsteFolge(Downloadposten.liste(folgen))) }
    val naechsteFolge = folgen.firstOrNull { it.id == naechste.feldText("id") }
    val kopfbild = nachgeholt ?: v.kopfbild(ziel.id)
        ?: (naechsteFolge ?: folgen.firstOrNull())?.let { p -> v.bildDatei(p.id).takeIf { it.exists() } }
        ?: v.bildDatei(ziel.id).takeIf { it.exists() }
    val angabe = uebersetzt("%lld Folgen", folgen.size) + " · " + groesse(folgen.sumOf { it.bytes })

    LaunchedEffect(ziel.id) {
        if (v.kopfbild(ziel.id) != null) return@LaunchedEffect
        val adresse = runCatching { app.kern.downloadKopfbild(ziel.id, app.kopfbildbreite()).await() }.getOrNull()
        if (!adresse.isNullOrEmpty()) nachgeholt = v.kopfbildNachholen(ziel.id, adresse)
    }

    fun entfernen(ids: Collection<String>) { v.entfernen(ids) }
    fun umschalten(id: String) { gewaehlt = if (id in gewaehlt) gewaehlt - id else gewaehlt + id }

    val liste = rememberLazyListState()
    val dichte = LocalDensity.current
    Box(Modifier.fillMaxSize().background(Stil.grund)) {
        LazyColumn(Modifier.fillMaxSize(), state = liste,
                   contentPadding = PaddingValues(bottom = if (bearbeiten) 84.dp else 32.dp)) {
            item(key = "held") {
                Held(kopfbild?.let { Uri.fromFile(it).toString() }, ziel.name, angabe)
            }
            item(key = "knopf") {
                Box(Modifier.padding(horizontal = Stil.randAbstand).padding(top = 14.dp, bottom = 22.dp)) {
                    Spielknopf(Zeichen.Abspielen, naechste.feldText("knopftext") ?: uebersetzt("Abspielen"),
                               an = naechsteFolge != null, haupt = true) {
                        naechsteFolge?.let { app.spiel.value = Abspielwunsch(it.id, null) }
                    }
                }
            }
            folgen.groupBy { it.staffel }.forEach { (nummer, staffel) ->
                if (nummer != null) item(key = "s-$nummer") {
                    Gruppentitel(uebersetzt("Staffel %lld", nummer), Modifier.padding(top = 6.dp))
                }
                items(staffel, key = { it.id }) { p ->
                    Box(Modifier.animateItem()) {
                        Wischzeile(Zeichen.Papierkorb, uebersetzt("Entfernen"), farbe = Stil.fehler, tun = { entfernen(listOf(p.id)) }) {
                            Downloadzeile(app, p, v.bildDatei(p.id), true, bearbeiten, p.id in gewaehlt,
                                tun = when {
                                    bearbeiten -> { { umschalten(p.id) } }
                                    p.stand == "fertig" -> { { app.spiel.value = Abspielwunsch(p.id, null) } }
                                    else -> null
                                },
                                lange = {
                                    app.blatt.value = Blattwunsch(p.titel, listOf(Wahl("weg", uebersetzt("Download entfernen"))), null,
                                                                  mapOf("weg" to Zeichen.Papierkorb), warnend = setOf("weg")) { entfernen(listOf(p.id)) }
                                })
                        }
                    }
                }
                item(key = "e-$nummer") { Spacer(Modifier.height(16.dp)) }
            }
            item(key = "fuss") { Spacer(Modifier.navigationBarsPadding()) }
        }
        Detailkopf(ziel.name, {
            if (liste.firstVisibleItemIndex > 0) 1f
            else ((liste.firstVisibleItemScrollOffset / dichte.density - 150f) / 70f).coerceIn(0f, 1f)
        }, zurueck, rechts = { Bearbeitenknopf(bearbeiten) { bearbeiten = it; if (!it) gewaehlt = emptySet() } })
        if (bearbeiten) {
            Loeschleiste(app, gewaehlt, Modifier.align(Alignment.BottomCenter).navigationBarsPadding()) {
                entfernen(gewaehlt)
                gewaehlt = emptySet()
                bearbeiten = false
            }
        }
    }
}

/**
 * Vorlage: Gruppe „Offline" in `EinstellungenView` — **aus, bis jemand es will** (H1). Ausschalten
 * mit Titeln auf dem Geraet fragt, statt still zu loeschen (H10).
 */
@Composable
fun OfflineGruppe(app: SwiftlyAnwendung) {
    val e = app.einstellungen
    val v = app.downloads
    Einstellungsgruppe(uebersetzt("Offline")) {
        Wahlzeile(Zeichen.LadenKreis, uebersetzt("Downloads"), uebersetzt("Titel aufs Gerät laden und offline schauen"), e.downloadsAn) { an ->
            val anzahl = v.posten.value.size
            if (!an && anzahl > 0) {
                app.blatt.value = Blattwunsch(uebersetzt("%lld Titel bleiben auf dem Gerät", anzahl),
                    listOf(Wahl("behalten", uebersetzt("Behalten")), Wahl("weg", uebersetzt("Alles entfernen"))), null,
                    mapOf("behalten" to Zeichen.Haken, "weg" to Zeichen.Papierkorb), warnend = setOf("weg")) { wahl ->
                    if (wahl == "weg") v.allesEntfernen()
                    e.downloadsAn = false
                }
            } else e.downloadsAn = an
        }
        if (e.downloadsAn) {
            Trennlinie()
            Wahlzeile(Zeichen.Wlan, uebersetzt("Nur über WLAN"), uebersetzt("Downloads warten, bis du im WLAN bist"), e.nurUeberWLAN) {
                e.nurUeberWLAN = it
                v.takt()
            }
            Trennlinie()
            val fertig = v.posten.value.filter { it.stand == "fertig" }
            Wertzeile(Zeichen.Laufwerk, uebersetzt("Speicher"), uebersetzt("%lld Titel auf diesem Gerät", fertig.size),
                      wert = groesse(fertig.sumOf { it.bytes }))
        }
    }
}
