import CGtk
import Foundation
import JellyfinKit

/// **A choice that concerns the whole app opens in the middle, over a dimmed
/// window** (Mac `SharedPanel`): "Senden an …", "Übergeben an …" and the
/// question before a takeover.
///
/// **An overlay of the window, not a popover.** A popover hangs inside the
/// widget tree of its anchor; in the player's icon row its rows (which expand)
/// let the row expand too, and every icon moved while the list was open. Here
/// the card sits on ``App/windowCover``, above the player and every page, and
/// nothing underneath is laid out again.
///
/// The frame is the same for every window: heading, the caller's content, a
/// hairline and "Abbrechen". A click on the dimmed background and Escape cancel
/// as well, as in the support sheets (``App/supportLayerOpen(_:width:sheet:)``).
extension App {

    /// **Opens the window; one at a time.** `closed` runs once, however it
    /// closes: a choice, "Abbrechen", Escape, a click outside or a newer window.
    func panelWindowOpen(_ heading: String, content: Widget!, closed: (() -> Void)? = nil) {
        guard let cover = windowCover else { return }
        panelWindowClose()
        let root: Widget! = gtk_overlay_new()
        let dim = stack(GTK_ORIENTATION_VERTICAL)
        gtk_widget_add_css_class(dim, "swiftly-stuetzgrund")
        gtk_widget_set_hexpand(dim, 1)
        gtk_widget_set_vexpand(dim, 1)
        gtk_overlay_set_child(OpaquePointer(root), dim)

        // A click outside cancels. A button, not a gesture, so the keyboard and
        // screen readers get it too.
        let outside: Widget! = gtk_button_new()
        gtk_widget_add_css_class(outside, "swiftly-handlung")
        gtk_widget_set_hexpand(outside, 1)
        gtk_widget_set_vexpand(outside, 1)
        gtk_widget_set_can_focus(outside, 0)
        gtk_widget_set_focus_on_click(outside, 0)
        caption(outside, translated("Abbrechen"))
        signal(outside, "clicked") { [weak self] in self?.panelWindowClose() }
        gtk_overlay_add_overlay(OpaquePointer(root), outside)

        let card = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_add_css_class(card, "swiftly-wahlfenster")
        gtk_widget_set_overflow(card, GTK_OVERFLOW_HIDDEN)
        gtk_widget_set_size_request(card, Int32(Theme.formWidth), -1)
        gtk_widget_set_halign(card, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(card, GTK_ALIGN_CENTER)

        // The heading as `PanelCategory` on the Mac: 17 semibold, one line, 20 around.
        let header = label(heading, style: "swiftly-spaltentitel")
        gtk_label_set_xalign(OpaquePointer(header), 0)
        gtk_label_set_ellipsize(OpaquePointer(header), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(OpaquePointer(header), 1)
        gtk_widget_set_margin_start(header, 20)
        gtk_widget_set_margin_end(header, 20)
        gtk_widget_set_margin_top(header, 20)
        gtk_widget_set_margin_bottom(header, 12)
        append(card, header)
        append(card, content)

        append(card, divider())
        let cancel: Widget! = gtk_button_new()
        gtk_widget_add_css_class(cancel, "swiftly-handlung")
        gtk_widget_set_size_request(cancel, -1, 50)
        let word = label(translated("Abbrechen"), style: "swiftly-koerper")
        gtk_widget_add_css_class(word, "swiftly-leisefarbe")
        gtk_button_set_child(asButton(cancel), word)
        signal(cancel, "clicked") { [weak self] in self?.panelWindowClose() }
        append(card, cancel)
        gtk_overlay_add_overlay(OpaquePointer(root), card)

        gtk_overlay_add_overlay(OpaquePointer(cover), root)
        panelWindow = root
        panelWindowClosed = closed
        signal(root, "destroy") { [weak self] in
            guard let self, self.panelWindow == root else { return }
            self.panelWindow = nil
            self.panelWindowClosed = nil
        }
        gtk_widget_set_opacity(root, 0)
        crossfade(root, on: 1, duration: Theme.timeFadeFromIn)
    }

    /// **Closes before the choice runs**, so a slow server leaves no window
    /// standing. Does nothing when none is open.
    func panelWindowClose() {
        guard let root = panelWindow, let cover = windowCover else { return }
        let closed = panelWindowClosed
        panelWindow = nil
        panelWindowClosed = nil
        gtk_overlay_remove_overlay(OpaquePointer(cover), root)
        closed?()
    }

    /// Escape closes the window first. True means consumed.
    func panelWindowEscape() -> Bool {
        guard panelWindow != nil else { return false }
        panelWindowClose()
        return true
    }
}
