package de.paulherter.swiftly.tv

import de.paulherter.swiftly.rustcore.host.CoreWords
import de.paulherter.swiftly.rustcore.PlayerStartVeil
import de.paulherter.swiftly.rustcore.playerStartFailure
import de.paulherter.swiftly.rustcore.SubtitleSearchIntent
import de.paulherter.swiftly.rustcore.SubtitleSearchPhase
import de.paulherter.swiftly.rustcore.SubtitleSearchVm
import de.paulherter.swiftly.rustcore.subtitleSearchOffered
import de.paulherter.swiftly.rememberSubtitleSearch
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
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.animation.shrinkHorizontally
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.BorderStroke
import coil3.compose.AsyncImage
import androidx.compose.foundation.background
import androidx.compose.foundation.basicMarquee
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
import de.paulherter.swiftly.shared.smoothRoundedShape
import de.paulherter.swiftly.shared.translated
import de.paulherter.swiftly.KernRules
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
    val area = remember { arrayOfNulls<android.widget.FrameLayout>(1) }
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
            if (event == androidx.lifecycle.Lifecycle.Event.ON_START && !mediaWork.player.isAttached()) {
                area[0]?.let { mediaWork.player.attach(it) }
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
            if (mediaWork.playerFree) activity?.let { TvImageTick.adapt(it, mediaWork.player, frameRateAllowed) }
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
    // The core's menus (box in the capsule's place, and the season box under the "Staffel N" pill of the Folgen panel).
    val menuSession = remember { de.paulherter.swiftly.PlayerMenuSession() }
    // The season list is a second box that hangs from the Folgen panel; it has its own session, so opening it does not swap the Folgen box out.
    val seasonSession = remember { de.paulherter.swiftly.PlayerMenuSession() }
    var seasonList by remember { mutableStateOf<List<Season>>(emptyList()) }
    var seasonShown by remember { mutableStateOf<String?>(null) }
    var seasonChosen by remember { mutableStateOf<String?>(null) }
    // **Folgen is a box of the menu session** (like Einstellungen), not a layer of its own; only the subtitle search is still a layer.
    val folgenShown = menuSession.isOpen && menuSession.kind == de.paulherter.swiftly.MenuKind.Folgen
    val layerOpen = openLayer != null || folgenShown

    LaunchedEffect(visible) { mediaWork.controlsChanged(visible) }
    LaunchedEffect(visible, mediaWork.running, openLayer, touched, menuSession.kind) {
        if (visible && mediaWork.running && openLayer == null && menuSession.kind == null) { delay(4000); visible = false }
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
            if (should != mediaWork.running) app.rk.syncPlayPleaseToggle(mediaWork.running)
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

    // **Holding left/right** (mirrors tvOS `holdBegins`): the key repeat starts after about half a second;
    // from then on the film pauses and the marker runs, 10, then 30, then 90 s per second (a step faster
    // every two seconds). Releasing jumps there and plays on. Before, every repeat added a full step
    // (a constant, far too fast run of 200 s per second and more).
    val holding = remember { booleanArrayOf(false) }
    val holdRan = remember { booleanArrayOf(false) }
    val holdTimes = remember { longArrayOf(0L, 0L) }
    fun holdStep(direction: Int) {
        if (mediaWork.duration <= 0) return
        val now = SystemClock.elapsedRealtime()
        if (!holding[0]) {
            val base = seekTarget ?: mediaWork.position
            holding[0] = true
            holdTimes[0] = now; holdTimes[1] = now
            collector?.cancel()
            holdRan[0] = !mediaWork.inGroup && wanted[0]
            if (holdRan[0]) runSet(false, "Halten")
            seekTarget = base
            AppLog.writeOut("[Spulen] Halten ${if (direction < 0) "links" else "rechts"}")
        }
        val held = (now - holdTimes[0]) / 1000.0
        val pace = if (held < 2) 10.0 else if (held < 4) 30.0 else 90.0
        val next = (seekTarget ?: mediaWork.position) + direction * pace * (now - holdTimes[1]) / 1000.0
        holdTimes[1] = now
        seekTarget = next.coerceIn(0.0, mediaWork.duration)
        showItem()
    }
    fun holdEnd(jump: Boolean) {
        if (!holding[0]) return
        holding[0] = false
        val target = seekTarget
        markDiscard()
        if (jump && target != null) mediaWork.vault(target)
        if (holdRan[0]) { holdRan[0] = false; wanted[0] = true; lastCommanded[0] = SystemClock.elapsedRealtime(); if (jump) mediaWork.playOn() else mediaWork.resume() }
        showItem()
    }

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
    // **The first stop of the capsule is Folgen** (when the series or chapters have it), else Untertitel.
    val barFirst = if (hasEpisodes || mediaWork.chapterCount > 0) buttonEpisodes else buttonTracks
    val title = plan?.headerLine?.takeIf { it.isNotEmpty() } ?: plan?.title.orEmpty()
    val meta = plan?.let {
        if (it.episode && it.seasonNr != null && it.episodeNr != null) "S${it.seasonNr} · F${it.episodeNr} · ${it.subtitle}" // 1.1: "S1 · F3 · Name", not in the catalog on tvOS either
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
    val titleTarget = controlsTarget || folgenShown
    val titleCoverage by animateFloatAsState(if (titleTarget) 1f else 0f, tween(200), label = "titel")

    fun toTop() {
        val alreadyPresent = coverage > 0.01f
        showItem()
        if (alreadyPresent) runCatching { barFirst.requestFocus() } else topRequest[0] = true
    }

    fun unfoldLayer(which: String) {
        AppLog.writeOut("[Ebene] auf $which")
        layersOutput[0] = false
        seasonChosen = null
        openLayer = which
        touched++
    }
    // **Back to the button that opened the layer**: focus first, then the layer goes.
    fun layerClose() {
        val was = openLayer ?: return
        AppLog.writeOut("[Ebene] zu $was")
        layersOutput[0] = true
        seasonChosen = null
        val target = when (was) { "suche" -> buttonTracks; else -> buttonSettings }
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
    val cardPresent = mediaWork.overlay != CoreWords.Einblendung.NOTHING && mediaWork.imageFree && !controlsTarget && !layerOpen && !mediaWork.switches
    // **The next-episode card** (`TVEpisodesCard`): the overlay's countdown case, or while it zooms.
    // With controls open it waits (`OfferingLayer.cardWaitsControls`).
    val episodesCardPresent = mediaWork.cardsSwitch != null || (cardPresent && mediaWork.overlay == CoreWords.Einblendung.CARD)
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
    val offeringPresent = mediaWork.offeringArt != CoreWords.Angebot.NOBODY && mediaWork.offerText.isNotEmpty() && mediaWork.imageFree && !layerOpen
        && !mediaWork.switches && seekTarget == null
        && (mediaWork.overlay != CoreWords.Einblendung.NOTHING || (controlsTarget && mediaWork.offeringArt == CoreWords.Angebot.NEXT))

    // If the pill disappears under focus (pressed, section over, seeking), focus moves to the surface,
    // otherwise it would be left on nothing.
    var pillHasFocus by remember { mutableStateOf(false) }
    LaunchedEffect(offeringPresent) { if (!offeringPresent && pillHasFocus) runCatching { remoteHandset.requestFocus() } }

    // **Back**: same order as `onExitCommand` on tvOS. The season picker in the episode layer attaches
    // later and therefore goes first.
    BackHandler {
        when {
            // The season list hangs under the Folgen box and answers first, then the box: one level back, then closed (focus returns to its button).
            seasonSession.isOpen -> seasonSession.backOrClose()
            menuSession.isOpen -> menuSession.backOrClose()
            // The layer lies on top, so it answers first; a stale marker must not swallow the press.
            openLayer != null -> { if (seekTarget != null) markDiscard(); layerClose() }
            // One press clears marker and bar together, otherwise Back seems dead until the bar times out.
            seekTarget != null -> {
                holdEnd(jump = false)
                markDiscard()
                runCatching { remoteHandset.requestFocus() }
                visible = false
                AppLog.writeOut("[Zurück] Marke verworfen, Steuerung aus")
            }
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
            Key.DirectionLeft -> if (e.nativeKeyEvent.repeatCount > 0) holdStep(-1) else scrub(-mediaWork.backS)
            Key.DirectionRight -> if (e.nativeKeyEvent.repeatCount > 0) holdStep(1) else scrub(mediaWork.preS)
            Key.MediaRewind -> scrub(-mediaWork.backS)
            Key.MediaFastForward -> scrub(mediaWork.preS)
            Key.MediaNext -> if (mediaWork.hasNext) run.launch { mediaWork.nextEpisode() }
            // **Up goes straight to the icons**, also on the first press while the controls are still hidden.
            // If the pill sits above the bar, it comes in between.
            Key.DirectionUp -> if (visible && offeringPresent) runCatching { offeringFocus.requestFocus() } else toTop()
            Key.Menu -> if (mediaWork.imageFree && e.nativeKeyEvent.repeatCount == 0) { showItem(); menuSession.open(de.paulherter.swiftly.MenuKind.Settings) }
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
        if (holding[0] && e.type == KeyEventType.KeyUp && (k == Key.DirectionLeft || k == Key.DirectionRight)) { holdEnd(jump = true); return true }
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
        AndroidView(factory = { ctx -> android.widget.FrameLayout(ctx).also { area[0] = it; mediaWork.videoArea = it; mediaWork.player.attach(it) } },
                    modifier = Modifier.fillMaxSize())

        if (!mediaWork.imageFree && mediaWork.cardsSwitch == null) {
            Box(Modifier.fillMaxSize().background(Color.Black), contentAlignment = Alignment.Center) {
                if (mediaWork.startVeil == PlayerStartVeil.FAILED) {
                    // **The start failed** (error or the core's start timeout): "Das startet nicht", focus on "Erneut versuchen"
                    // (`startFailedVeil` on tvOS). Back closes as everywhere.
                    val failure = remember { playerStartFailure() }
                    val retryFocus = remember { FocusRequester() }
                    LaunchedEffect(Unit) { delay(80); runCatching { retryFocus.requestFocus() } }
                    TvEmpty(translated(failure.header), translated(failure.text), symbol = Glyph.Warning,
                            button = translated(failure.primary) to { mediaWork.startAgain() },
                            buttonModifier = Modifier.focusRequester(retryFocus),
                            quietButton = translated(failure.quiet) to { mediaWork.finish(close) }, top = 0.dp)
                } else if (mediaWork.hint == null) TvLoader(size = 64.dp)
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
        if (cardScrim > 0.01f && !itemWitnessPresent) Box(Modifier.fillMaxSize().graphicsLayer { alpha = cardScrim }.background(PlayerScrim))
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
            // The design's one gradient over the whole picture (mirrors `scrim`): .65 black at the top, clear from
            // 32 % to 62 %, .8 black at the bottom.
            Box(Modifier.fillMaxSize().graphicsLayer { alpha = coverage }.background(PlayerScrim))
            Box(Modifier.fillMaxSize().graphicsLayer { alpha = coverage }
                    .padding(start = TvTheme.edgePage, end = TvTheme.edgePage, top = TvTheme.edgeTop, bottom = TvPlayerMetric.bottom)) {
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
                        TvBarCapsule(hasEpisodes || mediaWork.chapterCount > 0, folgenShown, menuSession, buttonEpisodes, buttonTracks, buttonSettings,
                            folgen = { menuSession.open(de.paulherter.swiftly.MenuKind.Folgen) },
                            modifier = Modifier.alpha(if (menuSession.isOpen) 0f else 1f))
                        LaunchedEffect(Unit) {
                            if (topRequest[0]) {
                                topRequest[0] = false
                                repeat(5) { if (runCatching { barFirst.requestFocus() }.isSuccess) return@LaunchedEffect; delay(TvTheme.focusDeadline) }
                            }
                        }
                    }
                }
                Box(Modifier.align(Alignment.BottomStart).fillMaxWidth()
                        .semantics(mergeDescendants = true) {
                            contentDescription = translated("Abspielstelle")
                            // With chapter: "12:00 / 45:00, chapter name"; the name comes from the server, untranslated.
                            stateDescription = timeText(mediaWork.position) + " / " + timeText(mediaWork.duration) +
                                (if (mediaWork.chapterCount > 0) app.rk.chapterName(mediaWork.position).let { if (it.isEmpty()) "" else ", $it" } else "")
                        }) {
                    TvTimeBar(app, { mediaWork.position }, mediaWork.duration, seekTarget, mediaWork.running, asEnd, mediaWork.chapterCount) { mediaWork.trickplayImage(it) }
                }
            }
        }

        // **The offer button**, right above the bar, in the same place with and without controls.
        // Not while the card is there.
        AnimatedVisibility(visible = offeringPresent && mediaWork.overlay != CoreWords.Einblendung.CARD && mediaWork.cardsSwitch == null, modifier = Modifier.align(Alignment.BottomEnd),
            enter = fadeIn(tween(180, easing = Motion.soft)),
            exit = fadeOut(tween(340, easing = Motion.soft))) {
            Box(Modifier.padding(end = TvTheme.edgePage, bottom = TvPlayerMetric.bottom + TvPlayerMetric.bar + TvPlayerMetric.overBar)
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
                            Key.DirectionUp -> runCatching { barFirst.requestFocus() }
                            Key.DirectionDown -> runCatching { remoteHandset.requestFocus() }
                            else -> {}
                        }
                        true
                    }) {
                val skipShare = mediaWork.buttonCountdown
                TvOfferingPill(mediaWork.offerText,
                    share = skipShare,
                    seconds = skipShare?.let { kotlin.math.ceil((1 - it) * de.paulherter.swiftly.SKIP_BUTTON_SECONDS).toInt() },
                    running = mediaWork.running, length = de.paulherter.swiftly.SKIP_BUTTON_SECONDS,
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

        // **The menus**: the core builds every level; the box takes the capsule's place (the season box hangs under the pill).
        TvPlayerMenuLayer(menuSession, { de.paulherter.swiftly.playerMenus(app, mediaWork, menuSession, emptyList(), seasonList, seasonShown) },
            press = { a -> de.paulherter.swiftly.playerMenuPress(app, mediaWork, menuSession, run, close, emptyList(), { seasonChosen = it },
                { unfoldLayer("suche") }, {}, a) })
        TvPlayerMenuLayer(seasonSession, { de.paulherter.swiftly.playerMenus(app, mediaWork, seasonSession, emptyList(), seasonList, seasonShown) },
            press = { a -> de.paulherter.swiftly.playerMenuPress(app, mediaWork, seasonSession, run, close, emptyList(), { seasonChosen = it },
                { unfoldLayer("suche") }, {}, a) })
        val lastKind = remember { arrayOfNulls<de.paulherter.swiftly.MenuKind>(1) }
        LaunchedEffect(menuSession.isOpen, menuSession.kind) {
            val k = menuSession.kind
            if (menuSession.isOpen && k != null) {
                lastKind[0] = k
                if (k == de.paulherter.swiftly.MenuKind.Folgen) { layersOutput[0] = false; seasonChosen = null }
                menuSession.audioSelected = mediaWork.player.audioTrack; menuSession.subtitleSelected = mediaWork.player.spuTrack
            } else if (!menuSession.isOpen) {
                // **Closing a menu returns focus to the capsule button that opened it**, never to the timeline.
                val target = when (lastKind[0]) {
                    de.paulherter.swiftly.MenuKind.Tracks -> buttonTracks; de.paulherter.swiftly.MenuKind.Settings -> buttonSettings
                    de.paulherter.swiftly.MenuKind.Folgen -> buttonEpisodes; else -> null }
                // The Folgen box lies in a closed focus group; it lets focus out now.
                if (lastKind[0] == de.paulherter.swiftly.MenuKind.Folgen) layersOutput[0] = true
                // **Focus goes back to the capsule button twice**: once as the box closes, and again when the box has left the
                // composition (`kind` null): its focused row disappearing used to drop focus to the idle surface, so the
                // next Left + OK did nothing.
                if (k == null) lastKind[0] = null
                if (target != null) { showItem(); focusPut(target) }
            }
        }

        // **The layers**: full screen over the picture, closed focus group: focus stays inside until
        // Back closes it.
        var lastLayer by remember { mutableStateOf("folgen") }
        LaunchedEffect(openLayer, folgenShown) { if (openLayer != null) lastLayer = openLayer!! else if (folgenShown) lastLayer = "folgen" }
        // The Folgen box opens and closes with the motion of the other menu boxes; the search layer keeps its plain fade.
        AnimatedVisibility(visible = layerOpen,
                enter = fadeIn(tween(200)) + scaleIn(initialScale = 0.96f, transformOrigin = TransformOrigin(1f, 0f), animationSpec = menuOpenSpring),
                exit = fadeOut(tween(140, easing = menuCloseCurve)) + scaleOut(targetScale = 0.96f, transformOrigin = TransformOrigin(1f, 0f), animationSpec = tween(140, easing = menuCloseCurve))) {
            @OptIn(ExperimentalComposeUiApi::class)
            Box(Modifier.fillMaxSize()
                    // **Open for a panel above** (tile menu of an episode): otherwise `Cancel` would lock its
                    // `requestFocus` too, it would show without focus, and OK would go to the tile below.
                    // **Open for the season box too** (it is drawn outside this group): `Cancel` made its first-row `requestFocus`
                    // fail, so the box showed but focus stayed on the Staffel button and DOWN went to the Folge 1 card.
                    .focusProperties { exit = { if (layersOutput[0] || app.sheet.value != null || seasonSession.isOpen) FocusRequester.Default else FocusRequester.Cancel } }
                    .focusGroup()) {
                // **No blur:** VLC draws into a `SurfaceView`, which the system composites separately, so a
                // `RenderEffect` does not reach it (same as on the phone, `Ebenengrund` in PlayerPage.kt).
                // Substitute: pure black, 80 %.
                if (!folgenShown || openLayer != null) Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.8f)))
                when (openLayer ?: if (folgenShown) "folgen" else lastLayer) {
                    "suche" -> TvSearchLayer(mediaWork) { layerClose() }
                    "folgen" -> plan?.takeIf { hasEpisodes || mediaWork.chapterCount > 0 }?.let { p ->
                        val chapterList = remember(mediaWork.chapterCount) { de.paulherter.swiftly.chapterListRead(app.rk.chapterList(mediaWork.position)) }
                        TvEpisodesLayer(app, p, hasEpisodes, title, seasonSession, seasonChosen, { l, sel -> seasonList = l; seasonShown = sel },
                                chapterList, { mediaWork.trickplayImage(it) }, { at -> menuSession.close(); mediaWork.vault(at) }) { f ->
                            menuSession.close()
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
                Spacer(Modifier.width(24.dp + 56.dp * (if (hasEpisodes || mediaWork.chapterCount > 0) 3 else 2) + 8.dp))
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
    val title = TvTheme.titleLarge
    val meta = TvTheme.small
    val time = 13.sp
    val previewTime = 15.sp
    val barReason = Color.White.copy(alpha = 0.25f)
    val titleSpacing = 5.dp
    val button = 44.dp
    val buttonSpacing = 4.dp
    val overBar = 14.dp
    val bar = 16.dp
    /** Bottom edge of the player: 90 pt. */
    val bottom = 45.dp
    val column = 250.dp
    val columnSpacing = 57.dp
    /** For when the columns would not otherwise fit (settings with quality or group). */
    val columnsSpacingNarrow = 20.dp
    val columnsTop = 106.dp
    /** Layers column (tvOS 1.1): heading 36/700 (18 sp), gap 16 pt, rows 72 pt, delay block 28 pt below the last row. */
    val heading = 18.sp
    val headingGap = 8.dp
    val rowHeight = 36.dp
    val delayTop = 14.dp
    /** Row inset 20 pt, so heading, row and delay share one text edge; 40 pt bleed keeps the lifted focus row unclipped. */
    val inset = 10.dp
    val bleed = 20.dp
    fun iconRail(count: Int) = button * count + buttonSpacing * (count - 1)
}

/** Loading ring for the TV picture: larger than on the phone, read from three meters. */
@Composable
private fun TvLoader(size: androidx.compose.ui.unit.Dp) {
    de.paulherter.swiftly.Spinner(size, Theme.font)
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
    val form = smoothRoundedShape(TvTheme.corner)
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
        horizontalArrangement = Arrangement.spacedBy(12.dp)) {
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
                chapterBarRead(app.rk.chapterBar(duration, width.value.toDouble(), ChapterMass.minWidth, ChapterMass.gap))
            }
            val elevated = if (seeks) app.rk.chapterPiece(target.toDouble(), duration, width.value.toDouble(), ChapterMass.minWidth).toInt() else -1
            val fromState = width * minOf(state, target)
            bar.pieces.forEachIndexed { i, piece ->
                key(i) {
                    val stripe by animateDpAsState(if (i == elevated) 7.dp else 5.dp, tween(180), label = "balken")
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
                            modifier = Modifier.size(200.dp, 112.5.dp).clip(smoothRoundedShape(TvTheme.corner))
                                .border(1.dp, Color.White.copy(alpha = 0.35f), smoothRoundedShape(TvTheme.corner)))
                    }
                    // **With a chapter its name precedes the time**, on one line and at most as wide as the thumbnail;
                    // a long name is truncated, never the time.
                    val name = if (chapterCount > 0) app.rk.chapterName(shown) else ""
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
            // Left-aligned from the page margin (tvOS 1.1), no longer centred.
            Row(Modifier.fillMaxSize(), horizontalArrangement = Arrangement.spacedBy(spacing, Alignment.Start), content = content)
        }
    }
}

/** Fixed heading, only the rows below scroll; by focus, each column on its own. */
@Composable
private fun SelectionColumn(title: String, list: LazyListState, content: LazyListScope.() -> Unit) {
    Column(Modifier.width(LocalColumnsWidth.current).fillMaxHeight()) {
        // 36 / 700 / -0.6 pt (18 sp, -0.3 sp) in a 1.15 line box, 16 pt above the rows.
        Text(title, style = TvTheme.subpageTitle.copy(fontSize = TvPlayerMetric.heading, fontWeight = FontWeight.Bold,
                                                       letterSpacing = (-0.3).sp),
             color = Theme.font, maxLines = 1,
             modifier = Modifier.height(TvPlayerMetric.heading.value.dp * 1.15f).semantics { heading() })
        Spacer(Modifier.height(TvPlayerMetric.headingGap))
        // The list is widened by the bleed on both sides and its content pushed back in.
        val bleed = with(LocalDensity.current) { TvPlayerMetric.bleed.roundToPx() }
        LazyColumn(Modifier.weight(1f).focusGroup().layout { measurable, c ->
                       val w = c.maxWidth + 2 * bleed
                       val p = measurable.measure(c.copy(minWidth = w, maxWidth = w))
                       layout(c.maxWidth, p.height) { p.place(-bleed, 0) }
                   }, state = list, verticalArrangement = Arrangement.spacedBy(0.dp),
                   contentPadding = PaddingValues(start = TvPlayerMetric.bleed, end = TvPlayerMetric.bleed,
                                                  bottom = TvTheme.edgeTop + 30.dp), content = content)
    }
}

/**
 * Checkmark and name (`LayersRowStyle`). Focus is a white row with dark semibold text, wide magnifier and
 * lift; otherwise selected is white semibold, the rest quiet medium. Row 72 pt, check 30 in a 32 slot, gap 20.
 */
@Composable
private fun LayersRow(text: String, selected: Boolean, modifier: Modifier = Modifier, perform: () -> Unit) {
    FocusArea(modifier.fillMaxWidth().semantics { this.selected = selected }, magnifier = TvTheme.focusMagnifierWide,
              lift = true, liftCorner = TvTheme.corner, perform = perform) { focus ->
        Row(Modifier.fillMaxWidth().height(TvPlayerMetric.rowHeight)
                .background(if (focus) Color.White else Color.Transparent, smoothRoundedShape(TvTheme.corner))
                .padding(horizontal = TvPlayerMetric.inset),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            val color = if (focus) Theme.reason else if (selected) Theme.font else Theme.fontQuiet
            Box(Modifier.width(16.dp), contentAlignment = Alignment.Center) {
                if (selected) Symbol(Glyph.Checkmark, 15.dp, color = color, strength = Strength.Semibold)
            }
            // Track names come from the file, verbatim.
            // A name that does not fit runs through while focused (tvOS `Marquee`), otherwise it truncates.
            @OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
            Text(text, style = TvTheme.body.copy(fontWeight = if (selected || focus) FontWeight.SemiBold else FontWeight.Medium),
                 color = color, maxLines = 1, softWrap = false,
                 overflow = if (focus && !motionReduced()) TextOverflow.Clip else TextOverflow.Ellipsis,
                 modifier = if (focus && !motionReduced()) Modifier.basicMarquee(iterations = Int.MAX_VALUE, initialDelayMillis = 1200, repeatDelayMillis = 1500, velocity = 55.dp) else Modifier)
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
private fun TvEpisodesLayer(app: SwiftlyApplication, plan: PlayPlan, hasEpisodes: Boolean, title: String, session: de.paulherter.swiftly.PlayerMenuSession, chosen: String?,
                            onSeasons: (List<Season>, String?) -> Unit, chapters: de.paulherter.swiftly.ChapterList, preview: (Double) -> android.graphics.Bitmap?,
                            jump: (Double) -> Unit, start: (Episode) -> Unit) {
    // Series: Folgen (+ Kapitel when the file has chapters); film: Kapitel only (the core's `PanelTab` rule).
    val seriesIdentifier = plan.seriesIdentifier.takeIf { hasEpisodes }.orEmpty()
    var tab by remember { mutableStateOf(if (hasEpisodes) de.paulherter.swiftly.FolgenTab.Episodes else de.paulherter.swiftly.FolgenTab.Chapters) }
    val chapterFocus = remember { FocusRequester() }
    val chapterTab = remember { FocusRequester() }
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
    val focusLaid = remember { booleanArrayOf(false) }
    val pillFocus = remember { booleanArrayOf(false) }

    // **The season picker, entries built once on open**: rebuilt from the tick, the rows were replaced
    // and focus jumped.
    // The season box is the core's menu (`PlayerMenuLevel.Seasons`); this layer tells the player which seasons exist.
    val seasonMenuWas = remember { booleanArrayOf(false) }

    // **After a change to the watch state** (tile menu) refetch, same follow-up as in the phone's
    // episode layer (`EpisodesLayer.episodesRefresh`).
    suspend fun episodesRefresh() {
        val g = selected ?: return
        try {
            val f = episodesRead(withContext(Dispatchers.IO) { app.rk.episodes(seriesIdentifier, g).await() })
            if (selected == g) { episodes = f; app.episodesCache[g] = f }
        } catch (e: CancellationException) { throw e } catch (_: Exception) {}
    }

    LaunchedEffect(seriesIdentifier) {
        if (!hasEpisodes) return@LaunchedEffect
        try {
            val s = seriesRead(withContext(Dispatchers.IO) { app.rk.series(seriesIdentifier).await() })
            app.seriesCache[seriesIdentifier] = s
            seasons = s.seasons
            if (selected == null || seasons.none { it.id == selected }) selected = matching(seasons, s.selected)
            val g = selected ?: return@LaunchedEffect
            if (episodes.isEmpty()) app.episodesCache[g]?.let { episodes = it }
            val f = episodesRead(withContext(Dispatchers.IO) { app.rk.episodes(seriesIdentifier, g).await() })
            // If another season has been chosen in the meantime, its episodes are used.
            if (selected == g) { episodes = f; app.episodesCache[g] = f }
        } catch (e: CancellationException) { throw e } catch (_: Exception) {}
    }

    // Focus on the running episode once the row is there, but not if it is already on the pill.
    LaunchedEffect(episodes.isNotEmpty(), tab) {
        if (tab != de.paulherter.swiftly.FolgenTab.Episodes || episodes.isEmpty() || focusLaid[0] || pillFocus[0]) return@LaunchedEffect
        focusLaid[0] = true
        val i = episodes.indexOfFirst { it.id == runningId }
        if (i >= 0 && strip.layoutInfo.visibleItemsInfo.none { it.index == i }) strip.scrollToItem(i)
        focusPut(running)
    }
    // Without episodes the pill keeps focus, otherwise it would stay on the invisible button behind it.
    LaunchedEffect(Unit) {
        delay(300)
        if (tab == de.paulherter.swiftly.FolgenTab.Episodes && !focusLaid[0] && !pillFocus[0]) runCatching { pill.requestFocus() }
    }
    // Chapters: focus on the running chapter's tile once the tab shows (also for a film, where it is the only tab).
    LaunchedEffect(tab) { if (tab == de.paulherter.swiftly.FolgenTab.Chapters) { delay(120); focusPut(chapterFocus) } }

    fun seasonSelect(s: Season) {
        if (s.id == selected) return
        selected = s.id
        run.launch {
            reveal.snapTo(0f)
            val remembered = app.episodesCache[s.id]
            if (remembered != null) episodes = remembered
            try {
                val f = if (remembered != null) remembered else episodesRead(withContext(Dispatchers.IO) { app.rk.episodes(seriesIdentifier, s.id).await() })
                if (selected == s.id) { episodes = f; app.episodesCache[s.id] = f }
            } catch (e: CancellationException) { throw e } catch (_: Exception) {}
            strip.scrollToItem(episodes.indexOfFirst { it.id == runningId }.coerceAtLeast(0))
            reveal.animateTo(1f, tween(250, easing = EaseOut))
            // Fresh from the server in case the cache was old.
            if (remembered != null) try {
                val f = episodesRead(withContext(Dispatchers.IO) { app.rk.episodes(seriesIdentifier, s.id).await() })
                if (selected == s.id) { episodes = f; app.episodesCache[s.id] = f }
            } catch (e: CancellationException) { throw e } catch (_: Exception) {}
        }
    }

    LaunchedEffect(seasons, selected) { onSeasons(seasons, selected) }
    LaunchedEffect(chosen) { chosen?.let { id -> seasons.firstOrNull { it.id == id }?.let { seasonSelect(it) } } }
    LaunchedEffect(session.isOpen, session.kind) {
        if (session.isOpen && session.kind == de.paulherter.swiftly.MenuKind.Seasons) seasonMenuWas[0] = true
        // **Back to the button once the box has left the composition** (`kind` null): while its focused row is still there,
        // its own `Cancel` exit refuses the request, and the first 180 ms of retries ran out before the 140 ms close motion ended.
        else if (!session.isOpen && session.kind == null && seasonMenuWas[0]) { seasonMenuWas[0] = false; focusPut(pill) }
    }

    // **The Folgen box** (tvOS `TVFolgenBox`): the dark menu box top right, as wide as the other player boxes' family but wider for
    // the stills; its first row is the season button, then the vertical list. The season list is a second box (`TvPlayerMenuLayer`).
    Box(Modifier.fillMaxSize()) {
        Column(Modifier.align(Alignment.TopEnd).padding(top = TvTheme.edgeTop - 6.dp, end = TvTheme.edgePage).width(TvFolgenMetric.width)
                .clip(smoothRoundedShape(TvFolgenMetric.radius)).background(Theme.raised)
                .border(BorderStroke(1.dp, TvTheme.edge), smoothRoundedShape(TvFolgenMetric.radius))
                .padding(TvFolgenMetric.boxPad)) {
            if (!hasEpisodes) Text(translated("Kapitel"), style = Theme.listTitle.copy(fontSize = 15.sp, fontWeight = FontWeight.SemiBold), color = Theme.font,
                    modifier = Modifier.height(TvFolgenMetric.row).wrapContentHeight(Alignment.CenterVertically).padding(horizontal = 12.dp))
            else Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                if (tab == de.paulherter.swiftly.FolgenTab.Episodes) {
                    if (seasons.isNotEmpty()) FolgenTabButton(seasons.firstOrNull { it.id == selected }?.name ?: translated("Staffel"), true, true,
                            Modifier.focusRequester(pill), focusChanged = { pillFocus[0] = it }) {
                        AppLog.writeOut("[Ebene] Staffel-Knopf")
                        session.open(de.paulherter.swiftly.MenuKind.Seasons)
                    }
                    else FolgenTabButton(translated("Folgen"), true, false, Modifier.focusRequester(pill), focusChanged = { pillFocus[0] = it }) {}
                } else FolgenTabButton(translated("Folgen"), false, false, Modifier.focusRequester(pill), focusChanged = { pillFocus[0] = it }) {
                    tab = de.paulherter.swiftly.FolgenTab.Episodes
                }
                if (chapters.rows.isNotEmpty()) FolgenTabButton(translated("Kapitel"), tab == de.paulherter.swiftly.FolgenTab.Chapters, false,
                        Modifier.focusRequester(chapterTab)) { tab = de.paulherter.swiftly.FolgenTab.Chapters }
            }
            if (tab == de.paulherter.swiftly.FolgenTab.Chapters) {
                val now = chapters.rows.indexOfFirst { it.current }.coerceAtLeast(0)
                LazyColumn(Modifier.heightIn(max = TvFolgenMetric.listMax), state = rememberLazyListState(now)) {
                    itemsIndexed(chapters.rows, key = { _, c -> c.index }) { i, c ->
                        val bitmap = preview(c.start)
                        FolgenRow(if (i == now) Modifier.focusRequester(chapterFocus) else Modifier, { jump(c.start) }, bitmap, null,
                                  c.heading(chapters.numberTitle), if (c.current) "${translated("Läuft")} · ${c.startText}" else c.startText,
                                  false, c.current, null, null)
                    }
                }
            } else if (episodes.isNotEmpty()) {
                LazyColumn(Modifier.heightIn(max = TvFolgenMetric.listMax).graphicsLayer { alpha = reveal.value }, state = strip) {
                    itemsIndexed(episodes, key = { _, f -> f.id }) { i, f ->
                        // Long OK or the menu key: the tile menu, in the player only with the watch state
                        // (`TileMenuRequest.inPlayer`); the row itself already starts the episode.
                        val menu = de.paulherter.swiftly.LocalTileMenu.current
                        val lengthy: (() -> Unit)? = menu?.let { m -> {
                            m(de.paulherter.swiftly.TileMenuRequest(f.id, f.name.ifEmpty { f.title }, "Episode",
                                f.image, true, f.subline, inPlayer = true,
                                afterwards = { run.launch { episodesRefresh() } }))
                        } }
                        val title = f.number?.let { "${translated("F%d", it)} · ${f.name}" } ?: f.name
                        val subline = buildList {
                            f.runtimeMin?.let { add(translated("%lld Min", it)) }
                            f.remainingTime?.let { add(it) }
                        }.joinToString(" · ").ifEmpty { null }
                        FolgenRow(if (f.id == runningId) Modifier.focusRequester(running) else Modifier, { start(f) }, null, f.image,
                                  title, subline, f.watched, f.id == runningId, if (f.watched) null else f.progress, lengthy)
                    }
                }
            }
        }
    }
}

/** Sizes of the Folgen box (tvOS `TVFolgenMetric`, 860 pt halved); the season box hangs from it (`TvPlayerMenuLayer`). */
internal object TvFolgenMetric {
    val width = 430.dp
    val listMax = 300.dp
    val row = 36.dp
    val boxPad = 6.dp
    /** Same as the menu box (`TvMenuMetric`): card corner, rows and tabs `radius.small` (concentric with the 6 dp pad), the still a tile at 8 % of its width = `radius.small`. */
    val radius = TvTheme.cornerArea
    val rowRadius = TvTheme.cornerSmall
    val stillRadius = TvTheme.cornerSmall
    val still = androidx.compose.ui.unit.DpSize(88.dp, 50.dp)
}

/** A tab of the Folgen box's header: white with dark text on focus, the open one carries a line under its label. */
@Composable
private fun FolgenTabButton(text: String, on: Boolean, chevron: Boolean, modifier: Modifier = Modifier, focusChanged: (Boolean) -> Unit = {}, perform: () -> Unit) {
    FocusArea(modifier.semantics { selected = on }, magnifier = 1f, focusChanged = focusChanged, perform = perform) { lit ->
        val ink = if (lit) Theme.reason else if (on) Theme.font else Theme.fontVeryQuiet
        Column(Modifier.clip(smoothRoundedShape(TvFolgenMetric.rowRadius)).background(if (lit) Color.White else Color.Transparent).padding(horizontal = 12.dp, vertical = 4.dp)) {
            Row(Modifier.height(26.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                Text(text, style = Theme.listTitle.copy(fontSize = 15.sp, fontWeight = FontWeight.SemiBold), color = ink, maxLines = 1)
                if (chevron) Symbol(Glyph.AngleDown, 10.dp, color = ink, strength = Strength.Semibold)
            }
            Box(Modifier.height(2.dp).fillMaxWidth().background(if (on) ink else Color.Transparent, CircleShape))
        }
    }
}

/** One row of the Folgen box: still (episode picture or chapter frame), "F2 · Title", runtime and progress; focus white with dark text. */
@Composable
private fun FolgenRow(modifier: Modifier, perform: () -> Unit, bitmap: android.graphics.Bitmap?, image: String?, title: String, subline: String?,
                      watched: Boolean, now: Boolean, progress: Double?, lengthy: (() -> Unit)?) {
    FocusArea(modifier.fillMaxWidth().semantics(mergeDescendants = true) { selected = now; contentDescription = title }, magnifier = 1f, lengthy = lengthy, perform = perform) { lit ->
        Row(Modifier.fillMaxWidth().clip(smoothRoundedShape(TvFolgenMetric.rowRadius)).background(if (lit) Color.White else Color.Transparent).padding(horizontal = 6.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(Modifier.size(TvFolgenMetric.still.width, TvFolgenMetric.still.height).clip(smoothRoundedShape(TvFolgenMetric.stillRadius)).background(Theme.area)) {
                if (bitmap != null) Image(bitmap.asImageBitmap(), null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
                else AsyncImage(model = image, contentDescription = null, contentScale = ContentScale.Crop,
                                colorFilter = if (watched) de.paulherter.swiftly.WATCHED_DIM else null, modifier = Modifier.fillMaxSize())
                progress?.takeIf { it > 0 && it < 1 }?.let { a ->
                    Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(3.dp).background(Color.White.copy(alpha = 0.22f))) {
                        Box(Modifier.fillMaxWidth(a.toFloat().coerceIn(0f, 1f)).fillMaxHeight().background(Theme.accent))
                    }
                }
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(title, style = Theme.listTitle.copy(fontSize = 14.sp, fontWeight = FontWeight.SemiBold), color = if (lit) Theme.reason else if (watched) Theme.fontQuiet else Theme.font,
                     maxLines = 2, overflow = TextOverflow.Ellipsis)
                if (!subline.isNullOrEmpty()) Text(subline, style = Theme.listTitle.copy(fontSize = 12.sp, fontWeight = FontWeight.Normal),
                     color = if (lit) Theme.reason.copy(alpha = 0.7f) else if (now) Theme.accent else Theme.fontVeryQuiet, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

/** `scrim` on tvOS 1.1: one gradient, .65 > 0 at .32 > 0 at .62 > .8. */
private val PlayerScrim = androidx.compose.ui.graphics.Brush.verticalGradient(
    0.00f to Color.Black.copy(alpha = 0.65f), 0.32f to Color.Transparent, 0.62f to Color.Transparent, 1.00f to Color.Black.copy(alpha = 0.8f))

/** The core's subtitle search in place of the layer (opened by the menu's "Untertitel suchen …"). */
@Composable
private fun TvSearchLayer(mediaWork: PlayItem, close: () -> Unit) {
    val vm = remember { mediaWork.subtitleSearchVm() } ?: return
    TvSubtitleSearch(vm) { index -> mediaWork.subtitleAdded(index); close() }
}

/** The core's `SubtitleSearchPart` drawn as it is, in the focusable rows of the TV layers. */
@Composable
private fun TvSubtitleSearch(vm: SubtitleSearchVm, added: (Long?) -> Unit) {
    val part = rememberSubtitleSearch(vm, added)
    val first = remember { FocusRequester() }
    val list = rememberLazyListState()
    LaunchedEffect(Unit) { focusPut(first) }
    ColumnsRail(1) {
        SelectionColumn(part.title, list) {
            itemsIndexed(part.languages, key = { _, l -> "l${l.value}" }) { i, l ->
                LayersRow(l.label, l.selected, if (i == 0) Modifier.focusRequester(first) else Modifier) { vm.send(SubtitleSearchIntent.Search(l.value)) }
            }
            when (part.phase) {
                SubtitleSearchPhase.IDLE, SubtitleSearchPhase.LOADING -> {}
                SubtitleSearchPhase.RESULTS, SubtitleSearchPhase.DOWNLOADING ->
                    itemsIndexed(part.rows, key = { _, r -> "r${r.id}" }) { _, r ->
                        LayersRow(listOf(r.title, r.sourceLine).filter { it.isNotEmpty() }.joinToString(" · "), false) {
                            if (part.phase != SubtitleSearchPhase.DOWNLOADING) vm.send(SubtitleSearchIntent.Download(r.id))
                        }
                    }
                else -> item(key = "message") {
                    Text(part.message.orEmpty(), style = TvTheme.body, color = Theme.fontQuiet,
                         modifier = Modifier.padding(horizontal = TvPlayerMetric.inset, vertical = 12.dp))
                }
            }
        }
    }
}
