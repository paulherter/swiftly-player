package de.paulherter.swiftly.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import de.paulherter.swiftly.BuildConfig
import de.paulherter.swiftly.SwiftlyApplication
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import de.paulherter.swiftly.support.LookTileView
import de.paulherter.swiftly.support.localized
import de.paulherter.swiftly.support.whatsNewGlyph
import kotlinx.coroutines.delay
import org.json.JSONObject

/**
 * **"What's new" on Android TV**, after the Apple TV page (`TVWhatsNew` in `TVLooks.swift`): once
 * after an update, from the version's JSON in the package. The phone shows the same entry as a
 * sheet (`whatsNewShow`); a television gets one plain full page: the version line, the title, three
 * to five entries, the gift when there is one, and the buttons, focus on the first. Every tvOS
 * point halved. The rules (once per version, only after an update, a draft never) are the
 * package's (`WhatsNew.decide`); this file is only the surface and the moment.
 *
 * Not here, as on Apple TV: the gift offer and the pick-up animation. "Hol ihn dir" picks the
 * gift up and opens the looks page.
 */

/**
 * **Asks once, calmly:** a few seconds after the home page is up (`LookGift.quietAfterHome`),
 * never during playback, never on top of another page. Stores the version when it shows or when
 * there is nothing to show, so a fresh install stays quiet.
 */
@Composable
private fun TvWhatsNewWatcher(app: SwiftlyApplication) {
    val context = LocalContext.current
    val idle = app.play.value == null && app.support.tvPanel.value == null && !app.looks.tvPage.value
    LaunchedEffect(idle) {
        if (!idle) return@LaunchedEffect
        delay(3_000)
        val looks = app.looks
        if (app.play.value != null || app.support.tvPanel.value != null || looks.tvPage.value ||
            looks.tvWhatsNew.value != null || looks.askedThisSession) return@LaunchedEffect
        val version = BuildConfig.VERSION_NAME
        val entry = looks.whatsNewEntry(context, version)
        when (looks.whatsNewDecision(version, entry != null)) {
            "show" -> {
                looks.whatsNewSeen(version)
                if (entry != null) {
                    val gift = entry.optJSONObject("module")?.optString("lookId").orEmpty()
                    if (gift.isNotEmpty() && looks.giftAvailable(gift)) looks.markOffered(gift)
                    looks.askedThisSession = true
                    looks.tvWhatsNew.value = entry
                }
            }
            "markSeen" -> looks.whatsNewSeen(version)
        }
    }
}

/** The watcher and the page, once at the root next to `TvLooksLayer`. */
@Composable
fun TvWhatsNewLayer(app: SwiftlyApplication) {
    TvWhatsNewWatcher(app)
    val entry = app.looks.tvWhatsNew.value ?: return
    TvWhatsNewPage(app, entry)
}

@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun TvWhatsNewPage(app: SwiftlyApplication, entry: JSONObject) {
    val looks = app.looks
    val context = LocalContext.current
    // As in the looks page: focus stays inside until it closes, then the exit opens to hand it back.
    val origin = remember { FocusRemember.lastOne }
    val sharing = remember { booleanArrayOf(false) }
    val close = {
        sharing[0] = true
        FocusRemember.lastOne = origin
        FocusRemember.backGive()
        looks.tvWhatsNew.value = null
    }
    BackHandler(onBack = close)
    val first = remember { FocusRequester() }
    LaunchedEffect(Unit) { delay(2 * TvTheme.focusDeadline); runCatching { first.requestFocus() } }

    val giftId = entry.optJSONObject("module")?.takeIf { it.optString("type") == "gift" }?.optString("lookId").orEmpty()
    val gift = if (giftId.isNotEmpty() && looks.giftAvailable(giftId) && giftId !in looks.owned.value) looks.info(giftId) else null
    val label = entry.optJSONObject("primary")?.optString("label").orEmpty()
    val action = entry.optJSONObject("primary")?.optString("action").orEmpty()
    val grab = gift != null && label == "grab"
    // Without a gift to pick up, "grab" reads like a plain "continue" (`primaryTitle`).
    val text = when {
        grab -> translated("Hol ihn dir")
        label == "try" -> translated("Ausprobieren")
        label == "tryLook" -> translated("Look ausprobieren")
        else -> translated("Verstanden")
    }
    val items = entry.optJSONArray("items")

    Box(Modifier.fillMaxSize().background(Theme.reason)
            .focusProperties { exit = { if (sharing[0]) FocusRequester.Default else FocusRequester.Cancel } }.focusGroup()) {
        TvGlow(app, strength = tvSoftGlow(app))
        CompositionLocalProvider(LocalWithinPanel provides true) {
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())
                       .padding(horizontal = TvTheme.edgePage, vertical = TvTheme.edgeTop)) {
                Text(translated("Neu in Version %@", entry.optString("version")), style = TvTheme.small, color = Theme.fontVeryQuiet)
                Text(entry.localized("title"), style = TvTheme.titleLarge, color = Theme.font,
                     modifier = Modifier.padding(top = 4.dp).semantics { heading() })

                Column(Modifier.padding(top = 20.dp), verticalArrangement = Arrangement.spacedBy(13.dp)) {
                    for (i in 0 until (items?.length() ?: 0)) {
                        val item = items!!.getJSONObject(i)
                        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                            Box(Modifier.size(26.dp), contentAlignment = Alignment.Center) {
                                Symbol(whatsNewGlyph(item.optString("symbol")), 17.dp, color = Theme.fontQuiet)
                            }
                            Column(Modifier.widthIn(max = 550.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Text(item.localized("title"), style = TvTheme.button, color = Theme.font)
                                val detail = item.localized("detail")
                                if (detail.isNotEmpty()) Text(detail, style = TvTheme.small, color = Theme.fontQuiet)
                            }
                        }
                    }
                }

                if (gift != null) {
                    Row(Modifier.padding(top = 18.dp).widthIn(max = 550.dp).fillMaxWidth()
                            .clip(RoundedCornerShape(TvTheme.cornerArea)).background(Theme.groupsArea).padding(12.dp),
                        horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        LookTileView(looks.tileIcon(gift), 44.dp)
                        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(gift.name, style = TvTheme.button, color = Theme.font)
                            Text(translated("Geschenk, bleibt für immer in deiner Sammlung"), style = TvTheme.small, color = Theme.fontQuiet)
                        }
                    }
                }

                Row(Modifier.padding(top = 24.dp).focusGroup(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    TvButton(text, modifier = Modifier.focusRequester(first)) {
                        close()
                        when {
                            grab -> { looks.claim(gift!!.id, context); tvLooksOpen(app) }
                            action == "open:looks" || label == "try" || label == "tryLook" -> tvLooksOpen(app)
                        }
                    }
                    if (gift != null) TvButton(translated("Nicht jetzt"), perform = close)
                }
            }
        }
    }
}
