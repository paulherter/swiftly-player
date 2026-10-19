package de.paulherter.swiftly

import de.paulherter.swiftly.support.SupporterAvatarHeart
import androidx.compose.foundation.layout.imePadding
import androidx.compose.ui.draw.alpha
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Strength
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.platform.LocalDensity
import de.paulherter.swiftly.shared.motionReduced
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.SubcomposeAsyncImage
import de.paulherter.swiftly.shared.Motion
import de.paulherter.swiftly.shared.InputField
import de.paulherter.swiftly.shared.PrimaryButton
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import de.paulherter.swiftly.core.Kern
import android.os.SystemClock
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

// MARK: Building blocks

/**
 * Mirrors `SecondaryButtonStyle`: 48 high, **`area`**, pressed `pressedArea`, instant on and
 * 120 ms off, plus the 0.97 scale like every other button.
 *
 * It used to draw white at 10 or 16 percent over the background, giving #2A2A2A and #333333: two
 * tones just beside the two that exist for this, and neither named. This version additionally
 * carries an icon; otherwise it is the shared `Nebenknopf`.
 *
 * `accent`: text and icon in the accent, `SecondaryButtonStyle(accent: true)`, the second way to the
 * same goal (Quick Connect under the sign-in button). 9 between icon and word.
 */
@Composable
fun SecondaryButton(symbol: Glyph, text: String, accent: Boolean = true, perform: () -> Unit) {
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val mass by androidx.compose.animation.core.animateFloatAsState(
        if (pressed) Motion.PressMetric else 1f, Motion.release(), label = "druck")
    Row(Modifier.fillMaxWidth().heightIn(min = Theme.buttonHeight)
            .graphicsLayer { scaleX = mass; scaleY = mass }
            .clip(RoundedCornerShape(Theme.corner))
            .background(if (pressed) Theme.pressedArea else Theme.area)
            .clickable(source, null, onClick = perform),
        horizontalArrangement = Arrangement.spacedBy(9.dp, Alignment.CenterHorizontally), verticalAlignment = Alignment.CenterVertically) {
        // The icon in the button carries the button's type: 15 Medium (`SecondaryButtonStyle`).
        val color = if (accent) Theme.accent else Theme.font
        Symbol(symbol, 15.dp, color = color, strength = Strength.Medium)
        Text(text, style = Theme.buttonText, color = color)
    }
}

/** "oder" between two lines, separating password and Quick Connect. */
@Composable
fun Or(modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Box(Modifier.weight(1f).height(1.dp).background(Theme.line))
        Text(translated("oder"), style = Theme.small, color = Theme.fontVeryQuiet)
        Box(Modifier.weight(1f).height(1.dp).background(Theme.line))
    }
}

/** Mirrors `ProfileCharacter`: image or letter; highlighted with an accent ring. */
@Composable
fun ProfileCharacter(name: String, image: String?, size: Dp, highlighted: Boolean = false) {
    Box(Modifier.size(size).border(if (highlighted) 1.5.dp else 1.dp, if (highlighted) Theme.accent else Theme.margin, CircleShape)
            .padding(if (highlighted) 2.dp else 0.dp)) {
        SubcomposeAsyncImage(model = image, contentDescription = name, contentScale = ContentScale.Crop,
            modifier = Modifier.fillMaxSize().clip(CircleShape),
            error = {
                Box(Modifier.fillMaxSize().background(Theme.raised), contentAlignment = Alignment.Center) {
                    Text(name.take(1).uppercase(), color = Theme.font,
                         style = TextStyle(fontSize = (size.value * 0.38f).sp, fontWeight = FontWeight.SemiBold))
                }
            })
    }
}

// MARK: Quick Connect

/**
 * Mirrors `QuickConnectLogin` + `QuickConnectModel`: this device shows a code, another one
 * authorizes it. Deadline and interval come from the package (`QuickConnectDeadline`); they used to
 * be in the code three times and drifted apart. A new code ends the old poll, so a late callback
 * of the old one overwrites nothing.
 */
@Composable
fun QuickConnectLogin(app: SwiftlyApplication, newServer: Boolean, back: () -> Unit, signedIn: (String) -> Unit) {
    val deadline = remember { JSONArray(Kern.quickConnectDeadline()) }
    val seconds = deadline.getInt(0)
    var code by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var rest by remember { mutableIntStateOf(0) }
    var run by remember { mutableIntStateOf(0) }
    val store = LocalClipboardManager.current
    BackHandler(onBack = back)

    LaunchedEffect(run) {
        code = null
        error = null
        try {
            code = withContext(Dispatchers.IO) { app.kern.quickConnectStart(newServer).await() }
            // **The waiting lives in the package** (`QuickConnectWait`, via the kernel): deadline on the
            // clock, ask at once after returning from the browser, a network error does not end the wait.
            // Here only show the remaining time and accept the result.
            val c = code.orEmpty()
            rest = seconds
            val display = launch { while (true) { delay(1000); rest = app.kern.quickConnectRest().toInt() } }
            try {
                val result = withContext(Dispatchers.IO) { app.kern.quickConnectWait(newServer).await() }
                display.cancel()
                when {
                    result == "freigegeben" -> signedIn(withContext(Dispatchers.IO) { app.kern.quickConnectSignIn(newServer).await() })
                    result.isNotEmpty() -> { rest = 0; error = result }
                }
            } finally {
                display.cancel()
                // Page closed or new code: stop polling, otherwise a late authorization signs in.
                app.kern.quickConnectWaitEnd(c)
            }
        } catch (e: CancellationException) { throw e } catch (e: Exception) {
            error = errorString(app, e)
        }
    }

    Column(Modifier.fillMaxSize().background(Theme.reason)) {
        SubpageHeader(translated("Quick Connect"), back)
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = Theme.edgeSpacing).widthIn(max = Theme.formWidth)) {
            Text(translated("Gib diesen Code in Jellyfin auf einem Gerät ein, an dem du schon angemeldet bist."),
                 style = Theme.body.copy(lineHeight = 21.sp), color = Theme.fontQuiet, modifier = Modifier.padding(top = 10.dp))
            val c = code
            when {
                // `error`, not `warning`: the code did not arrive, that went wrong rather than something
                // waiting on someone.
                error != null -> Text(error.orEmpty(), style = Theme.body.copy(textAlign = TextAlign.Center), color = Theme.error,
                                       modifier = Modifier.fillMaxWidth().padding(top = 40.dp))
                c == null -> Box(Modifier.fillMaxWidth().padding(top = 40.dp), contentAlignment = Alignment.Center) {
                    LoadField(Modifier.size(260.dp, 60.dp), 12.dp)
                }
                else -> {
                    // One field per digit; with an even length a small gap in the middle. Tapping copies.
                    Row(Modifier.fillMaxWidth().padding(top = 34.dp).tapOn { store.setText(AnnotatedString(c)) },
                        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally)) {
                        c.forEachIndexed { i, symbolText ->
                            if (c.length % 2 == 0 && i == c.length / 2) Spacer(Modifier.width(6.dp))
                            // **No border**: a field is a filled surface.
                            // 28 is the page title step: here the code *is* the page.
                            Box(Modifier.size(46.dp, 60.dp).clip(RoundedCornerShape(Theme.cornerField)).background(Theme.area),
                                contentAlignment = Alignment.Center) {
                                Text(symbolText.toString(), style = Theme.titleLarge.copy(fontWeight = FontWeight.SemiBold, letterSpacing = 0.sp, fontFeatureSettings = "tnum"),
                                     color = Theme.font)
                            }
                        }
                    }
                    Row(Modifier.fillMaxWidth().padding(top = 22.dp), verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally)) {
                        Box(Modifier.size(8.dp).clip(CircleShape).background(Theme.accent))
                        Text(translated("Warte auf Freigabe · noch %lld:%@", rest / 60, "%02d".format(rest % 60)),
                             style = Theme.tile.copy(fontFeatureSettings = "tnum"), color = Theme.fontQuiet)
                    }
                }
            }
            Column(Modifier.padding(top = 38.dp)) {
                Box(Modifier.fillMaxWidth().height(1.dp).background(Theme.line))
                // Group title: 20 Semibold in normal case, `schriftLeise`.
                Text(translated("So gehts"), style = Theme.rail,
                     color = Theme.fontQuiet, modifier = Modifier.padding(top = 16.dp, bottom = 10.dp))
                listOf("Jellyfin im Browser öffnen und anmelden", "Oben rechts aufs Profil, dann Quick Connect",
                       "Code eingeben, dann geht es hier von selbst weiter").forEachIndexed { i, step ->
                    Row(Modifier.padding(top = 10.dp)) {
                        Text("${i + 1}", style = Theme.body, color = Theme.fontVeryQuiet, modifier = Modifier.width(Theme.characterColumn))
                        Text(translated(step), style = Theme.body.copy(lineHeight = 21.sp), color = Theme.fontQuiet)
                    }
                }
            }
        }
        Box(Modifier.padding(horizontal = Theme.edgeSpacing).navigationBarsPadding().padding(bottom = 24.dp)) {
            // `SecondaryButtonStyle()` without icon and without accent.
            de.paulherter.swiftly.shared.SecondaryButton(translated("Neuen Code holen")) { run++ }
        }
    }
}

// MARK: Add server

/**
 * Mirrors `ServerOnboardingView`: another Jellyfin server. **The running session is left
 * untouched** until the new one is up: the facade checks and signs in on a client of its own.
 * `preset`: from the plus of a foreign server card, then without an address field while it
 * works.
 */
@Composable
fun ServerOnboardingPage(app: SwiftlyApplication, preset: String?, back: () -> Unit) {
    var address by remember { mutableStateOf(preset.orEmpty()) }
    var server by remember { mutableStateOf<Pair<String, String>?>(null) }
    var examine by remember { mutableStateOf(false) }
    var user by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var running by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var quick by remember { mutableStateOf(false) }
    /** "Advanced": custom headers for a service in front of the server. */
    val headers = rememberHeaderRow()
    val run = rememberCoroutineScope()

    fun cancel() { app.kern.onboardingCancel(); back() }
    fun record(session: String) { app.kern.onboardingCancel(); app.sessionRecord(session) }
    fun check() {
        if (address.isBlank() || examine) return
        examine = true; error = null
        run.launch {
            try {
                val o = JSONObject(withContext(Dispatchers.IO) { app.kern.onboardingConnect(address, headers.asJson()).await() })
                // Store only now: an address where nothing answers leaves nothing behind.
                if (headers.isNotEmpty()) app.storeOwnHeaders()
                server = o.getString("name") to o.getString("version")
            } catch (e: CancellationException) { throw e } catch (e: Exception) { error = errorString(app, e) }
            examine = false
        }
    }
    fun signIn() {
        if (user.isBlank() || running) return
        running = true; error = null
        run.launch {
            try { record(withContext(Dispatchers.IO) { app.kern.onboardingSignIn(user, password).await() }) }
            catch (e: CancellationException) { throw e } catch (e: Exception) { error = errorString(app, e) }
            running = false
        }
    }
    LaunchedEffect(Unit) { if (preset != null) check() }

    if (quick) {
        QuickConnectLogin(app, newServer = true, back = { quick = false }) { record(it) }
        return
    }
    // **No back handling of its own**: it took away the main view's follow-along drag. The intake
    // aborts as soon as the page goes, by whatever route.
    DisposableEffect(Unit) { onDispose { app.kern.onboardingCancel() } }

    val s = server
    // The title is the server name once it is known.
    val pagesTitle = s?.first ?: translated(if (preset != null) "Konto hinzufügen" else "Server hinzufügen")
    // **Back at the top, nothing at the bottom.** As a pushed page it has the same arrow at the top as
    // every other subpage; a second "Abbrechen" below would be a second way back.
    Column(Modifier.fillMaxSize().background(Theme.reason)) {
        SubpageHeader(pagesTitle, { cancel() })
        Box(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()), contentAlignment = Alignment.TopCenter) {
            Column(Modifier.widthIn(max = Theme.formWidth).fillMaxWidth().padding(horizontal = 28.dp).padding(bottom = 40.dp)
                       .navigationBarsPadding().imePadding()) {
                // `header`: connected, the preset address, or what the page does: 8 above.
                Box(Modifier.padding(top = 8.dp)) {
                    when {
                        s != null -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Box(Modifier.size(7.dp).clip(CircleShape).background(Theme.accent))
                            Text(translated("Verbunden · Jellyfin %@", s.second), style = Theme.small, color = Theme.fontVeryQuiet)
                        }
                        preset != null -> Text(runCatching { java.net.URI(preset).host }.getOrNull() ?: preset,
                                                       style = Theme.body, color = Theme.fontQuiet)
                        else -> Text(translated("Die Adresse eines weiteren Jellyfin-Servers. Du bleibst bei beiden angemeldet und wechselst auf der Profilseite zwischen ihnen."),
                                     style = Theme.body.copy(lineHeight = 21.sp), color = Theme.fontQuiet)
                    }
                }
                if (s != null) {
                    Column(Modifier.padding(top = 28.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        InputField(user, { user = it }, Glyph.Person, translated("Benutzername"))
                        InputField(password, { password = it }, Glyph.Padlock, translated("Passwort"), secret = true) { signIn() }
                        PrimaryButton(translated(if (running) "Anmelden…" else "Anmelden"), released = user.isNotBlank() && !running,
                                   modifier = Modifier.padding(top = 10.dp).alpha(if (user.isBlank()) 0.4f else 1f)) { signIn() }
                        Or(Modifier.padding(top = 16.dp))
                        Box(Modifier.padding(top = 10.dp)) {
                            SecondaryButton(Glyph.Tv, translated("Mit Quick Connect anmelden")) { quick = true }
                        }
                    }
                } else if (preset == null || error != null) {
                    Column(Modifier.padding(top = 28.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        InputField(address, { address = it }, Glyph.Server, "tv.example.de", address = true) { check() }
                        AdvancedSection(headers)
                        PrimaryButton(translated(if (examine) "Verbinden…" else "Verbinden"), released = address.isNotBlank() && !examine,
                                   modifier = Modifier.padding(top = 10.dp).alpha(if (address.isBlank()) 0.4f else 1f)) { check() }
                    }
                }
                // `error`, not `warning`: a rejected sign-in went wrong.
                error?.let { Text(it, style = Theme.small.copy(textAlign = TextAlign.Center), color = Theme.error,
                                   modifier = Modifier.fillMaxWidth().padding(top = 12.dp)) }
            }
        }
    }
}

// MARK: Account cards

private data class AccountEntry(val identifier: String, val name: String, val active: Boolean, val image: String?)
private data class ServerCard(val address: String, val host: String, val active: Boolean, val accounts: List<AccountEntry>)

/**
 * Mirrors `Kontokarte` in `ProfileView.swift`: one card per server. In front the account that is
 * current, below it the others and a plus as a field. **Edge to edge, no peek:** with one server
 * nothing hints at swiping; from two the cards page, with dots below. Switching does not sign out;
 * the abandoned account stays valid for the way back.
 */
@Composable
fun AccountCards(app: SwiftlyApplication, server: Pair<String, String>?, open: (Destination) -> Unit) {
    val bundle = app.store.accounts.orEmpty()
    val cards = remember(bundle) {
        JSONArray(Kern.bundleOverview(bundle)).let { a ->
            (0 until a.length()).map { i ->
                a.getJSONObject(i).let { o ->
                    ServerCard(o.getString("adresse"), o.getString("host"), o.getBoolean("aktiv"),
                        o.getJSONArray("konten").let { k -> (0 until k.length()).map { j -> k.getJSONObject(j).let { e ->
                            AccountEntry(e.getString("kennung"), e.getString("name"), e.getBoolean("aktiv"), if (e.isNull("bild")) null else e.getString("bild"))
                        } } })
                }
            }
        }
    }
    if (cards.size <= 1) {
        cards.firstOrNull()?.let { CardView { CardContent(app, it, multiple = false, server, open) } }
        return
    }
    val leaves = rememberPagerState(initialPage = cards.indexOfFirst { it.active }.coerceAtLeast(0)) { cards.size }
    Column {
        HorizontalPager(leaves, verticalAlignment = Alignment.Top) { i -> CardView { CardContent(app, cards[i], multiple = true, server, open) } }
        Row(Modifier.fillMaxWidth().padding(top = 10.dp), horizontalArrangement = Arrangement.spacedBy(7.dp, Alignment.CenterHorizontally)) {
            cards.indices.forEach { i ->
                Box(Modifier.size(6.dp).clip(CircleShape).background(if (i == leaves.currentPage) Theme.font else Theme.fontVeryQuiet))
            }
        }
    }
}

@Composable
private fun CardContent(app: SwiftlyApplication, card: ServerCard, multiple: Boolean, server: Pair<String, String>?, open: (Destination) -> Unit) {
    val front = card.accounts.firstOrNull { it.active } ?: card.accounts.firstOrNull() ?: return
    val other = card.accounts.filter { it.identifier != front.identifier }
    // The own header row switches nothing; that of a foreign server switches there.
    // **Switching, with motion** (`AccountSwitchTransition`): the image lifts off from here.
    val density = LocalDensity.current.density
    val calm = motionReduced()
    val headerFrame = remember { arrayOf(androidx.compose.ui.geometry.Rect.Zero) }
    Row(Modifier.fillMaxWidth().then(if (!card.active) Modifier.pressRow {
            AccountSwitchTransition.start(app, front.identifier, front.name, front.image, headerFrame[0], Theme.groupsArea, density, calm)
        } else Modifier).padding(16.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Box(Modifier.onGloballyPositioned { headerFrame[0] = it.boundsInRoot() }) {
            ProfileCharacter(front.name, front.image, 56.dp, highlighted = card.active && multiple)
            // The supporter heart, on this device's own account only.
            if (card.active) SupporterAvatarHeart(app, 56.dp)
        }
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            // 17 Semibold, the sheet heading: the name is the subject of the card, not a row.
            Text(front.name, style = Theme.categoryLarge, color = Theme.font, maxLines = 1)
            // **Both lines keep their place, even while empty.** Name and server info arrive one after the
            // other: the name is there at once, `serverInfo` only after the response. If the header grew
            // past the 56 of the icon, everything below (divider and the row of other accounts) shifted down
            // and looked "loaded late".
            val (row, subline) = if (card.active)
                (server?.first?.takeIf { it.isNotEmpty() } ?: app.serverName.value.orEmpty()) to
                    (server?.second?.takeIf { it.isNotEmpty() }?.let { translated("Jellyfin %@", it) } ?: "")
            else card.host to translated("Antippen zum Wechseln")
            Text(row.ifEmpty { " " }, style = Theme.small, color = Theme.fontVeryQuiet, maxLines = 1)
            Text(subline.ifEmpty { " " }, style = Theme.small, color = Theme.fontVeryQuiet, maxLines = 1)
        }
    }
    Box(Modifier.fillMaxWidth().height(1.dp).background(Theme.line))
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(16.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        other.forEach { k ->
            val frameRect = remember { arrayOf(androidx.compose.ui.geometry.Rect.Zero) }
            Box(Modifier.size(40.dp).onGloballyPositioned { frameRect[0] = it.boundsInRoot() }.tapOn {
                AccountSwitchTransition.start(app, k.identifier, k.name, k.image, frameRect[0], Theme.groupsArea, density, calm)
            }) { ProfileCharacter(k.name, k.image, 40.dp) }
        }
        // The plus: on the own server another account, on a foreign one the intake with its address.
        // A field on `area`, not a dashed circle (iPhone: a button without a label is square).
        Box(Modifier.size(40.dp).background(Theme.area, RoundedCornerShape(Theme.corner))
                .tapOn {
                    if (card.active) open(Destination("weiteresKonto", translated("Konto hinzufügen"), "WeiteresKonto"))
                    else open(Destination(card.address, translated("Konto hinzufügen"), "ServerAufnahme"))
                },
            contentAlignment = Alignment.Center) {
            Symbol(Glyph.Plus, 15.dp, color = Theme.fontQuiet, strength = Strength.Semibold, description = translated("Konto hinzufügen"))
        }
    }
}
