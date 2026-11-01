import CGtk
import Foundation
import JellyfinKit

// MARK: - Which server: the first page of the app, and the first page of "Server hinzufügen"

// The counterpart of `Sources/macOS/MacKindPicker.swift`: the same three cards in the same
// order with the same words (`ServerKind.shownName`, `pitch`). One click goes straight on,
// there is no "Weiter" below.
//
// At the first start the column is centred like the address page next to it; from the
// profile it is a subpage at the left edge with its arrow.

extension App {

    /// The three cards in a column. `pick` gets the kind that was clicked.
    func kindCardsBuild(pick: @escaping (ServerKind) -> Void) -> Widget! {
        let column = stack(GTK_ORIENTATION_VERTICAL, spacing: 10)
        gtk_widget_set_size_request(column, Int32(Theme.formWidth), -1)
        for kind in ServerKind.pickerOrder {
            let card = rowsGroup()
            let button: Widget! = gtk_button_new()
            gtk_widget_add_css_class(button, "swiftly-einstellzeile")

            let row = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 14)
            gtk_widget_set_margin_start(row, 16)
            gtk_widget_set_margin_end(row, 16)
            gtk_widget_set_margin_top(row, 14)
            gtk_widget_set_margin_bottom(row, 14)
            let mark = KindMark(kind: kind, size: 34)
            let markHolder = compartment(mark.display, width: 44, height: 44)
            gtk_widget_set_valign(markHolder, GTK_ALIGN_CENTER)
            append(row, markHolder)

            let texts = stack(GTK_ORIENTATION_VERTICAL, spacing: 3)
            gtk_widget_set_valign(texts, GTK_ALIGN_CENTER)
            gtk_widget_set_hexpand(texts, 1)
            let name = label(kind.shownName, style: "swiftly-kontoname")
            gtk_label_set_xalign(OpaquePointer(name), 0)
            append(texts, name)
            let pitch = label(kind.pitch, style: "swiftly-zweitzeile", wrap: true)
            gtk_widget_add_css_class(pitch, "swiftly-leise")
            gtk_label_set_xalign(OpaquePointer(pitch), 0)
            gtk_label_set_justify(OpaquePointer(pitch), GTK_JUSTIFY_LEFT)
            append(texts, pitch)
            append(row, texts)

            let chevron: Widget! = gtk_image_new_from_icon_name("go-next-symbolic")
            gtk_image_set_pixel_size(OpaquePointer(chevron), 13)
            gtk_widget_add_css_class(chevron, "swiftly-sehrleise")
            gtk_widget_set_valign(chevron, GTK_ALIGN_CENTER)
            append(row, chevron)

            gtk_button_set_child(asButton(button), row)
            caption(button, kind.shownName)
            signal(button, "clicked") { pick(kind) }
            append(card.space, button)
            append(column, card.outer)
        }
        return column
    }

    /// The first page: wordmark, the question, one sentence, the cards.
    func kindPickerBuild(firstStart: Bool, pick: @escaping (ServerKind) -> Void) -> Widget! {
        let center = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_valign(center, GTK_ALIGN_CENTER)
        gtk_widget_set_halign(center, GTK_ALIGN_CENTER)

        append(center, Theme.wordmark(height: 44))

        let question = label(translated("Was läuft bei dir?"), style: "swiftly-titel-gross")
        gtk_widget_set_margin_top(question, 40)
        append(center, question)

        let sentence = label(translated("Weitere Server kannst du später dazunehmen, auch gemischt."),
                             style: "swiftly-koerper", wrap: true)
        gtk_widget_add_css_class(sentence, "dim-label")
        gtk_widget_set_margin_top(sentence, 8)
        append(center, sentence)

        let cards = kindCardsBuild(pick: pick)
        gtk_widget_set_margin_top(cards, 28)
        append(center, cards)
        return center
    }

    /// The subpage behind "Server hinzufügen".
    func kindPickerSubpageBuild(_ block: Widget!) {
        append(block, subpageHeader(translated("Server hinzufügen")))

        let sentence = label(translated("Du bleibst bei allen angemeldet und wechselst auf der Profilseite zwischen ihnen."),
                             style: "swiftly-koerper", wrap: true)
        gtk_widget_add_css_class(sentence, "dim-label")
        gtk_label_set_xalign(OpaquePointer(sentence), 0)
        gtk_label_set_justify(OpaquePointer(sentence), GTK_JUSTIFY_LEFT)
        gtk_widget_set_margin_top(sentence, 14)
        append(block, sentence)

        let cards = kindCardsBuild { [weak self] kind in self?.kindChosenForAdding(kind) }
        gtk_widget_set_margin_top(cards, 26)
        append(block, cards)
    }

    /// A card on the "Server hinzufügen" page was chosen.
    private func kindChosenForAdding(_ kind: ServerKind) {
        serverOnboardingFromPicker = true
        if kind == .plex {
            subpageOpen(.plexSignIn)
        } else {
            serverOnboardingKind = kind
            serverOnboardingOpen(nil)
        }
    }
}
