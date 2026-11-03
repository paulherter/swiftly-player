package de.paulherter.swiftly.tv

import androidx.activity.compose.BackHandler
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.shared.Wordmark
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import de.paulherter.swiftly.SwiftlyApplication
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Motion
import de.paulherter.swiftly.shared.Strength
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import de.paulherter.swiftly.support.LookTileView
import de.paulherter.swiftly.support.Looks
import de.paulherter.swiftly.support.TvSupportPanel
import de.paulherter.swiftly.support.ellipseGradient
import de.paulherter.swiftly.support.findActivity
import kotlinx.coroutines.delay
import org.json.JSONObject

/**
 * **Looks on Android TV**, after the Apple TV version (`TVLooks.swift`): the glow behind the main
 * pages, the full-screen "Wähl deinen Look", the "Dein Look / Ändern" row. All rules live in `Looks`
 * (the package's `LookTryOn`); this file is only the television's surface: D-pad, focus, Back.
 */

/**
 * How strongly the dark scrim of Home (`HeaderShadow`) still draws. It used to swallow the glow;
 * with a glow on it is down to 30 %, as on Apple TV.
 */
var tvScrimScale by mutableFloatStateOf(1f)

/** Keeps `tvScrimScale` in step with the look; drawn nothing. */
@Composable
fun TvScrimFollowsGlow(app: SwiftlyApplication) {
    // Home has no glow, so its scrim keeps full strength.
    SideEffect { tvScrimScale = 1f }
}

/** A quarter of the 1080 picture (`LookGlowLayer`: 270 pt on tvOS), halved to dp. */
private const val GLOW_REACH = 135f

/** How far the glow follows the page up (`LookGlowScroll`: 300 pt), halved. */
const val TV_GLOW_SCROLL_MAX = 150f

/**
 * **The look's glow** (`LookGlowLayer` on tvOS): the look's color from the top center, an ellipse
 * 0.75 of the width wide and a quarter of the picture deep, its second tone (only where the look
 * has one) from beyond the right edge. Lies **behind** the page and starts at the screen's top
 * edge; `scrolled` (dp) moves it up with the content, at most `TV_GLOW_SCROLL_MAX` (read while
 * drawing, so scrolling never recomposes). `strength` overrides the chosen one (the looks and the
 * support page show it soft, as on tvOS). Nothing with the Original look's "off".
 */
@Composable
fun TvGlow(app: SwiftlyApplication, modifier: Modifier = Modifier, strength: Float? = null, scrolled: () -> Float = { 0f }) {
    val p = app.looks.palette.value
    val c by animateColorAsState(p.glowColor, Motion.change(), label = "schein")
    val s by animateFloatAsState(strength ?: p.glowOpacity, Motion.change(), label = "staerke")
    val tint = p.glowTint
    val density = LocalDensity.current
    Box(modifier.fillMaxWidth().height((GLOW_REACH * 2).dp).drawBehind {
        if (s <= 0.001f) return@drawBehind
        val w = size.width
        val r = with(density) { GLOW_REACH.dp.toPx() }
        val y = -with(density) { scrolled().coerceIn(0f, TV_GLOW_SCROLL_MAX).dp.toPx() }
        tint?.let { t ->
            ellipseGradient(Offset(w * 1.25f, y), w * 0.9f, r * 1.2f,
                0f to t.copy(alpha = 0.36f * s), 0.5f to t.copy(alpha = 0.16f * s), 1f to t.copy(alpha = 0f))
        }
        ellipseGradient(Offset(w / 2, y), w * 0.75f, r,
            0f to c.copy(alpha = s), 0.35f to c.copy(alpha = 0.62f * s), 0.7f to c.copy(alpha = 0.22f * s), 1f to c.copy(alpha = 0f))
    })
}

/** The soft strength (`LookGlow.soft`) for the looks and support pages. */
fun tvSoftGlow(app: SwiftlyApplication): Float = app.looks.glowOpacity["soft"] ?: 0.2f

/** "Dein Look / Ändern" and the settings row open the page. */
fun tvLooksOpen(app: SwiftlyApplication) {
    app.looks.tvPage.value = true
}

/** Whether "Darstellung" shows a looks row at all (`TVLookEntry.shown`). */
fun tvLookRowShown(app: SwiftlyApplication): Boolean {
    val (entry, plainRow) = app.looks.profileEntry()
    return entry != "none" || plainRow
}

/**
 * **The look row on the settings card** (`TVLookEntryRow`), by `LookProfileEntry`: the worn look's
 * tile, its name and "Ändern" in the accent; the teaser with its line; or the plain "Looks".
 * Tile 52 pt, spacing 24, halved.
 */
@Composable
fun TvLookRow(app: SwiftlyApplication, modifier: Modifier = Modifier) {
    val looks = app.looks
    val entry = looks.profileEntry().first
    val saved = looks.info(JSONObject(looks.saved.value).optString("look", looks.palette.value.look))
    // The settings look (`TvSettingsRow`): white focus surface over the group, dark type in focus, gaps 24 pt.
    TvSettingsRow(modifier.semantics(mergeDescendants = true) { role = Role.Button },
                  spacing = 12.dp, perform = { tvLooksOpen(app) }) { focus ->
        val ink = if (focus) Theme.reason else Theme.font
        val quiet = if (focus) Theme.reason else Theme.fontVeryQuiet
        Box(Modifier.padding(vertical = 5.dp)) { LookTileView(looks.tileIcon(saved), 26.dp) }
        when (entry) {
            "current" -> {
                Text(saved.name, style = TvTheme.body, color = ink, maxLines = 1,
                     overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                Text(translated("Ändern"), style = TvTheme.body, color = if (focus) Theme.reason else Theme.accent, maxLines = 1)
            }
            "teaser" -> {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    Text(translated("Wähl deinen Look"), style = TvTheme.body, color = ink, maxLines = 1)
                    Text(translated("Looks und Icons für alle, die Swiftly am Laufen halten."), style = TvTheme.small,
                         color = quiet, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                Symbol(Glyph.AngleRight, 12.dp, color = quiet, strength = Strength.Semibold)
            }
            else -> {
                Text(translated("Looks"), style = TvTheme.body, color = ink, maxLines = 1, modifier = Modifier.weight(1f))
                Symbol(Glyph.AngleRight, 12.dp, color = quiet, strength = Strength.Semibold)
            }
        }
    }
}

/** Above the pages, below the support panels (they open from here). Back closes; focus goes back to the row. */
@Composable
fun TvLooksLayer(app: SwiftlyApplication) {
    if (!app.looks.tvPage.value) return
    TvLooksPage(app)
}

/**
 * **"Wähl deinen Look"** (`TVLooksPage`): one scrolling column. The title, a stand-in of Home in the
 * colors being tried, the looks in a row, the settings card ("Startseiten-Schein", "Akzentfarbe")
 * and one button. Every tvOS point halved. Picking a look applies it live (a preview where it may
 * not be worn); a gift not picked up yet is picked up. Back closes.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun TvLooksPage(app: SwiftlyApplication) {
    val looks = app.looks
    val context = LocalContext.current
    val support = app.support
    // Who opened the page, kept apart: the button that opens the buy page sets `lastOne` too.
    val origin = remember { FocusRemember.lastOne }
    val sharing = remember { booleanArrayOf(false) }
    val close = {
        sharing[0] = true
        FocusRemember.lastOne = origin
        FocusRemember.backGive()
        looks.tvPage.value = false
    }
    BackHandler(onBack = close)
    DisposableEffect(Unit) { onDispose { looks.panelClosed(context) } }

    val shown = JSONObject(looks.shown.value)
    val look = looks.info(shown.optString("look", "original"))
    val wearable = looks.mayWear(shown)
    val owned = looks.owned.value
    val list = looks.catalog.filter { !it.isGift || it.id in owned || looks.giftAvailable(it.id) }
    // The default focus is the look being shown (`defaultFocus(.look(look.id))`).
    val initial = remember { look.id }
    val first = remember { FocusRequester() }
    LaunchedEffect(Unit) { delay(2 * TvTheme.focusDeadline); runCatching { first.requestFocus() } }

    fun pick(item: Looks.LookInfo) {
        if (item.id == look.id) return
        // A gift not picked up yet ("Nicht jetzt" before): choosing it here picks it up.
        if (item.isGift && item.id !in owned) { looks.claim(item.id, context); return }
        looks.pick(looks.switching(item.id))
    }
    fun openSupport() {
        looks.tvFromLooks = true
        support.tvPanel.value = TvSupportPanel.Ask
    }

    Box(Modifier.fillMaxSize().background(Theme.reason)
            .focusProperties { exit = { if (sharing[0]) FocusRequester.Default else FocusRequester.Cancel } }.focusGroup()) {
        TvGlow(app, strength = tvSoftGlow(app))
        CompositionLocalProvider(LocalWithinPanel provides true) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())
                   .padding(horizontal = TvTheme.edgePage, vertical = TvTheme.edgeTop),
               horizontalAlignment = Alignment.CenterHorizontally) {
            Text(translated("Wähl deinen Look"), style = TvTheme.titleLarge, color = Theme.font)

            TvLooksMock(Modifier.padding(top = 14.dp))

            Row(Modifier.padding(top = 18.dp).focusGroup(), verticalAlignment = Alignment.Top,
                horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                list.forEach { item ->
                    val allowed = looks.mayWear(JSONObject().put("look", item.id)) || (item.isGift && item.id !in owned)
                    TvLookChoice(app, item, chosen = item.id == look.id, locked = !allowed,
                                 modifier = if (item.id == initial) Modifier.focusRequester(first) else Modifier) { pick(item) }
                }
            }

            // The settings card: always the same rows, so the page does not jump between looks.
            Column(Modifier.padding(top = 14.dp).widthIn(max = 650.dp).fillMaxWidth()
                       .clip(RoundedCornerShape(TvTheme.cornerTile)).background(Theme.area).padding(5.dp).focusGroup()) {
                val glow = looks.palette.value.glow
                TvLooksRow(translated("Startseiten-Schein"), translated(glowName(glow)),
                           Modifier.alpha(if (wearable) 1f else 0.5f)) {
                    // Only what changes the look is locked for a look that may not be worn yet.
                    if (!wearable) return@TvLooksRow
                    val all = listOf("off", "soft", "bright")
                    val next = all[(all.indexOf(glow).coerceAtLeast(0) + 1) % all.size]
                    looks.change { if (next == look.defaultGlow) it.remove("glow") else it.put("glow", next) }
                }
                Box(Modifier.fillMaxWidth().height(1.dp).background(Theme.line))
                if (support.isSupporter) {
                    val accent = shown.optString("accent", look.accent.id)
                    Row(Modifier.fillMaxWidth().height(TvTheme.rowsHeight + 10.dp).padding(horizontal = 13.dp)
                            .alpha(if (wearable) 1f else 0.5f).focusGroup(),
                        verticalAlignment = Alignment.CenterVertically) {
                        Text(translated("Akzentfarbe"), style = TvTheme.body, color = Theme.font, modifier = Modifier.weight(1f))
                        Row(horizontalArrangement = Arrangement.spacedBy(9.dp)) {
                            looks.accents.forEach { a ->
                                val on = a.id == accent
                                FocusArea(Modifier.semantics { role = Role.RadioButton; selected = on; contentDescription = a.id },
                                          magnifier = TvTheme.focusMagnifier,
                                          perform = { if (wearable) looks.change { if (a.id == look.accent.id) it.remove("accent") else it.put("accent", a.id) } }) { _ ->
                                    Box(Modifier.size(28.dp).border(1.5.dp, if (on) Theme.font else Color.Transparent, CircleShape)
                                            .padding(3.dp).clip(CircleShape).background(a.main))
                                }
                            }
                        }
                    }
                } else {
                    TvLooksRow(translated("Akzentfarbe"), translated("Unterstützer werden")) { openSupport() }
                }
            }

            Box(Modifier.padding(top = 16.dp)) {
                if (wearable) TvButton(translated("Verwenden")) { looks.use(context); close() }
                else TvButton(translated("Unterstützer werden")) { if (looks.keep()) openSupport() else close() }
            }
        }
        }
    }
}

private fun glowName(glow: String) = when (glow) {
    "off" -> "Aus"
    "bright" -> "Kräftig"
    else -> "Sanft"
}

/** A row on the looks page's card (`RowsStyle`): name left, value quiet on the right. */
@Composable
private fun TvLooksRow(title: String, value: String, modifier: Modifier = Modifier, perform: () -> Unit) {
    FocusArea(modifier.fillMaxWidth(), magnifier = 1f, perform = perform) { focus ->
        Row(Modifier.fillMaxWidth().height(TvTheme.rowsHeight).clip(RoundedCornerShape(TvTheme.corner))
                .background(if (focus) TvTheme.focusArea else Color.Transparent).padding(horizontal = 13.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Text(title, style = TvTheme.body, color = Theme.font, maxLines = 1, modifier = Modifier.weight(1f))
            Spacer(Modifier.width(20.dp))
            Text(value, style = TvTheme.body, color = Theme.fontQuiet, maxLines = 1)
        }
    }
}

/**
 * **The real Home is not under this page, so a stand-in is** (`mock`): four poster tiles, two with
 * progress, the "Weiterschauen" pill, in the colors being tried.
 */
@Composable
private fun TvLooksMock(modifier: Modifier = Modifier) {
    Row(modifier.clip(RoundedCornerShape(TvTheme.cornerArea)).background(Theme.groupsArea.copy(alpha = 0.7f)).padding(12.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        repeat(4) { index ->
            Box(Modifier.size(100.dp, 56.dp).clip(RoundedCornerShape(TvTheme.cornerTile)).background(Theme.area)) {
                if (index < 2) Box(Modifier.align(Alignment.BottomStart).padding(8.dp)
                                       .size(if (index == 0) 55.dp else 30.dp, 3.dp).clip(CircleShape).background(Theme.accent))
            }
        }
        Box(Modifier.height(28.dp).clip(CircleShape).background(Theme.accent).padding(horizontal = 13.dp),
            contentAlignment = Alignment.Center) {
            Text(translated("Weiterschauen"), style = TvTheme.small, color = Theme.onAccent, maxLines = 1)
        }
    }
}

/**
 * A look in the row (`choice`): its tile 136 pt, a white ring 8 pt outside when chosen, a lock badge
 * when it cannot be worn, its name. `TileStyle`: focus magnifies. Halved.
 */
@Composable
private fun TvLookChoice(app: SwiftlyApplication, look: Looks.LookInfo, chosen: Boolean, locked: Boolean,
                         modifier: Modifier = Modifier, pick: () -> Unit) {
    val looks = app.looks
    FocusArea(modifier.width(82.dp).semantics(mergeDescendants = true) {
        role = Role.Button; this.selected = chosen
        contentDescription = look.name + if (locked) ", " + translated("Nur für Unterstützer") else ""
    }, magnifier = TvTheme.focusMagnifier, perform = pick) { _ ->
        Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(7.dp)) {
            Box(Modifier.size(76.dp), contentAlignment = Alignment.Center) {
                if (chosen) Box(Modifier.matchParentSize().border(2.dp, Theme.font, RoundedCornerShape((68 * 0.225f + 4).dp)))
                LookTileView(looks.tileIcon(look), 68.dp, Modifier.alpha(if (locked) 0.45f else 1f))
                if (locked) {
                    Box(Modifier.align(Alignment.BottomEnd).size(20.dp).clip(CircleShape).background(Theme.raised),
                        contentAlignment = Alignment.Center) {
                        Symbol(Glyph.Padlock, 10.dp, color = Theme.font, strength = Strength.Bold)
                    }
                }
            }
            Text(look.name, style = TvTheme.small.copy(textAlign = TextAlign.Center),
                 color = if (chosen) Theme.font else Theme.fontQuiet, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

// MARK: - Buy page (Play)

private const val TERMS_ADDRESS = "play.google.com/about/play-terms"
private const val PRIVACY_ADDRESS = "swiftlyplayer.com/privacy.html"

/** `column` of `TVSupportGrowView` (1040 pt), halved. */
internal val GrowColumn = 520.dp

/**
 * **"Hilf Swiftly zu wachsen" on the television** (`TVSupportGrowView`): one left-aligned column of
 * 520 dp. Top to bottom the three mini screens with "Look ausprobieren", the title, the two plans
 * side by side (badge on the edge, empty ring or accent check), the tips in one row with their
 * label, nothing preselected, the white buy button, the terms, "Wiederherstellen". Back closes. The
 * store's dialog (or, in Debug, the simulated purchase) does the rest; the thanks replaces this page.
 * A television has no browser, so the legal addresses stand as text. Every tvOS point halved.
 */
@Composable
fun TvGrowBody(app: SwiftlyApplication, close: () -> Unit, first: FocusRequester) {
    val support = app.support
    val activity = LocalContext.current.findActivity()
    val plans = support.channel.plans.value
    val offers = support.channel.offers.value
    var chosen by remember { mutableStateOf<String?>(null) }
    val price = (plans.map { it.productId to it.price } + offers.map { it.productId to it.price }).toMap()
    val monthly = plans.firstOrNull { it.plan == "monthly" }
    val lifetime = plans.firstOrNull { it.plan == "lifetime" }

    Column(Modifier.width(GrowColumn)) {
        TvLooksHero(app, Modifier.fillMaxWidth().padding(top = 18.dp)) { close(); tvLooksOpen(app) }
        Column(Modifier.padding(top = 12.dp, start = 10.dp, end = 10.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(translated("Hilf Swiftly zu wachsen"), style = TvTheme.titleLarge, color = Theme.font)
                Text("🌱", fontSize = 17.sp)
            }
            Text(translated("Dein Beitrag hält Swiftly am Laufen."), fontSize = 16.sp, color = Theme.font.copy(alpha = 0.9f))
            Text(translated("Open Source, keine Werbung, alles zum Schauen bleibt kostenlos."), fontSize = 13.sp, color = Theme.fontVeryQuiet)
        }

        if (support.channel.pricesUnavailable.value) {
            Column(Modifier.padding(top = 14.dp).fillMaxWidth().clip(RoundedCornerShape(TvTheme.cornerTile))
                       .background(Theme.groupsArea).padding(15.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(translated("Preise sind gerade nicht verfügbar"), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Theme.font)
                Text(translated("Google Play hat nicht geantwortet. Das passiert ohne Internet oder wenn Käufe auf deinem Konto eingeschränkt sind. Nichts geht verloren, und Swiftly läuft wie immer."),
                     fontSize = 13.sp, color = Theme.fontQuiet)
                TvButton(translated("Google Play erneut fragen"), modifier = Modifier.padding(top = 4.dp).focusRequester(first)) {
                    support.channel.connect(); support.channel.refresh()
                }
            }
        } else {
            if (monthly != null || lifetime != null) {
                Row(Modifier.padding(top = 13.dp).focusGroup().height(IntrinsicSize.Max), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    monthly?.let {
                        TvPlanTile(translated("Beliebt"), true, translated("Monatlich"), it.price, translated("im Monat · jederzeit kündbar"),
                                   chosen == it.productId, Modifier.weight(1f).fillMaxHeight().focusRequester(first)) { chosen = it.productId }
                    }
                    lifetime?.let {
                        TvPlanTile(translated("Guter Deal"), false, translated("Für immer"), it.price, translated("einmal zahlen · wie 10 Monate"),
                                   chosen == it.productId, Modifier.weight(1f).fillMaxHeight().then(if (monthly == null) Modifier.focusRequester(first) else Modifier)) { chosen = it.productId }
                    }
                }
            }
            if (offers.isNotEmpty()) {
                Row(Modifier.padding(top = 8.dp).focusGroup(), verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                    Text(translated("Einfach Danke ☕"), fontSize = 12.sp, color = Theme.fontVeryQuiet, maxLines = 1,
                         modifier = Modifier.padding(end = 3.dp))
                    support.tips.forEach { tip ->
                        val offer = offers.firstOrNull { it.productId == tip.productId } ?: return@forEach
                        TvTipCapsule(if (offer.owned) translated("Danke") else offer.price, chosen == tip.productId,
                                     released = !offer.owned, Modifier.weight(1f)) { chosen = tip.productId }
                    }
                }
            }
        }

        val label = when (chosen) {
            null -> translated("Wähl eine Option")
            monthly?.productId -> translated("Für %@ im Monat unterstützen", price[chosen].orEmpty())
            lifetime?.productId -> translated("Mit %@ unterstützen", price[chosen].orEmpty())
            else -> translated("Mit %@ Danke sagen", price[chosen].orEmpty())
        }
        Column(Modifier.fillMaxWidth().padding(top = 12.dp), horizontalAlignment = Alignment.CenterHorizontally,
               verticalArrangement = Arrangement.spacedBy(7.dp)) {
            TvBuyButton(label, chosen != null && activity != null) {
                val id = chosen ?: return@TvBuyButton
                activity?.let { support.channel.buy(it, id) }
            }
            Text("${translated("Nutzungsbedingungen")}: $TERMS_ADDRESS  ·  ${translated("Datenschutz")}: $PRIVACY_ADDRESS",
                 fontSize = 11.sp, textAlign = TextAlign.Center, color = Theme.fontVeryQuiet, modifier = Modifier.padding(top = 2.dp))
            TvLinkButton(translated("Wiederherstellen")) { support.channel.refresh() }
        }
    }
}

/** The pill under the mini screens (`TVPillStyle`): dark with a thin edge, white when focused. */
@Composable
private fun TvPill(text: String, perform: () -> Unit) {
    FocusArea(Modifier.semantics { role = Role.Button }, magnifier = TvTheme.focusMagnifier, lift = true, liftCorner = 100.dp,
              perform = perform) { focus ->
        Row(Modifier.height(36.dp).clip(CircleShape)
                .background(if (focus) Color.White else Color(0xFF292929).copy(alpha = 0.92f))
                .border(1.dp, Theme.font.copy(alpha = if (focus) 0f else 0.14f), CircleShape).padding(horizontal = 17.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(text, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = if (focus) Theme.reason else Theme.font, maxLines = 1)
            Symbol(Glyph.AngleRight, 11.dp, color = if (focus) Theme.reason else Theme.font, strength = Strength.Bold)
        }
    }
}

/** `TVLooksHero`: three small 16:9 Start pages in three looks, the pill in its own row below. */
@Composable
internal fun TvLooksHero(app: SwiftlyApplication, modifier: Modifier, tryLooks: () -> Unit) {
    val looks = app.looks
    val palettes = remember {
        listOf(looks.paletteFor("""{"look":"original","glow":"soft"}"""),
               looks.paletteFor("""{"look":"neonNight"}"""),
               looks.paletteFor("""{"look":"neonNight","accent":"coral"}"""))
    }
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            palettes.forEach { p ->
                // Drawn at 128 x 72 and shown at 104 x 58.5 (208 / 256).
                Box(Modifier.size(104.dp, 58.5.dp)) {
                    Box(Modifier.requiredSize(128.dp, 72.dp).graphicsLayer { scaleX = 208f / 256f; scaleY = 208f / 256f }) {
                        TvMiniScreen(p)
                    }
                }
            }
        }
        TvPill(translated("Look ausprobieren"), tryLooks)
    }
}

/** `TVMiniScreen`: a 256 x 144 pt Start page in a look, here 128 x 72 dp (points halved). */
@Composable
private fun TvMiniScreen(palette: Looks.Palette) {
    val accent = palette.accent.main
    val shape = RoundedCornerShape(5.dp)
    Box(Modifier.size(128.dp, 72.dp).clip(shape).background(Theme.reason).border(0.5.dp, Theme.font.copy(alpha = 0.12f), shape)
            .drawBehind {
                ellipseGradient(Offset(size.width * 0.62f, size.height * 0.3f), size.width * 0.6f, size.height * 0.6f,
                                0f to accent.copy(alpha = 0.32f), 1f to accent.copy(alpha = 0f))
            }) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 5.5.dp).offset(y = 5.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(3.5.dp)) {
            Box(Modifier.padding(end = 1.5.dp)) {
                Wordmark(height = 3.5.dp, accent = palette.logoGradient.firstOrNull() ?: accent,
                         gradient = palette.logoGradient.takeIf { it.size > 1 })
            }
            repeat(4) { i ->
                Box(Modifier.size(if (i == 0) 7.dp else 8.dp, 1.25.dp).clip(CircleShape)
                        .background(Theme.font.copy(alpha = if (i == 0) 1f else 0.35f)))
            }
            Spacer(Modifier.weight(1f))
            Box(Modifier.size(3.5.dp).clip(CircleShape).background(accent))
        }
        Column(Modifier.offset(5.5.dp, 16.dp), verticalArrangement = Arrangement.spacedBy(1.5.dp)) {
            Box(Modifier.size(26.dp, 3.dp).clip(CircleShape).background(Theme.font))
            Box(Modifier.size(18.dp, 1.25.dp).clip(CircleShape).background(Theme.font.copy(alpha = 0.45f)))
            Box(Modifier.padding(top = 1.dp).size(45.dp, 1.25.dp).clip(CircleShape).background(Theme.font.copy(alpha = 0.3f)))
        }
        Column(Modifier.offset(5.5.dp, 39.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Box(Modifier.size(15.dp, 1.5.dp).clip(CircleShape).background(Theme.font.copy(alpha = 0.8f)))
            Row(horizontalArrangement = Arrangement.spacedBy(2.5.dp)) {
                repeat(4) { i ->
                    val tile = RoundedCornerShape(1.5.dp)
                    Box(Modifier.size(27.dp, 15.5.dp).clip(tile).background(Brush.verticalGradient(listOf(Theme.raised, Theme.area)))
                            .then(if (i == 0) Modifier.border(0.5.dp, Theme.font.copy(alpha = 0.7f), tile) else Modifier)) {
                        if (i == 0) Box(Modifier.align(Alignment.BottomStart).size(11.dp, 1.dp).background(accent))
                    }
                }
            }
        }
    }
}

/** One plan (`planTile`): title, price, terms, left-aligned; badge on the top edge; ring or check at the top right. */
@Composable
private fun TvPlanTile(badge: String, loud: Boolean, title: String, price: String, detail: String, chosen: Boolean,
                       modifier: Modifier, choose: () -> Unit) {
    val shape = RoundedCornerShape(TvTheme.cornerTile)
    FocusArea(modifier.semantics(mergeDescendants = true) { role = Role.Button; selected = chosen },
              magnifier = TvTheme.focusMagnifier, perform = choose) { _ ->
        Box(Modifier.fillMaxSize()) {
            Column(Modifier.fillMaxSize().clip(shape).background(Theme.area)
                    .then(if (chosen) Modifier.border(2.dp, Theme.accent, shape) else Modifier).padding(14.dp).heightIn(min = 56.dp),
                   verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(title, fontSize = 14.sp, color = Theme.fontQuiet, maxLines = 1, modifier = Modifier.padding(top = 7.dp))
                Text(price, fontSize = 26.sp, fontWeight = FontWeight.Bold, color = Theme.font, maxLines = 1,
                     style = TextStyle(fontFeatureSettings = "tnum"), modifier = Modifier.padding(top = 3.dp))
                Text(detail, fontSize = 12.sp, color = Theme.fontVeryQuiet, maxLines = 1)
            }
            // Empty ring, or the accent check.
            Box(Modifier.align(Alignment.TopEnd).padding(13.dp).size(20.dp), contentAlignment = Alignment.Center) {
                if (chosen) Box(Modifier.fillMaxSize().clip(CircleShape).background(Theme.accent), contentAlignment = Alignment.Center) {
                    Symbol(Glyph.Checkmark, 10.dp, color = Theme.onAccent, strength = Strength.Bold)
                } else Box(Modifier.fillMaxSize().border(1.5.dp, Theme.font.copy(alpha = 0.25f), CircleShape))
            }
            Box(Modifier.offset(14.dp, (-9).dp).height(19.dp).clip(CircleShape)
                    .background(if (loud) Theme.font else Theme.pressedArea).padding(horizontal = 8.dp),
                contentAlignment = Alignment.Center) {
                Text(badge.uppercase(), fontSize = 10.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.4.sp, maxLines = 1,
                     color = if (loud) Color(0xFF0A0A0A) else Theme.font)
            }
        }
    }
}

/** A tip (`tips`): a capsule of at least 40 dp with the price, the accent ring when chosen. */
@Composable
private fun TvTipCapsule(text: String, chosen: Boolean, released: Boolean, modifier: Modifier, choose: () -> Unit) {
    FocusArea(modifier.semantics(mergeDescendants = true) { role = Role.Button; selected = chosen },
              magnifier = TvTheme.focusMagnifier, perform = { if (released) choose() }) { _ ->
        Box(Modifier.fillMaxWidth().heightIn(min = 40.dp).clip(CircleShape).background(Theme.area)
                .then(if (chosen) Modifier.border(2.dp, Theme.accent, CircleShape) else Modifier),
            contentAlignment = Alignment.Center) {
            Text(text, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = if (released) Theme.font else Theme.fontQuiet,
                 maxLines = 1, style = TextStyle(fontFeatureSettings = "tnum"))
        }
    }
}

/** `TVBuyStyle`: the big white purchase button, muted when it cannot be used; focus lifts it. */
@Composable
private fun TvBuyButton(text: String, released: Boolean, perform: () -> Unit) {
    FocusArea(Modifier.fillMaxWidth().semantics { role = Role.Button }, magnifier = TvTheme.focusMagnifier, lift = true,
              liftCorner = TvTheme.corner, perform = { if (released) perform() }) { _ ->
        Box(Modifier.fillMaxWidth().height(44.dp).clip(RoundedCornerShape(TvTheme.corner))
                .background(if (released) Color.White else Theme.area), contentAlignment = Alignment.Center) {
            Text(text, style = TvTheme.button, maxLines = 1, color = if (released) Color(0xFF0A0A0A) else Theme.fontVeryQuiet)
        }
    }
}

/** `TVLinkStyle`: a quiet underlined text link; focus puts a white capsule behind it. */
@Composable
private fun TvLinkButton(text: String, perform: () -> Unit) {
    FocusArea(Modifier.semantics { role = Role.Button }, magnifier = TvTheme.focusMagnifier, perform = perform) { focus ->
        Box(Modifier.height(30.dp).clip(CircleShape).background(if (focus) Color.White else Color.Transparent)
                .padding(horizontal = 14.dp), contentAlignment = Alignment.Center) {
            Text(text, fontSize = 13.sp, fontWeight = FontWeight.Medium, textDecoration = TextDecoration.Underline,
                 color = if (focus) Theme.reason else Theme.fontQuiet, maxLines = 1)
        }
    }
}

// MARK: - Thanks

/** The thanks (`thanks` in `TVSupportGrowView`): the worn look's tile, "Danke, Name", what happened, two buttons. */
@Composable
fun TvThanksBody(app: SwiftlyApplication, first: FocusRequester, close: () -> Unit, home: () -> Unit) {
    val looks = app.looks
    val look = looks.info(looks.palette.value.look)
    val name = app.username().takeIf { it != "?" }.orEmpty()
    // A tip is a thank-you only: nothing is unlocked, so nothing is promised.
    val tipOnly = !app.support.isSupporter
    LookTileView(looks.tileIcon(look), 90.dp)
    Text(if (name.isNotEmpty()) translated("Danke, %@ 🫶", name) else translated("Danke 🫶"),
         style = TvTheme.titleLarge, color = Theme.font, modifier = Modifier.padding(top = 18.dp))
    Text(if (tipOnly) translated("Du hast Swiftly gerade beim Weitermachen geholfen. Freigeschaltet wird dafür nichts, es ist einfach nur Danke.")
         else if (look.id != "original") translated("Du hast Swiftly gerade beim Weitermachen geholfen. %@ ist an, dein Icon und Logo auch. Schau dich um.", look.name)
         else translated("Du hast Swiftly gerade beim Weitermachen geholfen. Looks und Icons gehören jetzt dir. Schau dich um."),
         style = TvTheme.body.copy(textAlign = TextAlign.Center), color = Theme.fontQuiet,
         modifier = Modifier.padding(top = 6.dp).widthIn(max = 550.dp))
    if (!tipOnly) Text(translated("Looks kannst du jederzeit im Profil wechseln."), style = TvTheme.small.copy(textAlign = TextAlign.Center),
         color = Theme.fontVeryQuiet, modifier = Modifier.padding(top = 7.dp))
    Row(Modifier.padding(top = 24.dp).focusGroup(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        if (!tipOnly) {
            TvButton(translated("Zeig mir meine Startseite"), modifier = Modifier.focusRequester(first)) { home() }
            TvButton(translated("Fertig"), perform = close)
        } else TvButton(translated("Fertig"), modifier = Modifier.focusRequester(first), perform = close)
    }
}
