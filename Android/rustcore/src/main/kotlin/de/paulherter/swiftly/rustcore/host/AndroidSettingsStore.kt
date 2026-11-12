package de.paulherter.swiftly.rustcore.host

import de.paulherter.swiftly.rustcore.SettingValue
import de.paulherter.swiftly.rustcore.SettingsStore
import org.json.JSONArray
import org.json.JSONObject

/**
 * The core's typed `SettingsStore` over the old Android preferences.
 *
 * **Old preferences hold every setting as a string** (`Store.remember(key, String)` in the file `swiftly`): booleans
 * as `"1"`/`"0"`, numbers in decimal, lists as a JSON array, maps as a JSON object, `Data` (the subtitle look, the
 * library rails) as the UTF-8 text of the JSON the old app wrote. The value stays a string on disk, so an old and a
 * new build read each other's values. The type comes from [TYPES], key by key (the names and types of
 * `crates/swiftly-settings/src/keys.rs`; a unit test compares both). A value that does not parse as its type reads as
 * absent, so the core falls back to its default, exactly as the old `bool(k, default)` helpers did.
 *
 * Three differences between the Android names and the core's keys are bridged here instead of renaming anything on
 * disk: `gesehenVonAn` is `gesehenVon` on Android; `gesehenVonServer` (a list) is assembled from the per-server flags
 * `gesehenVonPlugin|<server>` = `"1"`.
 */
class AndroidSettingsStore(
    private val prefs: StringPrefs,
    /** Told after every write, like `Store.onChange` (the settings sync watches the synced keys through it). */
    private val onChange: ((String) -> Unit)? = null,
) : SettingsStore {

    enum class Kind { BOOL, INT, DOUBLE, TEXT, DATA, LIST, MAP }

    override fun get(key: String): SettingValue? {
        if (key == SERVER_LIST_KEY) return serversWithPlugin()?.let { SettingValue.Items(it) }
        val raw = prefs.get(disk(key)) ?: return null
        return decode(kindOf(key), raw)
    }

    override fun set(key: String, value: SettingValue) {
        if (key == SERVER_LIST_KEY) {
            val want = (value as? SettingValue.Items)?.value.orEmpty().toSet()
            serverFlagKeys().forEach { k -> if (prefs.get(k) == "1" && k.removePrefix(PLUGIN_PREFIX) !in want) prefs.remove(k) }
            want.forEach { prefs.put(PLUGIN_PREFIX + it, "1") }
        } else {
            prefs.put(disk(key), encode(value))
        }
        onChange?.invoke(key)
    }

    override fun remove(key: String) {
        if (key == SERVER_LIST_KEY) serverFlagKeys().forEach { prefs.remove(it) } else prefs.remove(disk(key))
        onChange?.invoke(key)
    }

    override fun keys(): List<String> {
        val held = prefs.keys()
        val out = LinkedHashSet<String>()
        for (k in held) {
            val core = core(k)
            if (known(core)) out += core
        }
        if (serverFlagKeys().any { prefs.get(it) == "1" }) out += SERVER_LIST_KEY
        return out.toList()
    }

    // ---- names ----------------------------------------------------------------------------------------------------

    private fun disk(key: String) = if (key == "gesehenVonAn") "gesehenVon" else key
    private fun core(key: String) = if (key == "gesehenVon") "gesehenVonAn" else key

    /** The type of a key: the table, a family (`sortierung.<x>`, `filter.<x>`), or a per-server key (`<base>|<server>`). */
    private fun kindOf(key: String): Kind {
        TYPES[key]?.let { return it }
        if (key.startsWith("sortierung.") || key.startsWith("filter.")) return Kind.TEXT
        val base = key.substringBefore('|', "")
        if (base.isNotEmpty()) TYPES[base]?.let { return it }
        return Kind.TEXT
    }

    private fun known(key: String) =
        key in TYPES || key.startsWith("sortierung.") || key.startsWith("filter.") ||
            (key.contains('|') && key.substringBefore('|') in TYPES && key.substringBefore('|') != "gesehenVonPlugin")

    private fun serverFlagKeys() = prefs.keys().filter { it.startsWith(PLUGIN_PREFIX) }
    private fun serversWithPlugin(): List<String>? =
        serverFlagKeys().filter { prefs.get(it) == "1" }.map { it.removePrefix(PLUGIN_PREFIX) }.sorted().takeIf { it.isNotEmpty() }

    // ---- values ---------------------------------------------------------------------------------------------------

    private fun decode(kind: Kind, raw: String): SettingValue? = when (kind) {
        Kind.BOOL -> when (raw) { "1", "true" -> SettingValue.Bool(true); "0", "false" -> SettingValue.Bool(false); else -> null }
        Kind.INT -> raw.trim().toLongOrNull()?.let { SettingValue.Int(it) }
            ?: raw.trim().toDoubleOrNull()?.takeIf { it % 1.0 == 0.0 }?.let { SettingValue.Int(it.toLong()) }
        Kind.DOUBLE -> raw.trim().toDoubleOrNull()?.takeIf { it.isFinite() }?.let { SettingValue.Double(it) }
        Kind.TEXT -> SettingValue.Text(raw)
        Kind.DATA -> SettingValue.Data(if (raw.startsWith(B64)) java.util.Base64.getDecoder().decode(raw.removePrefix(B64)) else raw.toByteArray(Charsets.UTF_8))
        Kind.LIST -> runCatching { JSONArray(raw).let { j -> SettingValue.Items((0 until j.length()).map { j.getString(it) }) } }.getOrNull()
        Kind.MAP -> runCatching {
            val o = JSONObject(raw)
            SettingValue.Pairs(o.keys().asSequence().associateWith { o.getString(it) })
        }.getOrNull()
    }

    private fun encode(value: SettingValue): String = when (value) {
        is SettingValue.Bool -> if (value.value) "1" else "0"
        is SettingValue.Int -> value.value.toString()
        is SettingValue.Double -> value.value.let { if (it % 1.0 == 0.0 && kotlin.math.abs(it) < 1e15) it.toLong().toString() + ".0" else it.toString() }
        is SettingValue.Text -> value.value
        is SettingValue.Data -> runCatching {
            // JSON written by either app stays readable text; arbitrary bytes get a marker.
            Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(value.value)).toString().takeIf { !it.startsWith(B64) }
        }.getOrNull() ?: (B64 + java.util.Base64.getEncoder().encodeToString(value.value))
        is SettingValue.Items -> JSONArray(value.value).toString()
        is SettingValue.Pairs -> JSONObject(value.value as Map<*, *>).toString()
    }

    companion object {
        private const val B64 = "\u0000b64:"
        private const val PLUGIN_PREFIX = "gesehenVonPlugin|"
        private const val SERVER_LIST_KEY = "gesehenVonServer"

        /** Name and type of every key of `swiftly-settings/src/keys.rs` (generated from it, compared by a unit test). */
        val TYPES: Map<String, Kind> = mapOf(
        "technikschild" to Kind.BOOL,
        "technikschildMessen" to Kind.BOOL,
        "introAbspannAuto" to Kind.BOOL,
        "endzeitImPlayer" to Kind.BOOL,
        "bildfuellend" to Kind.BOOL,
        "querformatFest" to Kind.BOOL,
        "zurueckSek" to Kind.INT,
        "vorSek" to Kind.INT,
        "playerLautstaerke" to Kind.DOUBLE,
        "playerLautstaerkeDavor" to Kind.DOUBLE,
        "immerDirectPlay" to Kind.BOOL,
        "bitratenGrenze" to Kind.INT,
        "bildrateAnpassen" to Kind.BOOL,
        "startmessung" to Kind.BOOL,
        "utAussehen" to Kind.DATA,
        "utAuto" to Kind.BOOL,
        "utAutoNachgezogen" to Kind.BOOL,
        "tonSprache" to Kind.TEXT,
        "utSprache" to Kind.TEXT,
        "naechsteAuto" to Kind.BOOL,
        "utJeTitel" to Kind.MAP,
        "tonJeTitel" to Kind.MAP,
        "pufferstufe" to Kind.TEXT,
        "titelAlsLogo" to Kind.BOOL,
        "fortschritt" to Kind.BOOL,
        "merklisteAn" to Kind.BOOL,
        "alphabetAn" to Kind.BOOL,
        "gesehenVonAn" to Kind.BOOL,
        "gesehenVonServer" to Kind.LIST,
        "neuGetrennt" to Kind.BOOL,
        "startReihen" to Kind.LIST,
        "startReihenfolge" to Kind.LIST,
        "startAus" to Kind.LIST,
        "startGenres" to Kind.LIST,
        "genreChips" to Kind.BOOL,
        "startBibliotheken" to Kind.DATA,
        "letzteSuchen" to Kind.TEXT,
        "askProfileAtLaunch" to Kind.BOOL,
        "serverNamenCache" to Kind.MAP,
        "gattung.merkliste" to Kind.TEXT,
        "downloadsAn" to Kind.BOOL,
        "nurUeberWLAN" to Kind.BOOL,
        "naechsteFolgeLaden" to Kind.BOOL,
        "einstellungenSync" to Kind.BOOL,
        "einstellungenSyncZeit" to Kind.DOUBLE,
        "einstellungenSyncKonto" to Kind.TEXT,
        "einstellungenSyncServer" to Kind.DOUBLE,
        "letzterServer" to Kind.DATA,
        "nachmeldungen" to Kind.DATA,
        "discordAnzeigen" to Kind.BOOL,
        "discordHinweisGezeigt" to Kind.BOOL,
        "bewertungFassung" to Kind.TEXT,
        "bewertungFertig" to Kind.INT,
        "restzeitAlsEnde" to Kind.BOOL,
        "whatsnew.lastSeen" to Kind.TEXT,
        "look.selection" to Kind.DATA,
        "look.owned" to Kind.LIST,
        "look.gift.offered" to Kind.LIST,
        "look.effects" to Kind.BOOL,
        "look.debug.season" to Kind.BOOL,
        "support.status" to Kind.DATA,
        "support.usage" to Kind.DATA,
        "support.promptHistory" to Kind.DATA,
        "support.plan" to Kind.TEXT,
        "support.key" to Kind.TEXT,
        "support.keyChecked" to Kind.TEXT,
        "support.appIcon" to Kind.TEXT,
        "support.preview.profileIntroShown" to Kind.BOOL,
        "support.debug.simulatePurchases" to Kind.BOOL,

        )
    }
}
