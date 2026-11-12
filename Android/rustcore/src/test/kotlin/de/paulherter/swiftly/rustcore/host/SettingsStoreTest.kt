package de.paulherter.swiftly.rustcore.host

import de.paulherter.swiftly.rustcore.SettingValue
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

private class Prefs : StringPrefs {
    val map = LinkedHashMap<String, String>()
    override fun get(key: String) = map[key]
    override fun put(key: String, value: String) { map[key] = value }
    override fun remove(key: String) { map.remove(key) }
    override fun keys(): Set<String> = map.keys
}

/** Old Android preferences hold everything as strings; the typed store must read them and write them back unchanged. */
class SettingsStoreTest {
    private val prefs = Prefs()
    private val store = AndroidSettingsStore(prefs)

    /** An old preference file, written by `Store.remember` with the string forms of `Settings.kt`. */
    private fun oldFile() = prefs.map.putAll(
        mapOf(
            "immerDirectPlay" to "0", "bitratenGrenze" to "20", "querformatFest" to "1", "zurueckSek" to "15",
            "tonSprache" to "deu", "utAussehen" to """{"groesse":3}""", "naechsteAuto" to "1",
            "startReihen" to """["fortsetzen","neu"]""", "startAus" to "[]",
            "utJeTitel" to """{"a|1":"eng"}""", "einstellungenSyncZeit" to "1762600000.5",
            "gesehenVon" to "0", "sortierung.filme" to "datum", "filter.filme" to "alle",
            "startBibliotheken|srv" to """[{"id":"x"}]""", "immerDirectPlay|srv" to "1",
            // not settings: must never be listed
            "konten.tresor" to "AAAA", "de.paulherter.swiftly.deviceID" to "abc", "sitzung" to "x",
        ),
    )

    @Test fun oldStringsReadAsTheirTypes() {
        oldFile()
        assertEquals(SettingValue.Bool(false), store.get("immerDirectPlay"))
        assertEquals(SettingValue.Int(20), store.get("bitratenGrenze"))
        assertEquals(SettingValue.Bool(true), store.get("querformatFest"))
        assertEquals(SettingValue.Int(15), store.get("zurueckSek"))
        assertEquals(SettingValue.Text("deu"), store.get("tonSprache"))
        assertEquals(SettingValue.Bool(true), store.get("naechsteAuto"))
        assertEquals(SettingValue.Items(listOf("fortsetzen", "neu")), store.get("startReihen"))
        assertEquals(SettingValue.Items(emptyList()), store.get("startAus"))
        assertEquals(SettingValue.Pairs(mapOf("a|1" to "eng")), store.get("utJeTitel"))
        assertEquals(SettingValue.Double(1762600000.5), store.get("einstellungenSyncZeit"))
        assertEquals(SettingValue.Bool(false), store.get("gesehenVonAn"))
        assertEquals(SettingValue.Text("datum"), store.get("sortierung.filme"))
        assertEquals(SettingValue.Bool(true), store.get("immerDirectPlay|srv"))
        assertArrayEquals("""{"groesse":3}""".toByteArray(), (store.get("utAussehen") as SettingValue.Data).value)
        assertArrayEquals("""[{"id":"x"}]""".toByteArray(), (store.get("startBibliotheken|srv") as SettingValue.Data).value)
        assertNull(store.get("einstellungenSyncKonto"))
    }

    @Test fun valuesThatDoNotFitTheirTypeReadAsAbsent() {
        prefs.put("immerDirectPlay", "vielleicht"); prefs.put("bitratenGrenze", "viel"); prefs.put("startReihen", "kein json")
        assertNull(store.get("immerDirectPlay")); assertNull(store.get("bitratenGrenze")); assertNull(store.get("startReihen"))
    }

    @Test fun writesKeepTheOldStringForms() {
        store.set("immerDirectPlay", SettingValue.Bool(true))
        store.set("bitratenGrenze", SettingValue.Int(8))
        store.set("startReihen", SettingValue.Items(listOf("a", "b")))
        store.set("utAussehen", SettingValue.Data("""{"x":1}""".toByteArray()))
        store.set("utJeTitel", SettingValue.Pairs(mapOf("k" to "v")))
        store.set("einstellungenSyncZeit", SettingValue.Double(5.0))
        store.set("gesehenVonAn", SettingValue.Bool(false))
        assertEquals("1", prefs.get("immerDirectPlay"))
        assertEquals("8", prefs.get("bitratenGrenze"))
        assertEquals("""["a","b"]""", prefs.get("startReihen"))
        assertEquals("""{"x":1}""", prefs.get("utAussehen"))
        assertEquals("""{"k":"v"}""", prefs.get("utJeTitel"))
        assertEquals("5.0", prefs.get("einstellungenSyncZeit"))
        assertEquals("0", prefs.get("gesehenVon"))
        assertNull(prefs.get("gesehenVonAn"))
    }

    @Test fun binaryDataSurvivesARoundTrip() {
        val bytes = byteArrayOf(0, -1, -2, 5)
        store.set("letzterServer", SettingValue.Data(bytes))
        assertArrayEquals(bytes, (store.get("letzterServer") as SettingValue.Data).value)
    }

    @Test fun keysListsOnlySettings() {
        oldFile()
        val keys = store.keys()
        assertTrue("immerDirectPlay" in keys && "gesehenVonAn" in keys && "sortierung.filme" in keys && "immerDirectPlay|srv" in keys)
        assertTrue(keys.none { it.endsWith(".tresor") || it == "sitzung" || it.contains("deviceID") })
    }

    @Test fun pluginServersAreOneListOfFlags() {
        prefs.put("gesehenVonPlugin|a", "1"); prefs.put("gesehenVonPlugin|b", "0")
        assertEquals(SettingValue.Items(listOf("a")), store.get("gesehenVonServer"))
        store.set("gesehenVonServer", SettingValue.Items(listOf("c")))
        assertEquals("1", prefs.get("gesehenVonPlugin|c")); assertNull(prefs.get("gesehenVonPlugin|a"))
        assertEquals("0", prefs.get("gesehenVonPlugin|b"))
    }

    @Test fun removeAndChangeNotification() {
        val seen = ArrayList<String>()
        val s = AndroidSettingsStore(prefs) { seen += it }
        s.set("fortschritt", SettingValue.Bool(false)); s.remove("fortschritt")
        assertEquals(listOf("fortschritt", "fortschritt"), seen)
        assertNull(prefs.get("fortschritt"))
    }

    /** The table is the registry of the Rust crate: same names, same types. */
    @Test fun tableMatchesTheRustRegistry() {
        var dir: File? = File("").absoluteFile
        while (dir != null && !File(dir, "crates/swiftly-settings/src/keys.rs").exists()) dir = dir.parentFile
        val text = File(dir ?: return, "crates/swiftly-settings/src/keys.rs").readText()
        val rows = Regex("""^\s+[A-Z_0-9]+: ([^=]+?) = .*?"([^"]+)", \w+,""", RegexOption.MULTILINE).findAll(text).toList()
        val kind = mapOf(
            "bool" to AndroidSettingsStore.Kind.BOOL, "Option<bool>" to AndroidSettingsStore.Kind.BOOL,
            "i64" to AndroidSettingsStore.Kind.INT, "f64" to AndroidSettingsStore.Kind.DOUBLE,
            "Option<f64>" to AndroidSettingsStore.Kind.DOUBLE, "String" to AndroidSettingsStore.Kind.TEXT,
            "Option<String>" to AndroidSettingsStore.Kind.TEXT, "Option<Vec<u8>>" to AndroidSettingsStore.Kind.DATA,
            "Vec<String>" to AndroidSettingsStore.Kind.LIST, "Option<BTreeMap<String, String>>" to AndroidSettingsStore.Kind.MAP,
        )
        assertTrue(rows.size > 60)
        for (r in rows) assertEquals(r.groupValues[2], kind[r.groupValues[1].trim()], AndroidSettingsStore.TYPES[r.groupValues[2]])
        assertEquals(rows.size, AndroidSettingsStore.TYPES.size)
    }
}
