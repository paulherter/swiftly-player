package de.paulherter.swiftly

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.LaunchedEffect
import de.paulherter.swiftly.rustcore.SubtitleSearchIntent
import de.paulherter.swiftly.rustcore.SubtitleSearchPart
import de.paulherter.swiftly.rustcore.SubtitleSearchPhase
import de.paulherter.swiftly.rustcore.SubtitleSearchVm

/**
 * The core's subtitle search (`SubtitleSearchVm`) as a Compose state, shared by the phone and the TV player: the first
 * search starts when the panel appears, every change of the core's part redraws, and a finished download reports the
 * stream index of the added track once (`added`), so the player reloads the title and switches it on. The screens only draw
 * `SubtitleSearchPart` and send intents; nothing is decided here.
 */
@Composable
fun rememberSubtitleSearch(vm: SubtitleSearchVm, added: (Long?) -> Unit): SubtitleSearchPart {
    var part by remember(vm) { mutableStateOf(vm.part()) }
    val report by rememberUpdatedState(added)
    LaunchedEffect(vm) {
        vm.send(SubtitleSearchIntent.Search(null))
        part = vm.part()
        var seen = part.version
        var reported = false
        while (true) {
            runCatching { vm.changed(seen) }.getOrNull() ?: break
            part = vm.part()
            seen = part.version
            if (part.phase == SubtitleSearchPhase.DONE && !reported) {
                reported = true
                report(part.selectedTrack)
            }
        }
    }
    return part
}
