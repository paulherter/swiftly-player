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
    FocusArea(modifier.fillMaxWidth().semantics(mergeDescendants = true) { role = Role.Button },
              magnifier = 1f, perform = { tvLooksOpen(app) }) { focus ->
        Row(Modifier.fillMaxWidth().heightIn(min = TvTheme.rowsHeight).clip(RoundedCornerShape(TvTheme.corner))
                .background(if (focus) TvTheme.focusArea else Color.Transparent).padding(horizontal = 13.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            LookTileView(looks.tileIcon(saved), 26.dp)
            when (entry) {
                "current" -> {
                    Text(saved.name, style = TvTheme.body, color = Theme.font, maxLines = 1,
                         overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                    Text(translated("Ändern"), style = TvTheme.body, color = Theme.accent, maxLines = 1)
                }
                "teaser" -> {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                        Text(translated("Wähl deinen Look"), style = TvTheme.body, color = Theme.font, maxLines = 1)
                        Text(translated("Looks und Icons für alle, die Swiftly am Laufen halten."), style = TvTheme.small,
                             color = Theme.fontQuiet, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    Symbol(Glyph.AngleRight, 12.dp, color = Theme.fontVeryQuiet, strength = Strength.Semibold)
                }
                else -> {
                    Text(translated("Looks"), style = TvTheme.body, color = Theme.font, maxLines = 1, modifier = Modifier.weight(1f))
                    Symbol(Glyph.AngleRight, 12.dp, color = Theme.fontVeryQuiet, strength = Strength.Semibold)
                }
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

/**
 * **"Hilf Swiftly zu wachsen" on the television** (`TVSupportGrowView`): one column, top to bottom
 * the title, "Look ausprobieren", the two plans side by side, the tips as capsules, nothing
 * preselected, the buy button, the terms, "Wiederherstellen". Back closes. The store's dialog (or,
 * in Debug, the simulated purchase) does the rest; the thanks replaces this page. A television has
 * no browser, so the legal addresses stand as text. Every tvOS point halved.
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

    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
        Text(translated("Hilf Swiftly zu wachsen"), style = TvTheme.titleLarge, color = Theme.font)
        Text("🌱", style = TvTheme.titleLarge)
    }
    Text(translated("Dein Beitrag hält Swiftly am Laufen."), style = TvTheme.body.copy(textAlign = TextAlign.Center),
         color = Theme.fontQuiet, modifier = Modifier.padding(top = 5.dp))
    Text(translated("Open Source, keine Werbung, alles zum Schauen bleibt kostenlos."),
         style = TvTheme.small.copy(textAlign = TextAlign.Center), color = Theme.fontVeryQuiet, modifier = Modifier.padding(top = 2.dp))

    TvButton(translated("Look ausprobieren"), Glyph.AngleRight, symbolToText = true, modifier = Modifier.padding(top = 18.dp)) {
        close()
        tvLooksOpen(app)
    }

    if (support.channel.pricesUnavailable.value) {
        Text(translated("Preise sind gerade nicht verfügbar"), style = TvTheme.body, color = Theme.font, modifier = Modifier.padding(top = 18.dp))
        Text(translated("Google Play hat nicht geantwortet. Das passiert ohne Internet oder wenn Käufe auf deinem Konto eingeschränkt sind. Nichts geht verloren, und Swiftly läuft wie immer."),
             style = TvTheme.small.copy(textAlign = TextAlign.Center), color = Theme.fontQuiet,
             modifier = Modifier.padding(top = 4.dp).widthIn(max = 550.dp))
        TvButton(translated("Google Play erneut fragen"), modifier = Modifier.padding(top = 8.dp).focusRequester(first)) {
            support.channel.connect(); support.channel.refresh()
        }
    }
    if (monthly != null || lifetime != null) {
        Row(Modifier.padding(top = 18.dp).focusGroup(), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            monthly?.let {
                TvPlanTile(translated("Beliebt"), translated("Monatlich"), it.price, translated("im Monat · jederzeit kündbar"),
                           chosen == it.productId, Modifier.focusRequester(first)) { chosen = it.productId }
            }
            lifetime?.let {
                TvPlanTile(translated("Guter Deal"), translated("Für immer"), it.price, translated("einmal zahlen · wie 10 Monate"),
                           chosen == it.productId, if (monthly == null) Modifier.focusRequester(first) else Modifier) { chosen = it.productId }
            }
        }
    }
    if (offers.isNotEmpty()) {
        Column(Modifier.padding(top = 14.dp), horizontalAlignment = Alignment.CenterHorizontally,
               verticalArrangement = Arrangement.spacedBy(7.dp)) {
            Text(translated("Einfach Danke ☕"), style = TvTheme.small, color = Theme.fontVeryQuiet)
            Row(Modifier.focusGroup(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                support.tips.forEach { tip ->
                    val offer = offers.firstOrNull { it.productId == tip.productId } ?: return@forEach
                    TvTipCapsule(if (offer.owned) translated("Danke") else offer.price, chosen == tip.productId,
                                 released = !offer.owned) { chosen = tip.productId }
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
    TvButton(label, released = chosen != null && activity != null, modifier = Modifier.padding(top = 14.dp)) {
        val id = chosen ?: return@TvButton
        activity?.let { support.channel.buy(it, id) }
    }
    Text("${translated("Nutzungsbedingungen")}: $TERMS_ADDRESS  ·  ${translated("Datenschutz")}: $PRIVACY_ADDRESS",
         style = TvTheme.small.copy(textAlign = TextAlign.Center), color = Theme.fontVeryQuiet,
         modifier = Modifier.padding(top = 12.dp).widthIn(max = 550.dp))
    TvButton(translated("Wiederherstellen"), modifier = Modifier.padding(top = 10.dp)) { support.channel.refresh() }
}

/** One plan (`planTile`): badge, title, price, terms, centered; chosen is the accent ring. 440 pt wide, halved. */
@Composable
private fun TvPlanTile(badge: String, title: String, price: String, detail: String, chosen: Boolean,
                       modifier: Modifier, choose: () -> Unit) {
    val shape = RoundedCornerShape(TvTheme.cornerTile)
    FocusArea(modifier.width(220.dp).semantics(mergeDescendants = true) { role = Role.Button; selected = chosen },
              magnifier = TvTheme.focusMagnifier, perform = choose) { _ ->
        Column(Modifier.fillMaxWidth().clip(shape).background(Theme.area)
                .border(2.dp, if (chosen) Theme.accent else Color.Transparent, shape).padding(12.dp),
               horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(badge, style = TvTheme.small, color = Theme.fontQuiet, maxLines = 1)
            Text(title, style = TvTheme.button, color = Theme.font, maxLines = 1)
            Text(price, style = TvTheme.categoryLarge.copy(fontFeatureSettings = "tnum"), color = Theme.font, maxLines = 1)
            Text(detail, style = TvTheme.small, color = Theme.fontQuiet, maxLines = 1)
        }
    }
}

/** A tip (`tips`): a 200 by 84 pt capsule with the price, the accent ring when chosen. Halved. */
@Composable
private fun TvTipCapsule(text: String, chosen: Boolean, released: Boolean, choose: () -> Unit) {
    FocusArea(Modifier.semantics(mergeDescendants = true) { role = Role.Button; selected = chosen },
              magnifier = TvTheme.focusMagnifier, perform = { if (released) choose() }) { _ ->
        Box(Modifier.size(100.dp, 42.dp).clip(CircleShape).background(Theme.area)
                .border(2.dp, if (chosen) Theme.accent else Color.Transparent, CircleShape),
            contentAlignment = Alignment.Center) {
            Text(text, style = TvTheme.button, color = if (released) Theme.font else Theme.fontQuiet, maxLines = 1)
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
