import CGtk
import Foundation
import JellyfinKit

/// **Seerr: request what the server does not have.**
///
/// The client is in the package (`JellyfinKit.SeerrClient`) and platform
/// independent; only the UI is here. On the Apple builds that is `SeerrModel`
/// plus four views; the split is the same, drawn in GTK.
extension App {

    /// The credentials, fetched once from storage.
    func seerrLoad() {
        seerrAccess = Cache.seerrRead()
        seerrClient = seerrAccess.map { SeerrClient(access: $0) }
    }

    var seerrPresent: Bool { seerrClient != nil }

    // MARK: Settings

    /// **Address and key, nothing more.**
    ///
    /// The same fields as the Apple version (`SeerrSettingsView`): the
    /// service address and an API key. It is checked with `gilt()` so a typo shows
    /// up here and not only when someone wants to request something.
    func seerrPageBuild(_ block: Widget!) {
        append(block, seerrHeader())

        let hint = label(
            translated("Jellyseerr oder Overseerr. Dann zeigt die Suche auch Titel, die noch nicht auf deinem Server sind, und du kannst sie anfragen."),
            style: "swiftly-zweitzeile", wrap: true)
        gtk_label_set_xalign(OpaquePointer(hint), 0)
        gtk_widget_set_margin_bottom(hint, 18)
        append(block, hint)

        // **Connected or form, not both.** On the Mac this spot reads
        // `if seerr.verbunden { verbunden } else { formSheet }`. Here the form was
        // always shown, so there was no way to disconnect: once signed in, the
        // credentials could only be overwritten.
        if seerrPresent, let access = seerrAccess {
            append(block, seerrConnectedGroup(access))
            return
        }

        let address: Widget! = gtk_entry_new()
        gtk_entry_set_placeholder_text(asField(address), "seerr.example.com")
        if let z = seerrAccess { gtk_editable_set_text(OpaquePointer(address), z.address.absoluteString) }
        append(block, fieldRow(translated("Adresse"), address))

        let user: Widget! = gtk_entry_new()
        gtk_entry_set_placeholder_text(asField(user), translated("Benutzername"))
        gtk_editable_set_text(OpaquePointer(user), username)
        append(block, fieldRow(translated("Benutzername"), user))

        let password: Widget! = gtk_entry_new()
        gtk_entry_set_visibility(asField(password), 0)
        gtk_entry_set_placeholder_text(asField(password), translated("Passwort"))
        append(block, fieldRow(translated("Passwort"), password))

        // "Erweitert": custom headers for a service in front of Seerr (issue #4).
        let (advanced, headerReader) = advancedBuild(available: [])
        gtk_widget_set_margin_bottom(advanced, 14)
        append(block, advanced)

        // **The password is not stored**, only the session Seerr issues for it. Same
        // promise as the Apple version, and it is shown on the page, not only in the
        // source.
        let commitment = label(
            translated("Swiftly speichert dein Passwort nicht, nur die Anmeldung bei Seerr."),
            style: "swiftly-zweitzeile", wrap: true)
        gtk_label_set_xalign(OpaquePointer(commitment), 0)
        gtk_widget_add_css_class(commitment, "dim-label")
        append(block, commitment)

        let state = label("", style: "swiftly-zweitzeile", wrap: true)
        gtk_label_set_xalign(OpaquePointer(state), 0)
        gtk_widget_set_margin_top(state, 12)
        gtk_widget_set_visible(state, 0)
        append(block, state)

        let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        gtk_widget_set_margin_top(rail, 20)
        let stateBox = PointerBox(state)
        let aBox = PointerBox(address)
        let bBox = PointerBox(user)
        let pBox = PointerBox(password)

        let linkUp = primaryButton(translated("Verbinden"), symbol: "object-select-symbolic")
        signal(linkUp, "clicked") { [weak self] in
            guard let self else { return }
            let raw = String(cString: gtk_editable_get_text(OpaquePointer(aBox.widget)))
            let b = String(cString: gtk_editable_get_text(OpaquePointer(bBox.widget)))
            let pw = String(cString: gtk_editable_get_text(OpaquePointer(pBox.widget)))
            let headers = headerReader.headers()
            // **One input yields several addresses.** `Seerr.addresses` fans it out (with
            // and without scheme, with and without port); same rule as on the Apple
            // builds, in the package and tested there.
            let addresses = Seerr.addresses(from: raw)
            guard !addresses.isEmpty else {
                self.seerrStateShow(stateBox, translated("Das ist keine gültige Adresse."))
                return
            }
            guard !b.isEmpty, !pw.isEmpty else {
                self.seerrStateShow(stateBox, translated("Benutzername und Passwort fehlen"))
                return
            }
            self.seerrStateShow(stateBox, translated("Verbinde…"))
            // The response may arrive after the page is closed.
            let stateLives = LifeCharacter(stateBox.widget)
            Task.detached {
                var lastOne: String?
                var firstTry: Error?
                for url in addresses {
                    do {
                        let new = try await SeerrClient.signIn(an: url, user: b, password: pw,
                                                                 headers: headers)
                        onMainThread {
                            self.seerrAccess = new
                            self.seerrClient = SeerrClient(access: new)
                            self.seerrApplies = .valid
                            Cache.seerrWrite(new)
                            // The password field is cleared once it is no longer needed, if the page
                            // still exists.
                            guard stateLives.lives else { return }
                            gtk_editable_set_text(OpaquePointer(pBox.widget), "")
                            self.seerrStateShow(stateBox, translated("Verbunden"))
                        }
                        return
                    } catch {
                        // As on the Apple side: the first network error stays unless the
                        // second attempt says something about Seerr itself.
                        let shown = firstTry.map { Seerr.errorToShow(first: $0, second: error) } ?? error
                        lastOne = readableError(shown)
                        guard error is URLError, firstTry == nil else { break }
                        firstTry = error
                    }
                }
                // **Capture first, then hand over.** Swift 6 does not allow capturing a
                // mutable variable across a thread boundary, rightly so: the block runs
                // later.
                let message = lastOne ?? translated("Keine Verbindung")
                onMainThread(during: stateLives) {
                    self.seerrStateShow(stateBox, message)
                }
            }
        }
        append(rail, linkUp)
        // **No disabled button, no button** (`SeerrSettingsView` on the Mac):
        // until address, user and password are filled there is nothing to do, and a
        // gray button suggests otherwise. It appears once all three are filled.
        let buttonBox = PointerBox(linkUp)
        let bringUpToDate: () -> Void = {
            let full = [aBox, bBox, pBox].allSatisfy {
                !String(cString: gtk_editable_get_text(OpaquePointer($0.widget)))
                    .trimmingCharacters(in: .whitespaces).isEmpty
            }
            gtk_widget_set_visible(buttonBox.widget, full ? 1 : 0)
        }
        for inputField in [address, user, password] {
            signal(inputField, "changed", bringUpToDate)
        }
        bringUpToDate()

        if seerrAccess != nil {
            let distance = secondaryButton("user-trash-symbolic", name: translated("Verbindung trennen"))
            signal(distance, "clicked") { [weak self] in
                guard let self else { return }
                self.seerrAccess = nil
                self.seerrClient = nil
                Cache.seerrWrite(nil)
                gtk_editable_set_text(OpaquePointer(aBox.widget), "")
                gtk_editable_set_text(OpaquePointer(pBox.widget), "")
                self.seerrStateShow(stateBox, translated("Getrennt"))
            }
            append(rail, distance)
        }
        append(block, rail)
    }

    /// **The same header as every other subpage.**
    ///
    /// This used to be a custom three-line one because `subpageHeader` was
    /// private, and it lacked the one thing that matters: the back arrow, making
    /// the page a dead end. The Mac uses `SubpageHeader(title:back:)` here.
    private func seerrHeader() -> Widget! {
        let header = subpageHeader(translated("Seerr"))
        gtk_widget_set_margin_bottom(header, 10)
        return header
    }

    private func seerrStateShow(_ container: PointerBox, _ text: String) {
        gtk_label_set_text(OpaquePointer(container.widget), text)
        gtk_widget_set_visible(container.widget, 1)
    }

    /// **What is shown when connected.** Address, session state, and the way
    /// out.
    ///
    /// "Verbindung trennen", not "Abmelden", worded like the Mac: everything on
    /// the Seerr side stays as it is; only this one connection here is dropped.
    private func seerrConnectedGroup(_ access: SeerrAccess) -> Widget! {
        let g = settingGroup(translated("Verbunden"))
        let word: String
        switch seerrApplies {
        case .valid?:       word = translated("Aktiv")
        case .invalid?:     word = translated("Sitzung abgelaufen")
        case .unreachable?: word = translated("Seerr nicht erreichbar")
        case nil:           word = translated("Wird geprüft …")
        }
        append(g.space, valuesRow(symbol: "network-transmit-receive-symbolic",
                                     title: access.address.absoluteString,
                                     value: word))
        append(g.space, rowsLine())
        append(g.space, valuesRow(symbol: "window-close-symbolic",
                                     title: translated("Verbindung trennen")) { [weak self] in
            guard let self else { return }
            // First the connection's cookie, then the credentials; otherwise the session
            // stays valid and the next sign-in attempt gets no new one
            // (`Seerr.cookiesForget`).
            if let address = self.seerrAccess?.address { Seerr.cookiesForget(for: address) }
            self.seerrAccess = nil
            self.seerrClient = nil
            self.seerrApplies = nil
            Cache.seerrWrite(nil)
            // Otherwise search keeps showing the foreign hits of the last query, which
            // come from a service that is no longer connected.
            self.seerrHitShow([])
            self.subpageOpen(.seerr)
        })

        // **Only the service knows whether the session still holds.** The cookie
        // expires, and credentials that are there but no longer valid are worse than
        // none: search would stay silently empty.
        //
        // It is checked once per visit, and the result rebuilds the page in place,
        // the same way all selection lists work here. A pointer to the value label
        // across a thread boundary would be the alternative and the worse one.
        if let client = seerrClient, seerrApplies == nil {
            Task.detached { [self] in
                let applies = await client.applies()
                onMainThread {
                    guard self.openSubpage == .seerr else { return }
                    self.seerrApplies = applies
                    self.subpageOpen(.seerr)
                }
            }
        }
        return g.outer
    }

    /// Caption above the field, the form of the other settings.
    private func fieldRow(_ title: String, _ inputField: Widget!) -> Widget! {
        let smallStack = stack(GTK_ORIENTATION_VERTICAL, spacing: 6)
        gtk_widget_set_margin_bottom(smallStack, 14)
        let l = label(title, style: "swiftly-zweitzeile")
        gtk_label_set_xalign(OpaquePointer(l), 0)
        append(smallStack, l)
        append(smallStack, inputField)
        return smallStack
    }
}

// MARK: - Search and request

extension App {

    /// Put the Seerr results below the own ones, or hide both.
    /// **Anything already on the server is not shown again.** A title in state
    /// `present` is already in the own results above; the "Anfragen ueber Seerr" row
    /// below would be the same tile twice, and tapping it would ask for
    /// confirmation for something nobody has to request. The Apple builds solve
    /// this with two blocks; here there is only one, so that state is dropped.
    func seerrHitShow(_ hit: [SeerrHit]) {
        guard seerrGrid != nil else { return }
        let foreignOnes = hit.filter { $0.state != .present }
        let visible = !foreignOnes.isEmpty
        gtk_widget_set_visible(seerrHeaderRow, visible ? 1 : 0)
        gtk_widget_set_visible(seerrGrid, visible ? 1 : 0)
        gtk_label_set_text(OpaquePointer(seerrNumber), String(foreignOnes.count))
        // "Nichts gefunden" only applies once Seerr has nothing either.
        seerrHitEmpty = foreignOnes.isEmpty
        if searchEmpty != nil {
            gtk_widget_set_visible(searchEmpty, ownHitEmpty && foreignOnes.isEmpty ? 1 : 0)
        }
        gridEmpty(seerrGrid)
        for t in foreignOnes {
            gtk_flow_box_insert(OpaquePointer(seerrGrid), seerrTile(t), -1)
        }
    }

    /// **A tile like any other, plus the badge.**
    ///
    /// The badge says what already happened to the title: waiting, requested,
    /// partial. Without it the same title gets requested three times with no
    /// visible effect; `Seerrstand` in the package exists for this.
    func seerrTile(_ t: SeerrHit) -> Widget! {
        let button: Widget! = gtk_button_new()
        gtk_widget_add_css_class(button, "swiftly-kachel")
        let block = stack(GTK_ORIENTATION_VERTICAL, spacing: 8)

        let (wrapper, image) = framedImage(width: Theme.tileWidth,
                                           height: Theme.tileHeight, style: "swiftly-plakat")
        if let url = t.poster() {
            imageLoad(image, url: url, key: "seerr-\(t.art)-\(t.id)", immediate: true)
        }
        // **Faded, and that is the whole message.** A poster at full opacity looks
        // like a title the server has (`Sources/macOS/SeerrTileAndPage.swift`).
        // The one cue that shows at a glance that it is not was missing.
        gtk_widget_set_opacity(wrapper, 0.45)
        // **Bottom left, not top right** (`.bottomLeading` with 8 padding), and
        // filled with the state's color, not an outlined pill: `swiftly-marke` was a
        // class missing from the style sheet, so "wartet", "angefragt" and
        // "teilweise" looked identical.
        if let word = seerrBrandName(t.state) {
            let mark = label(word, style: "swiftly-marke")
            gtk_widget_add_css_class(mark, seerrBrandStyle(t.state))
            gtk_widget_set_halign(mark, GTK_ALIGN_START)
            gtk_widget_set_valign(mark, GTK_ALIGN_END)
            gtk_widget_set_margin_bottom(mark, 8)
            gtk_widget_set_margin_start(mark, 8)
            gtk_overlay_add_overlay(OpaquePointer(wrapper), mark)
        }
        append(block, wrapper)

        // 1 point spacing inside, title `tileTitleText` in `schriftLeise`, second
        // line in `schriftSehrLeise`. The title used to be full white and the same
        // size as body text.
        let textBlock = stack(GTK_ORIENTATION_VERTICAL, spacing: 1)
        let title = label(t.title, style: "swiftly-kacheltitel")
        gtk_widget_add_css_class(title, "dim-label")
        gtk_label_set_xalign(OpaquePointer(title), 0)
        gtk_label_set_ellipsize(OpaquePointer(title), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(OpaquePointer(title), 1)
        append(textBlock, title)

        // "2019 · Serie", not just the year.
        let art = t.isSeries ? translated("Serie") : translated("Film")
        let bottom = label(t.year.map { "\($0) · \(art)" } ?? art,
                                 style: "swiftly-zweitzeile")
        gtk_widget_add_css_class(bottom, "swiftly-leise")
        gtk_label_set_xalign(OpaquePointer(bottom), 0)
        append(textBlock, bottom)
        append(block, textBlock)

        gtk_button_set_child(asButton(button), block)
        // One statement per tile: title, year and kind, and the request state; the
        // badge is part of the image and would otherwise be missed.
        caption(button, ([t.title, t.year.map { "\($0) · \(art)" } ?? art]
                            + [seerrBrandName(t.state)].compactMap { $0 })
                                .joined(separator: ", "))
        // **Page first, then the request.** A tap used to trigger the confirmation
        // right away, without showing what it is about, how long it is or which
        // seasons exist.
        signal(button, "clicked") { [weak self] in self?.seerrPageOpen(t) }
        return button
    }

    /// Same table as `Seerrstand.shortWord` on the Apple builds, **word for word,
    /// even where it feels wrong.**
    ///
    /// `loads` means "angefragt", not "laedt". In Seerr that state means the
    /// request went through and is with the downloader; whether anything is
    /// actually transferring is unknown. Seerr's own UI also calls it
    /// "Requested". The Mac had this wrong once and fixed it; reinventing it here
    /// would repeat the bug.
    /// The badge color as a style class, same values as `Seerrstand.farbe` on
    /// Apple (`Sources/Shared/SeerrMark.swift`).
    private func seerrBrandStyle(_ state: SeerrState) -> String {
        switch state {
        case .waitsSharing: return "swiftly-marke-wartet"
        case .loads:             return "swiftly-marke-laedt"
        default:                 return "swiftly-marke-akzent"
        }
    }

    private func seerrBrandName(_ state: SeerrState) -> String? {
        switch state {
        case .opened, .deleted:    return nil
        case .waitsSharing:    return translated("wartet")
        case .loads:                return translated("angefragt")
        case .partWayPresent:          return translated("teilweise")
        case .present:                   return nil
        }
    }}
