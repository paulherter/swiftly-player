package de.paulherter.swiftly.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.SwiftlyApplication
import de.paulherter.swiftly.errorString
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.asJson
import de.paulherter.swiftly.shared.Wordmark
import de.paulherter.swiftly.shared.translated
import de.paulherter.swiftly.core.Kern
import android.os.SystemClock
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/**
 * Mirrors `ServerView` and `SignInView` in `Sources/tvOS/RootView.swift` and `QuickConnectView` in
 * `Sources/tvOS/QuickConnectView.swift`. `TvActivity` used to borrow the phone pages
 * (`ServerPage`, `LoginPage`, `QuickConnectLogin` from `AccountsPages.kt`) for all three
 * steps, with tap-oriented `Eingabefeld`/`Hauptknopf`/`Nebenknopf`, no focus ring and not tvOS's
 * own order (fields first, Quick Connect equal beside it instead of ahead). This file replaces
 * that with real TV pages.
 *
 * **No "Who's watching?".** The row of recently signed-in accounts exists only in
 * `Sources/Shared/RootView.swift` (iPhone/iPad); `Sources/tvOS/RootView.swift` has none, its
 * `SignInView` is just user name, password, button. Adopting it would rebuild the iPhone version,
 * not the tvOS model, so it is deliberately absent.
 *
 * `TvField` (instead of an invisible `TextField` behind own drawing as on tvOS) is in `TvTheme.kt`:
 * Android does not force a white capsule on a `BasicTextField`, so the detour is unnecessary there.
 */
@Composable
fun TvServerPage(app: SwiftlyApplication, connected: (String, String) -> Unit) {
    var address by remember { mutableStateOf(app.store.lastServer ?: "") }
    var running by remember { mutableStateOf(false) }
    /** The running check: only it may take effect; a changed address cancels it. */
    var verification by remember { mutableStateOf<Job?>(null) }
    // After a revoked sign-in, this says why the user is back on server selection.
    var error by remember { mutableStateOf<String?>(app.loginHint.value.also { app.loginHint.value = null }) }
    val run = rememberCoroutineScope()
    val focus = firstFocus()
    /** "Advanced": custom headers for a service in front of the server. */
    val headers = de.paulherter.swiftly.rememberHeaderRow()

    fun linkUp() {
        if (address.isBlank() || running) return
        running = true; error = null
        val checked = address
        verification = run.launch {
            try {
                val answer = JSONObject(withContext(Dispatchers.IO) { app.kern.linkUp(checked, headers.asJson()).await() })
                // Store only now: for an address where nothing answers, nothing is left behind.
                if (headers.isNotEmpty()) app.storeOwnHeaders()
                app.store.lastServer = checked
                connected(answer.getString("name"), answer.getString("version"))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                error = errorString(app, e)
            } finally {
                // A cancelled check already releases the form in `addressChange`.
                if (verification == coroutineContext[Job]) running = false
            }
        }
    }

    /** Like `AppModel.addressChanged` on Apple: changing the address during the check cancels it. */
    fun addressChange(new: String) {
        if (new != address && running) {
            verification?.cancel(); verification = null; running = false; error = null
        }
        address = new
    }

    Box(Modifier.fillMaxSize().background(Theme.reason), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.widthIn(max = 480.dp)) {
            Wordmark(height = 36.dp)
            Text(translated("Wo steht dein Jellyfin-Server?"), style = TvTheme.body, color = Theme.fontQuiet,
                 modifier = Modifier.padding(top = 28.dp))
            TvField(address, { addressChange(it) }, "tv.beispiel.de",
                   Modifier.padding(top = 16.dp).fillMaxWidth().focusRequester(focus),
                   imeAction = ImeAction.Go, keyboardAction = { linkUp() })
            Text(translated("https:// kannst du weglassen."), style = TvTheme.small, color = Theme.fontVeryQuiet,
                 modifier = Modifier.fillMaxWidth().padding(top = 8.dp))
            TvAdvanced(headers, modifier = Modifier.padding(top = 14.dp))
            TvButton(translated(if (running) "Verbinden…" else "Verbinden"), released = address.isNotBlank() && !running,
                    modifier = Modifier.padding(top = 22.dp)) { linkUp() }
            // **No ring replacing the button**, as on tvOS: the button keeps its place and its label says
            // "Connecting…" instead of hiding.
            error?.let {
                Text(it, style = TvTheme.body, color = Theme.warning, textAlign = TextAlign.Center,
                     modifier = Modifier.widthIn(max = 560.dp).padding(top = 18.dp))
            }
        }
    }
}

/**
 * Mirrors `SignInView`: user name, password, "Sign in", below it equal "Quick Connect" and "Other
 * server". `moreAccount`: the same page for a second account (see `TvUnterseite` in `TvMain.kt`,
 * target `WeiteresKonto`); then the bottom says "Cancel" instead of "Other server", both call the
 * same `otherServer`, as in the phone version (`LoginPage.kt`).
 */
@Composable
fun TvLoginPage(app: SwiftlyApplication, serverName: String, version: String,
                   moreAccount: Boolean = false, otherServer: () -> Unit, signedIn: () -> Unit) {
    var user by remember { mutableStateOf("") }
    var passphrase by remember { mutableStateOf("") }
    var running by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var quickConnect by remember { mutableStateOf(false) }
    val run = rememberCoroutineScope()
    val focus = firstFocus()

    fun signIn() {
        if (user.isBlank() || running) return
        running = true; error = null
        run.launch {
            try {
                val session = withContext(Dispatchers.IO) { app.kern.signIn(user, passphrase).await() }
                app.sessionRecord(session)
                signedIn()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                error = errorString(app, e)
            } finally { running = false }
        }
    }

    Box(Modifier.fillMaxSize().background(Theme.reason), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.widthIn(max = 480.dp)) {
            Wordmark(height = 30.dp)
            Text(serverName, style = TvTheme.rail, color = Theme.font, modifier = Modifier.padding(top = 22.dp))
            if (version.isNotEmpty()) {
                Text(translated("Jellyfin %@", version), style = TvTheme.small, color = Theme.fontVeryQuiet,
                     modifier = Modifier.padding(top = 3.dp))
            }
            Column(Modifier.padding(top = 22.dp).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                TvField(user, { user = it }, translated("Benutzername"), Modifier.fillMaxWidth().focusRequester(focus))
                TvField(passphrase, { passphrase = it }, translated("Kennwort"), Modifier.fillMaxWidth(),
                       secret = true, imeAction = ImeAction.Done, keyboardAction = { signIn() })
            }
            TvButton(translated(if (running) "Anmelden…" else "Anmelden"), released = user.isNotBlank() && !running,
                    modifier = Modifier.padding(top = 20.dp)) { signIn() }
            error?.let {
                Text(it, style = TvTheme.body, color = Theme.warning, textAlign = TextAlign.Center,
                     modifier = Modifier.widthIn(max = 560.dp).padding(top = 16.dp))
            }
            // Equal, side by side, no submenu: on TV the better way than the password field above it, see
            // `SignInView`.
            Row(Modifier.padding(top = 30.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                TvButton(translated("Quick Connect")) { quickConnect = true }
                TvButton(translated(if (moreAccount) "Abbrechen" else "Anderer Server"), perform = otherServer)
            }
        }
        if (quickConnect) {
            TvQuickConnectPage(app, close = { quickConnect = false }) { session ->
                app.sessionRecord(session)
                quickConnect = false
                signedIn()
            }
        }
    }
}

/**
 * Mirrors `QuickConnectView`: the code is large and in separate fields, readable across the room;
 * below it the instructions in three steps. Same facade as `QuickConnectLogin`
 * (`AccountsPages.kt`): `Kern.quickConnectDeadline/-Starten/-Freigegeben/-Anmelden`; only the drawing
 * is tvOS's own.
 */
@Composable
fun TvQuickConnectPage(app: SwiftlyApplication, newServer: Boolean = false, close: () -> Unit, signedIn: (String) -> Unit) {
    val deadline = remember { JSONArray(Kern.quickConnectDeadline()) }
    val seconds = deadline.getInt(0)
    var code by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var rest by remember { mutableIntStateOf(0) }
    var run by remember { mutableIntStateOf(0) }
    BackHandler(onBack = close)

    LaunchedEffect(run) {
        code = null; error = null
        try {
            code = withContext(Dispatchers.IO) { app.kern.quickConnectStart(newServer).await() }
            // **The waiting lives in the package** (`QuickConnectWait`, via the core): deadline on the clock,
            // ask immediately after returning from the browser, a network error does not end the waiting.
            // Here only show the time left and accept the result.
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
                // Page closed or new code: stop asking, otherwise a late approval would sign in.
                app.kern.quickConnectWaitEnd(c)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            error = errorString(app, e)
        }
    }

    Box(Modifier.fillMaxSize().background(Theme.reason)) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(top = 64.dp, bottom = 40.dp),
               horizontalAlignment = Alignment.CenterHorizontally) {
            Text(translated("Quick Connect"), style = TvTheme.titleLarge, color = Theme.font)
            Text(translated("Gib diesen Code in Jellyfin auf einem Gerät ein, an dem du schon angemeldet bist."),
                 style = TvTheme.body, color = Theme.fontQuiet, textAlign = TextAlign.Center,
                 modifier = Modifier.widthIn(max = 560.dp).padding(top = 12.dp))

            val c = code
            when {
                c != null -> {
                    Row(Modifier.padding(top = 32.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        c.forEach { symbolText ->
                            Box(Modifier.size(58.dp, 78.dp).clip(RoundedCornerShape(TvTheme.corner))
                                    // **No border** and `area` instead of `erhoeht`: `erhoeht` is what lies on a surface, and
                                    // nothing lies beneath here.
                                    .background(Theme.area),
                                contentAlignment = Alignment.Center) {
                                Text(symbolText.toString(), style = TvTheme.titleLarge.copy(fontWeight = FontWeight.SemiBold, letterSpacing = 0.sp), color = Theme.font)
                            }
                        }
                    }
                    // No ring: the row itself already counts down, as on tvOS.
                    Text(translated("Läuft ab in %lld:%@", rest / 60, "%02d".format(rest % 60)),
                         style = TvTheme.small, color = Theme.fontVeryQuiet, modifier = Modifier.padding(top = 16.dp))
                }
                error != null -> Text(error.orEmpty(), style = TvTheme.body, color = Theme.warning, textAlign = TextAlign.Center,
                                       modifier = Modifier.widthIn(max = 560.dp).padding(top = 32.dp))
                // The code is coming; until then its shape is shown.
                else -> Box(Modifier.padding(top = 40.dp).size(280.dp, 78.dp).clip(RoundedCornerShape(TvTheme.corner)).background(Theme.area))
            }

            Column(Modifier.padding(top = 32.dp).widthIn(max = 460.dp)) {
                Text(translated("So gehts"), style = TvTheme.rail,
                     color = Theme.fontVeryQuiet)
                listOf("Jellyfin im Browser öffnen und anmelden", "Oben rechts aufs Profil, dann Quick Connect",
                       "Code eingeben, dann geht es hier von selbst weiter").forEachIndexed { i, step ->
                    Row(Modifier.padding(top = 10.dp)) {
                        Text("${i + 1}", style = TvTheme.body, color = Theme.fontVeryQuiet, modifier = Modifier.width(26.dp))
                        Text(translated(step), style = TvTheme.body, color = Theme.fontQuiet)
                    }
                }
            }

            Row(Modifier.padding(top = 32.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                TvButton(translated("Neuer Code")) { run++ }
                TvButton(translated("Zurück"), perform = close)
            }
        }
    }
}
