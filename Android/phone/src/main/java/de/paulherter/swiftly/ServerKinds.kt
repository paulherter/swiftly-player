package de.paulherter.swiftly

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Strength
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.Wordmark
import de.paulherter.swiftly.shared.motionReduced
import de.paulherter.swiftly.shared.translated
import kotlin.math.cos
import kotlin.math.sin

// MARK: - How a server kind presents itself (`ServerKindLook.swift`)

/**
 * The kinds of server the app talks to. `raw` is the core's name for it (`Kern.kind()`, the `art`
 * of an account card). **No foreign logos, and nothing that looks like one:** the three are named
 * as text, the marks are our own, drawn from one stroke on one grid (see [ServerKindMark]).
 */
enum class ServerKind(val raw: String, val displayName: String, val tint: Color) {
    Jellyfin("jellyfin", "Jellyfin", Color(0f, 0.64f, 0.86f)),
    Plex("plex", "Plex", Color(0.90f, 0.63f, 0.05f)),
    Emby("emby", "Emby", Color(0.32f, 0.71f, 0.29f));

    /** The name where people choose or read it: Plex and Emby carry "(Beta)" until they have run long enough. */
    val shownName: String get() = if (this == Jellyfin) displayName else "$displayName (Beta)"

    /** One sentence under the name: what happens next, not what the kind is. */
    val pitch: String get() = when (this) {
        Jellyfin -> translated("Adresse rein und anmelden, oder per Quick Connect ganz ohne Passwort.")
        Plex -> translated("Einmal bei Plex anmelden, deine Server sucht die App dann selbst raus.")
        Emby -> translated("Adresse von deinem Server rein, dann Name und Passwort.")
    }

    companion object {
        /** Jellyfin first: it is what the app grew up with. */
        val pickerOrder = listOf(Jellyfin, Plex, Emby)
        fun from(raw: String?): ServerKind = entries.firstOrNull { it.raw == raw } ?: Jellyfin
    }
}

/**
 * **The mark of a server kind:** a bare stroke drawing on a 24 grid, no tile behind it. One stroke
 * weight for all three (1.8 of 24), scaled with the size. The colour is the caller's; `null` draws
 * the kind's own hue. Never the accent: the mark is an identity, not a state.
 */
@Composable
fun ServerKindMark(kind: ServerKind, size: Dp = 28.dp, color: Color? = null, modifier: Modifier = Modifier) {
    val tint = color ?: kind.tint
    Canvas(modifier.size(size)) {
        val u = this.size.minDimension / 24f
        fun p(x: Float, y: Float) = Offset(x * u, y * u)
        val stroke = Stroke(width = this.size.minDimension * 1.8f / 24f, cap = StrokeCap.Round, join = StrokeJoin.Round)
        when (kind) {
            ServerKind.Jellyfin -> {
                // A bell with three strands: the half circle, its rim a straight line, the middle strand a touch longer.
                val path = Path()
                path.arcTo(Rect(p(4f, 4f), p(20f, 20f)), 180f, 180f, true)
                path.close()
                for ((x, end) in listOf(8f to 19.5f, 12f to 21f, 16f to 19.5f)) {
                    path.moveTo(p(x, 12f).x, p(x, 12f).y)
                    path.quadraticTo(p(x + 2, (12 + end) / 2).x, p(x + 2, (12 + end) / 2).y, p(x, end).x, p(x, end).y)
                }
                drawPath(path, tint, style = stroke)
            }
            ServerKind.Plex -> {
                // An orbit: the ring opens where the satellite sits, so the two never touch.
                val ring = Path()
                ring.arcTo(Rect(p(12f - 8.5f, 12f - 8.5f), p(12f + 8.5f, 12f + 8.5f)), -18f, 306f, true)
                drawPath(ring, tint, style = stroke)
                drawCircle(tint, 3f * u, p(12f, 12f))
                val angle = -Math.PI.toFloat() / 4
                drawCircle(tint, 2.2f * u, p(12f + 8.5f * cos(angle), 12f + 8.5f * sin(angle)))
            }
            ServerKind.Emby -> {
                // Two frames, one behind the other: the front one whole, the one behind only as the edge that shows.
                val path = Path()
                path.addRoundRect(androidx.compose.ui.geometry.RoundRect(
                    p(3.5f, 8.5f).x, p(3.5f, 8.5f).y, p(15.5f, 20.5f).x, p(15.5f, 20.5f).y, CornerRadius(3f * u)))
                path.moveTo(p(8.5f, 3.5f).x, p(8.5f, 3.5f).y)
                path.lineTo(p(17.5f, 3.5f).x, p(17.5f, 3.5f).y)
                path.quadraticTo(p(20.5f, 3.5f).x, p(20.5f, 3.5f).y, p(20.5f, 6.5f).x, p(20.5f, 6.5f).y)
                path.lineTo(p(20.5f, 15.5f).x, p(20.5f, 15.5f).y)
                drawPath(path, tint, style = stroke)
            }
        }
    }
}

/** **Something is being prepared here:** the opacity breathes. Still under reduced motion. */
@Composable
fun Modifier.breathing(on: Boolean): Modifier {
    if (!on || motionReduced()) return this
    val transition = rememberInfiniteTransition(label = "atmen")
    val level by transition.animateFloat(1f, 0.45f, infiniteRepeatable(tween(900), RepeatMode.Reverse), label = "atmen")
    return this.alpha(level)
}

// MARK: - The picker (`ServerKindPicker.swift`)

enum class PickerPurpose {
    /** First start: the wordmark and the question, no way back. */
    FirstStart,
    /** From the profile: the subpage header with its arrow. */
    AddServer
}

/**
 * **Which server: the first page of the app, and the first page of "Server hinzufügen".** Three
 * cards, one per kind: the mark, the name as text, one sentence about what comes next. A tap goes
 * straight on; there is no "Weiter", because a choice of three that needs a fourth tap to confirm
 * is a form, and this is a question. No primary button: none of the kinds is the recommended one.
 */
@Composable
fun ServerKindPicker(purpose: PickerPurpose, pick: (ServerKind) -> Unit, back: () -> Unit = {}) {
    Column(Modifier.fillMaxSize().background(Theme.reason)) {
        if (purpose == PickerPurpose.AddServer) SubpageHeader(translated("Server hinzufügen"), back)
        Box(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()), contentAlignment = Alignment.TopCenter) {
            Column(Modifier.widthIn(max = Theme.formWidth).fillMaxWidth()
                       .then(if (purpose == PickerPurpose.FirstStart) Modifier.statusBarsPadding() else Modifier)
                       .padding(horizontal = Theme.edgePageWide).padding(bottom = 40.dp).navigationBarsPadding()) {
                when (purpose) {
                    PickerPurpose.FirstStart -> {
                        Box(Modifier.padding(top = 96.dp)) { Wordmark(height = 32.dp) }
                        Text(translated("Was läuft bei dir?"), style = Theme.titleLarge, color = Theme.font,
                             modifier = Modifier.padding(top = 40.dp))
                        Text(translated("Weitere Server kannst du später dazunehmen, auch gemischt."),
                             style = Theme.body.copy(lineHeight = 21.sp), color = Theme.fontQuiet,
                             modifier = Modifier.padding(top = 8.dp))
                    }
                    PickerPurpose.AddServer -> Text(
                        translated("Du bleibst bei allen angemeldet und wechselst auf der Profilseite zwischen ihnen."),
                        style = Theme.body.copy(lineHeight = 21.sp), color = Theme.fontQuiet, modifier = Modifier.padding(top = 8.dp))
                }
                Column(Modifier.padding(top = 28.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    ServerKind.pickerOrder.forEach { kind -> KindCard(kind) { pick(kind) } }
                }
            }
        }
    }
}

@Composable
private fun KindCard(kind: ServerKind, perform: () -> Unit) {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(Theme.cornerCard)).background(Theme.groupsArea).pressRow(perform)
            .padding(start = 12.dp, end = 16.dp, top = 16.dp, bottom = 16.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Box(Modifier.size(44.dp), contentAlignment = Alignment.Center) { ServerKindMark(kind, 34.dp) }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(kind.shownName, style = Theme.categoryLarge, color = Theme.font)
            Text(kind.pitch, style = Theme.body.copy(lineHeight = 19.sp), color = Theme.fontQuiet)
        }
        Symbol(Glyph.AngleRight, 13.dp, color = Theme.fontVeryQuiet, strength = Strength.Semibold)
    }
}

// MARK: - The flows that tie the picker to the three sign-ins (`ServerFlows.swift`)

/**
 * The first page of the app, before any server is known. State instead of a stack: the arrow of a
 * flow goes back to the picker. `jellyfinPage` draws the Jellyfin address page (it lives in
 * `ServerPage`), the other two kinds are finished pages of their own.
 */
@Composable
fun FirstStartFlow(app: SwiftlyApplication, connected: (String, String) -> Unit, finished: () -> Unit) {
    var chosen by rememberSaveable { mutableStateOf<String?>(null) }
    /** An address Emby recognised as Jellyfin: the Jellyfin page starts with it. */
    var carried by rememberSaveable { mutableStateOf<String?>(null) }
    BackHandler(enabled = chosen != null) { carried = null; chosen = null }
    when (chosen?.let { ServerKind.from(it) }) {
        null -> ServerKindPicker(PickerPurpose.FirstStart, { chosen = it.raw })
        ServerKind.Jellyfin -> ServerPage(app, back = { carried = null; chosen = null }, presetAddress = carried, connected = connected)
        ServerKind.Emby -> EmbySignInPage(app, address = null, finished = finished, back = { chosen = null },
            useJellyfin = { carried = it; chosen = ServerKind.Jellyfin.raw })
        ServerKind.Plex -> PlexSignInPage(app, finished = finished, back = { chosen = null })
    }
}

/**
 * "Server hinzufügen" and the plus on a card. Without `kind` the picker comes first; with it (a
 * second account on a known server) the page goes straight to that kind's sign-in.
 */
@Composable
fun AddServerFlow(app: SwiftlyApplication, kind: ServerKind?, preset: String?, back: () -> Unit) {
    var chosen by rememberSaveable { mutableStateOf<String?>(null) }
    var carried by rememberSaveable { mutableStateOf<String?>(null) }
    val current = kind ?: chosen?.let { ServerKind.from(it) }
    /** The arrow of a flow: back to the picker, or out when there was no picker. */
    fun step() { if (kind == null) { carried = null; chosen = null } else back() }
    // System back from a flow goes to the picker first; at the picker (or without one) the stack handles it.
    BackHandler(enabled = kind == null && chosen != null) { carried = null; chosen = null }
    when (current) {
        null -> ServerKindPicker(PickerPurpose.AddServer, { chosen = it.raw }, back)
        ServerKind.Jellyfin -> ServerOnboardingPage(app, preset ?: carried, kindPicked = true, back = { step() })
        ServerKind.Emby -> EmbySignInPage(app, address = preset, finished = {}, back = { step() },
            useJellyfin = { carried = it; chosen = ServerKind.Jellyfin.raw })
        ServerKind.Plex -> PlexSignInPage(app, finished = {}, back = { step() })
    }
}
