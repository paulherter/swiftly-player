package de.paulherter.swiftly

import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Strength
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import de.paulherter.swiftly.shared.InputField
import de.paulherter.swiftly.shared.PrimaryButton
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale

/** A Seerr result: `state` is Seerr's own number, `requestable` the rule from the package. */
data class SeerrTile(val id: Int, val art: String, val title: String, val year: Int?, val poster: String?,
                       val backdrop: String?, val state: Int, val requestable: Boolean) {
    val isSeries: Boolean get() = art == "tv"
    val key: String get() = "$art:$id"
}

fun seerrTileRead(o: JSONObject) = SeerrTile(o.getInt("id"), o.getString("art"), o.getString("titel"),
    if (o.isNull("jahr")) null else o.getInt("jahr"), o.fieldText("plakat"), o.fieldText("kulisse"), o.getInt("stand"), o.optBoolean("anfragbar"))

fun seerrTilesRead(json: String): List<SeerrTile> =
    JSONArray(json).let { a -> (0 until a.length()).map { seerrTileRead(a.getJSONObject(it)) } }

/**
 * Mirrors `SeerrMark`: **one table** for tile and detail page; there used to be two and they
 * drifted apart. Two words per state on purpose: the detail page's long sentence does not fit at
 * 112 pt. "Requested" instead of "Loading": the request is through, no bytes are flowing.
 */
object SeerrMark {
    private val amber = Color(0.85f, 0.60f, 0.17f)
    private val blue = Color(0.29f, 0.56f, 0.85f)

    fun color(state: Int): Color = when (state) { 2 -> amber; 3 -> blue; else -> Theme.accent }

    fun symbol(state: Int): Glyph = when (state) {
        2 -> Glyph.Clock
        3 -> Glyph.LoadCircle
        4 -> Glyph.Contrast
        5 -> Glyph.Checkmark
        else -> Glyph.PlusCircle
    }

    fun word(state: Int) = translated(when (state) {
        2 -> "Wartet auf Freigabe"; 3 -> "Angefragt"; 4 -> "Teilweise vorhanden"; 5 -> "Auf deinem Server"
        else -> "Nicht auf deinem Server"
    })

    fun shortWord(state: Int): String? = when (state) {
        2 -> translated("wartet"); 3 -> translated("angefragt"); 4 -> translated("teilweise"); else -> null
    }

    fun hint(state: Int) = translated(when (state) {
        2 -> "Deine Anfrage liegt beim Verwalter des Servers. Du musst nichts weiter tun."
        3 -> "Deine Anfrage ist durch. Der Titel erscheint von selbst in deiner Bibliothek."
        else -> "Dieser Titel liegt bereits auf deinem Server."
    })
}

/**
 * Mirrors `SeerrTile`: **faded, and that is the whole message**: someone scrolling fast sees
 * without reading that there is nothing to play. The badge on it stays fully opaque.
 */
@Composable
fun SeerrTileView(k: SeerrTile, modifier: Modifier = Modifier, perform: () -> Unit) {
    Column(modifier.reveal().tapOn(perform), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.fillMaxWidth().aspectRatio(2f / 3f).clip(RoundedCornerShape(Theme.cornerTile)).background(Theme.area)) {
            AsyncImage(model = k.poster, contentDescription = k.title, contentScale = ContentScale.Crop,
                       modifier = Modifier.fillMaxSize().alpha(0.45f))
            if (k.state != 5) {
                val short = SeerrMark.shortWord(k.state)
                Row(Modifier.align(Alignment.BottomStart).padding(6.dp).clip(CircleShape).background(SeerrMark.color(k.state))
                        .padding(horizontal = if (short != null) 7.dp else 5.dp, vertical = 3.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                    Symbol(SeerrMark.symbol(k.state), 10.dp, color = Theme.reason, strength = Strength.Semibold)
                    short?.let { Text(it, style = Theme.badge.copy(letterSpacing = 0.sp), color = Theme.reason) }
                }
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(k.title, style = Theme.tile, color = Theme.fontQuiet, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(listOfNotNull(k.year?.toString(), translated(if (k.isSeries) "Serie" else "Film")).joinToString(" · "),
                 style = Theme.small, color = Theme.fontVeryQuiet, maxLines = 1)
        }
    }
}

/** Heading of a result block with count, e.g. "On your server", "Can be requested". */
@Composable
fun BlockTitle(title: String, count: Int, modifier: Modifier = Modifier) {
    // `blockTitle`: heading 20 `schriftLeise`, count badge on the right, 16 above, 10 below.
    Row(modifier.fillMaxWidth().padding(top = 16.dp, bottom = 10.dp), verticalAlignment = Alignment.Bottom) {
        Text(title, style = Theme.rail,
             color = Theme.fontQuiet, modifier = Modifier.weight(1f))
        if (count > 0) CountMark(count)
    }
}

/**
 * Mirrors `SeerrSettingsView`. Sign-in with Jellyfin's own name and password; **the password
 * is not stored**, only the session Seerr issues, encrypted, per Jellyfin server. "Disconnect",
 * not "Sign out": the account at Seerr stays untouched.
 */
@Composable
fun SeerrSettingsPage(app: SwiftlyApplication, back: () -> Unit) {
    var address by remember { mutableStateOf("") }
    var user by remember { mutableStateOf(app.username().takeIf { it != "?" }.orEmpty()) }
    var password by remember { mutableStateOf("") }
    var leftUp by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var carries by remember { mutableStateOf<Boolean?>(null) }
    /** "Advanced": custom headers for a service in front of Seerr. They end up in the credentials, i.e. the vault. */
    val headers = rememberHeaderRow()
    val run = rememberCoroutineScope()
    val connected = app.seerrConnected.value
    LaunchedEffect(connected) {
        // No network or broken response: "does not hold" instead of a crash out of the effect.
        carries = if (!connected) null else try { withContext(Dispatchers.IO) { app.kern.seerrApplies().await() } }
                 catch (e: CancellationException) { throw e } catch (_: Exception) { false }
    }
    fun linkUp() {
        if (leftUp || address.isBlank() || user.isBlank() || password.isBlank()) return
        leftUp = true; error = null
        run.launch {
            try {
                app.seerrRemember(withContext(Dispatchers.IO) { app.kern.seerrConnect(address, user, password, headers.asJson()).await() })
                password = ""
            } catch (e: CancellationException) { throw e } catch (e: Exception) { error = errorString(app, e) }
            leftUp = false
        }
    }

    SettingPage("Seerr", back) {
        Text(translated("Jellyseerr oder Overseerr. Dann zeigt die Suche auch Titel, die noch nicht auf deinem Server sind, und du kannst sie anfragen."),
             style = Theme.body.copy(lineHeight = 21.sp), color = Theme.fontQuiet, modifier = Modifier.padding(horizontal = Theme.edgeSpacing))
        if (connected) {
            SettingGroup(translated("Verbunden")) {
                ValueRow(Glyph.Chain, app.seerrAddress().orEmpty(),
                          value = when (carries) { true -> translated("Aktiv"); false -> translated("Sitzung abgelaufen"); null -> null })
                SeparatorLine()
                ValueRow(Glyph.CrossCircle, translated("Verbindung trennen")) { app.seerrDisconnect(); password = "" }
            }
        } else {
            // `formSheet`: 26 below the intro, fields 12 apart, error 14 above in `error`, button 20, hint 12.
            Column(Modifier.padding(horizontal = Theme.edgeSpacing).padding(top = 26.dp)) {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    InputField(address, { address = it }, Glyph.Chain, "seerr.example.de", address = true)
                    InputField(user, { user = it }, Glyph.Person, translated("Benutzername"))
                    InputField(password, { password = it }, Glyph.Padlock, translated("Passwort"), secret = true) { linkUp() }
                    AdvancedSection(headers)
                }
                error?.let { Text(it, style = Theme.small, color = Theme.error, modifier = Modifier.padding(top = 14.dp)) }
                // No disabled button: it appears as soon as everything is there.
                when {
                    leftUp -> Text(translated("Verbinde…"), style = Theme.body, color = Theme.fontQuiet, modifier = Modifier.padding(top = 20.dp))
                    address.isNotBlank() && user.isNotBlank() && password.isNotBlank() ->
                        PrimaryButton(translated("Verbinden"), modifier = Modifier.padding(top = 20.dp)) { linkUp() }
                }
                Text(translated("Swiftly speichert dein Passwort nicht, nur die Anmeldung bei Seerr."),
                     style = Theme.small.copy(lineHeight = 17.sp), color = Theme.fontVeryQuiet, modifier = Modifier.padding(top = 12.dp))
            }
        }
    }
}

private val confirmations = listOf("Nochmal, dann läuft’s", "Nochmal — ab die Post", "Nochmal, dann frag ich", "Nochmal, her damit")

/**
 * Mirrors `SeerrDetailView`: **the same layout as the real title page**; three separate versions
 * used to drift apart. Requesting takes two steps: the second tap is the order, the confirmation
 * falls back after five seconds. For a series the season sheet is the second step; nothing is
 * preselected, and an empty selection is never sent, since it would mean "all".
 */
@Composable
fun SeerrDetailPage(app: SwiftlyApplication, target: Destination, open: (Destination) -> Unit, back: () -> Unit) {
    val k = app.seerrHit[target.id] ?: run { LaunchedEffect(Unit) { back() }; return }
    var detail by remember(target.id) { mutableStateOf<JSONObject?>(null) }
    var state by remember(target.id) { mutableIntStateOf(k.state) }
    var requestable by remember(target.id) { mutableStateOf(k.requestable) }
    var requested by remember(target.id) { mutableStateOf(false) }
    var confirmed by remember { mutableStateOf(false) }
    var version by remember { mutableIntStateOf(0) }
    var running by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    val run = rememberCoroutineScope()
    val jerk = rememberJerk()
    LaunchedEffect(target.id) {
        detail = runCatching { JSONObject(withContext(Dispatchers.IO) { app.kern.seerrDetail(k.art, k.id.toLong()).await() }) }.getOrNull()
        // The server knows better than the search result from before (`SeerrDetail.state`).
        detail?.takeIf { it.has("stand") && !it.isNull("stand") }?.let { state = it.getInt("stand"); requestable = it.optBoolean("anfragbar") }
    }
    LaunchedEffect(confirmed) { if (confirmed) { delay(5000); confirmed = false } }

    fun askFor(seasons: List<Int>) {
        if (k.isSeries && seasons.isEmpty()) return
        running = true
        run.launch {
            val reason = withContext(Dispatchers.IO) { app.kern.seerrRequest(k.art, k.id.toLong(), seasons.joinToString(",")).await() }
            if (reason.isEmpty()) {
                // Read the state, do not assume: if Seerr approves at once, the title is not "waiting".
                runCatching { JSONObject(withContext(Dispatchers.IO) { app.kern.seerrDetail(k.art, k.id.toLong()).await() }) }.getOrNull()?.let { freshValue ->
                    detail = freshValue
                    if (freshValue.has("stand") && !freshValue.isNull("stand")) { state = freshValue.getInt("stand"); requestable = freshValue.optBoolean("anfragbar") }
                }
                if (requestable) { state = 2; requestable = false }
                requested = state == 2
            } else message = errorString(reason)
            running = false
            confirmed = false
        }
    }
    fun seasonSheet() {
        val raw = detail?.optJSONArray("staffeln") ?: return
        val list = (0 until raw.length()).map { raw.getJSONObject(it) }
        app.sheet.value = SheetRequest(translated("Welche Staffeln?"),
            list.map { o ->
                val episodes = o.getInt("folgen")
                Choice(o.getInt("nummer").toString(),
                     translated("Staffel %lld", o.getInt("nummer")), if (episodes > 0) "· " + translated("%lld Folgen", episodes) else null)
            },
            null,
            moreCompartment = emptySet(),
            locked = list.filter { !it.optBoolean("anfragbar") }
                .associate { it.getInt("nummer").toString() to translated(if (it.getInt("stand") == 5) "vorhanden" else "unterwegs") },
            completionText = { n -> if (n == 0) translated("Staffel wählen") else translated("%lld anfragen", n) },
            completion = { amount -> askFor(amount.map { it.toInt() }.sorted()) }) {}
    }

    val d = detail
    val secondaryLine = listOfNotNull(
        k.year?.toString(),
        if (k.isSeries) d?.optJSONArray("staffeln")?.length()?.takeIf { it > 0 }?.let { n -> if (n == 1) translated("1 Staffel") else translated("%lld Staffeln", n) }
        else d?.fieldNumber("laufzeit")?.toInt()?.takeIf { it > 0 }?.let { translated("%lld Min.", it) },
        d?.fieldTexts("genres")?.takeIf { it.isNotEmpty() }?.joinToString(", "),
    ).joinToString(" · ").ifEmpty { translated(if (k.isSeries) "Serie" else "Film") }
    val scroll = rememberScrollState()
    val density = LocalDensity.current.density

    Box(Modifier.fillMaxSize().background(Theme.reason)) {
        Column(Modifier.fillMaxSize().verticalScroll(scroll)) {
            Hero(k.backdrop, k.title, secondaryLine)
            Column(Modifier.padding(horizontal = Theme.edgeSpacing).padding(top = 14.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                // The same `ProofRow` as on the title page, with the state as free-form evidence.
                // 0 means "no rating" at TMDB, not zero stars.
                ProofRow(true, false, false, null, d?.fieldNumber("bewertung")?.takeIf { it > 0 }, null,
                           own = Triple(SeerrMark.symbol(state), SeerrMark.word(state), SeerrMark.color(state)))
                Column(verticalArrangement = Arrangement.spacedBy(9.dp)) {
                    when {
                        requested -> HintBox(translated("Angefragt. Sobald sie freigegeben ist, lädt sie von selbst."))
                        // White like "Resume", not accent: the badge above already carries the color. "Really request?"
                        // did not read as "press again". Every variant starts with "Nochmal"; one is drawn at random on
                        // the first tap, never the same twice.
                        requestable -> PlayButton(if (confirmed) Glyph.Checkmark else Glyph.Plus,
                            when { running -> translated("Wird angefragt…"); confirmed -> translated(confirmations[version]); else -> translated("Anfragen") },
                            an = !running, main = true) {
                            jerk(Jerk.Medium)
                            when {
                                k.isSeries -> seasonSheet()
                                confirmed -> askFor(emptyList())
                                else -> { version = (confirmations.indices - version).random(); confirmed = true }
                            }
                        }
                        else -> HintBox(SeerrMark.hint(state))
                    }
                }
                d?.fieldText("beschreibung")?.let { CollapsibleText(it) }
            }
            val folks = d?.fieldList("besetzung") { WithAct(it.getString("id"), it.getString("name"), it.fieldText("rolle"), it.fieldText("bild")) }.orEmpty()
            if (folks.isNotEmpty()) Segment(translated("Besetzung"), 14.dp) {
                tilesWithKey(folks.take(12), { it.id }) { p -> CastTile(p) }
            }
            val similar = d?.fieldList("aehnliches") { seerrTileRead(it) }.orEmpty()
            if (similar.isNotEmpty()) Segment(translated("Ähnliche Titel"), Theme.tileSpacing) {
                tilesWithKey(similar, { it.key }) { t ->
                    SeerrTileView(t, Modifier.width(Theme.tileWidth)) { app.seerrHit[t.key] = t; open(Destination(t.key, t.title, "Seerrtitel")) }
                }
            }
            Spacer(Modifier.navigationBarsPadding().height(30.dp))
        }
        DetailHeader(k.title, { ((scroll.value / density - 150f) / 70f).coerceIn(0f, 1f) }, back)
        HintStrip(message, Modifier.align(Alignment.BottomCenter)) { message = null }
    }
}

@Composable
private fun HintBox(text: String) {
    Text(text, style = Theme.body.copy(lineHeight = 21.sp), color = Theme.fontQuiet,
         modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(Theme.corner)).background(Theme.area).padding(14.dp))
}
