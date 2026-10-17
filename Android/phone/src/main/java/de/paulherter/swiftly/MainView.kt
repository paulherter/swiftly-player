package de.paulherter.swiftly

import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Strength
import androidx.activity.compose.PredictiveBackHandler
import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.ui.draw.clip
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.lifecycle.repeatOnLifecycle
import androidx.compose.foundation.selection.selectable
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.shared.Motion
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.future.await
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext

/** Mirrors `Region` in `Sources/Shared/Style.swift`: Downloads only when enabled. */
enum class Region(val title: String, val symbol: Glyph) {
    Start("Start", Glyph.House),
    Movies("Filme", Glyph.Film),
    Series("Serien", Glyph.Tv),
    Downloads("Downloads", Glyph.LoadCircle),
    Search("Suche", Glyph.Magnifier),
}

/**
 * A place in a section's stack, like `NavigationLink(value: Item)` on iOS. Only a person carries
 * `role` and `origin`: "Woody in Toy Story" shows before anything is loaded.
 */
data class Destination(val id: String, val name: String, val type: String, val role: String? = null, val origin: String? = null)

/**
 * Mirrors `MainView` in `Sources/Shared/MainView.swift`: one stack per section.
 *
 * The motion is `NavigationStack`'s, not Android's: the new page slides in from the right, the old
 * one recedes by a third to the left and darkens. The back gesture drags the page with the finger;
 * `PredictiveBackHandler` is Android's counterpart to `SwipeBack`. Only the top page and, during
 * a motion, the one below are drawn; both keep their identity via `key` when they swap places.
 *
 * The bar belongs to the root page and moves with it; on iOS `sectionBar()` hangs there, not
 * on deeper pages.
 */
@Composable
fun MainScreen(app: SwiftlyApplication) {
    var section by rememberSaveable { mutableStateOf(Region.Start) }
    // Each section keeps its state (scroll position) on switching.
    val stateHolder = rememberSaveableStateHolder()
    // Right on arrival, not only in the library, where it let the header grow in afterwards.
    LaunchedEffect(Unit) {
        app.sessionCheck()
        app.seerrLoad()
        app.downloads.accountSet(app.accountId())
        app.serverNameLoad()
        app.postConnect()
        // Remote control: buttons in the dashboard, and other devices see this session to take over.
        app.kern.remoteControlStart().await()
    }
    // "Continue watching here": every five seconds while the app is in front. It looks for a session
    // that did not exist before, and that should not wait ten seconds.
    @Suppress("DEPRECATION")
    val lifecycle = androidx.compose.ui.platform.LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(lifecycle) {
        lifecycle.repeatOnLifecycle(androidx.lifecycle.Lifecycle.State.STARTED) {
            while (true) { app.offeringsFetch(); kotlinx.coroutines.delay(5000) }
        }
    }
    // One stack per section; `pfade[b.rawValue]` in `MainView`.
    val stack = remember { mutableStateMapOf<Region, List<Destination>>() }
    // On tap in the profile picker a still of the page flies away; underneath, stack and section
    // jump back here without animation, invisible meanwhile (`AccountSwitchTransition.back`).
    val backState = remember { AccountSwitchTransition.back }
    LaunchedEffect(AccountSwitchTransition.back) {
        if (AccountSwitchTransition.back != backState && AccountSwitchTransition.waits) { stack.clear(); section = Region.Start }
    }
    val top = stack[section].orEmpty()
    val run = rememberCoroutineScope()
    /** How far the top page is out to the right: 0 is at rest, 1 is gone. */
    val push = remember { Animatable(0f) }
    /** `sectionMetric`: the content grows from 0.995 to 1 on a section switch. */
    val sectionMetric = remember { Animatable(1f) }
    val moved by remember { derivedStateOf { push.value > 0f } }

    // The routing rule from `targetPlace` is in `Unterseite`.
    //
    // A new job does not discard a tap. If a motion is still running, it is set to its target and
    // awaited, so a second tap or back in the middle of a switch takes effect instead of being
    // dropped silently.
    val ongoing = remember { arrayOfNulls<Job>(1) }
    fun job(block: suspend () -> Unit) {
        val before = ongoing[0]
        ongoing[0] = run.launch {
            if (before?.isActive == true) { push.snapTo(push.targetValue); before.join() }
            block()
        }
    }
    fun remove() { stack[section] = stack[section].orEmpty().dropLast(1) }
    val open: (Destination) -> Unit = { z ->
        job {
            // First push it out, then insert, in the same frame; otherwise the page flashes.
            push.snapTo(1f)
            stack[section] = stack[section].orEmpty() + z
            push.animateTo(0f, Motion.page())
        }
    }
    val back: () -> Unit = {
        if (stack[section].orEmpty().isNotEmpty()) job {
            // The way back also counts when cancelled, so the completion is in the finally block.
            try {
                // Build the page below first, then move, as when opening. Otherwise it was built in the first
                // frame of the motion and closing stalled right at the start.
                push.snapTo(0.0001f)
                androidx.compose.runtime.withFrameNanos { }
                androidx.compose.runtime.withFrameNanos { }
                push.animateTo(1f, Motion.back())
            }
            finally { withContext(NonCancellable) { remove(); push.snapTo(0f) } }
        }
    }
    PredictiveBackHandler(enabled = top.isNotEmpty()) { events ->
        ongoing[0]?.let { if (it.isActive) { push.snapTo(push.targetValue); it.join() } }
        // The finger's velocity, so releasing flies on instead of starting over.
        var tempo = 0f
        var recent = 0L
        var value = push.value
        try {
            events.collect { e ->
                val now = System.nanoTime()
                if (recent > 0) { val dt = (now - recent) / 1e9f; if (dt > 0f) tempo = (e.progress - value) / dt }
                recent = now
                value = e.progress
                push.snapTo(e.progress)
            }
            // A little overshoot is fine, but a very fast fling shot far beyond.
            push.animateTo(1f, Motion.toss(), initialVelocity = tempo.coerceIn(0f, 6f))
            remove()
            push.snapTo(0f)
        } catch (e: CancellationException) {
            // Released before it was enough: the page glides back at its speed.
            val backTempo = tempo.coerceIn(-6f, 0f)
            run.launch { push.animateTo(0f, Motion.toss(), initialVelocity = backTempo) }
            throw e
        }
    }
    // The player has its own activity (picture-in-picture); a request starts it.
    val context = androidx.compose.ui.platform.LocalContext.current
    val play = app.play.value
    // Each request starts the player exactly once. Without `playHandOver`, a rebuilt main
    // activity started it again with the same request, and closing resumed the episode. See
    // `SwiftlyApplication.playHandOver`.
    LaunchedEffect(play) {
        if (play == null || play === app.playHandOver) return@LaunchedEffect
        app.playHandOver = play
        // From a handover without its own transition: the card lies above (`Uebergabe`).
        val on = if (Handoff.arrival != null) de.paulherter.swiftly.R.anim.hold else de.paulherter.swiftly.R.anim.player_enter
        context.startActivity(android.content.Intent(context, PlayerActivity::class.java),
            android.app.ActivityOptions.makeCustomAnimation(context, on, de.paulherter.swiftly.R.anim.hold).toBundle())
    }

    val select: (Region) -> Unit = { b ->
        if (b == section) {
            stack[b] = emptyList()
            // The second tap on Search opens the keyboard.
            if (b == Region.Search) app.search.anotherTime++
        }
        else {
            section = b
            run.launch {
                push.snapTo(0f)
                // Hard cut, then a touch of growth. A crossfade let the background shine through both pages
                // (iOS, `sectionSwitch`).
                sectionMetric.snapTo(Motion.SectionMetric)
                sectionMetric.animateTo(1f, Motion.sectionSwitch())
            }
        }
    }

    // Disabled while standing in the section: back to Start.
    val downloadsAn = app.settings.downloadsAn
    LaunchedEffect(downloadsAn) { if (!downloadsAn && section == Region.Downloads) select(Region.Start) }

    var tileMenu by remember { mutableStateOf<TileMenuRequest?>(null) }
    CompositionLocalProvider(LocalSectionMetric provides sectionMetric, LocalProgressShow provides app.settings.progress,
                              LocalTileMenu provides { w: TileMenuRequest -> tileMenu = w },
                              LocalLoadingPulse provides LoadingPulse()) {
        Box(Modifier.fillMaxSize().background(Theme.reason)) {
            val since = if (moved && top.isNotEmpty()) top.size - 1 else top.size
            for (depth in since..top.size) {
                val target = top.getOrNull(depth - 1)
                key(section, depth, target?.id) {
                    val isTop = depth == top.size
                    Box(Modifier.fillMaxSize()
                        .graphicsLayer {
                            translationX = if (isTop) push.value * size.width
                                           else -0.25f * (1f - push.value) * size.width
                        }
                        .background(Theme.reason)) {
                        stateHolder.SaveableStateProvider("${section.name}/$depth/${target?.id.orEmpty()}") {
                            if (target == null) InitialPage(app, section, open, select)
                            else Subpage(app, target, open, back)
                        }
                        // The page below darkens while the top one covers it.
                        if (!isTop) Box(Modifier.matchParentSize().graphicsLayer { alpha = 1f - push.value }
                            .background(Color.Black.copy(alpha = 0.15f)))
                    }
                }
            }
            // Above everything, also above the bar: on iOS the sheet hangs behind `.sectionBar()`.
            // "Leave movie night · Rejoin" after closing the player (`SharedSheets`).
            // On a root page above the bar, otherwise at the edge like any hint.
            if (play == null) ReturnPathStrip(app, if (top.isEmpty()) Theme.stripHeight + 12.dp else 34.dp)
            // A group message: the same strip as on every page; in the player it shows there.
            if (play == null) HintStrip(app.sharedError.value, Modifier.align(Alignment.BottomCenter)
                .padding(bottom = if (top.isEmpty()) Theme.stripHeight else 0.dp)) { app.sharedError.value = null }
            // While the player runs, the sheet belongs to it.
            if (play == null) SheetStatus(app)
            // "Where to continue watching?": the card grows out of the badge.
            if (play == null) TakeoverStatus(app)
            // The tile menu above everything (`TileMenu`), and what it reports.
            if (play == null) TileMenuStatus(app, tileMenu, open) { tileMenu = null }
            if (play == null) HintStrip(app.message.value, Modifier.align(Alignment.BottomCenter)
                .padding(bottom = if (top.isEmpty()) Theme.stripHeight else 0.dp)) { app.message.value = null }
        }
    }
}

@Composable
private fun InitialPage(app: SwiftlyApplication, section: Region, open: (Destination) -> Unit, select: (Region) -> Unit) {
    Column(Modifier.fillMaxSize()) {
        Box(Modifier.weight(1f)) {
            when (section) {
                Region.Start -> StartPage(app, open)
                Region.Movies -> LibraryPage(app, "movies", translated("Filme"),
                                                 listOf("alle", "angefangen", "merkliste", "ungesehen"), open)
                // For series "unwatched" helps little; the same list as on iOS.
                Region.Series -> LibraryPage(app, "tvshows", translated("Serien"),
                                                  listOf("alle", "angefangen", "merkliste"), open)
                Region.Downloads -> DownloadsPage(app, open)
                Region.Search -> SuchPage(app, open)
            }
        }
        Bar(section, app.settings.downloadsAn,
               app.downloads.entries.value.count { it.state == "laedt" || it.state == "wartet" }, select)
    }
}

/** The routing rule from `targetPlace`: series to series page, episode to its season, person to person page, otherwise title page. */
@Composable
private fun Subpage(app: SwiftlyApplication, target: Destination, open: (Destination) -> Unit, back: () -> Unit) {
    when (target.type) {
        "Series", "Episode" -> SeriesPage(app, target, open, back)
        "Person" -> PersonPage(app, target, open, back)
        "Profil" -> ProfilePage(app, open, back)
        "Merkliste" -> WatchlistPage(app, open, back)
        "WeiteresKonto" -> Box(Modifier.fillMaxSize().background(Theme.reason)) {
            LoginPage(app, app.serverName.value.orEmpty(), "", otherServer = back, moreAccount = true) { back() }
        }
        "ServerAufnahme" -> ServerOnboardingPage(app, target.id.takeIf { it != "serveraufnahme" }, back)
        "Genre" -> GenrePage(app, target, open, back)
        // A collection: with a section from the title menu, without from search or watchlist.
        "BoxSet" -> CollectionPage(app, target, open, back)
        "QuickConnect" -> QuickConnectPage(app, back)
        "Wiedergabeeinstellungen" -> PlaybackSettingsPage(app, back)
        "Darstellung" -> PresentationPage(app, open, back)
        "Einstellungen" -> SettingsPage(app, open, back)
        "Seerr" -> SeerrSettingsPage(app, back)
        "EigeneKoepfe" -> OwnHeadersPage(app, back)
        "Lizenzen" -> LicensesPage(open, back, app)
        "Lizenz" -> LicenseScreen(target, back, app)
        "Lizenzangebot" -> LicenseOfferingPage(back)
        "Seerrtitel" -> SeerrDetailPage(app, target, open, back)
        "Genrewahl" -> GenreSelectionPage(app, back)
        "Bibliothekswahl" -> LibrarySelectionPage(app, back)
        "Downloadserie" -> DownloadSeriesPage(app, target, back)
        else -> TitlePage(app, target, open, back)
    }
}

/**
 * Mirrors `NavBar` + `SectionButton` in `Style.swift`: 54 high, opaque in `reason`, hairline
 * on top, 9 space above the icons, 4 between icon and label.
 */
@Composable
private fun Bar(active: Region, downloads: Boolean, runningCount: Int, select: (Region) -> Unit) {
    Column(Modifier.fillMaxWidth().background(Theme.reason).navigationBarsPadding()) {
        Box(Modifier.fillMaxWidth().height(1.dp).background(Theme.line))
        Row(Modifier.fillMaxWidth().height(Theme.stripHeight).padding(top = 9.dp)) {
            // Downloads only when the feature is on; left of Search, which stays at the far right.
            Region.entries.filter { it != Region.Downloads || downloads }.forEach { b ->
                val an = b == active
                // The selected section carries the accent: the one justified exception to "selected means
                // white". At rest `schriftSehrLeise`.
                val color = if (an) Theme.accent else Theme.fontVeryQuiet
                val source = remember { MutableInteractionSource() }
                val pressed by source.collectIsPressedAsState()
                // `Theme.PressButton`: scale 0.97 and opacity 0.85, press immediate, release 0.12 s.
                val press by animateFloatAsState(if (pressed) 1f else 0f,
                    if (pressed) snap() else Motion.release(), label = "druck")
                Column(
                    Modifier.weight(1f).selectable(an, source, null,
                        role = androidx.compose.ui.semantics.Role.Tab) { select(b) }
                        .graphicsLayer { val m = 1f - 0.03f * press; scaleX = m; scaleY = m; alpha = 1f - 0.15f * press },
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Box {
                        // Icon 20 pt means a 24 dp box here. SF Symbols at size 20 are about 20 pt tall; a Material
                        // icon has 2 dp padding all round in its 24 grid, so in a 20 box the glyph kept barely 17.
                        // That is the "looks smaller" effect at pixel level. Cause: different symbol set, not a
                        // different size.
                        Symbol(b.symbol, 20.dp, color = color, strength = if (an) Strength.Semibold else Strength.Normal)
                        if (b == Region.Downloads && runningCount > 0) {
                            // The count of running ones, not finished ones; offset outwards, otherwise it covers the icon.
                            Text(runningCount.toString(), style = Theme.badge.copy(letterSpacing = 0.sp), color = Theme.reason,
                                 modifier = Modifier.align(Alignment.TopEnd).offset(x = 11.dp, y = (-7).dp)
                                     .clip(CircleShape).background(Theme.accent).padding(horizontal = 4.dp, vertical = 2.dp))
                        }
                    }
                    // Label 10, semibold when selected, otherwise medium; as in `SectionButton`.
                    Text(translated(b.title), color = color,
                         style = Theme.badge.copy(letterSpacing = 0.sp, fontWeight = if (an) FontWeight.SemiBold else FontWeight.Medium))
                }
            }
        }
    }
}
