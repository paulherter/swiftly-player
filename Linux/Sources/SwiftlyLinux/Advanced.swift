import CGtk
import Foundation
import JellyfinKit

/// **"Erweitert": custom headers for a service in front of the server.**
///
/// Cloudflare Access, Authelia, Authentik, Pangolin: anyone protecting
/// Jellyfin or Seerr this way lets the app through only with certain headers
/// (issue #4). Modeled on `Sources/macOS/MacAdvanced.swift`: collapsed and
/// empty so nothing changes for anyone else; the value is masked like a
/// password. What is actually sent is decided by
/// ``Eigenkoepfe/bereinigt(_:)`` in the package, not by this file.
final class HeaderRowReader {
    fileprivate struct RowItem { let rail: Widget!; let name: Widget!; let value: Widget! }
    fileprivate var rows: [RowItem] = []
    /// After the page is torn down the fields point to nothing; the reader then
    /// reads nothing instead of touching freed memory.
    fileprivate var tidiedAway = false

    /// What is entered, already passed through the package's sanitizer.
    func headers() -> [OwnHeader] {
        guard !tidiedAway else { return [] }
        return OwnHeaders.cleaned(rows.map { z in
            OwnHeader(name: String(cString: gtk_editable_get_text(OpaquePointer(z.name))),
                      value: String(cString: gtk_editable_get_text(OpaquePointer(z.value))))
        })
    }
}

/// Builds the section. `expanded` is for settings, where headers may
/// already exist, so there is nothing to expand.
func advancedBuild(available: [OwnHeader], expanded: Bool = false,
                    changed: @escaping () -> Void = {}) -> (Widget?, HeaderRowReader) {
    let reader = HeaderRowReader()
    let outer = stack(GTK_ORIENTATION_VERTICAL, spacing: 10)
    gtk_widget_set_margin_top(outer, 10)
    signal(outer, "destroy") { reader.tidiedAway = true; reader.rows = [] }

    let content = stack(GTK_ORIENTATION_VERTICAL, spacing: 10)
    let opened = expanded || !available.isEmpty

    if !expanded {
        let button: Widget! = gtk_button_new()
        gtk_widget_add_css_class(button, "swiftly-flach")
        gtk_widget_set_halign(button, GTK_ALIGN_START)
        let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        append(rail, label(translated("Erweitert"), style: "swiftly-zweitzeile"))
        let arrow: Widget! = gtk_image_new_from_icon_name(opened ? "pan-down-symbolic" : "pan-end-symbolic")
        append(rail, arrow)
        gtk_button_set_child(asButton(button), rail)
        let ik = PointerBox(content), pk = PointerBox(arrow)
        signal(button, "clicked") {
            let now = gtk_widget_get_visible(ik.widget) == 0
            gtk_widget_set_visible(ik.widget, now ? 1 : 0)
            gtk_image_set_from_icon_name(OpaquePointer(pk.widget),
                                         now ? "pan-down-symbolic" : "pan-end-symbolic")
        }
        append(outer, button)
    }
    gtk_widget_set_visible(content, opened ? 1 : 0)

    let sentence = label(translated("Für einen Dienst vor deinem Server, etwa Cloudflare Access, Authelia oder Pangolin. Swiftly schickt die Header nur an diese Adresse."),
                            style: "swiftly-zweitzeile", wrap: true)
    gtk_widget_add_css_class(sentence, "dim-label")
    gtk_label_set_xalign(OpaquePointer(sentence), 0)
    append(content, sentence)

    let list = stack(GTK_ORIENTATION_VERTICAL, spacing: 8)
    append(content, list)
    let lk = PointerBox(list)

    func rowCreate(_ k: OwnHeader?) {
        let rail = stack(GTK_ORIENTATION_VERTICAL, spacing: 4)
        let name = inputRow(symbol: "tag-symbolic", placeholder: translated("Header-Name"), stretches: true)
        let value = inputRow(symbol: "dialog-password-symbolic", placeholder: translated("Wert"),
                                secret: true, stretches: true)
        if let k {
            gtk_editable_set_text(OpaquePointer(name), k.name)
            gtk_editable_set_text(OpaquePointer(value), k.value)
        }
        let distance = secondaryButton("list-remove-symbolic", name: translated("Entfernen"))
        let fields = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        append(fields, name)
        append(fields, value)
        append(fields, distance)
        append(rail, fields)
        // Swiftly sets this one itself; the row says so instead of silently doing
        // nothing.
        let hint = label(translated("Den setzt Swiftly selbst."), style: "swiftly-zweitzeile")
        gtk_widget_add_css_class(hint, "swiftly-warnung")
        gtk_label_set_xalign(OpaquePointer(hint), 0)
        let hk = PointerBox(hint), nk = PointerBox(name)
        let pointOut: () -> Void = {
            let n = String(cString: gtk_editable_get_text(OpaquePointer(nk.widget)))
            gtk_widget_set_visible(hk.widget, OwnHeaders.isLocked(n) ? 1 : 0)
        }
        pointOut()
        signal(name, "changed", pointOut)
        append(rail, hint)
        let rk = PointerBox(rail)
        signal(distance, "clicked") {
            reader.rows.removeAll { $0.rail == rk.widget }
            gtk_box_remove(asBox(lk.widget), rk.widget)
            changed()
        }
        signal(name, "changed", changed)
        signal(value, "changed", changed)
        reader.rows.append(.init(rail: rail, name: name, value: value))
        append(lk.widget, rail)
    }
    for k in available { rowCreate(k) }

    let toIt: Widget! = gtk_button_new()
    gtk_widget_add_css_class(toIt, "swiftly-flach")
    gtk_widget_set_halign(toIt, GTK_ALIGN_START)
    let toItRail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
    append(toItRail, gtk_image_new_from_icon_name("list-add-symbolic"))
    append(toItRail, label(translated("Header hinzufügen"), style: "swiftly-zweitzeile"))
    gtk_button_set_child(asButton(toIt), toItRail)
    signal(toIt, "clicked") { rowCreate(nil); changed() }
    append(content, toIt)

    append(outer, content)
    return (outer, reader)
}

extension App {

    /// **The active server's custom headers**, in settings under the "Server"
    /// group, without a page of their own, as on the Mac (`MacOwnHeaders`).
    /// "Sichern" only appears once something changed and applies to every
    /// further request immediately.
    func ownHeadersBuild() -> Widget! {
        let outer = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        guard let server = bundle?.serverURL else { return outer }

        final class Snapshot { var secured: [OwnHeader] = []; var button: Widget!; var reader: HeaderRowReader? }
        let state = Snapshot()
        state.secured = OwnHeaders.registered(for: server)
        let (section, reader) = advancedBuild(available: state.secured) {
            guard let button = state.button, let reader = state.reader else { return }
            gtk_widget_set_visible(button, reader.headers() != state.secured ? 1 : 0)
        }
        state.reader = reader
        append(outer, section)

        let button = primaryButton(translated("Sichern"), symbol: "object-select-symbolic")
        gtk_widget_set_margin_top(button, 14)
        gtk_widget_set_halign(button, GTK_ALIGN_START)
        gtk_widget_set_visible(button, 0)
        state.button = button
        signal(outer, "destroy") { state.button = nil; state.reader = nil }
        signal(button, "clicked") {
            guard let reader = state.reader else { return }
            Cache.headersSafe(reader.headers(), for: server)
            state.secured = OwnHeaders.registered(for: server)
            if let k = state.button { gtk_widget_set_visible(k, 0) }
        }
        append(outer, button)
        return outer
    }
}
