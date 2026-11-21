package de.paulherter.swiftly

import de.paulherter.swiftly.rustcore.MenuKind
import de.paulherter.swiftly.rustcore.MoreFactsInput
import de.paulherter.swiftly.rustcore.PlayOnDevice
import de.paulherter.swiftly.rustcore.detailMoreMenu
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Texts

/**
 * **The "More" sheet of a film or series page on the phone, from the core's list** (`DetailVm::more_menu`, the rule the
 * iPhone and Apple TV draw): entries, order and words all come from the core, so no entry can get lost here. The page only
 * maps each entry to its action id and icon.
 */
internal class PhoneMore(val choices: List<Choice>, val icons: Map<String, Glyph>)

internal const val MORE_TRAILER = "trailer"
internal const val MORE_FROM_START = "vonvorn"
internal const val MORE_RESET = "zuruecksetzen"
internal const val MORE_NEXT = "naechste"
internal const val MORE_SHUFFLE = "zufaellig"
internal const val MORE_TOGETHER = "gemeinsam"
internal const val MORE_METADATA = "metadaten"

internal fun phoneMore(app: SwiftlyApplication, series: Boolean, planKnown: Boolean, begun: Boolean, together: Boolean): PhoneMore {
    val devices = app.playTargets.value.map { PlayOnDevice(it.deviceID, it.name) }
    val list = detailMoreMenu(Texts.language,
        MoreFactsInput(series = series, planKnown = planKnown, begun = begun, together = together,
            downloadButton = app.settings.downloadButtonShow, playOn = devices))
    val choices = ArrayList<Choice>()
    val icons = HashMap<String, Glyph>()
    for (e in list) {
        val (id, glyph) = when (val k = e.kind) {
            is MenuKind.PlayOn -> PLAY_ON_PREFIX + k.id to Glyph.Tv
            is MenuKind.Trailer -> MORE_TRAILER to Glyph.Film
            is MenuKind.PlayFromStart, is MenuKind.PlayEpisodeFromStart -> MORE_FROM_START to Glyph.Rewind
            is MenuKind.ResetProgress -> MORE_RESET to Glyph.ResetCircle
            is MenuKind.NextEpisode -> MORE_NEXT to Glyph.Skip
            is MenuKind.Shuffle -> MORE_SHUFFLE to Glyph.Shuffle
            is MenuKind.Together -> MORE_TOGETHER to Glyph.Cluster
            is MenuKind.RefreshMetadata -> MORE_METADATA to Glyph.Reload
            else -> continue
        }
        choices.add(Choice(id, e.text)); icons[id] = glyph
    }
    return PhoneMore(choices, icons)
}
