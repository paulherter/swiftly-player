import CGtk
import Foundation
import JellyfinKit

/// Where the window stands: area, the detail pages above it and an open subpage.
struct NavPlace: Equatable {
    var section: Region
    var pages: [Item]
    var subpage: App.Subpage?

    static func == (a: NavPlace, b: NavPlace) -> Bool {
        a.section == b.section && a.subpage == b.subpage && a.pages.map(\.id) == b.pages.map(\.id)
    }
}

/// **One history for the whole window, as in a browser** (`Navigator.swift` on the Mac).
///
/// Every step that goes somewhere new records where the window stood; the two fixed
/// arrows at the top left walk that record, areas included. A page that closes itself
/// (its own back step) puts where it was on the forward list.
extension App {
    func navPlace() -> NavPlace {
        NavPlace(section: section, pages: pagesStack[section] ?? [], subpage: openSubpage)
    }

    /// Called by `shove(toward:bearing:)`, the one place every page change passes.
    func navNote(_ bearing: Push) {
        guard bearing != .without else { return }
        let now = navPlace()
        defer { navRefresh() }
        let old = navNow ?? NavPlace(section: .start, pages: [], subpage: nil)
        if let wanted = navPending {
            if wanted == now { navPending = nil; navNow = now }
            return
        }
        guard now != old else { return }
        if bearing == .back {
            navFuture.append(old)
            while navHistory.last == now { navHistory.removeLast() }
        } else {
            navHistory.append(old)
            navFuture = []
        }
        navNow = now
    }

    func navCanBack() -> Bool { navHistory.contains { $0 != navPlace() } }
    func navCanForward() -> Bool { navFuture.contains { $0 != navPlace() } }

    func navBackStep() {
        guard runningTitle == nil else { return }
        let now = navPlace()
        while let place = navHistory.popLast() {
            guard place != now else { continue }
            navFuture.append(now)
            navRestore(place, push: .back)
            return
        }
    }

    func navForwardStep() {
        guard runningTitle == nil else { return }
        let now = navPlace()
        while let place = navFuture.popLast() {
            guard place != now else { continue }
            navHistory.append(now)
            navRestore(place, push: .deeper)
            return
        }
    }

    /// A new account or a sign-out starts a new history.
    func navReset() {
        navHistory = []
        navFuture = []
        navNow = nil
        navPending = nil
        navRefresh()
    }

    /// **Back slides the page out to the right, forward pushes it in from the right**, as the
    /// Mac does; only a jump to another area fades.
    private func navRestore(_ place: NavPlace, push wished: Push) {
        let push: Push = place.section == section ? wished : .fade
        navPending = place
        section = place.section
        pagesStack[place.section] = place.pages
        if let sub = place.subpage {
            subpageOpen(sub, push: push)
        } else {
            openSubpage = nil
            sectionRowsDraw()
            if let top = place.pages.last, top.type == App.downloadSeriesArt {
                downloadSeriesShow(top, push: push)
            } else if let top = place.pages.last {
                detailShow(top, push: push)
            } else {
                sectionShow(place.section.identifier, push: push)
            }
            sectionLoadOnce(place.section)
        }
        // A path that shows nothing new (same widget on top) never reaches `shove`.
        if navPlace() == place { navNow = place; navPending = nil }
        navRefresh()
    }

    /// The pair of buttons in the header bar: caret left, caret right, 30 x 24 each. An
    /// arrow with nowhere to go stays in place at 35 %, so nothing beside it jumps.
    func navArrowsBuild() -> Widget! {
        let row = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 2)
        func arrow(_ icon: String, _ name: String, _ tip: String, _ action: @escaping () -> Void) -> Widget! {
            let b: Widget! = gtk_button_new()
            gtk_widget_add_css_class(b, "swiftly-navpfeil")
            caption(b, translated(name))
            gtk_widget_set_tooltip_text(b, tip)
            gtk_button_set_child(asButton(b), gtk_image_new_from_icon_name(icon))
            gtk_widget_set_size_request(b, 30, 24)
            signal(b, "clicked", action)
            return b
        }
        navBackButton = arrow("go-previous-symbolic", "Zurück", "\(translated("Zurück")) (Ctrl+[)") { [weak self] in
            self?.navBackStep()
        }
        navForwardButton = arrow("go-next-symbolic", "Vorwärts", "\(translated("Vorwärts")) (Ctrl+])") { [weak self] in
            self?.navForwardStep()
        }
        append(row, navBackButton)
        append(row, navForwardButton)
        navArrowsRow = row
        navRefresh()
        return row
    }

    func navRefresh() {
        guard let back = navBackButton, let forward = navForwardButton, let row = navArrowsRow else { return }
        // Only over the main view: not on the sign-in page, not in the player.
        gtk_widget_set_visible(row, (client != nil && runningTitle == nil) ? 1 : 0)
        let canBack = navCanBack()
        let canForward = navCanForward()
        gtk_widget_set_sensitive(back, canBack ? 1 : 0)
        gtk_widget_set_sensitive(forward, canForward ? 1 : 0)
    }
}
