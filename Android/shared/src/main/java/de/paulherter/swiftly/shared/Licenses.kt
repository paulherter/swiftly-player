package de.paulherter.swiftly.shared

import android.content.Context
import org.json.JSONObject

/**
 * Open-source licenses; phone and TV read the same files.
 *
 * `LICENSES/components.json` and the full texts in `LICENSES/` exist once in the repo; the build
 * copies them to `assets/licenses/` (`phone/build.gradle.kts`). Nothing is entered by hand here,
 * since a second copy would drift. Only the components that ship in Android are shown.
 */
data class LicenseComponent(val id: String, val name: String, val version: String, val spdx: String,
                          val author: String, val source: String, val texts: List<String>,
                          val group: String, val note: String?)

data class OfferingSection(val title: String, val paragraphs: List<String>)

data class LicenseState(val components: List<LicenseComponent>, val offeringTitle: String,
                         val offering: List<OfferingSection>, val sourceSwiftly: String) {
    /** Player (Media3, FFmpeg) first, then the rest. */
    fun group(name: String) = components.filter { it.group == name }

    companion object {
        /** `null` if the file is missing from the build; the page says so instead of staying empty. */
        fun load(context: Context): LicenseState? = runCatching {
            val o = JSONObject(context.assets.open("licenses/components.json").bufferedReader().use { it.readText() })
            val list = o.getJSONArray("bausteine")
            val components = (0 until list.length()).map { list.getJSONObject(it) }.filter { b ->
                val p = b.getJSONArray("plattformen")
                (0 until p.length()).any { p.getString(it).let { s -> s == "android" || s == "androidtv" } }
            }.map { b ->
                val t = b.getJSONArray("texte")
                LicenseComponent(b.getString("id"), b.getString("name"), b.getString("version"), b.getString("spdx"),
                    b.getString("urheber"), b.getString("quelle"), (0 until t.length()).map { t.getString(it) },
                    b.optString("gruppe", "app"), b.optString("notiz").ifEmpty { null })
            }
            val a = o.getJSONObject("angebot")
            val sections = a.getJSONArray("abschnitte")
            LicenseState(components, a.getString("titel"),
                (0 until sections.length()).map { sections.getJSONObject(it) }.map { s ->
                    val since = s.getJSONArray("absaetze")
                    OfferingSection(s.getString("titel"), (0 until since.length()).map { since.getString(it) })
                }, a.getString("quelle_swiftly"))
        }.getOrNull()

        /** Full text of a license; `null` if the file is missing. */
        fun text(context: Context, file: String): String? = runCatching {
            context.assets.open("licenses/$file").bufferedReader().use { it.readText() }
        }.getOrNull()
    }
}

/** Intro sentence at the top of the page. The obligation depends on its wording, so it is the same in both versions. */
fun licenseInLine(): String = translated("Swiftly Player spielt mit AetherEngine und FFmpeg (Apple), Media3 (Android) und libmpv (Windows, Linux). Was sonst noch drinsteckt, steht darunter, mit Lizenz und Urheber.")

/** Short pointer under the offer link: earlier versions contained VLCKit and libVLC, the written offer for their source stays. */
fun licenseEarlierLine(): String = translated("Frühere Versionen enthielten VLCKit und libVLC (LGPL 2.1 oder später). Das schriftliche Angebot für ihren Quelltext gilt weiter, siehe „Quelltext und schriftliches Angebot“.")

/** The sources listed at the top: Swiftly's own repo, Media3 and FFmpeg upstream. */
fun licenseSources(inventory: LicenseState): List<String> =
    listOf(inventory.sourceSwiftly, "https://github.com/androidx/media", "https://ffmpeg.org/")
