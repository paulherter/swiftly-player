package de.paulherter.swiftly.tv

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import de.paulherter.swiftly.LoadField
import de.paulherter.swiftly.PlexProfile
import de.paulherter.swiftly.PlexServer
import de.paulherter.swiftly.PlexSignInModel
import de.paulherter.swiftly.PlexStep
import de.paulherter.swiftly.ServerKind
import de.paulherter.swiftly.ServerKindMark
import de.paulherter.swiftly.SwiftlyApplication
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Strength
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated

/** Where the code is typed (the page the QR code opens on tvOS). */
private const val linkAddress = "plex.tv/link"

/**
 * Mirrors `TVPlexSignInView`: **sign in with Plex on the TV, a code instead of a browser.** The
 * phone opens Plex's page in a window; the TV has no browser, so the page holds the code in large
 * fields and says where to type it (plex.tv/link), with the time left. The app polls plex.tv until the
 * code is confirmed, then goes on as the phone does: who is watching (Plex Home, with a PIN on the
 * remote's keyboard where protected), then which server.
 *
 * Draws `PlexSignInModel` (`SignInModels.kt`) and nothing else. The Back key is one step back
 * (`model.goBack()`).
 *
 * While it waits, the QR code of the same page stands left of the code (ZXing's encoder, error correction M like tvOS).
 */
@Composable
fun TvPlexSignInPage(app: SwiftlyApplication, finished: () -> Unit, back: () -> Unit) {
    val scope = rememberCoroutineScope()
    val model = remember { PlexSignInModel(app, scope, tv = true, finished = finished, leave = back) }
    val step = model.step
    val waiting = step is PlexStep.Waiting
    LaunchedEffect(waiting) { if (waiting) model.poll() }
    DisposableEffect(Unit) { onDispose { model.dispose() } }
    BackHandler { model.goBack() }

    Box(Modifier.fillMaxSize().background(Theme.reason), contentAlignment = Alignment.Center) {
        Column(Modifier.width(TvSpec.messageWidth)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(TvSpec.pickerCardGap)) {
                ServerKindMark(ServerKind.Plex, TvSpec.pickerCardMark)
                Text(model.title, style = TvTheme.titleLarge, color = Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            // One step is one picture: the countdown inside "waiting" changes without fading.
            AnimatedContent(step, contentKey = { it::class },
                transitionSpec = { fadeIn(tween(TvSpec.revealMs)) togetherWith fadeOut(tween(TvSpec.revealMs)) },
                label = "plex") { s ->
                when (s) {
                    PlexStep.Start, PlexStep.Opening -> Intro(model, s == PlexStep.Opening)
                    is PlexStep.Waiting -> Waiting(model, s)
                    PlexStep.LoadingServers -> Placeholder()
                    is PlexStep.Profiles -> Profiles(model, s.list)
                    is PlexStep.Pin -> PinEntry(model, s.profile)
                    is PlexStep.Servers -> if (s.list.isEmpty()) NoServer(model) else ServerList(model, s.list)
                    PlexStep.PlexUnreachable -> Notice(Glyph.WlanDisruption, translated("plex.tv antwortet nicht"),
                        translated("Ohne plex.tv klappt die Anmeldung nicht. Hängt vielleicht das WLAN?"),
                        translated("Erneut versuchen") to { model.start() }, translated("Zurück") to { model.goBack() })
                    PlexStep.Expired -> Notice(Glyph.History, translated("Die Anmeldung ist abgelaufen"),
                        translated("Der Code war zu lange offen. Hol dir einfach einen neuen."),
                        translated("Neuen Code holen") to { model.start() }, translated("Zurück") to { model.goBack() })
                    is PlexStep.Failed -> Notice(Glyph.Warning, translated("Anmeldung hat nicht geklappt"), s.message,
                        translated("Erneut versuchen") to { model.start() }, translated("Zurück") to { model.goBack() })
                }
            }
        }
    }
}

@Composable
private fun Intro(model: PlexSignInModel, opening: Boolean) {
    val focus = firstFocus()
    Column {
        Text(translated("Die Anmeldung läuft auf der Seite von Plex. Dein Passwort bekommt Swiftly Player nie zu sehen."),
             style = TvTheme.body, color = Theme.fontQuiet, modifier = Modifier.padding(top = TvSpec.onboardingSubtitleTop))
        Text(translated("Gleich bekommst du einen Code. Den gibst du am Handy oder Computer auf plex.tv/link ein."),
             style = TvTheme.body, color = Theme.fontQuiet, modifier = Modifier.padding(top = TvSpec.onboardingSubtitleTop))
        Row(Modifier.padding(top = TvSpec.onboardingBlockTop), horizontalArrangement = Arrangement.spacedBy(TvSpec.onboardingButtonSpacing)) {
            TvButton(translated(if (opening) "Wird geöffnet…" else "Mit Plex anmelden"), modifier = Modifier.focusRequester(focus),
                     released = !opening) { model.start() }
            TvButton(translated("Zurück")) { model.goBack() }
        }
    }
}

@Composable
private fun Waiting(model: PlexSignInModel, step: PlexStep.Waiting) {
    val focus = firstFocus()
    Column(Modifier.padding(top = TvSpec.onboardingBlockTop)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(TvSpec.plexWaitingGap)) {
            QrCode(step.url)
            Column(verticalArrangement = Arrangement.spacedBy(TvSpec.onboardingHintSpacing)) {
                Text(translated("Geh auf %@ und gib diesen Code ein.", linkAddress), style = TvTheme.body, color = Theme.font)
                step.code?.let { CodeFields(it) }
                val left = step.secondsLeft
                Text(if (left != null) translated("Warte auf Plex · noch %lld:%@", left / 60, "%02d".format(left % 60))
                     else translated("Warte auf Plex"),
                     style = TvTheme.small.copy(fontFeatureSettings = "tnum"), color = Theme.fontVeryQuiet)
            }
        }
        Row(Modifier.padding(top = TvSpec.plexActionsTop), horizontalArrangement = Arrangement.spacedBy(TvSpec.onboardingButtonSpacing)) {
            TvButton(translated("Neuen Code holen"), modifier = Modifier.focusRequester(focus)) { model.start() }
            TvButton(translated("Zurück")) { model.goBack() }
        }
    }
}

/** Mirrors the QR image of `TVPlexSignInView.waiting`: dark modules on a white card with the code's own quiet border, drawn without smoothing. */
@Composable
private fun QrCode(address: String) {
    val matrix = remember(address) {
        runCatching {
            QRCodeWriter().encode(address, BarcodeFormat.QR_CODE, 0, 0,
                mapOf(EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M, EncodeHintType.MARGIN to 0))
        }.getOrNull()
    } ?: return
    Box(Modifier.size(TvSpec.plexQrSize + TvSpec.plexQrInset * 2).clip(RoundedCornerShape(TvTheme.corner)).background(Color.White)
            .clearAndSetSemantics { },
        contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(TvSpec.plexQrSize)) {
            val cell = size.width / matrix.width
            for (y in 0 until matrix.height) for (x in 0 until matrix.width) {
                if (matrix[x, y]) drawRect(Color.Black, Offset(x * cell, y * cell), Size(cell + 0.5f, cell + 0.5f))
            }
        }
    }
}

/** Mirrors `CodeFields`: one field per character, set apart so you do not miscount while copying it to the phone. */
@Composable
private fun CodeFields(code: String) {
    val size = with(LocalDensity.current) { TvSpec.plexCodeFont.toSp() }
    Row(Modifier.clearAndSetSemantics { contentDescription = translated("Code") + " " + code.toList().joinToString(" ") },
        horizontalArrangement = Arrangement.spacedBy(TvSpec.plexCodeSpacing)) {
        code.forEach { c ->
            Box(Modifier.size(TvSpec.plexCodeWidth, TvSpec.plexCodeHeight).clip(RoundedCornerShape(TvTheme.corner)).background(Theme.raised),
                contentAlignment = Alignment.Center) {
                Text(c.toString(), style = TvTheme.titleLarge.copy(fontSize = size, fontWeight = FontWeight.Bold, fontFeatureSettings = "tnum"),
                     color = Theme.font)
            }
        }
    }
}

/** Placeholders in the shape of what comes next: the servers (the profiles arrive inside the poll's answer). */
@Composable
private fun Placeholder() {
    Column(Modifier.padding(top = TvSpec.onboardingBlockTop)) {
        TvGroupHeading(translated("Deine Server"))
        Column(verticalArrangement = Arrangement.spacedBy(TvSpec.plexServerSpacing)) {
            repeat(2) { LoadField(Modifier.fillMaxWidth().height(TvTheme.rowsHeight), TvTheme.corner) }
        }
    }
}

@Composable
private fun Profiles(model: PlexSignInModel, profiles: List<PlexProfile>) {
    val focus = firstFocus()
    LaunchedEffect(profiles) { model.lastProfiles = profiles }
    Column(Modifier.padding(top = TvSpec.onboardingBlockTop)) {
        TvGroupHeading(translated("Wer schaut?"))
        Row(Modifier.horizontalScroll(rememberScrollState()).padding(TvSpec.pickerRingGap + TvSpec.pickerRingWidth),
            horizontalArrangement = Arrangement.spacedBy(TvSpec.signInAccountSpacing), verticalAlignment = Alignment.Top) {
            profiles.forEachIndexed { index, profile ->
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(TvSpec.signInAccountNameTop)) {
                    TvPickCircle(profile.name, profile.image, TvSpec.signInAccountSize,
                                 modifier = if (index == 0) Modifier.focusRequester(focus) else Modifier,
                                 description = if (profile.protected) profile.name + ", " + translated("Mit PIN") else profile.name,
                                 overlay = { if (profile.protected) LockMark() }) { model.pickProfile(profile) }
                    Text(profile.name, style = TvTheme.small, color = Theme.fontQuiet, maxLines = 1, overflow = TextOverflow.Ellipsis,
                         modifier = Modifier.width(TvSpec.signInAccountSize + TvSpec.signInAccountSpacing))
                }
            }
        }
        Text(translated("Jedes Profil hat seinen eigenen Fortschritt."), style = TvTheme.small, color = Theme.fontVeryQuiet,
             modifier = Modifier.padding(top = TvSpec.signInAccountsTop))
    }
}

/** On the portrait's upper right edge, as a mark on a picture: a small field, not a circle (round is only what is a picture). */
@Composable
private fun LockMark() {
    Box(Modifier.size(TvSpec.plexLockBadge).background(Theme.raised, RoundedCornerShape(TvTheme.cornerSmall)), contentAlignment = Alignment.Center) {
        Symbol(Glyph.Padlock, TvSpec.plexLockIcon, color = Theme.fontQuiet, strength = Strength.Semibold)
    }
}

@Composable
private fun PinEntry(model: PlexSignInModel, profile: PlexProfile) {
    var pin by remember { mutableStateOf("") }
    var focused by remember { mutableStateOf(false) }
    val focus = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current
    LaunchedEffect(Unit) { kotlinx.coroutines.delay(2 * TvTheme.focusDeadline); runCatching { focus.requestFocus() }; keyboard?.show() }
    // A wrong PIN is wiped so the next try starts empty.
    LaunchedEffect(model.pinWrong) { if (model.pinWrong) pin = "" }
    // The field is disabled while the PIN is checked, which takes its focus (and the keyboard) with it;
    // after a wrong PIN nothing gave it back, so the next try needed a click first.
    LaunchedEffect(model.pinWrong, model.pinChecking) {
        if (model.pinWrong && !model.pinChecking) {
            kotlinx.coroutines.delay(TvTheme.focusDeadline)
            runCatching { focus.requestFocus() }
            keyboard?.show()
        }
    }
    Column(Modifier.padding(top = TvSpec.onboardingBlockTop)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(TvSpec.pickerCardGap)) {
            Box(Modifier.size(TvSpec.plexPinAvatar).clip(androidx.compose.foundation.shape.CircleShape)) { AccountCircle(profile.name, profile.image, TvSpec.plexPinAvatar) }
            Text(profile.name, style = TvTheme.rail, color = Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Text(translated("Dieses Profil hat eine PIN. Gib sie hier ein."), style = TvTheme.body, color = Theme.fontQuiet,
             modifier = Modifier.padding(top = TvSpec.onboardingSubtitleTop))
        // Four boxes; the field behind them takes the digits from the remote's keyboard. Shown as dots:
        // someone on the sofa next to you need not read the PIN. The boxes turn white while the field has focus.
        Box(Modifier.padding(top = TvSpec.plexPinTop)) {
            val boxFill by androidx.compose.animation.animateColorAsState(if (focused) Color.White else Theme.raised, tvTween(TvSpec.focusMs), label = "pin")
            Row(horizontalArrangement = Arrangement.spacedBy(TvSpec.plexPinSpacing)) {
                repeat(4) { index ->
                    Box(Modifier.size(TvSpec.plexPinWidth, TvSpec.plexPinHeight).clip(RoundedCornerShape(TvTheme.corner)).background(boxFill),
                        contentAlignment = Alignment.Center) {
                        Text(if (index < pin.length) "•" else "", style = TvTheme.titleLarge, color = if (focused) Theme.reason else Theme.font)
                    }
                }
            }
            BasicTextField(pin, { new ->
                val digits = new.filter { it.isDigit() }.take(4)
                pin = digits
                if (digits.isNotEmpty()) model.pinWrong = false
                if (digits.length == 4) model.submitPin(profile, digits)
            }, enabled = !model.pinChecking, singleLine = true,
                textStyle = TvTheme.body.copy(color = Color.Transparent), cursorBrush = SolidColor(Color.Transparent),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword, imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { keyboard?.hide() }),
                modifier = Modifier.matchParentSize().alpha(TvSpec.hiddenFieldOpacity).focusRequester(focus)
                    .onFocusChanged { focused = it.isFocused }.remoteBarField())
        }
        Box(Modifier.height(TvTheme.rowsHeight), contentAlignment = Alignment.CenterStart) {
            if (model.pinChecking) Text(translated("Wird geprüft…"), style = TvTheme.small, color = Theme.fontQuiet)
            else if (model.pinWrong) Text(translated("Die PIN passt nicht. Versuchs noch mal."), style = TvTheme.small, color = Theme.error)
        }
    }
}

@Composable
private fun ServerList(model: PlexSignInModel, servers: List<PlexServer>) {
    val focus = firstFocus()
    Column(Modifier.padding(top = TvSpec.onboardingBlockTop)) {
        TvGroupHeading(translated("Deine Server"))
        Column(Modifier.heightIn(max = TvSpec.plexServerListHeight).verticalScroll(rememberScrollState()),
               verticalArrangement = Arrangement.spacedBy(TvSpec.plexServerSpacing)) {
            servers.forEachIndexed { index, server ->
                ServerRow(model, server, if (index == 0) Modifier.focusRequester(focus) else Modifier)
            }
        }
        model.profileName?.let {
            Text(translated("Als %@", it), style = TvTheme.small, color = Theme.fontVeryQuiet, modifier = Modifier.padding(top = TvSpec.onboardingCodeTop))
        }
        TvButton(translated("Anderes Plex-Konto"), modifier = Modifier.padding(top = TvSpec.onboardingCodeTop),
                 released = model.connecting == null) { model.otherAccount() }
    }
}

@Composable
private fun ServerRow(model: PlexSignInModel, server: PlexServer, modifier: Modifier) {
    val busy = model.connecting == server.id
    val failed = server.id in model.unreachable
    val other = model.connecting != null && !busy
    FocusArea(modifier.fillMaxWidth().alpha(if (other) TvSpec.pickerDimWaitingOpacity else 1f), magnifier = 1f,
              perform = { if (!other) model.pickServer(server) }) { focus ->
        Row(Modifier.fillMaxWidth().heightIn(min = TvTheme.rowsHeight).clip(RoundedCornerShape(TvTheme.corner))
                .background(tvFocusSurface(focus)).padding(horizontal = TvSpec.pickerCardInsetHorizontal),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(TvSpec.plexServerGap)) {
            Box(Modifier.width(TvSpec.plexServerIconBox), contentAlignment = Alignment.Center) {
                Symbol(Glyph.Drive, TvSpec.valueIcon, color = Theme.fontQuiet)
            }
            Column(Modifier.weight(1f)) {
                Text(server.name, style = if (focus) TvTheme.button else TvTheme.body.copy(fontWeight = FontWeight.Medium),
                     color = Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (busy) Text(translated("Verbinden…"), style = TvTheme.small, color = Theme.font, maxLines = 1)
                else if (failed) Text(translated("Antwortet gerade nicht. Tipp für einen neuen Versuch."), style = TvTheme.small, color = Theme.error, maxLines = 1)
                else {
                    val owner = server.sharedBy?.let { translated("Von %@ freigegeben", it) } ?: translated("Dein Server")
                    val place = if (!server.online) translated("laut Plex offline")
                                else if (server.local) translated("im WLAN") else translated("über das Internet")
                    Text("$owner · $place", style = TvTheme.small, color = Theme.fontQuiet, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            // Running now: a spinner where the arrow stands, so the press visibly did something.
            if (busy) de.paulherter.swiftly.Spinner(TvSpec.valueIcon)
            else Symbol(Glyph.AngleRight, TvSpec.valueIcon, color = Theme.fontVeryQuiet, strength = Strength.Semibold)
        }
    }
}

@Composable
private fun NoServer(model: PlexSignInModel) {
    Notice(Glyph.Server, translated("Kein Server auf diesem Konto"),
           translated("Richte Plex Media Server ein oder lass dir einen freigeben. Danach hier noch mal suchen."),
           translated("Noch mal suchen") to { model.loadServers() }, translated("Anderes Plex-Konto") to { model.otherAccount() })
}

/** The empty state of the other pages, left-aligned in the column and with two ways on. */
@Composable
private fun Notice(symbol: Glyph, title: String, text: String, primary: Pair<String, () -> Unit>, secondary: Pair<String, () -> Unit>) {
    val focus = firstFocus()
    Column(Modifier.padding(top = TvSpec.onboardingBlockTop)) {
        Symbol(symbol, TvSpec.plexNoticeIcon, color = Theme.fontVeryQuiet)
        Text(title, style = TvTheme.rail, color = Theme.font, modifier = Modifier.padding(top = TvSpec.onboardingSubtitleTop))
        Text(text, style = TvTheme.body, color = Theme.fontQuiet, modifier = Modifier.padding(top = TvSpec.onboardingSubtitleTop))
        Row(Modifier.padding(top = TvSpec.onboardingBlockTop), horizontalArrangement = Arrangement.spacedBy(TvSpec.onboardingButtonSpacing)) {
            TvButton(primary.first, modifier = Modifier.focusRequester(focus), perform = primary.second)
            TvButton(secondary.first, perform = secondary.second)
        }
    }
}
