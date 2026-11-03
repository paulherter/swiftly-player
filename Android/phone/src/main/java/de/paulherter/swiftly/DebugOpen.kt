package de.paulherter.swiftly

/**
 * Debug builds only: opens a page straight away by launch extras, for screenshots without taps.
 * `page` = start, movies, series, downloads, search, movie-detail, series-detail, watchlist, profile,
 * settings, playback-settings, appearance, server-choice, sign-in, selection-sheet, player.
 * Titles take `itemId` (+ optional `itemName`). No counterpart on Apple; there it is a launch argument.
 */
class DebugOpen(val page: String, val itemId: String, val itemName: String) {
    val since = System.currentTimeMillis()
    companion object {
        var pending: DebugOpen? = null
        fun read(intent: android.content.Intent?) {
            if (!BuildConfig.DEBUG) return
            val page = intent?.getStringExtra("page") ?: return
            pending = DebugOpen(page, intent.getStringExtra("itemId").orEmpty(), intent.getStringExtra("itemName").orEmpty())
        }
    }

    /** The section to switch to and the stack on it. */
    fun target(): Pair<Region, List<Destination>> = when (page) {
        "movies" -> Region.Movies to emptyList()
        "series" -> Region.Series to emptyList()
        "downloads" -> Region.Downloads to emptyList()
        "search" -> Region.Search to emptyList()
        "movie-detail" -> Region.Movies to listOf(Destination(itemId, itemName, "Movie"))
        "series-detail" -> Region.Series to listOf(Destination(itemId, itemName, "Series"))
        "watchlist" -> Region.Start to listOf(Destination("merkliste", "Merkliste", "Merkliste"))
        "profile" -> Region.Start to listOf(Destination("profil", "Profil", "Profil"))
        "settings" -> Region.Start to profileAnd(Destination("einstellungen", "Allgemein", "Einstellungen"))
        "playback-settings" -> Region.Start to profileAnd(Destination("wiedergabe", "Wiedergabe", "Wiedergabeeinstellungen"))
        "appearance" -> Region.Start to profileAnd(Destination("darstellung", "Darstellung", "Darstellung"))
        "server-choice" -> Region.Start to profileAnd(Destination("serveraufnahme", "Server hinzufügen", "ServerAufnahme"))
        "sign-in" -> Region.Start to profileAnd(Destination("weiteresKonto", "Konto hinzufügen", "WeiteresKonto"))
        else -> Region.Start to emptyList()
    }

    private fun profileAnd(d: Destination) = listOf(Destination("profil", "Profil", "Profil"), d)
}
