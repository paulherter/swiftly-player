package de.paulherter.swiftly

import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Strength
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
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
import kotlinx.coroutines.delay
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/**
 * Mirrors `ConnectView` in `Sources/Shared/RootView.swift`.
 *
 * `back`: reached through the kind picker. Then a subpage with its arrow back to the picker and
 * "Mit Jellyfin anmelden" on top, and the wordmark stays on the picker where it already stood.
 * `presetAddress`: an address another page already knows (Emby found a Jellyfin there).
 */
@Composable
fun ServerPage(app: SwiftlyApplication, back: (() -> Unit)? = null, presetAddress: String? = null,
               connected: (String, String) -> Unit) {
    var address by remember { mutableStateOf(presetAddress ?: app.store.lastServer ?: "") }
    var running by remember { mutableStateOf(false) }
    /** The running check; only it may take effect. A changed address cancels it. */
    var verification by remember { mutableStateOf<Job?>(null) }
    // After a revoked sign-in this says why the server choice is shown again.
    var error by remember { mutableStateOf<String?>(app.loginHint.value.also { app.loginHint.value = null }) }
    val scope = rememberCoroutineScope()
    /** "Advanced": custom headers for a service in front of the server. */
    val headers = rememberHeaderRow()
    val found = rememberFoundServers(app)

    fun linkUp() {
        if (address.isBlank() || running) return
        running = true; error = null
        val checked = address
        verification = scope.launch {
            try {
                val json = withContext(Dispatchers.IO) { app.rk.linkUp(checked, headers.asJson()).await() }
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

    Column(Modifier.fillMaxSize()) {
    if (back != null) SubpageHeader(translated("Mit Jellyfin anmelden"), back)
    Column(
        Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = Theme.edgeSpacing),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Column(Modifier.widthIn(max = Theme.formWidth), horizontalAlignment = Alignment.CenterHorizontally) {
            if (back == null) Box172 { Wordmark(height = 40.dp) }
            Box(Modifier.padding(top = if (back == null) 44.dp else 24.dp)) { ServerKindMark(ServerKind.Jellyfin, 44.dp) }
            Text(translated("Wo steht dein Jellyfin-Server?"), style = Theme.body, color = Theme.fontQuiet,
                 modifier = Modifier.padding(top = 14.dp))
            Column(Modifier.padding(top = 18.dp)) {
                InputField(address, { addressChange(it) }, Glyph.Globe, "jellyfin.beispiel.de", address = true) { linkUp() }
            }
            if (presetAddress == null) Text(translated("https:// kannst du weglassen. Du bleibst auch beim anderen Server angemeldet."),
                 style = Theme.small, color = Theme.fontVeryQuiet,
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
            FoundServers(found, Modifier.padding(top = 36.dp)) { addressChange(it.address); linkUp() }
        }
    }
    }
}

/** A Jellyfin server that answered on the local network; see `ServerDiscovery` in the package. */
data class FoundServer(val name: String, val address: String, val short: String)

/**
 * Mirrors `.serverSearch` on Apple: the servers on the local network, while the page is shown.
 * One round after another in the core, which merges and sorts; leaving the page ends the loop.
 * `except`: addresses the page already offers some other way.
 */
@Composable
fun rememberFoundServers(app: SwiftlyApplication, except: List<String> = emptyList()): List<FoundServer> {
    var found by remember { mutableStateOf(emptyList<FoundServer>()) }
    LaunchedEffect(except) {
        val taken = JSONArray(except).toString()
        val pause = app.rk.serverSearchPause().toLong()
        var known = "[]"
        while (true) {
            known = withContext(Dispatchers.IO) { app.rk.serverSearch(known, taken).await() }
            val list = JSONArray(known)
            found = (0 until list.length()).map { i ->
                list.getJSONObject(i).let { FoundServer(it.getString("name"), it.getString("adresse"), it.getString("kurz")) }
            }
            delay(pause)
        }
    }
    return found
}

/**
 * Mirrors `FoundServersSection`: dot, name, address below, chevron, like "Zuletzt verbunden" on
 * iPhone. Nothing while no server has answered, so a network without one shows the page as before.
 */
@Composable
fun FoundServers(found: List<FoundServer>, modifier: Modifier = Modifier, pick: (FoundServer) -> Unit) {
    if (found.isEmpty()) return
    Column(modifier.fillMaxWidth()) {
        GroupsTitle(translated("Im Netzwerk gefunden"))
        SeparatorLine()
        found.forEach { server ->
            Row(Modifier.fillMaxWidth().pressRow { pick(server) }.padding(vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(Modifier.size(7.dp).clip(CircleShape).background(Theme.accent))
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(server.name, style = Theme.listTitle, color = Theme.font)
                    Text(server.short, style = Theme.small, color = Theme.fontVeryQuiet)
                }
                Symbol(Glyph.AngleRight, 13.dp, color = Theme.fontVeryQuiet, strength = Strength.Semibold)
            }
            SeparatorLine()
        }
    }
}

@Composable
private fun Box172(content: @Composable () -> Unit) {
    Column(Modifier.padding(top = 172.dp)) { content() }
}
