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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
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
    FocusArea(magnifier = TvTheme.focusMagnifierSmall, perform = {
        support.tvPanel.value = if (support.isSupporter) TvSupportPanel.Thanks else TvSupportPanel.Ask
    }) { focus ->
        Box(Modifier.size(32.dp).border(2.dp, if (focus) Theme.font else Color.Transparent, CircleShape),
            contentAlignment = Alignment.Center) {
            Symbol(if (support.isSupporter) Glyph.HeartFilled else Glyph.Heart, 14.dp,
                   color = if (support.isSupporter) Theme.accent else Theme.font, strength = Strength.Medium,
                   description = translated("Swiftly unterstützen"))
        }
    }
}

/** The settings row in the "Swiftly" section: opens the ask, or the thanks for supporters. */
fun tvSupportOpen(app: SwiftlyApplication) {
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
    // As in `TvPanel`: focus stays inside until it closes; for handing it back the exit opens.
    val sharing = remember(panel) { booleanArrayOf(false) }
    val close = {
        sharing[0] = true
        FocusRemember.backGive()
        support.tvPanel.value = null
    }
    BackHandler(onBack = close)
    val first = remember(panel) { FocusRequester() }
    LaunchedEffect(panel) { delay(2 * TvTheme.focusDeadline); runCatching { first.requestFocus() } }
    Box(Modifier.fillMaxSize().background(Theme.reason.copy(alpha = 0.96f))
            .focusProperties { exit = { if (sharing[0]) FocusRequester.Default else FocusRequester.Cancel } }.focusGroup(),
        contentAlignment = Alignment.Center) {
        CompositionLocalProvider(LocalWithinPanel provides true) {
        Column(Modifier.widthIn(max = 820.dp).padding(horizontal = TvTheme.edgePage),
               horizontalAlignment = Alignment.CenterHorizontally) {
            Box(Modifier.size(64.dp).background(Theme.accentQuiet, CircleShape), contentAlignment = Alignment.Center) {
                Symbol(if (panel == TvSupportPanel.Thanks) Glyph.HeartFilled else Glyph.Heart, 28.dp, color = Theme.accent)
            }
            when (panel) {
                TvSupportPanel.Thanks -> {
                    Text(translated("Danke. Du bist dabei."), style = TvTheme.titleLarge, color = Theme.font,
                         modifier = Modifier.padding(top = 18.dp))
                    Text(translated("Dein Kaffee hilft uns, Swiftly für alle kostenlos zu halten. Das ist neu für dich."),
                         style = TvTheme.body.copy(textAlign = TextAlign.Center), color = Theme.fontQuiet,
                         modifier = Modifier.padding(top = 8.dp).widthIn(max = 620.dp))
                    Row(Modifier.padding(top = 26.dp).background(Theme.area, androidx.compose.foundation.shape.RoundedCornerShape(TvTheme.cornerTile))
                            .padding(horizontal = 20.dp, vertical = 14.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        Symbol(Glyph.HeartFilled, 15.dp, color = Theme.accent)
                        Column {
                            Text(translated("Ein Herz in „Über“"), style = TvTheme.button, color = Theme.font)
                            Text(translated("Neben deiner Versionsnummer"), style = TvTheme.small, color = Theme.fontQuiet)
                        }
                    }
                    TvButton(translated("Fertig"), modifier = Modifier.padding(top = 28.dp).focusRequester(first), perform = close)
                }
                else -> {
                    Text(translated("Swiftly unterstützen"), style = TvTheme.titleLarge, color = Theme.font,
                         modifier = Modifier.padding(top = 18.dp))
                    Text(translated("Wir bauen Swiftly ohne Werbung und ohne Tracking. Wenn es deine Abende besser macht, hilft uns ein Kaffee, weiterzumachen."),
                         style = TvTheme.body.copy(textAlign = TextAlign.Center), color = Theme.fontQuiet,
                         modifier = Modifier.padding(top = 8.dp).widthIn(max = 620.dp))
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        FlavorSupport.TvAskBody(app, close, first)
                    }
                }
            }
        }
        }
    }
}
