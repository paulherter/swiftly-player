package de.paulherter.swiftly.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.border
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.runtime.State
import de.paulherter.swiftly.PickerPurpose
import de.paulherter.swiftly.ServerKind
import de.paulherter.swiftly.SwiftlyApplication
import de.paulherter.swiftly.shared.Theme

/**
 * Mirrors `TVFirstStartView` and `TVAddServerFlow` (`TVServerFlows.swift`): **the picker, then the
 * page of the chosen kind.** The same state machine as the phone's `FirstStartFlow` / `AddServerFlow`
 * (`ServerKinds.kt`); the Back key on a kind's page is one step back to the picker.
 *
 * `connected`: the Jellyfin address page answered (name and version), the sign-in page follows.
 * `finished`: Emby or Plex signed in and connected, the session is stored already.
 */
@Composable
fun TvFirstStartFlow(app: SwiftlyApplication, connected: (String, String) -> Unit, finished: () -> Unit) {
    var chosen by rememberSaveable { mutableStateOf<String?>(null) }
    /** An address Emby recognised as Jellyfin: the Jellyfin page starts with it. */
    var carried by rememberSaveable { mutableStateOf<String?>(null) }
    when (chosen?.let { ServerKind.from(it) }) {
        null -> TvServerKindPicker(PickerPurpose.FirstStart, { chosen = it.raw })
        ServerKind.Jellyfin -> TvServerPage(app, presetAddress = carried, back = { carried = null; chosen = null }, connected = connected)
        ServerKind.Emby -> TvEmbySignInPage(app, address = null, finished = finished, back = { chosen = null },
            useJellyfin = { carried = it; chosen = ServerKind.Jellyfin.raw })
        ServerKind.Plex -> TvPlexSignInPage(app, finished = finished, back = { chosen = null })
    }
}

/**
 * "Server hinzufügen" from the profile and the plus on an account of a known server. Without `kind` the
 * picker comes first; with it (a second account on a known server) the page goes straight to that
 * kind's sign-in. `close` leaves the whole flow.
 */
@Composable
fun TvAddServerFlow(app: SwiftlyApplication, kind: ServerKind?, preset: String?, close: () -> Unit) {
    var chosen by rememberSaveable { mutableStateOf<String?>(null) }
    var carried by rememberSaveable { mutableStateOf<String?>(null) }
    val current = kind ?: chosen?.let { ServerKind.from(it) }
    /** The arrow of a flow: back to the picker, or out when there was no picker. */
    fun step() { if (kind == null) { carried = null; chosen = null } else close() }
    when (current) {
        null -> TvServerKindPicker(PickerPurpose.AddServer, { chosen = it.raw }, close)
        ServerKind.Jellyfin -> TvServerOnboarding(app, preset ?: carried, kindPicked = true, back = { step() })
        ServerKind.Emby -> TvEmbySignInPage(app, address = preset, finished = close, back = { step() },
            useJellyfin = { carried = it; chosen = ServerKind.Jellyfin.raw })
        ServerKind.Plex -> TvPlexSignInPage(app, finished = close, back = { step() })
    }
}

/** Mirrors `GroupsTitle` on tvOS: the quiet heading above a choice ("Wer schaut?", "Deine Server"). */
@Composable
internal fun TvGroupHeading(text: String, modifier: Modifier = Modifier) {
    Text(text, style = TvTheme.rail, color = Theme.fontQuiet, maxLines = 1,
         modifier = modifier.padding(bottom = TvSpec.groupsTitleBottom).semantics { heading() })
}

/**
 * Mirrors `ProfileCharacter` under `ProfilePickerStyle`: **a profile picture to choose, round.** At
 * rest the picture is dimmed; focus is the white ring with a gap and the magnification of the cold-start
 * picker (`TvProfilePicker`), never the accent. `selected` (Emby: the account whose name is in the
 * field) keeps a thin ring at rest. `overlay` sits on the upper right edge (the PIN mark).
 */
@Composable
internal fun TvPickCircle(name: String, image: String?, size: Dp, modifier: Modifier = Modifier, selected: Boolean = false,
                          description: String = name, overlay: @Composable () -> Unit = {}, perform: () -> Unit) {
    FocusArea(modifier, magnifier = TvTheme.focusMagnifier, perform = perform) { focus ->
        val dim by animateFloatAsState(if (focus) 0f else TvSpec.pickerDimIdleOpacity, tvTween(TvSpec.focusMs), label = "dim")
        val ring by animateFloatAsState(if (focus) 1f else 0f, tvTween(TvSpec.focusMs), label = "ring")
        Box(Modifier.size(size).semantics { contentDescription = description }
                .drawWithContent {
                    drawContent()
                    if (ring > 0f) drawCircle(Color.White, alpha = ring,
                        radius = this.size.minDimension / 2 + (TvSpec.pickerRingGap + TvSpec.pickerRingWidth / 2).toPx(),
                        style = Stroke(TvSpec.pickerRingWidth.toPx()))
                }) {
            Box(Modifier.size(size).clip(CircleShape)
                    .then(if (selected) Modifier.border(TvSpec.hairline * 2, Theme.font, CircleShape) else Modifier)) {
                AccountCircle(name, image, size)
                Box(Modifier.size(size).background(Theme.reason.copy(alpha = dim)))
            }
            Box(Modifier.align(androidx.compose.ui.Alignment.TopEnd)) { overlay() }
        }
    }
}
