package de.paulherter.swiftly

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.InputField
import de.paulherter.swiftly.shared.PrimaryButton
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated

/**
 * Mirrors `EmbySignInView` (with `AppModel.embyCheck` / `embySignIn`): **the Jellyfin way, two steps
 * on one page.** An address, then name and password, with the accounts the server shows as pictures.
 * Built from the same parts as `ServerPage` and `LoginPage` and differs only in what it says.
 * Without Quick Connect (Emby has none) and without "Zuletzt verbunden" (the picker is the way back).
 *
 * One page instead of two: the header stays, only the column changes, so the arrow at the top
 * always goes one step back, not out of the flow by surprise.
 *
 * - `address`: a known server's address (the plus on its card); checked at once.
 * - `useJellyfin`: only offered when an address answers as Jellyfin.
 */
@Composable
fun EmbySignInPage(app: SwiftlyApplication, address: String?, finished: () -> Unit, back: () -> Unit,
                   useJellyfin: ((String) -> Unit)? = null) {
    val scope = rememberCoroutineScope()
    val model = remember { EmbySignInModel(app, scope, address, finished, back) }
    val headers = rememberHeaderRow()

    LaunchedEffect(Unit) { if (address != null) model.check(headers) }
    DisposableEffect(Unit) { onDispose { model.dispose() } }
    BackHandler(enabled = model.server != null) { model.goBack() }

    Column(Modifier.fillMaxSize().background(Theme.reason)) {
        SubpageHeader(translated("Mit Emby anmelden"), { model.goBack() })
        Box(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()), contentAlignment = Alignment.TopCenter) {
            Column(Modifier.widthIn(max = Theme.formWidth).fillMaxWidth().padding(horizontal = Theme.edgePageWide)
                       .padding(bottom = 40.dp).navigationBarsPadding().imePadding()) {
                val found = model.server
                if (found == null) AddressStep(model.address, { model.address = it; model.problem = null }, headers, model.checking,
                                               model.problem, { model.check(headers) }, useJellyfin)
                else SignInStep(found.first, found.second, model.users.orEmpty(), model.user,
                                { model.user = it; model.signInError = null }, model.password,
                                { model.password = it }, model.signingIn, model.signInError) { model.signIn() }
            }
        }
    }
}

@Composable
private fun AddressStep(address: String, change: (String) -> Unit, headers: androidx.compose.runtime.snapshots.SnapshotStateList<HeaderRow>,
                        checking: Boolean, problem: EmbyProblem?, check: () -> Unit, useJellyfin: ((String) -> Unit)?) {
    Column {
        Box(Modifier.padding(top = 8.dp)) { ServerKindMark(ServerKind.Emby, 44.dp) }
        Text(translated("Wo steht dein Emby-Server?"), style = Theme.body, color = Theme.fontQuiet,
             modifier = Modifier.padding(top = 20.dp))
        Box(Modifier.padding(top = 14.dp).alpha(if (checking) 0.6f else 1f)) {
            InputField(address, { if (!checking) change(it) }, Glyph.Globe, translated("emby.beispiel.de"), address = true) { check() }
        }
        Text(translated("https:// kannst du weglassen."), style = Theme.small, color = Theme.fontVeryQuiet,
             modifier = Modifier.fillMaxWidth().padding(top = 9.dp, start = 2.dp))
        AdvancedSection(headers, modifier = Modifier.padding(top = 6.dp))
        val empty = address.isBlank()
        PrimaryButton(translated(if (checking) "Verbinden…" else "Verbinden"), released = !empty && !checking,
                      modifier = Modifier.padding(top = 22.dp).alpha(if (empty) 0.4f else 1f)) { check() }
        when (problem) {
            null -> {}
            // The same hint as everywhere a server does not answer: one sentence for one situation.
            is EmbyProblem.Unreachable -> DisturbHint(problem.address, spacingTop = 32.dp, retry = check)
            is EmbyProblem.NotEmby -> Column(Modifier.padding(top = 14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(if (problem.found != null) translated("Unter der Adresse läuft %@, kein Emby.", problem.found)
                     else translated("Unter der Adresse antwortet etwas, aber kein Emby."),
                     style = Theme.small, color = Theme.error)
                // Jellyfin and Emby share their roots and answer alike: whoever typed the address of a
                // Jellyfin server here only picked the wrong card.
                if (useJellyfin != null && problem.found == ServerKind.Jellyfin.displayName) {
                    de.paulherter.swiftly.shared.SecondaryButton(translated("Mit Jellyfin weiter")) { useJellyfin(address) }
                }
            }
            is EmbyProblem.Other -> Text(problem.message, style = Theme.small, color = Theme.error,
                                         modifier = Modifier.padding(top = 14.dp))
        }
    }
}

@Composable
private fun SignInStep(serverName: String, version: String, users: List<EmbyUser>, user: String, userChange: (String) -> Unit,
                       password: String, passwordChange: (String) -> Unit, signingIn: Boolean, error: String?, signIn: () -> Unit) {
    Column {
        // The header of the Jellyfin page, with the other name: the accent dot is the state (it
        // answered), the name the place.
        Column(Modifier.padding(top = 24.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Box(Modifier.size(7.dp).background(Theme.accent, CircleShape))
                Text(translated("Verbunden · Emby %@", version), style = Theme.small, color = Theme.fontVeryQuiet)
            }
            Text(serverName, style = Theme.title, color = Theme.font)
        }
        if (users.isNotEmpty()) {
            Column(Modifier.padding(top = 22.dp)) {
                Text(translated("Wer schaut?"), style = Theme.rail, color = Theme.fontQuiet, modifier = Modifier.padding(bottom = 10.dp))
                Row(Modifier.horizontalScroll(rememberScrollState()).padding(vertical = 2.dp), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    users.forEach { AccountCharacter(it.name, it.image, user == it.name) { userChange(it.name) } }
                }
            }
        }
        Column(Modifier.padding(top = 28.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            InputField(user, userChange, Glyph.Person, translated("Benutzername"))
            InputField(password, passwordChange, Glyph.Padlock, translated("Passwort"), secret = true) { signIn() }
            PrimaryButton(translated(if (signingIn) "Anmelden…" else "Anmelden"), released = user.isNotEmpty() && !signingIn,
                          modifier = Modifier.padding(top = 10.dp).alpha(if (user.isEmpty()) 0.4f else 1f)) { signIn() }
            error?.let {
                Text(it, style = Theme.small, color = Theme.error, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
            }
        }
    }
}
