package de.paulherter.swiftly

import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Strength
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
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
import de.paulherter.swiftly.shared.InputField
import de.paulherter.swiftly.shared.PrimaryButton
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.Wordmark
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

/** Mirrors `ConnectView` in `Sources/Shared/RootView.swift`. */
@Composable
fun ServerPage(app: SwiftlyApplication, connected: (String, String) -> Unit) {
    var address by remember { mutableStateOf(app.store.lastServer ?: "") }
    var running by remember { mutableStateOf(false) }
    /** The running check; only it may take effect. A changed address cancels it. */
    var verification by remember { mutableStateOf<Job?>(null) }
    // After a revoked sign-in this says why the server choice is shown again.
    var error by remember { mutableStateOf<String?>(app.loginHint.value.also { app.loginHint.value = null }) }
    val scope = rememberCoroutineScope()
    /** "Advanced": custom headers for a service in front of the server. */
    val headers = rememberHeaderRow()

    fun linkUp() {
        if (address.isBlank() || running) return
        running = true; error = null
        val checked = address
        verification = scope.launch {
            try {
                val json = withContext(Dispatchers.IO) { app.kern.linkUp(checked, headers.asJson()).await() }
                // Store only now: for an address where nothing answers, nothing is left behind.
                if (headers.isNotEmpty()) app.storeOwnHeaders()
                val answer = JSONObject(json)
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

    Column(
        Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 28.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Column(Modifier.widthIn(max = Theme.formWidth), horizontalAlignment = Alignment.CenterHorizontally) {
            Box172 { Wordmark(height = 40.dp) }
            Text(translated("Wo steht dein Jellyfin-Server?"), style = Theme.body, color = Theme.fontQuiet,
                 modifier = Modifier.padding(top = 44.dp))
            Column(Modifier.padding(top = 18.dp)) {
                InputField(address, { addressChange(it) }, Glyph.Globe, "tv.beispiel.de", address = true) { linkUp() }
            }
            Text(translated("https:// kannst du weglassen."), style = Theme.small, color = Theme.fontVeryQuiet,
                 modifier = Modifier.fillMaxWidth().padding(top = 9.dp, start = 2.dp))
            AdvancedSection(headers, modifier = Modifier.padding(top = 6.dp))
            PrimaryButton(if (running) translated("Verbinden…") else translated("Verbinden"),
                       released = address.isNotBlank() && !running,
                       modifier = Modifier.padding(top = 22.dp)) { linkUp() }
            error?.let {
                // `error`, not `warning`: the connection failed, it is not waiting.
                Text(it, style = Theme.small, color = Theme.error, textAlign = TextAlign.Center,
                     modifier = Modifier.padding(top = 14.dp))
            }
        }
    }
}

@Composable
private fun Box172(content: @Composable () -> Unit) {
    Column(Modifier.padding(top = 172.dp)) { content() }
}
