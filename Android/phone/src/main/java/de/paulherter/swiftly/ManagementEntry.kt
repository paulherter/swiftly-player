package de.paulherter.swiftly

import de.paulherter.swiftly.rustcore.HubSection
import de.paulherter.swiftly.rustcore.HubSectionKind
import de.paulherter.swiftly.rustcore.ProfileEntry
import de.paulherter.swiftly.rustcore.ProfileEntryKind
import de.paulherter.swiftly.rustcore.ServerKind
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * **The one Profile entry for requests, reports and the server**, as the core decides it (`SeerrHub.profileEntry`):
 * "Verwaltung" for an administrator, "Meine Anfragen" for everyone else with Seerr, nothing without either. Phone and TV
 * both ask here; the page behind it ([ManagementHubPage], `TvManagementPage`) draws the core's sections as tabs.
 * Mirrors `ManagementEntryFlow` (Sources/Shared/ServerAdminHost.swift).
 */
object ManagementEntry {
    /** The last answer per account, so a page that opens later (the hub) has its title and sections in the first frame. */
    private val lastEntries = mutableMapOf<String, ProfileEntry?>()

    fun last(app: SwiftlyApplication): ProfileEntry? = synchronized(lastEntries) { lastEntries[app.accountId()] }

    /** Asks the server (administrator) and Seerr (rights, counts) and keeps the answer. Call from any thread. */
    suspend fun load(app: SwiftlyApplication): ProfileEntry? = withContext(Dispatchers.IO) {
        val key = app.accountId()
        val account = app.rk.account()
        val entry = try {
            if (account == null) null else {
                val administrator = account.serverKind == ServerKind.JELLYFIN &&
                    (try { app.rk.core().isAdministrator(account) } catch (e: CancellationException) { throw e } catch (_: Exception) { false })
                val hub = app.seerr.hub()
                if (app.seerrConnected.value) {
                    // The account is read once even when several screens ask at the same time (single-flight in the core).
                    if (hub.ensureAvailable()) hub.refreshCounts()
                }
                ManagementWords.set(hub.adminWords())
                hub.profileEntry(account.serverKind, administrator)
            }
        } catch (e: CancellationException) { throw e } catch (_: Exception) { null }
        synchronized(lastEntries) { lastEntries[key] = entry }
        entry
    }

    /** The count mark of the row: what waits for a manager; the own requests show none. */
    fun mark(entry: ProfileEntry): Int = if (entry.kind == ProfileEntryKind.ADMIN) entry.count.toInt() else 0

    /** The sections this app can draw today (the others stay unlisted rather than empty): all of them: requests (own list or the manager's queue), reports, server. */
    fun drawn(entry: ProfileEntry): List<HubSection> = entry.sections

    fun tabLabel(s: HubSection): String = if (s.count > 0) "${s.title} ${s.count}" else s.title

    val destination = Destination("verwaltung", "Verwaltung", "Verwaltung")
}
