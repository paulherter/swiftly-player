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
import de.paulherter.swiftly.rustcore.PrimaryKind
import de.paulherter.swiftly.rustcore.SeerrSetupInfo
import de.paulherter.swiftly.rustcore.SeerrSetupScreen
import de.paulherter.swiftly.rustcore.SeerrTitleInfo
import de.paulherter.swiftly.rustcore.SeerrTitleScreen
import de.paulherter.swiftly.rustcore.SetupEntry
import de.paulherter.swiftly.rustcore.SetupPhase
import de.paulherter.swiftly.rustcore.SignInMethod
import de.paulherter.swiftly.rustcore.TitleLoad
import de.paulherter.swiftly.shared.Texts
import androidx.compose.foundation.horizontalScroll
import kotlinx.coroutines.isActive

/** Heading of a result block with count, e.g. "On your server", "Can be requested". */
@Composable
fun BlockTitle(title: String, count: Int, modifier: Modifier = Modifier) {
    // `blockTitle`: heading 22 bold white, count badge on the right, 16 above, 10 below.
    Row(modifier.fillMaxWidth().padding(top = 16.dp, bottom = 10.dp), verticalAlignment = Alignment.Bottom) {
        Text(title, style = Theme.section,
             color = Theme.font, modifier = Modifier.weight(1f))
        if (count > 0) CountMark(count)
    }
}

/**
 * The host side of the core's `SeerrSetupScreen`, shared by the phone page and the TV page (`TvSeerrPage`): it opens the
 * screen, hands a connection the core returns to the vault and keeps the address config (`seerrServer|<server>`). What
 * is asked, which ways in exist, what is busy and which sentence a failure gets stay the core's; the two pages only draw it.
 */
class SeerrSetupHost(private val app: SwiftlyApplication, private val run: kotlinx.coroutines.CoroutineScope) {
    var screen by mutableStateOf<SeerrSetupScreen?>(null)
    var info by mutableStateOf<SeerrSetupInfo?>(null)
    var method by mutableStateOf<SignInMethod?>(null)
    val connected: Boolean get() = info?.phase == SetupPhase.CONNECTED
    private var signing: kotlinx.coroutines.Job? = null
    private val configKey: String get() = "seerrServer|" + app.seerrServer()

    /** What the core now says; a connection it hands back is stored (and the server's address config with it). */
    private fun settle(s: SeerrSetupScreen) {
        val now = s.info()
        info = now
        if (now.phase == SetupPhase.CONNECTED) {
            val connection = s.connection()
            if (connection != null) {
                val access = SeerrScreens.accessOf(connection)
                if (access != app.seerrStored()) app.seerrRemember(access) else app.seerrConnected.value = true
            }
            now.serverConfig?.let { app.store.remember(configKey, it) }
        }
    }

    /** Opens the screen with the stored session; the core checks it and either connects or shows the form. */
    suspend fun open() {
        val s = withContext(Dispatchers.IO) { app.rk.core().seerrSetup(Texts.language, null) }
        screen = s
        val stored = app.seerrStored()?.let { SeerrScreens.connectionOf(it) }
        withContext(Dispatchers.IO) { try { s.start(true, app.store.rememberValue(configKey), stored, null, null, null) } catch (e: CancellationException) { throw e } catch (_: Exception) {} }
        settle(s)
        method = method ?: s.info().methods.firstOrNull()?.method
    }

    /** One sign-in at a time; the core shows its busy line while it works. `done` runs afterwards (clear the password). */
    fun signIn(address: String, headersJson: String, user: String, email: String, password: String, done: () -> Unit) {
        val s = screen ?: return
        val i = info ?: return
        if (signing?.isActive == true) return
        val typed = if (i.entry == SetupEntry.ASK_ADDRESS) address else i.address.orEmpty()
        val own = SeerrScreens.headersOf(headersJson)
        signing = run.launch {
            val working = launch(Dispatchers.IO) {
                try {
                    when (method) {
                        SignInMethod.LOCAL -> s.signInLocal(typed, own, email, password)
                        SignInMethod.PLEX -> s.signInPlex(typed, own, "")
                        else -> s.signInJellyfin(typed, own, user, password)
                    }
                } catch (e: CancellationException) { throw e } catch (_: Exception) {}
            }
            while (working.isActive) { info = s.info(); delay(150) }
            settle(s); done()
        }
    }

    fun editAddress() { screen?.let { s -> s.editAddress(); settle(s) } }

    /** Forgets the connection (core, vault, platform cookies) and shows the form again. */
    fun disconnect(done: () -> Unit) {
        val s = screen ?: return
        s.disconnect(); app.seerrDisconnect(); done()
        run.launch { withContext(Dispatchers.IO) { runCatching { s.start(true, app.store.rememberValue(configKey), null, null, null, null) } }; settle(s) }
    }
}

@Composable
fun rememberSeerrSetup(app: SwiftlyApplication): SeerrSetupHost {
    val run = rememberCoroutineScope()
    val host = remember { SeerrSetupHost(app, run) }
    LaunchedEffect(app.seerrServer()) { host.open() }
    return host
}

/**
 * Mirrors `SeerrSettingsView`: draws the core's `SeerrSetupScreen` through `SeerrSetupHost`, which the TV page uses as well.
 */
@Composable
fun SeerrSettingsPage(app: SwiftlyApplication, back: () -> Unit) {
    val host = rememberSeerrSetup(app)
    var address by remember { mutableStateOf("") }
    var user by remember { mutableStateOf(app.username().takeIf { it != "?" }.orEmpty()) }
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var arrival by remember { mutableStateOf(seerrArrivalOn(app)) }
    /** "Advanced": custom headers for a service in front of Seerr. They end up in the credentials, i.e. the vault. */
    val headers = rememberHeaderRow()
    val info = host.info
    val connected = host.connected
    val method = host.method
    fun signIn() = host.signIn(address, headers.asJson(), user, email, password) { password = "" }

    SettingPage("Seerr", back) {
        Text(translated("Jellyseerr oder Overseerr. Dann zeigt die Suche auch Titel, die noch nicht auf deinem Server sind, und du kannst sie anfragen."),
             style = Theme.body.copy(lineHeight = 21.sp), color = Theme.fontQuiet, modifier = Modifier.padding(horizontal = Theme.edgeSpacing))
        val i = info
        if (i != null && connected) {
            SettingGroup(translated("Verbunden")) {
                // The core only reports "connected" after it checked the session, so there is no separate "expired" state to draw.
                ValueRow(Glyph.Chain, app.seerrAddress().orEmpty(), value = translated("Aktiv"))
                SeparatorLine()
                ValueRow(Glyph.CrossCircle, translated("Verbindung trennen")) {
                    host.disconnect { password = "" }
                }
            }
            SettingGroup(translated("Startseite")) {
                ChoiceRow(Glyph.SparkleSearch, translated("Ankunft-Hinweise anzeigen"), an = arrival) { arrival = it; seerrArrivalSet(app, it) }
            }
        } else if (i != null) {
            Column(Modifier.padding(horizontal = Theme.edgeSpacing).padding(top = 26.dp)) {
                i.notSetUp?.let { Text(it, style = Theme.body.copy(lineHeight = 21.sp), color = Theme.fontQuiet) }
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    when (i.entry) {
                        SetupEntry.ASK_ADDRESS -> { InputField(address, { address = it }, Glyph.Chain, "seerr.example.de", address = true); AdvancedSection(headers) }
                        SetupEntry.KNOWN_ADDRESS -> {
                            ValueRow(Glyph.Chain, i.address.orEmpty())
                            if (i.canEditAddress) ValueRow(Glyph.Chain, translated("Adresse ändern")) { host.editAddress() }
                        }
                        SetupEntry.NOT_SET_UP -> {}
                    }
                    if (i.entry != SetupEntry.NOT_SET_UP) {
                        if (i.methods.size > 1) Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.horizontalScroll(rememberScrollState())) {
                            i.methods.forEach { m ->
                                Text(m.title, style = Theme.small, color = if (method == m.method) Theme.reason else Theme.font,
                                     modifier = Modifier.clip(CircleShape).background(if (method == m.method) Theme.font else Theme.area)
                                         .tapOn { host.method = m.method }.padding(horizontal = 12.dp, vertical = 7.dp))
                            }
                        }
                        val chosen = i.methods.firstOrNull { it.method == method } ?: i.methods.firstOrNull()
                        if (chosen != null) {
                            if (chosen.method == SignInMethod.LOCAL) InputField(email, { email = it }, Glyph.Person, chosen.userLabel ?: translated("E-Mail"))
                            else if (chosen.method == SignInMethod.JELLYFIN) InputField(user, { user = it }, Glyph.Person, chosen.userLabel ?: translated("Name"))
                            if (chosen.needsPassword) InputField(password, { password = it }, Glyph.Padlock, translated("Passwort"), secret = true) { signIn() }
                        }
                    }
                }
                i.error?.let { Text(it, style = Theme.small, color = Theme.error, modifier = Modifier.padding(top = 14.dp)) }
                val ready = i.entry != SetupEntry.NOT_SET_UP && i.methods.isNotEmpty() && (i.entry != SetupEntry.ASK_ADDRESS || address.isNotBlank()) && password.isNotBlank()
                // No disabled button: it appears as soon as everything is there.
                when {
                    i.busy != null -> Text(i.busy.orEmpty(), style = Theme.body, color = Theme.fontQuiet, modifier = Modifier.padding(top = 20.dp))
                    ready -> PrimaryButton(i.methods.firstOrNull { it.method == method }?.title ?: translated("Verbinden"), modifier = Modifier.padding(top = 20.dp)) { signIn() }
                }
            }
        }
    }
}

/**
 * Mirrors `SeerrDetailView`: draws the core's `SeerrTitleScreen` (page, season rows, request sheet). The state line, the one
 * primary button, the quota and every sentence come from the core; the host only draws them and forwards the taps.
 */
@Composable
fun SeerrDetailPage(app: SwiftlyApplication, target: Destination, open: (Destination) -> Unit, back: () -> Unit) {
    val art = target.id.substringBefore(':')
    val tmdb = target.id.substringAfter(':').toLongOrNull()
    if (tmdb == null) { LaunchedEffect(Unit) { back() }; return }
    var screen by remember(target.id) { mutableStateOf<SeerrTitleScreen?>(null) }
    var info by remember(target.id) { mutableStateOf<SeerrTitleInfo?>(null) }
    var retry by remember { mutableIntStateOf(0) }
    val run = rememberCoroutineScope()
    val jerk = rememberJerk()
    LaunchedEffect(target.id, retry) {
        val s = withContext(Dispatchers.IO) { app.seerr.title(art, tmdb) }
        screen = s
        info = withContext(Dispatchers.IO) { try { s.load() } catch (e: CancellationException) { throw e } catch (_: Exception) { s.info() } }
    }
    val scroll = rememberScrollState()
    val density = LocalDensity.current.density
    val i = info
    // Debug builds only (`testSheet`): the request sheet opens by itself once the page stands.
    LaunchedEffect(i?.load) {
        if (!BuildConfig.DEBUG || !app.debugSheet || i?.load != TitleLoad.CONTENT || i.primary.kind != PrimaryKind.REQUEST) return@LaunchedEffect
        app.debugSheet = false
        kotlinx.coroutines.delay(1500)
        screen?.let { s -> seerrSheetShow(app, s, null) { info = s.info() } }
    }
    Box(Modifier.fillMaxSize().background(Theme.reason)) {
        Column(Modifier.fillMaxSize().verticalScroll(scroll)) {
            when {
                i == null || i.load == TitleLoad.LOADING -> Box(Modifier.fillMaxWidth().height(420.dp), contentAlignment = Alignment.Center) { Spinner(28.dp) }
                i.load != TitleLoad.CONTENT -> Box(Modifier.fillMaxWidth().height(420.dp)) {
                    EmptyState(Glyph.WlanDisruption, i.error ?: translated("Seerr antwortet gerade nicht."), translated("Deine Bibliothek läuft normal."),
                               primaryButton = translated("Erneut versuchen") to { retry++ })
                }
                else -> {
                    Hero(tmdbImage(i.backdrop ?: i.poster, 780), i.title, i.secondaryLine)
                    Column(Modifier.padding(horizontal = Theme.edgeSpacing).padding(top = 14.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                        // The same `ProofRow` as on the title page, with the core's state line as free-form evidence.
                        ProofRow(true, false, false, null, i.rating?.takeIf { it > 0 }, null,
                                   own = i.badge?.let { b -> Triple(SeerrBadgeMark.glyph(b.kind), b.line, SeerrBadgeMark.color(b.kind)) })
                        when (i.primary.kind) {
                            PrimaryKind.REQUEST, PrimaryKind.BUSY -> PlayButton(Glyph.Plus, i.primary.text, an = i.primary.enabled && i.primary.kind == PrimaryKind.REQUEST, main = true) {
                                jerk(Jerk.Medium)
                                screen?.let { s -> seerrSheetShow(app, s, null) { info = s.info() } }
                            }
                            PrimaryKind.REQUESTED, PrimaryKind.LOCKED -> HintBox(i.primary.text)
                            PrimaryKind.HIDDEN -> {}
                        }
                        if (i.seasons.isNotEmpty()) Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(Theme.corner)).background(Theme.area)) {
                            i.seasons.forEach { r ->
                                Row(Modifier.fillMaxWidth().heightIn(min = 46.dp).padding(horizontal = 14.dp), verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                    Text(r.title, style = Theme.body, color = Theme.font)
                                    r.episodes?.let { Text("· $it", style = Theme.small, color = Theme.fontVeryQuiet) }
                                    Spacer(Modifier.weight(1f))
                                    Capsule(r.badge)
                                }
                            }
                        }
                        i.overview?.let { CollapsibleText(it) }
                    }
                    if (i.cast.isNotEmpty()) Segment(translated("Besetzung"), 14.dp) {
                        tilesWithKey(i.cast.take(12), { it.name + it.role }) { p -> CastTile(WithAct(p.name, p.name, p.role, tmdbImage(p.image, 185))) { open(seerrPersonTarget(p, i.title)) } }
                    }
                    if (i.similar.isNotEmpty()) Segment(translated("Ähnliche Titel"), Theme.tileSpacing) {
                        tilesWithKey(i.similar, { it.key }) { t -> SeerrCardTile(t, Modifier.width(Theme.tileWidth)) { run.launch { openSeerrCard(app, t, open) } } }
                    }
                }
            }
            Spacer(Modifier.navigationBarsPadding().height(30.dp))
        }
        DetailHeader(i?.title ?: target.name, { ((scroll.value / density - 150f) / 70f).coerceIn(0f, 1f) }, back)
    }
}

@Composable
private fun HintBox(text: String) {
    Text(text, style = Theme.body.copy(lineHeight = 21.sp), color = Theme.fontQuiet,
         modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(Theme.corner)).background(Theme.area).padding(14.dp))
}
