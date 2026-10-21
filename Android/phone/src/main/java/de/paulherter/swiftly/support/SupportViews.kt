package de.paulherter.swiftly.support

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.CardView
import de.paulherter.swiftly.Choice
import de.paulherter.swiftly.Destination
import de.paulherter.swiftly.Footer
import de.paulherter.swiftly.GroupsTitle
import de.paulherter.swiftly.SeparatorLine
import de.paulherter.swiftly.SettingGroup
import de.paulherter.swiftly.SettingPage
import de.paulherter.swiftly.SheetRequest
import de.paulherter.swiftly.SwiftlyApplication
import de.paulherter.swiftly.ValueRow
import de.paulherter.swiftly.pressRow
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.PrimaryButton
import de.paulherter.swiftly.shared.SecondaryButton
import de.paulherter.swiftly.shared.Strength
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import de.paulherter.swiftly.tapOn
import kotlinx.coroutines.delay

// MARK: - Entry points

/** The ask, as a sheet from below (`app.sheet`): mark, intro, then what this build offers. */
fun supportSheetShow(app: SwiftlyApplication, fromLooks: Boolean = false) {
    // The Play build's sheet is iOS's "Hilf Swiftly zu wachsen": full height, in the look's glow, its own X.
    val grow = de.paulherter.swiftly.BuildConfig.FLAVOR == "play" && !app.isTv
    app.sheet.value = SheetRequest(translated("Swiftly unterstützen"), emptyList(), null, heading = !grow, full = grow,
        backdrop = if (grow) ({ GrowBackdrop(app) }) else null, content = { close ->
        if (fromLooks) {
            // Closing without a purchase ends the preview that led here (`LookTryOn`).
            val context = LocalContext.current
            DisposableEffect(Unit) { onDispose { app.looks.supportClosed(context) } }
        }
        FlavorSupport.PhoneSheetBody(app, close)
    }) { }
}

/** After a purchase or an accepted key: what is new, with a preview of the icons. */
fun supportThanksShow(app: SwiftlyApplication, open: (Destination) -> Unit) {
    val grow = !app.isTv
    app.sheet.value = SheetRequest(translated("Danke. Du bist dabei."), emptyList(), null, heading = !grow, full = grow,
        backdrop = if (grow) ({ GrowBackdrop(app) }) else null, content = { close ->
        if (app.isTv) ThanksBody(app, close, open) else GrowThanksBody(app, close) { app.looks.goHome() }
    }) { }
}

/** The look's soft glow behind the full support sheets, as on the home page. */
@Composable
private fun BoxScope.GrowBackdrop(app: SwiftlyApplication) {
    val p = app.looks.palette.value
    LookGlowLayer(p.glowColor, p.glowTint, app.looks.glowOpacity["soft"] ?: p.glowOpacity, Modifier.align(Alignment.TopCenter))
}

/**
 * **The heart and the sheet, wired once per activity.** Shows the sheet when the package says it
 * is due (only once playback is closed, never in the first minute) and the thanks when a purchase
 * or a key came through.
 */
@Composable
fun SupportPromptWatcher(app: SwiftlyApplication, ask: () -> Unit, thanks: () -> Unit) {
    val support = app.support
    val idle = app.play.value == null
    LaunchedEffect(idle, support.channel.available.value) {
        if (!idle) return@LaunchedEffect
        // The package's quiet minute plus a little: asked on a calm home page, not on arrival.
        delay(62_000)
        if (app.play.value != null || app.sheet.value != null) return@LaunchedEffect
        if (!app.isTv && app.looks.askedThisSession) return@LaunchedEffect
        if (support.decide().showsSheet) {
            support.answer("sheetShown")
            if (!app.isTv) app.looks.askedThisSession = true
            ask()
        }
    }
    LaunchedEffect(support.thanksDue.value) {
        if (!support.thanksDue.value) return@LaunchedEffect
        support.thanksDue.value = false
        delay(400)
        thanks()
    }
}

// MARK: - Sheet parts both flavors use

/** The mark above the sheet's text: the heart, outlined, in the accent. */
@Composable
fun SupportMark(filled: Boolean = false) {
    Box(Modifier.fillMaxWidth().padding(top = 2.dp, bottom = 12.dp), contentAlignment = Alignment.Center) {
        Box(Modifier.size(56.dp).clip(CircleShape).background(Theme.accentQuiet), contentAlignment = Alignment.Center) {
            Symbol(if (filled) Glyph.HeartFilled else Glyph.Heart, 26.dp, color = Theme.accent, strength = Strength.Medium)
        }
    }
}

/** A paragraph in the sheet: body text, quiet, on the sheet's edge. */
@Composable
fun SheetText(text: String, quiet: Boolean = true, small: Boolean = false, center: Boolean = false, top: Dp = 0.dp) {
    Text(text, style = (if (small) Theme.small.copy(lineHeight = 17.sp) else Theme.body.copy(lineHeight = 21.sp))
            .copy(textAlign = if (center) TextAlign.Center else TextAlign.Start),
         color = if (quiet) (if (small) Theme.fontVeryQuiet else Theme.fontQuiet) else Theme.font,
         modifier = Modifier.fillMaxWidth().padding(horizontal = Theme.edgeSpacing).padding(top = top))
}

/**
 * **One tip as a choice**: symbol, name, price. Nothing is chosen at first; the chosen one carries
 * the accent edge. A tip bought before reads "Thank you" and cannot be chosen again (Play keeps
 * every tip once, acknowledged, never consumed).
 */
@Composable
fun TipChoice(emoji: String, title: String, price: String, chosen: Boolean, owned: Boolean, choose: () -> Unit) {
    val shape = RoundedCornerShape(Theme.cornerField)
    Row(Modifier.fillMaxWidth().heightIn(min = 52.dp).clip(shape)
            .background(if (chosen) Theme.raised else Theme.groupsArea)
            .border(1.5.dp, if (chosen) Theme.accent else Color.Transparent, shape)
            .then(if (owned) Modifier.alpha(0.55f) else Modifier.pressRow(choose))
            .semantics(mergeDescendants = true) { role = Role.RadioButton; selected = chosen }
            .padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(emoji, style = Theme.body.copy(fontSize = 20.sp))
        Text(title, style = Theme.listTitle, color = Theme.font, modifier = Modifier.weight(1f))
        Text(if (owned) translated("Danke") else price, style = Theme.body.copy(fontFeatureSettings = "tnum"),
             color = if (chosen) Theme.font else Theme.fontQuiet)
    }
}

// MARK: - Thanks

@Composable
private fun ThanksBody(app: SwiftlyApplication, close: () -> Unit, open: (Destination) -> Unit) {
    SupportMark(filled = true)
    SheetText(translated("Dein Kaffee hilft uns, Swiftly für alle kostenlos zu halten. Das ist neu für dich."))
    Spacer(Modifier.height(16.dp))
    Column(Modifier.fillMaxWidth().padding(horizontal = Theme.edgeSpacing).clip(RoundedCornerShape(Theme.cornerCard))
               .background(Theme.groupsArea)) {
        GiftRow(Glyph.AppIcon, translated("Unterstützer-App-Icons"), translated("Neue Icons für die App")) {
            Row(horizontalArrangement = Arrangement.spacedBy((-6).dp)) {
                AppIcons.all.drop(1).take(3).forEach { IconThumb(it, 26.dp) }
            }
        }
        SeparatorLine()
        GiftRow(Glyph.HeartFilled, translated("Ein Herz in „Über“"), translated("Neben deiner Versionsnummer")) {}
    }
    Column(Modifier.fillMaxWidth().padding(horizontal = Theme.edgeSpacing).padding(top = 20.dp, bottom = 12.dp),
           verticalArrangement = Arrangement.spacedBy(10.dp)) {
        PrimaryButton(translated("App-Icon wählen")) { close(); open(appIconTarget()) }
        SecondaryButton(translated("Fertig"), action = close)
    }
}

@Composable
private fun GiftRow(symbol: Glyph, title: String, under: String, right: @Composable () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Box(Modifier.width(Theme.characterColumn), contentAlignment = Alignment.Center) {
            Symbol(symbol, 17.dp, color = Theme.accent)
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = Theme.listTitle, color = Theme.font)
            Text(under, style = Theme.small, color = Theme.fontVeryQuiet)
        }
        right()
    }
}

// MARK: - Home page

/**
 * **The heart in the home header** (`SupportHeart`), left of the watchlist. Filled and white like
 * the bookmark next to it: it is a destination, not a state, and the accent belongs to state.
 * In debug builds it beats twice, once per launch, a second after the home page first appears
 * (the design's `beat`: 1.18 / 1.0 / 1.12 / 1.0 at 0.31 s each, 1.36 s still, again).
 */
@Composable
fun SupportHeaderHeart(app: SwiftlyApplication) {
    val support = app.support
    if (!support.available && !support.isSupporter) return
    val scale = remember { androidx.compose.animation.core.Animatable(1f) }
    val reduced = de.paulherter.swiftly.shared.motionReduced()
    LaunchedEffect(Unit) {
        if (!de.paulherter.swiftly.BuildConfig.DEBUG || heartHasBeaten || reduced) return@LaunchedEffect
        heartHasBeaten = true
        try {
            delay(1_000)
            val step = androidx.compose.animation.core.tween<Float>(310, easing = androidx.compose.animation.core.FastOutSlowInEasing)
            repeat(2) { round ->
                if (round == 1) delay(1_360)
                for (target in floatArrayOf(1.18f, 1f, 1.12f, 1f)) scale.animateTo(target, step)
            }
        } catch (e: kotlinx.coroutines.CancellationException) {
            heartHasBeaten = false; throw e
        }
    }
    Box(Modifier.size(44.dp).tapOn { if (support.isSupporter) supportThanksShow(app, support.openPage) else supportSheetShow(app) },
        contentAlignment = Alignment.Center) {
        Symbol(Glyph.HeartFilled, 20.dp, color = Theme.font, description = translated("Swiftly unterstützen"),
               modifier = Modifier.graphicsLayer { scaleX = scale.value; scaleY = scale.value })
    }
}

/** The heart beats once per launch. */
private var heartHasBeaten = false

/**
 * **The card at the end of the home page**, `SupportPrompt.decide` → `showsCard`. A calm block like
 * a settings card, never a pop-up. "Not now" hides it for 30 days; "Don't show again" sits in its
 * menu.
 */
@Composable
fun SupportHomeCard(app: SwiftlyApplication) {
    val support = app.support
    val decision = remember(support.changed.intValue, app.play.value == null, support.channel.available.value) { support.decide() }
    // Decided again after the quiet minute, when the page has been open that long.
    var late by remember { mutableStateOf(0) }
    LaunchedEffect(Unit) { delay(61_000); late += 1 }
    val now = remember(late, decision) { if (late > 0) support.decide() else decision }
    if (!now.showsCard) return
    CardView {
        Box(Modifier.fillMaxWidth()) {
            Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(translated("Du hast mit Swiftly %lld Stunden geschaut.", now.watchedHours),
                     style = Theme.categoryLarge, color = Theme.font, modifier = Modifier.padding(end = 30.dp))
                Text(translated("Wenn es dir einen Kaffee wert ist, freuen wir uns sehr."), style = Theme.body, color = Theme.fontQuiet)
                Row(Modifier.padding(top = 12.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    PrimaryButton(translated("Unterstützen"), stretches = false, modifier = Modifier.weight(1f)) { supportSheetShow(app) }
                    SecondaryButton(translated("Nicht jetzt"), stretches = false, modifier = Modifier.weight(1f)) { support.answer("snooze") }
                }
            }
            Box(Modifier.align(Alignment.TopEnd).size(44.dp).tapOn {
                app.sheet.value = SheetRequest(translated("Swiftly unterstützen"), listOf(Choice("weg", translated("Nicht mehr zeigen"))), null,
                    icons = mapOf("weg" to Glyph.CrossCircle)) { support.answer("dismiss") }
            }, contentAlignment = Alignment.Center) {
                Symbol(Glyph.More, 17.dp, color = Theme.fontVeryQuiet, description = translated("Mehr"))
            }
        }
    }
}

// MARK: - Settings, About

/** The "Swiftly" group in Settings: support, and the app icon on the phone. */
@Composable
fun SupportSettingsGroup(app: SwiftlyApplication, open: (Destination) -> Unit) {
    val support = app.support
    if (!support.available && !support.isSupporter) return
    SettingGroup("Swiftly") {
        ValueRow(Glyph.Heart, translated("Swiftly unterstützen"), translated("Mit einem Kaffee Danke sagen"),
                 value = if (support.isSupporter) translated("Danke") else null) {
            if (support.isSupporter) supportThanksShow(app, open) else supportSheetShow(app)
        }
        if (!app.isTv) {
            SeparatorLine()
            val context = LocalContext.current
            val current = remember(support.changed.intValue) { AppIcons.current(context) }
            ValueRow(Glyph.AppIcon, translated("App-Icon"), value = if (current == "Standard") null else current) {
                open(appIconTarget())
            }
        }
    }
}

/** The version line in Profile and Settings, with the heart and "Supporter" for supporters. */
@Composable
fun VersionLine(app: SwiftlyApplication, text: String, modifier: Modifier = Modifier) {
    Row(modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        // White at 30 percent is 2.67:1 and not allowed for text.
        Text(text, style = Theme.small, color = Theme.fontVeryQuiet)
        if (app.support.isSupporter) {
            Symbol(Glyph.HeartFilled, 11.dp, color = Theme.accent)
            Text(translated("Unterstützer"), style = Theme.small.copy(fontWeight = FontWeight.SemiBold), color = Theme.accent)
        }
    }
}

/** A small filled heart at the lower edge of an avatar, for supporters. */
@Composable
fun BoxScope.SupporterAvatarHeart(app: SwiftlyApplication, avatar: Dp) {
    if (!app.support.isSupporter) return
    val size = (avatar.value * 0.36f).coerceIn(14f, 22f).dp
    Box(Modifier.align(Alignment.BottomEnd).offset(x = 2.dp, y = 2.dp).size(size).clip(CircleShape)
            .background(Theme.reason).padding(2.dp).clip(CircleShape).background(Theme.accentQuiet)
            .semantics { contentDescription = translated("Unterstützer") },
        contentAlignment = Alignment.Center) {
        Symbol(Glyph.HeartFilled, size * 0.45f, color = Theme.accent)
    }
}

// MARK: - App icon picker (phone)

fun appIconTarget() = Destination("appicon", translated("App-Icon"), "AppIcon")

/** One icon as the launcher draws it: background and foreground layer, rounded. */
@Composable
fun IconThumb(icon: AppIcons.Icon, size: Dp, modifier: Modifier = Modifier) {
    Box(modifier.size(size).clip(RoundedCornerShape(size * 0.24f)).border(1.dp, Theme.reason, RoundedCornerShape(size * 0.24f))) {
        Image(painterResource(icon.background), null, Modifier.fillMaxSize())
        Image(painterResource(icon.foreground), null, Modifier.fillMaxSize())
    }
}

/**
 * **Choose an app icon.** Supporters choose; everyone else sees the icons as a preview, with
 * "Support Swiftly" below. The standard icon is always there.
 */
@Composable
fun AppIconPage(app: SwiftlyApplication, back: () -> Unit) {
    val context = LocalContext.current
    val support = app.support
    var current by remember { mutableStateOf(AppIcons.current(context)) }
    SettingPage(translated("App-Icon"), back) {
        IconGrid(AppIcons.all.take(1), current, enabled = true) { AppIcons.set(context, it); current = AppIcons.current(context) }
        GroupsTitle(translated("Unterstützer-Icons"), Modifier.padding(top = 26.dp, bottom = 2.dp))
        IconGrid(AppIcons.all.drop(1), current, enabled = support.isSupporter) {
            AppIcons.set(context, it); current = AppIcons.current(context)
        }
        if (!support.isSupporter && support.available) {
            Footer(translated("Als Dankeschön bekommst du ein Herz in „Über“ und zusätzliche App-Icons."))
            PrimaryButton(translated("Swiftly unterstützen"), modifier = Modifier.padding(horizontal = Theme.edgeSpacing).padding(top = 20.dp)) {
                supportSheetShow(app)
            }
        }
    }
}

@Composable
private fun ColumnScope.IconGrid(icons: List<AppIcons.Icon>, current: String, enabled: Boolean, choose: (String) -> Unit) {
    CardView {
        icons.chunked(3).forEach { row ->
            Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 10.dp)) {
                row.forEach { icon ->
                    val on = icon.name == current
                    Column(Modifier.weight(1f).then(if (enabled) Modifier.tapOn { choose(icon.name) } else Modifier)
                            .semantics(mergeDescendants = true) { contentDescription = icon.name; selected = on }
                            .padding(vertical = 6.dp),
                        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Box(Modifier.size(70.dp).border(2.dp, if (on) Theme.accent else Color.Transparent, RoundedCornerShape(18.dp)),
                            contentAlignment = Alignment.Center) {
                            IconThumb(icon, 60.dp, Modifier.alpha(if (enabled) 1f else 0.45f))
                        }
                        Box(Modifier.height(18.dp), contentAlignment = Alignment.Center) {
                            if (on) Symbol(Glyph.CheckmarkCircleFilled, 15.dp, color = Theme.accent)
                        }
                    }
                }
                repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
            }
        }
    }
}
