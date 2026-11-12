package de.paulherter.swiftly.rustcore.host

import de.paulherter.swiftly.rustcore.SeerrSyncOutcome
import de.paulherter.swiftly.rustcore.SettingsSyncModel
import de.paulherter.swiftly.rustcore.SettingsSyncOutcome
import de.paulherter.swiftly.rustcore.SyncSetting
import org.json.JSONObject

/**
 * `Kern.settingsSyncRun` on the Rust core: the same arguments (times in milliseconds, 0 = never), the same answer JSON
 * (`decision`, `remote`, `stamp`, `values`, `seerr`, `seerrAccess`, `seerrStamp`), so `SettingsSyncRun.kt` does not
 * change. Differences that the caller already treats alike: a run with nothing of the device's own to write answers
 * `nothing` where the Swift facade said `empty`; an unreachable server is `error` as before.
 */
class SettingsSyncAdapter(private val model: SettingsSyncModel) {
    suspend fun run(local: String, localChanged: Double, remoteSeen: Double, otherAccount: Boolean, seerr: String, seerrChanged: Double): String {
        val values = JSONObject(local.ifBlank { "{}" }).let { o -> o.keys().asSequence().map { SyncSetting(it, o.getString(it)) }.toList() }
        val round = runCatching {
            model.runWithSeerr(
                values, localChanged.takeIf { it > 0 }?.div(1000.0), remoteSeen.takeIf { it > 0 }?.div(1000.0), otherAccount,
                System.currentTimeMillis() / 1000.0, seerr.takeIf { it.isNotEmpty() }, seerrChanged.takeIf { it > 0 }?.div(1000.0),
            )
        }.getOrNull() ?: return answer("error")
        val remoteMs = round.remoteChanged * 1000
        var out = JSONObject()
        out = when (val s = round.settings) {
            is SettingsSyncOutcome.Apply -> answer("apply", remoteMs, remoteMs, s.values.associate { it.name to it.value })
            is SettingsSyncOutcome.Pushed -> answer("push", s.changed * 1000, s.changed * 1000)
            SettingsSyncOutcome.Nothing -> answer("nothing", remoteMs)
            SettingsSyncOutcome.Unreachable -> return answer("error")
        }.let { JSONObject(it) }
        when (val x = round.seerr) {
            is SeerrSyncOutcome.Adopt -> out.put("seerr", "adopt").put("seerrAccess", x.access).put("seerrStamp", x.changed * 1000)
            is SeerrSyncOutcome.Pushed -> out.put("seerr", "push").put("seerrAccess", "").put("seerrStamp", x.changed * 1000)
            SeerrSyncOutcome.Nothing -> {}
        }
        return out.toString()
    }

    private fun answer(decision: String, remote: Double = 0.0, stamp: Double = 0.0, values: Map<String, String> = emptyMap()) =
        JSONObject().put("decision", decision).put("remote", remote).put("stamp", stamp)
            .put("values", JSONObject(values)).put("seerr", "nothing").put("seerrAccess", "").put("seerrStamp", 0.0).toString()
}
