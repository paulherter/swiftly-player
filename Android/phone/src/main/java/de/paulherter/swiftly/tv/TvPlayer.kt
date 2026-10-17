package de.paulherter.swiftly.tv

import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Strength
import androidx.compose.foundation.gestures.BringIntoViewSpec
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.AnimationSpec
import androidx.compose.runtime.withFrameNanos
import android.os.SystemClock
import de.paulherter.swiftly.AppLog
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.EaseOut
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandHorizontally
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkHorizontally
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.focusable
import androidx.compose.foundation.gestures.LocalBringIntoViewSpec
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.zIndex
import de.paulherter.swiftly.PlayRequest
import de.paulherter.swiftly.Episode
import de.paulherter.swiftly.R
import de.paulherter.swiftly.PlayPlan
import de.paulherter.swiftly.ChapterMass
import de.paulherter.swiftly.PlayItem
import de.paulherter.swiftly.chapterBarRead
import de.paulherter.swiftly.SharedEvent
import de.paulherter.swiftly.GroupsEvent
import de.paulherter.swiftly.GroupsRow
import de.paulherter.swiftly.Season
import de.paulherter.swiftly.SwiftlyApplication
import de.paulherter.swiftly.TechBadge
import de.paulherter.swiftly.Choice
import de.paulherter.swiftly.activity
import de.paulherter.swiftly.episodesRead
import de.paulherter.swiftly.episodesPreload
import de.paulherter.swiftly.shared.Motion
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import de.paulherter.swiftly.core.Kern
import de.paulherter.swiftly.seriesRead
import de.paulherter.swiftly.selectionRead
import de.paulherter.swiftly.timeText
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.future.await
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.abs
import kotlin.math.roundToInt
import androidx.compose.animation.core.EaseInOut
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntOffset
import androidx.compose.foundation.layout.offset
import de.paulherter.swiftly.shared.motionReduced

/**
 * Player screen for TV; mirrors tvOS `PlayerScreen` and `PlayerEbenen`.
 *
 * Playback mechanics (VLC, tick, reports, media session) live in `PlayItem` (`PlayerPage.kt`),
 * shared with the phone player. This file only covers what differs on a TV: remote instead of touch.
 *
 * **Look (as on tvOS):** flat pure-black dimming, title and meta line top left, only icon buttons
 * top right (audio & subtitles, episodes, settings), bar at the bottom. No close button, no pause
 * glyph in the middle, no skip buttons; the D-pad operates it and Back closes.
 *
 * **Remote:** OK pauses or confirms a collected seek target; left/right collect for 350 ms before
 * seeking **once**, since VLC rebuilds the stream on every seek. Up goes to the icons on top
 * (to the skip pill first if it is shown).
 * Back: discard seek target, close layer, hide controls, hide overlay, close player.
 */
@Composable
fun TvPlayer(app: SwiftlyApplication, wish: PlayRequest, close: () -> Unit) {
    val context = LocalContext.current
    val activity = remember(context) { context.activity() }
    val run = rememberCoroutineScope()

    // The player runs in its own activity (`PlayerActivity`), so a `FocusRemember.letzter` from the
    // previous screen belongs to a foreign composition. `FocusRemember.prePlayer` (set in `TvMain`)
    // holds the way back.
    LaunchedEffect(Unit) { FocusRemember.lastOne = null }

    val mediaWork = remember { PlayItem(app, context, run) }
    val area = remember { arrayOfNulls<org.videolan.libvlc.util.VLCVideoLayout>(1) }
    @Suppress("DEPRECATION")
    val lifeRun = androidx.compose.ui.platform.LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifeRun) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == androidx.lifecycle.Lifecycle.Event.ON_PAUSE) mediaWork.backgroundReport()
            // **Home means pause.** A TV has no small window for the player to retreat to; without this VLC
            // kept playing behind the home screen, audible only. Same as tvOS pausing a backgrounded app.
            // The pause is reported through VLC's `Paused`; in a group the request goes to everyone (`toggle`).
            if (event == androidx.lifecycle.Lifecycle.Event.ON_STOP && mediaWork.player.isPlaying
                && activity?.isChangingConfigurations != true && activity?.isInPictureInPictureMode != true) {
                AppLog.writeOut("[Player] verlassen: anhalten")
                mediaWork.toggle()
            }
            if (event == androidx.lifecycle.Lifecycle.Event.ON_START && !mediaWork.player.vlcVout.areViewsAttached()) {
                area[0]?.let { mediaWork.player.attachViews(it, null, true, false) }
            }
        }
        lifeRun.addObserver(observer)
        onDispose { lifeRun.removeObserver(observer) }
    }

    DisposableEffect(mediaWork) {
        mediaWork.installEventListener()
        onDispose { mediaWork.cleanUp() }
    }
    DisposableEffect(mediaWork.session) {
        mediaWork.installSession()
        onDispose { mediaWork.sessionCleanUp() }
    }
    LaunchedEffect(mediaWork.plan, mediaWork.duration > 0) { mediaWork.metaDataUpdate() }
    LaunchedEffect(app.settings.techBadge, mediaWork.plan) { mediaWork.techBadgeTick(app.settings.techBadge) }
    LaunchedEffect(wish) { mediaWork.openAndTick(wish, close) }
    // Preload seasons and the current season so the episode layer is ready on open.
    LaunchedEffect(mediaWork.plan?.itemId) {
        val p = mediaWork.plan
        if (p != null && p.episode && p.seriesIdentifier != null) episodesPreload(app, p.seriesIdentifier, p.seasonIdentifier)
    }

    // **Kick the frame clock before the first frame, then leave it alone** (see `TvImageTick`).
    val frameRateAllowed = remember { app.store.rememberValue("bildrateAnpassen") != "0" }
    LaunchedEffect(Unit) {
        while (isActive && TvImageTick.stillPostMeasure()) {
            if (mediaWork.vlcFree) activity?.let { TvImageTick.adapt(it, mediaWork.player, frameRateAllowed) }
            delay(300)
        }
    }
    DisposableEffect(activity) {
        onDispose { activity?.let { TvImageTick.resolve(it) } }
    }

    var visible by remember { mutableStateOf(true) }
    var touched by remember { mutableIntStateOf(0) }
    // **Time left or end time**, as on phone and Apple TV: "-12:34" or "Ends at 22:41", same spot;
    // the choice persists. Down on the bar toggles it (`keyButton`).
    var asEnd by remember { mutableStateOf(app.store.rememberValue("restzeitAlsEnde") == "1") }
    fun asEndSet(an: Boolean) { asEnd = an; app.store.remember("restzeitAlsEnde", if (an) "1" else "0") }
    /** `tracks`, `episodes` or `settings`. */
    var openLayer by remember { mutableStateOf<String?>(null) }
    val layerOpen = openLayer != null

    LaunchedEffect(visible) { mediaWork.controlsChanged(visible) }
    LaunchedEffect(visible, mediaWork.running, openLayer, touched) {
        if (visible && mediaWork.running && openLayer == null) { delay(4000); visible = false }
    }
    LaunchedEffect(mediaWork.hint) { if (mediaWork.hint != null) { delay(5000); mediaWork.hint = null } }

    fun showItem() { visible = true; touched++ }

    // **Play/pause toggles against the intended state**, not VLC's report (mirrors tvOS `Switchgear`).
    // The report arrives only after the command; pressing twice quickly would toggle against the old
    // state and lose the second press. VLC's report becomes the intended state one second after the
    // last command; then it is something VLC did on its own (end, sleep timer).
    val wanted = remember { booleanArrayOf(false) }
    val lastCommanded = remember { longArrayOf(0L) }
    LaunchedEffect(mediaWork.running) {
        if (SystemClock.elapsedRealtime() - lastCommanded[0] > 1000) wanted[0] = mediaWork.running
    }

    // Seeking: collect, then jump **once** (mirrors tvOS `PlayerScreen.jump`).
    var seekTarget by remember { mutableStateOf<Double?>(null) }
    val lastStep = remember { longArrayOf(0L) }
    var collector by remember { mutableStateOf<Job?>(null) }
    fun markDiscard() { collector?.cancel(); seekTarget = null }
    fun scrub(um: Int) {
        if (!visible) { showItem(); return }
        val now = SystemClock.elapsedRealtime()
        val sinceLast = now - lastStep[0]
        lastStep[0] = now
        showItem()
        val target = (seekTarget ?: mediaWork.position) + um
        if (seekTarget == null && sinceLast > 450) { mediaWork.vault(target); return }
        seekTarget = target
        collector?.cancel()
        collector = run.launch { delay(350); seekTarget?.let { mediaWork.vault(it) }; seekTarget = null }
    }

    fun runSet(should: Boolean, source: String) {
        // **In a group this is a request** (iOS `ausfuehren`/`togglePlaying`): the button flips only when
        // the command comes back, then for everyone at once.
        if (mediaWork.inGroup) {
            markDiscard()
            if (should != mediaWork.running) app.kern.syncPlayPleaseToggle(mediaWork.running)
            AppLog.writeOut("[Taste] $source: Bitte an die Gruppe")
            showItem()
            return
        }
        wanted[0] = should
        lastCommanded[0] = SystemClock.elapsedRealtime()
        // Pause/resume means "here", not "there": a pending target is discarded.
        markDiscard()
        // Resuming after a long pause steps back a little (`PauseJumpBack`, via `werk.resume`).
        if (should) mediaWork.resume() else mediaWork.halt()
        AppLog.writeOut("[Taste] $source: ${if (should) "abspielen" else "anhalten"}")
        showItem()
    }
    fun toggle(source: String) = runSet(if (mediaWork.inGroup) !mediaWork.running else !wanted[0], source)

    val remoteHandset = remember { FocusRequester() }
    val buttonTracks = remember { FocusRequester() }
    val buttonEpisodes = remember { FocusRequester() }
    val buttonSettings = remember { FocusRequester() }
    val offeringFocus = remember { FocusRequester() }
    /** Up with hidden controls: the button attaches late, so it takes focus itself. */
    val topRequest = remember { booleanArrayOf(false) }
    /** Releases the layer's locked exit so focus can be restored. */
    val layersOutput = remember { booleanArrayOf(false) }

    val plan = mediaWork.plan
    val hasEpisodes = plan?.episode == true && plan.seriesIdentifier != null
    val title = plan?.headerLine?.takeIf { it.isNotEmpty() } ?: plan?.title.orEmpty()
    val meta = plan?.let {
        if (it.episode && it.seasonNr != null && it.episodeNr != null) translated("Staffel %lld · Folge %lld", it.seasonNr, it.episodeNr)
        else if (it.episode) it.subtitle.takeIf { u -> u.isNotEmpty() }
        else it.secondaryLine?.takeIf { n -> n.isNotEmpty() }
    }

    // **No controls before the first frame, only the loader** (tvOS: `firstImagePresent`).
    val controlsTarget = visible && mediaWork.imageFree && !layerOpen
    val coverage by animateFloatAsState(
        if (controlsTarget) 1f else 0f,
        if (controlsTarget) tween(180, easing = Motion.soft) else tween(340, easing = Motion.soft),
        label = "steuerung")
    // While a layer is open the controls stay attached (invisible): the button that opened the layer
    // must be able to take focus on close, **before** the layer goes away.
    // **Also in the frame after closing:** `coverage` is still 0 there and the fade-in only starts.
    // Without `controlsTarget` the controls dropped out for that one frame, the focused button went with
    // them, and focus landed on the bar instead of the button.
    val itemWitnessPresent = coverage > 0.01f || layerOpen || controlsTarget
    val titleTarget = controlsTarget || openLayer == "folgen"
    val titleCoverage by animateFloatAsState(if (titleTarget) 1f else 0f, tween(200), label = "titel")

    fun toTop() {
        val alreadyPresent = coverage > 0.01f
        showItem()
        if (alreadyPresent) runCatching { buttonTracks.requestFocus() } else topRequest[0] = true
    }

    fun unfoldLayer(which: String) {
        AppLog.writeOut("[Ebene] auf $which")
        layersOutput[0] = false
        openLayer = which
        touched++
    }
    // **Back to the button that opened the layer**: focus first, then the layer goes.
    fun layerClose() {
        val was = openLayer ?: return
        AppLog.writeOut("[Ebene] zu $was")
        layersOutput[0] = true
        val target = when (was) { "spuren" -> buttonTracks; "folgen" -> if (hasEpisodes) buttonEpisodes else remoteHandset; else -> buttonSettings }
        if (runCatching { target.requestFocus() }.isFailure) runCatching { remoteHandset.requestFocus() }
        openLayer = null
        showItem()
        // While the layer is up, the buttons below are locked, so the request above has no effect.
        // Repeat two frames later, when the controls are back.
        run.launch {
            repeat(2) { withFrameNanos { } }
            runCatching { target.requestFocus() }
        }
    }

    // **The overlay** without controls (mirrors `cardPresent`/`offeringLayer`): while shown, it holds focus.
    // Afterwards focus goes to the remote surface, not to a button, also when "Skip intro" hides
    // itself after six seconds.
    val cardPresent = mediaWork.overlay != "nichts" && mediaWork.imageFree && !controlsTarget && !layerOpen && !mediaWork.switches
    // **The next-episode card** (`TVEpisodesCard`): the overlay's countdown case, or while it zooms.
    // With controls open it waits (`OfferingLayer.cardWaitsControls`).
    val episodesCardPresent = mediaWork.cardsSwitch != null || (cardPresent && mediaWork.overlay == "karte")
    LaunchedEffect(episodesCardPresent) {
        if (mediaWork.cardsSwitch == null) AppLog.writeOut(if (episodesCardPresent) "[Karte] erscheint bei ${mediaWork.position.toInt()} s von ${mediaWork.duration.toInt()} s"
                                                         else "[Karte] geht (Zurück oder Steuerung)")
    }
    // From the card the controls stay hidden and focus goes to the idle surface (`focus = .idle`).
    LaunchedEffect(mediaWork.cardsSwitch == null) { if (mediaWork.cardsSwitch == null && !controlsTarget && !layerOpen) runCatching { remoteHandset.requestFocus() } }
    LaunchedEffect(cardPresent) {
        if (cardPresent) {
            runCatching { offeringFocus.requestFocus() }
            delay(80)
            runCatching { offeringFocus.requestFocus() }
            AppLog.writeOut("Angebot: ein (${mediaWork.overlay}), Fokus auf dem Knopf")
        } else if (!controlsTarget && !layerOpen) {
            runCatching { remoteHandset.requestFocus() }
        }
    }
    // **Focus follows the controls** instead of vanishing with them (mirrors `onChange(of: controlsPresent)`):
    // on a fading button, OK would open an invisible layer.
    LaunchedEffect(controlsTarget) {
        if (!controlsTarget && !layerOpen && !cardPresent) runCatching { remoteHandset.requestFocus() }
    }

    // While seeking, the pill makes way for the preview above the bar.
    val offeringPresent = mediaWork.offeringArt != "keiner" && mediaWork.offerText.isNotEmpty() && mediaWork.imageFree && !layerOpen
        && !mediaWork.switches && seekTarget == null
        && (mediaWork.overlay != "nichts" || (controlsTarget && mediaWork.offeringArt == "naechste"))

    // If the pill disappears under focus (pressed, section over, seeking), focus moves to the surface,
    // otherwise it would be left on nothing.
    var pillHasFocus by remember { mutableStateOf(false) }
    LaunchedEffect(offeringPresent) { if (!offeringPresent && pillHasFocus) runCatching { remoteHandset.requestFocus() } }

    // **Back**: same order as `onExitCommand` on tvOS. The season picker in the episode layer attaches
    // later and therefore goes first.
    BackHandler {
        when {
            seekTarget != null -> markDiscard()
            openLayer != null -> layerClose()
            controlsTarget -> {
                runCatching { remoteHandset.requestFocus() }
                visible = false
                AppLog.writeOut("[Zurück] Steuerung aus")
            }
            cardPresent -> { mediaWork.offeringClose(); AppLog.writeOut("[Angebot] Zurück schließt") }
            else -> mediaWork.finish(close)
        }
    }

    // **Only the bar interprets directions.** `onKeyEvent` on the outer box also receives what a
    // focused button top right does not consume.
    var barFocus by remember { mutableStateOf(false) }
    fun keyButton(e: KeyEvent): Boolean {
        if (layerOpen || !barFocus) return false
        if (e.type != KeyEventType.KeyDown) return false
        when (e.key) {
            Key.DirectionCenter, Key.Enter, Key.NumPadEnter, Key.Spacebar -> {
                if (e.nativeKeyEvent.repeatCount > 0) return true
                val target = seekTarget
                if (target != null) { showItem(); markDiscard(); mediaWork.vault(target) } else toggle("Klick")
            }
            Key.DirectionLeft -> scrub(-mediaWork.backS)
            Key.DirectionRight -> scrub(mediaWork.preS)
            Key.MediaRewind -> scrub(-mediaWork.backS)
            Key.MediaFastForward -> scrub(mediaWork.preS)
            Key.MediaNext -> if (mediaWork.hasNext) run.launch { mediaWork.nextEpisode() }
            // **Up goes straight to the icons**, also on the first press while the controls are still hidden.
            // If the pill sits above the bar, it comes in between.
            Key.DirectionUp -> if (visible && offeringPresent) runCatching { offeringFocus.requestFocus() } else toTop()
            Key.Menu -> if (mediaWork.imageFree && e.nativeKeyEvent.repeatCount == 0) unfoldLayer("einstellungen")
            // **Down toggles time left** (mirrors `TimeBar.onMoveCommand`): "-12:34" or "Ends at 22:41".
            // Without controls, Down first brings them up, like every direction on tvOS.
            Key.DirectionDown -> if (controlsTarget) { asEndSet(!asEnd); showItem() } else showItem()
            else -> return false
        }
        return true
    }

    // **Play/pause applies everywhere in the player** (`onPlayPauseCommand`), also on a button or in a
    // layer. Held keys do not repeat.
    fun playbackKey(e: KeyEvent): Boolean {
        val k = e.key
        if (k != Key.MediaPlayPause && k != Key.MediaPlay && k != Key.MediaPause) return false
        if (e.type != KeyEventType.KeyDown || e.nativeKeyEvent.repeatCount > 0) return true
        when (k) {
            Key.MediaPlay -> runSet(true, "Abspieltaste")
            Key.MediaPause -> runSet(false, "Pausetaste")
            else -> toggle("Wiedergabetaste")
        }
        return true
    }

    CompositionLocalProvider(LocalWithinPanel provides true) {
    Box(Modifier.fillMaxSize().background(Color.Black).onPreviewKeyEvent { playbackKey(it) }) {
    Box(Modifier.fillMaxSize()
            .focusRequester(remoteHandset).onFocusChanged { barFocus = it.isFocused }.focusable().onKeyEvent { keyButton(it) }) {
        AndroidView(factory = { ctx -> org.videolan.libvlc.util.VLCVideoLayout(ctx).also { area[0] = it; mediaWork.videoArea = it; mediaWork.player.attachViews(it, null, true, false) } },
                    modifier = Modifier.fillMaxSize())

        if (!mediaWork.imageFree && mediaWork.cardsSwitch == null) {
            Box(Modifier.fillMaxSize().background(Color.Black), contentAlignment = Alignment.Center) {
                if (mediaWork.hint == null) TvLoader(size = 64.dp)
            }
        }

        // **Only the ring, no pause glyph**: when paused the bar shows it. Also while the stream is rebuilt
        // after a drop (tvOS: `timeStands || restoring`).
        if (mediaWork.imageFree && mediaWork.cardsSwitch == null && (mediaWork.switches || mediaWork.restoring || (mediaWork.running && mediaWork.buffers))) {
            Box(Modifier.align(Alignment.Center)) { TvLoader(size = 64.dp) }
        }

        // **With the card up, the scrim dims the picture** as with open controls, and the card sits in front.
        val cardScrim by animateFloatAsState(if (episodesCardPresent && mediaWork.cardsSwitch == null) 1f else 0f,
            if (episodesCardPresent) tween(180, easing = Motion.soft) else tween(340, easing = Motion.soft), label = "kartenschleier")
        if (cardScrim > 0.01f && !itemWitnessPresent) Box(Modifier.fillMaxSize().graphicsLayer { alpha = cardScrim }.background(Color.Black.copy(alpha = 0.42f)))
        if (!mediaWork.inGroup && (mediaWork.plan?.nextEpisode != null || mediaWork.cardsSwitch != null)) {
            val m = mediaWork.cardsMetrics
            Box(Modifier.fillMaxSize().onPreviewKeyEvent { e ->
                    // Without controls every direction brings them up; the card then waits (gone, countdown paused).
                    val bearing = e.key == Key.DirectionUp || e.key == Key.DirectionDown || e.key == Key.DirectionLeft || e.key == Key.DirectionRight
                    if (!bearing || !episodesCardPresent || mediaWork.cardsSwitch != null) return@onPreviewKeyEvent false
                    if (e.type == KeyEventType.KeyDown) { AppLog.writeOut("[Karte] Richtungstaste holt die Steuerung"); showItem() }
                    true
                }) {
                de.paulherter.swiftly.EpisodeCard(mediaWork, episodesCardPresent, card = { w, h, d ->
                    val width = m.width
                    val height = width * 9f / 16f
                    val x = w / d - TvTheme.edgePage.value - width
                    val y = h / d - TvTheme.edgeTop.value - m.rows - height
                    androidx.compose.ui.geometry.Rect(x * d, y * d, (x + width) * d, (y + height) * d)
                }, focus = offeringFocus) { mediaWork.offeringClose() }
            }
        }

        if (itemWitnessPresent) {
            // **Pure black, 42 %**, no gradients (mirrors `scrim`).
            Box(Modifier.fillMaxSize().graphicsLayer { alpha = coverage }.background(Color.Black.copy(alpha = 0.42f)))
            Box(Modifier.fillMaxSize().graphicsLayer { alpha = coverage }
                    .padding(horizontal = TvTheme.edgePage, vertical = TvTheme.edgeTop)) {
                val seeks = seekTarget != null
                // Room on the left for the title (drawn by `stehender Title`) and the meta line below.
                Row(Modifier.fillMaxWidth().align(Alignment.TopStart), verticalAlignment = Alignment.Top) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(TvPlayerMetric.titleSpacing)) {
                        Text(title, style = TvPlayerMetric.title, maxLines = 1, modifier = Modifier.alpha(0f))
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            // **In a group the group is shown here**: state, so accent color.
                            val group = if (mediaWork.inGroup) app.gemeinsam.value.group else null
                            if (group != null) GroupsRow(group.name, app.gemeinsam.value.withWhom, TvPlayerMetric.meta.fontSize)
                            else meta?.let { Text(it, style = TvPlayerMetric.meta, color = Theme.fontQuiet, maxLines = 1, overflow = TextOverflow.Ellipsis) }
                            if (plan != null && !plan.lossless && plan.method.isNotEmpty()) {
                                Symbol(Glyph.Warning, 12.dp, color = Theme.warning)
                                Text(plan.method, style = TvPlayerMetric.meta, color = Theme.warning, maxLines = 1)
                            }
                        }
                    }
                    Spacer(Modifier.width(24.dp))
                    // Audio & subtitles, episodes (series only), settings. They make way while seeking.
                    Row(Modifier.alpha(if (seeks) 0f else 1f)
                            .onPreviewKeyEvent { e ->
                                if (e.type == KeyEventType.KeyDown) showItem()
                                when (e.key) {
                                    Key.DirectionDown -> { if (e.type == KeyEventType.KeyDown) runCatching { remoteHandset.requestFocus() }; true }
                                    Key.DirectionUp -> true
                                    else -> false
                                }
                            },
                        horizontalArrangement = Arrangement.spacedBy(TvPlayerMetric.buttonSpacing)) {
                        TvIconButton(Glyph.Subtitle, translated("Audio & Untertitel"), !seeks, buttonTracks) { unfoldLayer("spuren") }
                        if (hasEpisodes) TvIconButton(Glyph.Pile, translated("Folgen"), !seeks, buttonEpisodes) { unfoldLayer("folgen") }
                        TvIconButton(Glyph.SliderControl, translated("Einstellungen"), !seeks, buttonSettings) { unfoldLayer("einstellungen") }
                        LaunchedEffect(Unit) {
                            if (topRequest[0]) {
                                topRequest[0] = false
                                repeat(5) { if (runCatching { buttonTracks.requestFocus() }.isSuccess) return@LaunchedEffect; delay(TvTheme.focusDeadline) }
                            }
                        }
                    }
                }
                Box(Modifier.align(Alignment.BottomStart).fillMaxWidth()
                        .semantics(mergeDescendants = true) {
                            contentDescription = translated("Abspielstelle")
                            // With chapter: "12:00 / 45:00, chapter name"; the name comes from the server, untranslated.
                            stateDescription = timeText(mediaWork.position) + " / " + timeText(mediaWork.duration) +
                                (if (mediaWork.chapterCount > 0) app.kern.chapterName(mediaWork.position).let { if (it.isEmpty()) "" else ", $it" } else "")
                        }) {
                    TvTimeBar(app, { mediaWork.position }, mediaWork.duration, seekTarget, mediaWork.running, asEnd, mediaWork.chapterCount) { mediaWork.trickplayImage(it) }
                }
            }
        }

        // **The offer button**, right above the bar, in the same place with and without controls.
        // Not while the card is there.
        AnimatedVisibility(visible = offeringPresent && mediaWork.overlay != "karte" && mediaWork.cardsSwitch == null, modifier = Modifier.align(Alignment.BottomEnd),
            enter = fadeIn(tween(180, easing = Motion.soft)),
            exit = fadeOut(tween(340, easing = Motion.soft))) {
            Box(Modifier.padding(end = TvTheme.edgePage, bottom = TvTheme.edgeTop + TvPlayerMetric.bar + TvPlayerMetric.overBar)
                    .onFocusChanged { pillHasFocus = it.hasFocus }
                    .onPreviewKeyEvent { e ->
                        val bearing = e.key == Key.DirectionUp || e.key == Key.DirectionDown || e.key == Key.DirectionLeft || e.key == Key.DirectionRight
                        if (!bearing) return@onPreviewKeyEvent false
                        if (e.type != KeyEventType.KeyDown) return@onPreviewKeyEvent true
                        if (!controlsTarget) {
                            // Without controls every direction brings them up. A card is thereby dismissed; a skip button
                            // stays.
                            AppLog.writeOut("Angebot: Richtungstaste holt die Steuerung")
                            showItem()
                        } else when (e.key) {
                            Key.DirectionUp -> runCatching { buttonTracks.requestFocus() }
                            Key.DirectionDown -> runCatching { remoteHandset.requestFocus() }
                            else -> {}
                        }
                        true
                    }) {
                TvOfferingPill(mediaWork.offerText,
                    share = null,
                    seconds = null,
                    running = mediaWork.running, length = mediaWork.countdownLength,
                    modifier = Modifier.focusRequester(offeringFocus)) {
                    AppLog.writeOut("Angebot: gedrückt (${mediaWork.offeringArt})")
                    mediaWork.offeringRun()
                }
            }
        }

        // **What happens in the group, briefly on top**, so nobody wonders why the film stopped.
        val event = if (mediaWork.inGroup) app.gemeinsam.value.event else null
        val rememberedEvent = remember { arrayOfNulls<SharedEvent>(1) }
        event?.let { rememberedEvent[0] = it }
        AnimatedVisibility(event != null, Modifier.align(Alignment.TopCenter)
                .padding(top = TvTheme.edgeTop + TvPlayerMetric.button + 8.dp),
            enter = fadeIn(tween(180, easing = Motion.soft)), exit = fadeOut(tween(340, easing = Motion.soft))) {
            rememberedEvent[0]?.let { e -> androidx.compose.runtime.key(e.id) { GroupsEvent(e, style = TvTheme.body, symbolText = 20.dp, height = 56.dp) } }
        }
        // A group message (`SyncPlayError`) shown where the player's own messages appear.
        val sharedError = app.sharedError.value
        LaunchedEffect(sharedError) { sharedError?.let { mediaWork.hint = it; app.sharedError.value = null } }

        mediaWork.hint?.let {
            Text(it, style = TvTheme.body.copy(textAlign = androidx.compose.ui.text.style.TextAlign.Center), color = Theme.font,
                 modifier = Modifier.align(Alignment.TopCenter).padding(top = 90.dp, start = 96.dp, end = 96.dp))
        }

        // **The tech badge**: takes neither focus nor input. It starts below the title line and **slides
        // with the controls**: with controls hidden it moves up to where they were. Movement instead of
        // fade, 0.2 s easeInOut; with reduced motion it jumps.
        if (app.settings.techBadge && mediaWork.techFixed.isNotEmpty()) {
            val reduced = motionReduced()
            val up by animateFloatAsState(if (controlsTarget) 0f else 1f,
                if (reduced) snap() else tween(200, easing = EaseInOut), label = "technikschild")
            val distance = with(LocalDensity.current) { (TvPlayerMetric.button + TvTheme.tileSpacing).toPx() }
            TechBadge(mediaWork.techFixed, mediaWork.techLive, { mediaWork.position }, mediaWork.duration,
                app.settings.techBadgeMeasure, far = true,
                Modifier.align(Alignment.TopStart)
                    .padding(start = TvTheme.edgePage, top = TvTheme.edgeTop + TvPlayerMetric.button + TvTheme.tileSpacing)
                    .offset { IntOffset(0, -(up * distance).roundToInt()) })
        }

        // **The three layers**: full screen over the picture, closed focus group: focus stays inside until
        // Back closes it.
        var lastLayer by remember { mutableStateOf("spuren") }
        LaunchedEffect(openLayer) { openLayer?.let { lastLayer = it } }
        AnimatedVisibility(visible = layerOpen, enter = fadeIn(tween(200)), exit = fadeOut(tween(200))) {
            @OptIn(ExperimentalComposeUiApi::class)
            Box(Modifier.fillMaxSize()
                    // **Open for a panel above** (tile menu of an episode): otherwise `Cancel` would lock its
                    // `requestFocus` too, it would show without focus, and OK would go to the tile below.
                    .focusProperties { exit = { if (layersOutput[0] || app.sheet.value != null) FocusRequester.Default else FocusRequester.Cancel } }
                    .focusGroup()) {
                // **No blur:** VLC draws into a `SurfaceView`, which the system composites separately, so a
                // `RenderEffect` does not reach it (same as on the phone, `Ebenengrund` in PlayerPage.kt).
                // Substitute: pure black, 80 %.
                Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.8f)))
                when (openLayer ?: lastLayer) {
                    "spuren" -> TvTracksLayer(mediaWork)
                    "einstellungen" -> TvSettingLayer(mediaWork, app, layerClose = { layerClose() }) { mediaWork.finish(close) }
                    "folgen" -> plan?.takeIf { hasEpisodes }?.let { p ->
                        TvEpisodesLayer(app, p, title) { f ->
                            layerClose()
                            // Choosing the running episode means: keep watching.
                            if (f.id != p.itemId) run.launch { mediaWork.episodeSelect(f.id) }
                        }
                    }
                }
            }
        }

        // **The title top left, one layer above everything**; it stays when the episode layer is open.
        if (titleCoverage > 0.01f) {
            Row(Modifier.fillMaxWidth().graphicsLayer { alpha = titleCoverage }
                    .padding(horizontal = TvTheme.edgePage).padding(top = TvTheme.edgeTop)) {
                Text(title, style = TvPlayerMetric.title, color = Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis,
                     modifier = Modifier.weight(1f))
                Spacer(Modifier.width(24.dp + TvPlayerMetric.iconRail(if (hasEpisodes) 3 else 2)))
            }
        }
    }
    }
    }
}

/**
 * Player dimensions on TV: `Playermass` in `Sources/tvOS/PlayerLayers.swift`, halved
 * (tvOS works in 1920 pt width, Android TV in 960 dp).
 */
private object TvPlayerMetric {
    val title = TvTheme.rail
    val meta = TvTheme.small
    val time = 13.sp
    val previewTime = 15.sp
    val barReason = Color.White.copy(alpha = 0.28f)
    val titleSpacing = 3.dp
    val button = 44.dp
    val buttonSpacing = 10.dp
    val overBar = 20.dp
    val bar = 20.dp
    val column = 250.dp
    val columnSpacing = 57.dp
    /** For when the columns would not otherwise fit (settings with quality or group). */
    val columnsSpacingNarrow = 20.dp
    val columnsTop = 76.dp
    fun iconRail(count: Int) = button * count + buttonSpacing * (count - 1)
}

/** Loading ring for the TV picture: larger than on the phone, read from three meters. */
@Composable
private fun TvLoader(size: androidx.compose.ui.unit.Dp) {
    androidx.compose.material3.CircularProgressIndicator(color = Theme.font, strokeWidth = 3.dp, modifier = Modifier.size(size))
}

/** One of the icon buttons top right: at rest only the glyph, focused the white surface (`IconButtonStyle`). */
@Composable
private fun TvIconButton(symbol: Glyph, description: String, active: Boolean, focus: FocusRequester, perform: () -> Unit) {
    FocusArea(Modifier.focusRequester(focus).focusProperties { canFocus = active }
            .semantics { contentDescription = description }, magnifier = TvTheme.focusMagnifierSmall, perform = perform) { has ->
        Box(Modifier.size(TvPlayerMetric.button).clip(RoundedCornerShape(TvTheme.corner))
                .background(if (has) Color.White else Color.Transparent), contentAlignment = Alignment.Center) {
            // tvOS 38 pt Medium, halved.
            Symbol(symbol, 19.dp, color = if (has) Theme.reason else Theme.font, strength = Strength.Medium)
        }
    }
}

/**
 * **The skip pill** (`PillsStyle` on tvOS): at rest a dark surface with white text, focused a white
 * surface with dark text and magnifier, like the icon buttons. The countdown fills it from the left;
 * in the player the accent color belongs only to the bar's handle.
 */
@Composable
private fun TvOfferingPill(text: String, share: Double?, seconds: Int?, running: Boolean, length: Double,
                            modifier: Modifier = Modifier, perform: () -> Unit) {
    val fillContent = de.paulherter.swiftly.continuousFill(share, running, length)
    val form = RoundedCornerShape(TvTheme.corner)
    FocusArea(modifier = modifier.semantics(mergeDescendants = true) {
        if (seconds != null) stateDescription = translated("Startet in %lld Sekunden", seconds)
    }, magnifier = TvTheme.focusMagnifier, perform = perform) { focus ->
        // **No shadows**, also not under the skip pill: a soft shadow turns to mud at three
        // meters, and it would be the only platform with shadows. Focus is expressed by size and surface.
        val font = if (focus) Theme.reason else Theme.font
        Row(Modifier.height(36.dp).clip(form).background(if (focus) Theme.font else Color.Black.copy(alpha = 0.55f))
                .drawBehind {
                    if (share != null) drawRect(font.copy(alpha = 0.16f), size = size.copy(width = size.width * fillContent))
                }
                .padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
            Symbol(Glyph.Skip, 15.dp, color = font, strength = Strength.Semibold)
            Text(text, style = TvTheme.button, color = font, maxLines = 1)
        }
    }
}

/**
 * Time, bar, time left; mirrors `TimeBar` in `Sources/tvOS/PlayerScreen.swift`. **Not a focus
 * target**: the remote is evaluated on the surface, the bar only draws the state. When paused the
 * pause glyph precedes the time. While seeking the bar thickens, the handle appears in accent color,
 * above it the trickplay image with the target time (without trickplay only the time).
 */
@Composable
private fun TvTimeBar(app: SwiftlyApplication, position: () -> Double, duration: Double, mark: Double?, running: Boolean, asEnd: Boolean,
                         chapterCount: Int, preview: (Double) -> android.graphics.Bitmap?) {
    val seeks = mark != null
    // `position` is a lambda: it is read here, not on every tick in the whole player.
    val now = position()
    val shown = mark ?: now
    fun share(s: Double): Float = if (duration > 0) (s / duration).coerceIn(0.0, 1.0).toFloat() else 0f
    val handleScale by animateFloatAsState(if (seeks) 1f else 0.4f, tween(180), label = "griffSkala")
    val handleCoverage by animateFloatAsState(if (seeks) 1f else 0f, tween(180), label = "griffDeckung")
    val digits = TextStyle(fontSize = TvPlayerMetric.time, fontFeatureSettings = "tnum")

    Row(Modifier.fillMaxWidth().height(TvPlayerMetric.bar), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            AnimatedVisibility(visible = !running, enter = fadeIn(tween(180)) + expandHorizontally(tween(180)),
                               exit = fadeOut(tween(180)) + shrinkHorizontally(tween(180))) {
                Symbol(Glyph.Pause, 12.dp, Modifier.padding(end = 8.dp), color = Theme.font, strength = Strength.Medium)
            }
            Text(timeText(now), style = digits, color = Theme.fontQuiet)
        }
        BoxWithConstraints(Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.CenterStart) {
            val width = maxWidth
            val state = share(now)
            val target = share(shown)
            // **One segment per chapter** (mirrors `ChapterMask`): the core computes gaps and too-narrow cuts
            // (`ChapterBar`); without chapters one segment across the full width. While seeking only the
            // segment containing the target rises to 6, the others stay at 4. Gap size as on the phone: tvOS
            // uses 4 pt at an 8 pt bar, here 2 dp at 4 dp.
            val bar = remember(chapterCount, duration, width) {
                chapterBarRead(app.kern.chapterBar(duration, width.value.toDouble(), ChapterMass.minWidth, ChapterMass.gap))
            }
            val elevated = if (seeks) app.kern.chapterPiece(target.toDouble(), duration, width.value.toDouble(), ChapterMass.minWidth).toInt() else -1
            val fromState = width * minOf(state, target)
            bar.pieces.forEachIndexed { i, piece ->
                key(i) {
                    val stripe by animateDpAsState(if (i == elevated) 6.dp else 4.dp, tween(180), label = "balken")
                    Box(Modifier.offset(x = piece.x.dp).width(piece.width.dp).height(stripe)
                        .clip(CircleShape).background(TvPlayerMetric.barReason)) {
                        // Up to the actual position: that part has been seen.
                        Box(Modifier.width((fromState - piece.x.dp).coerceIn(0.dp, piece.width.dp)).fillMaxHeight().background(Theme.font))
                        // The span between position and target: how far from here the seek lands.
                        if (seeks) Box(Modifier.offset(x = fromState - piece.x.dp).width(width * abs(target - state)).fillMaxHeight()
                            .background(Color.White.copy(alpha = 0.55f)))
                    }
                }
            }
            Box(Modifier.offset(x = width * target - 9.dp).size(18.dp)
                    .graphicsLayer { scaleX = handleScale; scaleY = handleScale; alpha = handleCoverage }
                    .background(Theme.accent, CircleShape))
            if (seeks) {
                val image = preview(shown)
                // Bottom edge just above the bar, horizontally above the handle; at the edges the box stays
                // fully on the bar.
                Column(Modifier.align(Alignment.TopStart).layout { measurable, _ ->
                        val p = measurable.measure(Constraints())
                        layout(0, 0) {
                            val total = width.roundToPx()
                            val half = p.width / 2
                            val x = (total * target).roundToInt().coerceIn(half, maxOf(total - half, half)) - half
                            p.place(x, -p.height - 4.dp.roundToPx())
                        }
                    },
                    horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    image?.let {
                        Image(it.asImageBitmap(), contentDescription = null, contentScale = ContentScale.Crop,
                            modifier = Modifier.size(200.dp, 112.5.dp).clip(RoundedCornerShape(TvTheme.corner))
                                .border(1.dp, Color.White.copy(alpha = 0.35f), RoundedCornerShape(TvTheme.corner)))
                    }
                    // **With a chapter its name precedes the time**, on one line and at most as wide as the thumbnail;
                    // a long name is truncated, never the time.
                    val name = if (chapterCount > 0) app.kern.chapterName(shown) else ""
                    Row(Modifier.widthIn(max = 200.dp), verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally)) {
                        if (name.isNotEmpty()) {
                            Text(name, style = TextStyle(fontSize = TvPlayerMetric.previewTime), color = Theme.font, maxLines = 1,
                                 overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                        }
                        Text(timeText(shown), style = TextStyle(fontSize = TvPlayerMetric.previewTime, fontWeight = FontWeight.SemiBold,
                             fontFeatureSettings = "tnum"), color = Theme.font, maxLines = 1)
                    }
                }
            }
        }
        val rest = (duration - now).coerceAtLeast(0.0)
        val context = LocalContext.current
        val text = if (asEnd) translated("Endet um %@",
            android.text.format.DateFormat.getTimeFormat(context).format(java.util.Date(System.currentTimeMillis() + (rest * 1000).toLong())))
            else "−" + timeText(rest)
        Text(text, style = digits, color = Theme.fontQuiet, maxLines = 1)
    }
}

// MARK: Layers (mirrors tvOS `PlayerLayers.swift`)

/** Puts focus into a layer: the first request often falls into the pass that attaches the target. */
private suspend fun focusPut(target: FocusRequester) {
    repeat(6) { if (runCatching { target.requestFocus() }.isSuccess) return; delay(TvTheme.focusDeadline) }
}

/** Width of a `Wahlspalte`, set by `ColumnsRail` so all columns fit. */
private val LocalColumnsWidth = compositionLocalOf { TvPlayerMetric.column }

/**
 * Columns side by side, centered; at the bottom they end at the screen edge, overflow scrolls.
 * **All columns are on screen.** Four or five columns of 250 dp are wider than the TV (960 dp);
 * the row ran off to the right and `Row` gave the last columns no width, so focus never arrived.
 * If they do not fit, the row tightens and the columns get narrower.
 */
@Composable
private fun ColumnsRail(count: Int, content: @Composable RowScope.() -> Unit) {
    BoxWithConstraints(Modifier.fillMaxSize().padding(horizontal = TvTheme.edgePage).padding(top = TvPlayerMetric.columnsTop)) {
        val n = count.coerceAtLeast(1)
        val broad = TvPlayerMetric.column * n + TvPlayerMetric.columnSpacing * (n - 1)
        val spacing = if (broad <= maxWidth) TvPlayerMetric.columnSpacing else TvPlayerMetric.columnsSpacingNarrow
        val width = minOf(TvPlayerMetric.column, (maxWidth - spacing * (n - 1)) / n)
        CompositionLocalProvider(LocalColumnsWidth provides width) {
            Row(Modifier.fillMaxSize(), horizontalArrangement = Arrangement.spacedBy(spacing, Alignment.CenterHorizontally), content = content)
        }
    }
}

/** Fixed heading, only the rows below scroll; by focus, each column on its own. */
@Composable
private fun SelectionColumn(title: String, list: LazyListState, content: LazyListScope.() -> Unit) {
    Column(Modifier.width(LocalColumnsWidth.current).fillMaxHeight()) {
        Text(title, style = TvTheme.subpageTitle, color = Theme.font, maxLines = 1,
             modifier = Modifier.padding(start = 13.dp, bottom = 11.dp).semantics { heading() })
        LazyColumn(Modifier.weight(1f).focusGroup(), state = list, verticalArrangement = Arrangement.spacedBy(2.dp),
                   contentPadding = PaddingValues(bottom = TvTheme.edgeTop), content = content)
    }
}

/** Checkmark and name. Selected is white and semibold, otherwise quiet; focus is the calm surface of `EpisodesStyle`. */
@Composable
private fun LayersRow(text: String, selected: Boolean, modifier: Modifier = Modifier, perform: () -> Unit) {
    FocusArea(modifier.fillMaxWidth().semantics { this.selected = selected }, magnifier = 1f, perform = perform) { focus ->
        Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(TvTheme.cornerTile))
                .background(if (focus) TvTheme.focusArea else Color.Transparent)
                .padding(horizontal = 13.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(11.dp)) {
            val color = if (selected || focus) Theme.font else Theme.fontQuiet
            Box(Modifier.width(21.dp), contentAlignment = Alignment.Center) {
                if (selected) Symbol(Glyph.Checkmark, 15.dp, color = color, strength = Strength.Semibold)
            }
            // Track names come from the file, verbatim.
            Text(text, style = if (selected) TvTheme.button else TvTheme.body,
                 color = color, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/**
 * **Delay: last row of the audio and subtitle columns.** Mirrors `Verzoegerungszeile` in
 * `Sources/tvOS/PlayerLayers.swift`: three focus targets (-, +, reset) instead of one row catching
 * left/right, since left and right switch columns here. Held, the remote repeats the key; each press
 * goes through the `Haltezaehler` in the package and gets faster. After reset the reset arrow
 * disappears and focus goes to +.
 */
@Composable
private fun TvDelayRow(milliseconds: Int, shove: (Int) -> Unit, reset: () -> Unit) {
    val a = remember(milliseconds) { de.paulherter.swiftly.delayDisplay(milliseconds) }
    val plus = remember { FocusRequester() }
    Column(Modifier.fillMaxWidth().padding(top = 11.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(translated("Verzögerung"), style = TvTheme.small, color = Theme.fontVeryQuiet, modifier = Modifier.padding(horizontal = 13.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            TvDelayKey(Glyph.Minus, translated("Früher"), a.atStart, true) { shove(-1) }
            Text(a.text, style = TvTheme.button.copy(fontFeatureSettings = "tnum"), textAlign = androidx.compose.ui.text.style.TextAlign.Center, maxLines = 1,
                 color = if (a.isNull) Theme.fontQuiet else Theme.font,
                 modifier = Modifier.weight(1f).semantics { stateDescription = a.text })
            TvDelayKey(Glyph.Plus, translated("Später"), a.atEnd, true, Modifier.focusRequester(plus)) { shove(1) }
            TvDelayKey(Glyph.Ruecksetzen, translated("Zurücksetzen"), false, false,
                                 Modifier.focusProperties { canFocus = !a.isNull }.alpha(if (a.isNull) 0f else 1f)) {
                if (!a.isNull) { reset(); runCatching { plus.requestFocus() } }
            }
        }
    }
}

/**
 * One key of the delay row: white when focused like `TvIconButton`. **At the limit it stays focusable**
 * (just dimmed): if focus vanished mid-hold, it would jump to another column. `redo`: every
 * KeyDown of the center key counts, including repeats while held; `clickable` fires only on release,
 * once.
 */
@Composable
private fun TvDelayKey(symbol: Glyph, description: String, locked: Boolean, redo: Boolean,
                                 modifier: Modifier = Modifier, perform: () -> Unit) {
    val center = setOf(Key.DirectionCenter, Key.Enter, Key.NumPadEnter)
    FocusArea(modifier.semantics { contentDescription = description }
            .onPreviewKeyEvent { e ->
                if (!redo || e.key !in center) false
                else { if (e.type == KeyEventType.KeyDown) perform(); true }
            }, magnifier = TvTheme.focusMagnifierSmall, perform = perform) { has ->
        Box(Modifier.size(TvPlayerMetric.button).clip(RoundedCornerShape(TvTheme.corner))
                .background(if (has) Color.White else Color.Transparent), contentAlignment = Alignment.Center) {
            Symbol(symbol, 16.dp, Modifier.alpha(if (locked) 0.4f else 1f),
                   color = if (has) Theme.reason else Theme.font, strength = Strength.Semibold)
        }
    }
}

/**
 * Audio & subtitles: two columns, each scrolls on its own. The own choice shows immediately,
 * independent of VLC, which applies the selection one tick later. On open, focus is on the chosen audio track.
 */
@Composable
private fun TvTracksLayer(mediaWork: PlayItem) {
    val audio = remember { mediaWork.trackList(audio = true) }
    val subtitle = remember { mediaWork.trackList(audio = false) }
    var audioSelection by remember { mutableIntStateOf(mediaWork.player.audioTrack) }
    var utSelection by remember { mutableIntStateOf(mediaWork.player.spuTrack) }
    val audioStart = remember { audio.indexOfFirst { it.first == audioSelection } }
    // Row 0 is "Off".
    val utStart = remember { subtitle.indexOfFirst { it.first == utSelection } + 1 }
    val start = remember { FocusRequester() }
    val audioList = rememberLazyListState((audioStart - 2).coerceAtLeast(0))
    val utList = rememberLazyListState((utStart - 2).coerceAtLeast(0))
    LaunchedEffect(Unit) { focusPut(start) }

    ColumnsRail(2) {
        SelectionColumn(translated("Audio"), audioList) {
            itemsIndexed(audio, key = { _, s -> "t${s.first}" }) { i, (id, name) ->
                LayersRow(name, audioSelection == id, if (i == audioStart) Modifier.focusRequester(start) else Modifier) {
                    audioSelection = id; mediaWork.audioFromHand(id)
                }
            }
            item(key = "vt") {
                TvDelayRow(mediaWork.audioDelay, { mediaWork.delayPush(true, it) }) { mediaWork.delaySet(true, 0) }
            }
        }
        SelectionColumn(translated("Untertitel"), utList) {
            item(key = "aus") {
                LayersRow(translated("Aus"), utSelection == -1, if (audioStart < 0 && utStart == 0) Modifier.focusRequester(start) else Modifier) {
                    utSelection = -1; mediaWork.subtitleFromHand(-1)
                }
            }
            itemsIndexed(subtitle, key = { _, s -> "u${s.first}" }) { i, (id, name) ->
                LayersRow(name, utSelection == id, if (audioStart < 0 && utStart == i + 1) Modifier.focusRequester(start) else Modifier) {
                    utSelection = id; mediaWork.subtitleFromHand(id)
                }
            }
            item(key = "vu") {
                TvDelayRow(mediaWork.subtitleDelay, { mediaWork.delayPush(false, it) }) { mediaWork.delaySet(false, 0) }
            }
        }
    }
}

/**
 * Settings: picture, sleep timer, tech badge, quality (mirrors `SettingLayer`). Focus on the chosen picture mode.
 * **Time left is not here**: as on tvOS, Down on the bar toggles it (`keyButton`).
 */
@Composable
private fun TvSettingLayer(mediaWork: PlayItem, app: SwiftlyApplication,
                                layerClose: () -> Unit, groupLeave: () -> Unit) {
    val e = app.settings
    val start = remember { FocusRequester() }
    val fillingAtStart = remember { mediaWork.fillFrame }
    LaunchedEffect(Unit) { focusPut(start) }
    // Only when playing from the server and the account may transcode, **not in a group**: reloading
    // would bypass the group and playback would continue alone (iOS `qualitySelection`).
    val qualityShow = e.convertAllowed && mediaWork.plan?.url?.startsWith("file") != true && !mediaWork.inGroup
    val group = if (mediaWork.inGroup) app.gemeinsam.value.group else null
    val run = rememberCoroutineScope()
    // Order as on Apple TV: (group), picture, sleep timer, tech badge, (quality).
    ColumnsRail(3 + (if (group != null) 1 else 0) + (if (qualityShow) 1 else 0)) {
        // **Group first**: who is in it (information, no buttons), below that the exit.
        if (group != null) SelectionColumn(translated("Gemeinsam · %@", group.name), rememberLazyListState()) {
            group.participant.forEachIndexed { i, name ->
                item(key = "t$i") {
                    Row(Modifier.fillMaxWidth().padding(horizontal = 13.dp, vertical = 9.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(11.dp)) {
                        Box(Modifier.width(21.dp), contentAlignment = Alignment.Center) {
                            Symbol(Glyph.PersonFilled, 15.dp, color = Theme.fontVeryQuiet)
                        }
                        Text(name, style = TvTheme.body, color = Theme.fontQuiet, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
            item(key = "verlassen") {
                FocusArea(Modifier.fillMaxWidth(), magnifier = 1f, perform = groupLeave) { focus ->
                    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(TvTheme.cornerTile))
                            .background(if (focus) TvTheme.focusArea else Color.Transparent)
                            .padding(horizontal = 13.dp, vertical = 9.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(11.dp)) {
                        Box(Modifier.width(21.dp), contentAlignment = Alignment.Center) {
                            Symbol(Glyph.SignOut, 15.dp, color = Theme.accent, strength = Strength.Semibold)
                        }
                        Text(translated("Gruppe verlassen"), style = TvTheme.button, color = Theme.accent, maxLines = 1)
                    }
                }
            }
        }
        // Two picture formats as on iPhone: whole picture and fill.
        SelectionColumn(translated("Bild"), rememberLazyListState()) {
            item(key = "b0") {
                LayersRow(translated("Original"), !mediaWork.fillFrame, if (!fillingAtStart) Modifier.focusRequester(start) else Modifier) {
                    mediaWork.imageFillingSet(false)
                }
            }
            item(key = "b1") {
                LayersRow(translated("Füllen"), mediaWork.fillFrame, if (fillingAtStart) Modifier.focusRequester(start) else Modifier) {
                    mediaWork.imageFillingSet(true)
                }
            }
        }
        SelectionColumn(translated("Schlafzeit"), rememberLazyListState()) {
            item(key = "aus") { LayersRow(translated("Aus"), mediaWork.sleepTime == 0) { mediaWork.sleepTimeSet(0) } }
            // `SleepTimes.values` in the package.
            listOf(15, 30, 45, 60, 90).forEach { m ->
                item(key = "m$m") { LayersRow(translated("%lld Min.", m), mediaWork.sleepTime == m) { mediaWork.sleepTimeSet(m) } }
            }
        }
        SelectionColumn(translated("Technikschild"), rememberLazyListState()) {
            item(key = "aus") { LayersRow(translated("Aus"), !app.settings.techBadge) { app.settings.techBadge = false } }
            item(key = "an") { LayersRow(translated("An"), app.settings.techBadge) { app.settings.techBadge = true } }
        }
        // **Quality: Direct Play or a ceiling.** A ceiling means the server may transcode, so Direct Play
        // is off. Works like the setting in the app and reloads the film at the same position.
        if (qualityShow) {
            val bitrates = remember { selectionRead(Kern.bitrateLevels()) }
            // `-1`: Direct Play. Otherwise a bitrate limit, `0` means unlimited.
            fun select(megabit: Int) {
                val before = e.alwaysDirectPlay to e.bitratesLimit
                if (megabit < 0) e.alwaysDirectPlay = true
                else { e.alwaysDirectPlay = false; e.bitratesLimit = megabit }
                if (before == (e.alwaysDirectPlay to e.bitratesLimit)) return
                app.qualityReport()
                layerClose()
                run.launch { mediaWork.qualitySwitch() }
            }
            SelectionColumn(translated("Qualität"), rememberLazyListState()) {
                item(key = "direct") { LayersRow(translated("Direct Play"), e.alwaysDirectPlay) { select(-1) } }
                bitrates.forEach { b ->
                    val value = b.value.toIntOrNull() ?: 0
                    item(key = "b$value") {
                        LayersRow(b.text, !e.alwaysDirectPlay && e.bitratesLimit == value) { select(value) }
                    }
                }
            }
        }
    }
}

/**
 * The series' episodes: the same tile row as on the series page (`TvEpisodesTile`). The title sits
 * exactly where it was in the picture (placeholder here, the player draws the title); the season
 * pill takes the place of the meta line, the tiles follow with clear spacing. **On open the row is
 * already there** (preloaded) and focus is on the running episode.
 */
@OptIn(ExperimentalFoundationApi::class, ExperimentalComposeUiApi::class)
@Composable
private fun TvEpisodesLayer(app: SwiftlyApplication, plan: PlayPlan, title: String, start: (Episode) -> Unit) {
    val seriesIdentifier = plan.seriesIdentifier ?: return
    val runningId = plan.itemId
    // Mirrors `passendeStaffel(toward:)`: the season of the running episode.
    fun matching(list: List<Season>, remembered: String?) =
        list.firstOrNull { it.id == plan.seasonIdentifier }?.id ?: list.firstOrNull { it.id == remembered }?.id ?: list.firstOrNull()?.id
    val preloaded = remember(seriesIdentifier) { app.seriesCache[seriesIdentifier] }
    var seasons by remember(seriesIdentifier) { mutableStateOf(preloaded?.seasons.orEmpty()) }
    var selected by remember(seriesIdentifier) { mutableStateOf(preloaded?.let { matching(it.seasons, it.selected) }) }
    var episodes by remember(seriesIdentifier) { mutableStateOf(selected?.let { app.episodesCache[it] }.orEmpty()) }
    val run = rememberCoroutineScope()
    val reveal = remember { Animatable(1f) }
    val strip = rememberLazyListState(episodes.indexOfFirst { it.id == runningId }.coerceAtLeast(0))
    val running = remember { FocusRequester() }
    val pill = remember { FocusRequester() }
    // **No sliding on open.** The row used to sit at the running episode on the left edge; the first
    // focus animated it to the pivot (30 %), so it slid in from the left. Until the first focus is set,
    // the row therefore jumps there without motion.
    var immediate by remember { mutableStateOf(true) }
    val focusLaid = remember { booleanArrayOf(false) }
    val pillFocus = remember { booleanArrayOf(false) }

    // **The season picker, entries built once on open**: rebuilt from the tick, the rows were replaced
    // and focus jumped.
    var choice by remember { mutableStateOf<List<Season>?>(null) }
    val selectionOutput = remember { booleanArrayOf(false) }
    fun choiceTo() { selectionOutput[0] = true; runCatching { pill.requestFocus() }; choice = null }
    BackHandler(enabled = choice != null) { choiceTo() }

    // **After a change to the watch state** (tile menu) refetch, same follow-up as in the phone's
    // episode layer (`EpisodesLayer.episodesRefresh`).
    suspend fun episodesRefresh() {
        val g = selected ?: return
        try {
            val f = episodesRead(withContext(Dispatchers.IO) { app.kern.episodes(seriesIdentifier, g).await() })
            if (selected == g) { episodes = f; app.episodesCache[g] = f }
        } catch (e: CancellationException) { throw e } catch (_: Exception) {}
    }

    LaunchedEffect(seriesIdentifier) {
        try {
            val s = seriesRead(withContext(Dispatchers.IO) { app.kern.series(seriesIdentifier).await() })
            app.seriesCache[seriesIdentifier] = s
            seasons = s.seasons
            if (selected == null || seasons.none { it.id == selected }) selected = matching(seasons, s.selected)
            val g = selected ?: return@LaunchedEffect
            if (episodes.isEmpty()) app.episodesCache[g]?.let { episodes = it }
            val f = episodesRead(withContext(Dispatchers.IO) { app.kern.episodes(seriesIdentifier, g).await() })
            // If another season has been chosen in the meantime, its episodes are used.
            if (selected == g) { episodes = f; app.episodesCache[g] = f }
        } catch (e: CancellationException) { throw e } catch (_: Exception) {}
    }

    // Focus on the running episode once the row is there, but not if it is already on the pill.
    LaunchedEffect(episodes.isNotEmpty()) {
        if (episodes.isEmpty() || focusLaid[0] || pillFocus[0]) return@LaunchedEffect
        focusLaid[0] = true
        val i = episodes.indexOfFirst { it.id == runningId }
        if (i >= 0 && strip.layoutInfo.visibleItemsInfo.none { it.index == i }) strip.scrollToItem(i)
        focusPut(running)
        // Follow with motion again only after the first focus.
        repeat(2) { withFrameNanos { } }
        immediate = false
    }
    // Without episodes the pill keeps focus, otherwise it would stay on the invisible button behind it.
    LaunchedEffect(Unit) {
        delay(300)
        if (!focusLaid[0] && !pillFocus[0]) runCatching { pill.requestFocus() }
    }

    fun seasonSelect(s: Season) {
        choiceTo()
        if (s.id == selected) return
        selected = s.id
        run.launch {
            reveal.snapTo(0f)
            val remembered = app.episodesCache[s.id]
            if (remembered != null) episodes = remembered
            try {
                val f = if (remembered != null) remembered else episodesRead(withContext(Dispatchers.IO) { app.kern.episodes(seriesIdentifier, s.id).await() })
                if (selected == s.id) { episodes = f; app.episodesCache[s.id] = f }
            } catch (e: CancellationException) { throw e } catch (_: Exception) {}
            strip.scrollToItem(episodes.indexOfFirst { it.id == runningId }.coerceAtLeast(0))
            reveal.animateTo(1f, tween(250, easing = EaseOut))
            // Fresh from the server in case the cache was old.
            if (remembered != null) try {
                val f = episodesRead(withContext(Dispatchers.IO) { app.kern.episodes(seriesIdentifier, s.id).await() })
                if (selected == s.id) { episodes = f; app.episodesCache[s.id] = f }
            } catch (e: CancellationException) { throw e } catch (_: Exception) {}
        }
    }

    Column(Modifier.fillMaxSize().padding(top = TvTheme.edgeTop)) {
        Column(Modifier.padding(horizontal = TvTheme.edgePage).zIndex(1f), verticalArrangement = Arrangement.spacedBy(TvPlayerMetric.titleSpacing)) {
            // Placeholder: the title itself is in the player and does not fade with it.
            Text(title, style = TvPlayerMetric.title, maxLines = 1, modifier = Modifier.alpha(0f))
            if (seasons.isNotEmpty()) Box {
                TvButton(seasons.firstOrNull { it.id == selected }?.name ?: translated("Staffel"), Glyph.AngleDown,
                        Modifier.focusRequester(pill), height = 30.dp, focusChanged = { pillFocus[0] = it }) {
                    if (choice != null) choiceTo() else { selectionOutput[0] = false; choice = seasons }
                }
                choice?.let { entries ->
                    val first = remember { FocusRequester() }
                    LaunchedEffect(Unit) { focusPut(first) }
                    // Under the pill, without shifting the row below.
                    Column(Modifier.layout { m, c ->
                                val p = m.measure(c.copy(minWidth = 0, minHeight = 0, maxHeight = Constraints.Infinity, maxWidth = Constraints.Infinity))
                                layout(0, 0) { p.place(0, 36.dp.roundToPx()) }
                            }
                            .width(260.dp).heightIn(max = 330.dp).clip(RoundedCornerShape(TvTheme.cornerArea)).background(Theme.area)
                            .verticalScroll(rememberScrollState()).padding(vertical = 6.dp)
                            .focusProperties { exit = { if (selectionOutput[0]) FocusRequester.Default else FocusRequester.Cancel } }
                            .focusGroup()) {
                        val start = entries.indexOfFirst { it.id == selected }.coerceAtLeast(0)
                        entries.forEachIndexed { i, s ->
                            TvRow(s.name, if (s.id == selected) Glyph.CheckmarkCircleFilled else Glyph.Ring,
                                    modifier = if (i == start) Modifier.focusRequester(first) else Modifier) { seasonSelect(s) }
                        }
                    }
                }
            }
        }
        // Clear space below the season pill, otherwise the row would stick to it.
        if (episodes.isNotEmpty()) CompositionLocalProvider(LocalBringIntoViewSpec provides if (immediate) TvRailWithoutMotion else TvRailsBringIntoView) {
            val start = episodes.indexOfFirst { it.id == runningId }.coerceAtLeast(0)
            LazyRow(Modifier.padding(top = 22.dp).graphicsLayer { alpha = reveal.value }, state = strip,
                    contentPadding = PaddingValues(horizontal = TvTheme.edgePage, vertical = TvTheme.railsPadding),
                    horizontalArrangement = Arrangement.spacedBy(TvTheme.tileSpacing)) {
                itemsIndexed(episodes, key = { _, f -> f.id }) { i, f ->
                    // Long OK or the menu key: the tile menu, in the player only with the watch state
                    // (`TileMenuRequest.inPlayer`); the tile itself already starts the episode.
                    val menu = de.paulherter.swiftly.LocalTileMenu.current
                    val lengthy: (() -> Unit)? = menu?.let { m -> {
                        m(de.paulherter.swiftly.TileMenuRequest(f.id, f.name.ifEmpty { f.title }, "Episode",
                            f.image, true, f.subline, inPlayer = true,
                            afterwards = { run.launch { episodesRefresh() } }))
                    } }
                    TvEpisodesTile(f, if (i == start) Modifier.focusRequester(running) else Modifier, lengthy = lengthy) { start(f) }
                }
            }
        }
    }
}

/** Like `TvRailsBringIntoView`, but without motion, for the first focus on open. */
@OptIn(ExperimentalFoundationApi::class)
@Suppress("DEPRECATION")
private object TvRailWithoutMotion : BringIntoViewSpec {
    override val scrollAnimationSpec: AnimationSpec<Float> = snap()
    override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float): Float =
        TvRailsBringIntoView.calculateScrollDistance(offset, size, containerSize)
}
