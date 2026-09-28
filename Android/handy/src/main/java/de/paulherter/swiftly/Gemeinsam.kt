package de.paulherter.swiftly

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.gemeinsam.Hauptknopf
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.Symbol
import de.paulherter.swiftly.gemeinsam.Zeichen
import de.paulherter.swiftly.gemeinsam.uebersetzt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.util.Locale

// **Gemeinsam schauen** — Vorlage `Gemeinsammodell` (Sources/Shared) und `Gemeinsamansichten`
// (Sources/iOS). Der Ablauf steht im Paket (`SyncPlaySitzung`), die Bruecke im Kern
// (`Kern.syncPlay…`, `Gemeinsam.swift`). Hier liegt nur, was man sieht und antippt.

data class Gemeinsamgruppe(val id: String, val name: String, val teilnehmer: List<String>,
                           val namen: List<String>, val zustand: String?)

data class Gemeinsamereignis(val id: String, val art: String, val text: String)

/** Der Spiegel der `SyncPlayLage` — kommt fertig aus dem Kern (`Gemeinsamantwort`). */
data class Gemeinsamlage(
    val darfAnlegen: Boolean = true,
    val darfBeitreten: Boolean = true,
    /** Gruppen auf dem Server, in denen man nicht selbst ist. */
    val angebote: List<Gemeinsamgruppe> = emptyList(),
    /** Die Gruppe, in der man ist. */
    val gruppe: Gemeinsamgruppe? = null,
    /** Wer ausser einem selbst dabei ist, jeder einmal. */
    val andere: List<String> = emptyList(),
    val ereignis: Gemeinsamereignis? = null,
    /** Fuer den Streifen „Filmabend verlassen · Wieder beitreten". */
    val zuletztVerlassen: String? = null,
    val arbeitet: Boolean = false,
    val schlangeTitel: String? = null,
    val fehler: String? = null,
    val fehlerNummer: Int = 0,
    val angenommen: Int = 0,
) {
    /** „mit Paul und Tom" — ohne einen selbst. */
    val mitWem: String get() = if (andere.isEmpty()) uebersetzt("noch niemand dabei") else uebersetzt("mit %@", namenliste(andere))

    /** Was das Abzeichen mitzaehlt: offene Gruppen, solange man in keiner ist und beitreten darf. */
    val offeneGruppen: List<Gemeinsamgruppe> get() = if (gruppe == null && darfBeitreten) angebote else emptyList()
}

private fun gruppeLesen(o: JSONObject) = Gemeinsamgruppe(o.getString("id"), o.optString("name"), o.feldTexte("teilnehmer"),
                                                         o.feldTexte("namen"), o.feldText("zustand"))

internal fun gemeinsamlageLesen(o: JSONObject) = Gemeinsamlage(
    darfAnlegen = o.optBoolean("darfAnlegen", true),
    darfBeitreten = o.optBoolean("darfBeitreten", true),
    angebote = o.feldListe("angebote", ::gruppeLesen),
    gruppe = o.optJSONObject("gruppe")?.let(::gruppeLesen),
    andere = o.feldTexte("andere"),
    ereignis = o.optJSONObject("ereignis")?.let { Gemeinsamereignis(it.getString("id"), it.getString("art"), it.getString("text")) },
    zuletztVerlassen = o.feldText("zuletztVerlassen"),
    arbeitet = o.optBoolean("arbeitet"),
    schlangeTitel = o.feldText("schlangeTitel"),
    fehler = o.feldText("fehler"),
    fehlerNummer = o.optInt("fehlerNummer"),
    angenommen = o.optInt("angenommen"),
)

/** „Paul und Tom", „Paul, Tom und Anna" — `ListFormatter` wie auf Apple, in der Sprache der Texte. */
internal fun namenliste(namen: List<String>): String =
    android.icu.text.ListFormatter.getInstance(if (Locale.getDefault().language == "de") Locale.GERMAN else Locale.ENGLISH).format(namen)

/** „Paul und Tom schauen gerade" (`Gemeinsamblaetter.wer`). */
internal fun werSchaut(g: Gemeinsamgruppe): String = when {
    g.namen.isEmpty() -> uebersetzt("Noch niemand dabei")
    g.namen.size == 1 -> uebersetzt("%@ schaut gerade", namenliste(g.namen))
    else -> uebersetzt("%@ schauen gerade", namenliste(g.namen))
}

internal fun zustandText(z: String?): String? = when (z) {
    "laeuft" -> uebersetzt("Läuft gerade")
    "angehalten" -> uebersetzt("Angehalten")
    "wartet" -> uebersetzt("Wartet auf alle")
    else -> null
}

/** Das Zeichen je Ereignis (`Gemeinsammodell.zeichen`). */
internal fun ereigniszeichen(art: String): Zeichen = when (art) {
    "dabei" -> Zeichen.GruppeVoll
    "gegangen" -> Zeichen.Gruppe
    "wartet" -> Zeichen.Sanduhr
    "angehalten" -> Zeichen.Pause
    "weiter" -> Zeichen.Abspielen
    "gesprungen" -> Zeichen.Sprungpfeile
    else -> Zeichen.Warnung
}

/**
 * **Einmal beim Start der App:** die Lage aus dem Kern spiegeln, Fehler melden, und den Player
 * oeffnen, wenn die Gruppe einen Titel setzt und keiner offen ist (`Gemeinsammodell.titelLaden`,
 * `wunsch` in `HauptView`). Beides wartet im Kern, bis sich etwas aendert — kein Takt.
 */
fun SwiftlyAnwendung.gemeinsamZuhoeren(lauf: kotlinx.coroutines.CoroutineScope) {
    lauf.launch {
        var stand = 0L
        var fehlerGesehen = 0
        while (true) {
            val roh = runCatching { withContext(Dispatchers.IO) { kern.syncPlayLage(stand).await() } }.getOrNull()
            if (roh == null) { kotlinx.coroutines.delay(1000); continue }
            val o = JSONObject(roh)
            stand = o.optLong("stand", stand)
            val neu = gemeinsamlageLesen(o.getJSONObject("lage"))
            gemeinsam.value = neu
            if (neu.fehlerNummer != fehlerGesehen) {
                fehlerGesehen = neu.fehlerNummer
                // Als Hinweisstreifen — im Player als sein Hinweis, sonst ueber der Hauptansicht.
                neu.fehler?.let { gemeinsamFehler.value = it }
            }
        }
    }
    lauf.launch {
        while (true) {
            val roh = runCatching { withContext(Dispatchers.IO) { kern.syncPlayWunsch().await() } }.getOrNull()
            if (roh.isNullOrEmpty()) { kotlinx.coroutines.delay(500); continue }
            val o = JSONObject(roh)
            spiel.value = Abspielwunsch(o.getString("titel"), o.optDouble("ab", 0.0))
        }
    }
}

// MARK: Blaetter

/** Wie lange ein Blatt zum Hinausfahren braucht, bevor das naechste kommt (Mehr → „Gemeinsam schauen"). */
internal const val BLATTWECHSEL = 300L

/**
 * „Serie · Staffel 2 · Folge 3" bei einer Folge, sonst der Name — sonst weiss man im Blatt nicht,
 * welche Folge die Gruppe schauen wird (`Gemeinsamblaetter.titelzeile`).
 */
internal fun gemeinsamTitelzeile(name: String, serie: String?, staffel: Int?, folge: Int?): String = when {
    serie.isNullOrEmpty() -> name
    staffel != null && folge != null -> "$serie · " + uebersetzt("Staffel %lld · Folge %lld", staffel, folge)
    else -> "$serie · $name"
}

/**
 * Vorlage: das Blatt „Gemeinsam schauen" in `Gemeinsamblaetter` — Titelzeile, „Name der Gruppe"
 * mit „Filmabend" vorbelegt, der Satz dazu, „Gruppe öffnen". **Das Blatt geht zu, sobald der
 * Server angenommen hat** (`angenommen`), nicht erst nach dem Warten auf den Steuerkanal.
 */
fun gemeinsamAnlegenOeffnen(app: SwiftlyAnwendung, titelId: String, titelzeile: String) {
    app.blatt.value = Blattwunsch(uebersetzt("Gemeinsam schauen"), emptyList(), null, inhalt = { schliessen ->
        val lage = app.gemeinsam.value
        var name by remember { mutableStateOf(uebersetzt("Filmabend")) }
        val beiOeffnen = remember { lage.angenommen }
        val lauf = androidx.compose.runtime.rememberCoroutineScope()
        val fokus = LocalFocusManager.current
        LaunchedEffect(lage.angenommen) { if (lage.angenommen != beiOeffnen) schliessen() }
        fun oeffnen() {
            fokus.clearFocus()
            lauf.launch {
                if (withContext(Dispatchers.IO) { app.kern.syncPlayAnlegen(name, titelId).await() }) schliessen()
            }
        }
        Column(Modifier.padding(horizontal = Stil.randAbstand).padding(bottom = 12.dp)) {
            Text(titelzeile, style = Stil.koerper, color = Stil.schriftLeise, modifier = Modifier.padding(bottom = 16.dp))
            Text(uebersetzt("Name der Gruppe"), style = Stil.klein, color = Stil.schriftSehrLeise, modifier = Modifier.padding(bottom = 6.dp))
            Box(Modifier.fillMaxWidth().heightIn(min = 44.dp).background(Stil.erhoeht, RoundedCornerShape(Stil.eckeFeld))
                    .padding(horizontal = 14.dp), contentAlignment = Alignment.CenterStart) {
                if (name.isEmpty()) Text(uebersetzt("Filmabend"), style = Stil.koerper.copy(fontSize = 17.sp), color = Stil.schriftSehrLeise)
                BasicTextField(name, { name = it }, singleLine = true,
                    textStyle = Stil.koerper.copy(fontSize = 17.sp, color = Stil.schrift),
                    cursorBrush = SolidColor(Stil.akzent),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { fokus.clearFocus() }),
                    modifier = Modifier.fillMaxWidth())
            }
            Text(uebersetzt("Alle auf deinem Server sehen die Gruppe und können mit einsteigen. Pause und Springen gelten dann für alle."),
                 style = Stil.koerper, color = Stil.schriftLeise, modifier = Modifier.padding(top = 14.dp, bottom = 18.dp))
            Hauptknopf(uebersetzt("Gruppe öffnen"), freigegeben = !lage.arbeitet, gesperrtFlaeche = Stil.erhoeht) { oeffnen() }
        }
        Blattlinie()
        Blattabbruch(schliessen)
    }) { }
}

/** Vorlage: das Blatt „Beitreten" — Name der Gruppe als Rubrik, wer schaut, der Zustand im Akzent. */
fun gemeinsamBeitretenOeffnen(app: SwiftlyAnwendung, g: Gemeinsamgruppe) {
    app.blatt.value = Blattwunsch(g.name, emptyList(), null, inhalt = { schliessen ->
        val lage = app.gemeinsam.value
        val beiOeffnen = remember { lage.angenommen }
        val lauf = androidx.compose.runtime.rememberCoroutineScope()
        LaunchedEffect(lage.angenommen) { if (lage.angenommen != beiOeffnen) schliessen() }
        Column(Modifier.padding(horizontal = Stil.randAbstand).padding(bottom = 12.dp)) {
            Text(werSchaut(g), style = Stil.koerper, color = Stil.schriftLeise)
            zustandText(g.zustand)?.let { Text(it, style = Stil.klein, color = Stil.akzent, modifier = Modifier.padding(top = 6.dp)) }
            Text(uebersetzt("Pause und Springen gelten für alle."), style = Stil.klein, color = Stil.schriftSehrLeise,
                 modifier = Modifier.padding(top = 10.dp, bottom = 18.dp))
            Hauptknopf(uebersetzt("Beitreten"), freigegeben = !lage.arbeitet, gesperrtFlaeche = Stil.erhoeht) {
                lauf.launch { if (withContext(Dispatchers.IO) { app.kern.syncPlayBeitreten(g.id).await() }) schliessen() }
            }
        }
        Blattlinie()
        Blattabbruch(schliessen)
    }) { }
}

/**
 * Vorlage: die Auswahl „Läuft gerade" — erst, was auf anderen Geraeten laeuft („Hier weiterschauen"),
 * dann die Gruppen („Beitreten"). Zeichen 17 im Akzent, Titel und Unterzeile, die Handlung rechts.
 */
fun gemeinsamAuswahlOeffnen(app: SwiftlyAnwendung, weiterschauen: (Angebot) -> Unit) {
    app.blatt.value = Blattwunsch(uebersetzt("Läuft gerade"), emptyList(), null, inhalt = { schliessen ->
        val lauf = androidx.compose.runtime.rememberCoroutineScope()
        app.angebote.value.forEach { a ->
            Blattlinie()
            Auswahlzeile(uebernahmesymbol(a.art), a.geraet ?: uebersetzt("Gerät"), a.titelzeile, uebersetzt("Hier weiterschauen")) {
                schliessen(); weiterschauen(a)
            }
        }
        app.gemeinsam.value.offeneGruppen.forEach { g ->
            Blattlinie()
            Auswahlzeile(Zeichen.GruppeVoll, g.name, werSchaut(g), uebersetzt("Beitreten")) {
                lauf.launch { if (withContext(Dispatchers.IO) { app.kern.syncPlayBeitreten(g.id).await() }) schliessen() }
            }
        }
        Blattlinie()
        Blattabbruch(schliessen)
    }) { }
}

@Composable
private fun Auswahlzeile(symbol: Zeichen, titel: String, unter: String, handlung: String, tun: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 58.dp).druckzeile(tun).padding(horizontal = Stil.randAbstand),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Box(Modifier.width(26.dp), contentAlignment = Alignment.Center) { Symbol(symbol, 17.dp, farbe = Stil.akzent) }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(titel, style = Stil.listentitel, color = Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(unter, style = Stil.klein, color = Stil.schriftLeise, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Text(handlung, style = Stil.listentitel, color = Stil.akzent)
    }
}

/**
 * Vorlage: `Rueckwegstreifen` — „Filmabend verlassen · Wieder beitreten", Rückgängig statt Nachfrage.
 * Kapsel in `flaeche`, 34 ueber dem unteren Rand und 24 zur Seite, wie jeder Hinweis. Acht Sekunden
 * lang, die haelt das Paket.
 */
@Composable
fun Rueckwegstreifen(app: SwiftlyAnwendung, unten: androidx.compose.ui.unit.Dp = 34.dp) {
    val name = app.gemeinsam.value.zuletztVerlassen
    val gemerkt = remember { arrayOfNulls<String>(1) }
    if (name != null) gemerkt[0] = name
    val lauf = androidx.compose.runtime.rememberCoroutineScope()
    Box(Modifier.fillMaxSize().navigationBarsPadding(), contentAlignment = Alignment.BottomCenter) {
        AnimatedVisibility(name != null, enter = fadeIn(tween(220)), exit = fadeOut(tween(220))) {
            Row(Modifier.padding(bottom = unten, start = 24.dp, end = 24.dp)
                    .background(Stil.flaeche, RoundedCornerShape(50)).padding(start = 18.dp, end = 12.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(uebersetzt("%@ verlassen", gemerkt[0].orEmpty()), style = Stil.koerper.copy(fontSize = 13.sp),
                     color = Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                Box(Modifier.heightIn(min = 44.dp).antippen { lauf.launch { withContext(Dispatchers.IO) { app.kern.syncPlayWiederBeitreten().await() } } },
                    contentAlignment = Alignment.Center) {
                    Text(uebersetzt("Wieder beitreten"), style = Stil.koerper.copy(fontSize = 13.sp, fontWeight = FontWeight.SemiBold),
                         color = Stil.akzent)
                }
            }
        }
    }
}

// MARK: Im Player

/**
 * Vorlage: `Gruppenzeile` — „Filmabend · mit Paul und Tom" unter dem Titel, wo sonst Jahr und
 * Laufzeit stehen. Der Name traegt den Akzent: in einer Gruppe zu sein ist ein Zustand.
 */
@Composable
fun Gruppenzeile(name: String, mitWem: String, groesse: androidx.compose.ui.unit.TextUnit, farbe: androidx.compose.ui.graphics.Color = Stil.schriftLeise) {
    Row(Modifier.semantics(mergeDescendants = true) {}, verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Symbol(Zeichen.GruppeVoll, (groesse.value + 1).dp, farbe = Stil.akzent)
        Text(name, style = Stil.koerper.copy(fontSize = groesse, fontWeight = FontWeight.SemiBold), color = Stil.akzent, maxLines = 1)
        Text("· $mitWem", style = Stil.koerper.copy(fontSize = groesse), color = farbe, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** Vorlage: `Gruppenereignis` — kurz oben im Bild: wer kam, wer ging, warum der Film steht. */
@Composable
fun Gruppenereignis(e: Gemeinsamereignis, modifier: Modifier = Modifier, stil: androidx.compose.ui.text.TextStyle = Stil.koerper,
                    zeichen: androidx.compose.ui.unit.Dp = 15.dp, hoehe: androidx.compose.ui.unit.Dp = 44.dp) {
    Row(modifier.heightIn(min = hoehe).background(Stil.flaeche, RoundedCornerShape(50)).padding(horizontal = 16.dp)
            .semantics(mergeDescendants = true) { contentDescription = e.text },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Symbol(ereigniszeichen(e.art), zeichen, farbe = Stil.akzent)
        Text(e.text, style = stil, color = Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** Das Geraetezeichen eines Uebernahme-Angebots — dasselbe wie im Abzeichen. */
internal fun uebernahmesymbol(art: String): Zeichen = when (art) {
    "telefon" -> Zeichen.Telefon
    "tablet" -> Zeichen.Tablet
    "rechner" -> Zeichen.Laptop
    "fernseher" -> Zeichen.Fernseher
    else -> Zeichen.AbspielenFernseher
}

