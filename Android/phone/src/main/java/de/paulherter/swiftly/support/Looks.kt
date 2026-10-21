package de.paulherter.swiftly.support

import android.content.Context
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.graphics.Color
import de.paulherter.swiftly.SwiftlyApplication
import de.paulherter.swiftly.core.Kern
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import org.json.JSONArray
import org.json.JSONObject

/**
 * **The looks on the phone.** Every rule lives in the package (`Look`, `LookTryOn`, `LookGift`,
 * `LookEffects`, `LookProfileEntry`, `WhatsNew`) and is reached through the core (`Looks.swift`);
 * this class keeps the records in SharedPreferences under the package's keys, turns the answers
 * into Compose state and hands the tones to `Theme` (the phone only, TV never calls `apply`).
 */
class Looks(private val app: SwiftlyApplication) {
    class Accent(val id: String, val main: Color, val light: Color, val quiet: Color, val on: Color, val warning: Color?) {
        fun tones() = Theme.Tones(main, light, quiet, on, warning ?: Theme.Tones(main, light, quiet, on).warning)
    }

    class Season(val id: String, val fromMonth: Int, val fromDay: Int, val toMonth: Int, val toDay: Int)

    class LookInfo(val id: String, val nameKey: String, val accent: Accent, val glowColor: Color, val defaultGlow: String,
                   val logoGradient: List<Color>, val glowTint: Color?, val iconName: String?, val isGift: Boolean,
                   val season: Season?) {
        val name: String get() = translated(nameKey)
    }

    class Palette(val look: String, val accent: Accent, val glow: String, val glowOpacity: Float, val glowColor: Color,
                  val glowTint: Color?, val logoGradient: List<Color>, val iconName: String?)

    val catalog: List<LookInfo>
    val accents: List<Accent>
    val glowOpacity: Map<String, Float>

    init {
        val o = JSONObject(Kern.looksCatalog())
        accents = o.getJSONArray("accents").objects().map(::accent)
        catalog = o.getJSONArray("looks").objects().map { l ->
            LookInfo(l.getString("id"), l.getString("nameKey"), accent(l.getJSONObject("accent")),
                color(l.getString("glowColor")), l.getString("defaultGlow"),
                l.getJSONArray("logoGradient").strings().map(::color), l.optString("glowTint").takeIf { it.isNotEmpty() }?.let(::color),
                l.optString("iconName").takeIf { it.isNotEmpty() }, l.getBoolean("isGift"),
                l.optJSONObject("season")?.let { Season(it.getString("id"), it.getInt("fromMonth"), it.getInt("fromDay"), it.getInt("toMonth"), it.getInt("toDay")) })
        }
        val g = o.getJSONObject("glows")
        glowOpacity = g.keys().asSequence().associateWith { g.getDouble(it).toFloat() }
    }

    fun info(id: String): LookInfo = catalog.firstOrNull { it.id == id } ?: catalog.first()

    // MARK: State

    /** The try-on record, as the package's `LookTryOn` hands it back each call. */
    private var tryState = ""

    /** The selection shown now (the preview, else what is stored), as the package's JSON. */
    val shown = mutableStateOf("{}")
    /** What is stored (the preview does not touch it). */
    val saved = mutableStateOf("{}")
    val palette = mutableStateOf(basePalette())
    val previewing = mutableStateOf(false)
    val owned = mutableStateOf<Set<String>>(emptySet())
    val effectsOn = mutableStateOf(true)
    /** TV: the full-screen looks page is open. */
    val tvPage = mutableStateOf(false)
    /** TV: the buy page was opened from the looks page, so closing it without a purchase ends the preview. */
    var tvFromLooks = false

    /** One big ask per session: the gift, what's new, the support sheet. */
    var askedThisSession = false
    private var supporter = false
    /** The support sheet was opened from the looks panel: closing the panel then keeps the preview. */
    var supportOpening = false

    /** Set by the main view: back to the home page and close whatever lies above it. */
    var goHomeAction: () -> Unit = {}
    /** Set while `LookToneAnimator` is on screen: it moves the accent tones itself. */
    var tonesAnimated = false
    fun goHome() = goHomeAction()

    private fun basePalette() = runCatching { parsePalette(JSONObject(Kern.looksPalette("{}"))) }.getOrElse {
        val a = Accent("main", Theme.accent, Theme.accentLight, Theme.accentQuiet, Theme.onAccent, null)
        Palette("original", a, "off", 0f, Theme.accent, null, emptyList(), null)
    }

    /** Reads the records once at the start. Does not touch the system icon. */
    fun start() {
        supporter = app.support.isSupporter
        val selection = Kern.looksNormalize(app.store.rememberValue(SELECTION).orEmpty())
        val owned = strings(app.store.rememberValue(OWNED))
        effectsOn.value = app.store.rememberValue(EFFECTS) != "0"
        val state = JSONObject().put("saved", JSONObject(selection)).put("supporter", supporter)
            .put("owned", JSONArray(owned.toList()))
        tryState = state.toString()
        run("show")
    }

    /** One step of the package's `LookTryOn`; stores what became permanent. */
    fun run(op: String, arg: String = ""): JSONObject {
        val answer = JSONObject(Kern.looksTryOn(tryState, op, arg))
        val state = answer.getJSONObject("state")
        tryState = state.toString()
        val savedSelection = state.getJSONObject("saved").toString()
        if (savedSelection != saved.value) app.store.remember(SELECTION, Kern.looksNormalize(savedSelection))
        saved.value = savedSelection
        val own = state.getJSONArray("owned").strings().toSet()
        if (own != owned.value) app.store.remember(OWNED, JSONArray(own.sorted()).toString())
        owned.value = own
        shown.value = answer.getJSONObject("shown").toString()
        previewing.value = state.has("preview")
        val p = parsePalette(answer.getJSONObject("palette"))
        palette.value = p
        // On the phone `LookToneAnimator` carries the tones over with `Motion.change`.
        if (!tonesAnimated) Theme.applyTones(p.accent.tones())
        Theme.applyMarkGradient(p.logoGradient.takeIf { it.size > 1 })
        return answer
    }

    /** The supporter state changed (purchase, key, restore, refund). */
    fun syncSupporter() {
        val now = app.support.isSupporter
        if (now == supporter) return
        supporter = now
        if (now) {
            val kept = run("purchase").optString("result")
            if (kept.isNotEmpty()) applyIcon()
        } else run("supporter", "0")
    }

    // MARK: Picking

    /** The selection for another look, clean of the old overrides. */
    fun switching(lookID: String): String = Kern.looksSwitch(lookID)

    /** Whether this person may wear the selection as it is (the package's `mayWear`). */
    fun mayWear(selection: JSONObject): Boolean {
        if (supporter) return true
        val id = selection.optString("look", "original")
        if (selection.has("accent")) return false
        return id == "original" || (info(id).isGift && id in owned.value)
    }

    /** A look in the strip: worn at once when allowed, else a preview that stores nothing. */
    fun pick(next: String) {
        if (mayWear(JSONObject(next))) {
            if (previewing.value) run("end")
            run("choose", next)
        } else {
            if (!previewing.value) run("begin")
            run("tryOn", next)
        }
    }

    /** One setting of the shown selection (glow, icon, accent), applied the same way. */
    fun change(edit: (JSONObject) -> Unit) {
        val next = JSONObject(shown.value)
        edit(next)
        pick(next.toString())
    }

    /** "Verwenden": what is stored stays, the icon follows. */
    fun use(context: Context) {
        applyIcon(context)
    }

    /** The panel went away: a preview ends, the icon follows what is worn. */
    fun panelClosed(context: Context) {
        if (supportOpening) { supportOpening = false; return }
        if (previewing.value) run("end")
        applyIcon(context)
    }

    /** "Unterstützer werden" in the panel: keeps the preview and says whether the sheet is due. */
    fun keep(): Boolean = run("keep").optString("result") == "needsSupport"

    /** The support sheet opened from the panel went away without a purchase. */
    fun supportClosed(context: Context) {
        run("sheetClosed")
        if (previewing.value) run("end")
        applyIcon(context)
    }

    /** "Hol ihn dir": the gift is picked up for good and worn. */
    fun claim(lookID: String, context: Context) {
        run("claim", lookID)
        applyIcon(context)
    }

    // MARK: Icon

    /** Alias name for a look's icon name: `AppIcon-NeonNight` is `LookNeonNight`. */
    fun alias(iconName: String?): String? =
        iconName?.removePrefix("AppIcon-")?.let { if (it.startsWith("Look")) it else "Look$it" }

    /** The look icon of the shown look as a thumbnail (the standard icon for the original). */
    fun tileIcon(look: LookInfo): AppIcons.Icon = AppIcons.forAlias(alias(look.iconName))

    /** Puts the system icon on what is worn: the look's icon, or Standard when a look icon was set. */
    fun applyIcon(context: Context = app) {
        // The television has no alternative icons.
        if (app.isTv) return
        val wanted = alias(palette.value.iconName)
        if (wanted != null) AppIcons.set(context, wanted)
        else if (AppIcons.current(context).startsWith("Look")) AppIcons.set(context, "Standard")
    }

    // MARK: Season, gift

    private fun now() = System.currentTimeMillis()

    /** Whether a gift can be picked up now. */
    fun giftAvailable(lookID: String): Boolean = Kern.looksGiftAvailable(lookID, JSONArray(owned.value.toList()).toString(), now())

    fun anyGiftAvailable(): Boolean = Kern.looksAnyGiftAvailable(JSONArray(owned.value.toList()).toString(), now())

    /** The gift whose pop-up is due now, or null. */
    fun giftDue(playing: Boolean, secondsOnHome: Double): LookInfo? {
        val id = Kern.looksGiftDue(now(), true, playing, askedThisSession, secondsOnHome,
            JSONArray(owned.value.toList()).toString(), app.store.rememberValue(OFFERED) ?: "[]")
        return if (id.isEmpty()) null else info(id)
    }

    fun markOffered(lookID: String) {
        val offer = Kern.looksGiftOfferID(lookID, now())
        if (offer.isEmpty()) return
        val all = strings(app.store.rememberValue(OFFERED)) + offer
        app.store.remember(OFFERED, JSONArray(all.sorted()).toString())
    }

    /** In the look's season (the bats and the web belong to it). */
    fun effects(playing: Boolean, reduceMotion: Boolean, foreground: Boolean): JSONObject = JSONObject(Kern.looksEffects(
        palette.value.look, now(), effectsOn.value, playing, reduceMotion, false, foreground))

    fun setEffects(on: Boolean) {
        effectsOn.value = on
        app.store.remember(EFFECTS, if (on) "1" else "0")
    }

    /** Whether today lies in the look's window (`LookSeason.isActive`), the last day included. */
    fun seasonActive(look: LookInfo): Boolean {
        val s = look.season ?: return false
        val c = java.util.Calendar.getInstance()
        val today = (c.get(java.util.Calendar.MONTH) + 1) * 100 + c.get(java.util.Calendar.DAY_OF_MONTH)
        val from = s.fromMonth * 100 + s.fromDay
        val to = s.toMonth * 100 + s.toDay
        return if (to < from) today >= from || today <= to else today in from..to
    }

    /** "2. Nov.": the last day of the window this year (`LooksPanel.end(of:)`), for "Bis %@ dabei". */
    fun seasonEnd(look: LookInfo): String? = look.season?.let { s ->
        val c = java.util.Calendar.getInstance()
        var year = c.get(java.util.Calendar.YEAR)
        if (s.toMonth * 100 + s.toDay < s.fromMonth * 100 + s.fromDay && c.get(java.util.Calendar.MONTH) + 1 >= s.fromMonth) year += 1
        c.set(year, s.toMonth - 1, s.toDay)
        val locale = java.util.Locale.getDefault()
        java.text.SimpleDateFormat(android.text.format.DateFormat.getBestDateTimePattern(locale, "dMMM"), locale).format(c.time)
    }

    /** The palette a selection would give, without wearing it (the hero's small phones, a gift's light). */
    fun paletteFor(selection: String): Palette = runCatching { parsePalette(JSONObject(Kern.looksPalette(selection))) }.getOrElse { palette.value }

    /** `LookProfileEntry`: "none", "teaser" or "current" and whether the plain Looks row shows. */
    fun profileEntry(): Pair<String, Boolean> {
        val o = JSONObject(Kern.looksProfileEntry(true, app.support.isSupporter, owned.value.isNotEmpty(), anyGiftAvailable()))
        return o.getString("entry") to o.getBoolean("showsRow")
    }

    // MARK: What's new

    /** The shipped entry for this version (asset), or null. Validated by the package. */
    fun whatsNewEntry(context: Context, version: String): JSONObject? = runCatching {
        val text = context.assets.open("whatsnew/$version.json").bufferedReader().use { it.readText() }
        if (JSONObject(Kern.whatsNewCheck(text)).getBoolean("valid")) JSONObject(text) else null
    }.getOrNull()

    /** "show", "markSeen" or "nothing" for this start. */
    fun whatsNewDecision(version: String, hasEntry: Boolean): String =
        Kern.whatsNewDecide(app.store.rememberValue(WHATS_NEW).orEmpty(), app.support.usedBeforeThisLaunch, version, hasEntry)

    fun whatsNewSeen(version: String) = app.store.remember(WHATS_NEW, version)

    companion object {
        /** `LookStorageKey` and `WhatsNew.lastSeenKey` in the package. Never change. */
        const val SELECTION = "look.selection"
        const val OWNED = "look.owned"
        const val OFFERED = "look.gift.offered"
        const val EFFECTS = "look.effects"
        const val WHATS_NEW = "whatsnew.lastSeen"

        private fun color(hex: String) = Color(android.graphics.Color.parseColor(hex))

        private fun accent(o: JSONObject) = Accent(o.getString("id"), color(o.getString("main")), color(o.getString("light")),
            color(o.getString("quiet")), color(o.getString("on")), o.optString("warning").takeIf { it.isNotEmpty() }?.let(::color))

        private fun parsePalette(o: JSONObject) = Palette(o.getString("look"), accent(o.getJSONObject("accent")), o.getString("glow"),
            o.getDouble("glowOpacity").toFloat(), color(o.getString("glowColor")),
            o.optString("glowTint").takeIf { it.isNotEmpty() }?.let(::color),
            o.getJSONArray("logoGradient").strings().map(::color), o.optString("iconName").takeIf { it.isNotEmpty() })

        private fun JSONArray.objects() = (0 until length()).map { getJSONObject(it) }
        private fun JSONArray.strings() = (0 until length()).map { getString(it) }
        private fun strings(json: String?): List<String> = runCatching { JSONArray(json ?: "[]").strings() }.getOrDefault(emptyList())
    }
}
