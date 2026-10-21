package de.paulherter.swiftly.support

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.BuildConfig
import de.paulherter.swiftly.SheetRequest
import de.paulherter.swiftly.SwiftlyApplication
import de.paulherter.swiftly.ToggleSwitch
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Strength
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import de.paulherter.swiftly.tapOn
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import org.json.JSONObject

// MARK: - The looks panel

/** The sheets' side margin (`Theme.sheetInset`). */
private val SheetInset = 24.dp

/** Android's handle takes 13 dp at the top of every sheet; iOS lays its grabber over the content. */
private val HandleSpace = 13.dp

/**
 * **One looks panel for everything** (profile "Ändern", "Look ausprobieren", Settings, the gift):
 * a strip with every look, what can be changed on it, and one button. A look this person may not
 * wear is only tried on; nothing is stored until the support came through. Rules: `Looks`
 * (the package's `LookTryOn`). Like on iPhone it lies over the home page **without a scrim**, with
 * the look's light at its top, so every change is seen at once.
 */
fun looksPanelShow(app: SwiftlyApplication, tryLook: String? = null) {
    app.sheet.value = SheetRequest(translated("Wähl deinen Look"), emptyList(), null, dimmed = false, heading = false,
        backdrop = { val p = app.looks.palette.value; CardLightBackdrop(p.glowColor, p.glowTint) },
        content = { close -> LooksPanel(app, tryLook, close) }) { }
}

@Composable
private fun LooksPanel(app: SwiftlyApplication, tryLook: String?, close: () -> Unit) {
    val looks = app.looks
    val context = LocalContext.current
    DisposableEffect(Unit) { onDispose { looks.panelClosed(context) } }
    LaunchedEffect(tryLook) { if (tryLook != null) looks.pick(looks.switching(tryLook)) }

    val shown = JSONObject(looks.shown.value)
    val look = looks.info(shown.optString("look", "original"))
    val wearable = looks.mayWear(shown)
    val owned = looks.owned.value
    val list = looks.catalog.filter { !it.isGift || it.id in owned || looks.giftAvailable(it.id) }

    Column(Modifier.fillMaxWidth().heightIn(max = 720.dp).verticalScroll(rememberScrollState())) {
        Box(Modifier.fillMaxWidth()) {
            Text(translated("Wähl deinen Look"), style = giftFont(17f, FontWeight.SemiBold), color = Theme.font,
                 modifier = Modifier.padding(start = SheetInset, end = SheetInset + 40.dp).padding(top = 26.dp - HandleSpace)
                     .semantics { heading() })
            LookCloseButton(Modifier.align(Alignment.TopEnd).padding(top = 14.dp - HandleSpace, end = 10.dp), action = close)
        }

        // The strip runs to the sheet's edges; its first look starts on the margin, the chosen one is in view.
        val strip = rememberLazyListState()
        val density = LocalDensity.current
        LaunchedEffect(Unit) {
            val index = list.indexOfFirst { it.id == look.id }.coerceAtLeast(0)
            val width = snapshotFlow { strip.layoutInfo.viewportSize.width }.first { it > 0 }
            with(density) {
                val center = SheetInset.toPx() + index * (68.dp + 6.dp).toPx() + 34.dp.toPx()
                strip.scrollBy(center - width / 2f)
            }
        }
        LazyRow(Modifier.fillMaxWidth().padding(top = 12.dp), state = strip,
                contentPadding = PaddingValues(start = SheetInset, end = SheetInset, top = 6.dp, bottom = 2.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            items(list, key = { it.id }) { item ->
                val allowed = looks.mayWear(JSONObject(looks.switching(item.id))) || (item.isGift && item.id !in owned)
                LookChoice(looks, item, chosen = item.id == look.id, locked = !allowed) {
                    if (item.id == look.id) return@LookChoice
                    // A gift not picked up yet: picking it here picks it up.
                    if (item.isGift && item.id !in owned) looks.claim(item.id, context)
                    else looks.pick(looks.switching(item.id))
                }
            }
        }

        Settings(app, shown, look, wearable)

        Box(Modifier.padding(horizontal = SheetInset).padding(top = 16.dp, bottom = 16.dp)) {
            if (wearable) GiftButton(translated("Verwenden"), primary = true) { looks.use(context); close() }
            else GiftButton(translated("Unterstützer werden"), primary = true) {
                if (looks.keep()) {
                    looks.supportOpening = true
                    supportSheetShow(app, fromLooks = true)
                } else close()
            }
        }
    }
}

/** **The settings under the strip: always the same rows, 52 high**, greyed while a look is only tried on. */
@Composable
private fun Settings(app: SwiftlyApplication, shown: JSONObject, look: Looks.LookInfo, wearable: Boolean) {
    val looks = app.looks
    Column(Modifier.padding(horizontal = SheetInset).padding(top = 14.dp).fillMaxWidth()
            .clip(RoundedCornerShape(Theme.cornerArea)).background(Theme.raised.copy(alpha = 0.6f))
            .alpha(if (wearable) 1f else 0.5f)) {
        val rows = Modifier.fillMaxWidth().heightIn(min = 52.dp).padding(horizontal = 16.dp)
        if (looks.seasonActive(look)) {
            ToggleLine(translated("Fledermäuse und Spinnennetz"), looks.effectsOn.value, wearable, rows) { looks.setEffects(it) }
            Divider()
        }
        ToolLine(translated("Startseiten-Schein"), rows) {
            val current = shown.optString("glow", look.defaultGlow)
            Segments(listOf("off" to translated("Aus"), "soft" to translated("Sanft"), "bright" to translated("Kräftig")), current) { glow ->
                if (wearable) looks.change { if (glow == look.defaultGlow) it.remove("glow") else it.put("glow", glow) }
            }
        }
        Divider()
        val hasIcon = look.iconName != null
        Box(Modifier.alpha(if (hasIcon) 1f else 0.45f)) {
            ToggleLine(translated("App-Icon zum Look"), hasIcon && shown.optBoolean("icon", true), wearable && hasIcon, rows) { on ->
                looks.change { if (on) it.remove("icon") else it.put("icon", false) }
            }
        }
        Divider()
        ToolLine(translated("Akzentfarbe"), rows) {
            if (app.support.isSupporter) {
                AccentDots(looks.accents, shown.optString("accent", look.accent.id)) { accent ->
                    if (wearable) looks.change { if (accent.id == look.accent.id) it.remove("accent") else it.put("accent", accent.id) }
                }
            } else {
                Box(Modifier.heightIn(min = 44.dp).tapOn { if (wearable) supportSheetShow(app) }, contentAlignment = Alignment.Center) {
                    Box(Modifier.height(32.dp).background(Theme.area, CircleShape).padding(horizontal = 12.dp), contentAlignment = Alignment.Center) {
                        Text(translated("Unterstützer werden"), style = giftFont(13f, FontWeight.SemiBold), color = Theme.font, maxLines = 1)
                    }
                }
            }
        }
    }
}

@Composable
private fun Divider() {
    Box(Modifier.padding(start = 16.dp).fillMaxWidth().height(1.dp).background(Theme.line))
}

@Composable
private fun ToolLine(title: String, modifier: Modifier, trailing: @Composable () -> Unit) {
    Row(modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(title, style = giftFont(15f, FontWeight.SemiBold), color = Theme.font, maxLines = 1, modifier = Modifier.weight(1f))
        trailing()
    }
}

@Composable
private fun ToggleLine(title: String, on: Boolean, enabled: Boolean, modifier: Modifier, change: (Boolean) -> Unit) {
    Row(modifier.then(if (enabled) Modifier.toggleable(on, remember { MutableInteractionSource() }, null, role = Role.Switch, onValueChange = change) else Modifier),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(title, style = giftFont(15f, FontWeight.SemiBold), color = Theme.font, maxLines = 1, modifier = Modifier.weight(1f))
        ToggleSwitch(on) { if (enabled) change(it) }
    }
}

/** **One look in the strip** (`LookChoice`): 68 wide, the tile 56, a ring when chosen, a lock when it cannot be worn. */
@Composable
private fun LookChoice(looks: Looks, look: Looks.LookInfo, chosen: Boolean, locked: Boolean, pick: () -> Unit) {
    val lockedText = translated("Nur für Unterstützer")
    Column(Modifier.width(68.dp).tapOn(pick)
            .semantics(mergeDescendants = true) {
                role = Role.RadioButton; selected = chosen
                contentDescription = if (locked) "${look.name}, $lockedText" else look.name
            },
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(Modifier.size(56.dp)) {
            LookTileView(looks.tileIcon(look), 56.dp, Modifier.alpha(if (locked) 0.45f else 1f))
            if (chosen) Box(Modifier.requiredSize(64.dp).align(Alignment.Center).border(2.dp, Theme.font, RoundedCornerShape(17.dp)))
            if (locked) {
                Box(Modifier.align(Alignment.BottomEnd).offset(4.dp, 4.dp).size(20.dp).background(Theme.raised, CircleShape),
                    contentAlignment = Alignment.Center) {
                    Symbol(Glyph.Padlock, 10.dp, color = Theme.font, strength = Strength.Bold, filled = true)
                }
            }
        }
        Text(look.name, style = giftFont(12f, if (chosen) FontWeight.SemiBold else FontWeight.Normal).copy(textAlign = TextAlign.Center),
             color = if (chosen) Theme.font else Theme.fontQuiet, maxLines = 1,
             modifier = Modifier.alpha(if (locked) 0.6f else 1f).padding(horizontal = 2.dp))
    }
}

// MARK: - Gift and what's new

/** "Ein Look für dich" (`GiftOffer`): the offer in the look's own light; "Hol ihn dir" takes it and opens the panel. */
fun giftOfferShow(app: SwiftlyApplication, look: Looks.LookInfo) {
    val light = app.looks.paletteFor("""{"look":"${look.id}"}""")
    app.sheet.value = SheetRequest(translated("Ein Look für dich 🎃"), emptyList(), null, dimmed = false, heading = false,
        backdrop = { CardLightBackdrop(light.glowColor, light.glowTint) },
        content = { close -> GiftOffer(app, look, close) }) { }
}

@Composable
private fun GiftOffer(app: SwiftlyApplication, look: Looks.LookInfo, close: () -> Unit) {
    val looks = app.looks
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    Box(Modifier.fillMaxWidth()) {
        Column(Modifier.fillMaxWidth().padding(horizontal = SheetInset).padding(bottom = 16.dp)) {
            LookTileView(looks.tileIcon(look), 76.dp, Modifier.padding(top = 36.dp - HandleSpace))
            Text(translated("Ein Look für dich 🎃"), style = giftFont(24f, FontWeight.SemiBold), color = Theme.font,
                 modifier = Modifier.padding(top = 20.dp).semantics { heading() })
            Text(translated("Danke, dass du Swiftly benutzt. %@ ist ein Geschenk an alle.", look.name),
                 style = giftFont(15f).copy(lineHeight = 21.sp), color = Theme.fontQuiet, modifier = Modifier.padding(top = 8.dp))
            Text(translated("Bleibt für immer in deiner Sammlung."), style = giftFont(13f), color = Theme.fontVeryQuiet,
                 modifier = Modifier.padding(top = 6.dp))
            Column(Modifier.padding(top = 20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                GiftButton(translated("Hol ihn dir"), primary = true) {
                    looks.claim(look.id, context)
                    close()
                    scope.launch { delay(350); looksPanelShow(app) }
                }
                GiftButton(translated("Nicht jetzt"), primary = false, action = close)
            }
        }
        LookCloseButton(Modifier.align(Alignment.TopEnd).padding(top = 14.dp - HandleSpace, end = 10.dp), action = close)
    }
}

/** "Neu in Version x": the shipped entry, three to five lines, one button; carries the gift when it has one. */
fun whatsNewShow(app: SwiftlyApplication, entry: JSONObject) {
    val p = app.looks.palette.value
    app.sheet.value = SheetRequest(translated("Neu in Version %@", entry.optString("version")), emptyList(), null, heading = false,
        backdrop = { CardLightBackdrop(p.glowColor, p.glowTint) },
        content = { close -> WhatsNewBody(app, entry, close) }) { }
}

private fun JSONObject.localized(key: String): String {
    val o = optJSONObject(key) ?: return ""
    val language = if (java.util.Locale.getDefault().language == "de") "de" else "en"
    return o.optString(language, o.optString("en"))
}

@Composable
private fun WhatsNewBody(app: SwiftlyApplication, entry: JSONObject, close: () -> Unit) {
    val looks = app.looks
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val giftId = entry.optJSONObject("module")?.takeIf { it.optString("type") == "gift" }?.optString("lookId").orEmpty()
    val gift = if (giftId.isNotEmpty() && looks.giftAvailable(giftId) && giftId !in looks.owned.value) looks.info(giftId) else null
    val items = entry.optJSONArray("items")
    val label = entry.optJSONObject("primary")?.optString("label").orEmpty()
    Column(Modifier.heightIn(max = 680.dp).verticalScroll(rememberScrollState()).padding(horizontal = SheetInset).padding(top = 36.dp - HandleSpace)) {
        Text(entry.localized("title"), style = Theme.titleLarge.copy(fontSize = 26.sp), color = Theme.font)
        Column(Modifier.padding(top = 24.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
            for (i in 0 until (items?.length() ?: 0)) {
                val item = items!!.getJSONObject(i)
                Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(28.dp), contentAlignment = Alignment.Center) {
                        Symbol(whatsNewGlyph(item.optString("symbol")), 19.dp, color = Theme.fontQuiet)
                    }
                    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        Text(item.localized("title"), style = Theme.listTitle, color = Theme.font)
                        val detail = item.localized("detail")
                        if (detail.isNotEmpty()) Text(detail, style = Theme.small.copy(fontSize = 13.sp), color = Theme.fontVeryQuiet)
                    }
                }
            }
        }
        if (gift != null) {
            Row(Modifier.fillMaxWidth().padding(top = 24.dp).clip(RoundedCornerShape(14.dp)).background(Theme.raised.copy(alpha = 0.6f)).padding(14.dp),
                horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
                LookTileView(looks.tileIcon(gift), 44.dp)
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(gift.name, style = Theme.listTitle, color = Theme.font)
                    Text(translated("Geschenk, bleibt für immer in deiner Sammlung"), style = Theme.small.copy(fontSize = 13.sp), color = Theme.fontVeryQuiet)
                }
            }
        }
        Column(Modifier.fillMaxWidth().padding(top = 24.dp, bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            val grab = gift != null && label == "grab"
            val text = when {
                grab -> translated("Hol ihn dir")
                label == "try" -> translated("Ausprobieren")
                label == "tryLook" -> translated("Look ausprobieren")
                else -> translated("Verstanden")
            }
            GiftButton(text, primary = true) {
                close()
                when {
                    grab -> { looks.claim(gift!!.id, context); scope.launch { delay(350); looksPanelShow(app) } }
                    label == "try" || label == "tryLook" -> scope.launch { delay(350); looksPanelShow(app) }
                }
            }
            if (gift != null) GiftButton(translated("Nicht jetzt"), primary = false, action = close)
        }
    }
}

/** The shipped entries name SF Symbols; the closest glyphs here. */
private fun whatsNewGlyph(symbol: String): Glyph = when {
    symbol.startsWith("app") -> Glyph.AppIcon
    symbol.startsWith("heart") -> Glyph.Heart
    symbol.startsWith("paintpalette") -> Glyph.Palette
    symbol.startsWith("sparkle") -> Glyph.Funkeln
    else -> Glyph.Checkmark
}

/**
 * **Asks for the gift or the news, once per session, calmly.** A few seconds after the home page
 * is ready, never during playback, never on top of another sheet, never when another big ask came
 * first. What's new goes first (it carries the gift); else the gift once per season.
 */
@Composable
fun LooksWatcher(app: SwiftlyApplication) {
    if (app.isTv) return
    val context = LocalContext.current
    val idle = app.play.value == null
    LaunchedEffect(idle) {
        if (!idle) return@LaunchedEffect
        delay(3_000)
        val looks = app.looks
        if (app.play.value != null || app.sheet.value != null || looks.askedThisSession) return@LaunchedEffect
        val version = BuildConfig.VERSION_NAME
        val entry = looks.whatsNewEntry(context, version)
        when (looks.whatsNewDecision(version, entry != null)) {
            "show" -> {
                looks.whatsNewSeen(version)
                if (entry != null) {
                    val gift = entry.optJSONObject("module")?.optString("lookId").orEmpty()
                    if (gift.isNotEmpty() && looks.giftAvailable(gift)) looks.markOffered(gift)
                    looks.askedThisSession = true
                    whatsNewShow(app, entry)
                    return@LaunchedEffect
                }
            }
            "markSeen" -> looks.whatsNewSeen(version)
        }
        val gift = looks.giftDue(playing = false, secondsOnHome = 3.0) ?: return@LaunchedEffect
        looks.markOffered(gift.id)
        looks.askedThisSession = true
        giftOfferShow(app, gift)
    }
}

// MARK: - Home glow

/**
 * **The glow at the top of the phone's home page** (`LookGlowLayer`): the look's color in the
 * strength the person chose, its second tone from the right; it moves up with the page (up to
 * 300) and changes with `Motion.change`, also when it goes out.
 */
@Composable
fun LookHomeGlow(app: SwiftlyApplication, modifier: Modifier = Modifier, scrolled: () -> Float = { 0f }) {
    val p = app.looks.palette.value
    LookGlowLayer(p.glowColor, p.glowTint, p.glowOpacity, modifier, scrolled)
}

/**
 * **The television's glow** (unchanged): the look's color, fading down, in the chosen strength;
 * a faint second tone (`glowTint`) from the right for the looks whose mark has two.
 */
@Composable
fun HomeGlow(app: SwiftlyApplication, modifier: Modifier = Modifier) {
    val p = app.looks.palette.value
    if (p.glowOpacity <= 0f) return
    Box(modifier.fillMaxWidth().height(360.dp).drawBehind {
        val w = size.width
        drawRect(Brush.radialGradient(listOf(p.glowColor.copy(alpha = p.glowOpacity), Color.Transparent),
                                      center = Offset(w * 0.5f, 0f), radius = w * 1.05f))
        p.glowTint?.let { tint ->
            drawRect(Brush.radialGradient(listOf(tint.copy(alpha = p.glowOpacity * 0.55f), Color.Transparent),
                                          center = Offset(w * 0.95f, 0f), radius = w * 0.7f))
        }
    })
}
