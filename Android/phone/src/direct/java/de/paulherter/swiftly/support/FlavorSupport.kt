package de.paulherter.swiftly.support

import android.app.Activity
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import de.paulherter.swiftly.SwiftlyApplication
import de.paulherter.swiftly.core.Kern
import de.paulherter.swiftly.pressText
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.InputField
import de.paulherter.swiftly.shared.PrimaryButton
import de.paulherter.swiftly.shared.SecondaryButton
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import de.paulherter.swiftly.tv.TvButton
import de.paulherter.swiftly.tv.TvField
import de.paulherter.swiftly.tv.TvTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

/**
 * **The direct build (APK from GitHub): no store in between, so the app may point to the website.**
 * "Support on the website" opens the supporter page; the key from its thank-you page or email is
 * checked offline here (`SupporterKeyCheck`). No Billing library, no BILLING permission.
 *
 * Address and contact come from `DirectSupport` in the package's SupportKeyKit; the test
 * `SupporterKeyCheckTest` compares them.
 */
object FlavorSupport {
    /** `DirectSupport.websiteURL` (with the trailing slash the website serves). */
    const val WEBSITE = "https://swiftlyplayer.com/supporter/"
    /** `DirectSupport.contactEmail`. */
    const val CONTACT = "info@swiftlyplayer.com"

    fun channel(app: SwiftlyApplication, support: Support): SupportChannel = DirectChannel(keeper(app, support))

    /** The keeper on top of the app's records (`support.key`, `support.keyChecked`). */
    private fun keeper(app: SwiftlyApplication, support: Support) = SupporterKeyKeeper(
        storage = object : SupporterKeyKeeper.Storage {
            override fun get(key: String): String? = app.store.rememberValue(key)?.takeIf { it.isNotEmpty() }
            override fun set(key: String, value: String?) = app.store.remember(key, value.orEmpty())
        },
        sink = object : SupporterKeyKeeper.Sink {
            // The renewal runs on a background thread; state and records change on the main thread.
            private val main = android.os.Handler(android.os.Looper.getMainLooper())
            override fun grant(license: SupporterKeyCheck.License, fresh: Boolean) {
                val status = Kern.supportKeyStatus(license.issuedAtMs)
                main.post { support.becameSupporter(status, fresh = fresh, plan = license.plan) }
            }
            override fun withdraw() { main.post { support.keyStatusGone() } }
            override fun mayTouchStatus(): Boolean = support.source.value.let { it.isEmpty() || it == "key" }
        })

    /** Checks a key; on success stores it, the status and the plan, and asks for the thanks. */
    private fun activate(app: SwiftlyApplication, text: String): Boolean {
        val result = (app.support.channel as? DirectChannel)?.keeper?.activate(text) ?: return false
        if (result !is SupporterKeyCheck.Result.Valid) {
            Support.log("Schluessel abgelehnt: ${(result as SupporterKeyCheck.Result.Invalid).failure}")
            return false
        }
        return true
    }

    @Composable
    fun PhoneSheetBody(app: SwiftlyApplication, close: () -> Unit) {
        var entering by remember { mutableStateOf(false) }
        val context = LocalContext.current
        Column {
            SupportMark()
            if (!entering) {
                SheetText(translated("Wir bauen Swiftly ohne Werbung und ohne Tracking. Wenn es deine Abende besser macht, hilft uns ein Kaffee, weiterzumachen."))
                SheetText(translated("Alles bleibt für alle kostenlos."), quiet = false, top = 14.dp)
                SheetText(translated("Mit deinem Unterstützer-Schlüssel bekommst du ein Herz in „Über“ und zusätzliche App-Icons."), small = true, top = 4.dp)
                Column(Modifier.fillMaxWidth().padding(horizontal = Theme.edgeSpacing).padding(top = 18.dp),
                       verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    PrimaryButton(translated("Auf der Website unterstützen")) { close(); app.addressOpen(context, WEBSITE) }
                    Text(translated("Öffnet swiftlyplayer.com/supporter im Browser."), style = Theme.small, color = Theme.fontVeryQuiet,
                         modifier = Modifier.align(Alignment.CenterHorizontally))
                    SecondaryButton(translated("Ich habe einen Unterstützer-Schlüssel")) { entering = true }
                    SecondaryButton(translated("Vielleicht später"), action = close)
                }
            } else {
                KeyEntry(app, close)
            }
            Spacer(Modifier.height(16.dp))
        }
    }

    @Composable
    private fun KeyEntry(app: SwiftlyApplication, close: () -> Unit) {
        var key by remember { mutableStateOf("") }
        var refused by remember { mutableStateOf(false) }
        var checking by remember { mutableStateOf(false) }
        val context = LocalContext.current
        suspend fun check() {
            if (checking || key.isBlank()) return
            checking = true
            val ok = withContext(Dispatchers.Default) { activate(app, key) }
            checking = false
            if (ok) close() else refused = true
        }
        var go by remember { mutableStateOf(0) }
        LaunchedEffect(go) { if (go > 0) check() }
        SheetText(translated("Unterstützer-Schlüssel"), quiet = false)
        SheetText(translated("Den Schlüssel bekommst du, nachdem du uns auf der Website unterstützt hast: auf der Danke-Seite und per E-Mail."), top = 4.dp)
        Column(Modifier.fillMaxWidth().padding(horizontal = Theme.edgeSpacing).padding(top = 16.dp),
               verticalArrangement = Arrangement.spacedBy(10.dp)) {
            InputField(key, { key = it; refused = false }, Glyph.Keys, "SS2-…", completion = { go += 1 })
            if (refused) Text(translated("Dieser Schlüssel passt nicht. Prüf ihn auf Tippfehler und versuch es noch einmal."),
                              style = Theme.small, color = Theme.error)
            PrimaryButton(translated("Aktivieren"), released = key.isNotBlank() && !checking, lockedArea = Theme.raised) { go += 1 }
            Row(Modifier.align(Alignment.CenterHorizontally), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(translated("Schlüssel verloren? Schreib uns an"), style = Theme.small, color = Theme.fontVeryQuiet)
                Text(CONTACT, style = Theme.small, color = Theme.accent,
                     modifier = Modifier.pressText { app.addressOpen(context, "mailto:$CONTACT") })
            }
        }
    }

    /**
     * TV: most televisions have no browser, so the address is shown to type in elsewhere, and the key
     * is entered with the remote's keyboard.
     */
    @Composable
    fun TvAskBody(app: SwiftlyApplication, close: () -> Unit, first: FocusRequester) {
        var entering by remember { mutableStateOf(false) }
        Text(translated("Swiftly unterstützen"), style = TvTheme.titleLarge, color = Theme.font)
        if (!entering) {
            Text(translated("Mit deinem Unterstützer-Schlüssel bekommst du ein Herz in „Über“ und zusätzliche App-Icons."),
                 style = TvTheme.body, color = Theme.fontQuiet, modifier = Modifier.padding(top = 12.dp).widthIn(max = 620.dp))
            Text(translated("Auf der Website unterstützen"), style = TvTheme.body, color = Theme.font, modifier = Modifier.padding(top = 28.dp))
            Text("swiftlyplayer.com/supporter", style = TvTheme.titleLarge, color = Theme.font, modifier = Modifier.padding(top = 6.dp))
            Text(translated("Alles bleibt für alle kostenlos."), style = TvTheme.body, color = Theme.fontQuiet, modifier = Modifier.padding(top = 20.dp))
            Row(Modifier.padding(top = 28.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                TvButton(translated("Ich habe einen Unterstützer-Schlüssel"), modifier = Modifier.focusRequester(first)) { entering = true }
                TvButton(translated("Vielleicht später"), perform = close)
            }
        } else {
            var key by remember { mutableStateOf("") }
            var refused by remember { mutableStateOf(false) }
            val field = remember { FocusRequester() }
            LaunchedEffect(Unit) { delay(TvTheme.focusDeadline); runCatching { field.requestFocus() } }
            val submit = { if (key.isNotBlank()) { if (activate(app, key)) close() else refused = true } }
            Text(translated("Den Schlüssel bekommst du, nachdem du uns auf der Website unterstützt hast: auf der Danke-Seite und per E-Mail."),
                 style = TvTheme.body, color = Theme.fontQuiet, modifier = Modifier.padding(top = 12.dp).widthIn(max = 620.dp))
            TvField(key, { key = it; refused = false }, "SS2-…", Modifier.padding(top = 24.dp).widthIn(max = 620.dp).focusRequester(field),
                    imeAction = ImeAction.Done, keyboardAction = submit)
            if (refused) Text(translated("Dieser Schlüssel passt nicht. Prüf ihn auf Tippfehler und versuch es noch einmal."),
                              style = TvTheme.body, color = Theme.error, modifier = Modifier.padding(top = 10.dp))
            Row(Modifier.padding(top = 24.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                TvButton(translated("Aktivieren"), released = key.isNotBlank(), perform = submit)
                TvButton(translated("Vielleicht später"), perform = close)
            }
            Text("${translated("Schlüssel verloren? Schreib uns an")} $CONTACT", style = TvTheme.small, color = Theme.fontVeryQuiet,
                 modifier = Modifier.padding(top = 20.dp))
        }
    }
}

/**
 * Always there, nothing to buy in the app. At every start and return to the front it applies the
 * stored key's expiry and, when due, asks the shop for the renewed monthly key (a background
 * thread; the answer is only the licence number's state).
 */
private class DirectChannel(val keeper: SupporterKeyKeeper) : SupportChannel {
    private val yes = mutableStateOf(true)
    private val none = mutableStateOf<List<TipOffer>>(emptyList())
    override val available: State<Boolean> get() = yes
    override val offers: State<List<TipOffer>> get() = none
    override val plans: State<List<PlanOffer>> = androidx.compose.runtime.mutableStateOf(emptyList())
    private val main = android.os.Handler(android.os.Looper.getMainLooper())
    private val running = java.util.concurrent.atomic.AtomicBoolean(false)

    override fun connect() {
        runCatching { keeper.applyExpiry() }.onFailure { Support.log("Schluessel: $it") }
        if (!running.compareAndSet(false, true)) return
        Thread {
            try {
                val outcome = keeper.refreshIfDue()
                if (outcome != SupporterKeyKeeper.Refresh.NotDue) Support.log("Schluessel erneuert: $outcome")
            } catch (e: Exception) { Support.log("Schluessel erneuern: $e") } finally { running.set(false) }
        }.start()
    }
    override fun refresh() = connect()
    override fun buy(activity: Activity, productId: String) {}
}
