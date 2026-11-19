package de.paulherter.swiftly.tv

import androidx.activity.compose.BackHandler
import de.paulherter.swiftly.adminWords
import de.paulherter.swiftly.shared.translated
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.unit.dp
import de.paulherter.swiftly.Destination
import de.paulherter.swiftly.ManagementEntry
import de.paulherter.swiftly.SwiftlyApplication
import de.paulherter.swiftly.rustcore.HubSectionKind
import de.paulherter.swiftly.rustcore.ListLoad
import de.paulherter.swiftly.rustcore.ProfileEntry
import de.paulherter.swiftly.rustcore.SeerrRequestsInfo
import de.paulherter.swiftly.shared.Theme
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * **Profile > "Verwaltung" / "Meine Anfragen" on TV**: the same page as on the phone (`ManagementHubPage`), drawn for the
 * remote. The core's sections are the tabs (one section alone: no tab row); the section draws the core's rows.
 */
@Composable
fun TvManagementPage(app: SwiftlyApplication, open: (Destination) -> Unit, back: () -> Unit) {
    BackHandler(onBack = back)
    var entry by remember { mutableStateOf<ProfileEntry?>(ManagementEntry.last(app)) }
    LaunchedEffect(Unit) { entry = ManagementEntry.load(app) }
    var selected by remember { mutableIntStateOf(0) }
    val sections = entry?.let { ManagementEntry.drawn(it) }.orEmpty()
    val section = sections.getOrNull(selected) ?: sections.firstOrNull()
    val first = firstFocus(ready = section != null)
    Column(Modifier.fillMaxSize().background(Theme.reason).verticalScroll(rememberScrollState())
            .padding(horizontal = TvTheme.edgePage, vertical = TvTheme.edgeTop).widthIn(max = 1000.dp)) {
        Text(entry?.title ?: translated("Verwaltung"), style = TvTheme.titleLarge, color = Theme.font)
        Spacer(Modifier.height(18.dp))
        if (sections.size > 1) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                sections.forEachIndexed { n, s ->
                    TvButton(ManagementEntry.tabLabel(s), height = 52.dp, active = s == section,
                             modifier = if (n == 0) Modifier.focusRequester(first) else Modifier) { selected = n }
                }
            }
            Spacer(Modifier.height(14.dp))
        }
        when (section?.kind) {
            HubSectionKind.REQUESTS -> {
                val firstRow = if (sections.size > 1) Modifier else Modifier.focusRequester(first)
                if (section.manage) TvAdminQueueContent(app, open, firstRow) else TvRequestsContent(app, open, firstRow)
            }
            HubSectionKind.ISSUES -> TvAdminIssuesContent(app, if (sections.size > 1) Modifier else Modifier.focusRequester(first))
            HubSectionKind.SERVER -> TvServerAdminContent(app, if (sections.size > 1) Modifier else Modifier.focusRequester(first))
            else -> {}
        }
    }
}

@Composable
private fun TvRequestsContent(app: SwiftlyApplication, open: (Destination) -> Unit, firstRow: Modifier) {
    var info by remember { mutableStateOf<SeerrRequestsInfo?>(null) }
    LaunchedEffect(Unit) {
        // The list of the last visit is there at once (the core's stash); the live read below replaces it.
        val stored = try { withContext(Dispatchers.IO) { app.seerr.lists().restoreRequests() } } catch (e: CancellationException) { throw e } catch (_: Exception) { null }
        if (stored != null && info == null) info = stored
        val live = withContext(Dispatchers.IO) { try { app.seerr.lists().loadRequests() } catch (e: CancellationException) { throw e } catch (_: Exception) { null } }
        info = live ?: info
    }
    val run = rememberCoroutineScope()
    val i = info
    when {
        i == null || i.load == ListLoad.LOADING || i.load == ListLoad.IDLE -> Text(adminWords().loading, style = TvTheme.body, color = Theme.fontQuiet)
        i.load == ListLoad.OFFLINE || i.load == ListLoad.FAILED ->
            Text(i.error ?: adminWords().seerrOffline, style = TvTheme.body, color = Theme.fontQuiet)
        else -> Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                i.pills.forEach { p ->
                    TvButton(p.title + " " + p.count, height = 48.dp, active = p.selected) {
                        run.launch { info = withContext(Dispatchers.IO) { app.seerr.lists().selectPill(p.pill) } }
                    }
                }
            }
            i.quotaSummary?.let { Text(it, style = TvTheme.small, color = Theme.fontQuiet) }
            if (i.rows.isEmpty()) Text(adminWords().nothingRequested, style = TvTheme.body, color = Theme.fontQuiet)
            i.rows.forEachIndexed { n, r ->
                TvAction(name = listOfNotNull(r.title, r.year?.let { "($it)" }).joinToString(" "), value = r.badge.line, arrow = false,
                         modifier = if (n == 0) firstRow else Modifier) { open(Destination(r.art + ":" + r.tmdb, r.title, "Seerrtitel")) }
            }
        }
    }
}
