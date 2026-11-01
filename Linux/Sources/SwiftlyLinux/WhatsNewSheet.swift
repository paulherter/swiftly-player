import CGtk
import Foundation
import JellyfinKit

/// **"What's new": once after an update, filled from `whatsnew/<version>.json`.**
///
/// The Mac's `WhatsNewSheet` in GTK: a small version line, the title, three to five entries,
/// an optional gift card and one main button, in a sheet over the dimmed window (the same
/// layer as the support sheets, so it never meets another sheet). Every rule about *whether*
/// it is due lives in the package (`WhatsNew.decide`, `WhatsNewEntry`); the texts come from
/// the same JSON as on every other platform. This file draws the sheet and chooses the
/// moment.
///
/// **The moment** is the one of the other platforms: a few seconds after the home page has
/// its rows, never during playback, never on top of another sheet, and at most one big ask
/// per session (``App/bigAskShown``: this sheet and the support sheet share it). The
/// version is stored the moment the sheet shows, so closing it any way counts as seen; on a
/// fresh install, and when this version has no file, it is stored without showing anything.
///
/// Not here, as the support records say for the looks: the alternate app icon and the
/// pick-up animation of the gift. "Hol ihn dir" picks the gift up and opens the looks panel.
extension App {

    // MARK: - The moment

    /// The home page has its rows (or the player closed): look once, a few seconds later.
    func whatsNewSoon() {
        guard !whatsNewDone, !whatsNewScheduled else { return }
        whatsNewScheduled = true
        Task.detached { [self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            onMainThread { self.whatsNewCheck() }
        }
    }

    private func whatsNewCheck() {
        whatsNewScheduled = false
        guard !whatsNewDone, client != nil, runningTitle == nil, supportSheet == nil,
              panelWindow == nil, !discordHintDue, !bigAskShown, !lastStartRail.isEmpty else { return }
        let storage = supportStore.storage
        let lastSeen = storage.data(forKey: WhatsNew.lastSeenKey).map { String(decoding: $0, as: UTF8.self) }
        // The usage record is written at start (`supportStart`); one from before this launch
        // tells an update from a fresh install.
        let usedBefore = supportStore.usage.firstLaunch.map { $0 < supportLaunch } ?? false
        let version = Version.number
        let entry = WhatsNewEntry.bundled(for: version)
        switch WhatsNew.decide(lastSeen: lastSeen, usedBefore: usedBefore, current: version,
                               hasEntry: entry != nil) {
        case .show:
            storage.setData(Data(version.utf8), forKey: WhatsNew.lastSeenKey)
            whatsNewDone = true
            if let entry { whatsNewShow(entry) }
        case .markSeen:
            storage.setData(Data(version.utf8), forKey: WhatsNew.lastSeenKey)
            whatsNewDone = true
        case .nothing:
            whatsNewDone = true
        }
    }

    // MARK: - The sheet

    private func whatsNewShow(_ entry: WhatsNewEntry) {
        let language = upperAreasCatalog.language
        // The gift only while it can still be picked up (in its window, not owned).
        let gift = entry.giftLook.flatMap { look in
            LookGift.isAvailable(look, owned: looks.owned, now: Date()) && !looks.owned.contains(look.id) ? look : nil
        }

        let page = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        let inset: Int32 = 24

        let version = label(String(format: translated("Neu in Version %@"), entry.version), style: "swiftly-neu-version")
        gtk_label_set_xalign(OpaquePointer(version), 0)
        gtk_widget_set_margin_top(version, 34)
        gtk_widget_set_margin_start(version, inset)
        gtk_widget_set_margin_end(version, 64)
        append(page, version)

        let title = supportText(entry.title.localized(language), "swiftly-s28-titel", wrap: true)
        gtk_widget_set_margin_top(title, 6)
        gtk_widget_set_margin_start(title, inset)
        gtk_widget_set_margin_end(title, inset)
        append(page, title)

        let rows = stack(GTK_ORIENTATION_VERTICAL, spacing: 20)
        gtk_widget_set_margin_top(rows, 26)
        gtk_widget_set_margin_start(rows, inset)
        gtk_widget_set_margin_end(rows, inset)
        for item in entry.items { append(rows, whatsNewRow(item, language: language)) }
        append(page, rows)

        if let gift {
            let card = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 14)
            gtk_widget_add_css_class(card, "swiftly-neu-geschenk")
            append(card, lookTile(gift, size: 44))
            let text = stack(GTK_ORIENTATION_VERTICAL, spacing: 2)
            gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
            gtk_widget_set_hexpand(text, 1)
            append(text, supportText(gift.shownName, "swiftly-s15-fett"))
            append(text, supportText(translated("Geschenk, bleibt für immer in deiner Sammlung"),
                                     "swiftly-s13-sehrleise", wrap: true))
            append(card, text)
            gtk_widget_set_margin_top(card, 24)
            gtk_widget_set_margin_start(card, inset)
            gtk_widget_set_margin_end(card, inset)
            append(page, card)
        }

        // Without the gift (window over, or picked up already) "Grab it" has nothing to do.
        let primary = entry.primary
        let kind = gift == nil && primary.label == "grab" ? "continue" : primary.label
        let buttons = stack(GTK_ORIENTATION_VERTICAL, spacing: 10)
        gtk_widget_set_margin_top(buttons, 28)
        gtk_widget_set_margin_start(buttons, inset)
        gtk_widget_set_margin_end(buttons, inset)
        gtk_widget_set_margin_bottom(buttons, 16)
        let main = primaryWhiteButton(whatsNewPrimaryText(kind), large: true)
        signal(main, "clicked") { [weak self] in
            self?.whatsNewPrimary(label: kind, action: primary.action, gift: gift)
        }
        append(buttons, main)
        if gift != nil {
            let later = gtk_button_new_with_label(translated("Nicht jetzt"))!
            gtk_widget_add_css_class(later, "swiftly-neu-spaeter")
            signal(later, "clicked") { [weak self] in self?.supportSheetClose() }
            append(buttons, later)
        }
        append(page, buttons)

        bigAskShown = true
        supportLayerOpen(sheetFrame(page, close: sheetCloseButton(dark: false)), width: 460, sheet: "swiftly-neublatt")
        gtk_widget_grab_focus(main)
    }

    /// One entry: the icon in a fixed 28 box, centred on the text beside it.
    private func whatsNewRow(_ item: WhatsNewEntry.Item, language: String) -> Widget! {
        let row = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 14)
        let icon: Widget! = gtk_image_new_from_icon_name(whatsNewIconName(item.symbol))
        gtk_image_set_pixel_size(OpaquePointer(icon), 19)
        gtk_widget_add_css_class(icon, "swiftly-leise")
        gtk_widget_set_size_request(icon, 28, 28)
        gtk_widget_set_valign(icon, GTK_ALIGN_CENTER)
        append(row, icon)
        let text = stack(GTK_ORIENTATION_VERTICAL, spacing: 3)
        gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
        gtk_widget_set_hexpand(text, 1)
        append(text, supportText(item.title.localized(language), "swiftly-s15-fett", wrap: true))
        if let detail = item.detail?.localized(language), !detail.isEmpty {
            append(text, supportText(detail, "swiftly-s13-sehrleise", wrap: true))
        }
        append(row, text)
        return row
    }

    /// The package's SF Symbol names, in the few outline icons every icon theme carries
    /// (the same reduction as `whatsNewGlyph` on Android); anything else gets the check.
    private func whatsNewIconName(_ symbol: String) -> String {
        switch true {
        case symbol.hasPrefix("paintpalette"): "applications-graphics-symbolic"
        case symbol.hasPrefix("app"): "computer-symbolic"
        case symbol.hasPrefix("arrow.uturn"): "edit-undo-symbolic"
        case symbol.hasPrefix("heart"): "emblem-favorite-symbolic"
        case symbol.hasPrefix("sparkle"): "starred-symbolic"
        default: "object-select-symbolic"
        }
    }

    private func whatsNewPrimaryText(_ label: String) -> String {
        switch label {
        case "grab": translated("Hol ihn dir")
        case "try": translated("Ausprobieren")
        case "tryLook": translated("Look ausprobieren")
        default: translated("Verstanden")
        }
    }

    private func whatsNewPrimary(label: String, action: String, gift: Look?) {
        supportSheetClose()
        if action.hasPrefix("applyLook:"), let gift {
            _ = looks.claim(gift)
            lookApplied()
            lookOpenOnHome()
        } else if action == "open:looks" || label == "try" || label == "tryLook" {
            lookOpenOnHome()
        }
    }
}
