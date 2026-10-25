package de.paulherter.swiftly.tv

import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Strength
import android.content.Intent
import androidx.activity.compose.BackHandler
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import coil3.SingletonImageLoader
import coil3.request.ImageRequest
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.findRootCoordinates
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.SubcomposeAsyncImage
import de.paulherter.swiftly.*
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.Wordmark
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import android.widget.Toast
import androidx.lifecycle.repeatOnLifecycle
import androidx.lifecycle.Lifecycle

/**
 * Mirrors tvOS `Region`: navigation at the top, not the bottom. A bar at the bottom edge would
 * be too far from where people look. Watchlist has its own section; there are no downloads on TV.
 */
enum class TvSection(val title: String) { Start("Start"), Movies("Filme"), Series("Serien"), Watchlist("Merkliste"), Search("Suche") }

/**
 * What the home screen already knows about a title when it is opened (tvOS passes the same
 * `Item` to `DetailView`, so its header is there in the first frame). The detail page only gets
 * the id otherwise and its header would start empty until `Kern.title`/`Kern.series` answers.
 * `details` is already cut the way the target page shows the line (movie: year · runtime,
 * series: year only), so nothing jumps when the full data arrives.
 */
data class TvPreOff(val title: String, val details: String?, val rating: Double?, val sharing: String?,
                   val description: String?, val backdrop: String?)

/** Process-wide, small: the last handover per id. Read only until the full data is there. */
object TvHandoff {
    private val preOff = HashMap<String, TvPreOff>()
    fun remember(id: String, v: TvPreOff) { preOff[id] = v }
    fun of(id: String): TvPreOff? = preOff[id]
}

/** Reporter of the page currently drawn, see `TvBackdropReport`. */
val LocalBackdropReport = compositionLocalOf<(String?) -> Unit> { {} }

/**
 * A page reports its backdrop to `TvMain`, which draws it below the page stack.
 * `ready = false`: nothing reliable yet, `TvMain` keeps what is shown.
 */
@Composable
fun TvBackdropReport(image: String?, ready: Boolean = true) {
    val report = LocalBackdropReport.current
    LaunchedEffect(image, ready, report) { if (ready) report(image) }
}

/** Subpages that do not use the shared backdrop (counterpart of `TvSubpage`). Person and
 *  Seerr title draw their own (rotating banner, foreign URLs) on an opaque background. */
private val withoutSharedBackdrop = setOf("Person", "Genre", "BoxSet", "Playlist", "Profil", "WeiteresKonto", "ServerAufnahme",
    "Wiedergabeeinstellungen", "Darstellung", "Einstellungen", "Seerr", "Seerrtitel", "Genrewahl", "Merkliste")

private fun pagesKey(b: TvSection, depth: Int, id: String?) = "${b.name}/$depth/${id.orEmpty()}"

/** How far the top bar reaches; pages start below it. */
val headerBottom = TvTheme.edgeTop + TvTheme.stripHeight + 12.dp

/**
 * Mirrors tvOS `MainView`. One stack per section; sections switch by cross-fade only (sliding
 * past each other looked like a bug). Subpages appear without a push. Back goes up one level, not
 * out of the app: first the panel, then the stack, then to Start.
 *
 * The jump from Start to a subpage has no animation, on purpose. tvOS disables the push animation
 * of its `NavigationStack` for exactly this change (`MainView.stack`); here
 * `key(b, depth, target?.id)` does the same by swapping the old page for `TvSubpage` without a
 * transition. It still looks smooth because backdrop and header facts are pixel-identical on both
 * pages (`HeaderInfo` in `TvStart.kt`, `TvDetailHeader` in `TvTitle.kt`). What is new fades in
 * in the target page itself (`inFade` in `TvDetail`/`TvSeries`), not in this router: button
 * row and rows come 300 ms after appearing, the header is there immediately.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun TvMain(app: SwiftlyApplication) {
    var section by rememberSaveable { mutableStateOf(TvSection.Start) }
    val stack = remember { mutableStateMapOf<TvSection, List<Destination>>() }
    // Account switch: under the freeze frame, stack and section jump back without animation.
    val backState = remember { de.paulherter.swiftly.AccountSwitchTransition.back }
    LaunchedEffect(de.paulherter.swiftly.AccountSwitchTransition.back) {
        if (de.paulherter.swiftly.AccountSwitchTransition.back != backState && de.paulherter.swiftly.AccountSwitchTransition.waits) {
            stack.clear(); section = TvSection.Start
        }
    }
    val stateHolder = rememberSaveableStateHolder()
    val context = LocalContext.current
    // "Zeig mir meine Startseite" after the thanks; a purchase or key changes what may be worn.
    SideEffect { app.looks.goHomeAction = { stack.clear(); section = TvSection.Start } }
    LaunchedEffect(app.support.source.value) { app.looks.syncSupporter() }
    // Switched off while open, the watchlist must not stay on screen without its tab.
    LaunchedEffect(app.settings.watchlist) {
        if (!app.settings.watchlist && section == TvSection.Watchlist) section = TvSection.Start
    }

    LaunchedEffect(Unit) {
        app.sessionCheck()
        app.seerrLoad()
        app.serverNameLoad()
        app.postConnect()
        app.kern.remoteControlStart().await()
    }
    // "Continue here": taken from the phone (`MainScreen`, `Takeover.kt`). tvOS shows the badge on
    // every root page. Every five seconds while the app is in front; `offeringsFetch()` stays
    // silent during playback.
    @Suppress("DEPRECATION")
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) { app.offeringsFetch(); delay(5000) }
        }
    }
    val play = app.play.value
    // The player cross-fades, 0.3 s, as on tvOS and on the phone (`player_enter`/`player_exit`, see
    // `PlayerActivity.kt`). `playHandOver` as in `MainScreen`: a request starts the player
    // exactly once, even if the activity is rebuilt.
    LaunchedEffect(play) {
        if (play == null || play === app.playHandOver) return@LaunchedEffect
        app.playHandOver = play
        FocusRemember.playerStarted()
        // From a handover without its own fade: the card lies on top (`Uebergabe`).
        val on = if (de.paulherter.swiftly.Handoff.arrival != null) de.paulherter.swiftly.R.anim.hold else de.paulherter.swiftly.R.anim.player_enter
        context.startActivity(Intent(context, PlayerActivity::class.java),
            android.app.ActivityOptions.makeCustomAnimation(context, on, de.paulherter.swiftly.R.anim.hold).toBundle())
    }
    // After the player, focus returns to the tile, episode or button playback was started from
    // (as on tvOS), whether the player ends via Back or on its own.
    LaunchedEffect(play == null) {
        if (play == null) { delay(TvTheme.focusDeadline); FocusRemember.playerTo() }
    }

    // Reported backdrops per page (`pagesKey`), see `TvBackdropsLayer`.
    val backdrops = remember { mutableStateMapOf<String, String?>() }
    val open: (Destination) -> Unit = { z -> stack[section] = stack[section].orEmpty() + z }
    val back: () -> Unit = {
        val alt = stack[section].orEmpty()
        alt.lastOrNull()?.let { backdrops.remove(pagesKey(section, alt.size, it.id)) }
        stack[section] = alt.dropLast(1)
    }
    val top = stack[section].orEmpty()

    // Watch Next (`TvContinueWatchingShelf`) returns here via "swiftly://titel/<id>", the same address
    // as tvOS Top Shelf, but through the intent instead of `onOpenURL`. Same rule as
    // `continueWatchingRequest` for "Continue watching" on Start (`StartPage.kt`): with a resume point,
    // play directly, otherwise open the title page. Name and type are not known here yet, hence one
    // dedicated request instead of the helper function.
    LaunchedEffect(app.deepLink.value) {
        val address = app.deepLink.value ?: return@LaunchedEffect
        app.deepLink.value = null
        if (address.scheme != "swiftly" || address.host != "titel") return@LaunchedEffect
        // Only a Jellyfin id, like `PathPart.isId` in the package: no `..%2F` into the server address.
        val id = address.lastPathSegment?.takeIf { Regex("[A-Za-z0-9-]{1,64}").matches(it) } ?: return@LaunchedEffect
        section = TvSection.Start
        runCatching { titleRead(withContext(Dispatchers.IO) { app.kern.title(id).await() }) }.getOrNull()?.let { t ->
            if (t.planPresent) app.play.value = PlayRequest(id, t.resumeFrom) else open(Destination(id, t.name, t.type))
        }
    }

    BackHandler(enabled = top.isEmpty() && section != TvSection.Start) { section = TvSection.Start }
    BackHandler(enabled = top.isNotEmpty(), onBack = back)

    // The backdrop belongs to the stack, not to a page. On tvOS both pages hold the same URL when
    // opening (`HomeView.backdropsURL`), so nothing changes. Here every page used to build backdrop
    // and `TvImageReason` afresh: image briefly gone and faded in again, tint recalculated. Now the
    // page only reports its URL on top and it is drawn here, once. Start to detail with the same URL:
    // no rebuild, no fade. If the target page has not reported yet, the handover from Start counts,
    // otherwise the last shown image stays. A section change to a page without a backdrop still
    // fades out.
    val topTarget = top.lastOrNull()
    val topKey = pagesKey(section, top.size, topTarget?.id)
    val carriesBackdrop = if (topTarget == null) section == TvSection.Start else topTarget.type !in withoutSharedBackdrop
    val shown = remember { arrayOfNulls<String>(1) }
    val backdrop = when {
        !carriesBackdrop -> null
        backdrops.containsKey(topKey) -> backdrops[topKey]
        else -> topTarget?.let { TvHandoff.of(it.id)?.backdrop } ?: shown[0]
    }
    shown[0] = backdrop
    // Top bar and gradient: visible only at the root of a section, see the layer below.
    val content = remember { FocusRequester() }
    val focusManager = LocalFocusManager.current
    val bar = animateFloatAsState(if (top.isEmpty()) 1f else 0f,
        tween(TvTheme.barDuration, easing = TvTheme.barCurve), label = "kopfleiste")

    Box(Modifier.fillMaxSize().background(Theme.reason)) {
        TvBackdropsLayer(backdrop, shadow = carriesBackdrop)
        Crossfade(section, animationSpec = tween(250), label = "bereich") { b ->
            val target = stack[b].orEmpty().lastOrNull()
            val depth = stack[b].orEmpty().size
            key(b, depth, target?.id) {
                val key = pagesKey(b, depth, target?.id)
                val report = remember(key) { { url: String? -> backdrops[key] = url } }
                // Menu key or long OK on a tile: the tile menu as a panel (`tileMenuPanel`).
                CompositionLocalProvider(LocalBackdropReport provides report,
                    de.paulherter.swiftly.LocalTileMenu provides { w -> de.paulherter.swiftly.tileMenuPanel(app, w, open) }) {
                stateHolder.SaveableStateProvider(key) {
                    if (target == null) {
                        Box(Modifier.fillMaxSize().focusRequester(content).focusGroup()) {
                            when (b) {
                                // Start draws no look glow at all (Paul: the extra glow must not be on Home).
                                TvSection.Start -> TvStartPage(app, open)
                                TvSection.Movies -> TvLibrary(app, "movies", de.paulherter.swiftly.offeredFilters(listOf("alle", "angefangen", "merkliste", "ungesehen"), app.settings.watchlist), open)
                                TvSection.Series -> TvLibrary(app, "tvshows", de.paulherter.swiftly.offeredFilters(listOf("alle", "angefangen", "merkliste"), app.settings.watchlist), open)
                                TvSection.Watchlist -> TvWatchlist(app, open)
                                TvSection.Search -> TvSearch(app, open)
                            }
                            // Mirrors `HeaderHistory` in `MainView`. Not on Start, where nothing scrolls under the bar
                            // any more (fixed hero zone); on the other root pages it does (the chip/filter row
                            // carries its own top spacing as part of the scrolling content, not as `contentPadding`).
                            // Soft and at 30 %, as on Apple TV: it must not swallow the look's glow.
                            if (b != TvSection.Start) TvHeaderHistory(Modifier.align(Alignment.TopStart).graphicsLayer { alpha = bar.value },
                                                                       soft = true, strength = 0.3f)
                        }
                    } else {
                        TvSubpage(app, target, open, back)
                    }
                }
                }
            }
        }
        // The look's glow lies behind each page itself (`TvGlow`), never over it; the pages stay neutral black.
        TvScrimFollowsGlow(app)
        // The top bar is its own layer above the stack, not part of the root page. Mirrors
        // `MainView.barPresent` on tvOS: it fades out when a subpage opens and back in on return,
        // `.easeInOut(duration: 0.26)`. While it was part of the root page it vanished abruptly
        // when `key(b, depth, ...)` swapped the page.
        //
        // Hidden, it is not a focus target (like `.disabled(!barPresent)` on tvOS): `enter = Cancel`
        // lets no direction key in while it fades out or is invisible. At 0 it leaves the
        // composition entirely.
        if (bar.value > 0.001f || top.isEmpty()) {
            val barPresent = top.isEmpty()
            Box(Modifier.fillMaxWidth().graphicsLayer { alpha = bar.value }
                    .focusProperties { if (!barPresent) enter = { FocusRequester.Cancel } }.focusGroup()
                    .onPreviewKeyEvent { e ->
                        // Down from the bar finds the content even if the search finds nothing. Grids and lists of the
                        // root pages extend under the bar (content runs under the header), so their group does
                        // not start below the tab, and Compose dropped it as a target for "down": nothing
                        // happened on Movies, Series, Watchlist and Search. First the geometric search, else
                        // the first spot on the page.
                        if (e.type != KeyEventType.KeyDown || e.key != Key.DirectionDown) return@onPreviewKeyEvent false
                        if (!focusManager.moveFocus(FocusDirection.Down)) runCatching { content.requestFocus() }
                        true
                    }) {
                HeaderBar(app, section, { section = it }, app.offerings.value) { open(Destination("profil", translated("Profil"), "Profil")) }
            }
        }
        // "Leave movie night · Rejoin" after the player closes.
        if (play == null) TvReturnPathStrip(app)
        // A group message: the same strip as on the pages; in the player, the player shows it.
        if (play == null) app.sharedError.value?.let {
            TvHintStrip(it, Modifier.align(Alignment.TopCenter).padding(top = 74.dp)) { app.sharedError.value = null }
        }
        // While the player runs, the panel belongs to it.
        if (play == null) TvPanel(app)
        // "Wähl deinen Look": a full page; the buy page opens from it, so it lies below.
        if (play == null) TvLooksLayer(app)
        // "Support Swiftly": the ask and the thanks as full panels.
        if (play == null) TvSupportLayer(app)
        // "Where to continue?" grows out of the badge.
        if (play == null) TvTakeoverStatus(app)
    }
}

/**
 * Mirrors tvOS `TVTakeoverSelection` with scrim (black 72 %) and
 * `.transition(.outPoint(BadgeOrigin.point))` in `MainView.swift`. The scrim fades, the
 * selection grows out of the badge (scale from 12 %, opacity faster than scale) and shrinks back
 * into it on close; same mechanics as `TakeoverStatus` on the phone, spring `Theme.spring`.
 * Points halved. Back closes; focus returns to the badge.
 */
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
private fun TvTakeoverStatus(app: SwiftlyApplication) {
    val opened = app.takeoverSelection.value
    val remembered = remember { arrayOfNulls<de.paulherter.swiftly.TakeoverSelection>(1) }
    opened?.let { remembered[0] = it }
    val w = remembered[0] ?: return
    val calm = de.paulherter.swiftly.shared.motionReduced()
    val on = remember { androidx.compose.animation.core.Animatable(0f) }
    LaunchedEffect(opened != null) {
        on.animateTo(if (opened != null) 1f else 0f,
            if (calm) de.paulherter.swiftly.shared.Motion.fadeReduced()
            else androidx.compose.animation.core.spring(dampingRatio = 0.9f, stiffness = 322f))
        if (opened == null) remembered[0] = null
    }
    LaunchedEffect(opened == null) { if (opened == null) { delay(TvTheme.focusDeadline); FocusRemember.reclaim() } }
    if (opened == null && on.value <= 0.001f) return
    val sharing = remember(w) { booleanArrayOf(false) }
    fun toward() {
        sharing[0] = true
        FocusRemember.backGive()
        if (app.takeoverSelection.value === w) app.takeoverSelection.value = null
    }
    BackHandler(enabled = opened != null) { toward() }
    val firstOne = remember(w) { FocusRequester() }
    LaunchedEffect(w) { delay(TvTheme.focusDeadline); runCatching { firstOne.requestFocus() } }
    Box(Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize().graphicsLayer { alpha = on.value.coerceIn(0f, 1f) }.background(Color.Black.copy(alpha = 0.72f)))
        val frameRect = remember { arrayOf(androidx.compose.ui.geometry.Rect.Zero) }
        CompositionLocalProvider(LocalWithinPanel provides true) {
            Column(Modifier.align(Alignment.Center).padding(24.dp)
                    .onGloballyPositioned { frameRect[0] = it.boundsInRoot() }
                    .graphicsLayer {
                        val a = on.value
                        if (!calm && frameRect[0].width > 0 && w.provenance != androidx.compose.ui.geometry.Offset.Zero) {
                            val r = frameRect[0]
                            transformOrigin = androidx.compose.ui.graphics.TransformOrigin(
                                ((w.provenance.x - r.left) / r.width).coerceIn(-2f, 3f), ((w.provenance.y - r.top) / r.height).coerceIn(-2f, 3f))
                            val m = 0.12f + 0.88f * a
                            scaleX = m; scaleY = m
                        }
                        alpha = (a * 1.6f).coerceIn(0f, 1f)
                    }
                    .focusProperties { exit = { if (sharing[0]) FocusRequester.Default else FocusRequester.Cancel } }.focusGroup(),
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(17.dp)) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(5.dp)) {
                    Text(translated("Wo weiterschauen?"), style = TvTheme.subpageTitle, color = Theme.font)
                    Text(translated("Auf dem anderen Gerät hört die Wiedergabe auf. Hier läuft sie an derselben Stelle weiter."),
                         style = TvTheme.small.copy(textAlign = androidx.compose.ui.text.style.TextAlign.Center), color = Theme.fontQuiet)
                }
                Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
                    w.offerings.forEachIndexed { i, a ->
                        // Each row is a different device: cool, like the badge (`AbzeichenStil(otherDevice: true)`).
                        FocusArea(modifier = if (i == 0) Modifier.focusRequester(firstOne) else Modifier,
                                     magnifier = TvTheme.focusMagnifierWide, perform = { toward(); w.select(a) }) { focus ->
                            val front = if (focus) Theme.reason else Theme.accent
                            Row(Modifier.widthIn(max = 380.dp).fillMaxWidth().height(44.dp).clip(RoundedCornerShape(50))
                                    .background(Theme.reason).background(if (focus) Color.White else Theme.accent.copy(alpha = 0.18f))
                                    .padding(horizontal = 14.dp),
                                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                Box(Modifier.width(20.dp), contentAlignment = Alignment.Center) {
                                    Symbol(takeoverCharacter(a.art), 14.dp, color = front, strength = Strength.Medium)
                                }
                                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                                    Text(a.device ?: translated("Gerät"), style = TvTheme.button, color = front, maxLines = 1)
                                    Text(a.titleLine, style = TvTheme.small, color = front.copy(alpha = 0.75f), maxLines = 1,
                                         overflow = TextOverflow.Ellipsis)
                                }
                                Text(a.pointText, style = TvTheme.small.copy(fontFeatureSettings = "tnum"), color = front.copy(alpha = 0.75f))
                            }
                        }
                    }
                }
                // "Cancel" stays gray (`AbzeichenStil()`).
                FocusArea(magnifier = TvTheme.focusMagnifierWide, perform = { toward() }) { focus ->
                    Box(Modifier.height(TvTheme.buttonHeight).clip(RoundedCornerShape(50))
                            .background(if (focus) Color.White else Theme.raised).padding(horizontal = 18.dp),
                        contentAlignment = Alignment.Center) {
                        Text(translated("Abbrechen"), style = TvTheme.button, color = if (focus) Theme.reason else Theme.font)
                    }
                }
            }
        }
    }
}

/**
 * Background, backdrop and header shadow for Start, movie and series pages: the layers each of
 * these pages used to carry itself (mirrors `imageReason`, `Backdrop`, `HeaderShadow` on tvOS).
 *
 * The old image stays until the new one is loaded (tvOS `switchImage`): `steht` changes only
 * when Coil has the new image in memory at the same size. Then `Backdrop` hits the cache, Coil
 * does not fade again (memory hits have no Coil cross-fade), and only the 300 ms fade of
 * `Backdrop` runs.
 */
@Composable
private fun TvBackdropsLayer(image: String?, shadow: Boolean) {
    val context = LocalContext.current
    val density = LocalDensity.current
    var stands by remember { mutableStateOf(image) }
    LaunchedEffect(image) {
        if (image != null && image != stands) {
            SingletonImageLoader.get(context).execute(ImageRequest.Builder(context).data(image)
                .size(with(density) { 590.dp.roundToPx() }, with(density) { 350.dp.roundToPx() }).build())
        }
        // A `null` counts only if it stays: on a page change the URL can be missing for a frame or two
        // until the new page has reported, which must not fade anything out. If a URL arrives
        // first, this effect is cancelled.
        if (image == null && stands != null) delay(150)
        stands = image
    }
    // The header shadow depends on the page type, not on the image. With `steht != null`, every gap
    // in the URL (page change, report one frame late) faded the shadow out and in for 300 ms while
    // the image stayed, which flickered when opening the series page. tvOS draws `HeaderShadow()`
    // unconditionally in `HomeView` and `DetailView`: the same layer, so nothing shows in the
    // transition. `shadow` is the same on Start, movie and series (`true`).
    val coverage by animateFloatAsState(if (shadow) 1f else 0f, tween(300), label = "kopfschatten")
    Box(Modifier.fillMaxSize()) {
        TvImageReason(stands)
        Backdrop(stands, Modifier.align(Alignment.TopEnd))
        Box(Modifier.fillMaxWidth().alpha(coverage)) { HeaderShadow() }
    }
}

/** The routing rule from `targetPlace`; pages that exist only on the phone come from there. */
@Composable
private fun TvSubpage(app: SwiftlyApplication, target: Destination, open: (Destination) -> Unit, back: () -> Unit) {
    when (target.type) {
        "Series", "Episode" -> TvSeries(app, target, open)
        "Person" -> TvPerson(app, target, open)
        "Genre" -> TvGenre(app, target, open)
        // A collection: from the title menu with section, from search or watchlist without.
        "BoxSet" -> TvCollection(app, target, open)
        "Playlist" -> TvPlaylist(app, target, open)
        "Profil" -> TvProfile(app, open)
        "WeiteresKonto" -> Box(Modifier.fillMaxSize().background(Theme.reason)) {
            TvLoginPage(app, app.serverName.value.orEmpty(), "", moreAccount = true, otherServer = back) { back() }
        }
        "ServerAufnahme" -> TvServerOnboarding(app, target.id.takeIf { it != "serveraufnahme" }, back)
        "Wiedergabeeinstellungen" -> PlaybackSettingsPage(app, back)
        "Darstellung" -> PresentationPage(app, open, back)
        "Einstellungen" -> SettingsPage(app, open, back)
        "Seerr" -> TvSeerrPage(app, back)
        "EigeneKoepfe" -> { androidx.activity.compose.BackHandler(onBack = back); TvOwnHeadersPage(app, back) }
        "Lizenzen" -> TvLicenses(app, back)
        "Seerrtitel" -> TvSeerrDetailPage(app, target, open, back)
        "Genrewahl" -> GenreSelectionPage(app, back)
        "Merkliste" -> TvWatchlist(app, open)
        else -> TvDetail(app, target, open)
    }
}

/**
 * Mirrors `Kopfleiste`: wordmark left, tabs next to it, profile right; left-aligned, not centered.
 * Switching happens on click, not on focus: tvOS searches geometrically, and three attempts to
 * redirect that flickered.
 *
 * `offerings`: "Continue here" (`Uebernahmeabzeichen`), left of the profile picture, only when
 * something is playing on another device.
 */
@Composable
private fun HeaderBar(app: SwiftlyApplication, active: TvSection, select: (TvSection) -> Unit,
                       offerings: List<Offering>, profile: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = TvTheme.edgePage).padding(top = TvTheme.edgeTop).height(TvTheme.stripHeight).focusGroup(),
        verticalAlignment = Alignment.CenterVertically) {
        Wordmark(height = 18.dp)
        Spacer(Modifier.width(26.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            // Switched off in Appearance, the watchlist has no tab.
            TvSection.entries.filter { it != TvSection.Watchlist || app.settings.watchlist }
                .forEach { b -> PageTab(translated(b.title), b == active) { select(b) } }
        }
        Spacer(Modifier.weight(1f))
        // One badge for "Continue here" and open groups together.
        val groups = app.gemeinsam.value.openGroups
        if (offerings.isNotEmpty() || groups.isNotEmpty()) {
            TvTakeoverBadge(app, offerings, groups)
            Spacer(Modifier.width(9.dp))
        }
        // "Support Swiftly", left of the profile, as on the phone's home page.
        TvSupportHeart(app)
        Spacer(Modifier.width(9.dp))
        // A 32 dp profile circle, the small step of the focus ladder. The ring is white: an image cannot
        // get brighter like a tile, and the accent carries state, not "the remote is here"
        // (`ProfileStyle` on tvOS). The account switch flies here; while the new image is on its way,
        // none is shown.
        val transition = de.paulherter.swiftly.AccountSwitchTransition.transition
        FocusArea(magnifier = TvTheme.focusMagnifierSmall, perform = profile) { focus ->
            Box(Modifier.size(32.dp).border(2.dp, if (focus) Theme.font else Color.Transparent, CircleShape).padding(3.dp)
                    .onGloballyPositioned { de.paulherter.swiftly.AccountSwitchTransition.targetReport(it.boundsInRoot(), it.findRootCoordinates().size.width.toFloat()) }
                    .graphicsLayer { alpha = if (transition != null && !transition.replaced) 0f else 1f }) {
                SubcomposeAsyncImage(model = app.kern.userImage(160).orElse(null), contentDescription = translated("Profil"),
                    contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize().clip(CircleShape).background(Theme.raised),
                    error = { Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Symbol(Glyph.PersonFilled, 13.dp, color = Theme.fontQuiet)
                    } })
            }
        }
    }
}

private fun takeoverCharacter(art: String): Glyph = when (art) {
    "telefon" -> Glyph.Phone
    "tablet" -> Glyph.Tablet
    "rechner" -> Glyph.Laptop
    "fernseher" -> Glyph.Tv
    else -> Glyph.PlayTv
}

/**
 * Mirrors tvOS `Uebernahmeabzeichen`: "Playing on iPhone, continue here"; one line at rest, the
 * title joins on focus. On the phone the same action sits in `TakeoverCharacter` (`Takeover.kt`);
 * the logic (`app.kern.adopt`, `Angebot`) is shared, only the drawing is tvOS-specific:
 * capsule instead of circle.
 *
 * Several offers open `TvPanel` instead of a dedicated selection sheet, as on tvOS
 * (`TVTakeoverSelection`): the panel already has icon, checkmark and selection, a second sheet
 * would copy the same action.
 */
@Composable
private fun TvTakeoverBadge(app: SwiftlyApplication, offerings: List<Offering>, groups: List<SharedGroup>) {
    val context = LocalContext.current
    val run = rememberCoroutineScope()
    var takesOver by remember { mutableStateOf(false) }
    // Where the badge sits (root pixels); selection and card grow from there (`BadgeOrigin`).
    val center = remember { arrayOf(androidx.compose.ui.geometry.Offset.Zero) }
    val density = androidx.compose.ui.platform.LocalDensity.current.density
    val calm = de.paulherter.swiftly.shared.motionReduced()
    fun adopt(a: Offering) {
        if (takesOver) return
        takesOver = true
        run.launch { de.paulherter.swiftly.hereContinueWatching(app, context, a, center[0], density, calm); takesOver = false }
    }
    val firstOne = offerings.firstOrNull()
    val count = offerings.size + groups.size
    // Mirrors `OfferingBadge.tapOn` (iOS): only a handover as before; only a group: "Join";
    // otherwise the selection with both.
    FocusArea(magnifier = TvTheme.focusMagnifierWide, perform = {
        if (groups.isNotEmpty()) {
            if (offerings.isEmpty() && groups.size == 1) tvJoinOpen(app, groups.first())
            else tvSelectionOpen(app, ::adopt)
        }
        else if (offerings.size == 1 && firstOne != null) adopt(firstOne)
        // Several devices: the selection grows out of the badge (`TVTakeoverSelection`, `TvTakeoverStatus`).
        else app.takeoverSelection.value = de.paulherter.swiftly.TakeoverSelection(offerings, center[0]) { adopt(it) }
    }) { focus ->
        // Mirrors `AbzeichenStil(otherDevice: true)` in `TVComponents.swift`. Not translucent: at rest
        // the accent at 18 percent over the opaque page background, on focus a full white surface
        // with dark text/icon.
        val foreground = if (focus) Theme.reason else Theme.accent
        Row(Modifier.onGloballyPositioned { center[0] = it.boundsInRoot().center }
                .height(if (focus) 38.dp else 32.dp).clip(RoundedCornerShape(50))
                .background(Theme.reason).background(if (focus) Color.White else Theme.accent.copy(alpha = 0.18f))
                .padding(horizontal = 14.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
            Symbol(firstOne?.let { takeoverCharacter(it.art) } ?: Glyph.ClusterFilled, 13.dp, color = foreground, strength = Strength.Medium)
            Column {
                Text(translated(when {
                        count > 1 -> "Läuft gerade"
                        offerings.isEmpty() -> "Gemeinsam schauen"
                        else -> "Hier weiterschauen"
                     }), style = TvTheme.button, color = foreground, maxLines = 1)
                if (focus) Text(firstOne?.titleLine ?: groups.first().name, style = TvTheme.small, color = foreground.copy(alpha = 0.75f),
                                maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            // The counter when there is more than one, same as on the phone.
            if (count > 1) Box(Modifier.defaultMinSize(18.dp, 18.dp).clip(CircleShape).background(foreground).padding(horizontal = 5.dp),
                                contentAlignment = Alignment.Center) {
                Text("$count", style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.SemiBold, fontFeatureSettings = "tnum"),
                     color = if (focus) Color.White else Theme.onAccent)
            }
        }
    }
}

/** Mirrors `TabStyle`: magnifier 1.06, calm surface on focus, selected with accent underline. */
@Composable
private fun PageTab(text: String, selected: Boolean, perform: () -> Unit) {
    FocusArea(magnifier = TvTheme.focusMagnifier, perform = perform) { focus ->
        // The calm focus surface, same as everywhere, not a separate white value.
        Column(Modifier.clip(RoundedCornerShape(TvTheme.corner)).background(if (focus) TvTheme.focusArea else Color.Transparent)
                .padding(horizontal = 12.dp, vertical = 5.dp),
            horizontalAlignment = Alignment.CenterHorizontally) {
            Text(text, style = TvTheme.button,
                 color = if (focus || selected) Theme.font else Theme.fontQuiet)
            Box(Modifier.padding(top = 3.dp).size(18.dp, 2.dp).clip(CircleShape).background(if (selected) Theme.accent else Color.Transparent))
        }
    }
}

/**
 * Mirrors `Handlungstafel`: the same actions as the phone sheet (`app.sheet`), as a panel on the
 * right edge. Focus stays inside until it closes; Back closes only the panel.
 *
 * Focus returns to the row that opened the panel (selection or Back), see `FocusRemember` in
 * `TvTheme.kt`. Without that, focus landed randomly after closing, e.g. on the "+" button in the
 * accounts strip of the profile page, whatever row had opened the panel.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun TvPanel(app: SwiftlyApplication) {
    val w = app.sheet.value
    LaunchedEffect(w == null) { if (w == null) { delay(TvTheme.focusDeadline); FocusRemember.reclaim() } }
    if (w == null) return
    // `exit = Cancel` keeps the focus search in the panel, but also blocks a programmatic
    // `requestFocus` outward (Compose asks `exit` when leaving any group). So `sharing` opens the
    // exit just for handing focus back.
    val sharing = remember(w) { booleanArrayOf(false) }
    // First hand focus back to the trigger, then remove the panel: the other way round, focus would
    // fall onto the first focusable node for a few frames (see `FocusRemember.backGive`).
    val close = {
        sharing[0] = true
        FocusRemember.backGive()
        if (app.sheet.value === w) app.sheet.value = null
    }
    // A row may open the next panel right away (`select` sets `app.sheet` again); then focus stays
    // in the panel and nothing is closed.
    val selectAndClose = { perform: () -> Unit ->
        perform()
        if (app.sheet.value === w) close()
    }
    BackHandler(onBack = close)
    var pick by remember(w) { mutableStateOf(w.moreCompartment) }
    val firstOne = remember(w) { FocusRequester() }
    LaunchedEffect(w) { delay(TvTheme.focusDeadline); runCatching { firstOne.requestFocus() } }
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.55f))) {
        CompositionLocalProvider(LocalWithinPanel provides true) {
            Column(Modifier.align(Alignment.CenterEnd).padding(end = TvTheme.edgePage).width(310.dp)
                    .clip(RoundedCornerShape(TvTheme.cornerArea)).background(Theme.area).padding(10.dp)
                    .focusProperties { exit = { if (sharing[0]) FocusRequester.Default else FocusRequester.Cancel } }.focusGroup()) {
                // Without a title, no header row: the title menu of movies and series has none on tvOS.
                if (w.title.isNotEmpty()) Text(w.title, style = TvTheme.categoryLarge, color = Theme.font, maxLines = 2,
                     modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp))
                w.subline?.let { Text(it, style = TvTheme.body, color = Theme.fontQuiet,
                     modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 12.dp)) }
                Column(Modifier.heightIn(max = 380.dp).verticalScroll(rememberScrollState())) {
                    w.entries.forEachIndexed { i, e ->
                        w.categories[e.value]?.let { over ->
                            // Mirrors the section header of `Handlungstafel`: divider, then the heading in capitals,
                            // `schriftSehrLeise`, `railsHeaderPadding` on top (24 to 12), 8 to 4 below; indented
                            // like the row text, everything on one edge.
                            Box(Modifier.padding(horizontal = 16.dp).fillMaxWidth().height(1.dp).background(Theme.line))
                            Text(over.uppercase(), style = Theme.group, color = Theme.fontVeryQuiet,
                                 modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 4.dp))
                        }
                        val amount = pick
                        TvRow(e.text, w.icons[e.value], right = w.locked[e.value],
                                checkmark = if (amount != null) e.value in amount else e.value == w.selected,
                                modifier = if (i == 0) Modifier.focusRequester(firstOne) else Modifier) {
                            if (w.locked[e.value] != null) return@TvRow
                            if (amount != null) pick = if (e.value in amount) amount - e.value else amount + e.value
                            else selectAndClose { w.select(e.value) }
                        }
                    }
                }
                w.completion?.let { completion ->
                    val amount = pick.orEmpty()
                    TvRow(w.completionText(amount.size)) { if (amount.isNotEmpty()) selectAndClose { completion(amount) } }
                }
            }
        }
    }
}
