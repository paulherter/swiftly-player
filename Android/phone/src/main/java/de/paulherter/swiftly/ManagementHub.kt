package de.paulherter.swiftly

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import de.paulherter.swiftly.rustcore.HubSectionKind
import de.paulherter.swiftly.rustcore.ProfileEntry
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated

/**
 * **Profile > "Verwaltung" / "Meine Anfragen"**: the one page behind the one Profile row (`ManagementHubView` on iPhone).
 * The core decides the sections ([ManagementEntry]); a tab row over them, and one section alone shows no tab row.
 * Nothing is decided here: each section draws its own content.
 */
@Composable
fun ManagementHubPage(app: SwiftlyApplication, open: (Destination) -> Unit, back: () -> Unit) {
    // The last answer is there in the first frame (the Profile page asked just before); a fresh one replaces it.
    var entry by remember { mutableStateOf<ProfileEntry?>(ManagementEntry.last(app)) }
    LaunchedEffect(Unit) { entry = ManagementEntry.load(app) }
    var selected by rememberSaveable { mutableIntStateOf(0) }
    val e = entry
    val sections = e?.let { ManagementEntry.drawn(it) }.orEmpty()
    val section = sections.getOrNull(selected) ?: sections.firstOrNull()
    SettingPage(e?.title ?: translated("Verwaltung"), back) {
        if (sections.size > 1) {
            Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = Theme.edgeSpacing).padding(bottom = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                sections.forEachIndexed { n, s ->
                    val on = s == section
                    Text(ManagementEntry.tabLabel(s), style = Theme.small, color = if (on) Theme.reason else Theme.font,
                         modifier = Modifier.clip(CircleShape).background(if (on) Theme.font else Theme.area)
                             .semantics { contentDescription = "verwaltung-tab-" + s.kind.name.lowercase() }
                             .tapOn { selected = n }.padding(horizontal = 14.dp, vertical = 8.dp))
                }
            }
        }
        when (section?.kind) {
            HubSectionKind.REQUESTS -> if (section.manage) AdminQueueContent(app, open) else SeerrRequestsContent(app, open)
            HubSectionKind.ISSUES -> AdminIssuesContent(app, open)
            HubSectionKind.SERVER -> ServerAdminContent(app)
            else -> {}
        }
    }
}
