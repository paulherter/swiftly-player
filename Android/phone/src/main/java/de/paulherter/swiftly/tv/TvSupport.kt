package de.paulherter.swiftly.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import de.paulherter.swiftly.SwiftlyApplication
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Strength
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import de.paulherter.swiftly.support.FlavorSupport
import de.paulherter.swiftly.support.SupportPromptWatcher
import de.paulherter.swiftly.support.TvSupportPanel
import kotlinx.coroutines.delay

/**
 * **"Support Swiftly" on Android TV.** The heart sits in the top bar left of the profile; the ask
 * and the thanks are full panels over the app (Android TV may show the sheet, only Apple TV may not).
 * No app icons on TV. Back closes; focus goes back where it was (`FocusRemember`).
 */
@Composable
fun TvSupportHeart(app: SwiftlyApplication) {
    val support = app.support
    if (!support.available && !support.isSupporter) return
    FocusArea(magnifier = TvTheme.focusMagnifierSmall, perform = { tvSupportOpen(app) }) { focus ->
        Box(Modifier.size(32.dp).border(2.dp, if (focus) Theme.font else Color.Transparent, CircleShape),
            contentAlignment = Alignment.Center) {
            // Always filled and white, as on Apple TV (`heart.fill`); being a supporter shows in the settings row.
            Symbol(Glyph.HeartFilled, 15.dp, color = Theme.font, strength = Strength.Medium,
                   description = translated("Swiftly unterstützen"))
        }
    }
}

/**
 * **The support row in "Swiftly"** (`TVSupportEntryRow`): the filled heart, "Swiftly unterstützen"
 * with its quiet line below, "Danke" on the right for supporters. Opens the ask, or the thanks.
 */
@Composable
fun TvSupportEntryRow(app: SwiftlyApplication, modifier: Modifier = Modifier) {
    val supporter = app.support.isSupporter
    FocusArea(modifier.fillMaxWidth().semantics(mergeDescendants = true) { role = Role.Button },
              magnifier = 1f, perform = { tvSupportOpen(app) }) { focus ->
        Row(Modifier.fillMaxWidth().heightIn(min = TvTheme.rowsHeight).clip(RoundedCornerShape(TvTheme.corner))
                .background(if (focus) TvTheme.focusArea else Color.Transparent).padding(horizontal = 13.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(Modifier.width(20.dp), contentAlignment = Alignment.Center) {
                Symbol(Glyph.HeartFilled, 15.dp, color = if (supporter) Theme.accent else Theme.font, strength = Strength.Semibold)
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Text(translated("Swiftly unterstützen"), style = TvTheme.body, color = Theme.font, maxLines = 1)
                Text(translated("Mit einem Kaffee Danke sagen. Alles bleibt für alle kostenlos."), style = TvTheme.small,
                     color = Theme.fontQuiet, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            if (supporter) Text(translated("Danke"), style = TvTheme.body, color = Theme.fontQuiet, maxLines = 1)
        }
    }
}

/** The settings row in the "Swiftly" section: opens the ask, or the thanks for supporters. */
fun tvSupportOpen(app: SwiftlyApplication) {
    app.looks.tvFromLooks = false
    app.support.tvPanel.value = if (app.support.isSupporter) TvSupportPanel.Thanks else TvSupportPanel.Ask
}

/** Above everything in `TvMain`, below the player. Also shows the ask when the package says it is due. */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun TvSupportLayer(app: SwiftlyApplication) {
    val support = app.support
    SupportPromptWatcher(app, ask = { support.tvPanel.value = TvSupportPanel.Ask },
                         thanks = { support.tvPanel.value = TvSupportPanel.Thanks })
    val panel = support.tvPanel.value ?: return
    val looks = app.looks
    val context = androidx.compose.ui.platform.LocalContext.current
    // As in `TvPanel`: focus stays inside until it closes; for handing it back the exit opens.
    val sharing = remember(panel) { booleanArrayOf(false) }
    val close = {
        sharing[0] = true
        // Closing the buy page that the looks page led to, without a purchase, ends the preview (`LookTryOn`).
        if (looks.tvFromLooks) {
            looks.tvFromLooks = false
            if (panel == TvSupportPanel.Ask) looks.supportClosed(context)
            else looks.tvPage.value = false
        }
        FocusRemember.backGive()
        support.tvPanel.value = null
    }
    BackHandler(onBack = close)
    val first = remember(panel) { FocusRequester() }
    LaunchedEffect(panel) { delay(2 * TvTheme.focusDeadline); runCatching { first.requestFocus() } }
    // A page of its own, as on Apple TV: neutral black with the look's glow, soft (`glow: .soft`).
    // The buy page reads from the top; the thanks stands in the middle.
    val thanks = panel == TvSupportPanel.Thanks
    Box(Modifier.fillMaxSize().background(Theme.reason)
            .focusProperties { exit = { if (sharing[0]) FocusRequester.Default else FocusRequester.Cancel } }.focusGroup(),
        contentAlignment = if (thanks) Alignment.Center else Alignment.TopCenter) {
        TvGlow(app, Modifier.align(Alignment.TopStart), strength = tvSoftGlow(app))
        CompositionLocalProvider(LocalWithinPanel provides true) {
        Column(Modifier.widthIn(max = 820.dp).verticalScroll(rememberScrollState())
                   .padding(horizontal = TvTheme.edgePage, vertical = TvTheme.edgeTop),
               horizontalAlignment = Alignment.CenterHorizontally) {
            when (panel) {
                TvSupportPanel.Thanks -> TvThanksBody(app, first, close = {
                    // The purchase went through: the looks page below has nothing left to ask.
                    looks.tvFromLooks = false
                    looks.tvPage.value = false
                    close()
                }, home = {
                    looks.tvFromLooks = false
                    looks.tvPage.value = false
                    looks.goHome()
                    close()
                })
                else -> FlavorSupport.TvAskBody(app, close, first)
            }
        }
        }
    }
}
