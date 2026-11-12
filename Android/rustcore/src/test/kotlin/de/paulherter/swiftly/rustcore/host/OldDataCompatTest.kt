package de.paulherter.swiftly.rustcore.host

import de.paulherter.swiftly.rustcore.Core
import de.paulherter.swiftly.rustcore.DownloadsIntent
import de.paulherter.swiftly.rustcore.PlayerSection
import de.paulherter.swiftly.rustcore.SettingsFacts
import de.paulherter.swiftly.rustcore.SettingsIntent
import de.paulherter.swiftly.rustcore.SettingsPlatform
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.HttpURLConnection
import java.nio.file.Files
import javax.crypto.spec.SecretKeySpec

/** The real Rust core (JNA) over files and preferences exactly as the old build left them. */
class OldDataCompatTest {
    private class Mem : StringPrefs {
        val map = LinkedHashMap<String, String>()
        override fun get(key: String) = map[key]
        override fun put(key: String, value: String) { map[key] = value }
        override fun remove(key: String) { map.remove(key) }
        override fun keys(): Set<String> = map.keys
    }

    private class NoHooks : DownloadHooks {
        override suspend fun address(id: String, source: String?, quality: String, audioIndex: Int?) = error("none")
        override suspend fun subtitles(id: String, source: String?) {}
        override suspend fun sections(id: String): List<PlayerSection>? = null
        override suspend fun successor(id: String, seriesId: String): Pair<ByteArray, String?>? = null
        override fun prepare(connection: HttpURLConnection) {}
        override fun failureText(status: Int?, error: Throwable?) = "x"
    }

    private fun core(kv: StringPrefs) = Core(
        AndroidPlatform("Test-Pixel", null) {}, AndroidSecretStore(Mem(), GcmSealer { SecretKeySpec(ByteArray(32) { 9 }, "AES") }),
        AndroidKeyValueStore(kv), AndroidHttpClient(),
    )

    private fun facts() = SettingsFacts(
        platform = SettingsPlatform.PHONE, seerr = false, settingsSync = true, downloads = true, server = "", canConvert = true,
        watchersPlugin = false, landscapeLockPossible = true, seerrConnected = false, ownHeaders = 0u, subtitleLookSummary = "",
        storedDownloads = 0u, storedBytes = 0L, accountNextAuto = null,
    )

    @Test fun oldDownloadIndexListsInTheCore() {
        val folder = Files.createTempDirectory("dl").toFile()
        java.io.File(folder, "liste.json").writeText(
            """[{"id":"a","konto":"anna","art":"film","titel":"Der Film","bytes":1000,"geladen":1000,"stand":"fertig","gesehen":false,"angelegt":7.5e8,"nochAufDemServer":true,"container":"mkv"}]""",
        )
        val store = DownloadIndexStore(folder, AndroidKeyValueStore(Mem()))
        val host = AndroidDownloadHost(folder, NoHooks(), CoroutineScope(SupervisorJob() + Dispatchers.IO))
        val vm = Core(
            AndroidPlatform("Test-Pixel", null) {}, AndroidSecretStore(Mem(), GcmSealer { SecretKeySpec(ByteArray(32) { 9 }, "AES") }),
            store, AndroidHttpClient(),
        ).downloadsVm(host, "de", true, false)
        host.sink = { vm.send(it) }
        vm.send(DownloadsIntent.SignIn("anna", false))
        val rows = vm.list().rows
        assertEquals(1, rows.size)
        assertEquals("Der Film", rows[0].title)
        folder.deleteRecursively()
    }

    @Test fun settingsScreenReadsAndWritesTheOldStrings() {
        val prefs = Mem().also { it.map.putAll(mapOf("immerDirectPlay" to "0", "bitratenGrenze" to "20", "introAbspannAuto" to "0")) }
        val vm = core(Mem()).settingsVmNative(AndroidSettingsStore(prefs), "de", facts())
        assertTrue(vm.sections().sections.isNotEmpty())
        vm.send(SettingsIntent.SetSwitch("introAbspannAuto", true))
        vm.send(SettingsIntent.SetSwitch("immerDirectPlay", true))
        assertEquals("1", prefs.get("introAbspannAuto"))
        assertTrue(prefs.map.any { (k, v) -> k.startsWith("immerDirectPlay") && v == "1" })
        assertEquals("20", prefs.get("bitratenGrenze"))
    }
}
