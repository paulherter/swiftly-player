import CGtk
import Foundation
import JellyfinKit

/// **Looks on Linux and Windows**: the same nine looks as on Apple, drawn with GTK.
///
/// Every rule (which look is free, what a supporter may wear, what a try-on is, the
/// colors, the glow strength, when a seasonal gift is on) lives in the package
/// (`Look`, `LookTryOn`, `LookGift`). This file keeps the state in one file next to the
/// support records, puts the palette on ``Theme`` and draws the panel. Two things the
/// Apple versions have are left out because a desktop window has no counterpart: the
/// alternate app icon (the icon of a window comes from the desktop file) and the bats
/// and cobweb of Halloween.

// MARK: - State

/// **The look the window wears, with the try-on rules of the package.**
///
/// Lives next to the support status in `support.json` under the package's fixed keys
/// (`LookStorageKey`), so a file written here reads the same everywhere.
final class LookModel {
    private let storage: any SupportStorage
    private(set) var tryOn: LookTryOn

    init(storage: any SupportStorage, supporter: Bool) {
        self.storage = storage
        let saved = LookSelection.decoded(from: storage.data(forKey: LookStorageKey.selection))
        let owned = storage.data(forKey: LookStorageKey.owned)
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        tryOn = LookTryOn(saved: saved, isSupporter: supporter, owned: Set(owned))
    }

    /// What the window draws with now: the preview while one runs, else the saved look
    /// (the original if the person may not wear it, e.g. after a key was removed).
    var selection: LookSelection { tryOn.shown }
    var palette: LookPalette { selection.palette }
    var saved: LookSelection { tryOn.saved }
    var owned: Set<String> { tryOn.owned }
    var isPreviewing: Bool { tryOn.isPreviewing }

    func mayWear(_ selection: LookSelection) -> Bool { tryOn.mayWear(selection) }

    /// The supporter state can change under the model (a key was accepted).
    func setSupporter(_ supporter: Bool) {
        tryOn.setSupporter(supporter)
        persist()
    }

    func beginPreview() { tryOn.begin() }
    func tryOut(_ selection: LookSelection) { tryOn.tryOn(selection) }
    func endPreview() { tryOn.end() }

    @discardableResult
    func choose(_ selection: LookSelection) -> Bool {
        let done = tryOn.choose(selection)
        persist()
        return done
    }

    @discardableResult
    func claim(_ look: Look) -> LookSelection? {
        let done = tryOn.claim(look)
        persist()
        return done
    }

    func keep() -> LookTryOn.KeepResult {
        let result = tryOn.keep()
        persist()
        return result
    }

    func supportSheetClosed() { tryOn.supportSheetClosed() }

    @discardableResult
    func purchaseCompleted() -> LookSelection? {
        let applied = tryOn.purchaseCompleted()
        persist()
        return applied
    }

    private func persist() {
        storage.setData(tryOn.saved.encoded, forKey: LookStorageKey.selection)
        storage.setData(try? JSONEncoder().encode(tryOn.owned.sorted()), forKey: LookStorageKey.owned)
    }

    /// The palette to start with, read before the first window exists so the first frame
    /// is already in the right color.
    static func startPalette(storage: any SupportStorage, supporter: Bool) -> LookPalette {
        LookModel(storage: storage, supporter: supporter).palette
    }

    /// The looks the panel lists: all, but a seasonal gift only while it is on (or after it
    /// was picked up).
    func pickerLooks(now: Date = Date()) -> [Look] {
        Look.all.filter { !$0.isGift || LookGift.isAvailable($0, owned: owned, now: now) }
    }

    /// Whether this tile shows a lock: a supporter look the person may not wear.
    func isLocked(_ look: Look) -> Bool {
        !(mayWear(LookSelection(lookID: look.id)) || (look.isGift && !owned.contains(look.id)))
    }
}

// MARK: - Names

extension LookGlow {
    var shownName: String {
        switch self {
        case .off: translated("Aus")
        case .soft: translated("Sanft")
        case .bright: translated("Kräftig")
        }
    }
}

extension Look {
    var shownName: String { translated(nameKey) }
}

extension LookAccent {
    /// As `LookAccentDots.swift` names them.
    var shownName: String {
        switch id {
        case LookAccent.violet.id: translated("Violett")
        case LookAccent.coral.id: translated("Koralle")
        case LookAccent.gold.id: translated("Gold")
        case LookAccent.emerald.id: translated("Smaragd")
        default: translated("Türkis")
        }
    }
}

// MARK: - Putting a look on the window

extension App {

    /// Puts what the model shows on the whole window.
    func lookWear() {
        Theme.wear(looks.palette)
    }

    /// After the support status changed (key accepted).
    func lookSupporterChanged() {
        looks.setSupporter(isSupporter)
        lookWear()
    }

    /// The glow hangs on the content box of a main page (a CSS background, so it scrolls
    /// away with the content, as the Apple layer does).
    func lookGlowOn(_ page: Widget!) {
        gtk_widget_add_css_class(page, "swiftly-schein")
    }

    /// For a page whose content box has margins of its own: a plain box around it carries
    /// the glow, so it reaches the window edges and the top gap.
    func lookGlowWrapped(_ content: Widget!) -> Widget! {
        let wrapper = stack(GTK_ORIENTATION_VERTICAL)
        gtk_widget_set_hexpand(wrapper, 1)
        append(wrapper, content)
        lookGlowOn(wrapper)
        return wrapper
    }
}

// MARK: - The row "Your look ... Change"

extension App {

    /// **"Dein Look: Gold  Ändern"** in Appearance (`CurrentLookRow`): the icon 32, the
    /// name, "Ändern" in the accent. The choice itself happens in the one panel over the
    /// home page, where the change shows at once.
    func currentLookRow() -> Widget! {
        let look = looks.saved.look
        let row = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 14)
        append(row, lookTile(look, size: 32))
        let name = label(look.shownName, style: "swiftly-listentitel")
        gtk_label_set_xalign(OpaquePointer(name), 0)
        gtk_widget_set_hexpand(name, 1)
        append(row, name)
        let change = label(translated("Ändern"), style: "swiftly-listentitel")
        gtk_widget_add_css_class(change, "swiftly-akzentschrift")
        append(row, change)

        let button: Widget! = gtk_button_new()
        gtk_widget_add_css_class(button, "swiftly-einstellzeile")
        gtk_widget_add_css_class(button, "swiftly-lookzeile")
        gtk_button_set_child(asButton(button), row)
        caption(button, String(format: translated("Dein Look: %@"), look.shownName))
        signal(button, "clicked") { [weak self] in self?.lookOpenOnHome() }
        return button
    }

    /// The group "Looks" for Appearance: one row.
    func looksGroup() -> Widget! {
        let group = settingGroup(translated("Looks"))
        append(group.space, currentLookRow())
        return group.outer
    }

    /// The home page first, then the panel, once the page has slid in.
    func lookOpenOnHome(trying look: Look? = nil) {
        guard supportSheet == nil else { return }
        if section != .start || openSubpage != nil { show(.start) }
        Task.detached { [self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            onMainThread {
                self.lookPanelOpen()
                guard let look else { return }
                let next = self.looks.saved.switching(to: look)
                guard !self.looks.mayWear(next) else { return }
                self.looks.beginPreview()
                self.looks.tryOut(next)
                self.lookApplied()
            }
        }
    }
}

// MARK: - The panel

extension App {

    /// **`LooksPanel`**, 480 wide: the title, the strip of looks, the settings block (glow,
    /// accent) and the one button. The window behind it already wears what is chosen.
    func lookPanelOpen() {
        guard supportSheet == nil, runningTitle == nil else { return }
        let panel = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)

        let title = supportText(translated("Wähl deinen Look"), "swiftly-s17-fett")
        gtk_widget_set_margin_top(title, 26)
        gtk_widget_set_margin_start(title, 24)
        gtk_widget_set_margin_end(title, 64)
        append(panel, title)

        // The strip of looks: the icon 56 with a white ring when chosen, a lock when it
        // needs support, the name under it.
        let strip = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_widget_set_margin_start(strip, 24)
        gtk_widget_set_margin_end(strip, 24)
        gtk_widget_set_margin_top(strip, 6)
        gtk_widget_set_margin_bottom(strip, 2)
        var tiles = [(look: Look, button: Widget, art: Widget, name: Widget)]()
        for item in looks.pickerLooks() {
            let icon = LookArt.iconName(item)
            let art = paint(width: 68, height: 66) { [weak self] _, cr, _, _ in
                guard let self else { return }
                let chosen = self.looks.selection.look == item
                let locked = self.looks.isLocked(item)
                let x = 6.0, y = 4.0, s = 56.0
                if locked {
                    cairo_push_group(cr)
                    LookArt.tile(cr, icon, x: x, y: y, size: s)
                    cairo_pop_group_to_source(cr)
                    cairo_paint_with_alpha(cr, 0.45)
                } else {
                    LookArt.tile(cr, icon, x: x, y: y, size: s)
                }
                if chosen {
                    LookArt.rounded(cr, x - 4, y - 4, s + 8, s + 8, 17)
                    cairo_set_source_rgb(cr, 1, 1, 1)
                    cairo_set_line_width(cr, 2)
                    cairo_stroke(cr)
                }
                if locked {
                    let cx = x + s - 10 + 4, cy = y + s - 10 + 4
                    cairo_arc(cr, cx, cy, 10, 0, 2 * .pi)
                    cairo_set_source_rgb(cr, 0x30 / 255.0, 0x30 / 255.0, 0x30 / 255.0)
                    cairo_fill(cr)
                    cairo_set_source_rgb(cr, 1, 1, 1)
                    LookArt.lock(cr, cx: cx, cy: cy, size: 10)
                }
            }
            let column = stack(GTK_ORIENTATION_VERTICAL, spacing: 4)
            gtk_widget_set_halign(art, GTK_ALIGN_CENTER)
            append(column, art)
            let name = label(item.shownName, style: "swiftly-lookname")
            gtk_label_set_ellipsize(OpaquePointer(name), PANGO_ELLIPSIZE_END)
            gtk_label_set_max_width_chars(OpaquePointer(name), 9)
            append(column, name)
            let button: Widget! = gtk_button_new()
            gtk_widget_add_css_class(button, "swiftly-lookspalte")
            gtk_widget_set_size_request(button, 68, -1)
            gtk_button_set_child(asButton(button), column)
            caption(button, item.shownName)
            signal(button, "clicked") { [weak self] in self?.lookPick(item) }
            append(strip, button)
            tiles.append((item, button!, art!, name!))
        }
        let scroller: Widget! = gtk_scrolled_window_new()
        gtk_scrolled_window_set_policy(OpaquePointer(scroller), GTK_POLICY_AUTOMATIC, GTK_POLICY_NEVER)
        gtk_scrolled_window_set_child(OpaquePointer(scroller), strip)
        gtk_scrolled_window_set_propagate_natural_height(OpaquePointer(scroller), 1)
        gtk_widget_set_margin_top(scroller, 12)
        append(panel, scroller)

        // The settings block: the glow and the accent.
        let settings = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_add_css_class(settings, "swiftly-lookblock")
        gtk_widget_set_margin_top(settings, 14)
        gtk_widget_set_margin_start(settings, 24)
        gtk_widget_set_margin_end(settings, 24)

        let glowRow = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        gtk_widget_add_css_class(glowRow, "swiftly-lookblock-zeile")
        let glowTitle = supportText(translated("Startseiten-Schein"), "swiftly-s15-fett")
        gtk_widget_set_hexpand(glowTitle, 1)
        append(glowRow, glowTitle)
        let segments = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_add_css_class(segments, "swiftly-segmente")
        gtk_box_set_homogeneous(asBox(segments), 1)
        gtk_widget_set_size_request(segments, 168, -1)
        gtk_widget_set_valign(segments, GTK_ALIGN_CENTER)
        var segmentButtons = [(glow: LookGlow, button: Widget)]()
        for glow in LookGlow.allCases {
            let segment: Widget! = gtk_button_new_with_label(glow.shownName)
            gtk_widget_add_css_class(segment, "swiftly-segment")
            signal(segment, "clicked") { [weak self] in self?.lookGlowChosen(glow) }
            append(segments, segment)
            segmentButtons.append((glow, segment))
        }
        append(glowRow, segments)
        append(settings, glowRow)
        let line = divider()
        gtk_widget_set_margin_start(line, 16)
        append(settings, line)

        let accentRow = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        gtk_widget_add_css_class(accentRow, "swiftly-lookblock-zeile")
        let accentTitle = supportText(translated("Akzentfarbe"), "swiftly-s15-fett")
        gtk_widget_set_hexpand(accentTitle, 1)
        append(accentRow, accentTitle)
        var dots = [Widget]()
        if isSupporter {
            // Five dots, a white ring around the chosen one; 44 to hit, overlapping by 10.
            let row = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
            gtk_widget_set_margin_end(row, -5)
            for accent in LookAccent.all {
                let dot = paint(width: 34, height: 44) { [weak self] _, cr, w, h in
                    guard let self else { return }
                    let chosen = self.looks.selection.palette.accent == accent
                    LookArt.set(cr, accent.main)
                    cairo_arc(cr, w / 2, h / 2, 11, 0, 2 * .pi)
                    cairo_fill(cr)
                    if chosen {
                        cairo_set_source_rgb(cr, 1, 1, 1)
                        cairo_set_line_width(cr, 1.5)
                        cairo_arc(cr, w / 2, h / 2, 13.75, 0, 2 * .pi)
                        cairo_stroke(cr)
                    }
                }
                let button: Widget! = gtk_button_new()
                gtk_widget_add_css_class(button, "swiftly-akzentpunkt")
                gtk_button_set_child(asButton(button), dot)
                caption(button, accent.shownName)
                signal(button, "clicked") { [weak self] in self?.lookAccentChosen(accent) }
                append(row, button)
                dots.append(dot!)
            }
            append(accentRow, row)
        } else {
            let become = gtk_button_new_with_label(translated("Unterstützer werden"))!
            gtk_widget_add_css_class(become, "swiftly-kapselknopf")
            gtk_widget_set_valign(become, GTK_ALIGN_CENTER)
            signal(become, "clicked") { [weak self] in self?.lookSupportFromPanel() }
            append(accentRow, become)
        }
        append(settings, accentRow)
        append(panel, settings)

        // The one button: "Use" for a look that may be worn, else the way to the purchase page.
        let use = primaryWhiteButton(translated("Verwenden"), large: true)
        let become = primaryWhiteButton(translated("Unterstützer werden"), large: true)
        let buttons = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_margin_top(buttons, 16)
        gtk_widget_set_margin_bottom(buttons, 16)
        gtk_widget_set_margin_start(buttons, 24)
        gtk_widget_set_margin_end(buttons, 24)
        append(buttons, use)
        append(buttons, become)
        signal(use, "clicked") { [weak self] in self?.supportSheetClose() }
        signal(become, "clicked") { [weak self] in self?.lookKeep() }
        append(panel, buttons)

        lookPanelSync = { [weak self] in
            guard let self else { return }
            let shown = self.looks.selection
            let wearable = self.looks.mayWear(shown)
            for tile in tiles {
                gtk_widget_queue_draw(tile.art)
                let chosen = tile.look == shown.look
                if chosen { gtk_widget_add_css_class(tile.name, "swiftly-lookname-gewaehlt") }
                else { gtk_widget_remove_css_class(tile.name, "swiftly-lookname-gewaehlt") }
                gtk_widget_set_opacity(tile.name, self.looks.isLocked(tile.look) ? 0.6 : 1)
            }
            for dot in dots { gtk_widget_queue_draw(dot) }
            for item in segmentButtons {
                if item.glow == shown.palette.glow { gtk_widget_add_css_class(item.button, "swiftly-aktiv") }
                else { gtk_widget_remove_css_class(item.button, "swiftly-aktiv") }
            }
            gtk_widget_set_sensitive(settings, wearable ? 1 : 0)
            gtk_widget_set_opacity(settings, wearable ? 1 : 0.5)
            gtk_widget_set_visible(use, wearable ? 1 : 0)
            gtk_widget_set_visible(become, wearable ? 0 : 1)
        }
        lookPanelSync?()
        supportLayerOpen(sheetFrame(panel, close: sheetCloseButton(dark: false)), width: 480, sheet: "swiftly-lookblatt")
    }

    /// A look was tapped: wear it, or try it on.
    private func lookPick(_ item: Look) {
        let selection = looks.selection
        guard selection.look != item else { return }
        // A gift not picked up yet: choosing it here picks it up.
        if item.isGift, !looks.owned.contains(item.id) {
            _ = looks.claim(item)
            lookApplied()
            return
        }
        lookApply(selection.switching(to: item))
    }

    private func lookGlowChosen(_ glow: LookGlow) {
        let selection = looks.selection
        var next = selection
        next.glow = glow == selection.look.defaultGlow ? nil : glow
        lookApply(next)
    }

    /// An accent dot: the look's own accent is stored as none, as on Apple.
    private func lookAccentChosen(_ accent: LookAccent) {
        let selection = looks.selection
        var next = selection
        next.accentID = accent == selection.look.accent ? nil : accent.id
        lookApply(next)
    }

    /// "Unterstützer werden" in the accent row: the purchase page instead of the panel.
    private func lookSupportFromPanel() {
        lookKeepHeld = true
        supportSheetClose()
        lookKeepHeld = false
        supportSheetShow()
    }

    /// Wear it if it may be worn, otherwise start a try-on (shown, not kept).
    private func lookApply(_ next: LookSelection) {
        if looks.mayWear(next) {
            looks.endPreview()
            _ = looks.choose(next)
        } else {
            if !looks.isPreviewing { looks.beginPreview() }
            looks.tryOut(next)
        }
        lookApplied()
    }

    /// The window and the panel follow the model.
    func lookApplied() {
        lookWear()
        lookPanelSync?()
    }

    /// "Become a supporter" in the panel: the try-on is held while the purchase page is
    /// open; with a key it becomes the saved look, without one it is dropped on close.
    private func lookKeep() {
        switch looks.keep() {
        case .kept:
            supportSheetClose()
        case .needsSupport:
            lookKeepHeld = true
            supportSheetClose()
            lookKeepHeld = false
            supportSheetShow()
        case .nothing:
            break
        }
    }

    /// Called whenever the sheet layer closes: a try-on that was not kept ends, and the
    /// window goes back to the saved look.
    func lookSheetClosed() {
        lookPanelSync = nil
        guard !lookKeepHeld else { return }
        if looks.isPreviewing || !isSupporter {
            looks.supportSheetClosed()
            if looks.isPreviewing { looks.endPreview() }
        }
        lookWear()
    }
}
