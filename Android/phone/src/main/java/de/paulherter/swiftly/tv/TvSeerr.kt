package de.paulherter.swiftly.tv

import androidx.compose.ui.graphics.graphicsLayer
import de.paulherter.swiftly.sheetListFade
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
import androidx.compose.ui.focus.FocusRequester
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
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.asJson
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import de.paulherter.swiftly.rustcore.PrimaryKind
import de.paulherter.swiftly.rustcore.SeerrRequestResult
import de.paulherter.swiftly.rustcore.SeerrSheetInfo
import de.paulherter.swiftly.rustcore.SeerrTitleInfo
import de.paulherter.swiftly.rustcore.SeerrTitleScreen
import de.paulherter.swiftly.rustcore.SetupEntry
import de.paulherter.swiftly.rustcore.SignInMethod
import de.paulherter.swiftly.rustcore.TitleLoad
import org.json.JSONObject
import java.util.Locale

/**
 * Mirrors `SeerrConnectView` on tvOS: draws the core's `SeerrSetupScreen`, the same screen object and host (`SeerrSetupHost`) as
 * `SeerrSettingsPage` on the phone, so the address question, the ways in (Jellyfin, own Seerr account, Plex), the busy line and
 * every failure sentence are the core's. A page of its own rather than a row, because the fields need more room than a settings
 * row has (same reasoning as on tvOS).
 */
@Composable
fun TvSeerrPage(app: SwiftlyApplication, back: () -> Unit) {
    val host = rememberSeerrSetup(app)
    var address by remember { mutableStateOf("") }
    var user by remember { mutableStateOf(app.username().takeIf { it != "?" }.orEmpty()) }
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    /** "Advanced": custom headers for a service in front of Seerr; they are stored with the access afterwards. */
    val headers = de.paulherter.swiftly.rememberHeaderRow()
    val info = host.info
    val connected = host.connected
    fun signIn() = host.signIn(address, headers.asJson(), user, email, password) { password = "" }
    BackHandler(onBack = back)
    // The first element of whatever the core shows (field, method, or "disconnect") takes focus once the page is there.
    val first = remember { FocusRequester() }
    LaunchedEffect(info != null, connected) { if (info != null) { delay(2 * TvTheme.focusDeadline); runCatching { first.requestFocus() } } }
    var taken = false
    fun firstOnce(): Modifier = if (taken) Modifier else { taken = true; Modifier.focusRequester(first) }
    // "Next" on the keyboard goes to the next FIELD, not to the method buttons that sit between the fields.
    val userFocus = remember { FocusRequester() }
    val passwordFocus = remember { FocusRequester() }
    fun toField(target: FocusRequester) { runCatching { target.requestFocus() } }

    Box(Modifier.fillMaxSize().background(Theme.reason), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.widthIn(max = 480.dp)) {
            Text("Seerr", style = TvTheme.titleLarge, color = Theme.font)
            Text(translated("Jellyseerr oder Overseerr. Dann zeigt die Suche auch Titel, die noch nicht auf deinem Server sind, und du kannst sie anfragen."),
                 style = TvTheme.body, color = Theme.fontQuiet, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 14.dp))
            if (info == null) {
                Text(translated("Verbinde…"), style = TvTheme.body, color = Theme.fontQuiet, modifier = Modifier.padding(top = 26.dp))
            } else if (connected) {
                Text(app.seerrAddress().orEmpty(), style = TvTheme.body, color = Theme.font, modifier = Modifier.padding(top = 26.dp))
                // The core only reports "connected" after it checked the session.
                Text(translated("Aktiv"), style = TvTheme.small, color = Theme.accent, modifier = Modifier.padding(top = 6.dp))
                TvButton(translated("Verbindung trennen"), modifier = Modifier.padding(top = 20.dp).then(firstOnce())) { host.disconnect { password = "" } }
            } else {
                Column(Modifier.padding(top = 26.dp).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    info.notSetUp?.let { Text(it, style = TvTheme.body, color = Theme.fontQuiet, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth()) }
                    when (info.entry) {
                        SetupEntry.ASK_ADDRESS -> TvField(address, { address = it }, "seerr.example.de", Modifier.fillMaxWidth().then(firstOnce()),
                                                          keyboardType = androidx.compose.ui.text.input.KeyboardType.Uri, next = { toField(userFocus) })
                        SetupEntry.KNOWN_ADDRESS -> {
                            Text(info.address.orEmpty(), style = TvTheme.body, color = Theme.font, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
                            if (info.canEditAddress) TvButton(translated("Adresse ändern"), modifier = firstOnce()) { host.editAddress() }
                        }
                        SetupEntry.NOT_SET_UP -> {}
                    }
                    if (info.entry != SetupEntry.NOT_SET_UP) {
                        if (info.methods.size > 1) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            info.methods.forEachIndexed { n, m ->
                                TvButton(m.title, height = 52.dp, active = host.method == m.method,
                                         modifier = if (n == 0) firstOnce() else Modifier) { host.method = m.method }
                            }
                        }
                        val chosen = info.methods.firstOrNull { it.method == host.method } ?: info.methods.firstOrNull()
                        if (chosen != null) {
                            val toPassword: (() -> Unit)? = if (chosen.needsPassword) ({ toField(passwordFocus) }) else null
                            if (chosen.method == SignInMethod.LOCAL) TvField(email, { email = it }, chosen.userLabel ?: translated("E-Mail"),
                                                                          Modifier.fillMaxWidth().focusRequester(userFocus).then(firstOnce()),
                                                                          keyboardType = androidx.compose.ui.text.input.KeyboardType.Email, next = toPassword)
                            else if (chosen.method == SignInMethod.JELLYFIN) TvField(user, { user = it }, chosen.userLabel ?: translated("Benutzername"),
                                                                          Modifier.fillMaxWidth().focusRequester(userFocus).then(firstOnce()), next = toPassword)
                            if (chosen.needsPassword) TvField(password, { password = it }, translated("Passwort"),
                                                              Modifier.fillMaxWidth().focusRequester(passwordFocus).then(firstOnce()),
                                                              secret = true, imeAction = ImeAction.Done, keyboardAction = { signIn() })
                        }
                        if (info.entry == SetupEntry.ASK_ADDRESS) TvAdvanced(headers)
                    }
                }
                val ready = info.entry != SetupEntry.NOT_SET_UP && info.methods.isNotEmpty() && (info.entry != SetupEntry.ASK_ADDRESS || address.isNotBlank()) && password.isNotBlank()
                // No disabled button: it appears as soon as everything is there.
                when {
                    info.busy != null -> Text(info.busy.orEmpty(), style = TvTheme.body, color = Theme.fontQuiet, modifier = Modifier.padding(top = 18.dp))
                    ready -> TvButton(info.methods.firstOrNull { it.method == host.method }?.title ?: translated("Verbinden"), modifier = Modifier.padding(top = 18.dp)) { signIn() }
                }
                info.error?.let {
                    Text(it, style = TvTheme.small, color = Theme.warning, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 12.dp))
                }
                Text(translated("Swiftly speichert dein Passwort nicht, nur die Anmeldung bei Seerr."),
                     style = TvTheme.small, color = Theme.fontVeryQuiet, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 14.dp))
            }
        }
    }
}

/**
 * Mirrors `SeerrDetailView` on tvOS: draws the core's `SeerrTitleScreen` in the layout of `TvDetail` (`TvPages.kt`). The state
 * line, the one primary button, the quota and every sentence come from the core, the same screen object the phone draws;
 * this only places them for the remote. The request goes through a panel on the right edge (`tvSeerrSheetShow`).
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun TvSeerrDetailPage(app: SwiftlyApplication, target: Destination, open: (Destination) -> Unit, back: () -> Unit) {
    val art = target.id.substringBefore(':')
    val tmdb = target.id.substringAfter(':').toLongOrNull()
    if (tmdb == null) { LaunchedEffect(Unit) { back() }; return }
    var screen by remember(target.id) { mutableStateOf<SeerrTitleScreen?>(null) }
    var info by remember(target.id) { mutableStateOf<SeerrTitleInfo?>(null) }
    var retry by remember { mutableIntStateOf(0) }
    val run = rememberCoroutineScope()
    LaunchedEffect(target.id, retry) {
        val s = withContext(Dispatchers.IO) { app.seerr.title(art, tmdb) }
        screen = s
        info = withContext(Dispatchers.IO) { try { s.load() } catch (e: CancellationException) { throw e } catch (_: Exception) { s.info() } }
    }
    val i = info
    val ready = i?.load == TitleLoad.CONTENT
    // Debug builds only (`testSheet`): the request panel opens by itself once the page stands.
    LaunchedEffect(i?.load) {
        if (!de.paulherter.swiftly.BuildConfig.DEBUG || !app.debugSheet || i?.load != TitleLoad.CONTENT || i.primary.kind != PrimaryKind.REQUEST) return@LaunchedEffect
        app.debugSheet = false
        kotlinx.coroutines.delay(1500)
        screen?.let { s -> tvSeerrSheetShow(app, s, null) { info = s.info() } }
    }
    val main = firstFocus(ready)
    val backdrop = tmdbImage(i?.backdrop ?: i?.poster, 1280)
    BackHandler(onBack = back)

    Box(Modifier.fillMaxSize().background(Theme.reason)) {
        if (i != null && i.load != TitleLoad.LOADING && !ready) {
            Column(Modifier.align(Alignment.Center).widthIn(max = 520.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(i.error ?: translated("Seerr antwortet gerade nicht."), style = TvTheme.body, color = Theme.fontQuiet, textAlign = TextAlign.Center)
                Text(translated("Deine Bibliothek läuft normal."), style = TvTheme.small, color = Theme.fontVeryQuiet, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 6.dp))
                TvButton(translated("Erneut versuchen"), modifier = Modifier.padding(top = 20.dp).focusRequester(main)) { retry++ }
            }
        }
        if (i != null && ready) {
            TvImageReason(backdrop)
            Backdrop(backdrop, Modifier.align(Alignment.TopEnd))
            // Without a request button the header is not focusable; then the first section keeps it in view as far as possible.
            val firstArt = if (i.primary.kind == PrimaryKind.REQUEST) TvSectionKind.Flush else TvSectionKind.NearHeader
            TvSectionPage { a ->
                Box(Modifier.tvSection(a, "kopf", TvSectionKind.Header).fillMaxWidth().height(306.5.dp)) {
                    Column(Modifier.padding(start = TvTheme.edgePage, top = 98.dp)) {
                        HeaderInfo(i.title, null, i.secondaryLine, null, null, i.overview) {
                            TvProofRow(directPlayFlag = false, hint = null, rating = i.rating?.takeIf { it > 0 }, sharing = null,
                                       own = i.badge?.let { b -> Triple(SeerrBadgeMark.glyph(b.kind), b.line, SeerrBadgeMark.color(b.kind)) })
                        }
                        Row(Modifier.padding(top = 18.dp)) {
                            when (i.primary.kind) {
                                PrimaryKind.REQUEST -> TvButton(i.primary.text, Glyph.Plus, Modifier.focusRequester(main)) {
                                    screen?.let { s -> tvSeerrSheetShow(app, s, null) { info = s.info() } }
                                }
                                PrimaryKind.BUSY -> Text(i.primary.text, style = TvTheme.body, color = Theme.fontQuiet)
                                PrimaryKind.REQUESTED, PrimaryKind.LOCKED -> Text(i.primary.text, style = TvTheme.body, color = Theme.fontQuiet)
                                PrimaryKind.HIDDEN -> {}
                            }
                        }
                    }
                }
                if (i.cast.isNotEmpty()) TvStrip(translated("Besetzung"), Modifier.tvSection(a, "besetzung", firstArt)) {
                    items(i.cast.take(12), key = { it.name + it.role }) { p -> TvCast(WithAct(p.name, p.name, p.role, tmdbImage(p.image, 185))) { open(seerrPersonTarget(p, i.title)) } }
                }
                if (i.similar.isNotEmpty()) TvStrip(translated("Ähnliche Titel"),
                        Modifier.tvSection(a, "aehnliche", if (i.cast.isEmpty()) firstArt else TvSectionKind.Flush)) {
                    items(i.similar, key = { it.key }) { t ->
                        TvTile(tmdbImage(t.poster, 342), t.title, t.badge?.word ?: t.year?.toString(), opacity = 0.45f) { run.launch { openSeerrCard(app, t, open) } }
                    }
                }
                Spacer(Modifier.height(40.dp))
            }
        }
    }
}

/** Opens the request panel on the right edge: the core's rows, quota line, choices and button, drawn as remote rows. */
fun tvSeerrSheetShow(app: SwiftlyApplication, screen: SeerrTitleScreen, season: Long?, afterwards: () -> Unit) {
    val first = screen.openSheet(season)
    app.sheet.value = SheetRequest(first.title, emptyList(), null, content = { close -> TvSeerrSheetContent(screen, first, close, afterwards) }) {}
}

@Composable
private fun ColumnScope.TvSeerrSheetContent(screen: SeerrTitleScreen, first: SeerrSheetInfo, close: () -> Unit, afterwards: () -> Unit) {
    var sheet by remember { mutableStateOf(first) }
    var sending by remember { mutableStateOf(false) }
    val run = rememberCoroutineScope()
    val start = remember { FocusRequester() }
    LaunchedEffect(Unit) { sheet = withContext(Dispatchers.IO) { try { screen.loadSheet() } catch (e: CancellationException) { throw e } catch (_: Exception) { screen.info().sheet } } }
    LaunchedEffect(Unit) { kotlinx.coroutines.delay(TvTheme.focusDeadline); runCatching { start.requestFocus() } }
    val firstOpen = sheet.rows.indexOfFirst { it.selectable }
    val list = rememberScrollState()
    Column(Modifier.heightIn(max = 380.dp).sheetListFade(list).verticalScroll(list)) {
        sheet.rows.forEachIndexed { n, r ->
            TvRow(r.title + (r.episodes?.let { " · $it" } ?: ""), right = if (r.selectable) null else r.badge.line, checkmark = r.selected,
                  modifier = if (n == firstOpen) Modifier.focusRequester(start) else Modifier) { if (r.selectable) sheet = screen.toggle(r.number) }
        }
        sheet.fourK?.let { f -> TvRow(f.label, checkmark = f.on) { sheet = screen.setFourK(!f.on) } }
        sheet.quality?.let { q ->
            TvRow(q.label, right = q.value) {
                val at = q.options.indexOfFirst { it.id == q.selected }
                q.options.getOrNull((at + 1) % q.options.size.coerceAtLeast(1))?.let { sheet = screen.chooseQuality(it.id.toLong()) }
            }
        }
        sheet.folder?.let { f ->
            TvRow(f.label, right = f.value) {
                val at = f.options.indexOfFirst { it.id == f.selected }
                f.options.getOrNull((at + 1) % f.options.size.coerceAtLeast(1))?.let { sheet = screen.chooseFolder(it.id) }
            }
        }
    }
    // The quota line's space is reserved: it fades in inside it, so the button below never moves.
    Text(sheet.quotaLine ?: " ", style = TvTheme.small, color = if (sheet.quotaWarning) Theme.warning else Theme.fontQuiet,
         modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp).graphicsLayer { alpha = if (sheet.quotaLine == null) 0f else 1f })
    sheet.error?.let { Text(it, style = TvTheme.small, color = Theme.warning, modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) }
    TvRow(if (sending) translated("Wird angefragt…") else sheet.primary.text, Glyph.Plus, modifier = if (firstOpen < 0) Modifier.focusRequester(start) else Modifier) {
        if (!sheet.primary.enabled || sending) return@TvRow
        sending = true
        run.launch {
            val result = withContext(Dispatchers.IO) { try { screen.confirm() } catch (e: CancellationException) { throw e } catch (_: Exception) { SeerrRequestResult.NotSent } }
            sending = false
            when (result) {
                is SeerrRequestResult.Requested, is SeerrRequestResult.Exists -> { close(); afterwards() }
                else -> sheet = screen.info().sheet
            }
        }
    }
}
