package de.paulherter.swiftly.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import de.paulherter.swiftly.PickerPurpose
import de.paulherter.swiftly.ServerKind
import de.paulherter.swiftly.ServerKindMark
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Strength
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.Wordmark
import de.paulherter.swiftly.shared.translated

/**
 * Mirrors `TVServerKindPicker` on tvOS: **which server, the first page of the app and the first
 * page of "Server hinzufügen".** Three cards in one column (the screen is wide, the remote moves in
 * lines), each with the mark, the name and one sentence. A press goes straight on; there is no
 * "Weiter" below, a choice of three that needs a fourth press to confirm is a form, and this is a
 * question. The kinds and their sentences are the phone's (`ServerKind` in `ServerKinds.kt`).
 *
 * **No primary button, on purpose.** None of the three kinds is the recommended one, so none may
 * look like it. The cards rest on `area` and light up with the calm focus surface of the settings
 * rows; white stays reserved for the action buttons on the pages that follow.
 *
 * `back`: "Abbrechen" and the Back key in `PickerPurpose.AddServer`; the first start has no way back.
 */
@Composable
fun TvServerKindPicker(purpose: PickerPurpose, pick: (ServerKind) -> Unit, back: () -> Unit = {}) {
    val first = firstFocus()
    if (purpose == PickerPurpose.AddServer) BackHandler(onBack = back)
    Box(Modifier.fillMaxSize().background(Theme.reason), contentAlignment = Alignment.Center) {
        Column(Modifier.width(TvSpec.messageWidth)) {
            when (purpose) {
                PickerPurpose.FirstStart -> Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                    Wordmark(height = TvSpec.serverWordmark)
                    Text(translated("Was läuft bei dir?"), style = TvTheme.titleLarge, color = Theme.font,
                         modifier = Modifier.padding(top = TvSpec.pickerHeadlineTop))
                    Text(translated("Weitere Server kannst du später dazunehmen, auch gemischt."),
                         style = TvTheme.body, color = Theme.fontQuiet, textAlign = TextAlign.Center,
                         modifier = Modifier.padding(top = TvSpec.pickerSentenceTop))
                }
                PickerPurpose.AddServer -> Column {
                    Text(translated("Server hinzufügen"), style = TvTheme.titleLarge, color = Theme.font)
                    Text(translated("Du bleibst bei allen angemeldet und wechselst auf der Profilseite zwischen ihnen."),
                         style = TvTheme.body, color = Theme.fontQuiet,
                         modifier = Modifier.padding(top = TvSpec.pickerSentenceTop))
                }
            }
            Column(Modifier.padding(top = TvSpec.pickerCardsTop), verticalArrangement = Arrangement.spacedBy(TvSpec.pickerCardSpacing)) {
                ServerKind.pickerOrder.forEachIndexed { index, kind ->
                    TvKindCard(kind, if (index == 0) Modifier.focusRequester(first) else Modifier) { pick(kind) }
                }
            }
            if (purpose == PickerPurpose.AddServer) {
                TvButton(translated("Abbrechen"), modifier = Modifier.padding(top = TvSpec.pickerCancelTop), perform = back)
            }
        }
    }
}

/**
 * Mirrors `TVKindCardStyle`: `area` at rest, the calm focus surface on top while the remote is on
 * it, and the wide step of the focus magnifier (the card is wider than 500 on tvOS). Never white and
 * never the accent, as the settings rows. `released = false` dims it like a picker that waits.
 */
@Composable
private fun TvKindCard(kind: ServerKind, modifier: Modifier = Modifier, released: Boolean = true, perform: () -> Unit) {
    FocusArea(modifier.fillMaxWidth(), magnifier = TvTheme.focusMagnifierWide, perform = { if (released) perform() }) { focus ->
        Row(Modifier.fillMaxWidth()
                .alpha(if (released) 1f else TvSpec.pickerDimWaitingOpacity)
                .clip(RoundedCornerShape(TvTheme.corner))
                .background(Theme.area)
                .background(tvFocusSurface(focus))
                .padding(horizontal = TvSpec.pickerCardInsetHorizontal, vertical = TvSpec.pickerCardInsetVertical),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(TvSpec.pickerCardGap)) {
            Box(Modifier.size(TvSpec.pickerCardMarkBox), contentAlignment = Alignment.Center) {
                ServerKindMark(kind, TvSpec.pickerCardMark)
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(TvSpec.pickerCardTextSpacing)) {
                Text(kind.shownName, style = TvTheme.button, color = Theme.font)
                Text(kind.pitch, style = TvTheme.small, color = Theme.fontQuiet, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
            Symbol(Glyph.AngleRight, TvSpec.valueIcon, color = Theme.fontVeryQuiet, strength = Strength.Semibold)
        }
    }
}
