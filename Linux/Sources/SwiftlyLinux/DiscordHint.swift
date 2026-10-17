import CGtk
import Foundation
import JellyfinKit

/// **Once per installation: Swiftly has a Discord.**
///
/// Ported from `Sources/macOS/RootView.swift` (`Discordhinweis`): after the
/// fifth finished title, once the player is closed, with a 1.5 s delay. A card
/// at the bottom right instead of a window: it covers nothing, and a click on
/// the cross dismisses it for good. **No rating prompt**, since there is no
/// store here; the package does not make the Discord hint wait for a prompt
/// that is never asked (`Community.kickoff`, `ratingPossible: false`).
extension App {

    /// Finished watching? Counts toward the Discord hint, once per title, like
    /// `PlayerScreen.zaehlen` on the Mac: on close and on episode change.
    func readyCount(_ title: Item?, position: Double, duration: Double) {
        guard let title, countedTitle != title.id else { return }
        countedTitle = title.id
        guard RatingQuestion.countsAsReady(position: position, duration: duration) else { return }
        selection.doneWatch += 1
        if Community.kickoff(done: selection.doneWatch, ratingLast: nil,
                                version: Version.number,
                                discordShown: selection.discordHintShown,
                                ratingPossible: false) == .discord {
            // Mark it as shown right away: if the app crashes or is closed first, the
            // hint rather never appears than appears twice.
            selection.discordHintShown = true
            discordHintDue = true
        }
        selection.secure()
    }

    /// After the player closes: if the hint is due, it appears after a short
    /// delay, and only if no player is open by then.
    func discordHintCheck() {
        guard discordHintDue else { return }
        discordHintDue = false
        Task.detached { [self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            onMainThread {
                guard self.runningTitle == nil else {
                    self.discordHintDue = true
                    return
                }
                self.discordCardShow()
            }
        }
    }

    private func discordCardShow() {
        guard discordCard == nil, let cover = windowCover else { return }
        let card = stack(GTK_ORIENTATION_VERTICAL, spacing: 10)
        gtk_widget_add_css_class(card, "swiftly-discordkarte")
        gtk_widget_set_size_request(card, 320, -1)
        gtk_widget_set_halign(card, GTK_ALIGN_END)
        gtk_widget_set_valign(card, GTK_ALIGN_END)
        gtk_widget_set_margin_end(card, Int32(Theme.edgeSpacing))
        gtk_widget_set_margin_bottom(card, Int32(Theme.edgeSpacing))

        let header = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let title = label(translated("Swiftly hat einen Discord"), style: "swiftly-listentitel")
        gtk_label_set_xalign(OpaquePointer(title), 0)
        gtk_widget_set_hexpand(title, 1)
        append(header, title)
        let toward: Widget! = gtk_button_new_from_icon_name("window-close-symbolic")
        gtk_widget_add_css_class(toward, "swiftly-handlung")
        gtk_widget_set_valign(toward, GTK_ALIGN_START)
        caption(toward, translated("Schließen"))
        signal(toward, "clicked") { [weak self] in self?.discordCardDistance() }
        append(header, toward)
        append(card, header)

        let text = label(translated("Da kannst du Fragen stellen und Fehler melden. Neue Builds stehen da auch zuerst."),
                                style: "swiftly-zweitzeile", wrap: true)
        gtk_widget_add_css_class(text, "swiftly-leise")
        gtk_label_set_xalign(OpaquePointer(text), 0)
        append(card, text)

        let button = primaryButton(translated("Discord beitreten"), symbol: "user-available-symbolic")
        gtk_widget_set_size_request(button, -1, Int32(Theme.primaryButtonHeight))
        gtk_widget_set_halign(button, GTK_ALIGN_FILL)
        gtk_widget_set_margin_top(button, 4)
        signal(button, "clicked") { [weak self] in
            browser(Community.discord)
            self?.discordCardDistance()
        }
        append(card, button)

        gtk_overlay_add_overlay(OpaquePointer(cover), card)
        discordCard = card
        gtk_widget_set_opacity(card, 0)
        crossfade(card, on: 1, duration: Theme.timeFadeFromIn)
    }

    /// Removes the card, also when a player opens.
    func discordCardDistance() {
        guard let card = discordCard, let cover = windowCover else { return }
        discordCard = nil
        gtk_overlay_remove_overlay(OpaquePointer(cover), card)
    }
}
