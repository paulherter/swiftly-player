package de.paulherter.swiftly.tv

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import de.paulherter.swiftly.EmbyProblem
import de.paulherter.swiftly.EmbySignInModel
import de.paulherter.swiftly.EmbyUser
import de.paulherter.swiftly.LoadField
import de.paulherter.swiftly.ServerKind
import de.paulherter.swiftly.ServerKindMark
import de.paulherter.swiftly.SwiftlyApplication
import de.paulherter.swiftly.rememberHeaderRow
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated

/**
 * Mirrors `TVEmbySignInView`: **sign in with Emby, the Jellyfin way, two steps on one page.** An
 * address, then name and password, with the accounts the server shows as large circles ("Wer
 * schaut?"). No Quick Connect: Emby has none. The steps and calls are the phone's `EmbySignInModel`
 * (`SignInModels.kt`); this file only draws it.
 *
 * The Back key is one step back: from the sign-in to the address, from the address out of the flow
 * (`model.goBack()`), the same arrow the phone shows at the top.
 */
@Composable
fun TvEmbySignInPage(app: SwiftlyApplication, address: String?, finished: () -> Unit, back: () -> Unit,
                     useJellyfin: ((String) -> Unit)? = null) {
    val scope = rememberCoroutineScope()
    val model = remember { EmbySignInModel(app, scope, address, finished, back) }
    val headers = rememberHeaderRow()

    LaunchedEffect(Unit) { if (address != null) model.check(headers) }
    DisposableEffect(Unit) { onDispose { model.dispose() } }
    BackHandler { model.goBack() }

    Box(Modifier.fillMaxSize().background(Theme.reason), contentAlignment = Alignment.Center) {
        Column(Modifier.width(TvSpec.messageWidth)) {
            AnimatedContent(model.server != null,
                transitionSpec = { fadeIn(tween(TvSpec.revealMs)) togetherWith fadeOut(tween(TvSpec.revealMs)) },
                label = "emby") { signedIn ->
                val found = model.server
                if (!signedIn || found == null) AddressStep(model, headers, useJellyfin)
                else SignInStep(model, found.first, found.second)
            }
        }
    }
}

@Composable
private fun AddressStep(model: EmbySignInModel, headers: androidx.compose.runtime.snapshots.SnapshotStateList<de.paulherter.swiftly.HeaderRow>,
                        useJellyfin: ((String) -> Unit)?) {
    val focus = firstFocus()
    Column {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(TvSpec.pickerCardGap)) {
            ServerKindMark(ServerKind.Emby, TvSpec.pickerCardMark)
            Text(translated("Mit Emby anmelden"), style = TvTheme.titleLarge, color = Theme.font, maxLines = 1)
        }
        Text(translated("Wo steht dein Emby-Server?"), style = TvTheme.body, color = Theme.fontQuiet,
             modifier = Modifier.padding(top = TvSpec.onboardingSubtitleTop))
        Column(Modifier.padding(top = TvSpec.onboardingBlockTop), verticalArrangement = Arrangement.spacedBy(TvSpec.onboardingHintSpacing)) {
            // Changing the address after an error takes the error away: it was about the old one.
            TvField(model.address, { if (!model.checking) { model.address = it; model.problem = null } }, "emby.beispiel.de",
                    Modifier.width(TvSpec.formWidth).focusRequester(focus),
                    imeAction = ImeAction.Go, keyboardType = KeyboardType.Uri, keyboardAction = { model.check(headers) })
            Text(translated("https:// kannst du weglassen."), style = TvTheme.small, color = Theme.fontVeryQuiet)
            TvAdvanced(headers)
            Row(horizontalArrangement = Arrangement.spacedBy(TvSpec.onboardingButtonSpacing)) {
                TvButton(translated(if (model.checking) "Verbinden…" else "Verbinden"),
                         released = model.address.isNotBlank() && !model.checking) { model.check(headers) }
                TvButton(translated("Zurück")) { model.goBack() }
            }
        }
        model.problem?.let { Problem(it, model.address, useJellyfin) }
    }
}

@Composable
private fun Problem(problem: EmbyProblem, address: String, useJellyfin: ((String) -> Unit)?) {
    Column(Modifier.padding(top = TvSpec.onboardingErrorTop), verticalArrangement = Arrangement.spacedBy(TvSpec.onboardingButtonSpacing)) {
        when (problem) {
            // The same sentence as everywhere a server does not answer, whichever kind it is.
            is EmbyProblem.Unreachable ->
                Text(translated("%@ antwortet nicht. Läuft er noch, oder hängt das WLAN?", problem.address),
                     style = TvTheme.body, color = Theme.error)
            is EmbyProblem.NotEmby -> {
                Text(if (problem.found != null) translated("Unter der Adresse läuft %@, kein Emby.", problem.found)
                     else translated("Unter der Adresse antwortet etwas, aber kein Emby."),
                     style = TvTheme.body, color = Theme.error)
                // Jellyfin and Emby share their roots and answer alike: whoever typed the address of a
                // Jellyfin server here only picked the wrong card.
                if (useJellyfin != null && problem.found == ServerKind.Jellyfin.displayName) {
                    TvButton(translated("Mit Jellyfin weiter")) { useJellyfin(address) }
                }
            }
            is EmbyProblem.Other -> Text(problem.message, style = TvTheme.body, color = Theme.error)
        }
    }
}

@Composable
private fun SignInStep(model: EmbySignInModel, serverName: String, version: String) {
    val focus = firstFocus()
    Column {
        // No accent. Server name and version are information, not a choice.
        Text(translated("Verbunden · Emby %@", version), style = TvTheme.small, color = Theme.fontVeryQuiet)
        Text(serverName, style = TvTheme.rail, color = Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis,
             modifier = Modifier.padding(top = TvSpec.loginVersionTop))

        Accounts(model)

        Column(Modifier.padding(top = TvSpec.signInFieldsTop).width(TvSpec.formWidth),
               verticalArrangement = Arrangement.spacedBy(TvSpec.loginFieldSpacing)) {
            TvField(model.user, { model.user = it; model.signInError = null }, translated("Benutzername"),
                    Modifier.width(TvSpec.formWidth).focusRequester(focus), enabled = !model.signingIn)
            TvField(model.password, { model.password = it }, translated("Passwort"), Modifier.width(TvSpec.formWidth),
                    secret = true, imeAction = ImeAction.Done, keyboardAction = { model.signIn() }, enabled = !model.signingIn)
        }
        Row(Modifier.padding(top = TvSpec.loginButtonTop), horizontalArrangement = Arrangement.spacedBy(TvSpec.onboardingButtonSpacing)) {
            TvButton(translated(if (model.signingIn) "Anmelden…" else "Anmelden"),
                     released = model.user.isNotEmpty() && !model.signingIn) { model.signIn() }
            TvButton(translated("Zurück")) { model.goBack() }
        }
        model.signInError?.let {
            Text(it, style = TvTheme.small, color = Theme.error, modifier = Modifier.padding(top = TvSpec.onboardingErrorTop))
        }
    }
}

/**
 * The accounts the server shows. While they come: circles in their shape, so the fields below do not
 * jump down when they arrive. None: nothing, the fields alone.
 */
@Composable
private fun Accounts(model: EmbySignInModel) {
    val users = model.users
    if (users == null) {
        Column(Modifier.padding(top = TvSpec.signInAccountsTop)) {
            TvGroupHeading(translated("Wer schaut?"))
            Row(horizontalArrangement = Arrangement.spacedBy(TvSpec.signInAccountSpacing)) {
                repeat(3) { LoadField(Modifier.size(TvSpec.signInAccountSize), TvSpec.signInAccountSize / 2) }
            }
        }
    } else if (users.isNotEmpty()) {
        Column(Modifier.padding(top = TvSpec.signInAccountsTop)) {
            TvGroupHeading(translated("Wer schaut?"))
            Row(Modifier.horizontalScroll(rememberScrollState())
                    .padding(TvSpec.pickerRingGap + TvSpec.pickerRingWidth),
                horizontalArrangement = Arrangement.spacedBy(TvSpec.signInAccountSpacing), verticalAlignment = Alignment.Top) {
                users.forEach { person -> Account(person, model.user == person.name) { model.user = person.name; model.signInError = null } }
            }
        }
    }
}

@Composable
private fun Account(person: EmbyUser, chosen: Boolean, perform: () -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(TvSpec.signInAccountNameTop)) {
        TvPickCircle(person.name, person.image, TvSpec.signInAccountSize, selected = chosen, perform = perform)
        Text(person.name, style = TvTheme.small, color = if (chosen) Theme.font else Theme.fontQuiet, maxLines = 1,
             overflow = TextOverflow.Ellipsis, modifier = Modifier.width(TvSpec.signInAccountSize + TvSpec.signInAccountSpacing))
    }
}
