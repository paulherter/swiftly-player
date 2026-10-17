package de.paulherter.swiftly

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.unit.dp
import de.paulherter.swiftly.shared.Motion
import de.paulherter.swiftly.shared.InputField
import de.paulherter.swiftly.shared.PrimaryButton
import de.paulherter.swiftly.shared.Strength
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.translated
import de.paulherter.swiftly.core.Kern
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * One row in "Advanced": name and value of a custom header. Mirrors `Kopfzeile` in `LoginModel.swift`.
 * **Its own id, not the index.** Removing the second of three rows must not make the third's
 * value slide into the second while the user is still typing.
 */
class HeaderRow(name: String = "", value: String = "") {
    val id: String = UUID.randomUUID().toString()
    var name by mutableStateOf(name)
    var value by mutableStateOf(value)
    /** Swiftly sets this one itself; the row says so instead of silently doing nothing. */
    val locked: Boolean get() = Kern.headerLocked(name)
}

/** The rows as JSON `[{"name","wert"}]` for the core, which sanitises them with the same gate as everywhere. */
fun List<HeaderRow>.asJson(): String =
    JSONArray(map { JSONObject().put("name", it.name).put("wert", it.value) }).toString()

/** What of it may go out: `OwnHeaders.cleaned`, as JSON. */
fun List<HeaderRow>.cleaned(): String = Kern.ownHeadersCleaned(asJson())

fun headerRowOut(json: String): List<HeaderRow> = runCatching {
    val a = JSONArray(json)
    (0 until a.length()).map { a.getJSONObject(it).let { o -> HeaderRow(o.optString("name"), o.optString("wert")) } }
}.getOrDefault(emptyList())

/**
 * **The headers for a request to this address:** `OwnHeaders.felder(fuer:)` in the package.
 * Empty for any foreign host (TMDB, foreign images) and for everyone who entered nothing.
 */
fun ownHeadersFields(address: String): Map<String, String> {
    val o = runCatching { JSONObject(Kern.ownHeadersFields(address)) }.getOrNull() ?: return emptyMap()
    return o.keys().asSequence().associateWith { o.getString(it) }
}

/**
 * **Coil (OkHttp) sends the custom headers along** for posters, backdrops, tile sheets. Mirrors
 * `ImageCache` with `.withOwnHeaders` on Apple. Without an entry the request stays as it was.
 * VLC cannot take arbitrary headers; streams are excluded, as on Apple.
 */
object OwnHeadersCatch : okhttp3.Interceptor {
    override fun intercept(chain: okhttp3.Interceptor.Chain): okhttp3.Response {
        val petition = chain.request()
        val fields = ownHeadersFields(petition.url.toString())
        if (fields.isEmpty()) return chain.proceed(petition)
        val new = petition.newBuilder()
        fields.forEach { (name, value) -> new.header(name, value) }
        return chain.proceed(new.build())
    }
}

/**
 * **"Advanced": custom headers for a service in front of the server.** Mirrors
 * `AdvancedSection` in `AdvancedSection.swift`.
 * Cloudflare Access, Authelia, Authentik, Pangolin: whoever protects Jellyfin or Seerr this way
 * lets the app through only with certain headers (issue #4). Everyone else never needs it, hence
 * **collapsed and empty**; whoever does not open it sees no change. The values are credentials:
 * entered masked, stored in the vault, never logged.
 */
@Composable
fun AdvancedSection(rows: SnapshotStateList<HeaderRow>, expanded: Boolean = false, modifier: Modifier = Modifier) {
    var opened by rememberSaveable { mutableStateOf(false) }
    // Whoever already entered headers should see them.
    LaunchedEffect(Unit) { if (rows.isNotEmpty()) opened = true }
    val rotation by animateFloatAsState(if (opened) 90f else 0f, Motion.reveal(), label = "erweitert")
    Column(modifier.fillMaxWidth()) {
        if (!expanded) {
            Row(Modifier.heightIn(min = 44.dp).tapOn { opened = !opened },
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(translated("Erweitert"), style = Theme.small, color = Theme.fontQuiet)
                Symbol(Glyph.AngleRight, 11.dp, Modifier.rotate(rotation), color = Theme.fontQuiet, strength = Strength.Semibold)
            }
        }
        AnimatedVisibility(opened || expanded, enter = fadeIn(Motion.reveal()) + expandVertically(Motion.reveal()),
                           exit = fadeOut(Motion.reveal()) + shrinkVertically(Motion.reveal())) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(translated("Für einen Dienst vor deinem Server, etwa Cloudflare Access, Authelia oder Pangolin. Swiftly schickt die Header nur an diese Adresse."),
                     style = Theme.small, color = Theme.fontVeryQuiet)
                rows.forEach { row ->
                    androidx.compose.runtime.key(row.id) {
                        Column(Modifier.padding(top = 4.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Box(Modifier.weight(1f)) {
                                    InputField(row.name, { row.name = it }, Glyph.Tag, translated("Header-Name"))
                                }
                                Box(Modifier.size(44.dp).tapOn { rows.removeAll { it.id == row.id } },
                                    contentAlignment = Alignment.Center) {
                                    Symbol(Glyph.MinusCircle, 17.dp, color = Theme.fontVeryQuiet, description = translated("Entfernen"))
                                }
                            }
                            Box(Modifier.padding(end = 52.dp)) {
                                InputField(row.value, { row.value = it }, Glyph.Keys, translated("Wert"), secret = true)
                            }
                            if (row.locked) {
                                Text(translated("Den setzt Swiftly selbst."), style = Theme.small, color = Theme.warning)
                            }
                        }
                    }
                }
                // `SecondaryButtonStyle` with symbol and word, as on iPhone.
                Row(Modifier.padding(top = 4.dp).fillMaxWidth().heightIn(min = Theme.buttonHeight)
                        .background(Theme.area, RoundedCornerShape(Theme.corner)).tapOn { rows.add(HeaderRow()) },
                    horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                    Symbol(Glyph.Plus, 15.dp, color = Theme.font)
                    Spacer(Modifier.width(9.dp))
                    Text(translated("Header hinzufügen"), style = Theme.buttonText, color = Theme.font)
                }
            }
        }
    }
}

/** Rows for "Advanced", empty at first, like `@State private var headers: [Kopfzeile] = []`. */
@Composable
fun rememberHeaderRow(): SnapshotStateList<HeaderRow> = remember { mutableStateListOf() }

/**
 * **The custom headers of the server the app is currently connected to** (Settings → Server).
 * Mirrors `OwnHeadersPage`. Saving applies immediately to every further request, also images and downloads.
 */
@Composable
fun OwnHeadersPage(app: SwiftlyApplication, back: () -> Unit) {
    val server = app.activeServer()
    val rows = remember { mutableStateListOf<HeaderRow>().apply { addAll(headerRowOut(app.ownHeaders(server))) } }
    var secured by remember { mutableStateOf(Kern.ownHeadersCleaned(app.ownHeaders(server))) }
    SettingPage(translated("Eigene Header"), back) {
        Column(Modifier.padding(horizontal = Theme.edgeSpacing).padding(top = 10.dp)) {
            AdvancedSection(rows, expanded = true)
            if (rows.cleaned() != secured && server != null) {
                PrimaryButton(translated("Sichern"), modifier = Modifier.padding(top = 22.dp)) {
                    app.ownHeadersSafe(rows.asJson(), server)
                    secured = Kern.ownHeadersCleaned(app.ownHeaders(server))
                }
            }
        }
    }
}
