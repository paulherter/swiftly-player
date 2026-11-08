import CGtk
import Foundation
import JellyfinKit

/// **"Try a look": a slim bar at the bottom instead of the panel** (iPhone `LookPreviewBar`).
/// Icon, name, "Vorschau", and "Freischalten"; the chevrons on both sides of the name switch to
/// the previous and next look. A look that may be worn brings the panel back.
extension App {

    /// Called after every change of the look: shows, updates or removes the bar.
    func lookPreviewBarSync() {
        let previewing = looks.isPreviewing && !looks.mayWear(looks.selection)
        guard previewing else {
            let hadBar = lookPreviewBar != nil
            lookPreviewBarHide()
            // Back to a look that may be worn: the panel returns.
            if hadBar, supportSheet == nil { lookPanelOpen() }
            return
        }
        if lookPanelSync != nil, supportSheet != nil {
            lookKeepHeld = true
            supportSheetClose()
            lookKeepHeld = false
        }
        guard supportSheet == nil || lookPanelSync == nil else { return }
        lookPreviewBarShow()
    }

    func lookPreviewBarHide() {
        guard let bar = lookPreviewBar else { return }
        lookPreviewBar = nil
        if let parent = gtk_widget_get_parent(bar) { gtk_overlay_remove_overlay(OpaquePointer(parent), bar) }
    }

    private func lookPreviewBarShow() {
        guard let cover = windowCover else { return }
        lookPreviewBarHide()
        let look = looks.selection.look
        let bar = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_add_css_class(bar, "swiftly-lookleiste")
        gtk_widget_set_halign(bar, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(bar, GTK_ALIGN_END)
        gtk_widget_set_margin_bottom(bar, 32)

        func chevron(_ icon: String, _ step: Int) -> Widget! {
            let k: Widget! = gtk_button_new_from_icon_name(icon)
            gtk_widget_add_css_class(k, "swiftly-listenpfeil")
            gtk_widget_set_valign(k, GTK_ALIGN_CENTER)
            signal(k, "clicked") { [weak self] in self?.lookPreviewMove(step) }
            return k
        }
        append(bar, chevron("go-previous-symbolic", -1))
        let art = paint(width: 44, height: 44) { _, cr, _, _ in
            LookArt.tile(cr, LookArt.iconName(look), x: 2, y: 2, size: 40)
        }
        gtk_widget_set_valign(art, GTK_ALIGN_CENTER)
        append(bar, art)
        let text = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
        gtk_widget_set_margin_start(text, 8)
        gtk_widget_set_margin_end(text, 8)
        gtk_widget_set_size_request(text, 130, -1)
        let name = label(look.shownName, style: "swiftly-lookleiste-name")
        gtk_label_set_xalign(OpaquePointer(name), 0)
        gtk_label_set_ellipsize(OpaquePointer(name), PANGO_ELLIPSIZE_END)
        append(text, name)
        let sub = label(translated("Vorschau"), style: "swiftly-zweitzeile")
        gtk_widget_add_css_class(sub, "swiftly-leise")
        gtk_label_set_xalign(OpaquePointer(sub), 0)
        append(text, sub)
        append(bar, text)
        append(bar, chevron("go-next-symbolic", 1))
        let unlock = primaryButton(translated("Freischalten"), symbol: "swiftly-heart-symbolic")
        gtk_widget_set_valign(unlock, GTK_ALIGN_CENTER)
        gtk_widget_set_margin_start(unlock, 4)
        gtk_widget_set_margin_end(unlock, 8)
        signal(unlock, "clicked") { [weak self] in
            guard let self else { return }
            // The try-on is held while the purchase page is open.
            self.lookKeepHeld = true
            self.lookPreviewBarHide()
            self.lookKeepHeld = false
            self.supportSheetShow()
        }
        append(bar, unlock)

        gtk_overlay_add_overlay(OpaquePointer(cover), bar)
        lookPreviewBar = bar
    }

    /// The look `step` places along the picker, round the end; gifts not picked up are skipped.
    private func lookPreviewMove(_ step: Int) {
        let all = looks.pickerLooks().filter { !($0.isGift && !looks.owned.contains($0.id)) }
        guard all.count > 1, let index = all.firstIndex(of: looks.selection.look) else { return }
        let next = all[(index + step + all.count) % all.count]
        let selection = looks.selection.switching(to: next)
        if looks.mayWear(selection) {
            looks.endPreview()
            _ = looks.choose(selection)
        } else {
            if !looks.isPreviewing { looks.beginPreview() }
            looks.tryOut(selection)
        }
        lookApplied()
    }
}
