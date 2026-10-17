package de.paulherter.swiftly.tv

import android.content.ContentValues
import android.net.Uri
import androidx.tvprovider.media.tv.TvContractCompat
import androidx.tvprovider.media.tv.WatchNextProgram
import de.paulherter.swiftly.Tile
import de.paulherter.swiftly.Rail
import de.paulherter.swiftly.SwiftlyApplication

/**
 * Android counterpart to Top Shelf on tvOS (`shelfWrite()` in `HomeView.swift` and the
 * `ShelfProvider.swift` extension). There the app writes eight entries each for the three rows
 * "Continue watching", "Next episode" and "Recently added" to a shared file on every home load;
 * an extension reads it when the home screen fills.
 * **Android TV has no extension and no app-group folder.** Instead there is a system provider,
 * `TvContractCompat.WatchNextPrograms`, which each app writes to directly. This file therefore
 * does what two files do on Apple: on every home load (`TvStart.kt`) it puts the same three rows
 * into the same system row "Continue watching" on the TV home screen, eight entries per row, in the
 * same order. `Rail.key` tells them apart: the raw, untranslated name from
 * `StartRail.railsTitle` (`StartRails.swift`), the same in every language.
 * **Checked on Android 14 / Google TV:** Watch Next stays open to every app without special
 * permission. The "Channels" route (`TvContractCompat.Channels` / `PreviewPrograms`, an own channel
 * row below Watch Next) now requires the system permission `WRITE_EPG_DATA`, which third-party apps
 * no longer get. Hence Watch Next only, no own channel.
 * Errors here must never disturb the app: every call runs in `runCatching`, and the provider is
 * accessed only when `updateNow`/`leeren` already run off the main thread (see the call site
 * in `TvStart.kt`).
 */
internal object TvContinueWatchingShelf {
    private const val KEY_CONTINUE_WATCHING = "Weiterschauen"
    private const val KEY_NEXT_EPISODE = "Nächste Folge"
    private const val KEY_LAST = "Zuletzt hinzugefügt"

    /** The same URL as in tvOS Top Shelf (`ShelfProvider.swift`: `swiftly://titel/<id>`). */
    private fun address(id: String): Uri = Uri.parse("swiftly://titel/$id")

    /**
     * Writes the three rows from the already loaded home rows into the Watch Next shelf.
     * `rails` is exactly what `TvStart.kt` holds for the home page itself: same source, no second fetch.
     */
    fun updateNow(app: SwiftlyApplication, rails: List<Rail>?) {
        if (!app.isTv || rails == null) return
        runCatching {
            val resolver = app.contentResolver

            // **Do not delete and recreate existing entries**; that makes the entry vanish briefly from the
            // home screen. `internalProviderId` carries the Jellyfin id and tells what to update and what is
            // stale. The provider shows only this app's rows anyway, so a foreign Watch Next row never arrives here.
            val alreadyThere = mutableMapOf<String, Long>()
            resolver.query(TvContractCompat.WatchNextPrograms.CONTENT_URI,
                arrayOf(TvContractCompat.WatchNextPrograms._ID,
                        TvContractCompat.WatchNextPrograms.COLUMN_INTERNAL_PROVIDER_ID),
                null, null, null)?.use { c ->
                val indexId = c.getColumnIndex(TvContractCompat.WatchNextPrograms._ID)
                val providerIndex = c.getColumnIndex(TvContractCompat.WatchNextPrograms.COLUMN_INTERNAL_PROVIDER_ID)
                while (c.moveToNext()) {
                    val jellyfinId = c.getString(providerIndex) ?: continue
                    alreadyThere[jellyfinId] = c.getLong(indexId)
                }
            }

            // Same order as on the home page: Continue watching, then Next episode, then Recently added.
            // Empty rows drop out, as in `shelfWrite()`.
            val categories = listOfNotNull(
                rails.firstOrNull { it.key == KEY_CONTINUE_WATCHING }
                    ?.let { it to TvContractCompat.WatchNextPrograms.WATCH_NEXT_TYPE_CONTINUE },
                rails.firstOrNull { it.key == KEY_NEXT_EPISODE }
                    ?.let { it to TvContractCompat.WatchNextPrograms.WATCH_NEXT_TYPE_NEXT },
                rails.firstOrNull { it.key == KEY_LAST }
                    ?.let { it to TvContractCompat.WatchNextPrograms.WATCH_NEXT_TYPE_NEW })

            var railsEpisode = 0
            val written = mutableSetOf<String>()
            categories.forEach { (rail, watchNextType) ->
                rail.tiles.take(8).forEach { k ->
                    written += k.id
                    val values = values(k, rail.landscape, watchNextType, railsEpisode++)
                    val existingRow = alreadyThere[k.id]
                    if (existingRow != null) {
                        resolver.update(withId(existingRow), values, null, null)
                    } else {
                        resolver.insert(TvContractCompat.WatchNextPrograms.CONTENT_URI, values)
                    }
                }
            }
            // Stale: was in the shelf before and belongs to none of the three rows now, e.g. finished or dropped off the home page.
            alreadyThere.forEach { (jellyfinId, row) ->
                if (jellyfinId !in written) resolver.delete(withId(row), null, null)
            }
        }
    }

    /** Mirrors `Shelf.leeren()` in `ShelfPreview.swift`; on sign-out and account switch. */
    fun wipe(app: SwiftlyApplication) {
        if (!app.isTv) return
        runCatching {
            app.contentResolver.delete(TvContractCompat.WatchNextPrograms.CONTENT_URI, null, null)
        }
    }

    private fun withId(row: Long) =
        TvContractCompat.WatchNextPrograms.CONTENT_URI.buildUpon().appendPath(row.toString()).build()

    private fun values(k: Tile, landscape: Boolean, watchNextType: Int, railsEpisode: Int): ContentValues {
        val type = if (k.type == "Episode") TvContractCompat.PreviewPrograms.TYPE_TV_EPISODE
                  else TvContractCompat.PreviewPrograms.TYPE_MOVIE
        val build = WatchNextProgram.Builder()
            .setType(type)
            .setWatchNextType(watchNextType)
            .setTitle(k.name)
            .setInternalProviderId(k.id)
            .setIntentUri(address(k.id))
            // Controls only the order **within** this app row, the same as on the home page. Newer than the
            // last entry of the previous row, or Android orders them as it sees fit.
            .setLastEngagementTimeUtcMillis(System.currentTimeMillis() - railsEpisode * 1000L)
        // Episode title / series name as in tvOS Top Shelf: for episodes `subline` carries the
        // season/episode code and `name` already the series title (see `tile()` in `Core.swift`).
        k.subline?.let { build.setEpisodeTitle(it) }
        (if (landscape) k.landscape ?: k.poster else k.poster)?.let { build.setPosterArtUri(Uri.parse(it)) }
        // Real milliseconds for the progress bar, not just the share; otherwise the system launcher
        // showed an invented remaining time. See `TileResponse` in `Core.swift`.
        val runtime = k.runtimeSeconds
        val position = k.positionSeconds
        if (watchNextType == TvContractCompat.WatchNextPrograms.WATCH_NEXT_TYPE_CONTINUE
            && runtime != null && runtime > 0 && position != null && position > 0) {
            build.setDurationMillis((runtime * 1000).toInt())
            build.setLastPlaybackPositionMillis((position * 1000).toInt())
        }
        return build.build().toContentValues()
    }
}
