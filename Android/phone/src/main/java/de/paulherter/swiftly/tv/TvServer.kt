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
fun TvServerOnboarding(app: SwiftlyApplication, preset: String?, back: () -> Unit) {
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

    Box(Modifier.fillMaxSize().background(Theme.reason), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.widthIn(max = 480.dp)) {
            Text(translated(if (preset != null) "Konto hinzufügen" else "Server hinzufügen"), style = TvTheme.titleLarge, color = Theme.font)
            if (s == null) {
                Text(translated("Ein zweiter Jellyfin mit eigenen Konten. Beide bleiben angemeldet; im Profil wechselst du zwischen ihnen."),
                     style = TvTheme.body, color = Theme.fontQuiet, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 16.dp))
                TvField(address, { address = it }, "tv.example.de", Modifier.padding(top = 22.dp).fillMaxWidth().focusRequester(inputField),
                       imeAction = ImeAction.Go, keyboardAction = { check() })
                Text(translated("https:// kannst du weglassen."), style = TvTheme.small, color = Theme.fontVeryQuiet,
                     modifier = Modifier.fillMaxWidth().padding(top = 8.dp))
                TvAdvanced(headers, modifier = Modifier.padding(top = 14.dp))
                TvButton(translated(if (examine) "Verbinden…" else "Weiter"), released = address.isNotBlank() && !examine,
                        modifier = Modifier.padding(top = 20.dp)) { check() }
            } else {
                Text(translated("Verbunden · Jellyfin %@", s.second), style = TvTheme.small, color = Theme.fontVeryQuiet, modifier = Modifier.padding(top = 16.dp))
                Text(s.first, style = TvTheme.rail, color = Theme.font, modifier = Modifier.padding(top = 4.dp))
                Column(Modifier.padding(top = 22.dp).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    TvField(user, { user = it }, translated("Benutzername"), Modifier.fillMaxWidth().focusRequester(inputField))
                    TvField(password, { password = it }, translated("Passwort"), Modifier.fillMaxWidth(),
                           secret = true, imeAction = ImeAction.Done, keyboardAction = { signIn() })
                }
                TvButton(translated(if (running) "Anmelden…" else "Anmelden"), released = user.isNotBlank() && !running,
                        modifier = Modifier.padding(top = 20.dp)) { signIn() }
                TvButton(translated("Lieber Quick Connect"), modifier = Modifier.padding(top = 14.dp)) { perCode = true }
            }
            error?.let {
                Text(it, style = TvTheme.body, color = Theme.warning, textAlign = TextAlign.Center,
                     modifier = Modifier.widthIn(max = 560.dp).padding(top = 16.dp))
            }
        }
    }
}
