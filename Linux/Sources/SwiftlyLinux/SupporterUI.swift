import CGtk
import Foundation
import JellyfinKit

/// **The supporter screens as on the Mac**: the cards at the top of the profile, the heart
/// in the bar and under the version, the looks panel, the purchase page and the thank-you.
///
/// Sizes, radii and colours are those of `Sources/Shared/SupportProfileParts.swift`,
/// `LooksPanel.swift`, `SupportGrowSheet.swift` and `SupportThanksView.swift`; the comments
/// there carry the reasons. The rules (who sees which card, what may be worn) come from the
/// package as everywhere.

// MARK: - Small pieces

extension App {

    /// A label with one of the size classes below, left aligned.
    func supportText(_ text: String, _ style: String, wrap: Bool = false, centred: Bool = false) -> Widget! {
        let l = label(text, style: style, wrap: wrap)
        if centred {
            gtk_label_set_justify(OpaquePointer(l), GTK_JUSTIFY_CENTER)
            gtk_label_set_xalign(OpaquePointer(l), 0.5)
        } else {
            gtk_label_set_justify(OpaquePointer(l), GTK_JUSTIFY_LEFT)
            gtk_label_set_xalign(OpaquePointer(l), 0)
        }
        return l
    }

    /// **The glass pill "Look ausprobieren ›"** of the teaser card and the purchase page.
    func glassPill(_ text: String, small: Bool = false) -> Widget! {
        let pill = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_widget_add_css_class(pill, "swiftly-glaspille")
        if small { gtk_widget_add_css_class(pill, "swiftly-glaspille-klein") }
        append(pill, label(text, style: "swiftly-glaspille-text"))
        append(pill, symbolPaint(.chevron, size: small ? 9 : 10, style: "swiftly-schrift"))
        gtk_widget_set_halign(pill, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(pill, GTK_ALIGN_CENTER)
        return pill
    }

    /// **The close button of a sheet**: a cross in a 30 circle, 44 to hit. `dark` is the
    /// purchase page's (white on black .4, over the phones), else the panel's (quiet on raised).
    func sheetCloseButton(dark: Bool) -> Widget! {
        let button: Widget! = gtk_button_new()
        gtk_widget_add_css_class(button, "swiftly-blattzu")
        let circle = stack(GTK_ORIENTATION_VERTICAL)
        gtk_widget_add_css_class(circle, dark ? "swiftly-blattzu-dunkel" : "swiftly-blattzu-kreis")
        gtk_widget_set_size_request(circle, 30, 30)
        gtk_widget_set_halign(circle, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(circle, GTK_ALIGN_CENTER)
        let cross = symbolPaint(.cross, size: dark ? 10 : 11, box: 30, style: dark ? "swiftly-schrift" : "swiftly-leisefarbe")
        append(circle, cross)
        gtk_button_set_child(asButton(button), circle)
        gtk_widget_set_size_request(button, 44, 44)
        gtk_widget_set_halign(button, GTK_ALIGN_END)
        gtk_widget_set_valign(button, GTK_ALIGN_START)
        caption(button, translated("Schließen"))
        signal(button, "clicked") { [weak self] in self?.supportSheetClose() }
        return button
    }

    /// **The frame of a sheet**: the content scrolls when the window is lower than the sheet,
    /// the close button stays in the corner.
    func sheetFrame(_ content: Widget!, close: Widget?, height: Int32 = 660) -> Widget! {
        let frame: Widget! = gtk_overlay_new()
        let scroller: Widget! = gtk_scrolled_window_new()
        gtk_scrolled_window_set_policy(OpaquePointer(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_propagate_natural_height(OpaquePointer(scroller), 1)
        gtk_scrolled_window_set_max_content_height(OpaquePointer(scroller), height)
        gtk_scrolled_window_set_child(OpaquePointer(scroller), content)
        gtk_overlay_set_child(OpaquePointer(frame), scroller)
        if let close { gtk_overlay_add_overlay(OpaquePointer(frame), close) }
        return frame
    }

    static let supporterDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()
}

// MARK: - The profile

extension App {

    /// **Looks at the top of the profile, by state** (`LookProfileEntry`): the current look
    /// for whoever has one to choose, else the teaser; supporters also get the status card.
    func looksProfileBlock() -> Widget? {
        let entry = LookProfileEntry.at(supporterFeatures: true, isSupporter: isSupporter,
                                        ownsLook: looks.tryOn.ownsLook)
        guard entry != .none || isSupporter else { return nil }
        let block = stack(GTK_ORIENTATION_VERTICAL, spacing: 16)
        switch entry {
        case .current: append(block, currentLookCard())
        case .teaser: append(block, supportLooksCard())
        case .none: break
        }
        if isSupporter { append(block, supportStatusCard()) }
        return block
    }

    /// **`CurrentLookCard`**: the icon, "Dein Look" over the name, "Ändern" in the accent.
    func currentLookCard() -> Widget! {
        let look = looks.saved.look
        let row = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 14)
        append(row, lookTile(look, size: 44))
        let column = stack(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_widget_set_valign(column, GTK_ALIGN_CENTER)
        gtk_widget_set_hexpand(column, 1)
        append(column, supportText(translated("Dein Look"), "swiftly-s13-leise"))
        append(column, supportText(look.shownName, "swiftly-s17-fett"))
        append(row, column)
        let change = label(translated("Ändern"), style: "swiftly-s15-fett")
        gtk_widget_add_css_class(change, "swiftly-akzentschrift")
        gtk_widget_set_valign(change, GTK_ALIGN_CENTER)
        append(row, change)

        let button: Widget! = gtk_button_new()
        gtk_widget_add_css_class(button, "swiftly-lookkarte")
        gtk_button_set_child(asButton(button), row)
        caption(button, String(format: translated("Dein Look: %@"), look.shownName))
        signal(button, "clicked") { [weak self] in self?.lookOpenOnHome() }
        return button
    }

    /// **`SupportLooksCard`**: the fan of icons, the line, the pill. The whole card opens
    /// the looks.
    func supportLooksCard() -> Widget! {
        let column = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        let fan = iconFanPaint()
        gtk_widget_set_margin_top(fan, 0)
        append(column, fan)
        let text = stack(GTK_ORIENTATION_VERTICAL, spacing: 4)
        gtk_widget_set_margin_start(text, 18)
        gtk_widget_set_margin_end(text, 18)
        gtk_widget_set_margin_top(text, 10)
        gtk_widget_set_margin_bottom(text, 18)
        append(text, supportText(translated("Wähl deinen Look"), "swiftly-s20-fett", centred: true))
        append(text, supportText(translated("Looks für alle, die Swiftly am Laufen halten."),
                                 "swiftly-s13-leise", wrap: true, centred: true))
        let pill = glassPill(translated("Look ausprobieren"))
        gtk_widget_set_margin_top(pill, 10)
        append(text, pill)
        append(column, text)

        let button: Widget! = gtk_button_new()
        gtk_widget_add_css_class(button, "swiftly-lookteaser")
        gtk_button_set_child(asButton(button), column)
        caption(button, translated("Wähl deinen Look"))
        signal(button, "clicked") { [weak self] in self?.lookOpenOnHome() }
        return button
    }

    /// **`SupportStatusCard`**: the heart in its glow, "Unterstützer für immer" and since
    /// when. Keys: monthly ones show their end day, lifetime ones never run out.
    func supportStatusCard() -> Widget! {
        let card = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 14)
        gtk_widget_add_css_class(card, "swiftly-statuskarte")
        let circle = stack(GTK_ORIENTATION_VERTICAL)
        gtk_widget_add_css_class(circle, "swiftly-statusherz")
        gtk_widget_set_size_request(circle, 44, 44)
        gtk_widget_set_valign(circle, GTK_ALIGN_CENTER)
        append(circle, symbolPaint(.heart, size: 18, box: 44, style: "swiftly-akzentfarbe"))
        append(card, circle)
        let column = stack(GTK_ORIENTATION_VERTICAL, spacing: 3)
        gtk_widget_set_valign(column, GTK_ALIGN_CENTER)
        gtk_widget_set_hexpand(column, 1)
        var since: Date?
        if case let .supporter(_, date) = supportStore.status { since = date }
        let until = supportKeeper.license?.expiresAt
        let monthly = supportStore.plan == .monthly && until != nil
        append(column, supportText(translated(monthly ? "Unterstützer im Monatsabo" : "Unterstützer für immer"),
                                   "swiftly-s17-fett"))
        let detail: String
        if let since, monthly, let until {
            detail = String(format: translated("Seit %@. Gilt bis %@ und verlängert sich von selbst, solange das Abo läuft."),
                            Self.supporterDate.string(from: since), Self.supporterDate.string(from: until))
        } else if let since {
            detail = String(format: translated("Seit %@. Nichts verlängert sich, deine Extras bleiben."),
                            Self.supporterDate.string(from: since))
        } else {
            detail = translated(SupportCopy.supporterBadge.key)
        }
        append(column, supportText(detail, "swiftly-s13-leise", wrap: true))
        append(card, column)
        return card
    }
}

// MARK: - Hearts

extension App {

    /// **The heart in the bar**: `heart.fill` 17, quiet, bright on hover; in the accent for
    /// supporters. 44 to hit.
    func supportHeartButton() -> Widget! {
        let button: Widget! = gtk_button_new()
        gtk_widget_add_css_class(button, "swiftly-herz")
        let heart = symbolPaint(.heart, size: 17, box: 24, style: isSupporter ? "swiftly-akzentfarbe" : "swiftly-herzfarbe")
        gtk_button_set_child(asButton(button), heart)
        gtk_widget_set_size_request(button, 44, 44)
        caption(button, translated(SupportCopy.supportSwiftly.key))
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        signal(button, "clicked") { [weak self] in self?.supportOpen() }
        return button
    }

    /// **The version mark**: the version, and for supporters an accent heart with
    /// "Unterstützer".
    func versionMark(_ text: String) -> Widget! {
        let line = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        let version = label(text, style: "swiftly-s12-sehrleise")
        gtk_label_set_xalign(OpaquePointer(version), 0)
        append(line, version)
        if isSupporter {
            let badge = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 4)
            append(badge, symbolPaint(.heart, size: 11, box: 14, style: "swiftly-akzentfarbe"))
            append(badge, label(translated(SupportCopy.supporterBadge.key), style: "swiftly-s12-leise"))
            append(line, badge)
        }
        return line
    }
}

// MARK: - The purchase page

extension App {

    /// **`SupportGrowSheet` down to its button**: the phones, the words, the two plans, the
    /// tips and the button that names the choice. `open` gets the chosen id
    /// (`monthly`, `lifetime`, `tip-199` …); the checkout itself is on the website.
    func supportGrowOffer(open: @escaping (String) -> Void) -> Widget! {
        let page = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)

        // The phones and the pill over their lower edge.
        let hero: Widget! = gtk_overlay_new()
        let phones = looksHeroPaint(width: 480)
        gtk_widget_set_margin_top(phones, 36)
        gtk_overlay_set_child(OpaquePointer(hero), phones)
        let tryButton: Widget! = gtk_button_new()
        gtk_widget_add_css_class(tryButton, "swiftly-pillenknopf")
        gtk_button_set_child(asButton(tryButton), glassPill(translated("Look ausprobieren"), small: true))
        gtk_widget_set_halign(tryButton, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(tryButton, GTK_ALIGN_END)
        gtk_widget_set_margin_bottom(tryButton, 7)
        signal(tryButton, "clicked") { [weak self] in
            self?.supportSheetClose()
            self?.lookOpenOnHome()
        }
        gtk_overlay_add_overlay(OpaquePointer(hero), tryButton)
        append(page, hero)

        // The words.
        let words = stack(GTK_ORIENTATION_VERTICAL, spacing: 8)
        gtk_widget_set_margin_top(words, 22)
        gtk_widget_set_margin_start(words, 20)
        gtk_widget_set_margin_end(words, 20)
        let titleRow = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_widget_set_halign(titleRow, GTK_ALIGN_CENTER)
        append(titleRow, label(translated("Hilf Swiftly zu wachsen"), style: "swiftly-s28-titel"))
        let sprout = label("🌱", style: "swiftly-s17")
        gtk_widget_set_valign(sprout, GTK_ALIGN_CENTER)
        append(titleRow, sprout)
        append(words, titleRow)
        append(words, supportText(translated("Dein Beitrag hält Swiftly am Laufen."), "swiftly-s17-hell",
                                  wrap: true, centred: true))
        append(words, supportText(translated("Open Source, keine Werbung, alles zum Schauen bleibt kostenlos."),
                                  "swiftly-s13-sehrleise", wrap: true, centred: true))
        append(page, words)

        // The choice. Nothing is preselected (as on Apple); the button says what it does.
        var chosen: String?
        var marks = [(id: String, button: Widget, indicator: Widget?)]()
        let action = primaryWhiteButton(translated("Wähl eine Option"))
        gtk_widget_set_sensitive(action, 0)
        let prices: [String: String] = ["monthly": "1,99 €", "lifetime": "19,99 €",
                                        "tip-199": "1,99 €", "tip-499": "4,99 €", "tip-999": "9,99 €"]
        let choose: (String) -> Void = { id in
            chosen = id
            for mark in marks {
                if mark.id == id { gtk_widget_add_css_class(mark.button, "swiftly-gewaehlt") }
                else { gtk_widget_remove_css_class(mark.button, "swiftly-gewaehlt") }
                if let indicator = mark.indicator { gtk_widget_queue_draw(indicator) }
            }
            let price = translated(prices[id] ?? "")
            let text: String
            switch id {
            case "monthly": text = String(format: translated("Für %@ im Monat unterstützen"), price)
            case "lifetime": text = String(format: translated(SupportCopy.supportWithPrice.key), price)
            default: text = String(format: translated("Mit %@ Danke sagen"), price)
            }
            if let l = gtk_button_get_child(asButton(action)) { gtk_label_set_text(OpaquePointer(l), text) }
            gtk_widget_set_sensitive(action, 1)
        }

        let plans = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        gtk_box_set_homogeneous(asBox(plans), 1)
        gtk_widget_set_margin_top(plans, 18)
        gtk_widget_set_margin_start(plans, 16)
        gtk_widget_set_margin_end(plans, 16)
        let planList: [(id: String, title: String, price: String, detail: String, badge: String, light: Bool)] = [
            ("monthly", translated("Monatlich"), translated("1,99 €"),
             translated("im Monat · jederzeit kündbar"), translated("Beliebt"), true),
            ("lifetime", translated("Für immer"), translated("19,99 €"),
             translated("einmal zahlen · wie 10 Monate"), translated("Guter Deal"), false),
        ]
        for plan in planList {
            let tile: Widget! = gtk_button_new()
            gtk_widget_add_css_class(tile, "swiftly-plankachel")
            let inside: Widget! = gtk_overlay_new()
            let column = stack(GTK_ORIENTATION_VERTICAL, spacing: 2)
            let title = supportText(plan.title, "swiftly-s13-leise")
            gtk_widget_set_margin_top(title, 6)
            append(column, title)
            let price = supportText(plan.price, "swiftly-s22-fett")
            gtk_widget_set_margin_top(price, 4)
            append(column, price)
            append(column, supportText(plan.detail, "swiftly-s12-sehrleise", wrap: true))
            gtk_widget_set_margin_end(column, 22)
            gtk_overlay_set_child(OpaquePointer(inside), column)
            let id = plan.id
            var isChosen: () -> Bool = { false }
            let indicator = paint(width: 20, height: 20) { _, cr, w, h in
                if isChosen() {
                    let a = Theme.accentRGB
                    cairo_set_source_rgb(cr, a.0, a.1, a.2)
                    cairo_arc(cr, w / 2, h / 2, w / 2, 0, 2 * .pi)
                    cairo_fill(cr)
                    let on = LookColor(UInt32(Theme.onAccent.dropFirst(), radix: 16) ?? 0)
                    LookArt.set(cr, on)
                    LookArt.check(cr, cx: w / 2, cy: h / 2, size: 9)
                } else {
                    cairo_set_source_rgba(cr, 1, 1, 1, 0.25)
                    cairo_set_line_width(cr, 1.5)
                    cairo_arc(cr, w / 2, h / 2, w / 2 - 0.75, 0, 2 * .pi)
                    cairo_stroke(cr)
                }
            }
            isChosen = { chosen == id }
            gtk_widget_set_halign(indicator, GTK_ALIGN_END)
            gtk_widget_set_valign(indicator, GTK_ALIGN_START)
            gtk_overlay_add_overlay(OpaquePointer(inside), indicator)
            gtk_button_set_child(asButton(tile), inside)
            gtk_widget_set_margin_top(tile, 9)
            signal(tile, "clicked") { choose(id) }
            marks.append((id, tile, indicator))

            // The badge sits on the upper edge, so the tile and the badge share an overlay.
            let holder: Widget! = gtk_overlay_new()
            gtk_overlay_set_child(OpaquePointer(holder), tile)
            let badge = label(plan.badge.uppercased(), style: "swiftly-plakette")
            if !plan.light { gtk_widget_add_css_class(badge, "swiftly-plakette-dunkel") }
            gtk_widget_set_halign(badge, GTK_ALIGN_START)
            gtk_widget_set_valign(badge, GTK_ALIGN_START)
            gtk_widget_set_margin_start(badge, 14)
            gtk_widget_set_can_target(badge, 0)
            gtk_overlay_add_overlay(OpaquePointer(holder), badge)
            append(plans, holder)
        }
        append(page, plans)

        let tips = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_widget_set_margin_top(tips, 12)
        gtk_widget_set_margin_start(tips, 16)
        gtk_widget_set_margin_end(tips, 16)
        let thanks = label(translated("Einfach Danke ☕"), style: "swiftly-s12-sehrleise")
        gtk_widget_set_margin_end(thanks, 4)
        append(tips, thanks)
        let chips = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_box_set_homogeneous(asBox(chips), 1)
        gtk_widget_set_hexpand(chips, 1)
        for amount in ["1,99 €", "4,99 €", "9,99 €"] {
            let chip = gtk_button_new_with_label(translated(amount))!
            gtk_widget_add_css_class(chip, "swiftly-trinkgeld")
            let id = "tip-" + amount.prefix(4).replacingOccurrences(of: ",", with: "")
            signal(chip, "clicked") { choose(id) }
            marks.append((id, chip, nil))
            append(chips, chip)
        }
        append(tips, chips)
        append(page, tips)

        gtk_widget_set_margin_top(action, 12)
        gtk_widget_set_margin_bottom(action, 10)
        gtk_widget_set_margin_start(action, 16)
        gtk_widget_set_margin_end(action, 16)
        signal(action, "clicked") { if let chosen { open(chosen) } }
        append(page, action)
        return page
    }

    /// **The white button of the sheets** (`GiftButton`, the purchase button): full width,
    /// white, black text; raised and quiet while it cannot be pressed.
    func primaryWhiteButton(_ text: String, large: Bool = false) -> Widget! {
        let button = gtk_button_new_with_label(text)!
        gtk_widget_add_css_class(button, "swiftly-weissknopf")
        if large { gtk_widget_add_css_class(button, "swiftly-weissknopf-gross") }
        gtk_widget_set_hexpand(button, 1)
        return button
    }
}

// MARK: - The thank-you

extension App {

    /// **`SupportThanksView`**: the look's icon floating, "Danke 🫶", what changed, and the
    /// way to the home page.
    func supportThanksPage() -> Widget! {
        let page = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_size_request(page, -1, 660)
        let name = LookArt.iconName(looks.selection.look)
        let icon = paint(width: 140, height: 140, animated: true) { _, cr, w, _ in
            let t = LookArt.moves ? LookArt.now / 1.7 : 0
            let phase = t - floor(t / 2) * 2
            let half = phase < 1 ? phase : 2 - phase
            let lift = -4 * (0.5 - cos(half * .pi) / 2)
            let x = (w - 104) / 2
            let y = 8 + lift
            LookArt.shadow(cr, x: x, y: y, w: 104, h: 104, corner: 23.4, opacity: 0.35, radius: 18, drop: 10)
            LookArt.tile(cr, name, x: x, y: y, size: 104, corner: 23.4)
        }
        gtk_widget_set_margin_top(icon, 92)
        append(page, icon)

        let title = supportText(translated("Danke 🫶"), "swiftly-s30-titel", centred: true)
        gtk_widget_set_margin_top(title, 18)
        gtk_widget_set_margin_bottom(title, 8)
        append(page, title)
        let words = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_margin_start(words, 26)
        gtk_widget_set_margin_end(words, 26)
        append(words, supportText(translated("Du hast Swiftly gerade beim Weitermachen geholfen. Die Looks gehören jetzt dir. Schau dich um."),
                                  "swiftly-s15-leise", wrap: true, centred: true))
        let hint = supportText(translated("Looks kannst du jederzeit im Profil wechseln."),
                               "swiftly-s13-sehrleise", wrap: true, centred: true)
        gtk_widget_set_margin_top(hint, 18)
        append(words, hint)
        append(page, words)

        let space = stack(GTK_ORIENTATION_VERTICAL)
        gtk_widget_set_vexpand(space, 1)
        append(page, space)

        let buttons = stack(GTK_ORIENTATION_VERTICAL, spacing: 8)
        gtk_widget_set_margin_start(buttons, 16)
        gtk_widget_set_margin_end(buttons, 16)
        gtk_widget_set_margin_top(buttons, 12)
        gtk_widget_set_margin_bottom(buttons, 16)
        let home = primaryWhiteButton(translated("Zeig mir meine Startseite"))
        signal(home, "clicked") { [weak self] in
            guard let self else { return }
            self.supportSheetClose()
            if self.section != .start || self.openSubpage != nil { self.show(.start) }
        }
        append(buttons, home)
        let done = gtk_button_new_with_label(translated(SupportCopy.done.key))!
        gtk_widget_add_css_class(done, "swiftly-flaechenknopf")
        signal(done, "clicked") { [weak self] in self?.supportSheetClose() }
        append(buttons, done)
        append(page, buttons)
        return page
    }
}
