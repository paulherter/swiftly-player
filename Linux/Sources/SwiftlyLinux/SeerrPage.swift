import CGtk
import Foundation
import JellyfinKit

/// **The Seerr page: the same detail page, with foreign data.**
///
/// A tap on a tile used to trigger the request confirmation immediately,
/// which left out everything one wants to know before requesting: what it
/// is about, how long it is, how it is rated, which seasons exist, who is
/// in it.
///
/// **It is the detail page line for line**, not a second kind of page beside
/// it. Rebuilding the header instead of reusing it produced a gradient at the
/// top that the real page does not have. So this uses the same
/// `detailHeaderBuild`, the same `Backdrop`, the same field grid in the hero
/// block, and the same `rail` heading for cast and similar titles.
///
/// Only two things differ, both because of the source: images come from TMDB
/// instead of the own server, and instead of "Abspielen" there is the button
/// that requests.
extension App {

    // MARK: Opening

    /// **It slides in like a title page, not like a setting.** A Seerr title is a
    /// level deeper, not a place beside; hence `Push.deeper` and the back arrow
    /// at the top left.
    ///
    /// The page stack holds `Item`, and a Seerr result is not one; the page
    /// therefore sits on the subpage layer. Back leads to the section it was
    /// opened from.
    func seerrPageOpen(_ t: SeerrHit) {
        seerrSelectedSeasons = []
        seerrConfirmed = false
        seerrSeasonsOpen = false
        seerrRuns = false
        seerrRequested = false
        seerrState = nil
        seerrError = nil
        let disc: Widget! = nextDisc()
        // **Not one of the settings subpages**, otherwise a second call would take
        // it for the same page and rebuild in place instead of sliding in.
        openSubpage = nil
        append(disc, seerrDetailBuild(t))
        shove(toward: disc, bearing: .deeper)
        seerrDetailLoadMore(t)
    }

    // MARK: Layout

    private func seerrDetailBuild(_ t: SeerrHit) -> Widget! {
        let scroller = pagesScroller()
        let block = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)

        append(block, seerrHeroHeader(t))

        seerrBlock = stack(GTK_ORIENTATION_VERTICAL, spacing: 30)
        gtk_widget_set_margin_start(seerrBlock, Int32(Theme.edgeSpacing))
        gtk_widget_set_margin_end(seerrBlock, Int32(Theme.edgeSpacing))
        gtk_widget_set_margin_top(seerrBlock, 22)
        gtk_widget_set_margin_bottom(seerrBlock, 40)
        append(block, seerrBlock)

        gtk_scrolled_window_set_child(OpaquePointer(scroller), block)

        let over: Widget! = gtk_overlay_new()
        gtk_overlay_set_child(OpaquePointer(over), scroller)
        gtk_overlay_add_overlay(OpaquePointer(over), seerrHeaderBar(t))
        return over
    }

    /// Same header as the detail page: back arrow, soft gradient. Not rebuilt:
    /// `detailHeaderBuild` takes an `Item`, which does not exist here, so the
    /// measurements are copied from there and exist in exactly one more place.
    private func seerrHeaderBar(_ t: SeerrHit) -> Widget! {
        let header: Widget! = gtk_overlay_new()
        gtk_widget_set_valign(header, GTK_ALIGN_START)
        gtk_widget_set_halign(header, GTK_ALIGN_FILL)

        let history: Widget! = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
        gtk_widget_add_css_class(history, "swiftly-kopfverlauf")
        gtk_widget_set_size_request(history, -1, 74)
        gtk_overlay_set_child(OpaquePointer(header), history)

        let bar = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 4)
        gtk_widget_set_valign(bar, GTK_ALIGN_START)
        gtk_widget_set_margin_start(bar, Int32(Theme.edgeSpacing - 8))
        gtk_widget_set_margin_top(bar, 24)

        let arrow: Widget! = gtk_button_new()
        gtk_widget_add_css_class(arrow, "swiftly-zurueck")
        caption(arrow, translated("Zurück"))
        gtk_button_set_child(asButton(arrow), gtk_image_new_from_icon_name("go-previous-symbolic"))
        signal(arrow, "clicked") { [weak self] in self?.subpageBack() }
        append(bar, arrow)

        gtk_overlay_add_overlay(OpaquePointer(header), bar)
        return header
    }

    /// Backdrop on the right, block on the left: `heroHeader` with a TMDB image.
    private func seerrHeroHeader(_ t: SeerrHit) -> Widget! {
        let header: Widget! = gtk_overlay_new()
        gtk_widget_set_hexpand(header, 1)

        let image = Backdrop()
        gtk_overlay_set_child(OpaquePointer(header), image.display)
        gtk_overlay_add_overlay(OpaquePointer(header), seerrHeroBlock(t))

        // **The backdrop needs the landscape image, not the poster.** On TV it
        // once was missing entirely because only the tinted background was set;
        // hence an explicit `backdrop()`.
        if let large = t.backdrop(width: 1280) {
            Task.detached {
                guard let data = await ImageStorage.shared.load(
                    large, key: ImageKey.of(large)) else { return }
                onMainThread { image.setDown(data) }
            }
        }
        return header
    }

    /// Same four fields as `heroBlock`: title 0/42, info 54/20, description
    /// 92/66, button row 182/48.
    private func seerrHeroBlock(_ t: SeerrHit) -> Widget! {
        let inputField: Widget! = gtk_fixed_new()
        gtk_widget_set_halign(inputField, GTK_ALIGN_START)
        gtk_widget_set_valign(inputField, GTK_ALIGN_START)
        gtk_widget_set_size_request(inputField, 640, 230)
        gtk_widget_set_margin_start(inputField, Int32(Theme.edgeSpacing))
        gtk_widget_set_margin_top(inputField, Int32(Theme.titleHeight + 98 - Theme.headerRowHeight))

        let name = label(t.title, style: "swiftly-heldtitel")
        gtk_label_set_ellipsize(OpaquePointer(name), PANGO_ELLIPSIZE_END)
        gtk_label_set_xalign(OpaquePointer(name), 0)
        gtk_fixed_put(asField2(inputField), compartment(name, width: 640, height: 42), 0, 0)

        seerrDetails = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        seerrDetailsFill(t, nil)
        gtk_fixed_put(asField2(inputField), compartment(seerrDetails, width: 640, height: 20), 0, 54)

        seerrAction = label("", style: "swiftly-koerper", wrap: true)
        gtk_label_set_xalign(OpaquePointer(seerrAction), 0)
        gtk_label_set_yalign(OpaquePointer(seerrAction), 0)
        gtk_label_set_lines(OpaquePointer(seerrAction), 3)
        gtk_label_set_ellipsize(OpaquePointer(seerrAction), PANGO_ELLIPSIZE_END)
        gtk_widget_add_css_class(seerrAction, "swiftly-beschreibung")
        gtk_fixed_put(asField2(inputField), compartment(seerrAction, width: 640, height: 66,
                                           verticalRight: GTK_ALIGN_START), 0, 92)

        let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        seerrButtonRail = rail
        // A request can come back after the page is gone; it must not write into
        // destroyed widgets.
        signal(rail, "destroy") { [weak self] in
            if self?.seerrButtonRail == rail { self?.seerrButtonRail = nil }
        }
        seerrButtonRailFill(t)
        gtk_fixed_put(asField2(inputField), compartment(seerrButtonRail, width: 640,
                                           height: Theme.primaryButtonHeight), 0, 182)
        return inputField
    }

    // MARK: Info and button

    /// Year, runtime, genres, rating: **one** line, as on the detail page. What
    /// Seerr has not delivered yet is simply missing; the line is filled in once
    /// the answer arrives.
    private func seerrDetailsFill(_ t: SeerrHit, _ d: SeerrDetail?) {
        guard seerrDetails != nil else { return }
        wipe(seerrDetails)
        var pieces: [String] = []
        if let j = t.year { pieces.append(String(j)) }
        if let min = d?.runtime, min > 0 {
            pieces.append(String(format: translated("%lld Min."), min))
        }
        if let g = d?.genres, !g.isEmpty { pieces.append(g.prefix(2).joined(separator: ", ")) }
        if let b = d?.rating, b > 0 {
            pieces.append(comma(b))
        }
        for (i, s) in pieces.enumerated() {
            if i > 0 {
                let point = label("·", style: "swiftly-zweitzeile")
                gtk_widget_add_css_class(point, "swiftly-sehrleise")
                append(seerrDetails, point)
            }
            append(seerrDetails, label(s, style: "swiftly-zweitzeile"))
        }
    }

    /// **The button says what applies**, not always "Anfragen".
    ///
    /// Five states, five labels, worded exactly like `Seerrstand.wort` on the
    /// Apple versions. Where there is nothing to press, the sentence from
    /// `Seerrstand.hint` replaces a dead button.
    private func seerrButtonRailFill(_ t: SeerrHit) {
        guard seerrButtonRail != nil else { return }
        wipe(seerrButtonRail)

        // **After the request, the row says what became of it**, worded like the
        // Mac (`SeerrTileAndPage.swift`, `action`). Otherwise the button stayed
        // on "Wirklich anfragen?" and the message went to the hint field of the
        // Jellyfin detail page, which this page does not have: the request went
        // through, but nothing was visible.
        if seerrRequested {
            let word = label(translated("Angefragt. Sobald sie freigegeben ist, lädt sie von selbst."),
                                    style: "swiftly-koerper")
            gtk_widget_add_css_class(word, "swiftly-leise")
            gtk_widget_set_valign(word, GTK_ALIGN_CENTER)
            append(seerrButtonRail, word)
            return
        }

        // **The server knows better than the earlier search result:** on reopening
        // and after the request, its state applies.
        let state = seerrState ?? t.state
        guard state.requestable else {
            let word = label(seerrStateWord(state), style: "swiftly-koerper")
            gtk_widget_add_css_class(word, "swiftly-leise")
            gtk_widget_set_valign(word, GTK_ALIGN_CENTER)
            append(seerrButtonRail, word)
            return
        }

        // **Two steps, and the second is the actual request.**
        //
        // For a series, the season list takes the second step: without a selection
        // nothing happens. A movie has nothing to select, so the button itself asks
        // again: the first press shows "Wirklich anfragen?", the second sends. On
        // Linux a movie request used to go out on the **first** press; every other
        // platform has this safeguard built in (`SeerrDetailView.swift`,
        // `SeerrTileAndPage.swift`).
        let title: String
        if seerrRuns {
            title = translated("Wird angefragt…")
        } else if t.isSeries {
            title = seerrSelectedSeasons.isEmpty
                ? translated("Staffeln wählen")
                : numberWord(seerrSelectedSeasons.count, one: translated("1 Staffel anfragen"),
                           many: translated("%lld Staffeln anfragen"))
        } else {
            title = seerrConfirmed ? translated("Wirklich anfragen?") : translated("Anfragen")
        }
        let button = primaryButton(title, symbol: "folder-download-symbolic")
        gtk_widget_set_size_request(button, Int32(Theme.primaryButtonWidth),
                                    Int32(Theme.primaryButtonHeight))
        signal(button, "clicked") { [weak self] in
            guard let self, !self.seerrRuns else { return }
            if t.isSeries {
                // **The first press expands the list.** Without a selection nothing happens
                // afterwards: empty used to mean "all", so someone who only wanted to see
                // which seasons exist requested the whole series.
                guard self.seerrSeasonsOpen else {
                    self.seerrSeasonsOpen = true
                    if let on = self.seerrSeasonExpand {
                        gtk_revealer_set_reveal_child(asExpand(on), 1)
                    }
                    return
                }
                guard !self.seerrSelectedSeasons.isEmpty else { return }
                self.seerrRequestFromPage(t)
                return
            }
            if !self.seerrConfirmed {
                self.seerrConfirmed = true
                self.seerrButtonRailFill(t)
                return
            }
            self.seerrRequestFromPage(t)
        }
        append(seerrButtonRail, button)

        // An error stays next to the button until pressed again.
        if let error = seerrError {
            let l = label(error, style: "swiftly-zweitzeile", wrap: true)
            gtk_widget_add_css_class(l, "swiftly-warnung")
            gtk_label_set_xalign(OpaquePointer(l), 0)
            gtk_label_set_lines(OpaquePointer(l), 2)
            gtk_label_set_ellipsize(OpaquePointer(l), PANGO_ELLIPSIZE_END)
            gtk_widget_set_valign(l, GTK_ALIGN_CENTER)
            gtk_widget_set_hexpand(l, 1)
            append(seerrButtonRail, l)
        }
    }

    private func seerrStateWord(_ state: SeerrState) -> String {
        switch state {
        case .opened, .deleted:  return translated("Nicht auf deinem Server")
        case .waitsSharing:  return translated("Wartet auf Freigabe")
        case .loads:              return translated("Angefragt")
        case .partWayPresent:        return translated("Teilweise vorhanden")
        case .present:                 return translated("Auf deinem Server")
        }
    }

    // MARK: Loading more

    private func seerrDetailLoadMore(_ t: SeerrHit) {
        guard let client = seerrClient else { return }
        Task.detached { [self] in
            let d = await client.detail(art: t.art, id: t.id)
            onMainThread {
                // **It says when Seerr is unreachable**, with Seerr's address and not the
                // own server's: that one is running, otherwise the user would not be on this
                // page.
                guard let d else {
                    guard self.seerrBlock != nil else { return }
                    wipe(self.seerrBlock)
                    let h = self.disturbHint(top: 0, address: client.address.host) { [weak self] in
                        self?.seerrDetailLoadMore(t)
                    }
                    gtk_widget_set_halign(h, GTK_ALIGN_START)
                    gtk_widget_set_margin_start(h, Int32(Theme.edgeSpacing))
                    append(self.seerrBlock, h)
                    return
                }
                if let new = d.state, new != (self.seerrState ?? t.state) {
                    self.seerrState = new
                    self.seerrButtonRailFill(t)
                }
                self.seerrDetailsFill(t, d)
                if let text = d.description, !text.isEmpty {
                    gtk_label_set_text(OpaquePointer(self.seerrAction), text)
                }
                self.seerrBaseFill(t, d)
            }
        }
    }

    /// Seasons, cast, similar titles, in this order, as on the Mac.
    private func seerrBaseFill(_ t: SeerrHit, _ d: SeerrDetail) {
        guard seerrBlock != nil else { return }
        wipe(seerrBlock)

        // **Only on press, not from the start.** The Mac shows the season list only
        // once the main button is pressed (`SeerrTileAndPage.swift`); the first
        // press reads "Staffeln waehlen", the second requests. Here the list used
        // to be open as soon as the data arrived, and the button said "Anfragen"
        // without any selection having been made.
        if t.isSeries, !d.seasons.isEmpty {
            let list = seerrSeasonList(t, d)
            let expand: Widget! = gtk_revealer_new()
            gtk_revealer_set_transition_type(asExpand(expand),
                                             GTK_REVEALER_TRANSITION_TYPE_SLIDE_DOWN)
            gtk_revealer_set_transition_duration(asExpand(expand), 220)
            gtk_revealer_set_child(asExpand(expand), list)
            gtk_revealer_set_reveal_child(asExpand(expand), seerrSeasonsOpen ? 1 : 0)
            seerrSeasonExpand = expand
            append(seerrBlock, expand)
        }
        if !d.cast.isEmpty {
            append(seerrBlock, seerrPeopleRail(translated("Besetzung"), d.cast))
        }
        if !d.similarOne.isEmpty {
            append(seerrBlock, seerrTitleRail(translated("Ähnliche Titel"), d.similarOne, t))
        }
    }

    /// **Seasons are chosen, not assumed.** The request used to send
    /// `seasons: nil`, silently meaning all; for a series with a hundred
    /// episodes that is no detail.
    private func seerrSeasonList(_ t: SeerrHit, _ d: SeerrDetail) -> Widget! {
        let block = stack(GTK_ORIENTATION_VERTICAL, spacing: 10)
        append(block, label(translated("Welche Staffeln?"), style: "swiftly-reihe"))

        let space = rowsGroup()
        for (i, st) in d.seasons.enumerated() where !st.isSpecials {
            if i > 0 { append(space.space, rowsLine()) }
            let selected = seerrSelectedSeasons.contains(st.number)
            let name = String(format: translated("Staffel %lld"), st.number)
            let under = numberWord(st.episodes, one: translated("1 Folge"), many: translated("%lld Folgen"))
            let row = valuesRow(symbol: selected ? "object-select-symbolic" : "tv-symbolic",
                                   title: name, under: under,
                                   value: st.state.alreadyPresent ? translated("Auf deinem Server") : nil,
                                   accent: selected) { [weak self] in
                guard let self, !st.state.alreadyPresent else { return }
                if selected { self.seerrSelectedSeasons.remove(st.number) }
                else { self.seerrSelectedSeasons.insert(st.number) }
                self.seerrButtonRailFill(t)
                self.seerrBaseFill(t, d)
            }
            append(space.space, row)
        }
        append(block, space.outer)
        return block
    }

    private func seerrPeopleRail(_ title: String, _ folks: [SeerrPerson]) -> Widget! {
        var tiles: [Widget?] = []
        for person in folks.prefix(12) {
            let tile = stack(GTK_ORIENTATION_VERTICAL, spacing: 8)
            gtk_widget_set_size_request(tile, 110, -1)
            let (wrapper, image) = framedImage(width: 110, height: 110, style: "swiftly-rund")
            if let url = person.image(width: 220) {
                imageLoad(image, url: url, key: "seerr-person-\(person.id)", immediate: true)
            }
            append(tile, wrapper)
            let n = label(person.name, style: "swiftly-koerper")
            gtk_label_set_ellipsize(OpaquePointer(n), PANGO_ELLIPSIZE_END)
            gtk_label_set_xalign(OpaquePointer(n), 0)
            append(tile, n)
            if let role = person.role, !role.isEmpty {
                let r = label(role, style: "swiftly-zweitzeile")
                gtk_label_set_ellipsize(OpaquePointer(r), PANGO_ELLIPSIZE_END)
                gtk_label_set_xalign(OpaquePointer(r), 0)
                append(tile, r)
            }
            tiles.append(tile)
        }
        return railBuild(title: title, imageHeight: 110, piece: 110 + Theme.tileSpacing,
                          margin: 0, tiles: tiles)
    }

    /// **The tiles are buttons.** On TV they once were not, and "Aehnliches"
    /// could not be reached at all.
    private func seerrTitleRail(_ title: String, _ hit: [SeerrHit],
                                 _ origin: SeerrHit) -> Widget! {
        // **The media type is missing on suggestions**, but the page knows what it
        // is. Without this fallback no result would ever arrive there.
        let tiles: [Widget?] = hit.prefix(20).map {
            seerrTile($0.art.isEmpty ? origin : $0)
        }
        return railBuild(title: title, imageHeight: Theme.tileHeight,
                          piece: Theme.tileWidth + Theme.tileSpacing,
                          margin: 0, tiles: tiles)
    }

    // MARK: Requesting

    /// **Never empty.** For a series, `nil` means "all seasons" to Seerr, the
    /// case nobody should trigger by accident: someone only checking which
    /// seasons exist would request the whole series. On Apple a `guard` and a
    /// disabled button prevent it (`SeerrDetailView.swift`); on Linux the button
    /// was always active and sent `seasons: nil` for an empty selection.
    private func seerrRequestFromPage(_ t: SeerrHit) {
        guard let client = seerrClient, !seerrRuns else { return }
        guard !t.isSeries || !seerrSelectedSeasons.isEmpty else { return }
        let seasons = t.isSeries ? Array(seerrSelectedSeasons).sorted() : nil
        // **The response belongs to this page.** Someone who has opened another
        // page meanwhile sees none of it there.
        let rail = seerrButtonRail.map { Int(bitPattern: $0) }
        seerrError = nil
        seerrRuns = true
        seerrButtonRailFill(t)
        Task.detached { [self] in
            let failure: String?
            var newDetail: SeerrDetail?
            do {
                try await client.askFor(art: t.art, id: t.id, seasons: seasons)
                failure = nil
                // **Read the state, do not assume it.** If Seerr approves the request
                // immediately, the title is "loading" or available, not "waiting".
                newDetail = await client.detail(art: t.art, id: t.id)
            } catch {
                failure = readableError(error)
            }
            let freshValue = newDetail
            onMainThread {
                guard let now = self.seerrButtonRail, Int(bitPattern: now) == rail else { return }
                self.seerrRuns = false
                if let failure {
                    self.seerrError = failure
                } else {
                    var state = freshValue?.state ?? self.seerrState ?? t.state
                    if state.requestable { state = .waitsSharing }
                    self.seerrState = state
                    self.seerrRequested = state == .waitsSharing
                    if let on = self.seerrSeasonExpand {
                        gtk_revealer_set_reveal_child(asExpand(on), 0)
                    }
                    // The season list shows the fresh state for each season.
                    if let d = freshValue {
                        self.seerrSelectedSeasons = []
                        self.seerrSeasonsOpen = false
                        self.seerrBaseFill(t, d)
                    }
                }
                self.seerrButtonRailFill(t)
            }
        }
    }
}
