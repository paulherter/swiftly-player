import CGtk
import Foundation
import JellyfinKit
import SupportKeyKit

/// **"Support Swiftly" in the direct builds (Linux and Windows).**
///
/// There is no store here, so the app may point to the website: the sheet explains the
/// three tiers, "Support on the website" opens the page in the system browser, and a key
/// from the thank-you page is checked offline (``SupporterKey``). Every rule about *when*
/// to ask lives in the package (`SupportPrompt`), and so does the arithmetic of the
/// watched hours (`WatchTimeCounter`); this file only draws and wires.
///
/// Nothing here is a feature gate: supporters get a heart next to the version number,
/// everyone else gets the same app. Linux and Windows have no alternative app icons and
/// no profile colours, so those thank-you gifts are not mentioned.

// MARK: - Storage

/// **The support records, in one file next to the settings.**
///
/// The entries are keyed by the fixed names from the package (`SupportStorageKey`), each
/// holding the package's own JSON. The file is read once and rewritten whole, atomically,
/// on every change; there are three small records and writes are rare (at most once per
/// minute of playback).
final class SupportFile: SupportStorage, @unchecked Sendable {
    private let file: URL
    private var values: [String: Data]
    private let lock = NSLock()

    init(file: URL = SupportFile.defaultFile) {
        self.file = file
        if let data = try? Data(contentsOf: file),
           let stored = try? JSONDecoder().decode([String: Data].self, from: data) {
            values = stored
        } else {
            values = [:]
        }
    }

    static var defaultFile: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/swiftly/support.json")
    }

    func data(forKey key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func setData(_ data: Data?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = data
        let folder = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let encoded = try? JSONEncoder().encode(values) else { return }
        try? encoded.write(to: file, options: .atomic)
    }
}

// MARK: - Logic around the package

extension App {

    private var supportPlatform: SupportPlatform {
        #if os(Windows)
        .windows
        #else
        .linux
        #endif
    }

    var isSupporter: Bool { supportStore.status.isSupporter }

    /// The store with the key's expiry already applied, so a lapsed monthly key never
    /// shows a heart or unlocked looks for even one frame.
    static func makeSupportStore() -> SupportStore {
        let store = SupportStore(storage: SupportFile())
        SupporterKeyKeeper(store: store).applyExpiry()
        return store
    }

    /// At start and then hourly: apply the expiry day, and ask the shop for a renewed key
    /// when the keeper says it is due. Only the random licence number leaves the machine,
    /// and only for a stored key near its expiry (monthly) or once a month (lifetime).
    func supportLicenseTick() {
        let before = supportStore.status
        supportKeeper.applyExpiry()
        if before != supportStore.status { supportLicenseChanged() }
        Task.detached { [self] in
            let outcome = await supportKeeper.refreshIfDue()
            if outcome == .renewed || outcome == .ended || outcome == .revoked {
                onMainThread { self.supportLicenseChanged() }
            }
        }
    }

    private func supportLicenseChanged() {
        lookSupporterChanged()
        supportRefreshPages()
    }

    /// Once per app start, after the window exists.
    func supportStart() {
        supportStore.recordLaunch(now: Date())
        supportCounter = WatchTimeCounter(totalSeconds: supportStore.usage.watchedSeconds)
        Task.detached { [self] in
            while true {
                onMainThread { self.supportLicenseTick() }
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
            }
        }
        // The package keeps quiet for the first minute after launch; look again right after.
        Task.detached { [self] in
            try? await Task.sleep(nanoseconds: 65_000_000_000)
            onMainThread { self.supportCheck() }
        }
    }

    /// Fed from the playback tick (about once a second). The counter only credits time
    /// between two observations that both said "playing".
    func supportWatchTick(isPlaying: Bool) {
        supportCounter.playbackProgress(isPlaying: isPlaying, at: Date())
        if supportCounter.needsSave { supportStore.save(&supportCounter) }
    }

    /// The player closed: credit the last stretch and write it down.
    func supportWatchStop() {
        supportCounter.playbackStopped(at: Date())
        supportStore.save(&supportCounter)
    }

    func supportDecision() -> SupportPrompt.Decision {
        let now = Date()
        return SupportPrompt.decide(.init(
            now: now,
            status: supportStore.status,
            usage: supportStore.usage,
            history: supportStore.promptHistory,
            isPlaying: runningTitle != nil,
            secondsSinceLaunch: now.timeIntervalSince(supportLaunch),
            platform: supportPlatform))
    }

    /// Looks whether the sheet is due and shows it. Never while a title plays, never before
    /// a server is connected.
    func supportCheck() {
        guard client != nil, runningTitle == nil, supportSheet == nil else { return }
        if supportThanksDue {
            supportThanksDue = false
            supportThanksShow()
            return
        }
        let decision = supportDecision()
        if decision.showsSheet {
            var history = supportStore.promptHistory
            history.recordSheetShown(at: Date())
            supportStore.promptHistory = history
            supportSheetShow()
        } else if decision.showsCard, supportCard == nil,
                  !lastStartRail.isEmpty, openSubpage == nil {
            supportCardPlace()
        }
    }

    /// The row in Settings and the heart open this: the explanation for everyone else,
    /// the thank-you for supporters.
    func supportOpen() {
        guard supportSheet == nil, runningTitle == nil else { return }
        if isSupporter { supportThanksShow() } else { supportSheetShow() }
    }

    /// After the player closed, give the sheet a quiet moment before it may appear.
    func supportCheckAfterPlayer() {
        Task.detached { [self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            onMainThread { self.supportCheck() }
        }
    }
}

// MARK: - Pieces for other pages

extension App {

    /// The row "Support Swiftly" for Settings and the profile page.
    func supportRow() -> Widget! {
        valuesRow(symbol: "emblem-favorite-symbolic",
                  title: translated(SupportCopy.supportSwiftly.key),
                  under: isSupporter ? nil : translated(SupportCopy.freeForEveryone.key),
                  value: isSupporter ? translated(SupportCopy.supporterBadge.key) : nil,
                  arrow: !isSupporter) { [weak self] in
            self?.supportOpen()
        }
    }

    /// The version line, with the heart and "Unterstützer" for supporters (`versionMark`).
    func versionLine(_ text: String) -> Widget! {
        let line = versionMark(text)
        gtk_widget_set_margin_top(line, 26)
        return line
    }

    /// The heart in the header of the home page.
    func supportHeart() -> Widget! { supportHeartButton() }
}

// MARK: - The card at the end of the home page

extension App {

    /// Called after the home rows are drawn. The card only appears when the package says so
    /// (3 days, 2 hours watched, no sheet due, not snoozed).
    func supportCardAtEnd() {
        supportCard = nil
        guard supportDecision().showsCard else { return }
        supportCardPlace()
    }

    func supportCardPlace() {
        guard supportCard == nil, let rails = railsStack else { return }
        let card = stack(GTK_ORIENTATION_VERTICAL, spacing: 12)
        gtk_widget_add_css_class(card, "swiftly-discordkarte")
        gtk_widget_set_halign(card, GTK_ALIGN_START)
        gtk_widget_set_size_request(card, 520, -1)
        gtk_widget_set_margin_start(card, Int32(Theme.edgeSpacing))
        gtk_widget_set_margin_end(card, Int32(Theme.edgeSpacing))

        let header = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let hours = supportCounter.watchedHours
        let title = label(String(format: translated(SupportCopy.cardWatchedHours.key), hours),
                          style: "swiftly-listentitel")
        gtk_label_set_xalign(OpaquePointer(title), 0)
        gtk_widget_set_hexpand(title, 1)
        append(header, title)
        let more = secondaryButton("view-more-horizontal-symbolic",
                                   name: translated("Mehr"))
        gtk_widget_set_size_request(more, 32, 32)
        signal(more, "clicked") { [weak self] in self?.supportCardMenu(an: more) }
        append(header, more)
        append(card, header)

        let ask = label(translated(SupportCopy.cardAsk.key), style: "swiftly-zweitzeile", wrap: true)
        gtk_widget_add_css_class(ask, "swiftly-leise")
        gtk_label_set_xalign(OpaquePointer(ask), 0)
        gtk_label_set_justify(OpaquePointer(ask), GTK_JUSTIFY_LEFT)
        gtk_label_set_max_width_chars(OpaquePointer(ask), 60)
        append(card, ask)

        let buttons = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let support = primaryButton(translated(SupportCopy.cardSupport.key), symbol: "emblem-favorite-symbolic")
        gtk_widget_set_size_request(support, 160, Int32(Theme.primaryButtonHeight))
        signal(support, "clicked") { [weak self] in self?.supportOpen() }
        append(buttons, support)
        let notNow = gtk_button_new_with_label(translated(SupportCopy.notNow.key))!
        gtk_widget_add_css_class(notNow, "swiftly-sekundaer")
        gtk_widget_set_size_request(notNow, -1, Int32(Theme.primaryButtonHeight))
        signal(notNow, "clicked") { [weak self] in
            guard let self else { return }
            var history = self.supportStore.promptHistory
            history.snoozeCard(now: Date())
            self.supportStore.promptHistory = history
            self.supportCardRemove()
        }
        append(buttons, notNow)
        append(card, buttons)

        append(rails, card)
        supportCard = card
        // The page rebuilds its rows now and then; do not keep a pointer to a dead widget.
        signal(card, "destroy") { [weak self] in self?.supportCard = nil }
    }

    private func supportCardMenu(an button: Widget!) {
        let panel = panelOpen(an: button, flush: GTK_ALIGN_END)
        let list = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        append(list, actionRow("window-close-symbolic", translated(SupportCopy.dontShowAgain.key)) {
            [weak self] in
            gtk_popover_popdown(asPanel(panel))
            guard let self else { return }
            var history = self.supportStore.promptHistory
            history.dismissCard()
            self.supportStore.promptHistory = history
            self.supportCardRemove()
        })
        gtk_popover_set_child(asPanel(panel), Scaling.wrapped(list))
        gtk_popover_popup(asPanel(panel))
    }

    func supportCardRemove() {
        guard let card = supportCard else { return }
        supportCard = nil
        gtk_widget_unparent(card)
    }
}

// MARK: - The sheet

extension App {

    /// Dims the window and puts a dialog in the middle. Not a `GtkDialog` (E4): an overlay
    /// on the window, closed by the cross, Escape or a click outside.
    func supportLayerOpen(_ dialog: Widget!, width: Int32 = 600, sheet: String? = nil) {
        guard let cover = windowCover, supportSheet == nil else { return }
        let root: Widget! = gtk_overlay_new()
        let dim = stack(GTK_ORIENTATION_VERTICAL)
        gtk_widget_add_css_class(dim, "swiftly-stuetzgrund")
        gtk_widget_set_hexpand(dim, 1)
        gtk_widget_set_vexpand(dim, 1)
        gtk_overlay_set_child(OpaquePointer(root), dim)

        // A click outside closes. A button, not a gesture, so the keyboard and screen
        // readers get it too.
        let outside: Widget! = gtk_button_new()
        gtk_widget_add_css_class(outside, "swiftly-handlung")
        gtk_widget_set_hexpand(outside, 1)
        gtk_widget_set_vexpand(outside, 1)
        gtk_widget_set_can_focus(outside, 0)
        gtk_widget_set_focus_on_click(outside, 0)
        caption(outside, translated("Schließen"))
        signal(outside, "clicked") { [weak self] in self?.supportSheetClose() }
        gtk_overlay_add_overlay(OpaquePointer(root), outside)

        // `sheet`: the sheets drawn as on the Mac (no padding, their own background).
        if let sheet {
            gtk_widget_add_css_class(dialog, "swiftly-blatt")
            gtk_widget_add_css_class(dialog, sheet)
            gtk_widget_set_overflow(dialog, GTK_OVERFLOW_HIDDEN)
        } else {
            gtk_widget_add_css_class(dialog, "swiftly-stuetzblatt")
        }
        gtk_widget_set_size_request(dialog, width, -1)
        gtk_widget_set_halign(dialog, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(dialog, GTK_ALIGN_CENTER)
        gtk_overlay_add_overlay(OpaquePointer(root), dialog)

        gtk_overlay_add_overlay(OpaquePointer(cover), root)
        supportSheet = root
        signal(root, "destroy") { [weak self] in self?.supportSheet = nil }
        gtk_widget_set_opacity(root, 0)
        crossfade(root, on: 1, duration: Theme.timeFadeFromIn)
    }

    func supportSheetClose() {
        guard let layer = supportSheet, let cover = windowCover else { return }
        supportSheet = nil
        supportKeyField = nil
        gtk_overlay_remove_overlay(OpaquePointer(cover), layer)
        lookSheetClosed()
    }

    /// **The purchase page** (`SupportGrowSheet`): the offer as on the Mac, then the key.
    /// The amount is paid on the website, where the prices are.
    func supportSheetShow() {
        guard supportSheet == nil else { return }
        // The page as on the Mac (`supportGrowOffer`). The choice travels to the website
        // only as a hint (`?plan=`), where the real price and the checkout are.
        let page = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        append(page, supportGrowOffer { id in
            // Opens the page in the system browser through GLib (xdg-open on Linux, the
            // registered handler on Windows).
            if let address = URL(string: DirectSupport.websiteURL + "/" + "?plan=" + id) { browser(address) }
        })

        let note = label(translated(DirectSupportCopyKey.opensWebsite), style: "swiftly-s12-sehrleise")
        append(page, note)

        // The key, below the offer: on Linux and Windows the purchase ends with one.
        let keyBox = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_margin_start(keyBox, 16)
        gtk_widget_set_margin_end(keyBox, 16)
        gtk_widget_set_margin_bottom(keyBox, 18)
        append(page, keyBox)
        let dialog = keyBox

        let line = divider()
        gtk_widget_set_margin_top(line, 18)
        gtk_widget_set_margin_bottom(line, 16)
        append(dialog, line)

        let keyLabel = label(translated(DirectSupportCopyKey.haveKey), style: "swiftly-listentitel")
        gtk_widget_add_css_class(keyLabel, "swiftly-leise")
        gtk_label_set_xalign(OpaquePointer(keyLabel), 0)
        gtk_widget_set_margin_bottom(keyLabel, 8)
        append(dialog, keyLabel)

        let row = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let field: Widget! = gtk_entry_new()
        gtk_widget_add_css_class(field, "swiftly-schluessel")
        gtk_entry_set_placeholder_text(asField(field), "SS1-XXXX-XXXX-XXXX")
        gtk_widget_set_hexpand(field, 1)
        gtk_widget_set_valign(field, GTK_ALIGN_CENTER)
        append(row, field)
        let activate = gtk_button_new_with_label(translated(DirectSupportCopyKey.activate))!
        gtk_widget_add_css_class(activate, "swiftly-sekundaer")
        gtk_widget_set_sensitive(activate, 0)
        append(row, activate)
        append(dialog, row)

        let message = label("", style: "swiftly-schluesselmeldung", wrap: true)
        gtk_label_set_xalign(OpaquePointer(message), 0)
        gtk_label_set_justify(OpaquePointer(message), GTK_JUSTIFY_LEFT)
        gtk_label_set_max_width_chars(OpaquePointer(message), 60)
        gtk_widget_set_margin_top(message, 8)
        gtk_widget_set_visible(message, 0)
        append(dialog, message)

        // Lost key: a line with the contact address, shown after a failed attempt.
        let lost = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 4)
        gtk_widget_set_visible(lost, 0)
        let lostText = label(translated(DirectSupportCopyKey.lostKey), style: "swiftly-zweitzeile")
        gtk_widget_add_css_class(lostText, "swiftly-leise")
        append(lost, lostText)
        let mail = gtk_button_new_with_label(DirectSupport.contactEmail)!
        gtk_widget_add_css_class(mail, "swiftly-still")
        gtk_widget_set_size_request(mail, -1, 20)
        gtk_widget_set_valign(mail, GTK_ALIGN_CENTER)
        signal(mail, "clicked") {
            if let address = URL(string: "mailto:" + DirectSupport.contactEmail) { browser(address) }
        }
        append(lost, mail)
        gtk_widget_set_margin_top(lost, 6)
        append(dialog, lost)

        // Typing clears an earlier verdict and decides whether "Activate" can be pressed.
        signal(field, "changed") {
            let typed = String(cString: gtk_editable_get_text(OpaquePointer(field)))
            let empty = typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            gtk_widget_set_sensitive(activate, empty ? 0 : 1)
            gtk_widget_remove_css_class(field, "swiftly-ungueltig")
            gtk_widget_set_visible(message, 0)
            gtk_widget_set_visible(lost, 0)
        }
        let check: () -> Void = { [weak self] in
            self?.supportKeyCheck(field: field, message: message, lost: lost, button: activate)
        }
        signal(activate, "clicked", check)
        signal(field, "activate", check)

        supportLayerOpen(sheetFrame(page, close: sheetCloseButton(dark: true)),
                         width: 480, sheet: "swiftly-wachsenblatt")
        supportKeyField = field
        signal(field, "destroy") { [weak self] in self?.supportKeyField = nil }
    }

    /// Checks the pasted key, offline. The states follow the draft: valid with a thank-you
    /// (and the buyer's name, if they left one), invalid with a friendly line.
    private func supportKeyCheck(field: Widget!, message: Widget!, lost: Widget!, button: Widget!) {
        let typed = String(cString: gtk_editable_get_text(OpaquePointer(field)))
        let result = supportKeeper.activate(typed)
        gtk_widget_remove_css_class(message, "swiftly-gueltig")
        gtk_widget_remove_css_class(message, "swiftly-ungueltig")
        switch result {
        case .valid(_, _, _, let name):
            _ = looks.purchaseCompleted()
            lookSupporterChanged()
            gtk_widget_add_css_class(field, "swiftly-gueltig")
            gtk_widget_remove_css_class(field, "swiftly-ungueltig")
            gtk_widget_add_css_class(message, "swiftly-gueltig")
            var text = "\u{2713} " + translated(DirectSupportCopyKey.keyAccepted)
            if let name, !name.isEmpty { text += " " + name }
            gtk_label_set_text(OpaquePointer(message), text)
            gtk_widget_set_visible(message, 1)
            gtk_widget_set_visible(lost, 0)
            gtk_widget_set_sensitive(field, 0)
            gtk_widget_set_sensitive(button, 0)
            AppLog.writeOut("[Unterstützen] Schlüssel angenommen")
            // Let the verdict be read, then replace the sheet with the thank-you.
            Task.detached { [self] in
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                onMainThread {
                    self.supportSheetClose()
                    self.supportThanksShow()
                    self.supportRefreshPages()
                }
            }
        case .invalid(let failure):
            gtk_widget_add_css_class(field, "swiftly-ungueltig")
            gtk_widget_add_css_class(message, "swiftly-ungueltig")
            AppLog.writeOut("[Unterstützen] Schlüssel abgelehnt: \(failure.rawValue)")
            gtk_label_set_text(OpaquePointer(message), translated(SupportCopy.keyMessage(for: failure).key))
            gtk_widget_set_visible(message, 1)
            gtk_widget_set_visible(lost, 1)
        }
    }

    /// The heart and the rows change with the status: rebuild what is open.
    private func supportRefreshPages() {
        if let page = openSubpage {
            subpageOpen(page, push: .without)
        } else {
            homeLoad()
        }
    }

    /// **The thank-you dialog.** Never while a title plays: it waits for the player to
    /// close instead.
    func supportThanksShow() {
        guard runningTitle == nil else {
            supportThanksDue = true
            return
        }
        guard supportSheet == nil else { return }
        supportLayerOpen(sheetFrame(supportThanksPage(), close: nil), width: 480, sheet: "swiftly-dankblatt")
    }

    /// Escape closes the dialog first. True means consumed.
    func supportEscape() -> Bool {
        guard supportSheet != nil else { return false }
        supportSheetClose()
        return true
    }
}

// MARK: - Direct-only texts

/// **The direct-only strings, by their catalog key.** They come from the package module that
/// store builds do not link; the German sentence is the key here as everywhere.
enum DirectSupportCopyKey {
    static let supportOnWebsite = SupportCopy.supportOnWebsite.key
    static let opensWebsite = SupportCopy.opensWebsite.key
    static let haveKey = SupportCopy.haveKey.key
    static let keyInvalid = SupportCopy.keyInvalid.key
    static let activate = SupportCopy.activate.key
    static let keyAccepted = SupportCopy.keyAccepted.key
    static let lostKey = SupportCopy.lostKey.key
}
