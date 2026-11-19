package de.paulherter.swiftly

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import de.paulherter.swiftly.rustcore.AdminWords
import de.paulherter.swiftly.shared.translated

/**
 * **The action words of the management hub**, read from the core (`SeerrHub.adminWords`) in the account's language, the same
 * list the Apple hosts use through the shared catalogue. Before the first answer (the hub asks as it opens) the same keys come
 * from the catalogue, so a button never shows a word the core would not say.
 */
object ManagementWords {
    private var core by mutableStateOf<AdminWords?>(null)

    fun set(words: AdminWords) { core = words }

    fun current(): AdminWords = core ?: fromCatalogue()

    private fun fromCatalogue() = AdminWords(
        approve = translated("Freigeben"), decline = translated("Ablehnen"), retry = translated("Nochmal"),
        withdraw = translated("Zurückziehen"), reply = translated("Antworten"), resolve = translated("Erledigt"),
        reopen = translated("Wieder öffnen"), cancel = translated("Abbrechen"), back = translated("Zurück"),
        loading = translated("Moment…"), noReports = translated("Keine Meldungen"),
        nothingRequested = translated("Noch nichts angefragt"), seerrOffline = translated("Seerr antwortet gerade nicht"),
        reports = translated("Meldungen"), server = translated("Server"),
    )
}

@Composable
fun adminWords(): AdminWords = ManagementWords.current()
