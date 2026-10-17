package de.paulherter.swiftly

import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Strength
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import coil3.compose.AsyncImage
import org.json.JSONArray
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.shared.InputField
import de.paulherter.swiftly.shared.PrimaryButton
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Mirrors `LoginView` in `Sources/Shared/RootView.swift`: name and password, quick connect below.
 *
 * `moreAccount`: the same page for a second account on the connected server. Back at the top,
 * nothing at the bottom: as a pushed page it has the same arrow as any subpage, and two ways back
 * would be one too many. At the root, "Other server" stays at the bottom. The running session
 * stays until the new one is up.
 */
@Composable
fun LoginPage(app: SwiftlyApplication, serverName: String, version: String,
                 otherServer: () -> Unit, moreAccount: Boolean = false, signedIn: () -> Unit) {
    var user by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var running by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var quick by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    var knownOnes by remember { mutableStateOf<List<Triple<String, String, String?>>>(emptyList()) }
    LaunchedEffect(Unit) {
        knownOnes = runCatching {
            JSONArray(withContext(Dispatchers.IO) { app.kern.publicUser(false).await() }).let { a ->
                (0 until a.length()).map { a.getJSONObject(it) }.map { Triple(it.getString("kennung"), it.getString("name"), it.fieldText("bild")) }
            }
        }.getOrDefault(emptyList())
        // With exactly one account there is nothing to choose; making the user type the name anyway is a hurdle with no purpose.
        if (knownOnes.size == 1 && user.isEmpty()) user = knownOnes[0].second
    }

    if (quick) {
        QuickConnectLogin(app, newServer = false, back = { quick = false }) { session ->
            app.sessionRecord(session)
            signedIn()
        }
        return
    }

    fun signIn() {
        if (user.isBlank() || running) return
        running = true; error = null
        scope.launch {
            try {
                val session = withContext(Dispatchers.IO) { app.kern.signIn(user, password).await() }
                app.sessionRecord(session)
                signedIn()
            } catch (e: Throwable) {
                error = errorString(app, e)
            } finally { running = false }
        }
    }

    // Centred like the server page before it; pinned to the top, the change looked like a jump.
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val height = maxHeight
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).heightIn(min = height)
                .padding(horizontal = 28.dp).padding(bottom = 56.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            Column(Modifier.widthIn(max = Theme.formWidth).fillMaxWidth()) {
                Column(Modifier.padding(top = 24.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    if (version.isNotEmpty()) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Box(Modifier.size(7.dp).background(Theme.accent, CircleShape))
                            Text(translated("Verbunden · Jellyfin %@", version), style = Theme.small, color = Theme.fontVeryQuiet)
                        }
                    }
                    Text(serverName, style = Theme.title, color = Theme.font)
                }
                if (knownOnes.isNotEmpty()) {
                    Column(Modifier.padding(top = 22.dp)) {
                        // Group title: 20 semibold in normal case, not 11 in capitals. The capitals level still exists
                        // but now only carries badges. `schriftLeise`, because the heading announces the subject and is
                        // not one itself. The gap below grows with it: 10 instead of 8.
                        Text(translated("Wer schaut?"), style = Theme.rail,
                             color = Theme.fontQuiet, modifier = Modifier.padding(bottom = 10.dp))
                        Row(Modifier.horizontalScroll(rememberScrollState()).padding(vertical = 2.dp), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                            knownOnes.forEach { (_, name, image) -> AccountCharacter(name, image, user == name) { user = name } }
                        }
                    }
                }
                Column(Modifier.padding(top = 28.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    InputField(user, { user = it }, Glyph.Person, translated("Benutzername"))
                    InputField(password, { password = it }, Glyph.Padlock, translated("Passwort"), secret = true) { signIn() }
                    PrimaryButton(if (running) translated("Anmelden…") else translated("Anmelden"),
                               released = user.isNotBlank() && !running,
                               modifier = Modifier.padding(top = 10.dp)) { signIn() }
                    error?.let {
                        // `error`, not `warning`: a rejected sign-in went wrong.
                        Text(it, style = Theme.small, color = Theme.error, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
                    }
                    // Always there, as on iOS, which does not ask beforehand whether the server supports it; if it
                    // says no, that shows on the quick-connect page.
                    Or(Modifier.padding(top = 12.dp))
                    SecondaryButton(Glyph.Tv, translated("Mit Quick Connect anmelden")) { quick = true }
                }
            }
        }
        // 12 regular in `schriftSehrLeise`, 22 above the bottom edge; at the root only.
        if (moreAccount) Box(Modifier.align(Alignment.TopStart).background(Theme.reason)) {
            SubpageHeader(translated("Konto hinzufügen"), otherServer)
        } else Text(translated("Anderer Server"), style = Theme.small,
             color = Theme.fontVeryQuiet,
             modifier = Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 22.dp).pressRow(otherServer))
    }
}

/** Mirrors `AccountCharacter`: 60 circle, image or initial, selected with accent border. */
@Composable
private fun AccountCharacter(name: String, image: String?, selected: Boolean, perform: () -> Unit) {
    Column(Modifier.width(72.dp).tapOn(perform), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(Modifier.size(60.dp).clip(CircleShape).background(Theme.raised)
                // Ring: selected `font` 2, highlighted `accent` 1.5, otherwise `rand` 1 (`ProfileCharacter`).
                // Selected used to be the accent, but the accent carries state, and "I am meant" is a
                // selection, which white and weight express.
                .border(if (selected) 2.dp else 1.dp, if (selected) Theme.font else Theme.margin, CircleShape),
            contentAlignment = Alignment.Center) {
            // Letter = circle x 0.38 (60 x 0.38 = 22.8), not a number of its own.
            Text(name.take(1).uppercase(), style = TextStyle(fontSize = 22.8.sp, fontWeight = FontWeight.SemiBold),
                 color = if (selected) Theme.font else Theme.fontQuiet)
            if (image != null) AsyncImage(model = image, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize().clip(CircleShape))
        }
        Text(name, style = Theme.tile, color = if (selected) Theme.font else Theme.fontQuiet,
             maxLines = 2, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center)
    }
}
