package de.paulherter.swiftly.tv

import de.paulherter.swiftly.Choice
import de.paulherter.swiftly.SwiftlyApplication
import de.paulherter.swiftly.playOnChosen
import de.paulherter.swiftly.rustcore.MenuKind
import de.paulherter.swiftly.rustcore.MoreFactsInput
import de.paulherter.swiftly.rustcore.PlayOnDevice
import de.paulherter.swiftly.rustcore.detailMoreMenu
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Texts

/**
 * **The "..." panel of a film or a series, from the core's list** (`DetailVm::more_menu`, what Apple TV draws): the entries,
 * their order and their words ("Abspielen auf <Gerät>" first, one for each device in reach) all come from the core, so the
 * next change there reaches the TV at once. As on Apple TV (`TVRowActions`), "Shuffle" and "Watch together" are not in the
 * panel: the row has a button of their own for each, so nothing is offered twice.
 */
internal class TvMore(val choices: List<Choice>, val icons: Map<String, Glyph>)

internal const val TV_MORE_FROM_START = "vonvorn"
internal const val TV_MORE_RESET = "zuruecksetzen"
internal const val TV_MORE_NEXT = "naechste"
internal const val TV_MORE_METADATA = "metadaten"

internal fun tvMore(app: SwiftlyApplication, series: Boolean, planKnown: Boolean, begun: Boolean, together: Boolean): TvMore {
    val devices = app.playTargets.value.map { PlayOnDevice(it.deviceID, it.name) }
    val list = detailMoreMenu(Texts.language,
        MoreFactsInput(series = series, planKnown = planKnown, begun = begun, together = together, downloadButton = false, playOn = devices))
    val choices = ArrayList<Choice>()
    val icons = HashMap<String, Glyph>()
    for (e in list) {
        val (id, glyph) = when (val k = e.kind) {
            is MenuKind.PlayOn -> de.paulherter.swiftly.PLAY_ON_PREFIX + k.id to Glyph.Tv
            is MenuKind.PlayFromStart, is MenuKind.PlayEpisodeFromStart -> TV_MORE_FROM_START to Glyph.Rewind
            is MenuKind.ResetProgress -> TV_MORE_RESET to Glyph.ResetCircle
            is MenuKind.NextEpisode -> TV_MORE_NEXT to Glyph.Skip
            is MenuKind.RefreshMetadata -> TV_MORE_METADATA to Glyph.Reload
            // The row's own buttons (Shuffle, Together) and what the TV does not offer (Trailer).
            else -> continue
        }
        choices.add(Choice(id, e.text)); icons[id] = glyph
    }
    return TvMore(choices, icons)
}
