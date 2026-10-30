package de.paulherter.swiftly.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.AccountSwitchTransition
import de.paulherter.swiftly.SwiftlyApplication
import de.paulherter.swiftly.core.Kern
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.motionReduced
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.delay
import org.json.JSONArray
import org.json.JSONObject

/**
 * **When the profile picker opens, and how large it draws.** Mirrors `ProfilePickerRule` (tvOS).
 * The decision is made once per process (`decide`), so a return from the background, a switch or a
 * sign-in cannot bring it up. The picker's switch and the row in Profile > Konto read the same key;
 * unset means on. Asks with a single account too.
 */
object ProfilePickerRule {
    const val key = "askProfileAtLaunch"
    private const val minimum = 1
    private var decided: Boolean? = null

    fun asks(app: SwiftlyApplication): Boolean = app.store.rememberValue(key) != "0"
    fun set(app: SwiftlyApplication, on: Boolean) = app.store.remember(key, if (on) "1" else "0")

    /** All accounts of all servers, with the server host. */
    fun accounts(app: SwiftlyApplication): List<Entry> {
        val bundle = app.store.accounts ?: return emptyList()
        val cards = runCatching { JSONArray(Kern.bundleOverview(bundle)) }.getOrNull() ?: return emptyList()
        return (0 until cards.length()).flatMap { i ->
            val card = cards.getJSONObject(i)
            val list = card.optJSONArray("konten") ?: JSONArray()
            (0 until list.length()).map { list.getJSONObject(it) }.map { a ->
                Entry(a.optString("kennung"), a.optString("name"), a.optString("bild").ifEmpty { null },
                      serverName(app, card.optString("adresse"), card.optString("host")), a.optBoolean("aktiv"))
            }
        }
    }

    class Entry(val id: String, val name: String, val image: String?, val server: String, val active: Boolean)

    /** `Session` has no server name: what the server reported is kept per address, else the host. */
    private fun serverName(app: SwiftlyApplication, address: String, host: String): String =
        app.store.rememberValue("serverNamenCache|" + address.lowercase())?.takeIf { it.isNotEmpty() } ?: host

    fun remember(app: SwiftlyApplication, name: String?) {
        val address = app.activeServer() ?: return
        val host = runCatching { java.net.URI(address).host }.getOrNull()
        if (name.isNullOrEmpty() || name == host) return
        val k = "serverNamenCache|" + address.lowercase()
        if (app.store.rememberValue(k) != name) app.store.remember(k, name)
    }

    /** Evaluated on the first call in this process; later calls return the same answer. */
    fun opensAtLaunch(app: SwiftlyApplication, ready: Boolean): Boolean {
        decided?.let { return it }
        val now = ready && app.deepLink.value == null && accounts(app).size >= minimum && asks(app)
        decided = now
        return now
    }

    /** Once a profile is chosen, a recreated activity in the same process must not ask again. */
    fun answered() { decided = false }

    /** 2 to 5 profiles: 140 and a gap of 40 (tvOS 280/80, halved); from 6: 110 and 32. */
    fun size(count: Int): Dp = if (count <= 5) 140.dp else 110.dp
    fun gap(count: Int): Dp = if (count <= 5) 40.dp else 32.dp
}

/** The way back from "off": the same setting as the picker's switch, in Profile > Konto. */
@Composable
internal fun AskAtLaunchRow(app: SwiftlyApplication) {
    var asks by remember { mutableStateOf(ProfilePickerRule.asks(app)) }
    TvToggleRow(translated("Beim Start fragen, wer schaut"), asks) {
        asks = !asks; ProfilePickerRule.set(app, asks)
    }
}

/**
 * **"Wer schaut?"** at cold start. Mirrors `ProfilePicker` (tvOS). Sits above the blurred home page of
 * the last profile; a press starts the ordinary account switch. Focus from the switch upwards goes
 * back to the avatar that was focused last.
 */
@Composable
fun TvProfilePicker(app: SwiftlyApplication, entered: Boolean, close: () -> Unit, notice: (String) -> Unit) {
    val accounts = remember { ProfilePickerRule.accounts(app) }
    val count = accounts.size
    val size = ProfilePickerRule.size(count)
    val gap = ProfilePickerRule.gap(count)
    var asks by remember { mutableStateOf(ProfilePickerRule.asks(app)) }
    var lastAvatar by remember { mutableStateOf(accounts.firstOrNull { it.active }?.id ?: accounts.firstOrNull()?.id ?: "") }
    val requesters = remember { accounts.associate { it.id to FocusRequester() } }
    val density = LocalDensity.current.density
    val calm = motionReduced()
    val waits = AccountSwitchTransition.waits
    val context = LocalContext.current
    var shown by remember { mutableStateOf(false) }
    LaunchedEffect(entered) { if (entered) shown = true }
    LaunchedEffect(Unit) { delay(2 * TvTheme.focusDeadline); runCatching { requesters[lastAvatar]?.requestFocus() } }
    // The press: the still image lies on top by now, the picker goes away underneath it.
    val backState = remember { AccountSwitchTransition.back }
    LaunchedEffect(AccountSwitchTransition.back) { if (AccountSwitchTransition.back != backState) close() }
    // Neither focus nor Back reach the page below: Back leaves to the Home Screen.
    BackHandler { (context as? android.app.Activity)?.finish() }

    @Composable fun entrance(index: Int): Modifier {
        val step by animateFloatAsState(if (shown) 1f else 0f,
            if (calm) tween(150) else tween(300, delayMillis = index * 60), label = "auftritt")
        return Modifier.alpha(step).scale(if (calm) 1f else 0.97f + 0.03f * step)
    }

    Box(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().padding(horizontal = TvTheme.edgePage).padding(top = 50.dp),
               horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(32.dp)) {
            Text(translated("Wer schaut?"), style = TvTheme.titleLarge, color = Theme.font,
                 modifier = entrance(0).semantics { heading() })
            val row: @Composable () -> Unit = {
                Row(horizontalArrangement = Arrangement.spacedBy(gap), verticalAlignment = Alignment.Top) {
                    accounts.forEachIndexed { index, a ->
                        var focused by remember { mutableStateOf(false) }
                        val frameRect = remember { arrayOf(Rect.Zero) }
                        Column(Modifier.width(size).then(entrance(index + 1)), horizontalAlignment = Alignment.CenterHorizontally,
                               verticalArrangement = Arrangement.spacedBy(18.dp)) {
                            Box(Modifier.focusRequester(requesters.getValue(a.id))) {
                                FocusArea(magnifier = TvTheme.focusMagnifier,
                                    focusChanged = { f -> focused = f; if (f) lastAvatar = a.id },
                                    perform = {
                                        if (waits) return@FocusArea
                                        val gone = ProfilePickerRule.accounts(app)
                                        if (gone.none { it.id == a.id }) {
                                            notice(translated("Das Profil gibts nicht mehr. Du bist bei %@.", app.username()))
                                            close(); return@FocusArea
                                        }
                                        AccountSwitchTransition.start(app, a.id, a.name, a.image, frameRect[0], Theme.reason, density, calm)
                                    }) { focus ->
                                    Box(Modifier.size(size).onGloballyPositioned { frameRect[0] = it.boundsInRoot() }
                                            .semantics {
                                                contentDescription = "${a.name}, ${a.server}. " + translated("Mit diesem Profil weiter")
                                            }.clip(CircleShape)
                                            .then(if (focus) Modifier.border(3.dp, Color.White, CircleShape) else Modifier)) {
                                        AccountCircle(a.name, a.image, size)
                                        Box(Modifier.fillMaxSize().background(Theme.reason.copy(alpha =
                                            if (waits) 0.6f else if (focus) 0f else 0.35f)))
                                    }
                                }
                            }
                            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                Text(a.name, color = if (waits) Theme.fontVeryQuiet else if (focused) Theme.font else Theme.fontQuiet,
                                     fontSize = 15.sp, fontWeight = if (focused) FontWeight.SemiBold else FontWeight.Medium,
                                     maxLines = 1, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center,
                                     modifier = Modifier.width(size + 20.dp).height(20.dp))
                                // Space is always reserved, only the opacity changes, so nothing jumps.
                                Text(a.server, style = TvTheme.small, color = Theme.fontQuiet, maxLines = 1,
                                     overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center,
                                     modifier = Modifier.width(size + 20.dp).height(15.dp).alpha(if (focused && !waits) 1f else 0f))
                            }
                        }
                    }
                }
            }
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
                if (count > 5) Box(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = TvTheme.edgePage)) { row() }
                else row()
            }
        }

        Row(Modifier.align(Alignment.BottomStart).padding(start = TvTheme.edgePage, bottom = TvTheme.edgeTop).then(entrance(count + 1)),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            // Up from the switch: back to the avatar we left, not to whichever lies geometrically above.
            Box(Modifier.focusProperties { up = requesters[lastAvatar] ?: FocusRequester.Default }) {
                FocusArea(magnifier = 1f, perform = { if (!waits) { asks = !asks; ProfilePickerRule.set(app, asks) } }) { focus ->
                    Row(Modifier.height(TvTheme.rowsHeight).clip(RoundedCornerShape(TvTheme.corner))
                            .background(if (focus) TvTheme.focusArea else Color.Transparent).padding(horizontal = 13.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text(translated("Immer fragen"), style = TvTheme.body, color = Theme.fontQuiet, maxLines = 1)
                        TvToggle(asks)
                    }
                }
            }
            Text(translated("Dann gehts direkt ins letzte Profil. Wieder an unter Profil › Konto."),
                 style = TvTheme.small, color = Theme.fontQuiet, maxLines = 1,
                 modifier = Modifier.alpha(if (asks) 0f else 1f).clearAndSetSemantics { })
        }
    }
}
