import CGtk
import Foundation
import JellyfinKit

/// **Who has watched a title** on movie and series pages (Jelly Twiggy plugin): one row of
/// round avatars without a heading, each with an accent ring filled by ``Watcher/ring``. Name and "2 × · yesterday"
/// are the tooltip and the accessible label.
///
/// Absent without a trace when the server has no plugin, the answer is empty, or the
/// setting is off (then not even a request goes out).
extension App {

    /// The setting is offered only for a server that has answered once.
    var watchedByAvailable: Bool { selection.watchedByServers.contains(selection.activeServer) }

    /// Fetches the watchers and hands the finished section to `place` on the main thread.
    /// `place` always runs once on the main thread, with `nil` for no plugin, an empty list or
    /// the setting turned off in the meantime.
    func watchedByLoad(_ title: Item, place: @escaping @Sendable (Widget?) -> Void) {
        guard let client, selection.watchedByShown else { place(nil); return }
        let server = selection.activeServer
        Task.detached { [self] in
            guard let list = await client.watchers(itemID: title.id) else {
                postPush { place(nil) }
                return
            }
            postPush {
                // First non-nil answer: this server has the plugin.
                if !self.selection.watchedByServers.contains(server) {
                    self.selection.watchedByServers.append(server)
                    self.selection.secure()
                }
                // The user may have switched it off, or the server, while the answer was on its way.
                guard !list.isEmpty, self.selection.watchedByShown,
                      self.selection.activeServer == server,
                      let rail = self.watchedByRail(list) else { place(nil); return }
                place(rail)
            }
        }
    }

    /// Reserves an invisible slot at the end of `bottom` and fills it when the section arrives.
    func watchedByPlace(_ title: Item, in bottom: Widget!) {
        guard selection.watchedByShown else { return }
        let slot = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_visible(slot, 0)
        append(bottom, slot)
        let held = held(slot)
        watchedByLoad(title) { rail in
            defer { letGo(held) }
            guard let rail, let slot = held.widget else { return }
            append(slot, rail)
            gtk_widget_set_visible(slot, 1)
        }
    }

    /// One row of avatars at the page edge, without a heading, as on the other platforms; name and
    /// "2 × · gestern" are the tooltip.
    private func watchedByRail(_ list: [Watcher]) -> Widget? {
        let block = stack(GTK_ORIENTATION_VERTICAL, spacing: 14)

        let scroller = gtk_scrolled_window_new()
        gtk_scrolled_window_set_policy(OpaquePointer(scroller), GTK_POLICY_EXTERNAL, GTK_POLICY_NEVER)
        let row = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        gtk_widget_set_margin_start(row, Int32(Theme.edgeSpacing))
        gtk_widget_set_margin_end(row, Int32(Theme.edgeSpacing))
        for watcher in list { append(row, watcherCircle(watcher)) }
        gtk_scrolled_window_set_child(OpaquePointer(scroller), row)
        append(block, scroller)
        return block
    }

    /// 44 round avatar (the user's initial when there is no image), 3 pt ring 2 pt outside it.
    private func watcherCircle(_ watcher: Watcher) -> Widget! {
        let image = 44, gap = 2, stroke = 3
        let size = image + 2 * (gap + stroke)
        let outer: Widget! = gtk_overlay_new()
        let mass: Widget! = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
        gtk_widget_set_size_request(mass, Int32(size), Int32(size))
        gtk_overlay_set_child(OpaquePointer(outer), mass)
        gtk_widget_set_halign(outer, GTK_ALIGN_START)
        gtk_widget_set_valign(outer, GTK_ALIGN_START)

        let parts = profileCharacter(name: watcher.name.isEmpty ? "?" : watcher.name, border: image,
                                     style: "swiftly-gesehenbild", fontStyle: "swiftly-zeichen44")
        gtk_widget_set_halign(parts.wrapper, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(parts.wrapper, GTK_ALIGN_CENTER)
        gtk_overlay_add_overlay(OpaquePointer(outer), parts.wrapper)
        let url = addresses?.user(watcher.userID, mark: watcher.imageTag, border: image * 2)
        profileImageLoad(parts, url: url, key: "gesehen-\(watcher.userID)-\(watcher.imageTag ?? "")")

        let fill = watcher.ring
        let ring = paint(width: size, height: size) { _, cr, width, height in
            let m = (x: width / 2, y: height / 2)
            let r = min(width, height) / 2 - Double(stroke) / 2
            cairo_set_line_width(cr, Double(stroke))
            cairo_set_source_rgba(cr, 1, 1, 1, 0.18)
            cairo_arc(cr, m.x, m.y, r, 0, 2 * .pi)
            cairo_stroke(cr)
            guard fill > 0 else { return }
            let a = Theme.accentRGB
            cairo_set_source_rgba(cr, a.0, a.1, a.2, 1)
            cairo_set_line_cap(cr, fill >= 1 ? CAIRO_LINE_CAP_BUTT : CAIRO_LINE_CAP_ROUND)
            cairo_arc(cr, m.x, m.y, r, -.pi / 2, -.pi / 2 + 2 * .pi * fill)
            cairo_stroke(cr)
        }
        gtk_overlay_add_overlay(OpaquePointer(outer), ring)

        let text = watchedByText(watcher)
        gtk_widget_set_tooltip_text(outer, text)
        caption(outer, text)
        return outer
    }

    /// "Name\n2 × · gestern": the name, then ``Watcher/caption(now:calendar:)`` from the package,
    /// the same words as on every other platform; the second line only as far as the plugin gave data.
    private func watchedByText(_ watcher: Watcher) -> String {
        let name = watcher.name.isEmpty ? "?" : watcher.name
        let caption = watcher.caption()
        return caption.isEmpty ? name : name + "\n" + caption
    }
}
