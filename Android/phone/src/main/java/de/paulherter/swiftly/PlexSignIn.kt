package de.paulherter.swiftly

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.browser.customtabs.CustomTabColorSchemeParams
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.PrimaryButton
import de.paulherter.swiftly.shared.QuietButton
import de.paulherter.swiftly.shared.SecondaryButton
import de.paulherter.swiftly.shared.Strength
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated

/**
 * Mirrors `PlexSignInView` with `PlexSignInModel` / `PlexRun`: **sign in with Plex: one button,
 * a browser window, then the choice.**
 *
 * Plex has no address to type and no password for us. The sign-in happens on Plex's page, in the
 * Custom Tab (the counterpart of `ASWebAuthenticationSession`); the app holds a code and asks
 * plex.tv about once a second until it was confirmed. The Custom Tab never reports back by
 * itself, so the app brings its own window to the front when the token is seen, which closes
 * the tab (as `PlexBrowser.close()` does on Apple).
 *
 * After that, in this order: who is watching (Plex Home, only if there are several profiles,
 * with the PIN of a protected one), then the account's servers. The core does the network steps
 * (`plexStart`, `plexPoll`, `plexPickProfile`, `plexServers`, `plexPickServer`) and answers each
 * with the next step.
 *
 * `finished`: signed in and connected; the session is stored already.
 * `back`: the arrow at the top on the first step.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun PlexSignInPage(app: SwiftlyApplication, finished: () -> Unit, back: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val model = remember { PlexSignInModel(app, scope, tv = false, finished = finished, leave = back) }

    fun openBrowser(url: String) {
        val activity = context.activity() ?: return
        val dark = CustomTabColorSchemeParams.Builder().setToolbarColor(android.graphics.Color.BLACK).build()
        val tab = CustomTabsIntent.Builder().setColorScheme(CustomTabsIntent.COLOR_SCHEME_DARK)
            .setDefaultColorSchemeParams(dark).setShowTitle(true).setShareState(CustomTabsIntent.SHARE_STATE_OFF).build()
        try { tab.launchUrl(activity, Uri.parse(url)) }
        catch (_: ActivityNotFoundException) {
            // No browser with Custom Tabs: any browser does; the poll sees the token all the same.
            try { activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) } catch (_: ActivityNotFoundException) {}
        }
    }

    /** The window's job is done: our own screen comes to the front, which closes the Custom Tab above it. */
    fun bringToFront() {
        val activity = context.activity() ?: return
        activity.startActivity(Intent(activity, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
    }
    model.waitingEnded = { bringToFront() }

    fun start() = model.start { openBrowser(it.url) }

    val step = model.step
    val waiting = step is PlexStep.Waiting
    LaunchedEffect(waiting) { if (waiting) model.poll() }
    // The sign-in window closed by hand, or the page came back: look right now.
    val lifecycle = androidx.compose.ui.platform.LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_RESUME) model.lookNow() }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    DisposableEffect(Unit) { onDispose { model.dispose() } }
    BackHandler { model.goBack() }

    val title = model.title
    val connecting = model.connecting
    val unreachable = model.unreachable
    fun loadServers() = model.loadServers()
    fun otherAccount() = model.otherAccount()
    fun stepBack() = model.goBack()
    fun pickProfile(p: PlexProfile) = model.pickProfile(p)
    fun pickServer(s: PlexServer) = model.pickServer(s)
    val pinWrong = model.pinWrong
    val pinChecking = model.pinChecking
    val profileName = model.profileName

    Column(Modifier.fillMaxSize().background(Theme.reason)) {
        SubpageHeader(title, { stepBack() })
        Box(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()), contentAlignment = Alignment.TopCenter) {
            Column(Modifier.widthIn(max = Theme.formWidth).fillMaxWidth().padding(horizontal = Theme.edgeSpacing).padding(bottom = 40.dp)) {
                when (val s = step) {
                    PlexStep.Start, PlexStep.Opening -> PlexIntro(step == PlexStep.Opening) { start() }
                    is PlexStep.Waiting -> PlexWaiting(s.secondsLeft)
                    PlexStep.LoadingServers -> PlexPlaceholder()
                    is PlexStep.Profiles -> PlexProfiles(s.list, ::pickProfile)
                    is PlexStep.Pin -> PlexPin(s.profile, pinWrong, pinChecking, { model.submitPin(s.profile, it) }) { model.pinWrong = false }
                    is PlexStep.Servers ->
                        if (s.list.isEmpty()) Box(Modifier.padding(top = 48.dp).heightIn(min = 360.dp)) {
                            EmptyState(Glyph.Server, translated("Kein Server auf diesem Konto"),
                                       translated("Richte Plex Media Server ein oder lass dir einen freigeben. Danach hier noch mal suchen."),
                                       primaryButton = translated("Noch mal suchen") to { loadServers() },
                                       quietButton = translated("Anderes Plex-Konto") to { otherAccount() })
                        } else PlexServers(s.list, connecting, unreachable, profileName, ::pickServer)
                    PlexStep.PlexUnreachable -> Failure(Glyph.WlanDisruption, translated("plex.tv antwortet nicht"),
                        translated("Ohne plex.tv klappt die Anmeldung nicht. Hängt vielleicht das WLAN?"),
                        translated("Erneut versuchen")) { start() }
                    PlexStep.Expired -> Failure(Glyph.History, translated("Die Anmeldung ist abgelaufen"),
                        translated("Der Code war zu lange offen. Hol dir einfach einen neuen."),
                        translated("Neuen Code holen")) { start() }
                    is PlexStep.Failed -> Failure(Glyph.Warning, translated("Anmeldung hat nicht geklappt"), s.message,
                        translated("Erneut versuchen")) { start() }
                }
            }
        }
        // The bottom, as the footer on Apple: one button, or the quiet way to another account.
        Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(bottom = 24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Column(Modifier.widthIn(max = Theme.formWidth).fillMaxWidth().padding(horizontal = Theme.edgeSpacing)) {
                when (val s = step) {
                    is PlexStep.Waiting -> SecondaryButton(translated("Seite noch mal öffnen")) { openBrowser(s.url) }
                    is PlexStep.Servers -> if (s.list.isNotEmpty()) {
                        Box(Modifier.fillMaxWidth().heightIn(min = 44.dp), contentAlignment = Alignment.Center) {
                            QuietButton(translated("Anderes Plex-Konto")) { if (connecting == null) otherAccount() }
                        }
                    }
                    else -> {}
                }
            }
        }
    }
}

// MARK: - Steps

@Composable
private fun PlexIntro(opening: Boolean, start: () -> Unit) {
    Column {
        Box(Modifier.padding(top = 8.dp)) { ServerKindMark(ServerKind.Plex, 44.dp) }
        Text(translated("Die Anmeldung läuft auf der Seite von Plex. Dein Passwort bekommt Swiftly Player nie zu sehen."),
             style = Theme.body.copy(lineHeight = 21.sp), color = Theme.fontQuiet, modifier = Modifier.padding(top = 20.dp))
        // The three steps, built like the guide on the Quick Connect page.
        Column(Modifier.padding(top = 34.dp)) {
            Box(Modifier.fillMaxWidth().height(1.dp).background(Theme.line))
            Text(translated("So gehts"), style = Theme.body.copy(fontWeight = FontWeight.SemiBold), color = Theme.fontQuiet,
                 modifier = Modifier.padding(top = 18.dp))
            PlexGuideLine(1, translated("Die Seite von Plex geht hier in der App auf"))
            PlexGuideLine(2, translated("Dort anmelden, dann schließt sie sich von selbst"))
            PlexGuideLine(3, translated("Server aussuchen, fertig"))
        }
        // Under the guide, where the steps end (was pinned to the bottom edge).
        PrimaryButton(translated(if (opening) "Wird geöffnet…" else "Plex öffnen"), released = !opening,
                      modifier = Modifier.padding(top = 28.dp)) { start() }
    }
}

@Composable
private fun PlexGuideLine(figure: Int, text: String) {
    Row(Modifier.padding(top = 12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("$figure", style = Theme.small.copy(fontFamily = FontFamily.Monospace), color = Theme.fontVeryQuiet,
             modifier = Modifier.width(20.dp).padding(top = 2.dp))
        Text(text, style = Theme.body, color = Theme.fontQuiet)
    }
}

@Composable
private fun PlexWaiting(secondsLeft: Int?) {
    Column {
        Box(Modifier.padding(top = 8.dp).breathing(true)) { ServerKindMark(ServerKind.Plex, 44.dp) }
        Text(translated("Melde dich auf der Seite von Plex an. Danach gehts hier von selbst weiter."),
             style = Theme.body.copy(lineHeight = 21.sp), color = Theme.fontQuiet, modifier = Modifier.padding(top = 20.dp))
        Row(Modifier.padding(top = 24.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(9.dp)) {
            Box(Modifier.size(8.dp).background(Theme.accent, CircleShape))
            Text(if (secondsLeft != null) translated("Warte auf Plex · noch %lld:%@", secondsLeft / 60, "%02d".format(secondsLeft % 60))
                 else translated("Warte auf Plex"),
                 style = Theme.small.copy(fontFamily = FontFamily.Monospace), color = Theme.fontQuiet)
        }
    }
}

/** Placeholders in the shape of what comes next: the servers (the profiles arrive inside the poll's answer). */
@Composable
private fun PlexPlaceholder() {
    Column {
        PlexHeading(translated("Deine Server"))
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            repeat(2) { LoadField(Modifier.fillMaxWidth().height(64.dp), Theme.cornerCard) }
        }
    }
}

@Composable
private fun PlexHeading(text: String) {
    Text(text, style = Theme.rail, color = Theme.fontQuiet, modifier = Modifier.padding(top = 8.dp, bottom = 10.dp))
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun PlexProfiles(profiles: List<PlexProfile>, pick: (PlexProfile) -> Unit) {
    Column {
        PlexHeading(translated("Wer schaut?"))
        FlowRow(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            profiles.forEach { p ->
                Box {
                    AccountCharacter(p.name, p.image, false) { pick(p) }
                    if (p.protected) {
                        // On the portrait's upper right edge, as a mark on a picture: a small field, not a
                        // circle (round is only what is a picture).
                        Box(Modifier.align(Alignment.TopEnd).padding(end = 6.dp).size(22.dp)
                                .background(Theme.raised, RoundedCornerShape(Theme.cornerSmall)),
                            contentAlignment = Alignment.Center) {
                            Symbol(Glyph.Padlock, 10.dp, color = Theme.font, strength = Strength.Semibold)
                        }
                    }
                }
            }
        }
        Text(translated("Jedes Profil hat seinen eigenen Fortschritt."), style = Theme.small.copy(lineHeight = 17.sp),
             color = Theme.fontVeryQuiet, modifier = Modifier.padding(top = 22.dp))
    }
}

@Composable
private fun PlexPin(profile: PlexProfile, wrong: Boolean, checking: Boolean, submit: (String) -> Unit, clearWrong: () -> Unit) {
    var pin by remember { mutableStateOf("") }
    var focused by remember { mutableStateOf(false) }
    val focus = remember { FocusRequester() }
    val keyboard = androidx.compose.ui.platform.LocalSoftwareKeyboardController.current
    LaunchedEffect(Unit) { focus.requestFocus(); keyboard?.show() }
    // A wrong PIN is wiped so the next try starts empty.
    LaunchedEffect(wrong) { if (wrong) { pin = ""; focus.requestFocus() } }
    Column {
        Row(Modifier.padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            ProfileCharacter(profile.name, profile.image, 44.dp)
            Text(profile.name, style = Theme.categoryLarge, color = Theme.font, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        Text(translated("Dieses Profil hat eine PIN. Gib sie hier ein."), style = Theme.body, color = Theme.fontQuiet,
             modifier = Modifier.padding(top = 22.dp))
        // Four boxes; the field on top takes the digits. Shown as dots: someone on the sofa next to
        // you need not read the PIN.
        Box(Modifier.padding(top = 18.dp)) {
            CodeBoxes((0 until 4).map { if (it < pin.length) "•" else " " }, active = if (focused) pin.length else null)
            BasicTextField(
                value = pin,
                onValueChange = { new ->
                    val digits = new.filter(Char::isDigit).take(4)
                    pin = digits
                    if (digits.isNotEmpty()) clearWrong()
                    if (digits.length == 4) submit(digits)
                },
                readOnly = checking, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                cursorBrush = SolidColor(Color.Transparent),
                modifier = Modifier.matchParentSize().alpha(0.011f).focusRequester(focus).onFocusChanged { focused = it.isFocused })
        }
        Box(Modifier.padding(top = 14.dp).heightIn(min = 16.dp)) {
            if (checking) Text(translated("Wird geprüft…"), style = Theme.small, color = Theme.fontQuiet)
            else if (wrong) Text(translated("Die PIN passt nicht. Versuchs noch mal."), style = Theme.small, color = Theme.error)
        }
    }
}

/**
 * **A code in single boxes**, the build of the Quick Connect code: nobody reads four or six
 * characters in a row off a screen without errors. `active` marks the box the next digit goes
 * into with the stronger edge, the way `InputField` shows focus.
 */
@Composable
private fun CodeBoxes(characters: List<String>, active: Int? = null) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        characters.forEachIndexed { index, c ->
            val shape = RoundedCornerShape(Theme.cornerField)
            Box(Modifier.size(46.dp, 60.dp).clip(shape).background(Theme.area)
                    .then(if (active == index) Modifier.border(2.dp, Theme.margin, shape) else Modifier),
                contentAlignment = Alignment.Center) {
                Text(c, style = Theme.titleLarge.copy(fontSize = 28.sp, fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Monospace),
                     color = Theme.font)
            }
        }
    }
}

@Composable
private fun PlexServers(servers: List<PlexServer>, connecting: String?, unreachable: Set<String>, profile: String?,
                        pick: (PlexServer) -> Unit) {
    Column {
        PlexHeading(translated("Deine Server"))
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(Theme.cornerCard)).background(Theme.groupsArea)) {
            servers.forEachIndexed { index, server ->
                if (index > 0) Box(Modifier.padding(start = 34.dp)) { SeparatorLine() }
                PlexServerRow(server, busy = connecting == server.id, failed = server.id in unreachable,
                              locked = connecting != null && connecting != server.id) { pick(server) }
            }
        }
        if (profile != null) {
            Text(translated("Als %@", profile), style = Theme.small.copy(lineHeight = 17.sp), color = Theme.fontVeryQuiet,
                 modifier = Modifier.padding(top = 12.dp, start = 2.dp))
        }
    }
}

@Composable
private fun PlexServerRow(server: PlexServer, busy: Boolean, failed: Boolean, locked: Boolean, perform: () -> Unit) {
    Row(Modifier.fillMaxWidth().then(if (locked) Modifier else Modifier.pressRow(perform))
            .padding(horizontal = 14.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Box(Modifier.width(20.dp).breathing(busy), contentAlignment = Alignment.Center) {
            Symbol(Glyph.Server, 17.dp, color = Theme.font)
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(server.name, style = Theme.body.copy(fontWeight = FontWeight.SemiBold), color = Theme.font, maxLines = 2,
                 overflow = TextOverflow.Ellipsis)
            // In order of urgency: running now, did not answer, then the plain facts (whose, where).
            if (busy) Text(translated("Verbinden…"), style = Theme.small, color = Theme.font)
            else if (failed) Text(translated("Antwortet gerade nicht. Tipp für einen neuen Versuch."), style = Theme.small, color = Theme.error)
            else {
                val owner = server.sharedBy?.let { translated("Von %@ freigegeben", it) } ?: translated("Dein Server")
                val place = if (!server.online) translated("laut Plex offline")
                            else if (server.local) translated("im WLAN") else translated("über das Internet")
                Text("$owner · $place", style = Theme.small, color = Theme.fontVeryQuiet)
            }
        }
        // Running now: a spinner where the arrow stands, so the tap visibly did something.
        if (busy) de.paulherter.swiftly.Spinner(16.dp)
        else Symbol(Glyph.AngleRight, 13.dp, color = Theme.font, strength = Strength.Semibold)
    }
}

@Composable
private fun Failure(symbol: Glyph, headerLine: String, text: String, button: String, perform: () -> Unit) {
    Box(Modifier.padding(top = 48.dp).heightIn(min = 360.dp)) {
        EmptyState(symbol, headerLine, text, primaryButton = button to perform)
    }
}
