package de.paulherter.swiftly

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import de.paulherter.swiftly.gemeinsam.Bewegung
import de.paulherter.swiftly.gemeinsam.Staerke
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.Symbol
import de.paulherter.swiftly.gemeinsam.Zeichen
import de.paulherter.swiftly.gemeinsam.bewegungReduziert
import de.paulherter.swiftly.gemeinsam.uebersetzt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.future.await
import org.json.JSONObject
import kotlin.math.roundToInt

/**
 * **Langer Druck auf eine Kachel — ueberall dasselbe Menue** (Vorlage `Sources/Shared/Kachelmenue.swift`).
 *
 * Vorher hatte nur „Weiterschauen" eines (ein Blatt mit gesehen/ungesehen), die uebrigen Kacheln keins.
 * Jetzt steht an jeder Film-, Serien- und Folgenkachel dieselbe Liste, mit einer Vorschau in der Form der
 * Kachel (dasselbe Bild, der Speicher antwortet sofort): Abspielen oder Fortsetzen, gesehen/ungesehen,
 * Laden, Gemeinsam schauen, bei „Weiterschauen" dazu „Zur Uebersicht" und „Aus Weiterschauen entfernen".
 * Die Handlungen selbst sind die, die es schon gibt.
 */
data class Kachelmenuewunsch(
    val id: String, val name: String, val typ: String,
    /** Dieselbe Adresse wie die Kachel — und dieselbe Form (`quer` 16:9, sonst 2:3). */
    val bild: String?, val quer: Boolean,
    /** Die leise Zeile unter dem Titel der Vorschau. */
    val zeile: String?,
    /** Die Kachel steht in „Weiterschauen". */
    val weiterschauen: Boolean = false,
    /** Wo die Kachel steht (Wurzelkoordinaten) — dort hebt die Vorschau ab. */
    val ursprung: Rect = Rect.Zero,
    /**
     * **Im Player: nur der Sehstand.** Ohne „Abspielen", „Laden" und „Gemeinsam schauen" — die
     * Zeile selbst startet die Folge schon, ein Ladeblatt ginge unter dem Player auf, und der
     * laufende Player muesste fuer „Gemeinsam" erst weichen. Dieselbe Regel wie
     * `Kachelmenue.imPlayer` auf Apple.
     */
    val imPlayer: Boolean = false,
    /** Nach einer Aenderung am Sehstand, damit die Seite nachzieht. */
    val nachher: (() -> Unit)? = null,
) {
    /** Filme, Serien und Folgen — Sammlungen, Personen und Ordner haben nichts abzuspielen oder abzuhaken. */
    val traegt: Boolean get() = typ in setOf("Movie", "Series", "Episode")
}

/** Wer ein Kachelmenue oeffnet — gesetzt von der Hauptansicht. Ohne: kein Menue. */
val LocalKachelmenue = staticCompositionLocalOf<((Kachelmenuewunsch) -> Unit)?> { null }

/**
 * **Tippen wie `antippen`, lange druecken oeffnet das Kachelmenue.** Der Rahmen der Kachel wird mitgefuehrt,
 * damit die Vorschau dort abhebt, wo man drueckt.
 */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
fun Modifier.kachelDruck(wunsch: () -> Kachelmenuewunsch?, tun: () -> Unit): Modifier = composed {
    val menue = LocalKachelmenue.current
    val quelle = remember { MutableInteractionSource() }
    val gedrueckt by quelle.collectIsPressedAsState()
    val druck = remember { Animatable(0f) }
    LaunchedEffect(gedrueckt) { if (gedrueckt) druck.snapTo(1f) else druck.animateTo(0f, Bewegung.loslassen()) }
    val ruhig = bewegungReduziert()
    val ruck = rememberRuck()
    val rahmen = remember { arrayOf(Rect.Zero) }
    onGloballyPositioned { rahmen[0] = it.boundsInRoot() }
        .graphicsLayer {
            val d = druck.value
            if (!ruhig) { val m = 1f - (1f - Bewegung.DRUCKMASS) * d; scaleX = m; scaleY = m }
            alpha = 1f - 0.15f * d
        }
        .combinedClickable(quelle, null, onClick = tun,
            onLongClick = if (menue == null) null else ({
                wunsch()?.takeIf { it.traegt }?.let { ruck(Ruck.Mittel); menue(it.copy(ursprung = rahmen[0])) }
            }))
}

/**
 * **Die Vorschau ueber dem Menue und das Menue selbst** — ueber allem, auch ueber der Leiste. Die Vorschau
 * hebt aus der Kachel ab (Feder wie `Stil.feder`), der Schleier dunkelt ab, ein Tipp daneben oder Zurueck
 * schliesst.
 */
@Composable
fun Kachelmenueauflage(app: SwiftlyAnwendung, wunsch: Kachelmenuewunsch?, oeffnen: (Ziel) -> Unit, schliessen: () -> Unit) {
    val gemerkt = remember { arrayOfNulls<Kachelmenuewunsch>(1) }
    wunsch?.let { gemerkt[0] = it }
    val w = gemerkt[0] ?: return
    val auf = remember { Animatable(0f) }
    val ruhig = bewegungReduziert()
    LaunchedEffect(wunsch != null) {
        // `Stil.feder`: response 0,35, Daempfung 0,9 — (2π / 0,35)² ≈ 322.
        auf.animateTo(if (wunsch != null) 1f else 0f,
            if (ruhig) Bewegung.blendeReduziert() else spring(dampingRatio = 0.9f, stiffness = 322f))
        if (wunsch == null) gemerkt[0] = null
    }
    if (wunsch == null && auf.value <= 0.001f) return
    BackHandler(enabled = wunsch != null) { schliessen() }
    fun handeln(was: String) {
        schliessen()
        kachelmenueHandeln(app, w, was, oeffnen)
    }
    val eintraege = kachelmenueEintraege(app, w)

    BoxWithConstraints(Modifier.fillMaxSize()) {
        val d = LocalDensity.current.density
        val a = auf.value
        // Fängt auch den Druck ab, damit dahinter nichts reagiert.
        Box(Modifier.fillMaxSize().graphicsLayer { alpha = a.coerceIn(0f, 1f) }.background(Color.Black.copy(alpha = 0.55f))
                .tippen { schliessen() })
        // Dasselbe Bild wie die Kachel, im selben Seitenverhaeltnis, nur groesser.
        val breite = if (w.quer) 320.dp else 220.dp
        val bildHoehe = if (w.quer) breite * 9f / 16f else breite * 3f / 2f
        val vorschauHoehe = bildHoehe + 62.dp
        val menueHoehe = (44 * eintraege.size).dp
        val gesamt = vorschauHoehe + 12.dp + menueHoehe
        val hoehe = maxHeight
        val oben = (w.ursprung.top / d).dp.coerceIn(56.dp, (hoehe - gesamt - 24.dp).coerceAtLeast(56.dp))
        val links = (maxWidth - breite) / 2
        // Aus der Kachel heraus: Lage und Groesse der Kachel am Anfang, das Ziel am Ende.
        val start = w.ursprung
        val zielL = links.value * d
        val zielO = oben.value * d
        val massAnfang = if (start.width > 0) start.width / (breite.value * d) else 0.9f
        Column(Modifier.offset { IntOffset(links.roundToPx(), oben.roundToPx()) }.width(breite)
                .graphicsLayer {
                    transformOrigin = TransformOrigin(0f, 0f)
                    if (!ruhig && start.width > 0) {
                        val m = massAnfang + (1f - massAnfang) * a
                        scaleX = m; scaleY = m
                        translationX = (start.left - zielL) * (1f - a)
                        translationY = (start.top - zielO) * (1f - a)
                    }
                    alpha = if (ruhig) a else (a * 3f).coerceIn(0f, 1f)
                }
                .clip(RoundedCornerShape(Stil.eckeFlaeche)).background(Stil.grund)) {
            AsyncImage(model = w.bild, contentDescription = null, contentScale = ContentScale.Crop,
                       modifier = Modifier.size(breite, bildHoehe))
            Column(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(w.name, style = Stil.listentitel, color = Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(w.zeile.orEmpty().ifEmpty { " " }, style = Stil.klein.copy(fontFeatureSettings = "tnum"), color = Stil.schriftLeise,
                     maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        // Das Menue darunter — waechst aus der Vorschau.
        val menueBreite = breite.coerceAtLeast(250.dp)
        Column(Modifier.offset { IntOffset(((maxWidth - menueBreite) / 2).roundToPx(), (oben + vorschauHoehe + 12.dp).roundToPx()) }.width(menueBreite)
                .graphicsLayer {
                    transformOrigin = TransformOrigin(0.5f, 0f)
                    val m = if (ruhig) 1f else 0.9f + 0.1f * a
                    scaleX = m; scaleY = m; alpha = a.coerceIn(0f, 1f)
                }
                .clip(RoundedCornerShape(Stil.eckeFlaeche)).background(Stil.erhoeht)) {
            eintraege.forEachIndexed { i, (wert, text, zeichen) ->
                if (i > 0) Box(Modifier.fillMaxWidth().height(1.dp).background(Stil.linie))
                Row(Modifier.fillMaxWidth().heightIn(min = 44.dp).druckzeile { handeln(wert) }.padding(horizontal = 16.dp),
                    verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                    Text(text, style = Stil.koerper, color = Stil.schrift, modifier = Modifier.weight(1f), maxLines = 1)
                    Spacer(Modifier.width(12.dp))
                    Symbol(zeichen, 17.dp, farbe = Stil.schrift, staerke = Staerke.Mittel)
                }
            }
        }
    }
}

/**
 * **Was das Menue anbietet** — Telefon und Fernseher gleich, ausser „Laden" (am Fernseher gibt es keine
 * Downloads). Wert, Text, Zeichen.
 */
internal fun kachelmenueEintraege(app: SwiftlyAnwendung, w: Kachelmenuewunsch): List<Triple<String, String, Zeichen>> = buildList {
    val istSerie = w.typ == "Series"
    if (!w.imPlayer) add(Triple("abspielen", if (!istSerie && w.weiterschauen) uebersetzt("Fortsetzen") else uebersetzt("Abspielen"), Zeichen.Abspielen))
    if (w.weiterschauen) add(Triple("uebersicht", uebersetzt("Zur Übersicht"), Zeichen.Info))
    // **Beide Eintraege immer, nicht der passende** — eine Folge, durch die man nur gesprungen ist, gilt
    // als angefangen; „ungesehen" holt sie aus „Weiterschauen".
    add(Triple("gesehen", uebersetzt("Als gesehen markieren"), Zeichen.HakenKreis))
    add(Triple("ungesehen", uebersetzt("Als ungesehen markieren"), Zeichen.Auge))
    if (!istSerie && !w.imPlayer && !app.istFernseher && app.einstellungen.downloadKnopfZeigen && app.downloads.posten(w.id) == null)
        add(Triple("laden", uebersetzt("Laden"), Zeichen.LadenKreis))
    if (!istSerie && !w.imPlayer && app.gemeinsam.value.darfAnlegen) add(Triple("gemeinsam", uebersetzt("Gemeinsam schauen"), Zeichen.Gruppe))
    if (w.weiterschauen) add(Triple("entfernen", uebersetzt("Aus Weiterschauen entfernen"), Zeichen.MinusKreis))
}

/**
 * **Die Handlungen** — die, die es schon gibt; sie ueberleben das Menue (es ist zu, bevor der Server
 * antwortet). Nach einer Aenderung am Sehstand frischen die Seiten auf (`sehstandGeaendert`).
 */
/**
 * **Eine Liste mit Haken und Balken frischt auf**, wenn die Wiedergabe endet oder ein Kachelmenue den Sehstand
 * aendert (`listenAuffrischen` / `nachholen` auf Apple). Seiten, die verdeckt sind, sind nicht gebaut und laden beim
 * Zurueckkommen ohnehin neu; nur die oberste Seite muss das hier tun. Der Stand beim Bauen zaehlt nicht.
 */
@androidx.compose.runtime.Composable
fun BeiSehstandaenderung(app: SwiftlyAnwendung, tun: suspend () -> Unit) {
    val zaehler = app.wiedergabeBeendet.intValue + app.sehstandGeaendert.intValue
    val anfang = androidx.compose.runtime.remember { zaehler }
    androidx.compose.runtime.LaunchedEffect(zaehler) { if (zaehler != anfang) tun() }
}

internal fun kachelmenueHandeln(app: SwiftlyAnwendung, w: Kachelmenuewunsch, was: String, oeffnen: (Ziel) -> Unit) {
    val nachher = w.nachher
    app.anwendungslauf.launch {
        when (was) {
            "abspielen" -> {
                // Frisch holen: die Stelle im Listeneintrag ist oft veraltet. Bei einer Serie die Folge, bei
                // der man steht.
                if (w.typ == "Series") {
                    val stand = runCatching { JSONObject(withContext(Dispatchers.IO) { app.kern.serie(w.id).await() }).optJSONObject("stand") }.getOrNull()
                    if (stand == null) { app.meldung.value = uebersetzt("Danach kommt nichts mehr."); return@launch }
                    app.spiel.value = Abspielwunsch(stand.getString("id"), if (stand.isNull("ab")) null else stand.getDouble("ab"))
                } else {
                    val frisch = weiterschauenWunsch(app, w.id)
                    if (frisch != null) app.spiel.value = frisch else oeffnen(Ziel(w.id, w.name, w.typ))
                }
            }
            "uebersicht" -> oeffnen(Ziel(w.id, w.name, w.typ))
            "gesehen", "ungesehen" -> {
                val grund = withContext(Dispatchers.IO) { app.kern.gesehen(w.id, was == "gesehen").await() }
                if (grund.isNotEmpty()) app.meldung.value = fehlertext(app, Exception(grund)) else { app.sehstandGeaendert.intValue++; nachher?.invoke() }
            }
            "entfernen" -> {
                val grund = withContext(Dispatchers.IO) { app.kern.ausWeiterschauenNehmen(w.id).await() }
                if (grund.isNotEmpty()) app.meldung.value = fehlertext(app, Exception(grund)) else { app.sehstandGeaendert.intValue++; nachher?.invoke() }
            }
            "laden" -> app.downloadsAnlegen(listOf(w.id), w.name)
            "gemeinsam" -> gemeinsamAnlegenOeffnen(app, w.id, w.name)
        }
    }
}

/**
 * **Am Fernseher als Tafel** (Menue-Taste oder lange OK) — dieselben Eintraege, der Fokus kehrt zur
 * Kachel zurueck (`Fokusmerker`).
 */
fun kachelmenueTafel(app: SwiftlyAnwendung, w: Kachelmenuewunsch, oeffnen: (Ziel) -> Unit) {
    if (!w.traegt) return
    val eintraege = kachelmenueEintraege(app, w)
    app.blatt.value = Blattwunsch(w.name, eintraege.map { Wahl(it.first, it.second) }, null,
        eintraege.associate { it.first to it.third }) { was -> kachelmenueHandeln(app, w, was, oeffnen) }
}
