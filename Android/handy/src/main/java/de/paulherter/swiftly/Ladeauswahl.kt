package de.paulherter.swiftly

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.Crossfade
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.gemeinsam.Bewegung
import de.paulherter.swiftly.gemeinsam.Staerke
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.Symbol
import de.paulherter.swiftly.gemeinsam.Zeichen
import de.paulherter.swiftly.gemeinsam.uebersetzt
import de.paulherter.swiftly.kern.Kern
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/** Eine Folge, wie die Auswahl sie braucht — Antwort von `Kern.ladeauswahlFolgen`. */
private data class Ladefolge(val id: String, val name: String, val gesehen: Boolean, val bytes: Long)

private fun ladefolgenLesen(json: String): List<Ladefolge> = JSONArray(json).let { a ->
    (0 until a.length()).map { i ->
        a.getJSONObject(i).let { Ladefolge(it.getString("id"), it.getString("name"), it.optBoolean("gesehen"), it.optLong("bytes")) }
    }
}

/**
 * Vorlage: `Ladeauswahl` in `Sources/Shared/Ladeauswahl.swift` — **was geladen wird, wird ausgewaehlt,
 * nicht erraten.**
 *
 * Vorher stand hier ein runder Chip neben der Staffelwahl, der genau eine Staffel nahm, und zwar die
 * gerade gewaehlte. Jetzt ein Baum mit drei Ebenen — **ganze Serie, Staffel, Folge** —, und jede
 * Ebene traegt denselben runden Kasten: leer, teilweise, voll, und „da" fuer das, was schon auf dem
 * Geraet liegt. **Der Schalter waehlt nichts aus**: „Nur ungesehene" entscheidet, *was* ein Haken
 * nimmt, und die Auswahl wird neu gerechnet. Gesehene Folgen bleiben ohne Schalter waehlbar, mit
 * leisem Titel und „gesehen" vor der Groesse; mit Schalter stehen sie gar nicht erst da.
 *
 * Geladen wird hier nichts. Die gewaehlten Folgen gehen an `downloadsAnlegen` und damit ins
 * Ladeblatt — Platz, WLAN und Normalfall gelten dort unveraendert. Die Auswahl ist eine Stufe davor.
 *
 * **Tiefe geht nach oben:** das Blatt bleibt `flaeche`, die Karten liegen auf `erhoeht`, Ecke 14.
 */
fun ladeauswahlZeigen(app: SwiftlyAnwendung, serieId: String, name: String, staffeln: List<Staffel>) {
    app.blatt.value = Blattwunsch(name, emptyList(), null, inhalt = { schliessen ->
        Ladeauswahl(app, serieId, name, staffeln, schliessen)
    }) {}
}

/** Vier Zustaende: die drei der Auswahl, und **da** fuer das, was schon auf dem Geraet liegt. */
private enum class Kasten { Leer, Teil, Voll, Da }

@Composable
private fun Ladeauswahl(app: SwiftlyAnwendung, serieId: String, name: String, staffeln: List<Staffel>, schliessen: () -> Unit) {
    val v = app.downloads
    // Beobachtet: was waehrend des Offenseins fertig wird, wechselt hier auf „da".
    v.posten.value
    var folgen by remember { mutableStateOf<Map<String, List<Ladefolge>>>(emptyMap()) }
    var gewaehlt by remember { mutableStateOf(emptySet<String>()) }
    var offeneStaffel by remember { mutableStateOf<String?>(null) }
    var nurUngesehene by remember { mutableStateOf(false) }
    var laedt by remember { mutableStateOf(true) }
    /** **Der Fehlfall gehoert dazu.** Scheitert der Abruf, darf die Auswahl nicht leer dastehen. */
    var gestoert by remember { mutableStateOf(false) }
    var frei by remember { mutableLongStateOf(v.frei()) }

    val alleFolgen = staffeln.flatMap { folgen[it.id].orEmpty() }
    fun liegt(f: Ladefolge) = v.posten(f.id) != null
    /** Was ein Haken nimmt: ohne Schalter alles, mit Schalter nur Ungesehenes — was schon da ist, nie. */
    fun nehmbar(liste: List<Ladefolge>) = liste.filter { !liegt(it) && (!nurUngesehene || !it.gesehen) }
    /** Was in der Liste steht: mit „Nur ungesehene" stehen gesehene Folgen gar nicht erst da. */
    fun sichtbar(liste: List<Ladefolge>) = if (nurUngesehene) liste.filter { !it.gesehen } else liste
    fun stand(alle: List<Ladefolge>, daZaehlt: Boolean = true): Kasten {
        val liste = sichtbar(alle)
        if (daZaehlt && liste.isNotEmpty() && liste.all { liegt(it) }) return Kasten.Da
        val nimm = nehmbar(liste)
        if (nimm.isEmpty()) return Kasten.Leer
        val an = nimm.count { it.id in gewaehlt }
        return if (an == 0) Kasten.Leer else if (an == nimm.size) Kasten.Voll else Kasten.Teil
    }
    // Solange nicht jede Staffel gelesen ist, ist die Serie nicht „da".
    val standAlle = stand(alleFolgen, daZaehlt = !laedt)
    val bytes = alleFolgen.filter { it.id in gewaehlt }.sumOf { it.bytes }

    fun umschalten(liste: List<Ladefolge>) {
        val nimm = nehmbar(liste)
        if (nimm.isEmpty()) return
        val ids = nimm.map { it.id }.toSet()
        gewaehlt = if (nimm.all { it.id in gewaehlt }) gewaehlt - ids else gewaehlt + ids
    }
    /** Nach dem Schalter: alles, was nicht mehr nehmbar ist, faellt heraus. */
    fun neuRechnen() { gewaehlt = gewaehlt intersect nehmbar(alleFolgen).map { it.id }.toSet() }

    /** **Jede Staffel einmal, nacheinander** — `nil` heisst gestoert, `[]` heisst leer. */
    suspend fun alleLaden() {
        laedt = true
        gestoert = false
        frei = v.frei()
        for (st in staffeln) {
            if (folgen[st.id] != null) continue
            try {
                val liste = ladefolgenLesen(withContext(Dispatchers.IO) { app.kern.ladeauswahlFolgen(serieId, st.id).await() })
                folgen = folgen + (st.id to liste)
            } catch (e: CancellationException) { throw e } catch (_: Exception) { gestoert = true }
        }
        laedt = false
        // Was seit dem letzten Oeffnen geladen wurde, ist nicht mehr waehlbar.
        neuRechnen()
    }
    var versuch by remember { mutableIntStateOf(0) }
    LaunchedEffect(versuch) { alleLaden() }

    fun folgenzahl(n: Int) = if (n == 1) uebersetzt("1 Folge") else uebersetzt("%lld Folgen", n)
    /** „23 Folgen · 31,4 GB" — Anzahl und Groesse in einem Zug. */
    fun zahlUndGroesse(n: Int, b: Long) = folgenzahl(n) + " · " + Kern.downloadGroesse(b)

    if (gestoert && alleFolgen.isEmpty()) {
        Stoerhinweis(app.serveradresse(), Modifier.padding(bottom = 16.dp), abstandOben = 10.dp, erneut = { versuch++ })
        return
    }

    // **So hoch wie die Karten, hoechstens 440** — und die Hoehe laeuft in derselben Kurve wie das
    // Blatt (`blattbewegung`), statt nach dem Aufklappen schlagartig zu springen.
    Column(Modifier.animateContentSize(Bewegung.blatt()).heightIn(min = 58.dp, max = 440.dp).verticalScroll(rememberScrollState())
               .padding(bottom = 12.dp),
           verticalArrangement = Arrangement.spacedBy(12.dp)) {
        // Die Serienkarte: „Ganze Serie" und der Schalter.
        Column(Modifier.padding(horizontal = 16.dp).clip(RoundedCornerShape(Stil.eckeKarte)).background(Stil.erhoeht)) {
            // „Ganze Serie" nennt nur, was noch fehlt.
            val rechts = when {
                laedt -> uebersetzt("wird gelesen …")
                standAlle == Kasten.Da -> uebersetzt("alles da")
                alleFolgen.isNotEmpty() && sichtbar(alleFolgen).isEmpty() -> uebersetzt("alles gesehen")
                else -> nehmbar(alleFolgen).let { zahlUndGroesse(it.size, it.sumOf { f -> f.bytes }) }
            }
            Auswahlzeile(standAlle, uebersetzt("Ganze Serie"), rechts, tun = { umschalten(alleFolgen) })
            Blattlinie()
            Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(uebersetzt("Nur ungesehene"), style = Stil.listentitel, color = Stil.schrift, modifier = Modifier.weight(1f))
                    Spacer(Modifier.width(12.dp))
                    // Legt man den Schalter um, aendert sich nicht die Auswahl, sondern ihre Grundmenge.
                    Schalter(nurUngesehene) { nurUngesehene = it; neuRechnen() }
                }
                Text(uebersetzt("Entscheidet, was ein Haken auswählt."), style = Stil.klein, color = Stil.schriftSehrLeise)
            }
        }

        // Die Staffelkarte: aufklappbar, die Folgen nur eingerueckt, keine zweite Flaeche.
        Column(Modifier.padding(horizontal = 16.dp).clip(RoundedCornerShape(Stil.eckeKarte)).background(Stil.erhoeht)) {
            staffeln.forEachIndexed { nr, st ->
                val alle = folgen[st.id]
                val eigene = sichtbar(alle.orEmpty())
                val kasten = stand(eigene)
                val rechts = when {
                    alle == null -> if (laedt) uebersetzt("wird gelesen …") else "—"
                    alle.isEmpty() -> uebersetzt("Keine Folgen")
                    eigene.isEmpty() -> uebersetzt("alles gesehen")
                    kasten == Kasten.Da -> uebersetzt("alles da")
                    else -> nehmbar(eigene).let { if (it.isEmpty()) uebersetzt("alles da") else folgenzahl(it.size) }
                }
                val auf = offeneStaffel == st.id
                Auswahlzeile(kasten, st.name, rechts, aufgeklappt = auf, tun = { umschalten(eigene) },
                             aufklappen = { offeneStaffel = if (auf) null else st.id })
                AnimatedVisibility(auf, enter = expandVertically(Bewegung.blatt()) + fadeIn(Bewegung.blatt()),
                                   exit = shrinkVertically(Bewegung.blatt()) + fadeOut(Bewegung.blatt())) {
                    Column {
                        alle.orEmpty().forEach { f ->
                            // Der Schalter nimmt gesehene Folgen weich aus der Liste, nicht schlagartig.
                            AnimatedVisibility(!(nurUngesehene && f.gesehen),
                                enter = expandVertically(Bewegung.blatt()) + fadeIn(Bewegung.blatt()),
                                exit = shrinkVertically(Bewegung.blatt()) + fadeOut(Bewegung.blatt())) {
                                Column {
                                    // Durchgehend, auch unter den eingerueckten Folgen.
                                    Blattlinie()
                                    val p = v.posten(f.id)
                                    // **Gesehen steht dabei, bevor man waehlt**; eine geladene Folge sagt, dass sie da ist.
                                    val groesse = if (f.bytes > 0) Kern.downloadGroesse(f.bytes) else "—"
                                    val folgeRechts = when {
                                        p == null -> if (f.gesehen) uebersetzt("gesehen") + " · " + groesse else groesse
                                        p.stand == "fertig" -> uebersetzt("geladen")
                                        p.stand == "laedt" -> uebersetzt("lädt")
                                        else -> uebersetzt("wartet")
                                    }
                                    Auswahlzeile(if (p != null) Kasten.Da else if (f.id in gewaehlt) Kasten.Voll else Kasten.Leer,
                                                 f.name, folgeRechts, klein = true, einzug = 38.dp, leise = f.gesehen,
                                                 tun = { umschalten(listOf(f)) })
                                }
                            }
                        }
                    }
                }
                if (nr < staffeln.size - 1) Blattlinie()
            }
        }
    }

    // **Der Fuss rechnet mit.** Links, was gewaehlt ist; rechts, was danach frei bleibt.
    Column(Modifier.padding(top = 4.dp, bottom = 8.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Blattlinie()
        Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(if (gewaehlt.isEmpty()) uebersetzt("Nichts gewählt") else zahlUndGroesse(gewaehlt.size, bytes),
                 style = Stil.kachel.copy(fontFeatureSettings = "tnum"), color = Stil.schrift, modifier = Modifier.weight(1f))
            Spacer(Modifier.width(8.dp))
            // Ob es reicht, entscheidet `Downloadregeln.fussplatz` — mit derselben Reserve wie das Blatt danach.
            val platz = JSONObject(Kern.downloadFussplatz(bytes, frei))
            if (platz.getBoolean("reicht")) {
                Text(uebersetzt("Danach %@ frei", Kern.downloadGroesse(platz.getLong("bytes"))),
                     style = Stil.klein.copy(fontFeatureSettings = "tnum"), color = Stil.schriftSehrLeise)
            } else {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                    Symbol(Zeichen.Info, 12.dp, farbe = Stil.warnung, staerke = Staerke.Halbfett)
                    Text(uebersetzt("%@ zu wenig", Kern.downloadGroesse(platz.getLong("bytes"))),
                         style = Stil.klein.copy(fontFeatureSettings = "tnum"), color = Stil.warnung)
                }
            }
        }
        // **Die Qualitaet steht dabei, nicht im Kleingedruckten.**
        Row(Modifier.padding(horizontal = 16.dp).clip(RoundedCornerShape(Stil.eckeKlein)).background(Stil.akzent.copy(alpha = 0.15f))
                .padding(horizontal = 10.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Symbol(Zeichen.Haken, 11.dp, farbe = Stil.akzent, staerke = Staerke.Halbfett)
            Text(uebersetzt("Direct Play · Originalqualität"), style = Stil.klein, color = Stil.akzent)
        }
        // **Mit Pfeil**, wie in der Knopfreihe der Serie. Gesperrt auf `erhoeht`: auf dem Blatt in
        // `flaeche` waere ein gesperrter Knopf in `flaeche` nur noch leise Schrift.
        Box(Modifier.padding(horizontal = 16.dp)) {
            Spielknopf(Zeichen.PfeilRunter,
                       if (gewaehlt.isEmpty()) uebersetzt("Laden") else uebersetzt("%@ laden", folgenzahl(gewaehlt.size)),
                       an = gewaehlt.isNotEmpty(), haupt = true, gesperrtFlaeche = Stil.erhoeht) {
                val ids = alleFolgen.filter { it.id in gewaehlt }.map { it.id }
                schliessen()
                // Ein Blatt zur Zeit: das Ladeblatt kommt, wenn dieses unten ist.
                app.downloadsAnlegen(ids, name, abwarten = 260)
            }
        }
    }
}

/**
 * Eine Zeile der Auswahl — **Kreis 22, Trefferflaeche 44**; die 44 ragen je 11 ueber den Kreis hinaus,
 * Einzug und Abstand ziehen sie wieder ab. Die Folgenzeile traegt die 52 der uebrigen Blaetter, die
 * Staffelzeile eine Stufe darueber (58). Ohne Aufklapper tut die Zeile daneben dasselbe wie der Kreis.
 */
@Composable
private fun Auswahlzeile(kasten: Kasten, titel: String, rechts: String, klein: Boolean = false, einzug: Dp = 16.dp,
                         aufgeklappt: Boolean? = null, leise: Boolean = false, tun: () -> Unit, aufklappen: (() -> Unit)? = null) {
    val wert = when (kasten) { Kasten.Teil -> uebersetzt("teilweise"); Kasten.Da -> uebersetzt("geladen"); else -> "" }
    Row(Modifier.fillMaxWidth().heightIn(min = if (klein) 52.dp else 58.dp).padding(start = einzug - 11.dp, end = 16.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(44.dp).then(if (kasten == Kasten.Da) Modifier else Modifier.antippen(tun))
                .semantics { contentDescription = titel; stateDescription = wert; selected = kasten == Kasten.Voll },
            contentAlignment = Alignment.Center) {
            Kastenbild(kasten)
        }
        Spacer(Modifier.width(2.dp))
        Row(Modifier.weight(1f).heightIn(min = 44.dp).druckzeile { (aufklappen ?: tun)() },
            verticalAlignment = Alignment.CenterVertically) {
            Text(titel, style = TextStyle(fontSize = if (klein) 13.sp else 15.sp, fontWeight = if (klein) FontWeight.Medium else FontWeight.SemiBold),
                 color = if (kasten == Kasten.Da || leise) Stil.schriftLeise else Stil.schrift,
                 maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            Spacer(Modifier.width(10.dp))
            Text(rechts, style = Stil.klein.copy(fontFeatureSettings = "tnum"), color = Stil.schriftSehrLeise, maxLines = 1)
            if (aufgeklappt != null) {
                val drehung by animateFloatAsState(if (aufgeklappt) 0f else -90f, Bewegung.blatt(), label = "pfeil")
                Spacer(Modifier.width(10.dp))
                Symbol(Zeichen.WinkelRunter, 12.dp, Modifier.graphicsLayer { rotationZ = drehung },
                       farbe = Stil.schriftSehrLeise, staerke = Staerke.Halbfett,
                       beschreibung = uebersetzt(if (aufgeklappt) "Zuklappen" else "Aufklappen"))
            }
        }
    }
}

/** Der runde Kasten: leer als Ring in `schriftSehrLeise` (3:1 auf `erhoeht`), teilweise und voll im Akzent, da als leiser Haken. */
@Composable
private fun Kastenbild(k: Kasten) {
    Crossfade(k, animationSpec = Bewegung.umschalten(), label = "kasten") { z ->
        Box(Modifier.size(22.dp), contentAlignment = Alignment.Center) {
            when (z) {
                Kasten.Leer -> Canvas(Modifier.fillMaxSize()) {
                    val b = 1.6.dp.toPx()
                    drawCircle(Stil.schriftSehrLeise, size.minDimension / 2 - b / 2, style = Stroke(b))
                }
                Kasten.Teil -> {
                    Box(Modifier.fillMaxSize().clip(CircleShape).background(Stil.akzent))
                    Symbol(Zeichen.Minus, 12.dp, farbe = Stil.aufAkzent, staerke = Staerke.Halbfett)
                }
                Kasten.Voll -> {
                    Box(Modifier.fillMaxSize().clip(CircleShape).background(Stil.akzent))
                    Symbol(Zeichen.Haken, 11.dp, farbe = Stil.aufAkzent, staerke = Staerke.Halbfett)
                }
                // Leise, ohne Kreis: ein Haken in Akzent hiesse „gewaehlt"; dieser sagt, dass nichts mehr zu tun ist.
                Kasten.Da -> Symbol(Zeichen.Haken, 15.dp, farbe = Stil.schriftSehrLeise, staerke = Staerke.Halbfett)
            }
        }
    }
}
