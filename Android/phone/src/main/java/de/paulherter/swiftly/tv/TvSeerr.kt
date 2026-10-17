package de.paulherter.swiftly.tv

import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Strength
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.LocalBringIntoViewSpec
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.items
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
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import de.paulherter.swiftly.*
import de.paulherter.swiftly.SeerrTile as SeerrHit
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.asJson
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.util.Locale

/**
 * Mirrors `SeerrTile` in `Sources/tvOS/SeerrView.swift`: pale, and that is all the information:
 * whoever focuses it in the grid sees without reading a word that there is nothing to play. Public
 * because `TvSearch` (`TvPages.kt`) needs the same tile for its Seerr hits as the "Similar titles"
 * row here: one shape instead of two that drift apart.
 */
@Composable
fun SeerrTile(hit: SeerrHit, modifier: Modifier = Modifier, perform: () -> Unit) {
    Column(modifier.width(TvTheme.posterWidth)) {
        FocusArea(perform = perform) {
            Box(Modifier.size(TvTheme.posterWidth, TvTheme.posterHeight).clip(RoundedCornerShape(TvTheme.cornerTile)).background(Theme.area)) {
                AsyncImage(model = hit.poster, contentDescription = hit.title, contentScale = ContentScale.Crop,
                           modifier = Modifier.fillMaxSize().alpha(0.45f))
                if (hit.state != 5) {
                    val short = SeerrMark.shortWord(hit.state)
                    Row(Modifier.align(Alignment.BottomStart).padding(6.dp).clip(CircleShape).background(SeerrMark.color(hit.state))
                            .padding(horizontal = if (short != null) 8.dp else 6.dp, vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        Symbol(SeerrMark.symbol(hit.state), 10.dp, color = Theme.reason, strength = Strength.Semibold)
                        short?.let { Text(it, style = TvTheme.badge.copy(letterSpacing = 0.sp), color = Theme.reason) }
                    }
                }
            }
        }
        Text(hit.title, style = TvTheme.tile, color = Theme.fontQuiet, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 7.dp))
        Text(listOfNotNull(hit.year?.toString(), translated(if (hit.isSeries) "Serie" else "Film")).joinToString(" · "),
             style = TvTheme.small, color = Theme.fontVeryQuiet, maxLines = 1, modifier = Modifier.padding(top = 1.dp))
    }
}

/**
 * Mirrors `SeerrConnectView` on tvOS: address, username, password; Seerr asks Jellyfin itself
 * whether they are right. A page of its own rather than a row, because three fields need more room
 * than a settings row has (same reasoning as on tvOS). Same core functions as
 * `SeerrSettingsPage` on the phone (`seerrConnect`, `seerrApplies`), no logic of its own.
 */
@Composable
fun TvSeerrPage(app: SwiftlyApplication, back: () -> Unit) {
    var address by remember { mutableStateOf("") }
    var user by remember { mutableStateOf(app.username().takeIf { it != "?" }.orEmpty()) }
    var password by remember { mutableStateOf("") }
    var leftUp by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var carries by remember { mutableStateOf<Boolean?>(null) }
    /** "Advanced": custom headers for a service in front of Seerr; they are stored with the access afterwards. */
    val headers = de.paulherter.swiftly.rememberHeaderRow()
    val run = rememberCoroutineScope()
    val connected = app.seerrConnected.value
    LaunchedEffect(connected) {
        // As on the phone: an error means "does not hold", not a crash out of the effect.
        carries = if (!connected) null else try { withContext(Dispatchers.IO) { app.kern.seerrApplies().await() } }
                 catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (_: Exception) { false }
    }
    fun linkUp() {
        if (leftUp || address.isBlank() || user.isBlank() || password.isBlank()) return
        leftUp = true; error = null
        run.launch {
            try {
                app.seerrRemember(withContext(Dispatchers.IO) { app.kern.seerrConnect(address, user, password, headers.asJson()).await() })
                password = ""
            } catch (x: CancellationException) { throw x } catch (x: Exception) { error = errorString(app, x) }
            leftUp = false
        }
    }
    BackHandler(onBack = back)
    val inputField = firstFocus()

    Box(Modifier.fillMaxSize().background(Theme.reason), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.widthIn(max = 480.dp)) {
            Text("Seerr", style = TvTheme.titleLarge, color = Theme.font)
            Text(translated("Jellyseerr oder Overseerr. Dann zeigt die Suche auch Titel, die noch nicht auf deinem Server sind, und du kannst sie anfragen."),
                 style = TvTheme.body, color = Theme.fontQuiet, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 14.dp))
            if (connected) {
                Text(app.seerrAddress().orEmpty(), style = TvTheme.body, color = Theme.font, modifier = Modifier.padding(top = 26.dp))
                Text(translated(if (carries == true) "Sitzung aktiv" else "Sitzung abgelaufen"),
                     style = TvTheme.small, color = if (carries == true) Theme.accent else Theme.warning, modifier = Modifier.padding(top = 6.dp))
                TvButton(translated("Verbindung trennen"), modifier = Modifier.padding(top = 20.dp).focusRequester(inputField)) { app.seerrDisconnect(); password = "" }
            } else {
                Column(Modifier.padding(top = 26.dp).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    TvField(address, { address = it }, "seerr.example.de", Modifier.fillMaxWidth().focusRequester(inputField))
                    TvField(user, { user = it }, translated("Benutzername"), Modifier.fillMaxWidth())
                    TvField(password, { password = it }, translated("Passwort"), Modifier.fillMaxWidth(),
                           secret = true, imeAction = ImeAction.Done, keyboardAction = { linkUp() })
                    TvAdvanced(headers)
                }
                if (address.isNotBlank() && user.isNotBlank() && password.isNotBlank()) {
                    TvButton(translated(if (leftUp) "Verbinde…" else "Verbinden"), modifier = Modifier.padding(top = 18.dp)) { linkUp() }
                }
                error?.let {
                    Text(it, style = TvTheme.small, color = Theme.warning, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 12.dp))
                }
                Text(translated("Swiftly speichert dein Passwort nicht, nur die Anmeldung bei Seerr."),
                     style = TvTheme.small, color = Theme.fontVeryQuiet, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 14.dp))
            }
        }
    }
}

/**
 * Mirrors `SeerrDetailView` on tvOS: the same layout as `TvDetail` (`TvPages.kt`), except the
 * main button requests instead of playing. Season selection goes through `app.sheet` with multi
 * select, like `seasonSheet()` in `SeerrDetailPage` on the phone: the same component as any
 * other panel on the TV, no season panel of its own as on tvOS.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun TvSeerrDetailPage(app: SwiftlyApplication, target: Destination, open: (Destination) -> Unit, back: () -> Unit) {
    val k = app.seerrHit[target.id] ?: run { LaunchedEffect(Unit) { back() }; return }
    var detail by remember(target.id) { mutableStateOf<JSONObject?>(null) }
    var state by remember(target.id) { mutableIntStateOf(k.state) }
    var requestable by remember(target.id) { mutableStateOf(k.requestable) }
    var requested by remember(target.id) { mutableStateOf(false) }
    var confirmed by remember { mutableStateOf(false) }
    var running by remember { mutableStateOf(false) }
    // Mirrors `SeerrDetailView.error` on tvOS, where the reason sits next to the button; here via
    // `TvHintStrip` as on the phone. `anfragen()` used to swallow the reason entirely.
    var message by remember { mutableStateOf<String?>(null) }
    val run = rememberCoroutineScope()
    LaunchedEffect(target.id) {
        detail = runCatching { JSONObject(withContext(Dispatchers.IO) { app.kern.seerrDetail(k.art, k.id.toLong()).await() }) }.getOrNull()
        // The server knows better than the search hit from before (`SeerrDetail.state`).
        detail?.takeIf { it.has("stand") && !it.isNull("stand") }?.let { state = it.getInt("stand"); requestable = it.optBoolean("anfragbar") }
    }
    // Mirrors `SeerrView`: no 5-second timer. Reset only by button press, success (`anfragen`) or
    // leaving the page (own `remember`, dropped on leaving).

    fun askFor(seasons: List<Int>) {
        if (k.isSeries && seasons.isEmpty()) return
        running = true
        run.launch {
            val reason = withContext(Dispatchers.IO) { app.kern.seerrRequest(k.art, k.id.toLong(), seasons.joinToString(",")).await() }
            if (reason.isEmpty()) {
                // Read the state, do not assume it: if Seerr approves at once, the title is not "pending".
                runCatching { JSONObject(withContext(Dispatchers.IO) { app.kern.seerrDetail(k.art, k.id.toLong()).await() }) }.getOrNull()?.let { freshValue ->
                    detail = freshValue
                    if (freshValue.has("stand") && !freshValue.isNull("stand")) { state = freshValue.getInt("stand"); requestable = freshValue.optBoolean("anfragbar") }
                }
                if (requestable) { state = 2; requestable = false }
                requested = state == 2
            } else message = errorString(reason)
            running = false; confirmed = false
        }
    }
    fun seasonSheet() {
        val raw = detail?.optJSONArray("staffeln") ?: return
        val list = (0 until raw.length()).map { raw.getJSONObject(it) }
        app.sheet.value = SheetRequest(translated("Welche Staffeln?"),
            list.map { o ->
                val episodes = o.getInt("folgen")
                Choice(o.getInt("nummer").toString(), translated("Staffel %lld", o.getInt("nummer")) + if (episodes > 0) " · " + translated("%lld Folgen", episodes) else "")
            }, null, moreCompartment = emptySet(),
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
    val folks = d?.fieldList("besetzung") { WithAct(it.getString("id"), it.getString("name"), it.fieldText("rolle"), it.fieldText("bild")) }.orEmpty()
    val similar = d?.fieldList("aehnliches") { seerrTileRead(it) }.orEmpty()
    val main = firstFocus()

    Box(Modifier.fillMaxSize().background(Theme.reason)) {
        TvImageReason(k.backdrop)
        Backdrop(k.backdrop, Modifier.align(Alignment.TopEnd))
        // Section-wise scrolling like `TvDetail`, see `TvSectionPage` in `TvStart.kt`.
        // Without a request button the header is not focusable; then the first section keeps it in view
        // as far as possible (`NearHeader`).
        val firstArt = if (requestable && !requested) TvSectionKind.Flush else TvSectionKind.NearHeader
        TvSectionPage { a ->
                // Same header as `TvDetailHeader`: fixed zone 306.5 dp, block inside from 98 dp. Mirrors
                // `SeerrDetailView.header` (`.frame(height: heroHeightDetail)`, block at 140 + headerOffsetDetail).
                // The state sits in the details line instead of a line of its own below, so the button stays at
                // the height it has on every other page. With its own line under a 177 dp column it summed to
                // 132.5 header info + 32 state line + 56 button row = 220.5 dp, and the button row reached 40 dp
                // into the cast strip.
                Box(Modifier.tvSection(a, "kopf", TvSectionKind.Header).fillMaxWidth().height(306.5.dp)) {
                Column(Modifier.padding(start = TvTheme.edgePage, top = 98.dp)) {
                    HeaderInfo(k.title, null, secondaryLine, null, null, d?.fieldText("beschreibung")) {
                        // State and rating in the same capsule as direct play.
                        // 0 means "no rating" at TMDB, not zero stars.
                        TvProofRow(directPlayFlag = false, hint = null,
                                     rating = d?.fieldNumber("bewertung")?.takeIf { it > 0 }, sharing = null,
                                     own = Triple(SeerrMark.symbol(state), SeerrMark.word(state), SeerrMark.color(state)))
                    }
                    Row(Modifier.padding(top = 18.dp)) {
                        when {
                            requested -> Text(translated("Angefragt. Sobald sie freigegeben ist, lädt sie von selbst."), style = TvTheme.body, color = Theme.fontQuiet)
                            requestable -> TvButton(translated(when { running -> "Wird angefragt…"; confirmed -> "Wirklich anfragen?"; else -> "Anfragen" }),
                                    Glyph.Plus, Modifier.focusRequester(main)) {
                                when { k.isSeries -> seasonSheet(); confirmed -> askFor(emptyList()); else -> confirmed = true }
                            }
                            else -> Text(SeerrMark.hint(state), style = TvTheme.body, color = Theme.fontQuiet)
                        }
                    }
                }
                }
                if (folks.isNotEmpty()) TvStrip(translated("Besetzung"), Modifier.tvSection(a, "besetzung", firstArt)) {
                    items(folks, key = { it.id }) { p -> TvCast(p) {} }
                }
                if (similar.isNotEmpty()) TvStrip(translated("Ähnliche Titel"),
                        Modifier.tvSection(a, "aehnliche", if (folks.isEmpty()) firstArt else TvSectionKind.Flush)) {
                    items(similar, key = { it.key }) { t ->
                        SeerrTile(t) { app.seerrHit[t.key] = t; open(Destination(t.key, t.title, "Seerrtitel")) }
                    }
                }
                Spacer(Modifier.height(40.dp))
        }
        message?.let { text ->
            TvHintStrip(text, Modifier.align(Alignment.TopCenter).padding(top = 74.dp)) { message = null }
        }
    }
}
