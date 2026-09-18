package de.paulherter.swiftly

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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.ArrowCircleDown
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Storage
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
fun Downloadring(p: Downloadposten?, mass: Dp = 28.dp) {
    val anteil by animateFloatAsState((p?.anteil ?: 0.0).toFloat().coerceAtLeast(0.02f), tween(400, easing = LinearEasing), label = "ring")
    Box(Modifier.size(mass), contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            val duenn = 1.5.dp.toPx()
            val dick = 2.dp.toPx()
            val r = size.minDimension / 2
            when (p?.stand) {
                null -> drawCircle(Stil.schriftLeise, r - duenn / 2, style = Stroke(duenn))
                "wartet" -> drawCircle(Stil.schriftSehrLeise, r - duenn / 2,
                    style = Stroke(duenn, pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 4.dp.toPx()))))
                "laedt", "angehalten" -> {
                    drawCircle(Color.White.copy(alpha = 0.14f), r - dick / 2, style = Stroke(dick))
                    drawArc(if (p.stand == "laedt") Stil.akzent else Stil.schriftLeise, -90f, 360f * anteil, false,
                            topLeft = Offset(dick / 2, dick / 2), size = Size(size.width - dick, size.height - dick),
                            style = Stroke(dick, cap = StrokeCap.Round))
                    if (p.stand == "laedt") {
                        val k = size.minDimension * 0.32f
                        drawRoundRect(Stil.schrift, Offset((size.width - k) / 2, (size.height - k) / 2), Size(k, k), CornerRadius(1.5.dp.toPx()))
                    }
                }
                "fertig" -> drawCircle(Stil.akzent, r)
                "fehler" -> drawCircle(Stil.warnung, r - dick / 2, style = Stroke(dick))
            }
        }
        when (p?.stand) {
            null -> Icon(Icons.Filled.ArrowDownward, uebersetzt("Laden"), tint = Stil.schrift, modifier = Modifier.size(mass * 0.46f))
            "wartet" -> Icon(Icons.Filled.Pause, uebersetzt("Wartet"), tint = Stil.schriftLeise, modifier = Modifier.size(mass * 0.4f))
            "angehalten" -> Icon(Icons.Filled.PlayArrow, uebersetzt("Angehalten, fortsetzen"), tint = Stil.schriftLeise, modifier = Modifier.size(mass * 0.4f))
            "fertig" -> Icon(Icons.Filled.ArrowDownward, uebersetzt("Geladen, entfernen"), tint = Stil.grund, modifier = Modifier.size(mass * 0.46f))
            "fehler" -> Icon(Icons.Filled.PriorityHigh, uebersetzt("Fehlgeschlagen, erneut versuchen"), tint = Stil.warnung, modifier = Modifier.size(mass * 0.46f))
        }
    }
}

/** Der Ring mit 44 Trefferflaeche — kleiner ist nicht tippbar. */
@Composable
private fun Ringknopf(app: SwiftlyAnwendung, p: Downloadposten?, mass: Dp = 28.dp, anlegen: () -> Unit = {}) {
    Box(Modifier.size(44.dp).antippen { app.downloads.ringTippen(p, anlegen) }, contentAlignment = Alignment.Center) {
        Downloadring(p, mass)
    }
}

/**
 * Vorlage: `Downloadfeld` — das fuenfte Feld der Aktionsreihe, **neben der Merkliste**: beide sind
 * das Paar „fuer spaeter". Wer Downloads nie einschaltet, sieht die Reihe mit vier Feldern.
 */
@Composable
internal fun RowScope.Downloadfeld(app: SwiftlyAnwendung, id: String, titel: String) {
    val p = app.downloads.posten(id)
    Box(Modifier.weight(1f).height(44.dp).clip(RoundedCornerShape(Stil.ecke)).background(Stil.flaeche)
            .antippen { app.downloads.ringTippen(p) { app.downloadsAnlegen(listOf(id), titel) } },
        contentAlignment = Alignment.Center) {
        if (p?.stand == "fertig") Icon(Icons.Filled.ArrowCircleDown, uebersetzt("Laden"), tint = Stil.akzent, modifier = Modifier.size(24.dp))
        else Downloadring(p, 24.dp)
    }
}

/** Der Ring am Ende einer Folgenzeile. */
fun folgenring(app: SwiftlyAnwendung, id: String, titel: String): @Composable () -> Unit = {
    Ringknopf(app, app.downloads.posten(id), 26.dp) { app.downloadsAnlegen(listOf(id), titel) }
}

/**
 * **Die ganze Staffel, der Reihe nach** — gleichzeitig gibt es nicht (H4). Liegt jede Folge schon
 * auf dem Geraet, faellt der Knopf weg: einer, der nichts mehr tut, ist schlechter als keiner.
 */
@Composable
fun StaffelLaden(app: SwiftlyAnwendung, ids: List<String>, titel: String, modifier: Modifier = Modifier) {
    val offen = ids.filter { app.downloads.posten(it) == null }
    if (offen.isEmpty()) return
    Row(modifier.clip(CircleShape).background(Color.White.copy(alpha = 0.10f)).antippen { app.downloadsAnlegen(offen, titel) }
            .padding(horizontal = 12.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
        Icon(Icons.Filled.ArrowDownward, contentDescription = null, tint = Stil.schrift, modifier = Modifier.size(14.dp))
        Text(uebersetzt("Staffel laden"), style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium), color = Stil.schrift)
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
                        Spielknopf(Icons.Outlined.Delete, uebersetzt("Gesehene entfernen und laden"), true, haupt = true) {
                            schliessen()
                            val weg = platz.getJSONArray("entbehrlich").let { a -> (0 until a.length()).map { a.getString(it) } }
                            v.entfernen(weg)
                            laden()
                        }
                        Spielknopf(Icons.Filled.Close, uebersetzt("Abbrechen"), true, haupt = false, schliessen)
                    }
                } else {
                    Blatthinweis(uebersetzt("Auch nach dem Entfernen der gesehenen Titel reicht der Platz nicht. In den Einstellungen unter Offline steht, was belegt ist."))
                    Knopfreihe { Spielknopf(Icons.Filled.Check, uebersetzt("Verstanden"), true, haupt = false, schliessen) }
                }
            }
            !v.darfLaden() -> {
                Blattzeile(uebersetzt("Größe"), groesse(bytes))
                Blattzeile(uebersetzt("Kein WLAN"), uebersetzt("Mobilfunk"), warnend = true)
                Knopfreihe {
                    Spielknopf(Icons.Filled.Schedule, uebersetzt("In die Warteschlange"), true, haupt = true) { schliessen(); laden() }
                    Spielknopf(Icons.Filled.SignalCellularAlt, uebersetzt("Jetzt über Mobilfunk laden"), true, haupt = false) {
                        schliessen(); app.einstellungen.nurUeberWLAN = false; laden()
                    }
                }
                Blatthinweis(uebersetzt("Der Download startet von selbst, sobald WLAN da ist."))
            }
            else -> {
                Blattzeile(uebersetzt("Größe"), groesse(bytes))
                neue.singleOrNull()?.container?.let { Blattzeile(uebersetzt("Qualität"), it.uppercase()) }
                Blattzeile(uebersetzt("Danach frei"), groesse(platz.getLong("freiDanach")))
                Knopfreihe { Spielknopf(Icons.Filled.ArrowDownward, uebersetzt("Laden"), true, haupt = true) { schliessen(); laden() } }
                Blatthinweis(uebersetzt("Swiftly lädt die Originaldatei — dieselbe Qualität wie beim Streamen, weil nie umgerechnet wird."))
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
private fun unterzeile(p: Downloadposten): String {
    val teile = mutableListOf<String>()
    if (p.staffel != null && p.folge != null) teile += "S${p.staffel} F${p.folge}"
    else p.laufzeitTicks?.takeIf { it > 0 }?.let { teile += uebersetzt("%lld Min.", (it / 600_000_000L).toInt()) }
    when (p.stand) {
        "laedt" -> return groesse(p.geladen) + " " + uebersetzt("von") + " " + groesse(p.bytes)
        "wartet" -> teile += uebersetzt("wartet")
        "angehalten" -> teile += uebersetzt("angehalten")
        "fehler" -> return p.grund ?: uebersetzt("Fehlgeschlagen")
        else -> teile += groesse(p.bytes)
    }
    return teile.joinToString(" · ")
}

private fun zeilentitel(p: Downloadposten) = if (p.art == "folge" && p.serie != null) "${p.serie} · ${p.titel}" else p.titel

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

    Column(Modifier.fillMaxSize().background(Stil.grund)) {
        Column(Modifier.statusBarsPadding().padding(horizontal = Stil.randAbstand).padding(top = 8.dp, bottom = 6.dp),
               verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(uebersetzt("Downloads"), style = Stil.titel, color = Stil.schrift, modifier = Modifier.weight(1f))
                if (alle.isNotEmpty()) Box(Modifier.size(44.dp).antippen { bearbeiten = !bearbeiten; gewaehlt = emptySet() },
                                           contentAlignment = Alignment.Center) {
                    if (bearbeiten) Text(uebersetzt("Fertig"), style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold), color = Stil.akzent)
                    else Icon(Icons.Outlined.Edit, uebersetzt("Bearbeiten"), tint = Stil.schrift, modifier = Modifier.size(22.dp))
                }
            }
            val belegt = fertige.sumOf { it.bytes }
            val frei = remember(alle) { v.frei() }
            Text(when {
                     !netz -> uebersetzt("Kein Netz") + " · " + uebersetzt("%lld Titel spielbar", fertige.size)
                     fertige.isEmpty() && laufend.isEmpty() -> uebersetzt("Nichts auf dem Gerät")
                     else -> uebersetzt("%lld Titel", fertige.size) + " · " + groesse(belegt) + " · " + groesse(frei) + " " + uebersetzt("frei")
                 }, style = Stil.klein, color = if (!netz) Stil.warnung else Stil.schriftLeise)
            if (fertige.isNotEmpty()) Speicherbalken(belegt, frei, remember { v.gesamt() })
        }
        Box(Modifier.weight(1f)) {
            if (alle.isEmpty()) {
                Leerzustand(Icons.Outlined.ArrowCircleDown, uebersetzt("Noch nichts geladen"),
                    uebersetzt("Auf jeder Film- und Serienseite gibt es ein Feld zum Laden. Geladene Titel laufen auch ohne Netz — in voller Qualität, weil Swiftly nie umrechnet."))
            } else LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = if (bearbeiten) 90.dp else 24.dp)) {
                if (laufend.isNotEmpty()) {
                    item(key = "kopf-laufend") {
                        Blocktitel(uebersetzt(if (netz) "Lädt gerade" else "Wartet auf Netz"), laufend.size, Modifier.padding(horizontal = Stil.randAbstand))
                    }
                    items(laufend, key = { "l-" + it.id }) { p ->
                        Downloadzeile(v.bildDatei(p.id), p.art == "folge", zeilentitel(p), unterzeile(p),
                            balken = p.anteil?.takeIf { p.stand == "laedt" || p.stand == "angehalten" },
                            gewaehlt = if (bearbeiten) p.id in gewaehlt else null,
                            rechts = { Ringknopf(app, p) }) { if (bearbeiten) umschalten(listOf(p.id)) }
                    }
                }
                if (gruppen.isNotEmpty()) {
                    item(key = "kopf-geraet") {
                        Blocktitel(uebersetzt("Auf dem Gerät"), gruppen.size, Modifier.padding(horizontal = Stil.randAbstand))
                    }
                    items(gruppen, key = { "g-" + it.id }) { g ->
                        val sid = g.serienId
                        val erste = alle.firstOrNull { it.id == g.folgen.firstOrNull() }
                        if (sid != null) {
                            Downloadzeile(v.bildDatei(sid), false, g.titel, uebersetzt("%lld Folgen", g.folgen.size) + " · " + groesse(g.bytes),
                                gewaehlt = if (bearbeiten) g.folgen.all { it in gewaehlt } else null,
                                rechts = { Icon(Icons.Filled.KeyboardArrowRight, null, tint = Stil.schriftSehrLeise, modifier = Modifier.size(22.dp)) }) {
                                if (bearbeiten) umschalten(g.folgen) else oeffnen(Ziel(sid, g.titel, "Downloadserie"))
                            }
                        } else if (erste != null) {
                            Downloadzeile(v.bildDatei(erste.id), erste.art == "folge", zeilentitel(erste), unterzeile(erste),
                                // H9: leise, keine Fehlerfarbe — die Datei laeuft ja.
                                hinweis = if (!erste.nochAufDemServer) uebersetzt("nicht mehr auf dem Server") else null,
                                gewaehlt = if (bearbeiten) erste.id in gewaehlt else null,
                                rechts = { Ringknopf(app, erste) }) {
                                if (bearbeiten) umschalten(listOf(erste.id)) else app.spiel.value = Abspielwunsch(erste.id, null)
                            }
                        }
                    }
                }
            }
            if (bearbeiten && gewaehlt.isNotEmpty()) {
                val weg = alle.filter { it.id in gewaehlt }
                val text = uebersetzt("%lld entfernen", weg.size) + " · " + groesse(weg.sumOf { it.bytes })
                Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth().background(Stil.grund)
                        .padding(horizontal = Stil.randAbstand, vertical = 12.dp)) {
                    Spielknopf(Icons.Outlined.Delete, text, true, haupt = false) {
                        app.blatt.value = Blattwunsch(text, listOf(Wahl("weg", uebersetzt("Entfernen"))), null,
                                                      mapOf("weg" to Icons.Outlined.Delete)) {
                            v.entfernen(gewaehlt)
                            gewaehlt = emptySet()
                            bearbeiten = false
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun Speicherbalken(belegt: Long, frei: Long, gesamt: Long) {
    if (gesamt <= 0) return
    val eigen = (belegt.toFloat() / gesamt).coerceIn(0.005f, 1f)
    val offen = (frei.toFloat() / gesamt).coerceIn(0f, 1f - eigen)
    val rest = 1f - eigen - offen
    Row(Modifier.fillMaxWidth().padding(top = 6.dp).height(6.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.08f))) {
        Box(Modifier.weight(eigen).fillMaxHeight().background(Stil.akzent))
        if (offen > 0.001f) Box(Modifier.weight(offen).fillMaxHeight().background(Color.White.copy(alpha = 0.22f)))
        if (rest > 0.001f) Spacer(Modifier.weight(rest))
    }
}

@Composable
private fun Downloadzeile(bild: File, quer: Boolean, titel: String, unter: String, hinweis: String? = null, balken: Double? = null,
                          gewaehlt: Boolean? = null, rechts: @Composable () -> Unit = {}, tun: () -> Unit) {
    Row(Modifier.fillMaxWidth().druckzeile(tun).padding(horizontal = Stil.randAbstand, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        gewaehlt?.let {
            Icon(if (it) Icons.Filled.CheckCircle else Icons.Outlined.Circle, contentDescription = null,
                 tint = if (it) Stil.akzent else Stil.schriftSehrLeise, modifier = Modifier.size(22.dp))
        }
        Box(Modifier.size(if (quer) 104.dp else 64.dp, if (quer) 59.dp else 96.dp).clip(RoundedCornerShape(Stil.eckeKachel)).background(Stil.flaeche)) {
            AsyncImage(model = bild, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(titel, style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.Medium), color = Stil.schrift, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Text(unter, style = Stil.klein, color = Stil.schriftSehrLeise, maxLines = 1, overflow = TextOverflow.Ellipsis)
            hinweis?.let { Text(it, style = Stil.klein, color = Stil.schriftSehrLeise, maxLines = 1) }
            balken?.let { a ->
                Box(Modifier.padding(top = 4.dp).fillMaxWidth().height(3.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.12f))) {
                    Box(Modifier.fillMaxWidth(a.toFloat()).fillMaxHeight().background(Stil.akzent))
                }
            }
        }
        if (gewaehlt == null) rechts()
    }
}

/** Vorlage: `DownloadserieView` — die Folgen einer geladenen Serie, nach Staffel und Nummer. */
@Composable
fun DownloadserieSeite(app: SwiftlyAnwendung, ziel: Ziel, zurueck: () -> Unit) {
    val v = app.downloads
    val folgen = v.posten.value.filter { it.serienId == ziel.id }.sortedWith(compareBy({ it.staffel ?: 0 }, { it.folge ?: 0 }))
    LaunchedEffect(folgen.isEmpty()) { if (folgen.isEmpty()) zurueck() }
    Column(Modifier.fillMaxSize().background(Stil.grund)) {
        Unterseitenkopf(ziel.name, zurueck)
        LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(bottom = 24.dp)) {
            items(folgen, key = { it.id }) { p ->
                Downloadzeile(v.bildDatei(p.id), true, listOfNotNull(p.folge?.let { "$it." }, p.titel).joinToString(" "),
                    unterzeile(p),
                    hinweis = if (!p.nochAufDemServer) uebersetzt("nicht mehr auf dem Server") else null,
                    rechts = { Ringknopf(app, p, 26.dp) }) {
                    if (p.stand == "fertig") app.spiel.value = Abspielwunsch(p.id, null)
                }
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
        Wahlzeile(Icons.Outlined.ArrowCircleDown, uebersetzt("Downloads"), uebersetzt("Titel aufs Gerät laden und ohne Netz sehen"), e.downloadsAn) { an ->
            val anzahl = v.posten.value.size
            if (!an && anzahl > 0) {
                app.blatt.value = Blattwunsch(uebersetzt("%lld Titel bleiben auf dem Gerät", anzahl),
                    listOf(Wahl("behalten", uebersetzt("Behalten")), Wahl("weg", uebersetzt("Alles entfernen"))), null,
                    mapOf("behalten" to Icons.Filled.Check, "weg" to Icons.Outlined.Delete)) { wahl ->
                    if (wahl == "weg") v.allesEntfernen()
                    e.downloadsAn = false
                }
            } else e.downloadsAn = an
        }
        if (e.downloadsAn) {
            Trennlinie()
            Wahlzeile(Icons.Filled.Wifi, uebersetzt("Nur über WLAN"), uebersetzt("Über Mobilfunk warten Downloads"), e.nurUeberWLAN) {
                e.nurUeberWLAN = it
                v.takt()
            }
            Trennlinie()
            val fertig = v.posten.value.filter { it.stand == "fertig" }
            Wertzeile(Icons.Outlined.Storage, uebersetzt("Speicher"), uebersetzt("%lld Titel auf diesem Gerät", fertig.size),
                      wert = groesse(fertig.sumOf { it.bytes }))
        }
    }
}
