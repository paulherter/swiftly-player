package de.paulherter.swiftly.support

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.SwiftlyApplication
import de.paulherter.swiftly.pressRow
import de.paulherter.swiftly.pressText
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.PrimaryButton
import de.paulherter.swiftly.shared.SecondaryButton
import de.paulherter.swiftly.shared.Strength
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.motionReduced
import de.paulherter.swiftly.shared.translated
import android.os.Handler
import android.os.Looper

/**
 * The direct build's sheet: the same full sheet in the look's glow as `GrowSheetBody` (X at the top, the hero,
 * the heading), but with the website and the key where the Play build has plans and tips. The look of the
 * ask does not depend on how it is paid.
 */
@Composable
fun GrowDirectBody(app: SwiftlyApplication, close: () -> Unit, website: () -> Unit, keyEntry: @Composable (done: () -> Unit) -> Unit) {
    val uri = LocalUriHandler.current
    var entering by remember { mutableStateOf(false) }
    Box(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize()) {
            Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState())) {
                LooksHero(app, Modifier.padding(top = 36.dp - Handle)) {
                    app.looks.supportOpening = false
                    close()
                    Handler(Looper.getMainLooper()).postDelayed({ openLooksOnHome(app) }, 450)
                }
                Column(Modifier.padding(horizontal = 20.dp).padding(top = 22.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(buildAnnotatedString {
                        append(translated("Hilf Swiftly zu wachsen"))
                        append("  ")
                        withStyle(SpanStyle(fontSize = 17.sp, fontWeight = FontWeight.Normal, letterSpacing = 0.sp)) { append("🌱") }
                    }, style = giftFont(28f, FontWeight.Bold).copy(letterSpacing = (-0.56).sp), color = Theme.font,
                         modifier = Modifier.semantics { heading() })
                    Text(translated("Dein Beitrag hält Swiftly am Laufen."), style = giftFont(17f), color = Theme.font.copy(alpha = 0.9f))
                    Text(translated("Open Source, keine Werbung, alles zum Schauen bleibt kostenlos."), style = giftFont(13f),
                         color = Theme.fontVeryQuiet)
                    if (!entering) Text(translated("Mit deinem Unterstützer-Schlüssel bekommst du ein Herz in „Über“ und zusätzliche App-Icons."),
                                        style = giftFont(13f), color = Theme.fontVeryQuiet, modifier = Modifier.padding(top = 6.dp))
                }
                if (entering) keyEntry { close() }
                Spacer(Modifier.height(12.dp))
            }
            Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(top = 12.dp, bottom = 10.dp),
                   verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (!entering) {
                    PrimaryButton(translated("Auf der Website unterstützen")) { close(); website() }
                    SecondaryButton(translated("Ich habe einen Unterstützer-Schlüssel")) { entering = true }
                } else {
                    SecondaryButton(translated("Zurück")) { entering = false }
                }
                Row(Modifier.fillMaxWidth().padding(top = 2.dp), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                    LegalLink(translated("Datenschutz")) { uri.openUri(PRIVACY_URL) }
                }
            }
        }
        LookCloseButton(Modifier.align(Alignment.TopEnd).offset(y = 4.dp - Handle).padding(end = 8.dp), dark = true, action = close)
    }
}

