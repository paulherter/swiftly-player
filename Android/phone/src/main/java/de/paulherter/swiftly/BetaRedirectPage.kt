package de.paulherter.swiftly

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import de.paulherter.swiftly.shared.PrimaryButton
import de.paulherter.swiftly.shared.Theme

/**
 * Full-screen notice of the "switch to Google Play" build for the current beta testers
 * (`-PbetaRedirect=true`). Nothing else is reachable: no network, no sign-in, no player.
 * Back closes the app (the activity's default).
 */
@Composable
fun BetaRedirectPage(openPlay: () -> Unit) {
    Box(Modifier.fillMaxSize().background(Theme.reason).safeDrawingPadding(), contentAlignment = Alignment.Center) {
        Column(
            Modifier.widthIn(max = 480.dp).verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center
        ) {
            Box(Modifier.size(88.dp).clip(RoundedCornerShape(20.dp))) {
                Image(painterResource(R.drawable.ic_launcher_background), null, Modifier.fillMaxSize())
                Image(painterResource(R.drawable.ic_launcher_foreground), null, Modifier.fillMaxSize())
            }
            Spacer(Modifier.height(28.dp))
            Text(stringResource(R.string.beta_redirect_title), style = Theme.titleLarge, color = Theme.font, textAlign = TextAlign.Center)
            Spacer(Modifier.height(16.dp))
            Text(stringResource(R.string.beta_redirect_text), style = Theme.body, color = Theme.fontQuiet, textAlign = TextAlign.Center)
            Spacer(Modifier.height(32.dp))
            PrimaryButton(stringResource(R.string.beta_redirect_button), action = openPlay)
        }
    }
}
