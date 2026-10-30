package de.paulherter.swiftly

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import de.paulherter.swiftly.shared.Motion
import de.paulherter.swiftly.shared.Strength
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.motionReduced
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.future.await
import org.json.JSONObject
import kotlin.math.roundToInt

/**
 * Long press on a tile opens the same menu everywhere (mirrors `TileMenu.swift` in Shared).
 *
 * Every movie, series and episode tile has the same list, with a preview in the tile's shape (the
 * same image, the cache answers immediately): play or resume, watched/unwatched, download, watch
 * together, and for "Continue watching" also "Go to overview" and "Remove from Continue watching".
 * The actions themselves are the existing ones.
 */
data class TileMenuRequest(
    val id: String, val name: String, val type: String,
    /** The same URL as the tile and the same shape (`landscape` 16:9, otherwise 2:3). */
    val image: String?, val landscape: Boolean,
    /** The quiet line under the preview title. */
    val row: String?,
    /** The tile is in "Continue watching". */
    val continueWatching: Boolean = false,
    /** Where the tile is (root coordinates); the preview lifts off from there. */
    val provenance: Rect = Rect.Zero,
    /**
     * In the player: only the watch state. No "Play", "Download" and "Watch together": the row
     * itself already starts the episode, a download sheet would open under the player, and the
     * running player would have to give way for "Together". Same rule as `TileMenu.inPlayer`
     * on Apple.
     */
    val inPlayer: Boolean = false,
    /** After a change to the watch state, so the page catches up. */
    val afterwards: (() -> Unit)? = null,
) {
    /** Movies, series and episodes. Collections, people and folders have nothing to play or mark. */
    val carries: Boolean get() = type in setOf("Movie", "Series", "Episode")
}

/** Who opens a tile menu; set by the main view. Without it, no menu. */
val LocalTileMenu = staticCompositionLocalOf<((TileMenuRequest) -> Unit)?> { null }

/**
 * Tap works like `tapOn`, long press opens the tile menu. The tile's frame is carried along so
 * the preview lifts off where the finger is.
 */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
fun Modifier.tilePress(wish: () -> TileMenuRequest?, perform: () -> Unit): Modifier = composed {
    val menu = LocalTileMenu.current
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val press = remember { Animatable(0f) }
    LaunchedEffect(pressed) { if (pressed) press.snapTo(1f) else press.animateTo(0f, Motion.release()) }
    val calm = motionReduced()
    val jerk = rememberJerk()
    val frameRect = remember { arrayOf(Rect.Zero) }
    onGloballyPositioned { frameRect[0] = it.boundsInRoot() }
        .graphicsLayer {
            val d = press.value
            if (!calm) { val m = 1f - (1f - Motion.PressMetric) * d; scaleX = m; scaleY = m }
            alpha = 1f - 0.15f * d
        }
        .combinedClickable(source, null, onClick = perform,
            onLongClick = if (menu == null) null else ({
                wish()?.takeIf { it.carries }?.let { jerk(Jerk.Medium); menu(it.copy(provenance = frameRect[0])) }
            }))
}

/**
 * The preview above the menu and the menu itself, above everything including the bar. The preview
 * lifts off the tile (spring like `Theme.spring`), the scrim darkens, a tap outside or Back closes.
 */
@Composable
fun TileMenuStatus(app: SwiftlyApplication, wish: TileMenuRequest?, open: (Destination) -> Unit, close: () -> Unit) {
    val remembered = remember { arrayOfNulls<TileMenuRequest>(1) }
    wish?.let { remembered[0] = it }
    val w = remembered[0] ?: return
    val on = remember { Animatable(0f) }
    val calm = motionReduced()
    LaunchedEffect(wish != null) {
        // `Theme.spring`: response 0.35, damping 0.9; (2 pi / 0.35)^2 is about 322.
        on.animateTo(if (wish != null) 1f else 0f,
            if (calm) Motion.fadeReduced() else spring(dampingRatio = 0.9f, stiffness = 322f))
        if (wish == null) remembered[0] = null
    }
    if (wish == null && on.value <= 0.001f) return
    BackHandler(enabled = wish != null) { close() }
    fun act(was: String) {
        close()
        tileMenuAct(app, w, was, open)
    }
    val entries = tileMenuEntries(app, w)

    BoxWithConstraints(Modifier.fillMaxSize()) {
        val d = LocalDensity.current.density
        val a = on.value
        // Also catches the press so nothing behind reacts.
        Box(Modifier.fillMaxSize().graphicsLayer { alpha = a.coerceIn(0f, 1f) }.background(Color.Black.copy(alpha = 0.55f))
                .onTap { close() })
        // The same image as the tile, same aspect ratio, just larger.
        val width = if (w.landscape) 320.dp else 220.dp
        val imageHeight = if (w.landscape) width * 9f / 16f else width * 3f / 2f
        val previewHeight = imageHeight + 62.dp
        val menuHeight = (44 * entries.size).dp
        val total = previewHeight + 12.dp + menuHeight
        val height = maxHeight
        val top = (w.provenance.top / d).dp.coerceIn(56.dp, (height - total - 24.dp).coerceAtLeast(56.dp))
        val left = (maxWidth - width) / 2
        // Out of the tile: the tile's position and size at the start, the target at the end.
        val start = w.provenance
        val targetL = left.value * d
        val targetO = top.value * d
        val massStart = if (start.width > 0) start.width / (width.value * d) else 0.9f
        Column(Modifier.offset { IntOffset(left.roundToPx(), top.roundToPx()) }.width(width)
                .graphicsLayer {
                    transformOrigin = TransformOrigin(0f, 0f)
                    if (!calm && start.width > 0) {
                        val m = massStart + (1f - massStart) * a
                        scaleX = m; scaleY = m
                        translationX = (start.left - targetL) * (1f - a)
                        translationY = (start.top - targetO) * (1f - a)
                    }
                    alpha = if (calm) a else (a * 3f).coerceIn(0f, 1f)
                }
                .clip(RoundedCornerShape(Theme.cornerArea)).background(Theme.reason)) {
            AsyncImage(model = w.image, contentDescription = null, contentScale = ContentScale.Crop,
                       modifier = Modifier.size(width, imageHeight))
            Column(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(w.name, style = Theme.listTitle, color = Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(w.row.orEmpty().ifEmpty { " " }, style = Theme.small.copy(fontFeatureSettings = "tnum"), color = Theme.fontQuiet,
                     maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        // The menu below grows out of the preview.
        val menuWidth = width.coerceAtLeast(250.dp)
        Column(Modifier.offset { IntOffset(((maxWidth - menuWidth) / 2).roundToPx(), (top + previewHeight + 12.dp).roundToPx()) }.width(menuWidth)
                .graphicsLayer {
                    transformOrigin = TransformOrigin(0.5f, 0f)
                    val m = if (calm) 1f else 0.9f + 0.1f * a
                    scaleX = m; scaleY = m; alpha = a.coerceIn(0f, 1f)
                }
                .clip(RoundedCornerShape(Theme.cornerArea)).background(Theme.raised)) {
            entries.forEachIndexed { i, (value, text, symbolText) ->
                if (i > 0) Box(Modifier.fillMaxWidth().height(1.dp).background(Theme.line))
                Row(Modifier.fillMaxWidth().heightIn(min = 44.dp).pressRow { act(value) }.padding(horizontal = 16.dp),
                    verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                    Text(text, style = Theme.body, color = Theme.font, modifier = Modifier.weight(1f), maxLines = 1)
                    Spacer(Modifier.width(12.dp))
                    Symbol(symbolText, 17.dp, color = Theme.font, strength = Strength.Medium)
                }
            }
        }
    }
}

/**
 * What the menu offers: the same on phone and TV, except "Download" (no downloads on TV).
 * Value, text, icon.
 */
internal fun tileMenuEntries(app: SwiftlyApplication, w: TileMenuRequest): List<Triple<String, String, Glyph>> = buildList {
    val isSeries = w.type == "Series"
    if (!w.inPlayer) add(Triple("abspielen", if (!isSeries && w.continueWatching) translated("Fortsetzen") else translated("Abspielen"), Glyph.Play))
    if (w.continueWatching) add(Triple("uebersicht", translated("Zur Übersicht"), Glyph.Info))
    // Both entries always, not just the matching one: an episode that was only skipped through counts
    // as started, and "unwatched" removes it from "Continue watching".
    add(Triple("gesehen", translated("Als gesehen markieren"), Glyph.CheckmarkCircle))
    add(Triple("ungesehen", translated("Als ungesehen markieren"), Glyph.Auge))
    if (!isSeries && !w.inPlayer && !app.isTv && app.settings.downloadButtonShow && app.downloads.entries(w.id) == null)
        add(Triple("laden", translated("Laden"), Glyph.LoadCircle))
    // "Abspielen auf …": the TVs in reach, for something that can start right away.
    if (!isSeries && !w.inPlayer) app.playOnChoices().forEach { add(Triple(it.first, it.second, Glyph.Tv)) }
    if (!isSeries && !w.inPlayer && app.gemeinsam.value.mayCreate) add(Triple("gemeinsam", translated("Gemeinsam schauen"), Glyph.Cluster))
    if (w.continueWatching) add(Triple("entfernen", translated("Aus Weiterschauen entfernen"), Glyph.MinusCircle))
}

/**
 * The actions are the existing ones; they outlive the menu (it is closed before the server
 * answers). After a change to the watch state the pages refresh (`watchStateChanged`).
 */
/**
 * A list with checkmarks and bars refreshes when playback ends or a tile menu changes the watch
 * state (`listenRefresh` / `nachholen` on Apple). Covered pages are not built and reload on
 * return anyway; only the top page has to do it here. The value at build time does not count.
 */
@androidx.compose.runtime.Composable
fun WatchStateChange(app: SwiftlyApplication, perform: suspend () -> Unit) {
    val counter = app.playbackEnded.intValue + app.watchStateChanged.intValue
    val beginning = androidx.compose.runtime.remember { counter }
    androidx.compose.runtime.LaunchedEffect(counter) { if (counter != beginning) perform() }
}

internal fun tileMenuAct(app: SwiftlyApplication, w: TileMenuRequest, was: String, open: (Destination) -> Unit) {
    val afterwards = w.afterwards
    if (app.playOnChosen(was, w.id)) return
    app.applicationRun.launch {
        when (was) {
            "abspielen" -> {
                // Fetch fresh: the position in the list entry is often stale. For a series, the episode you are
                // on.
                if (w.type == "Series") {
                    val state = runCatching { JSONObject(withContext(Dispatchers.IO) { app.kern.series(w.id).await() }).optJSONObject("stand") }.getOrNull()
                    if (state == null) { app.message.value = translated("Danach kommt nichts mehr."); return@launch }
                    app.play.value = PlayRequest(state.getString("id"), if (state.isNull("ab")) null else state.getDouble("ab"))
                } else {
                    val freshValue = continueWatchingRequest(app, w.id)
                    if (freshValue != null) app.play.value = freshValue else open(Destination(w.id, w.name, w.type))
                }
            }
            "uebersicht" -> open(Destination(w.id, w.name, w.type))
            "gesehen", "ungesehen" -> {
                val reason = withContext(Dispatchers.IO) { app.kern.watched(w.id, was == "gesehen").await() }
                if (reason.isNotEmpty()) app.message.value = errorString(app, Exception(reason)) else { app.watchStateChanged.intValue++; afterwards?.invoke() }
            }
            "entfernen" -> {
                val reason = withContext(Dispatchers.IO) { app.kern.fromContinueWatchingTake(w.id).await() }
                if (reason.isNotEmpty()) app.message.value = errorString(app, Exception(reason)) else { app.watchStateChanged.intValue++; afterwards?.invoke() }
            }
            "laden" -> app.downloadsCreate(listOf(w.id), w.name)
            "gemeinsam" -> sharedCreateOpen(app, w.id, w.name)
        }
    }
}

/**
 * On TV as a panel (menu key or long OK): the same entries, focus returns to the tile
 * (`FocusRemember`).
 */
fun tileMenuPanel(app: SwiftlyApplication, w: TileMenuRequest, open: (Destination) -> Unit) {
    if (!w.carries) return
    val entries = tileMenuEntries(app, w)
    app.sheet.value = SheetRequest(w.name, entries.map { Choice(it.first, it.second) }, null,
        entries.associate { it.first to it.third }) { was -> tileMenuAct(app, w, was, open) }
}
