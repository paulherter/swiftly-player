import CGtk
import Foundation
import JellyfinKit

/// **A person: who they are and what exists for them.**
///
/// Ported from `Sources/Shared/PersonView.swift`. A click on a cast member
/// used to lead nowhere; worse, the cast row built a `gtk_button_new()` with no
/// signal connected, a button that highlights on hover and does nothing.
///
/// **The layout follows the detail page:** a banner on top with image and name
/// at the bottom left, below it the role the user came through, and the
/// biography. Then two rows: what is on the server, and, with Seerr, what can
/// be requested.
///
/// **What it does *not* have:** main button, action row, file excerpt. A person
/// is not played. The switch therefore lives in ``detailShow(_:schub:)`` and
/// not at the caller, so every path to a person yields the same page.
extension App {

    // MARK: - Opening

    /// Opens a person tapped on a cast row.
    ///
    /// **Fetch first, then push.** A cast `Person` entry only carries name, role
    /// and image marker; birth date, place and biography live on the item with
    /// the same ID. The page is built from the fetched item, and if none comes
    /// back, from whatever the tile provides rather than not at all.
    func openPerson(_ person: Person, origin: String?) {
        personRole = person.role
        personOrigin = origin
        guard let client else { return }
        Task.detached { [self] in
            let full = try? await client.item(id: person.id)
            onMainThread {
                let target = full ?? Item(id: person.id, name: person.name, type: "Person")
                self.pagesStack[self.section, default: []].append(target)
                self.detailShow(target)
            }
        }
    }

    // MARK: - Layout

    func personPageShow(_ person: Item, push: Push) {
        detailTouched = false
        sections = []
        let disc = nextDisc()

        let page = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_add_css_class(page, "swiftly-seitenton")

        let scroller = pagesScroller()
        gtk_scrolled_window_set_child(OpaquePointer(scroller), page)

        let over: Widget! = gtk_overlay_new()
        gtk_overlay_set_child(OpaquePointer(over), scroller)
        gtk_overlay_add_overlay(OpaquePointer(over), detailHeaderBuild(person))
        append(detailWrapper, over)

        append(page, personHeader(person))

        let bottom = stack(GTK_ORIENTATION_VERTICAL, spacing: 26)
        gtk_widget_set_margin_top(bottom, 26)
        gtk_widget_set_margin_bottom(bottom, Int32(Theme.edgeSpacing))
        append(page, bottom)

        // **The role waits for nothing**, it came with the tap.
        if let role = personRole, !role.isEmpty, let origin = personOrigin {
            let row = label(String(format: translated("%1$@ in %2$@"), role, origin),
                                     style: "swiftly-zweitzeile")
            gtk_widget_add_css_class(row, "swiftly-rolle")
            gtk_label_set_xalign(OpaquePointer(row), 0)
            gtk_widget_set_margin_start(row, Int32(Theme.edgeSpacing))
            gtk_widget_set_margin_end(row, Int32(Theme.edgeSpacing))
            append(bottom, row)
        }

        if let text = person.description, !text.isEmpty {
            append(bottom, biography(text))
        }

        // The rows arrive later; until then the space is empty. **No loading ring**:
        // the page is not waiting, it is just still empty.
        let railsSpace = stack(GTK_ORIENTATION_VERTICAL, spacing: 26)
        append(bottom, railsSpace)
        personRailsLoadMore(person, in: railsSpace)

        // Fade the title in at the top, over the same distance as on the detail page.
        let verticalRight = gtk_scrolled_window_get_vadjustment(OpaquePointer(scroller))!
        signalRaw(UnsafeMutableRawPointer(verticalRight), "value-changed") { [weak self] in
            guard let self, let header = self.detailHeaderTitle else { return }
            let v = gtk_adjustment_get_value(verticalRight)
            let strength = min(max((v - 74) / 42, 0), 1)
            gtk_widget_set_opacity(header, strength)
            if let bar = self.detailHeaderBar { gtk_widget_set_opacity(bar, strength) }
            if let history = self.detailHeaderHistory {
                gtk_widget_set_opacity(history, 1 - strength)
            }
        }

        shove(toward: disc, bearing: push)
    }

    // MARK: - Header

    /// Banner with round portrait, name, birthday and place.
    ///
    /// **Round because it is a picture**, like the cast tiles the user came from.
    /// The iPad was the only one with a square poster, because it used the
    /// detail pages' `HeroHeader`; that was the outlier, not the rule.
    private func personHeader(_ person: Item) -> Widget! {
        let header: Widget! = gtk_overlay_new()
        gtk_widget_set_hexpand(header, 1)

        // **Shorter than a detail page.** There, the header zone carries a 230 pt
        // block (title, info, description, button row); here only a 104 portrait
        // and two lines. The same height would leave a hole.
        let backdrop = Backdrop(height: Theme.personHeight)
        backdrop.fullWide = true
        gtk_overlay_set_child(OpaquePointer(header), backdrop.display)
        gtk_overlay_add_overlay(OpaquePointer(header), personBlock(person))
        personBannerLoadMore(person, in: backdrop)
        return header
    }

    /// **Fixed positions instead of fixed heights**, same reasoning as
    /// ``heldenblock(_:)``. What grows too large is clipped and moves nothing.
    ///
    /// **The numbers come from `PersonView.swift`:** round portrait 88, spacing
    /// 16, next to it a text block aligned to the **bottom**
    /// (`HStack(alignment: .bottom)`). Name 34 with 6 below, then the two 14-pt
    /// lines with 1 between, 82 in total, so the text starts 6 below the top
    /// edge of the portrait.
    ///
    ///     0    portrait 88 round, next to it from 104:
    ///     6    name         41
    ///     53   born         17
    ///     71   place        17
    private func personBlock(_ person: Item) -> Widget! {
        let inputField: Widget! = gtk_fixed_new()
        gtk_widget_set_halign(inputField, GTK_ALIGN_START)
        gtk_widget_set_valign(inputField, GTK_ALIGN_END)
        gtk_widget_set_size_request(inputField, 720, Int32(Theme.personBlockHeight))
        gtk_widget_set_margin_start(inputField, Int32(Theme.edgeSpacing))
        // 22, as in `PersonView.swift`.
        gtk_widget_set_margin_bottom(inputField, 22)

        // **With an initial when there is no image.** `framedImage` leaves an
        // empty circle in that case; `profileCharacter` carries the first letter, as
        // everywhere else in the app.
        let parts = profileCharacter(name: person.name, border: Theme.personBlockHeight,
                                  style: "swiftly-personkopf",
                                  fontStyle: "swiftly-zeichen96")
        gtk_fixed_put(asField2(inputField), parts.wrapper, 0, 0)
        if let addresses, let url = addresses.construct(itemID: person.id,
                                                  mass: .atMostHigh(300)) {
            profileImageLoad(parts, url: url, key: ImageKey.of(url))
        }

        let name = label(person.name, style: "swiftly-heldtitel")
        gtk_label_set_xalign(OpaquePointer(name), 0)
        gtk_label_set_ellipsize(OpaquePointer(name), PANGO_ELLIPSIZE_END)
        gtk_widget_set_size_request(name, 560, 41)
        gtk_fixed_put(asField2(inputField), name, 104, 6)

        // **The two lines have their place from the start.** If they were added
        // only on load, they would push the name up mid-slide-in. They sit at fixed
        // positions, so nothing moves even if one stays empty.
        if let born = birthRow(person) {
            // 14 and `schriftLeise`, as in `Sources/macOS/PersonView.swift`.
            let z = label(born, style: "swiftly-angaben")
            gtk_widget_add_css_class(z, "dim-label")
            gtk_label_set_xalign(OpaquePointer(z), 0)
            gtk_widget_set_size_request(z, 520, 17)
            gtk_fixed_put(asField2(inputField), z, 104, 53)
        }
        if let place = person.productionLocations?.first, !place.isEmpty {
            let z = label(place, style: "swiftly-angaben")
            gtk_widget_add_css_class(z, "dim-label")
            gtk_label_set_xalign(OpaquePointer(z), 0)
            gtk_label_set_ellipsize(OpaquePointer(z), PANGO_ELLIPSIZE_END)
            gtk_widget_set_size_request(z, 520, 17)
            gtk_fixed_put(asField2(inputField), z, 104, 71)
        }
        return inputField
    }

    /// **Server data never goes through translation**, so the date is formatted
    /// via the locale rather than the catalog.
    private func birthRow(_ person: Item) -> String? {
        guard let parts = person.daysDate,
              let date = Calendar.current.date(from: parts) else { return nil }
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return String(format: translated("Geboren %@"), f.string(from: date))
    }

    /// The banner cycles through the backgrounds of the person's titles.
    ///
    /// **Every six seconds, with a soft cross-fade** (six seconds hold, 1.2
    /// seconds blend, as on Apple). A tick on a destroyed GTK object crashes,
    /// and ``Backdrop`` already handles it: it records via `destroy` whether it
    /// is still alive, and `setzen` returns early if not. The tick checks the
    /// same before continuing and ends itself that way.
    ///
    /// **Only real landscape images cycle.** If none of the titles has one, the
    /// banner uses the fallback the first title provides; otherwise the round
    /// portrait would sit at the bottom of a dark area. Apple's `headerImageURL`
    /// handles the same case.
    private func personBannerLoadMore(_ person: Item, in backdrop: Backdrop) {
        guard let client, let addresses else { return }
        Task.detached { [self] in
            // `?? []` only for the banner: it is about an image, not a statement to the
            // user. The failed/empty distinction is shown on Apple; GTK follows with
            // the UI.
            let title = await client.title(person: person.id) ?? []
            guard let firstOne = title.first else { return }
            var images = title.compactMap {
                ImageSelection.landscape($0, addresses: addresses, width: 1600)?.url
            }
            if images.isEmpty,
               let substitute = await client.headerImageFallback(for: firstOne, addresses: addresses,
                                                        width: 1600) {
                images = [substitute]
            }
            // **Only the first image; the banner loop is removed.** A new background
            // every six seconds was decoration nobody asked for.
            guard let url = images.first, backdrop.lives,
                  let data = await ImageStorage.shared.load(url, key: ImageKey.of(url))
            else { return }
            onMainThread { backdrop.setDown(data) }
        }
    }

    private func biography(_ text: String) -> Widget! {
        let block = stack(GTK_ORIENTATION_VERTICAL, spacing: 6)
        gtk_widget_set_margin_start(block, Int32(Theme.edgeSpacing))
        gtk_widget_set_margin_end(block, Int32(Theme.edgeSpacing))

        let inputField = label(text, style: "swiftly-beschreibung", wrap: true)
        gtk_label_set_xalign(OpaquePointer(inputField), 0)
        gtk_label_set_lines(OpaquePointer(inputField), 4)
        gtk_label_set_ellipsize(OpaquePointer(inputField), PANGO_ELLIPSIZE_END)
        append(block, inputField)

        // **Not a standard control**: a bare glyph with a word, not a
        // `GtkExpander`.
        let more: Widget! = gtk_button_new()
        gtk_widget_add_css_class(more, "swiftly-umriss")
        gtk_widget_set_halign(more, GTK_ALIGN_START)
        gtk_button_set_label(asButton(more), translated("Mehr"))
        // `Widget` is a pointer, not an object, so `weak` does not work on it. It is
        // not needed: the callback hangs on the button and dies with it, and both
        // fields belong to the same page.
        signal(more, "clicked") {
            let whole = gtk_label_get_lines(OpaquePointer(inputField)) == 4
            gtk_label_set_lines(OpaquePointer(inputField), whole ? -1 : 4)
            gtk_label_set_ellipsize(OpaquePointer(inputField),
                                    whole ? PANGO_ELLIPSIZE_NONE : PANGO_ELLIPSIZE_END)
            gtk_button_set_label(asButton(more),
                                 whole ? translated("Weniger") : translated("Mehr"))
        }
        append(block, more)
        return block
    }

    // MARK: - Rows

    /// **Own server first, Seerr beside it.**
    ///
    /// For a filmography, Seerr first asks TMDB, which sometimes takes seconds.
    /// On Apple the whole page once waited for that. The row "Auf deinem Server"
    /// therefore appears as soon as the server answers, and "Kann angefragt
    /// werden" is added **below**, so nothing above it moves.
    private func personRailsLoadMore(_ person: Item, in space: Widget!) {
        guard let client else { return }
        // **Placeholder while loading**: before the answer there was nothing.
        wipe(space)
        append(space, railsPlaceholder(margin: Theme.edgeSpacing))
        let container = held(space)
        let seerr = seerrClient
        Task.detached { [self] in
            let fetched = await client.title(person: person.id)
            let ownOnes = fetched ?? []
            postPush {
                let target = container.widget
                wipe(target)
                // **`nil` means failed**: not "nothing else on your server", but the server
                // failure wording.
                if fetched == nil {
                    append(target, self.disturbHint(top: 0) { [weak self] in
                        guard let self, let space = container.widget else { return }
                        self.personRailsLoadMore(person, in: space)
                    })
                    self.personRequestableLoadMore(person, ownOnes: [],
                                                   seerr: seerr, in: target)
                } else if !ownOnes.isEmpty {
                    append(target, self.railBuild(title: translated("Auf deinem Server"),
                                                    art: .new, items: ownOnes))
                    self.personRequestableLoadMore(person, ownOnes: ownOnes,
                                                   seerr: seerr, in: target)
                } else {
                    // **Only when truly nothing is there.** Empty space without a word would
                    // look like a page still loading.
                    let hint = label(
                        String(format: translated("Auf deinem Server gibt es sonst nichts mit %@."),
                               person.name),
                        style: "swiftly-koerper", wrap: true)
                    gtk_label_set_xalign(OpaquePointer(hint), 0)
                    gtk_widget_add_css_class(hint, "swiftly-leise")
                    gtk_widget_set_margin_start(hint, Int32(Theme.edgeSpacing))
                    gtk_widget_set_margin_end(hint, Int32(Theme.edgeSpacing))
                    append(target, hint)
                    self.personRequestableLoadMore(person, ownOnes: ownOnes,
                                                   seerr: seerr, in: target)
                }
                letGo(container)
            }
        }
    }

    /// **"Kann angefragt werden": the second row of the person page.**
    ///
    /// Missing on Linux entirely, regardless of whether anyone is signed in to
    /// Seerr, because the call did not exist. On the Mac it sits below "Auf
    /// deinem Server" (`Sources/macOS/PersonView.swift`), filled from
    /// `seerr.filmography(person:)` via the person's TMDB ID.
    ///
    /// **Below and later.** Seerr first asks TMDB, which sometimes takes
    /// seconds; the first row must not wait for it.
    ///
    /// **Only what is not already there.** Seerr knows what it manages itself;
    /// what reached the server another way shows up there as open, and the name
    /// catches that case.
    private func personRequestableLoadMore(_ person: Item, ownOnes: [Item],
                                           seerr: SeerrClient?, in space: Widget!) {
        guard let seerr, let tmdb = person.tmdbId else { return }
        let container = held(space)
        let known = Set(ownOnes.map { $0.name.lowercased() })
        Task.detached { [self] in
            let foreignOnes = await seerr.filmography(person: tmdb)
                .filter { !$0.state.alreadyPresent && !known.contains($0.title.lowercased()) }
            onMainThread {
                defer { letGo(container) }
                guard !foreignOnes.isEmpty else { return }
                append(container.widget,
                          self.railBuild(title: translated("Kann angefragt werden"),
                                          imageHeight: Theme.tileHeight,
                                          piece: Theme.tileWidth + Theme.tileSpacing,
                                          tiles: foreignOnes.map { self.seerrTile($0) }))
            }
        }
    }
}
