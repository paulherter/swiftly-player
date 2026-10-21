package de.paulherter.swiftly.support

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.SwiftlyApplication
import de.paulherter.swiftly.pressRow
import de.paulherter.swiftly.pressText
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.PrimaryButton
import de.paulherter.swiftly.shared.SecondaryButton
import de.paulherter.swiftly.shared.Strength
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.motionReduced
import de.paulherter.swiftly.shared.translated
import android.os.Handler
import android.os.Looper

// MARK: - "Hilf Swiftly zu wachsen"

private const val TERMS_URL = "https://play.google.com/about/play-terms/"
private const val PRIVACY_URL = "https://swiftlyplayer.com/privacy.html"

/** Android's sheet handle takes 13 dp; iOS lays its grabber over the content. */
private val Handle = 13.dp

/**
 * **"Help Swiftly grow"**, the sheet of the Play build (`SupportGrowSheet` on iPhone): a full
 * sheet in the look's glow, the X at the top, the hero with three small phones, the two plans
 * side by side, the three tips as chips; the purchase and the terms stay at the bottom while the
 * rest scrolls. **Nothing is preselected.** The sheet stays open while the store's dialog is up and
 * gives way to the thanks when the purchase went through (`SupportPromptWatcher`).
 *
 * The Apple renewal sentence ("… in den Einstellungen deines Apple Accounts …") is not shown: the
 * catalog has no text for Play, so the sheet shows the links only (see PORT-ANDROID.md).
 */
@Composable
fun GrowSheetBody(app: SwiftlyApplication, close: () -> Unit) {
    val support = app.support
    val activity = LocalContext.current.findActivity()
    val uri = LocalUriHandler.current
    val plans = support.channel.plans.value
    val offers = support.channel.offers.value
    var chosen by remember { mutableStateOf<String?>(null) }
    var buying by remember { mutableStateOf(false) }
    val price = (plans.map { it.productId to it.price } + offers.map { it.productId to it.price }).toMap()
    val monthly = plans.firstOrNull { it.plan == "monthly" }
    val lifetime = plans.firstOrNull { it.plan == "lifetime" }

    Box(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize()) {
            Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState())) {
                LooksHero(app, Modifier.padding(top = 36.dp - Handle)) {
                    // The sheet goes first; the panel opens on the home page once it is down.
                    app.looks.supportOpening = false
                    close()
                    Handler(Looper.getMainLooper()).postDelayed({ openLooksOnHome(app) }, 450)
                }
                Column(Modifier.padding(horizontal = 20.dp).padding(top = 22.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(buildAnnotatedString {
                        append(translated("Hilf Swiftly zu wachsen"))
                        append("  ")
                        withStyle(SpanStyle(fontSize = 17.sp, fontWeight = FontWeight.Normal, letterSpacing = 0.sp)) { append("🌱") }
                    }, style = giftFont(28f, FontWeight.Bold).copy(letterSpacing = (-0.56).sp), color = Theme.font,
                         modifier = Modifier.semantics { heading() })
                    Text(translated("Dein Beitrag hält Swiftly am Laufen."), style = giftFont(17f), color = Theme.font.copy(alpha = 0.9f))
                    Text(translated("Open Source, keine Werbung, alles zum Schauen bleibt kostenlos."), style = giftFont(13f),
                         color = Theme.fontVeryQuiet)
                }

                if (support.channel.pricesUnavailable.value) {
                    PricesUnavailableCard(onRetry = { support.channel.connect(); support.channel.refresh() })
                }
                if (monthly != null || lifetime != null) {
                    Row(Modifier.padding(horizontal = 16.dp).padding(top = 18.dp).height(IntrinsicSize.Max),
                        horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        monthly?.let {
                            PlanTile(translated("Beliebt"), true, translated("Monatlich"), it.price, translated("im Monat · jederzeit kündbar"),
                                     chosen == it.productId, Modifier.weight(1f)) { chosen = it.productId }
                        }
                        lifetime?.let {
                            PlanTile(translated("Guter Deal"), false, translated("Für immer"), it.price, translated("einmal zahlen · wie 10 Monate"),
                                     chosen == it.productId, Modifier.weight(1f)) { chosen = it.productId }
                        }
                    }
                }
                if (offers.isNotEmpty()) {
                    Row(Modifier.padding(horizontal = 16.dp).padding(top = 12.dp), verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(translated("Einfach Danke ☕"), style = giftFont(12f), color = Theme.fontVeryQuiet, maxLines = 1,
                             modifier = Modifier.padding(end = 4.dp))
                        support.tips.forEach { tip ->
                            val offer = offers.firstOrNull { it.productId == tip.productId } ?: return@forEach
                            TipChip(offer.price, chosen == tip.productId, offer.owned, Modifier.weight(1f)) { chosen = tip.productId }
                        }
                    }
                }
                Spacer(Modifier.height(12.dp))
            }

            // The footer stays: the purchase and the terms.
            val label = when (chosen) {
                null -> translated("Wähl eine Option")
                monthly?.productId -> translated("Für %@ im Monat unterstützen", price[chosen].orEmpty())
                lifetime?.productId -> translated("Mit %@ unterstützen", price[chosen].orEmpty())
                else -> translated("Mit %@ Danke sagen", price[chosen].orEmpty())
            }
            Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(top = 12.dp, bottom = 10.dp),
                   verticalArrangement = Arrangement.spacedBy(8.dp)) {
                PrimaryButton(label, released = chosen != null && !buying && activity != null, lockedArea = Theme.raised) {
                    val id = chosen ?: return@PrimaryButton
                    buying = true
                    activity?.let { support.channel.buy(it, id) }
                    // The sheet stays up; a purchase that was cancelled lets the person choose again.
                    buying = false
                }
                Row(Modifier.fillMaxWidth().padding(top = 2.dp), horizontalArrangement = Arrangement.spacedBy(4.dp, Alignment.CenterHorizontally),
                    verticalAlignment = Alignment.CenterVertically) {
                    LegalLink(translated("Nutzungsbedingungen")) { uri.openUri(TERMS_URL) }
                    Text("·", style = giftFont(11f, FontWeight.Medium), color = Theme.fontVeryQuiet)
                    LegalLink(translated("Datenschutz")) { uri.openUri(PRIVACY_URL) }
                    Text("·", style = giftFont(11f, FontWeight.Medium), color = Theme.fontVeryQuiet)
                    LegalLink(translated("Wiederherstellen")) { support.channel.refresh() }
                }
            }
        }
        LookCloseButton(Modifier.align(Alignment.TopEnd).offset(y = 4.dp - Handle).padding(end = 8.dp), dark = true, action = close)
    }
}

/** Play delivered no prices: say so (`SupportGrowSheet`'s card), nothing fake, and let the person ask again. */
@Composable
private fun PricesUnavailableCard(onRetry: () -> Unit) {
    Column(Modifier.padding(horizontal = 16.dp).padding(top = 18.dp).fillMaxWidth()
               .clip(RoundedCornerShape(Theme.cornerField)).background(Theme.raised).padding(14.dp),
           verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(translated("Preise sind gerade nicht verfügbar"), style = giftFont(15f, FontWeight.SemiBold), color = Theme.font)
        Text(translated("Google Play hat nicht geantwortet. Das passiert ohne Internet oder wenn Käufe auf deinem Konto eingeschränkt sind. Nichts geht verloren, und Swiftly läuft wie immer."),
             style = giftFont(13f), color = Theme.fontQuiet)
        LegalLink(translated("Google Play erneut fragen"), onRetry)
    }
}

@Composable
private fun LegalLink(text: String, action: () -> Unit) {
    Box(Modifier.heightIn(min = 32.dp).pressText(action), contentAlignment = Alignment.Center) {
        Text(text, style = giftFont(11f, FontWeight.Medium).copy(textDecoration = TextDecoration.Underline), color = Theme.fontQuiet,
             maxLines = 1)
    }
}

/**
 * One plan (`PlanTile`): label, price, terms, a badge on the edge, the indicator top right.
 * Choosing is state, hence the accent ring and the check that pops in.
 */
@Composable
private fun PlanTile(badge: String, loud: Boolean, title: String, price: String, detail: String, chosen: Boolean,
                     modifier: Modifier, choose: () -> Unit) {
    val shape = RoundedCornerShape(Theme.cornerField)
    val calm = motionReduced()
    val pop = remember { Animatable(if (chosen) 1f else 0.4f) }
    LaunchedEffect(chosen) {
        if (!chosen) pop.snapTo(0.4f)
        else if (calm) pop.snapTo(1f)
        else pop.animateTo(1f, spring(dampingRatio = 0.62f, stiffness = 273f))
    }
    Box(modifier.fillMaxWidth().fillMaxHeight()) {
        Column(Modifier.fillMaxWidth().fillMaxHeight().clip(shape).background(Theme.area)
                .border(2.dp, if (chosen) Theme.accent else Color.Transparent, shape)
                .pressRow(choose).semantics(mergeDescendants = true) { role = Role.RadioButton; selected = chosen }
                .padding(14.dp).heightIn(min = 84.dp)) {
            Text(title, style = giftFont(13f), color = Theme.fontQuiet, modifier = Modifier.padding(top = 6.dp))
            Text(price, style = giftFont(22f, FontWeight.Bold).copy(letterSpacing = (-0.22).sp, fontFeatureSettings = "tnum"),
                 color = Theme.font, modifier = Modifier.padding(top = 4.dp))
            Text(detail, style = giftFont(12f), color = Theme.fontVeryQuiet)
        }
        Box(Modifier.align(Alignment.TopEnd).padding(12.dp).size(20.dp), contentAlignment = Alignment.Center) {
            if (chosen) {
                Box(Modifier.size(20.dp).graphicsLayer { scaleX = pop.value; scaleY = pop.value }.background(Theme.accent, CircleShape),
                    contentAlignment = Alignment.Center) {
                    Symbol(Glyph.Checkmark, 12.dp, color = Theme.onAccent, strength = Strength.Bold)
                }
            } else {
                Box(Modifier.size(20.dp).border(1.5.dp, Theme.font.copy(alpha = 0.25f), CircleShape))
            }
        }
        Box(Modifier.align(Alignment.TopStart).offset(x = 14.dp, y = (-9).dp).height(20.dp)
                .background(if (loud) Theme.font else Theme.pressedArea, CircleShape).padding(horizontal = 8.dp),
            contentAlignment = Alignment.Center) {
            Text(badge.uppercase(), style = giftFont(10f, FontWeight.Bold).copy(letterSpacing = 0.4.sp),
                 color = if (loud) Color(0xFF0A0A0A) else Theme.font, maxLines = 1)
        }
    }
}

/** One tip as a chip; chosen means the accent ring, like the plans. A tip bought before reads "Danke". */
@Composable
private fun TipChip(price: String, chosen: Boolean, owned: Boolean, modifier: Modifier, choose: () -> Unit) {
    Box(modifier.heightIn(min = 40.dp).clip(CircleShape).background(Theme.area)
            .border(2.dp, if (chosen) Theme.accent else Color.Transparent, CircleShape)
            .then(if (owned) Modifier else Modifier.pressRow(choose))
            .semantics(mergeDescendants = true) { role = Role.RadioButton; selected = chosen },
        contentAlignment = Alignment.Center) {
        Text(if (owned) translated("Danke") else price, style = giftFont(13f, FontWeight.SemiBold).copy(fontFeatureSettings = "tnum"),
             color = if (chosen) Theme.font else Theme.font.copy(alpha = 0.88f), maxLines = 1)
    }
}

// MARK: - Thanks

/**
 * The thanks, `SupportGrowThanks`, as a full sheet in the glow: the look's tile, "Danke, Name 🫶",
 * what happened, and at the bottom "Zeig mir meine Startseite" and "Fertig".
 */
@Composable
fun GrowThanksBody(app: SwiftlyApplication, close: () -> Unit, home: () -> Unit) {
    val looks = app.looks
    val look = looks.info(looks.palette.value.look)
    val name = app.username().takeIf { it != "?" }.orEmpty()
    val calm = motionReduced()
    // A tip is a thank-you only: nothing is unlocked, so nothing is promised.
    val tipOnly = !app.support.isSupporter
    val bobbing = remember { Animatable(0f) }
    LaunchedEffect(calm) {
        if (calm) return@LaunchedEffect
        bobbing.animateTo(1f, androidx.compose.animation.core.infiniteRepeatable(
            androidx.compose.animation.core.tween(1700, easing = androidx.compose.animation.core.EaseInOut),
            androidx.compose.animation.core.RepeatMode.Reverse))
    }
    Column(Modifier.fillMaxSize()) {
        Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 26.dp).padding(top = 100.dp - Handle),
               horizontalAlignment = Alignment.CenterHorizontally) {
            LookTileView(looks.tileIcon(look), 104.dp, Modifier.graphicsLayer { translationY = -4f * bobbing.value * density }
                .shadow(16.dp, RoundedCornerShape(23.4.dp), ambientColor = Color.Black.copy(alpha = 0.4f), spotColor = Color.Black.copy(alpha = 0.4f)))
            Text(if (name.isNotEmpty()) translated("Danke, %@ 🫶", name) else translated("Danke 🫶"),
                 style = giftFont(30f, FontWeight.Bold).copy(letterSpacing = (-0.6).sp, textAlign = TextAlign.Center), color = Theme.font,
                 modifier = Modifier.padding(top = 26.dp, bottom = 8.dp).semantics { heading() })
            Text(if (tipOnly) translated("Du hast Swiftly gerade beim Weitermachen geholfen. Freigeschaltet wird dafür nichts, es ist einfach nur Danke.")
                 else if (look.id != "original") translated("Du hast Swiftly gerade beim Weitermachen geholfen. %@ ist an, dein Icon und Logo auch. Schau dich um.", look.name)
                 else translated("Du hast Swiftly gerade beim Weitermachen geholfen. Looks und Icons gehören jetzt dir. Schau dich um."),
                 style = giftFont(15f).copy(lineHeight = 21.sp, textAlign = TextAlign.Center), color = Theme.fontQuiet)
            if (!tipOnly) Text(translated("Looks kannst du jederzeit im Profil wechseln."), style = giftFont(13f).copy(textAlign = TextAlign.Center),
                 color = Theme.fontVeryQuiet, modifier = Modifier.padding(top = 18.dp, start = 4.dp, end = 4.dp))
        }
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(top = 12.dp, bottom = 12.dp),
               verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (!tipOnly) PrimaryButton(translated("Zeig mir meine Startseite")) { close(); home() }
            if (tipOnly) PrimaryButton(translated("Fertig"), action = close) else SecondaryButton(translated("Fertig"), action = close)
        }
    }
}

/** What the person's support reads as in a settings row: monthly, for life, or just thanks. */
fun supportPlanText(app: SwiftlyApplication): String = when (app.store.rememberValue(Support.PLAN)) {
    "monthly" -> translated("Monatlich dabei")
    "lifetime" -> translated("Unterstützer für immer")
    else -> translated("Danke")
}
