package de.paulherter.swiftly

import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Strength
import android.widget.Toast
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.widthIn
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray

/** An offer from `Kern.takeoverOfferings`; the place comes from that query, not a later one. */
data class Offering(val session: String, val itemID: String, val device: String?, val art: String,
                   val titleLine: String, val spot: Double, val pointText: String,
                   /** For the handover card (`Handoff.kt`): its image and the lines below. */
                   val image: String? = null, val name: String = "", val series: String? = null,
                   val seasonNr: Int? = null, val episodeNr: Int? = null)

/** Mirrors `TakeoverModel.inTimesAsk`. Nothing is asked while something plays here. */
suspend fun SwiftlyApplication.offeringsFetch() {
    if (play.value != null) return
    // Ask about groups on the same tick (`SharedModel.start`); the state arrives via `sharedListen`.
    runCatching { withContext(Dispatchers.IO) { kern.syncPlayOfferingsAsk().await() } }
    offerings.value = runCatching {
        JSONArray(withContext(Dispatchers.IO) { kern.takeoverOfferings().await() }).let { a ->
            (0 until a.length()).map { a.getJSONObject(it) }.map {
                Offering(it.getString("id"), it.getString("itemID"), it.fieldText("geraet"), it.getString("art"),
                        it.getString("titelzeile"), it.optDouble("stelle", 0.0), it.optString("stelleText"),
                        it.fieldText("bild"), it.optString("name"), it.fieldText("serie"),
                        if (it.isNull("staffelNr")) null else it.optInt("staffelNr"),
                        if (it.isNull("folgeNr")) null else it.optInt("folgeNr"))
            }
        }
    }.getOrDefault(emptyList())
}

/**
 * Mirrors `OfferingBadge` in `Sources/iOS/SharedViews.swift`: one badge for
 * everything playing elsewhere, in place of "Hier weiterschauen" in `HeaderTargets`, on every root
 * page. If something plays elsewhere and a group exists, a counter is shown and a tap opens the
 * picker with both, instead of two icons that push the watchlist and profile aside.
 *
 * Handover only: as before (one device takes over at once, several: pick first). Group only:
 * the "Beitreten" sheet. The header icons are cool-colored, not accent, but the badge itself
 * uses the accent as on iOS.
 */
@Composable
fun TakeoverCharacter(app: SwiftlyApplication) {
    val offerings = app.offerings.value
    val groups = app.gemeinsam.value.openGroups
    val count = offerings.size + groups.size
    val context = LocalContext.current
    val run = rememberCoroutineScope()
    var takesOver by remember { mutableStateOf(false) }
    val center = remember { arrayOf(androidx.compose.ui.geometry.Offset.Zero) }
    val density = androidx.compose.ui.platform.LocalDensity.current.density
    val calm = de.paulherter.swiftly.shared.motionReduced()
    fun adopt(a: Offering) {
        if (takesOver) return
        takesOver = true
        run.launch { hereContinueWatching(app, context, a, center[0], density, calm); takesOver = false }
    }
    AnimatedVisibility(count > 0,
        enter = fadeIn(tween(220, easing = EaseInOut)) + scaleIn(tween(220, easing = EaseInOut), initialScale = 0.85f),
        exit = fadeOut(tween(220, easing = EaseInOut)) + scaleOut(tween(220, easing = EaseInOut), targetScale = 0.85f)) {
        val firstOne = offerings.firstOrNull()
        val label = when {
            count > 1 -> translated("Läuft gerade")
            offerings.isEmpty() -> translated("Gemeinsam schauen")
            else -> translated("Hier weiterschauen")
        }
        Box(Modifier.size(44.dp).onGloballyPositioned { center[0] = it.boundsInRoot().center }.tapOn {
                when {
                    // The card grows out of the badge: instead of a sheet from below it comes from the icon that
                    // was tapped and shrinks back into it.
                    groups.isEmpty() -> if (offerings.size == 1) firstOne?.let { adopt(it) }
                        else app.takeoverSelection.value = TakeoverSelection(offerings, center[0]) { adopt(it) }
                    offerings.isEmpty() && groups.size == 1 -> sharedJoinOpen(app, groups.first())
                    else -> sharedSelectionOpen(app, ::adopt)
                }
            }.semantics { contentDescription = label; stateDescription = (offerings.map { it.titleLine } + groups.map { it.name }).joinToString(", ") },
            contentAlignment = Alignment.Center) {
            Symbol(firstOne?.let { symbolText(it.art) } ?: Glyph.ClusterFilled, 20.dp, color = Theme.accent)
            if (count > 1) Box(Modifier.align(Alignment.TopEnd).offset(x = (-2).dp, y = 4.dp).defaultMinSize(16.dp, 16.dp)
                    .background(Theme.accent, CircleShape).padding(horizontal = 4.dp), contentAlignment = Alignment.Center) {
                Text("$count", style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.SemiBold, fontFeatureSettings = "tnum"),
                     color = Theme.onAccent)
            }
        }
    }
}

private fun symbolText(art: String): Glyph = takeoverIcon(art)

/**
 * Finish over there, continue here at the same position. Mirrors `hereContinueWatching` in
 * `Sources/Shared/MainView.swift` / `Sources/tvOS/MainView.swift`. The card grows out of the
 * badge at once (`Uebergabe.empfangen`) and runs alongside the network request; the player opens
 * under it without its own fade and becomes visible once the card has zoomed onto its first
 * frame. Phone and TV. `provenance`: center of the badge in root pixels.
 */
suspend fun hereContinueWatching(app: SwiftlyApplication, context: android.content.Context, a: Offering,
                              provenance: androidx.compose.ui.geometry.Offset, density: Float, calm: Boolean) {
    Handoff.receive(app, a, provenance, density, calm)
    val answer = runCatching {
        org.json.JSONObject(withContext(Dispatchers.IO) { app.kern.handedOver(a.session, a.itemID, a.spot, Handoff.ownName(app)).await() })
    }.getOrNull()
    val reason = answer?.optString("grund") ?: "nichtVerbunden"
    if (reason.isEmpty()) {
        app.offerings.value = emptyList()
        Handoff.prePlayer()
        Handoff.playerComes(app, a.itemID)
        app.play.value = PlayRequest(a.itemID, answer?.optDouble("ab", a.spot) ?: a.spot)
    } else {
        Handoff.cancel(app, "Stopp abgelehnt")
        Toast.makeText(context, errorString(reason), Toast.LENGTH_LONG).show()
    }
}

/** "Where to continue?": the sessions, and where the badge sits (root coordinates). */
class TakeoverSelection(val offerings: List<Offering>, val provenance: androidx.compose.ui.geometry.Offset, val select: (Offering) -> Unit)

/**
 * Mirrors `Uebernahmeauswahl.scrim` + `TakeoverCard` with `.transition(.outPoint(...))`
 * in `Sources/Shared/Components.swift` / `Sources/iOS/Transitions.swift`. The scrim fades, the
 * card grows out of the badge (scale from 12 %, alpha faster than scale) and shrinks back on
 * close. Spring `Theme.spring` (0.35/0.9); with reduced motion, crossfade only.
 */
@Composable
fun TakeoverStatus(app: SwiftlyApplication) {
    val opened = app.takeoverSelection.value
    val remembered = remember { arrayOfNulls<TakeoverSelection>(1) }
    opened?.let { remembered[0] = it }
    val w = remembered[0] ?: return
    val calm = de.paulherter.swiftly.shared.motionReduced()
    val on = remember { androidx.compose.animation.core.Animatable(0f) }
    androidx.compose.runtime.LaunchedEffect(opened != null) {
        on.animateTo(if (opened != null) 1f else 0f,
            if (calm) de.paulherter.swiftly.shared.Motion.fadeReduced()
            else androidx.compose.animation.core.spring(dampingRatio = 0.9f, stiffness = 322f))
        if (opened == null) remembered[0] = null
    }
    if (opened == null && on.value <= 0.001f) return
    fun toward() { app.takeoverSelection.value = null }
    androidx.activity.compose.BackHandler(enabled = opened != null) { toward() }
    Box(Modifier.fillMaxSize()) {
        // `reason` at 62 %, not black: the scrim is the page showing through. Swallows taps.
        Box(Modifier.fillMaxSize().graphicsLayer { alpha = on.value.coerceIn(0f, 1f) }.background(Theme.reason.copy(alpha = 0.62f)).onTap { toward() })
        val frameRect = remember { arrayOf(androidx.compose.ui.geometry.Rect.Zero) }
        androidx.compose.foundation.layout.Column(Modifier.align(Alignment.Center).padding(horizontal = 24.dp)
                .widthIn(max = 420.dp)
                .onGloballyPositioned { frameRect[0] = it.boundsInRoot() }
                .graphicsLayer {
                    val a = on.value
                    if (!calm && frameRect[0].width > 0) {
                        val r = frameRect[0]
                        transformOrigin = androidx.compose.ui.graphics.TransformOrigin(
                            ((w.provenance.x - r.left) / r.width).coerceIn(-2f, 3f), ((w.provenance.y - r.top) / r.height).coerceIn(-2f, 3f))
                        val m = 0.12f + 0.88f * a
                        scaleX = m; scaleY = m
                    }
                    // Alpha runs faster than scale: a very small card is nearly invisible.
                    alpha = (a * 1.6f).coerceIn(0f, 1f)
                }
                .clip(androidx.compose.foundation.shape.RoundedCornerShape(Theme.cornerArea)).background(Theme.area)) {
            androidx.compose.foundation.layout.Column(Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, top = 20.dp, bottom = 16.dp),
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp)) {
                Text(translated("Wo weiterschauen?"), style = Theme.listTitle, color = Theme.font)
                Text(translated("Auf dem anderen Gerät hört die Wiedergabe auf. Hier läuft sie an derselben Stelle weiter."),
                     style = Theme.small.copy(textAlign = androidx.compose.ui.text.style.TextAlign.Center), color = Theme.fontVeryQuiet)
            }
            w.offerings.forEach { a ->
                SheetLine()
                androidx.compose.foundation.layout.Row(Modifier.fillMaxWidth().defaultMinSize(minHeight = 58.dp)
                        .pressRow { toward(); w.select(a) }.padding(horizontal = 20.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(14.dp)) {
                    Box(Modifier.size(26.dp), contentAlignment = Alignment.Center) { Symbol(symbolText(a.art), 17.dp, color = Theme.accent, strength = Strength.Medium) }
                    androidx.compose.foundation.layout.Column(Modifier.weight(1f), verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(1.dp)) {
                        Text(a.device ?: translated("Gerät"), style = Theme.listTitle, color = Theme.font, maxLines = 1)
                        Text(a.titleLine, style = Theme.small, color = Theme.fontQuiet, maxLines = 1,
                             overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
                    }
                    Text(a.pointText, style = Theme.small.copy(fontFeatureSettings = "tnum"), color = Theme.fontVeryQuiet)
                }
            }
            Box(Modifier.fillMaxWidth().height(1.dp).background(Theme.margin))
            Box(Modifier.fillMaxWidth().defaultMinSize(minHeight = 58.dp).pressRow { toward() }, contentAlignment = Alignment.Center) {
                Text(translated("Abbrechen"), style = Theme.buttonText, color = Theme.font)
            }
        }
    }
}
