package de.paulherter.swiftly

import android.content.Context
import android.content.Intent
import android.net.Uri
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.withContext
import org.json.JSONArray

/**
 * Starts a title's trailer; mirrors `TrailerStart.start` on iOS. **The order is the package's**
 * (`TrailerChoice`, through `Kern.trailers`): files the server keeps first, in the app's own
 * player like any other title, then the linked page in the browser. Returns the message to show
 * when nothing could be started, `null` when something was.
 *
 * Before 01.11.2026 the phone only ever opened the link; a trailer stored next to the movie was
 * never asked for.
 */
internal suspend fun trailerStart(app: SwiftlyApplication, context: Context, id: String): String? {
    val found = try {
        JSONArray(withContext(Dispatchers.IO) { app.kern.trailers(id, true).await() })
    } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (_: Exception) { JSONArray() }
    for (i in 0 until found.length()) {
        val entry = found.getJSONObject(i)
        if (entry.getString("art") == "datei") {
            // A file the server cannot describe is skipped while another candidate is left (as
            // `TrailerStart` on iPhone); the last one goes to the player, which reports its own error.
            if (i < found.length() - 1) {
                val planned = try {
                    withContext(Dispatchers.IO) { app.kern.plan(entry.getString("id")).await() } != "{}"
                } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (_: Exception) { false }
                if (!planned) continue
            }
            app.play.value = PlayRequest(entry.getString("id"), null)
            return null
        }
        val opened = runCatching {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(entry.getString("adresse"))))
        }.isSuccess
        if (opened) return null
    }
    return translated("Für diesen Titel liegt kein Trailer vor.")
}

/**
 * The trailer files of a title for the TV's extras row (`TrailerChoice.files`): no link, a TV has
 * no browser. Several are all shown; a title the server also lists among its extras appears once
 * (`TrailerChoice.shelf`: trailers lead, then extras, by id).
 */
internal suspend fun trailerShelf(app: SwiftlyApplication, id: String, extras: List<Extra>): List<Extra> {
    val found = try {
        JSONArray(withContext(Dispatchers.IO) { app.kern.trailers(id, false).await() })
    } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (_: Exception) { JSONArray() }
    val files = (0 until found.length()).map { found.getJSONObject(it) }
        .filter { it.getString("art") == "datei" }
        .map { Extra(it.getString("id"), it.getString("name"), it.fieldText("bild"), it.fieldText("laufzeit")) }
    return (files + extras).distinctBy { it.id }
}
