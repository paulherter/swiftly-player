package de.paulherter.swiftly

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import coil3.compose.AsyncImage
import de.paulherter.swiftly.rustcore.RowWork
import de.paulherter.swiftly.rustcore.SeerrRequestRow
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.PrimaryButton
import de.paulherter.swiftly.shared.Strength
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.smoothRoundedShape
import de.paulherter.swiftly.shared.translated

/**
 * **One request opened** (Sources/Shared/RequestDetailView.swift): poster and state on top, the core's card of label/value rows (who asked,
 * version, quality, folder, seasons, when) and the verbs the core allows this account: "Freigeben", "Nochmal", "Ablehnen" (asks once),
 * "Zurückziehen". Opened from "Meine Anfragen" and from the queue; a verb tells the list through [RequestsChanged].
 * State: [RequestDetailModel]; texts from the catalogue and the core's words.
 */
@Composable
fun RequestDetailPage(app: SwiftlyApplication, target: Destination, back: () -> Unit) {
    val id = target.id.toLongOrNull()
    if (id == null) { LaunchedEffect(Unit) { back() }; return }
    val run = rememberCoroutineScope()
    val model = remember(id) { RequestDetailModel(app, run, id) }
    LaunchedEffect(id) { model.load() }
    var declineOpen by remember { mutableStateOf(false) }
    val d = model.detail
    SettingPage(d?.row?.title ?: target.name.ifEmpty { translated("Anfrage") }, back) {
        when {
            d != null -> {
                val row = d.row
                Row(Modifier.fillMaxWidth().padding(horizontal = Theme.edgeSpacing).padding(top = 4.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    AsyncImage(model = tmdbImage(row.poster, 342), contentDescription = null, contentScale = ContentScale.Crop,
                               modifier = Modifier.size(80.dp, 120.dp).clip(smoothRoundedShape(Theme.cornerTile)).background(Theme.area))
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(row.title, style = Theme.listTitle, color = Theme.font, maxLines = 3)
                        Text(listOfNotNull(translated(if (row.art == "tv") "Serie" else "Film"), row.detail).joinToString(" · "),
                             style = Theme.small, color = Theme.fontVeryQuiet)
                        Row(Modifier.padding(top = 2.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            Symbol(SeerrBadgeMark.glyph(row.badge.kind), 12.dp, color = SeerrBadgeMark.color(row.badge.kind), strength = Strength.Semibold)
                            Text(row.badge.line, style = Theme.small, color = SeerrBadgeMark.color(row.badge.kind))
                        }
                        row.badge.progress?.let { ProgressBar(it.toDouble(), Modifier.padding(top = 4.dp), round = true) }
                    }
                }
                if (d.rows.isNotEmpty()) Column(Modifier.padding(top = 18.dp).padding(horizontal = Theme.edgeSpacing).fillMaxWidth()
                        .clip(smoothRoundedShape(16.dp)).background(Theme.area)) {
                    d.rows.forEachIndexed { n, r ->
                        if (n > 0) Spacer(Modifier.padding(start = 16.dp).fillMaxWidth().height(1.dp).background(Theme.line))
                        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 13.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            Text(r.label, style = Theme.body, color = Theme.fontQuiet)
                            Text(r.value, style = Theme.body, color = Theme.font, textAlign = TextAlign.End, modifier = Modifier.weight(1f))
                        }
                    }
                }
                Verbs(row, model, ask = { declineOpen = true }, back = back)
                if (declineOpen) DeclineDialog(row.title, close = { declineOpen = false }) { model.decline() }
            }
            model.settled -> Column(Modifier.fillMaxWidth().padding(top = 80.dp).padding(horizontal = Theme.edgeSpacing), horizontalAlignment = Alignment.CenterHorizontally,
                                    verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(translated("Seerr antwortet gerade nicht"), style = Theme.listTitle, color = Theme.font)
                Text(translated("Diese Anfrage lässt sich gerade nicht lesen."), style = Theme.body, color = Theme.fontQuiet, textAlign = TextAlign.Center)
            }
            else -> Spacer(Modifier.height(400.dp))
        }
    }
}

@Composable
private fun Verbs(row: SeerrRequestRow, model: RequestDetailModel, ask: () -> Unit, back: () -> Unit) {
    val w = adminWords()
    Column(Modifier.padding(top = 18.dp).padding(horizontal = Theme.edgeSpacing), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        if (row.work == RowWork.WORKING) Text(row.workText.orEmpty(), style = Theme.small, color = Theme.accent)
        if (row.canApprove) PrimaryButton(w.approve, modifier = Modifier.semantics { contentDescription = "detail-approve" }) { model.approve() }
        if (row.canRetry) PrimaryButton(w.retry) { model.retry() }
        if (row.canDecline) SecondaryButton(Glyph.Cross, w.decline, accent = false, perform = ask)
        if (row.canWithdraw) SecondaryButton(Glyph.Cross, w.withdraw, accent = false) { model.withdraw(back) }
    }
}

/** "Anfrage ablehnen?": the question asks once, as the iPhone's sheet does (Seerr takes no reason). */
@Composable
private fun DeclineDialog(title: String, close: () -> Unit, confirm: () -> Unit) {
    Dialog(onDismissRequest = close) {
        Column(Modifier.clip(smoothRoundedShape(20.dp)).background(Theme.area).padding(20.dp).semantics { contentDescription = "decline-ask" },
               verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(translated("Anfrage ablehnen?"), style = Theme.small, color = Theme.fontQuiet)
            Text(title, style = Theme.listTitle, color = Theme.font, maxLines = 2)
            Text(translated("Wer sie gestellt hat, sieht nur „Abgelehnt“."), style = Theme.small, color = Theme.fontQuiet)
            Row(Modifier.padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(adminWords().cancel, style = Theme.buttonText, color = Theme.font,
                     modifier = Modifier.clip(smoothRoundedShape(Theme.corner)).background(Theme.reason).tapOn(close).padding(horizontal = 16.dp, vertical = 10.dp))
                Text(adminWords().decline, style = Theme.buttonText, color = Theme.warning,
                     modifier = Modifier.clip(smoothRoundedShape(Theme.corner)).background(Theme.reason).tapOn { close(); confirm() }
                         .semantics { contentDescription = "decline-confirm" }.padding(horizontal = 16.dp, vertical = 10.dp))
            }
        }
    }
}
