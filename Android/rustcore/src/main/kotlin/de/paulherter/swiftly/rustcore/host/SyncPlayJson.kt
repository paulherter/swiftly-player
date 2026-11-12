package de.paulherter.swiftly.rustcore.host

import de.paulherter.swiftly.rustcore.SyncPlayGroupDetail
import de.paulherter.swiftly.rustcore.SyncPlayPage
import org.json.JSONArray
import org.json.JSONObject

/** The core's `SyncPlayPage` as the old `SharedResponse` JSON (`darfAnlegen`, `angebote`, `gruppe`, `ereignis` ...) that the app reads. */
object SyncPlayJson {
    private fun group(g: SyncPlayGroupDetail) = JSONObject().put("id", g.id).put("name", g.name)
        .put("teilnehmer", JSONArray(g.participants)).put("namen", JSONArray(g.names)).apply { g.phase?.let { put("zustand", it) } }

    fun state(p: SyncPlayPage): JSONObject {
        val d = p.detail
        return JSONObject().put("darfAnlegen", p.mayCreate).put("darfBeitreten", p.mayJoin)
            .put("angebote", JSONArray().also { a -> d.offerings.forEach { a.put(group(it)) } })
            .apply {
                d.group?.let { put("gruppe", group(it)) }
                put("andere", JSONArray(d.other))
                val kind = d.noticeKind; val text = p.notice; val id = d.noticeId
                if (kind != null && text != null && id != null) put("ereignis", JSONObject().put("id", id.toString()).put("art", kind).put("text", text))
                p.lastLeave?.let { put("zuletztVerlassen", it) }
                put("arbeitet", p.works)
                p.queueTitle?.let { put("schlangeTitel", it) }
                d.errorLast?.let { put("fehler", it) }
                put("fehlerNummer", d.errorCount.toLong())
                put("angenommen", d.accepted.toLong())
            }
    }
}
