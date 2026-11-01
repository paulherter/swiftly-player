package de.paulherter.swiftly.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import de.paulherter.swiftly.*
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.asJson
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * Mirrors `ServerOnboardingView` on tvOS: another Jellyfin server. **Quick Connect first**, name and
 * password only as a fallback, the same trade-off as `TvLoginPage` (`TvLogin.kt`), whose
 * `TvField`/`TvButton`/`TvQuickConnectPage` blocks this page also uses. The running session stays
 * untouched: `onboardingConnect`/`onboardingSignIn` work on a client of their own, as in
 * `ServerOnboardingPage` on the phone: the same kernel functions, no logic of their own.
 * `preset`: from "add account" on a foreign server card in the profile (`TvProfile.kt`,
 * account section).
 */
@Composable
fun TvServerOnboarding(app: SwiftlyApplication, preset: String?, kindPicked: Boolean = false, back: () -> Unit) {
    var address by remember { mutableStateOf(preset.orEmpty()) }
    var server by remember { mutableStateOf<Pair<String, String>?>(null) }
    var examine by remember { mutableStateOf(false) }
    var perCode by remember { mutableStateOf(true) }
    var user by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var running by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val run = rememberCoroutineScope()
    /** "Advanced": custom headers for a service in front of the server. */
    val headers = de.paulherter.swiftly.rememberHeaderRow()

    fun cancel() { app.kern.onboardingCancel(); back() }
    fun record(session: String) { app.kern.onboardingCancel(); app.sessionRecord(session); back() }
    fun check() {
        if (address.isBlank() || examine) return
        examine = true; error = null
        run.launch {
            try {
                val o = JSONObject(withContext(Dispatchers.IO) { app.kern.onboardingConnect(address, headers.asJson()).await() })
                if (headers.isNotEmpty()) app.storeOwnHeaders()
                server = o.getString("name") to o.getString("version")
            } catch (x: CancellationException) { throw x } catch (x: Exception) { error = errorString(app, x) }
            examine = false
        }
    }
    fun signIn() {
        if (user.isBlank() || running) return
        running = true; error = null
        run.launch {
            try { record(withContext(Dispatchers.IO) { app.kern.onboardingSignIn(user, password).await() }) }
            catch (x: CancellationException) { throw x } catch (x: Exception) { error = errorString(app, x) }
            running = false
        }
    }
    LaunchedEffect(Unit) { if (preset != null) check() }

    val s = server
    // Once the server is set, the shared code screen takes over; going back from there only switches
    // to the form, not out of the whole page.
    if (s != null && perCode) {
        TvQuickConnectPage(app, newServer = true, close = { perCode = false }) { record(it) }
        return
    }
    BackHandler { cancel() }
    val inputField = firstFocus()

    // Left-aligned column like `ServerOnboardingView`: title, explanation, then address or sign-in, error, "Cancel".
    Box(Modifier.fillMaxSize().background(Theme.reason), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.Start, modifier = Modifier.width(TvSpec.messageWidth)) {
            Text(translated(if (kindPicked && preset == null) "Mit Jellyfin anmelden" else "Server hinzufügen"), style = TvTheme.titleLarge, color = Theme.font)
            Text(translated("Ein zweiter Jellyfin mit eigenen Konten. Beide bleiben angemeldet; im Profil wechselst du zwischen ihnen."),
                 style = TvTheme.body, color = Theme.fontQuiet, modifier = Modifier.width(TvSpec.messageWidth).padding(top = TvSpec.onboardingSubtitleTop))
            if (s == null) {
                Column(Modifier.padding(top = TvSpec.onboardingBlockTop), verticalArrangement = Arrangement.spacedBy(TvSpec.onboardingHintSpacing)) {
                    TvField(address, { address = it }, "tv.beispiel.de", Modifier.width(TvSpec.formWidth).focusRequester(inputField),
                           imeAction = ImeAction.Go, keyboardAction = { check() })
                    Text(translated("https:// kannst du weglassen."), style = TvTheme.small, color = Theme.fontVeryQuiet)
                    TvAdvanced(headers)
                    TvButton(translated(if (examine) "Moment…" else "Weiter"), released = address.isNotBlank() && !examine) { check() }
                }
            } else {
                Column(Modifier.padding(top = TvSpec.onboardingBlockTop)) {
                    // No accent: server name and version are information, not a choice.
                    Text("${s.first} · Jellyfin ${s.second}", style = TvTheme.small, color = Theme.fontQuiet)
                    Column(Modifier.padding(top = TvSpec.onboardingFormTop).width(TvSpec.formWidth),
                           verticalArrangement = Arrangement.spacedBy(TvSpec.onboardingHintSpacing)) {
                        TvField(user, { user = it }, translated("Benutzername"), Modifier.fillMaxWidth().focusRequester(inputField))
                        TvField(password, { password = it }, translated("Passwort"), Modifier.fillMaxWidth(),
                               secret = true, imeAction = ImeAction.Done, keyboardAction = { signIn() })
                        Row(horizontalArrangement = Arrangement.spacedBy(TvSpec.onboardingButtonSpacing)) {
                            TvButton(translated(if (running) "Moment…" else "Anmelden"), released = user.isNotBlank() && !running) { signIn() }
                            TvButton(translated("Lieber Quick Connect")) { perCode = true }
                        }
                    }
                }
            }
            error?.let {
                Text(it, style = TvTheme.small, color = Theme.error, modifier = Modifier.padding(top = TvSpec.onboardingErrorTop))
            }
            TvButton(translated("Abbrechen"), modifier = Modifier.padding(top = TvSpec.onboardingCancelTop)) { cancel() }
        }
    }
}
