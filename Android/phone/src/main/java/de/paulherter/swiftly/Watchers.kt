package de.paulherter.swiftly

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import de.paulherter.swiftly.shared.Theme
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.withContext
import org.json.JSONArray

/**
 * **Who has watched a title** (Jelly Twiggy plugin; mirrors `Watchers.swift` in the package).
 * `ring` is 0...1 and decided in the core (`Watcher.ring`); `last` is in milliseconds.
 */
data class Watcher(val id: String, val name: String, val image: String?, val plays: Int, val last: Long?, val ring: Float,
                   /** "2 × · gestern", already translated in the core (`Watcher.caption`); may be empty. */
                   val caption: String = "")

/**
 * Asks the core once per title page. Nothing is requested when the setting is off or the server
 * has answered "no plugin" since the app started; the next start asks again.
 * A failed request gives an empty list and is asked again next time. An empty list hides the section.
 */
suspend fun watchersLoad(app: SwiftlyApplication, id: String): List<Watcher> {
    val s = app.settings
    if (!s.watchersShow || s.watchersPlugin == "0") return emptyList()
    return try {
        val raw = withContext(Dispatchers.IO) { app.kern.watchers(id).await() }
        when (raw) {
            "" -> emptyList()
            "absent" -> { s.watchersPluginSet(false); emptyList() }
            else -> {
                s.watchersPluginSet(true)
                val j = JSONArray(raw)
                (0 until j.length()).map { i ->
                    val o = j.getJSONObject(i)
                    Watcher(o.getString("id"), o.optString("name"), o.fieldText("image"), o.optInt("plays"),
                            if (o.has("last")) o.getLong("last") else null, o.optDouble("ring", 0.0).toFloat().coerceIn(0f, 1f),
                            o.optString("caption"))
                }
            }
        }
    } catch (e: CancellationException) { throw e } catch (_: Exception) { emptyList() }
}

/** Name and caption as one line (`Watcher.spoken` in the package): what VoiceOver/TalkBack and the tap read. */
fun Watcher.spoken(): String {
    val shown = name.ifBlank { "?" }
    return if (caption.isEmpty()) shown else "$shown, $caption"
}

/**
 * **Round avatar with the progress ring** (3 dp, track white 18 %, fill in accent, from the top):
 * a full ring is watched. Without an image (or while it loads) the initial sits on the raised surface.
 */
@Composable
fun WatcherAvatar(w: Watcher, size: Dp, modifier: Modifier = Modifier) {
    val ring = 3.dp
    val accent = Theme.accent
    Box(modifier.size(size), contentAlignment = Alignment.Center) {
        Box(Modifier.size(size - ring * 2 - 3.dp).clip(CircleShape).background(Theme.raised), contentAlignment = Alignment.Center) {
            Text(w.name.trim().take(1).uppercase(), style = Theme.listTitle, color = Theme.fontQuiet)
            if (w.image != null) AsyncImage(model = w.image, contentDescription = null,
                contentScale = androidx.compose.ui.layout.ContentScale.Crop, modifier = Modifier.fillMaxSize())
        }
        Canvas(Modifier.fillMaxSize()) {
            val stroke = Stroke(ring.toPx(), cap = StrokeCap.Round)
            val inset = ring.toPx() / 2
            val box = Size(this.size.width - inset * 2, this.size.height - inset * 2)
            drawArc(Color.White.copy(alpha = 0.18f), 0f, 360f, false, Offset(inset, inset), box, style = stroke)
            if (w.ring > 0f) drawArc(accent, -90f, 360f * w.ring, false, Offset(inset, inset), box, style = stroke)
        }
    }
}

/**
 * **Who has watched a title** on the phone: one row of avatars without a heading, as on iPhone and
 * the TV. A tap names the avatar (who, how often, when last) to the right of the row, or under it when
 * the row leaves no room. Absent for an empty list, so a server without the plugin shows nothing.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun WatchedBy(watchers: List<Watcher>) {
    if (watchers.isEmpty()) return
    var chosen by remember(watchers) { mutableStateOf<String?>(null) }
    // Avatars first, then the line: beside them while it fits, otherwise wrapped below.
    FlowRow(Modifier.fillMaxWidth().padding(top = Theme.railsSpacing).padding(horizontal = Theme.edgeSpacing),
            horizontalArrangement = Arrangement.spacedBy(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            for (w in watchers) {
                WatcherAvatar(w, 56.dp, Modifier.tapOn { chosen = if (chosen == w.id) null else w.id }
                    .semantics { contentDescription = w.spoken() })
            }
        }
        watchers.firstOrNull { it.id == chosen }?.let { w ->
            Column(Modifier.align(Alignment.CenterVertically).clearAndSetSemantics {}) {
                Text(w.name.ifBlank { "?" }, style = Theme.small, color = Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (w.caption.isNotEmpty())
                    Text(w.caption, style = Theme.small, color = Theme.fontQuiet, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}
