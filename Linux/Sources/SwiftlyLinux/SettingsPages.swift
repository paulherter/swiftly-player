import CGtk
import Foundation
import JellyfinKit

/// Profile, Quick Connect, playback, settings.
///
/// Structure, order and texts follow `Sources/macOS/ProfileView.swift`,
/// `SettingsView.swift` and `PlaybackSettingsView.swift`. Pages are kept
/// narrow in the window (560); stretched to full width, icon and value would be
/// half a meter apart.
///
/// **The number of settings pages may differ per platform:** iPhone, iPad and Mac
/// keep profile, settings and playback separate, the TV has one page. Linux follows
/// the Mac.
extension App {

    enum Subpage: Hashable { case subtitleLook, profile, quickConnect, playback, seerr, settings, accountAdd, serverOnboarding, kindPicker, plexSignIn, presentation, genreSelection, librarySelection, licenses, licenseText(String) }

    /// **Settings cross-fade, they do not slide.**
    ///
    /// The page slide belongs to browsing titles and says "you went one level deeper".
    /// Profile, playback and settings sit side by side, not on top of each other;
    /// sliding them would claim a depth that does not exist. Hence ``Schub/ohne`` is the
    /// default here.
    ///
    /// **Rebuilding the same page happens in place.** Choosing a language triggers a
    /// rebuild; a new page should not slide in when only one row changed.
    /// **Slide in from the right, no hard cut.** On the Mac every subpage is pushed onto
    /// the page stack through `Navigator.openIt`, where going deeper slides in from the
    /// right and going back slides out to the right (`Sources/macOS/Navigator.swift`).
    /// Code that *restores* a subpage after an account switch passes `.without`
    /// explicitly: the page has been shown before.
    func subpageOpen(_ was: Subpage, push: Push = .deeper) {
        // **The profile is back immediately in the middle of an account switch**
        // (iOS `complete`): whatever is pending happens now.
        if was == .profile { accountTransitionComplete() }
        // An open subpage removes the highlight from the bar; otherwise "Start" would
        // light up while the profile is shown.
        defer { sectionRowsDraw() }
        let anPlace = (openSubpage == was)
        let disc: Widget! = anPlace ? detailWrapper : nextDisc()
        if anPlace { wipe(disc) }
        openSubpage = was

        // **The subtitle page builds its own scroller**: the picture stands beside the
        // rows and does not scroll with them (see `SubtitlePage.swift`).
        if was == .subtitleLook {
            subtitleBuild(into: disc)
            if !anPlace { shove(toward: disc, bearing: push) }
            return
        }

        let block = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        // **Subpages are not all the same width.** Settings have two columns side by side,
        // the rest reads like text. One shared 560 made a 1400 pt window look like a phone
        // view in the middle.
        //
        // **`size_request` is a minimum, not a maximum**, and GTK has no `max-width`. The
        // Mac caps with `frame(maxWidth:)` and lets columns shrink; using the same number
        // as a request here would blow up the window and push the right column outside.
        //
        // So the cap is applied from below via ``cap(_:on:)``: the scroller's
        // adjustment knows the visible width and reports every change. Without it the three
        // pages would grow with the window while the Mac stops at 1366.
        // **There are three two-column pages, not one.** Playback and appearance also build
        // with ``zweispalter``, so they get `formularbreite`, not `readWidth` (700, which
        // gives two columns of 326 pt); the Mac gives them `Theme.settingWidth`
        // (`PlaybackSettingsView.swift`, `AppearanceView.swift`).
        //
        // **Form pages are narrower than 700, not wider.** The Mac caps server setup, add
        // account and Quick Connect at 460 (`ServerOnboardingView.swift`, `ProfileView.swift`).
        let twoColumned: Set<Subpage> = [.settings, .playback, .presentation]
        // **Profile and Seerr belong here too.** `readWidth` is the width for running
        // text.
        let formSheet: Set<Subpage> = [.serverOnboarding, .kindPicker, .plexSignIn, .accountAdd, .quickConnect,
                                          .seerr]
        if twoColumned.contains(was) || was == .profile {
            gtk_widget_set_halign(block, GTK_ALIGN_FILL)
            gtk_widget_set_hexpand(block, 1)
            gtk_widget_set_margin_start(block, Int32(Theme.edgeSpacing))
            gtk_widget_set_margin_end(block, Int32(Theme.edgeSpacing))
        } else if formSheet.contains(was) {
            gtk_widget_set_size_request(block, Int32(Theme.formWidth), -1)
            gtk_widget_set_halign(block, GTK_ALIGN_START)
        } else {
            // **Left, not centered.** The Mac uses `frame(maxWidth: readWidth, alignment:
            // .leading)` and then `frame(maxWidth: .infinity, alignment: .leading)`: the block
            // is at most 700 wide and sits at the left edge. `CENTER` would make the profile
            // page, the first one opened, the only one in the middle while the subpages below
            // are left-aligned.
            gtk_widget_set_size_request(block, Int32(Theme.readWidth), -1)
            gtk_widget_set_halign(block, GTK_ALIGN_START)
        }
        gtk_widget_set_margin_top(block, Int32(Theme.contentTop))
        gtk_widget_set_margin_bottom(block, 40)
        gtk_widget_set_margin_start(block, Int32(Theme.edgeSpacing))
        gtk_widget_set_margin_end(block, Int32(Theme.edgeSpacing))

        switch was {
        case .profile:         profileBuild(block)
        case .quickConnect:   quickConnectBuild(block)
        case .playback:     playbackBuild(block)
        case .seerr:          seerrPageBuild(block)
        case .settings:  settingsBuild(block)
        case .accountAdd: accountAddBuild(block)
        case .serverOnboarding:   serverOnboardingBuild(block)
        case .kindPicker:         kindPickerSubpageBuild(block)
        case .plexSignIn:         plexSignInBuild(block)
        case .presentation:      presentationBuild(block)
        case .genreSelection:        genreSelectionBuild(block)
        case .librarySelection:  librarySelectionBuild(block)
        case .subtitleLook:     break
        case .licenses:         licensesBuild(block)
        case .licenseText(let id): licenseTextBuild(block, id: id)
        }

        let scroller = pagesScroller()
        gtk_scrolled_window_set_child(OpaquePointer(scroller), lookGlowWrapped(block))
        // Settings: **each column ends at `formWidth`** (`SettingsView.swift`),
        // i.e. two columns plus 48 spacing.
        // 1.1: profile and "Allgemein" are two columns of 470 with a 24 gap, 964 together
        // (Mac `ProfileView`, `SettingsView`: `frame(maxWidth: 964)`).
        if was == .settings || was == .profile {
            cap(block, in: scroller, on: 964)
        } else if twoColumned.contains(was) {
            cap(block, in: scroller, on: Theme.settingWidth)
        }
        append(disc, scroller)
        if !anPlace { shove(toward: disc, bearing: push) }
    }

    /// **A row that does nothing is worse than none.** The Mac starts the check, shows
    /// "Moment …" and then the result next to it; a button without a callback only
    /// pretends to work.
    private func connectionCheck() {
        guard let client else { return }
        checkResult = translated("Moment…")
        subpageOpen(.settings, push: .without)
        Task.detached { [self] in
            let ok = (try? await client.publicSystemInfo()) != nil
            onMainThread {
                self.checkResult = ok ? translated("Erreichbar") : translated("Nicht erreichbar")
                if self.openSubpage == .settings {
                    self.subpageOpen(.settings, push: .without)
                }
            }
        }
    }

    /// Back from a subpage: first to the profile, from there to the section.
    ///
    /// **Out to the right, in both steps.** This is the second half of the rule in
    /// `Navigator.swift`; mixing `.without` for one path and the default for the other
    /// made the playback page slide in from the left when going back, as if going
    /// deeper.
    func subpageBack() {
        if openSubpage == .profile {
            openSubpage = nil
            sectionShow(section.identifier, push: .back)
        } else if case .licenseText = openSubpage {
            subpageOpen(.licenses, push: .back)
        } else if openSubpage == .subtitleLook {
            subpageOpen(.playback, push: .back)
        } else if openSubpage == .plexSignIn {
            plexSubpage?.stop()
            subpageOpen(.kindPicker, push: .back)
        } else if openSubpage == .serverOnboarding, serverOnboardingFromPicker {
            subpageOpen(.kindPicker, push: .back)
        } else {
            subpageOpen(.profile, push: .back)
        }
    }

    // MARK: Profile

    private func profileBuild(_ block: Widget!) {
        // **With title.** It carries the header like every other subpage
        // (`ProfileView.swift`), flush with the cards.
        let title = subpageHeader(translated("Profil"))
        gtk_widget_set_margin_bottom(title, 18)
        append(block, title)

        // **1.1, two columns like the Mac** (`ProfileView`): the title, then two columns with
        // a 24 gap. Left: account cards, look line, support line, the three categories.
        // Right: server group, then the links. Cap 964 in `subpageOpen`.
        let (left, right) = twoColumn(in: block, gap: 24)

        append(left, accountsCards())

        // **The look line replaces the "Wähl deinen Look" banner** (Mac `LookLineCard`):
        // palette, the current look's name, "Dein aktueller Look", a chevron.
        let lookLine = lineCard(symbol: "applications-graphics-symbolic",
                                title: looks.saved.look.shownName,
                                under: translated("Dein aktueller Look"),
                                caption: String(format: translated("Dein Look: %@"), looks.saved.look.shownName)) { [weak self] in
            self?.lookOpenOnHome()
        }
        gtk_widget_set_margin_top(lookLine, 18)
        append(left, lookLine)

        // Support: the thank-you card for supporters, else the line "Swiftly unterstützen".
        let supportLine: Widget!
        if isSupporter {
            supportLine = supportStatusCard()
        } else {
            supportLine = lineCard(symbol: nil, title: translated(SupportCopy.supportSwiftly.key),
                                   under: translated(SupportCopy.sayThanks.key)) { [weak self] in
                self?.supportOpen()
            }
        }
        gtk_widget_set_margin_top(supportLine, 16)
        append(left, supportLine)

        // The categories live here, as on iPhone, iPad and Mac.
        let g2 = rowsGroup()
        append(g2.space, valuesRow(symbol: "media-playback-start-symbolic",
                                      title: translated("Wiedergabe"),
                                      under: translated("Qualität, Sprache, Player"),
                                      arrow: true) { [weak self] in
            self?.subpageOpen(.playback)
        })
        append(g2.space, rowsLine())
        append(g2.space, valuesRow(symbol: "view-app-grid-symbolic",
                                      title: translated("Darstellung"),
                                      under: translated("Startseite, Reihen, Genres"),
                                      arrow: true) { [weak self] in
            self?.subpageOpen(.presentation)
        })
        append(g2.space, rowsLine())
        append(g2.space, valuesRow(symbol: "emblem-system-symbolic",
                                      title: translated("Allgemein"),
                                      under: translated("Downloads, Server, Sync"),
                                      arrow: true) { [weak self] in
            self?.subpageOpen(.settings)
        })
        gtk_widget_set_margin_top(g2.outer, 18)
        append(left, g2.outer)

        let g3 = rowsGroup()
        // **"Add another account" is not here.** The plus in the account card does the
        // same, right where the accounts are.
        //
        // **"Add server" is here**, and that is different: a second Jellyfin with its own
        // accounts, not a second account on the same one.
        append(g3.space, valuesRow(symbol: "network-server-symbolic",
                                      title: translated("Server hinzufügen"),
                                      under: translated("Jellyfin, Emby oder Plex, auch gemischt"),
                                      arrow: true) { [weak self] in
            self?.subpageOpen(.kindPicker)
        })
        // Quick Connect is Jellyfin's; the other kinds have no counterpart (Mac `can(.quickConnect)`).
        if bundle?.activeOne.kind == .jellyfin {
            append(g3.space, rowsLine())
            append(g3.space, valuesRow(symbol: "dialog-password-symbolic", title: translated("Quick Connect"),
                                          under: translated("Code vom Fernseher eingeben"),
                                          accent: true, arrow: true) { [weak self] in
                self?.subpageOpen(.quickConnect)
            })
        }
        append(g3.space, rowsLine())
        append(g3.space, valuesRow(symbol: "application-exit-symbolic",
                                      title: translated("Abmelden")) { [weak self] in
            self?.signOff()
        })
        append(right, g3.outer)

        // **Discord, report a bug, log, licenses** under the server group. **No "rate":**
        // there is no store where a rating could land (Mac: App Store link), left out on
        // purpose. The URLs live in the package.
        let g4 = rowsGroup()
        append(g4.space, valuesRow(symbol: "user-available-symbolic",
                                      title: translated("Discord beitreten"),
                                      external: true) {
            browser(Community.discord)
        })
        append(g4.space, rowsLine())
        append(g4.space, valuesRow(symbol: "dialog-warning-symbolic",
                                      title: translated("Fehler melden"),
                                      external: true) {
            #if os(Windows)
            let system = "Windows"
            #else
            let system = "Linux"
            #endif
            browser(Community.errorReport(version: "\(Version.full) · libVLC \(VLCVersion.text)",
                                                platform: system))
        })
        append(g4.space, rowsLine())
        // Next to "Report a bug" because it belongs with it: someone reporting a bug in
        // Discord attaches this.
        append(g4.space, valuesRow(symbol: "text-x-generic-symbolic",
                                      title: translated("Protokoll teilen")) {
            guard let file = LogFile.write() else { return }
            fileManagerShow(file)
        })
        // **Required, not decoration:** libVLC is LGPL, which requires the license text,
        // authors and source inside the app itself.
        append(g4.space, rowsLine())
        append(g4.space, valuesRow(symbol: "text-x-generic-symbolic",
                                      title: translated("Open-Source-Lizenzen"),
                                      arrow: true) { [weak self] in
            self?.subpageOpen(.licenses)
        })
        #if os(Windows)
        // **Windows only.** On Linux the update comes from the package source set up by
        // `swiftly-install.sh`; a separate path would bypass the system package
        // manager.
        append(g4.space, rowsLine())
        updateSpace = stack(GTK_ORIENTATION_VERTICAL)
        updateRowFill()
        append(g4.space, updateSpace)
        #endif
        gtk_widget_set_margin_top(g4.outer, 18)
        append(right, g4.outer)

        append(block, versionLine(Version.full))
    }

    /// **The line card of the profile** (Mac `LookLineCard`, `SupportLineCard`): the icon in a
    /// 26 column, title 17 semibold over a 13 line, a chevron; groupsArea, radius 16,
    /// padding 12 x 14. `symbol` nil draws the heart.
    private func lineCard(symbol: String?, title: String, under: String, caption: String? = nil,
                          action: @escaping () -> Void) -> Widget! {
        let row = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        let icon: Widget!
        if let symbol {
            icon = gtk_image_new_from_icon_name(symbol)
            gtk_image_set_pixel_size(OpaquePointer(icon), 22)
            gtk_widget_add_css_class(icon, "swiftly-zeilensymbol")
        } else {
            icon = symbolPaint(.heart, size: 22, box: 26, style: "swiftly-s17-fett")
        }
        gtk_widget_set_size_request(icon, 26, -1)
        gtk_widget_set_valign(icon, GTK_ALIGN_CENTER)
        append(row, icon)
        let column = stack(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_widget_set_valign(column, GTK_ALIGN_CENTER)
        gtk_widget_set_hexpand(column, 1)
        append(column, supportText(title, "swiftly-s17-fett"))
        append(column, supportText(under, "swiftly-s13-sehrleise"))
        append(row, column)
        let chevron: Widget! = gtk_image_new_from_icon_name("go-next-symbolic")
        gtk_image_set_pixel_size(OpaquePointer(chevron), 13)
        gtk_widget_add_css_class(chevron, "swiftly-pfeilzeichen")
        gtk_widget_set_valign(chevron, GTK_ALIGN_CENTER)
        append(row, chevron)

        let button: Widget! = gtk_button_new()
        gtk_widget_add_css_class(button, "swiftly-zeilenkarte")
        gtk_button_set_child(asButton(button), row)
        caption.map { help(button, name: $0) }
        signal(button, "clicked", action)
        return button
    }

    // MARK: Quick Connect

    private func quickConnectBuild(_ block: Widget!) {
        append(block, subpageHeader(translated("Quick Connect")))

        let text = label(translated("Auf dem anderen Gerät steht ein sechsstelliger Code. Gib ihn hier ein, dann meldet es sich mit deinem Konto an."),
                                style: "swiftly-koerper", wrap: true)
        gtk_widget_add_css_class(text, "dim-label")
        gtk_label_set_xalign(OpaquePointer(text), 0)
        gtk_label_set_justify(OpaquePointer(text), GTK_JUSTIFY_LEFT)
        gtk_widget_set_margin_top(text, 14)
        append(block, text)

        let inputField: Widget! = gtk_entry_new()
        gtk_entry_set_placeholder_text(asField(inputField), "000000")
        gtk_entry_set_max_length(asField(inputField), 6)
        gtk_widget_add_css_class(inputField, "swiftly-code")
        gtk_widget_set_margin_top(inputField, 22)
        append(block, inputField)

        let state = label("", style: "swiftly-zweitzeile", wrap: true)
        gtk_widget_set_visible(state, 0)
        gtk_widget_set_margin_top(state, 12)
        append(block, state)

        let button = primaryButton(translated("Freigeben"), symbol: "object-select-symbolic")
        gtk_widget_set_size_request(button, -1, Int32(Theme.primaryButtonHeight))
        gtk_widget_set_halign(button, GTK_ALIGN_FILL)
        gtk_widget_set_margin_top(button, 22)
        gtk_widget_set_sensitive(button, 0)
        append(block, button)

        let fieldBox = PointerBox(inputField)
        let stateBox = held(state)
        signal(inputField, "changed") { [weak self] in
            guard let self else { return }
            // **From four characters, not six.** The Mac enables the button at
            // `code.count >= 4` (`ProfileView.swift`). A code has six digits, but a button that
            // stays dead until the last character looks stuck.
            gtk_widget_set_sensitive(button, self.text(inputField).count >= 4 ? 1 : 0)
        }
        signal(button, "clicked") { [weak self] in
            guard let self, let client = self.client else { return }
            let code = self.text(fieldBox.widget)
            gtk_widget_set_sensitive(button, 0)
            let buttonBox = held(button)
            Task.detached {
                // `good` is created **before** the jump to the main thread and only read there;
                // passing a mutable variable across that boundary is not possible.
                let good: Bool
                if let quick = client as? any QuickSignIn {
                    do { try await quick.quickConnectShare(code: code); good = true }
                    catch { good = false }
                } else { good = false }
                onMainThread {
                    defer { letGo(buttonBox) }
                    gtk_label_set_text(OpaquePointer(stateBox.widget),
                                       good ? translated("Freigegeben. Das andere Gerät meldet sich jetzt an.")
                                           : translated("Der Code stimmt nicht oder ist abgelaufen."))
                    gtk_widget_add_css_class(stateBox.widget,
                                             good ? "swiftly-beleg" : "swiftly-warnung")
                    gtk_widget_set_visible(stateBox.widget, 1)
                    gtk_widget_set_sensitive(buttonBox.widget, 1)
                }
            }
        }
    }

    // MARK: Playback

    private func playbackBuild(_ block: Widget!) {
        append(block, subpageHeader(translated("Wiedergabe")))

        // **Two columns, like the Mac** (`PlaybackSettingsView.swift`): left,
        // everything about sound (quality and language); right, behavior alone.
        let (left, right) = twoColumn(in: block)

        // MARK: Quality
        // If the server does not transcode there is nothing to choose: Direct Play is fixed
        // on and the bitrate is locked.
        let free = convertAllowed
        let directPlay = selection.alwaysDirectPlay || !free
        let q = settingGroup(translated("Qualität"), topGap: 22)
        let toggle = toggleRow(symbol: "media-playback-start-symbolic",
                                     title: translated("Immer Direct Play"),
                                     under: translated("Der Server wandelt nie um, es läuft immer die Originaldatei"),
                                     an: directPlay) { [weak self] an in
            self?.selection.alwaysDirectPlay = an
            self?.selection.secure()
            self?.subpageOpen(.playback)
        }
        gtk_widget_set_sensitive(toggle, free ? 1 : 0)
        append(q.space, toggle)
        append(q.space, rowsLine())
        let bitrate = valuesRow(symbol: "view-list-symbolic", title: translated("Höchste Bitrate"),
                                 value: Bitrate.text(selection.bitratesLimit), arrow: true) {
            [weak self] in self?.listToggle(.bitrate)
        }
        // **The bitrate only applies when Direct Play is not forced**; otherwise it would
        // have no effect and still be shown.
        gtk_widget_set_sensitive(bitrate, directPlay ? 0 : 1)
        gtk_widget_set_opacity(bitrate, directPlay ? 0.4 : 1)
        append(q.space, bitrate)
        if openList == .bitrate {
            append(q.space, valueList(Bitrate.levels.map { (Bitrate.text($0.value), $0.value) },
                                         selected: selection.bitratesLimit) { [weak self] value in
                self?.selection.bitratesLimit = value
                self?.selection.secure()
                self?.listClose(.playback)
            })
        }
        append(left, q.outer)

        // MARK: Language
        let sp = settingGroup(translated("Sprache"))
        append(sp.space, valuesRow(symbol: "audio-volume-high-symbolic", title: translated("Ton"),
                                      value: languageName(selection.audioLanguage), arrow: true) {
            [weak self] in self?.listToggle(.audio)
        })
        if openList == .audio {
            append(sp.space, valueList(LanguageSelection.all.map { ($0.name, $0.value) },
                                          selected: selection.audioLanguage) { [weak self] value in
                self?.selection.audioLanguage = value
                self?.selection.secure()
                self?.listClose(.playback)
            })
        }
        append(sp.space, rowsLine())
        append(sp.space, valuesRow(symbol: "media-view-subtitles-symbolic", title: translated("Untertitel"),
                                      value: languageName(selection.subtitleLanguage, from: translated("Aus")),
                                      arrow: true) {
            [weak self] in self?.listToggle(.subtitle)
        })
        if openList == .subtitle {
            append(sp.space, valueList(LanguageSelection.all(from: translated("Aus")).map { ($0.name, $0.value) },
                                          selected: selection.subtitleLanguage) { [weak self] value in
                self?.selection.subtitleLanguage = value
                // A language alone does nothing while "automatic" is off.
                if !value.isEmpty { self?.selection.subtitleAutomatic = true }
                self?.selection.secure()
                self?.listClose(.playback)
            })
        }
        append(sp.space, rowsLine())
        append(sp.space, toggleRow(symbol: "format-justify-left-symbolic",
                                         title: translated("Untertitel automatisch"),
                                         under: translated("Nur wenn der Ton nicht in der gewählten Sprache läuft"),
                                         an: selection.subtitleAutomatic) { [weak self] an in
            self?.selection.subtitleAutomatic = an
            self?.selection.secure()
        })
        append(sp.space, rowsLine())
        append(sp.space, subtitleEntryRow())
        append(left, sp.outer)

        // MARK: Behavior
        let v = settingGroup(translated("Verhalten"), topGap: 22)
        append(v.space, toggleRow(symbol: "media-skip-forward-symbolic",
                                        title: translated("Nächste Folge automatisch"),
                                        an: nextAutomatic) { [weak self] an in
            self?.selection.nextAutomaticSelected = an
            self?.selection.secure()
        })
        append(v.space, rowsLine())
        append(v.space, toggleRow(symbol: "media-skip-forward-symbolic",
                                        title: translated("Intro und Abspann automatisch überspringen"),
                                        an: selection.skipAutomatic) { [weak self] an in
            self?.selection.skipAutomatic = an
            self?.selection.secure()
        })
        // **The tech badge sits directly after "Next episode automatically"**, as in
        // `macOS/PlaybackSettingsView.swift` (second place, not after skip
        // forward/back).
        append(v.space, rowsLine())
        append(v.space, toggleRow(symbol: "preferences-system-symbolic",
                                        title: translated("Technische Daten im Player"),
                                        an: selection.techBadge) { [weak self] an in
            self?.selection.techBadge = an
            self?.selection.secure()
            self?.techBadgeSet(an)
        })
        append(v.space, rowsLine())
        append(v.space, toggleRow(symbol: "paint:clock",
                                        title: translated("Endzeit im Player"),
                                        an: selection.endTimeInPlayer) { [weak self] an in
            self?.selection.endTimeInPlayer = an
            self?.selection.secure()
        })
        append(v.space, rowsLine())
        append(v.space, valuesRow(symbol: "media-seek-backward-symbolic", title: translated("Zurückspulen"),
                                     value: "\(selection.backSeconds) s", arrow: true) {
            [weak self] in self?.listToggle(.back)
        })
        if openList == .back {
            append(v.space, valueList(Span.levels.map { ("\($0.value) s", $0.value) },
                                         selected: selection.backSeconds) { [weak self] value in
                self?.selection.backSeconds = value
                self?.selection.secure()
                self?.listClose(.playback)
            })
        }
        append(v.space, rowsLine())
        append(v.space, valuesRow(symbol: "media-seek-forward-symbolic", title: translated("Vorspulen"),
                                     value: "\(selection.forwardSeconds) s", arrow: true) {
            [weak self] in self?.listToggle(.forward)
        })
        if openList == .forward {
            append(v.space, valueList(Span.levels.map { ("\($0.value) s", $0.value) },
                                         selected: selection.forwardSeconds) { [weak self] value in
                self?.selection.forwardSeconds = value
                self?.selection.secure()
                self?.listClose(.playback)
            })
        }
        append(v.space, rowsLine())
        // **The buffer: three cases, no seconds.**
        //
        // The reserve is held in bytes: the same 16 MiB are about twenty-five seconds of
        // a 5 Mbit series and just under two seconds of an 80 Mbit film. A number of
        // seconds would mean something different for every title, so the levels name the
        // case.
        append(v.space, valuesRow(symbol: "network-wireless-signal-weak-symbolic",
                                     title: translated("Puffer"),
                                     value: selection.buffer.name, arrow: true) {
            [weak self] in self?.listToggle(.buffer)
        })
        if openList == .buffer {
            append(v.space, valueList(BufferLevel.allCases.map { ($0.name, $0) },
                                         selected: selection.buffer) { [weak self] rung in
                self?.selection.bufferLevel = rung.rawValue
                self?.selection.secure()
                self?.listClose(.playback)
            })
        }
        append(right, v.outer)
    }

    private func languageName(_ value: String, from: String = translated("Wie die Datei")) -> String {
        value.isEmpty ? from : value
    }

    // MARK: Settings

    private func settingsBuild(_ block: Widget!) {
        // 1.1: the page is called "Allgemein" (Mac `SettingsView`), title with no gap below.
        append(block, subpageHeader(translated("Allgemein")))

        // "Lock landscape in the player" does **not** exist here: a window has no
        // orientation to lock. A setting without a counterpart, not an omission.
        // **"Appearance" is its own page**, reached from the profile, as on the Mac
        // (`ProfileView.swift`). Keeping it as a group inside settings would put the same
        // settings in two places in different forms.

        // **Two columns, like the Mac** (`SettingsView.swift`): left, offline and
        // integration; right, server. One narrow 560 pt column would look like a phone view
        // in the middle of a wide window.
        let (left, right) = twoColumn(in: block, gap: 24)

        let o = settingGroup(translated("Offline"), topGap: 22)
        append(o.space, toggleRow(symbol: "folder-download-symbolic",
                                        title: translated("Downloads"),
                                        under: translated("Titel offline schauen"),
                                        an: selection.downloadsAn) { [weak self] an in
            guard let self else { return }
            if an || self.downloads.entries.isEmpty {
                self.selection.downloadsAn = an
                self.selection.secure()
                self.mineFill()
            } else {
                // **Switching off never deletes anything unasked.** The question appears where the
                // switch was flipped; there is no system dialog like on the Mac in this UI.
                self.disablePromptShow()
            }
        })
        // The confirmation: hidden until someone wants to switch off.
        downloadDisablePrompt = stack(GTK_ORIENTATION_VERTICAL, spacing: 10)
        gtk_widget_set_margin_start(downloadDisablePrompt, 14)
        gtk_widget_set_margin_end(downloadDisablePrompt, 14)
        gtk_widget_set_margin_bottom(downloadDisablePrompt, 12)
        gtk_widget_set_visible(downloadDisablePrompt, 0)
        append(o.space, downloadDisablePrompt)

        // **"Wi-Fi only" exists here too.** A desktop computer has no mobile network,
        // but the Mac is one as well and has the row: a laptop may well sit on a metered
        // connection.
        //
        // **One condition, not two.** Two nested `if selection.downloadsAn` with the same
        // comparison and an extra `rowsLine()` would draw a double hairline above the
        // Wi-Fi row.
        if selection.downloadsAn {
            let b = DownloadRules.allocation(downloads.entries)
            append(o.space, rowsLine())
            append(o.space, toggleRow(symbol: "network-wireless-symbolic",
                                            title: translated("Nur über WLAN"),
                                            under: translated("Downloads warten, bis du im WLAN bist"),
                                            an: selection.onlyOverWLAN) { [weak self] an in
                self?.selection.onlyOverWLAN = an
                self?.selection.secure()
            })
            append(o.space, rowsLine())
            append(o.space, toggleRow(symbol: "media-skip-forward-symbolic",
                                            title: translated("Nächste Folge laden"),
                                            under: translated("Lädt die nächste, löscht die gesehene"),
                                            an: selection.nextLoad) { [weak self] an in
                self?.selection.nextLoad = an
                self?.selection.secure()
            })
            append(o.space, rowsLine())
            append(o.space, valuesRow(symbol: "drive-harddisk-symbolic",
                                         title: translated("Speicher"),
                                         under: numberWord(downloads.entries.count,
                                                         one: translated("1 Titel auf diesem Rechner"),
                                                         many: translated("%d Titel auf diesem Rechner")),
                                         value: DownloadRules.size(b.bytes)))
        }
        append(left, o.outer)

        // **"Swiftly" group under offline** (Mac `MacSupportSettingsGroup`): the support row,
        // "Danke" for supporters. The app-icon picker below it does not exist here (a desktop
        // window takes its icon from the package), left out on purpose.
        let sw = settingGroup("Swiftly")
        append(sw.space, valuesRow(symbol: "paint:heart",
                                   title: translated(SupportCopy.supportSwiftly.key),
                                   under: translated(SupportCopy.sayThanks.key),
                                   value: isSupporter ? translated(SupportCopy.thankYou.key) : nil) { [weak self] in
            self?.supportOpen()
        })
        gtk_widget_set_margin_top(sw.outer, 6)
        append(left, sw.outer)

        // **Server and services in one card** (Mac `server` + `serviceRows`): server, check,
        // then Seerr and Discord; the own-headers editor sits under it.
        let s = settingGroup(translated("Server und Dienste"), topGap: 22)
        append(s.space, valuesRow(symbol: "network-server-symbolic",
                                     title: serverName.isEmpty ? translated("Server") : serverName,
                                     value: serverVersion))
        append(s.space, rowsLine())
        // **A row that does nothing is worse than none.** The Mac starts the check, shows
        // "Moment …" as the value and the result as a **subtitle**; while it runs, the row
        // is not clickable (`SettingsView.swift`). Putting both in the value field
        // would let a second click start the check again.
        let running = checkResult == translated("Moment…")
        let checkRow = valuesRow(symbol: "network-wireless-symbolic",
                                    title: translated("Verbindung prüfen"),
                                    under: running || checkResult.isEmpty ? nil : checkResult,
                                    value: running ? checkResult : nil,
                                    pick: running ? nil : { [weak self] in
                                        self?.connectionCheck()
                                    })
        append(s.space, checkRow)
        append(s.space, rowsLine())
        append(s.space, valuesRow(symbol: "edit-find-symbolic",
                                     title: translated("Seerr"),
                                     under: translated("Anfragen, was noch nicht da ist"),
                                     value: seerrPresent ? translated("Verbunden") : nil,
                                     // Value **or** arrow, not both, as on the Mac.
                                     arrow: !seerrPresent) { [weak self] in
            self?.subpageOpen(.seerr)
        })
        // **Here and not under "Playback".** The rows there say *how* something runs;
        // this one is the only one that gives something to the outside. It belongs next to
        // the other external service.
        append(s.space, rowsLine())
        append(s.space, toggleRow(symbol: "user-available-symbolic",
                                        title: translated("Discord"),
                                        under: translated("Zeigt im Profil, was gerade läuft"),
                                        an: selection.discordShow) { [weak self] an in
            guard let self else { return }
            self.selection.discordShow = an
            self.selection.secure()
            if !an { DiscordState.tidyAway() }
        })
        append(right, s.outer)
        append(right, ownHeadersBuild())

        // **Settings follow the account to every device** (Mac "Synchronisierung", gap 28).
        let sync = settingGroup(translated("Synchronisierung"))
        append(sync.space, toggleRow(symbol: "view-refresh-symbolic",
                                     title: translated("Auf allen Geräten gleich"),
                                     under: translated("Liegt auf deinem Server"),
                                     an: settingsSync.on) { [weak self] an in
            self?.settingsSync.on = an
        })
        append(right, sync.outer)

        append(block, versionLine("\(Version.full) · libVLC \(VLCVersion.text)"))
    }

    // MARK: Page building blocks

    private func listToggle(_ was: ValuesSelection) {
        openList = openList == was ? nil : was
        subpageOpen(.playback)
    }

    private func listClose(_ page: Subpage) {
        openList = nil
        subpageOpen(page)
    }

    /// **A maximum width GTK does not know.**
    ///
    /// The Mac writes `frame(maxWidth: Theme.settingWidth)`. GTK has no equivalent:
    /// `set_size_request` is a minimum, and setting it to 1366 forces the window to 1366
    /// plus sidebar.
    ///
    /// The visible width is known to the scroller's horizontal adjustment as
    /// `page-size`, and it reports every change through `changed`. The block is then
    /// requested exactly as much as it may have.
    ///
    /// **Only set on a real change.** A `set_size_request` changes the adjustment and
    /// triggers `changed` again; without the comparison this would loop.
    func cap(_ block: Widget!, in scroller: Widget!, on atMost: Int) {
        gtk_widget_set_halign(block, GTK_ALIGN_START)
        gtk_widget_set_hexpand(block, 0)
        guard let adjustment = gtk_scrolled_window_get_hadjustment(OpaquePointer(scroller))
        else { return }
        var recent: Int32 = -1
        let adapt: () -> Void = {
            let visible = gtk_adjustment_get_page_size(adjustment)
            guard visible > 1 else { return }
            let free = visible - Double(Theme.edgeSpacing) * 2
            let width = Int32(max(min(free, Double(atMost)), 320))
            guard width != recent else { return }
            recent = width
            gtk_widget_set_size_request(block, width, -1)
        }
        signalRaw(UnsafeMutableRawPointer(adjustment), "changed", adapt)
        adapt()
    }

    /// **Not private.** The Seerr page built its own header because this one was
    /// private, and left out the arrow, making it a dead end (in, but out only through
    /// the sidebar). On the Mac it uses the same `SubpageHeader` as every other
    /// subpage (`SeerrSettingsView.swift`).
    func subpageHeader(_ title: String) -> Widget! {
        let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 14)
        let t = label(title, style: "swiftly-titel-gross")
        gtk_widget_set_valign(t, GTK_ALIGN_CENTER)
        append(rail, t)
        return rail
    }
    // MARK: Account strip

    /// The horizontal strip above the profile when several accounts exist.
    ///
    /// **Two easily confused things, whose separation is the core of the design:**
    ///
    /// - **Large is what sits in the middle.** On the desktop the active account is
    ///   centered in the content area and measures 96; the others measure 72 and sit
    ///   beside it. Size and place say *nothing* about who is connected; they follow the
    ///   selection.
    /// - **Connected is what carries the accent ring and dot.** That changes only on
    ///   click, never on mere looking.
    ///
    /// ``GtkCenterBox`` does the centering: the active account is the center child and
    /// stays in the middle as long as the sides allow.
    // MARK: Account cards

    /// **One card per server, the connected one first.**
    ///
    /// A strip of circles was the earlier design; the Mac replaced it with cards. When
    /// porting, check how the Mac looks *today*, not what a change list says was built.
    ///
    /// **Stacked, not swiped.** The window has room downwards, and swiping is a finger
    /// gesture. This is a deviation permitted by input method and window size, not by
    /// taste.
    private func accountsCards() -> Widget! {
        let column = stack(GTK_ORIENTATION_VERTICAL, spacing: 14)
        gtk_widget_set_halign(column, GTK_ALIGN_FILL)
        let groups = serverGroups()
        if groups.isEmpty {
            append(column, accountCard(nil, count: 0))
        } else {
            for group in groups { append(column, accountCard(group, count: groups.count)) }
        }
        return column
    }

    /// One server of one kind with the accounts on it. A Plex server is its machine, never
    /// its address: a profile that came in over another route still sits on the same card.
    struct ServerGroup {
        let kind: ServerKind
        let id: String
        let address: URL
        var accounts: [Session]
    }

    /// All servers of all kinds, the connected one first, then in the order of their first account.
    private func serverGroups() -> [ServerGroup] {
        var groups: [ServerGroup] = []
        for session in allAccounts {
            var place = session.serverURL.absoluteString.lowercased()
            while place.hasSuffix("/") { place.removeLast() }
            let id = session.kind.rawValue + "|" + (session.plex.map { "plex:" + $0.machineIdentifier } ?? place)
            if let index = groups.firstIndex(where: { $0.id == id }) {
                groups[index].accounts.append(session)
            } else {
                groups.append(ServerGroup(kind: session.kind, id: id, address: session.serverURL,
                                          accounts: [session]))
            }
        }
        return groups
    }

    private func isActiveServer(_ group: ServerGroup?) -> Bool {
        guard let group, let key = bundle?.activeOne.accountKey else { return false }
        return group.accounts.contains { $0.accountKey == key }
    }

    private func accountCard(_ group: ServerGroup?, count: Int) -> Widget! {
        let all = group?.accounts ?? []
        let active = isActiveServer(group)
        // On the connected server the signed-in account comes first; on another server the
        // first account there, and a click switches to it.
        let front: Session? = active ? bundle?.activeOne : all.first
        let other = all.filter { $0.accountKey != front?.accountKey }

        let card = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_add_css_class(card, "swiftly-kontokarte")
        // **Accent border only when there is something to distinguish.** With a single
        // server it would be a highlight without a counterpart.
        if active, count > 1 {
            gtk_widget_add_css_class(card, "swiftly-aktiv")
        }
        append(card, cardsHeader(front, active: active, group: group, count: count))
        let stroke: Widget! = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
        gtk_widget_add_css_class(stroke, "swiftly-trennlinie")
        gtk_widget_set_size_request(stroke, -1, 1)
        append(card, stroke)
        append(card, cardsRail(other, active: active, group: group))
        return card
    }

    /// Avatar 56, next to it name, server and version. On another server the whole row
    /// is a button, on the connected one plain text.
    private func cardsHeader(_ account: Session?, active: Bool, group: ServerGroup?, count: Int) -> Widget! {
        let row = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 14)
        gtk_widget_set_margin_start(row, 16)
        gtk_widget_set_margin_end(row, 16)
        gtk_widget_set_margin_top(row, 16)
        gtk_widget_set_margin_bottom(row, 16)

        let parts = profileCharacter(name: account?.userName ?? "?", border: 56,
                                  style: active && count > 1 ? "swiftly-kontoaktiv"
                                                          : "swiftly-profilgross",
                                  fontStyle: "swiftly-zeichen72")
        append(row, parts.wrapper)
        if let account {
            profileImageLoad(parts, url: userImageURL(for: account, border: 200),
                            key: "konto-\(account.userID)")
        }

        let texts = stack(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_widget_set_valign(texts, GTK_ALIGN_CENTER)
        gtk_widget_set_hexpand(texts, 1)
        let name = label(account?.userName ?? translated("Angemeldet"),
                                style: "swiftly-kontoname")
        gtk_label_set_xalign(OpaquePointer(name), 0)
        append(texts, name)

        // **Name and version are only known from the server we are connected to**; for the
        // others the address is shown. A Plex server has its name in the session.
        let host = group?.address.host() ?? ""
        let second: String
        if let plexName = (account ?? group?.accounts.first)?.plex?.serverName {
            second = plexName
        } else {
            second = active ? (serverName.isEmpty ? host : serverName) : host
        }
        let z = label(second, style: "swiftly-zweitzeile")
        gtk_widget_add_css_class(z, "swiftly-leise")
        gtk_label_set_xalign(OpaquePointer(z), 0)
        gtk_label_set_ellipsize(OpaquePointer(z), PANGO_ELLIPSIZE_END)
        append(texts, z)

        if active {
            let kind = group?.kind ?? .jellyfin
            let f = label(serverVersion.isEmpty ? kind.shownName : "\(kind.shownName) \(serverVersion)",
                          style: "swiftly-zweitzeile")
            gtk_widget_add_css_class(f, "swiftly-leise")
            gtk_label_set_xalign(OpaquePointer(f), 0)
            append(texts, f)
        } else {
            // **"Click", not "tap"**: mouse and keyboard.
            let f = label(translated("Klicken zum Wechseln"), style: "swiftly-zweitzeile")
            gtk_widget_add_css_class(f, "swiftly-leise")
            gtk_label_set_xalign(OpaquePointer(f), 0)
            append(texts, f)
        }
        append(row, texts)

        guard !active, let account else { return row }
        let button: Widget! = gtk_button_new()
        gtk_widget_add_css_class(button, "swiftly-kontoknopf")
        gtk_button_set_child(asButton(button), row)
        let key = account.accountKey
        let image = parts.wrapper
        signal(button, "clicked") { [weak self] in
            self?.accountSwitchWithTransition(toward: key, account: account, from: image)
        }
        return button
    }

    /// The other accounts of this server, then the plus.
    private func cardsRail(_ other: [Session], active: Bool, group: ServerGroup?) -> Widget! {
        let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 14)
        gtk_widget_set_margin_start(rail, 16)
        gtk_widget_set_margin_end(rail, 16)
        gtk_widget_set_margin_top(rail, 12)
        gtk_widget_set_margin_bottom(rail, 12)

        for account in other {
            let button: Widget! = gtk_button_new()
            gtk_widget_add_css_class(button, "swiftly-kontoknopf")
            let parts = profileCharacter(name: account.userName, border: 40,
                                      style: "swiftly-kontoandere",
                                      fontStyle: "swiftly-zeichen26")
            gtk_button_set_child(asButton(button), parts.wrapper)
            gtk_widget_set_tooltip_text(button, account.userName)
            caption(button, String(format: translated("Zu %@ wechseln"), account.userName))
            profileImageLoad(parts, url: userImageURL(for: account, border: 200),
                            key: "konto-\(account.userID)")
            let key = account.accountKey
            let image = parts.wrapper
            signal(button, "clicked") { [weak self] in
                self?.accountSwitchWithTransition(toward: key, account: account, from: image)
            }
            append(rail, button)
        }

        // **The plus is on every card** and adds an account on *this* server. A Plex card
        // opens the Plex sign-in (a further profile signs in over the same code page); on
        // the connected Jellyfin or Emby it is the usual sign-in; on another one it is the
        // same as when adding a server, with the address already filled in.
        let plus: Widget! = gtk_button_new()
        gtk_widget_add_css_class(plus, "swiftly-kontoplus")
        gtk_widget_set_size_request(plus, 40, 40)
        gtk_button_set_child(asButton(plus), gtk_image_new_from_icon_name("list-add-symbolic"))
        gtk_widget_set_tooltip_text(plus, translated("Weiteres Konto hinzufügen"))
        caption(plus, translated("Weiteres Konto hinzufügen"))
        signal(plus, "clicked") { [weak self] in
            guard let self else { return }
            self.serverOnboardingFromPicker = false
            if group?.kind == .plex {
                self.subpageOpen(.plexSignIn)
            } else if active, group?.kind != .emby {
                self.subpageOpen(.accountAdd)
            } else if let group {
                self.serverOnboardingKind = group.kind
                self.serverOnboardingOpen(group.address)
            }
        }
        append(rail, plus)

        let padding: Widget! = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
        gtk_widget_set_hexpand(padding, 1)
        append(rail, padding)
        return rail
    }

    // MARK: Appearance: configuring the home page

    /// **Which rows, in which order, and genres as rows or chips.**
    ///
    /// The calculation behind it lives in the package as ``Startreihenfolge``, so the
    /// same storage gives the same result on every platform.
    private func presentationBuild(_ block: Widget!) {
        append(block, subpageHeader(translated("Darstellung")))

        // Two columns like the Mac (`macOS/AppearanceView.swift`): left, general, rows
        // and new additions; right, the genres.
        let (left, right) = twoColumn(in: block)

        // **General**: the same section as on Apple (`AppearanceView.swift`).
        let ga = settingGroup(translated("Allgemein"))
        // **Interface size**, for 4K screens. Takes effect immediately
        // (``scaleSurface(_:)``); "Reset" only appears while the value is not
        // 100 %.
        let slider = SizesSlider(value: selection.surface,
                                    title: translated("Größe der Oberfläche"),
                                    under: translated("Kommt zur Skalierung des Systems dazu"))
        append(ga.space, slider.display)
        let jumpBack = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        append(jumpBack, rowsLine())
        append(jumpBack, valuesRow(symbol: "edit-undo-symbolic",
                                          title: translated("Zurücksetzen"),
                                          accent: true) { [weak self, weak slider] in
            slider?.setDown(1)
            gtk_widget_set_visible(jumpBack, 0)
            self?.scaleSurface(1)
        })
        gtk_widget_set_visible(jumpBack, selection.surface != 1 ? 1 : 0)
        slider.selected = { [weak self] value in
            gtk_widget_set_visible(jumpBack, value != 1 ? 1 : 0)
            self?.scaleSurface(value)
        }
        append(ga.space, jumpBack)
        append(ga.space, rowsLine())
        append(ga.space, toggleRow(symbol: "view-list-symbolic",
                                         title: translated("Fortschritt auf Kacheln"),
                                         an: selection.progressOnTiles) { [weak self] an in
            self?.selection.progressOnTiles = an
            self?.selection.secure()
            // The home page already exists; without a rebuild the switch would only apply on
            // the next load. Grids rebuild when opened.
            self?.homeLoad()
        })
        append(ga.space, toggleRow(symbol: "user-bookmarks-symbolic",
                                         title: translated("Merkliste"),
                                         under: translated("Seite, Filter und Knopf auf Film- und Serienseiten"),
                                         an: selection.watchlistShown) { [weak self] an in
            self?.selection.watchlistShown = an
            self?.selection.secure()
            // The sidebar row comes and goes at once; filters and detail pages follow when opened.
            self?.mineFill()
        })
        // Only when this server has shown it has the plugin; otherwise the switch would
        // promise something that cannot happen.
        if watchedByAvailable {
            append(ga.space, toggleRow(symbol: "avatar-default-symbolic",
                                             title: translated("Gesehen von"),
                                             under: translated("Zeigt auf Titelseiten, wer einen Titel gesehen hat"),
                                             an: selection.watchedByShown) { [weak self] an in
                self?.selection.watchedByShown = an
                self?.selection.secure()
            })
        }
        append(ga.space, toggleRow(symbol: "format-text-bold-symbolic",
                                         title: translated("Alphabetische Suche in Listen"),
                                         an: selection.alphabetShown) { [weak self] an in
            guard let self else { return }
            self.selection.alphabetShown = an
            self.selection.secure()
            // The strips come and go at once on the grids that already exist.
            for was in [Region.movies, .seriesList, .collection] { self.alphabetRailUpdate(was) }
        })
        append(ga.space, toggleRow(symbol: "format-text-bold-symbolic",
                                         title: translated("Titel als Logo"),
                                         under: translated("Auf Film- und Serienseiten, wenn dein Server eins hat"),
                                         an: selection.titleAsLogo) { [weak self] an in
            self?.selection.titleAsLogo = an
            self?.selection.secure()
        })
        append(left, ga.outer)
        append(left, paddingHigh(26))
        append(left, looksGroup())
        append(left, paddingHigh(26))

        // **"Rows" above the list, "New additions" below**, the Mac's order
        // (`AppearanceView.swift`). The switch above the rows would put them under a
        // heading they do not belong to.
        // **One group, not heading and card separate.** The Mac puts the rows into the same
        // `Einstellungsgruppe` as their heading; separate groups leave a visible gap.
        //
        // **Reordering uses what the input method offers**: handles on iPhone, two arrows
        // per row here. Dragging with the mouse over a list that can also hide entries
        // would put two gestures on one row.
        // **Fixed rows, libraries and collections in one list** (``StartOrder``): a library can
        // stand above "Weiterschauen" or between two fixed rows. "+" adds one at the end.
        let g0 = settingGroup(translated("Reihen"))
        let visible = selection.startListed
        for (spot, entry) in visible.enumerated() {
            if spot > 0 { append(g0.space, rowsLine()) }
            switch entry {
            case .rail(let rail):
                append(g0.space, railsRow(rail, spot: spot, from: visible.count))
            case .library(let id):
                if let entryRecord = selection.startLibraries.first(where: { $0.id == id }) {
                    append(g0.space, libraryRow(entryRecord, spot: spot, from: visible.count))
                }
            }
        }
        append(g0.space, divider())
        append(g0.space, valuesRow(symbol: "list-add-symbolic",
                                      title: translated("Bibliothek hinzufügen"),
                                      accent: true,
                                      arrow: true) { [weak self] in
            self?.subpageOpen(.librarySelection)
        })
        append(left, g0.outer)

        let gn = settingGroup(translated("Neuzugänge"))
        append(gn.space, toggleRow(symbol: "folder-new-symbolic",
                                         title: translated("Neuzugänge getrennt"),
                                         under: translated("Neue Filme und neue Serien in eigenen Reihen"),
                                         an: selection.newArrivalsDisconnected) { [weak self] an in
            self?.selection.newArrivalsDisconnected = an
            self?.selection.secure()
            self?.loaded.remove(.start)
            self?.subpageOpen(.presentation)
        })

        let foot1 = label(translated("Mit den Pfeilen umsortieren. Was aus ist, steht nicht auf der Startseite."),
                                 style: "swiftly-zweitzeile", wrap: true)
        gtk_widget_add_css_class(foot1, "swiftly-sehrleise")
        gtk_label_set_xalign(OpaquePointer(foot1), 0)
        gtk_label_set_justify(OpaquePointer(foot1), GTK_JUSTIFY_LEFT)
        gtk_widget_set_margin_top(foot1, 8)
        append(left, foot1)
        append(left, paddingHigh(26))
        append(left, gn.outer)

        append(left, paddingHigh(26))

        // **Two forms of the same selection**, not two sets. Like the other rows in the
        // card: an icon showing the form, no selection circle; the checkmark is on the
        // right.
        let g2 = settingGroup(translated("Genres"))
        append(g2.space, valuesRow(symbol: "view-grid-symbolic",
                                      title: translated("Als eigene Reihen"),
                                      checkmark: !selection.genreChips) { [weak self] in
            self?.selection.genreChips = false
            self?.selection.secure()
            self?.loaded.remove(.start)
            self?.subpageOpen(.presentation)
        })
        append(g2.space, rowsLine())
        append(g2.space, valuesRow(symbol: "view-continuous-symbolic",
                                      title: translated("Als Chips über den Reihen"),
                                      checkmark: selection.genreChips) { [weak self] in
            self?.selection.genreChips = true
            self?.selection.secure()
            self?.loaded.remove(.start)
            self?.subpageOpen(.presentation)
        })
        // **One card, not three.** On the Mac the two forms, the chosen genres and "Add
        // genre" are in **one** `Einstellungsgruppe` (`AppearanceView.swift`), so the
        // divider runs through them instead of a gap.
        for (spot, name) in selection.startGenres.enumerated() {
            append(g2.space, rowsLine())
            append(g2.space, genreRow(name, spot: spot,
                                          from: selection.startGenres.count))
        }
        // The divider before "Add genre" spans the full width on the Mac (`Trennstrich()`
        // without inset): it separates the list from its entry point, not two rows of the
        // same kind.
        append(g2.space, divider())
        // **In accent color.** `ValuesRow(..., accent: true, ...)` on the Mac
        // (`AppearanceView.swift`).
        append(g2.space, valuesRow(symbol: "list-add-symbolic",
                                      title: translated("Genre hinzufügen"),
                                      accent: true,
                                      arrow: true) { [weak self] in
            self?.subpageOpen(.genreSelection)
        })
        append(right, g2.outer)
    }

    /// A row in the list: name, switch, two arrows.
    private func railsRow(_ rail: StartRail, spot: Int, from: Int) -> Widget! {
        let row = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        // **The same body as every other row.** Its own 14/10 padding made it the only
        // row in the card taller than "Progress on tiles" next to it; on the Mac `ChoiceRow`
        // is the same 44 pt row as `ToggleRow`
        // (`Sources/macOS/SettingRows.swift`).
        gtk_widget_add_css_class(row, "swiftly-zeilenrumpf")

        // **With an icon like every other row of the app.** Without it the row list was
        // the only one that looked different.
        let image: Widget! = gtk_image_new_from_icon_name(rail.symbolText)
        gtk_image_set_pixel_size(OpaquePointer(image), 15)
        gtk_widget_set_size_request(image, 22, -1)
        append(row, image)
        let name = label(translated(rail.listsName), style: "swiftly-koerper")
        gtk_label_set_xalign(OpaquePointer(name), 0)
        gtk_widget_set_hexpand(name, 1)
        append(row, name)

        let up = listArrow("go-up-symbolic", name: translated("Nach oben"), an: spot > 0) { [weak self] in
            self?.entryMove(.rail(rail), um: -1)
        }
        append(row, up)
        let down = listArrow("go-down-symbolic", name: translated("Nach unten"), an: spot < from - 1) { [weak self] in
            self?.entryMove(.rail(rail), um: 1)
        }
        append(row, down)

        let an = !selection.startOut.contains(rail.rawValue)
        append(row, smallerToggle(an: an, name: translated(rail.listsName)) { [weak self] new in
            guard let self else { return }
            if new { self.selection.startOut.removeAll { $0 == rail.rawValue } }
            else { self.selection.startOut.append(rail.rawValue) }
            self.selection.secure()
            self.loaded.remove(.start)
        })
        return row
    }

    /// One step up or down in the list of rows and libraries (``StartOrder/shifted``).
    private func entryMove(_ entry: StartEntry, um step: Int) {
        guard let moved = StartOrder.shifted(entry, by: step, in: selection.startListed) else { return }
        selection.startArrange(moved)
        selection.secure()
        loaded.remove(.start)
        subpageOpen(.presentation)
    }

    /// A chosen genre: name and a way to remove it.
    /// - Parameters:
    ///   - stelle: Where the genre is in the list, for the two arrows.
    ///   - von: How many there are in total.
    ///
    /// **With arrows, like the start rows above.** The Mac lets genres be dragged
    /// (`AppearanceView.swift`, `genreStore`); here two arrows do it, as for the
    /// rows: the same deviation for the same reason (input method).
    private func genreRow(_ name: String, spot: Int, from: Int) -> Widget! {
        let row = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        gtk_widget_add_css_class(row, "swiftly-zeilenrumpf")
        // **The name comes from the server** and is not translated.
        let l = label(name, style: "swiftly-koerper")
        gtk_label_set_xalign(OpaquePointer(l), 0)
        gtk_widget_set_hexpand(l, 1)
        append(row, l)
        append(row, listArrow("go-up-symbolic", name: translated("Nach oben"), an: spot > 0) { [weak self] in
            self?.genreMove(name, um: -1)
        })
        append(row, listArrow("go-down-symbolic", name: translated("Nach unten"), an: spot < from - 1) { [weak self] in
            self?.genreMove(name, um: 1)
        })
        let distance = listArrow("list-remove-symbolic", name: translated("Entfernen"), an: true) { [weak self] in
            guard let self else { return }
            self.selection.startGenres.removeAll { $0 == name }
            self.selection.secure()
            self.loaded.remove(.start)
            self.subpageOpen(.presentation)
        }
        append(row, distance)
        return row
    }

    /// Moves a genre by one position. The dragged one takes the place of the one it
    /// lands on, exactly like `genreStore` on the Mac.
    private func genreMove(_ name: String, um step: Int) {
        var list = selection.startGenres
        guard let from = list.firstIndex(of: name) else { return }
        let to = from + step
        guard to >= 0, to < list.count else { return }
        list.remove(at: from)
        list.insert(name, at: to)
        selection.startGenres = list
        selection.secure()
        loaded.remove(.start)
        subpageOpen(.presentation, push: .without)
    }

    /// A chosen library or collection: name, two arrows, remove. The name comes from
    /// the server and is not translated.
    private func libraryRow(_ entryRecord: StartLibrary, spot: Int, from: Int) -> Widget! {
        let row = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        gtk_widget_add_css_class(row, "swiftly-zeilenrumpf")
        let image: Widget! = gtk_image_new_from_icon_name(
            entryRecord.collection ? "view-grid-symbolic" : "folder-symbolic")
        gtk_image_set_pixel_size(OpaquePointer(image), 15)
        gtk_widget_set_size_request(image, 22, -1)
        append(row, image)
        let l = label(entryRecord.name, style: "swiftly-koerper")
        gtk_label_set_xalign(OpaquePointer(l), 0)
        gtk_widget_set_hexpand(l, 1)
        append(row, l)
        append(row, listArrow("go-up-symbolic", name: translated("Nach oben"), an: spot > 0) { [weak self] in
            self?.entryMove(.library(entryRecord.id), um: -1)
        })
        append(row, listArrow("go-down-symbolic", name: translated("Nach unten"), an: spot < from - 1) { [weak self] in
            self?.entryMove(.library(entryRecord.id), um: 1)
        })
        append(row, listArrow("list-remove-symbolic", name: translated("Entfernen"), an: true) { [weak self] in
            guard let self else { return }
            self.selection.startLibraries.removeAll { $0.id == entryRecord.id }
            self.selection.secure()
            self.loaded.remove(.start)
            self.subpageOpen(.presentation, push: .without)
        })
        return row
    }

    /// What can be chosen as a custom start row: the account's libraries and its
    /// collections, minus what is already chosen. A click adds it and goes back. The
    /// collections arrive with the directory, which is awaited here.
    private func librarySelectionBuild(_ block: Widget!) {
        append(block, subpageHeader(translated("Bibliothek hinzufügen")))
        let group = rowsGroup()
        append(block, group.outer)
        let container = held(group.space)
        offeringLoad { [weak self] in
            defer { letGo(container) }
            guard let self else { return }
            let collections = self.offeringFor != nil
                ? (self.collectionDirectory?.all.map(\.item) ?? []) : []
            let free = StartLibraries.pick(
                libraries: self.review.filter { StartLibraries.selectable($0) },
                collections: collections, selected: self.selection.startLibraries)
            guard !free.isEmpty else {
                let text = self.review.isEmpty
                    ? translated("Auf deinem Server gibt es keine Bibliotheken.")
                    : translated("Alle Bibliotheken und Sammlungen stehen schon auf der Startseite.")
                let l = label(text, style: "swiftly-koerper", wrap: true)
                gtk_widget_set_margin_start(l, 14)
                gtk_widget_set_margin_top(l, 12)
                gtk_widget_set_margin_bottom(l, 12)
                append(container.widget, l)
                return
            }
            for (spot, item) in free.enumerated() {
                if spot > 0 { append(container.widget, rowsLine()) }
                append(container.widget, valuesRow(
                    symbol: item.type == "BoxSet" ? "view-grid-symbolic" : "folder-symbolic",
                    title: item.name) { [weak self] in
                    guard let self else { return }
                    self.selection.startLibraries.append(StartLibrary(item))
                    self.selection.secure()
                    self.loaded.remove(.start)
                    self.subpageOpen(.presentation)
                })
            }
        }
    }

    /// The server's free genres.
    private func genreSelectionBuild(_ block: Widget!) {
        append(block, subpageHeader(translated("Genre hinzufügen")))
        let group = rowsGroup()
        append(block, group.outer)
        let space = group.space
        let already = Set(selection.startGenres)
        guard let client else { return }
        genreSelectionLoad(client: client, space: space, already: already)
    }

    /// **`nil` means disturbed, `[]` means: the server knows no genres** (`AppModel.genres()`
    /// on Apple). A failed fetch shows the server hint with "Erneut versuchen" instead of
    /// claiming the server has no genres.
    private func genreSelectionLoad(client: any MediaServer, space: Widget!, already: Set<String>) {
        let container = held(space)
        Task.detached { [self] in
            let fetched = try? await client.genres()
            onMainThread {
                defer { letGo(container) }
                wipe(container.widget)
                guard let all = fetched else {
                    append(container.widget, self.disturbHint(top: 12) { [weak self] in
                        self?.genreSelectionLoad(client: client, space: container.widget, already: already)
                    })
                    return
                }
                let free = all.filter { !already.contains($0) }
                guard !free.isEmpty else {
                    let text = all.isEmpty
                        ? translated("Auf deinem Server sind keine Genres hinterlegt.")
                        : translated("Alle Genres stehen schon auf der Startseite.")
                    let l = label(text, style: "swiftly-koerper", wrap: true)
                    gtk_widget_set_margin_start(l, 14)
                    gtk_widget_set_margin_top(l, 12)
                    gtk_widget_set_margin_bottom(l, 12)
                    append(container.widget, l)
                    return
                }
                for (spot, name) in free.enumerated() {
                    if spot > 0 { append(container.widget, rowsLine()) }
                    append(container.widget, valuesRow(symbol: "paint:tag", title: name) {
                        [weak self] in
                        guard let self else { return }
                        self.selection.startGenres.append(name)
                        self.selection.secure()
                        self.loaded.remove(.start)
                        self.subpageOpen(.presentation)
                    })
                }
            }
        }
    }

    // MARK: A second server

    /// Opens the setup: without address for a new server, with address for another
    /// account on an already known one.
    func serverOnboardingOpen(_ preset: URL?) {
        serverOnboardingAddress = preset?.absoluteString ?? ""
        serverOnboardingChecked = nil
        serverOnboardingError = ""
        serverOnboardingPreGiven = preset != nil
        serverOnboardingNotEmby = false
        accountPerCode = false
        subpageOpen(.serverOnboarding)
    }

    /// Shows "Mit Jellyfin weiter" under the error when an Emby address turned out to be a Jellyfin.
    func serverOnboardingNotEmbyShow() {
        guard let button = serverOnboardingNotEmbyButton else { return }
        gtk_widget_set_visible(button, serverOnboardingNotEmby ? 1 : 0)
    }

    /// The Plex sign-in as a subpage: header with arrow, then the code page.
    private func plexSignInBuild(_ block: Widget!) {
        plexSubpage?.stop()
        let page = PlexSignInPage(
            header: subpageHeader(ServerKind.plex.shownName),
            back: { [weak self] in self?.subpageBack() },
            finished: { [weak self] session in
                guard let self else { return }
                self.plexSubpage?.stop()
                self.accountAdd(session)
                self.subpageOpen(.profile, push: .without)
            })
        plexSubpage = page
        signal(page.display, "destroy") { [weak self] in
            if self?.plexSubpage === page { self?.plexSubpage = nil }
        }
        append(block, page.display)
    }

    /// **Check the address, then sign in: in the window, not as a sheet.**
    ///
    /// On the Mac both are stacked on one page (`macOS/ServerOnboardingView.swift`), and
    /// the reason applies here too: a sheet over a half-filled form would hide which
    /// server one is signing in to.
    private func serverOnboardingBuild(_ block: Widget!) {
        let newServer = !serverOnboardingPreGiven
        let kind = serverOnboardingKind
        // Mac `ServerOnboardingView` at HEAD: a page reached from the picker has the kind's own
        // title; the explaining sentence stays (no kind mark, no question, no extra hint).
        let pickedJellyfin = newServer && serverOnboardingFromPicker && kind == .jellyfin
            && serverOnboardingChecked == nil
        append(block, subpageHeader(pickedJellyfin ? translated("Mit Jellyfin anmelden")
                                    : newServer ? translated("Server hinzufügen")
                                                : translated("Weiteres Konto")))

        let sentence = label(newServer
            ? translated("Ein zweiter Jellyfin mit eigenen Konten. Beide bleiben angemeldet; auf der Profilseite wechselst du zwischen ihnen.")
            : translated("Ein weiteres Konto auf diesem Server. Beide bleiben angemeldet; auf der Profilseite wechselst du zwischen ihnen."),
            style: "swiftly-koerper", wrap: true)
        gtk_widget_add_css_class(sentence, "dim-label")
        gtk_label_set_xalign(OpaquePointer(sentence), 0)
        gtk_widget_set_margin_top(sentence, 14)
        append(block, sentence)

        if let checked = serverOnboardingChecked {
            // **What is verified is shown as a checkmark**, not as a field that could be
            // filled in again.
            let row = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
            gtk_widget_set_margin_top(row, 22)
            let checkmark: Widget! = gtk_image_new_from_icon_name("object-select-symbolic")
            gtk_widget_add_css_class(checkmark, "swiftly-akzentzeile")
            append(row, checkmark)
            let text = label(checked, style: "swiftly-zweitzeile")
            gtk_widget_add_css_class(text, "swiftly-leise")
            gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
            append(row, text)
            append(block, row)
            if accountPerCode { accountCodePart(block) } else { serverOnboardingForm(block) }
            return
        }

        let inputField = inputRow(symbol: "network-server-symbolic",   // Mac: server.rack
                                placeholder: kind == .emby ? translated("emby.beispiel.de")
                                                          : translated("jellyfin.beispiel.de"),
                                stretches: true)
        gtk_widget_set_margin_top(inputField, 26)
        gtk_editable_set_text(OpaquePointer(inputField), serverOnboardingAddress)
        append(block, inputField)
        // "Advanced": custom headers for a service in front of the server.
        let (advanced, reader) = advancedBuild(available: [])
        append(block, advanced)

        serverOnboardingState = label(serverOnboardingError, style: "swiftly-zweitzeile",
                                           wrap: true)
        gtk_widget_add_css_class(serverOnboardingState, "swiftly-warnung")
        gtk_label_set_xalign(OpaquePointer(serverOnboardingState), 0)
        gtk_widget_set_visible(serverOnboardingState, serverOnboardingError.isEmpty ? 0 : 1)
        gtk_widget_set_margin_top(serverOnboardingState, 12)
        append(block, serverOnboardingState)

        // Emby chosen but a Jellyfin answered: one click carries on as Jellyfin.
        let asJellyfin: Widget! = gtk_button_new_with_label(translated("Mit Jellyfin weiter"))
        gtk_widget_add_css_class(asJellyfin, "swiftly-umriss")
        gtk_widget_set_margin_top(asJellyfin, 12)
        gtk_widget_set_visible(asJellyfin, serverOnboardingNotEmby ? 1 : 0)
        serverOnboardingNotEmbyButton = asJellyfin
        signal(asJellyfin, "destroy") { [weak self] in self?.serverOnboardingNotEmbyButton = nil }
        append(block, asJellyfin)

        serverOnboardingButton = primaryButton(translated("Weiter"))
        let button: Widget! = serverOnboardingButton
        gtk_widget_set_margin_top(button, 22)
        // Mac `PrimaryButton`: `maxWidth: .infinity`, as wide as the field above it.
        gtk_widget_set_halign(button, GTK_ALIGN_FILL)
        gtk_widget_set_sensitive(button, serverOnboardingAddress.isEmpty ? 0 : 1)
        append(block, button)
        signal(asJellyfin, "clicked") { [weak self] in
            guard let self else { return }
            self.serverOnboardingKind = .jellyfin
            self.serverOnboardingNotEmby = false
            self.serverOnboardingErrorShow("")
            self.serverOnboardingNotEmbyShow()
            self.serverCheck(self.text(inputField))
        }

        let perform: () -> Void = { [weak self] in
            guard let self else { return }
            self.serverOnboardingHeaders = reader.headers()
            self.serverCheck(self.text(inputField))
        }
        signal(button, "clicked", perform)
        signal(inputField, "activate", perform)
        signal(inputField, "changed") { [weak self] in
            guard let self else { return }
            gtk_widget_set_sensitive(button, self.text(inputField).isEmpty ? 0 : 1)
        }

        // Without the servers already in the bundle: another account there is
        // "Weiteres Konto", not a new server.
        if newServer {
            let found = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
            append(block, found)
            foundOnOnboarding = found
            // The page is rebuilt on every step and dropped on leaving; the search must not
            // ask a destroyed widget whether it is on screen.
            signal(found, "destroy") { [weak self] in
                if self?.foundOnOnboarding == found { self?.foundOnOnboarding = nil }
            }
            foundServersFill()
        }

        // If the address was passed in there is nothing to type, so check right away.
        if serverOnboardingPreGiven, !serverOnboardingAddress.isEmpty {
            let address = serverOnboardingAddress
            onMainThread { [weak self] in self?.serverCheck(address) }
        }
    }

    /// Name and password for the **new** server.
    private func serverOnboardingForm(_ block: Widget!) {
        let name = inputRow(symbol: "avatar-default-symbolic",
                                placeholder: translated("Benutzername"), stretches: true)
        gtk_widget_set_margin_top(name, 26)
        append(block, name)

        let word = inputRow(symbol: "channel-secure-symbolic",
                                placeholder: translated("Passwort"), secret: true, stretches: true)
        gtk_widget_set_margin_top(word, 10)
        append(block, word)

        serverOnboardingState = label(serverOnboardingError, style: "swiftly-zweitzeile",
                                           wrap: true)
        gtk_widget_add_css_class(serverOnboardingState, "swiftly-warnung")
        gtk_label_set_xalign(OpaquePointer(serverOnboardingState), 0)
        gtk_widget_set_visible(serverOnboardingState, serverOnboardingError.isEmpty ? 0 : 1)
        gtk_widget_set_margin_top(serverOnboardingState, 12)
        append(block, serverOnboardingState)

        serverOnboardingButton = primaryButton(translated("Anmelden"))
        let button: Widget! = serverOnboardingButton
        gtk_widget_set_margin_top(button, 22)
        gtk_widget_set_sensitive(button, 0)
        append(block, button)

        let perform: () -> Void = { [weak self] in
            guard let self else { return }
            self.atNewServerSignIn(user: self.text(name), password: self.text(word))
        }
        signal(button, "clicked", perform)
        signal(word, "activate", perform)
        signal(name, "activate") { gtk_widget_grab_focus(word) }
        signal(name, "changed") { [weak self] in
            guard let self else { return }
            gtk_widget_set_sensitive(button, self.text(name).isEmpty ? 0 : 1)
        }

        // Quick Connect exists on Jellyfin only.
        guard serverOnboardingKind == .jellyfin else { return }
        append(block, separatorWithOr())

        let toggle: Widget! = gtk_button_new_with_label(translated("Mit Quick Connect anmelden"))
        gtk_widget_add_css_class(toggle, "swiftly-umriss")
        gtk_widget_set_margin_top(toggle, 18)
        signal(toggle, "clicked") { [weak self] in
            guard let self else { return }
            self.serverOnboardingError = ""
            self.accountPerCode = true
            self.subpageOpen(.serverOnboarding, push: .without)
        }
        append(block, toggle)
    }

    // MARK: Another account

    /// A second Jellyfin account on the same server.
    ///
    /// **Its own page, not the sign-in screen.** Reusing the sign-in looked like an
    /// error: wordmark and server name as on a restart, and the Quick Connect code in
    /// the row where error messages normally appear (orange, under the password field),
    /// so it read like a fault instead of an instruction.
    ///
    /// The model is `AccountAddView` in `Sources/macOS/ProfileView.swift`: header
    /// with back, one sentence saying what happens, the server as a **label** instead of
    /// a field, name and password as the normal path, Quick Connect as a toggle next to
    /// it, and the code in its own part.
    private func accountAddBuild(_ block: Widget!) {
        append(block, subpageHeader(translated("Weiteres Konto")))

        let sentence = label(translated("Ein zweites Jellyfin-Konto auf demselben Server. Beide bleiben angemeldet; oben auf der Profilseite wechselst du zwischen ihnen."),
                                style: "swiftly-koerper", wrap: true)
        gtk_widget_add_css_class(sentence, "dim-label")
        gtk_label_set_xalign(OpaquePointer(sentence), 0)
        gtk_label_set_justify(OpaquePointer(sentence), GTK_JUSTIFY_LEFT)
        gtk_widget_set_margin_top(sentence, 14)
        append(block, sentence)

        // **Where the account goes: a label, not a field.** An account belongs to exactly
        // one server; asking for it again would be a question whose answer is fixed.
        let serverRail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        gtk_widget_set_margin_top(serverRail, 22)
        let symbol: Widget! = gtk_image_new_from_icon_name("network-server-symbolic")
        gtk_widget_add_css_class(symbol, "swiftly-sehrleise")
        append(serverRail, symbol)
        var whereTo: [String] = []
        if !serverName.isEmpty { whereTo.append(serverName) }
        if let url = bundle?.serverURL { whereTo.append(url.absoluteString) }
        let serverRow2 = label(whereTo.joined(separator: " · "), style: "swiftly-zweitzeile")
        gtk_widget_add_css_class(serverRow2, "swiftly-sehrleise")
        gtk_widget_set_valign(serverRow2, GTK_ALIGN_CENTER)
        append(serverRail, serverRow2)
        append(block, serverRail)

        if accountPerCode { accountCodePart(block) } else { accountForm(block) }
    }

    /// Name and password, the normal path on the desktop.
    private func accountForm(_ block: Widget!) {
        let name = inputRow(symbol: "avatar-default-symbolic",
                                placeholder: translated("Benutzername"), stretches: true)
        gtk_widget_set_margin_top(name, 26)
        append(block, name)

        let word = inputRow(symbol: "channel-secure-symbolic",
                               placeholder: translated("Passwort"), secret: true, stretches: true)
        gtk_widget_set_margin_top(word, 10)
        append(block, word)

        // **"Expires in 4:58"**: the Mac shows the remaining time by the second
        // (`ProfileView.swift`, `ServerOnboardingView.swift`). Otherwise the five-minute limit
        // would run only as an internal counter, and the user would not know how long the
        // code is valid.
        accountRemainingField = label("", style: "swiftly-zweitzeile")
        gtk_widget_add_css_class(accountRemainingField, "swiftly-sehrleise")
        gtk_label_set_xalign(OpaquePointer(accountRemainingField), 0)
        gtk_widget_set_margin_top(accountRemainingField, 14)
        gtk_widget_set_visible(accountRemainingField, 0)
        append(block, accountRemainingField)

        accountStateField = label(accountError, style: "swiftly-zweitzeile", wrap: true)
        gtk_widget_add_css_class(accountStateField, "swiftly-warnung")
        gtk_label_set_xalign(OpaquePointer(accountStateField), 0)
        gtk_widget_set_visible(accountStateField, accountError.isEmpty ? 0 : 1)
        gtk_widget_set_margin_top(accountStateField, 12)
        append(block, accountStateField)

        accountButton = primaryButton(translated("Hinzufügen"))
        let button: Widget! = accountButton
        gtk_widget_set_margin_top(button, 22)
        gtk_widget_set_sensitive(button, 0)
        append(block, button)

        let perform: () -> Void = { [weak self] in
            guard let self else { return }
            self.accountSignIn(user: self.text(name), password: self.text(word))
        }
        signal(button, "clicked", perform)
        signal(word, "activate", perform)
        signal(name, "activate") { gtk_widget_grab_focus(word) }
        signal(name, "changed") { [weak self] in
            guard let self else { return }
            gtk_widget_set_sensitive(button, self.text(name).isEmpty ? 0 : 1)
        }

        append(block, separatorWithOr())

        let toggle: Widget! = gtk_button_new_with_label(translated("Mit Quick Connect anmelden"))
        gtk_widget_add_css_class(toggle, "swiftly-umriss")
        gtk_widget_set_margin_top(toggle, 18)
        signal(toggle, "clicked") { [weak self] in
            guard let self else { return }
            self.accountError = ""
            self.accountPerCode = true
            self.subpageOpen(.accountAdd, push: .without)
        }
        append(block, toggle)

        gtk_widget_grab_focus(name)
    }

    /// Quick Connect: **the code gets its own part.**
    ///
    /// It is also fetched only here, not when the page opens; otherwise every visit
    /// would request a code from the server that nobody needs.
    private func accountCodePart(_ block: Widget!) {
        let sentence = label(translated("Gib diesen Code in Jellyfin auf einem Gerät ein, an dem du schon angemeldet bist."),
                                style: "swiftly-zweitzeile", wrap: true)
        gtk_widget_add_css_class(sentence, "dim-label")
        gtk_label_set_xalign(OpaquePointer(sentence), 0)
        gtk_widget_set_margin_top(sentence, 26)
        append(block, sentence)

        // **One click copies the code to the clipboard.** Typing six digits that are
        // already in front of you is work an app can take over. Not on tvOS, which has no
        // clipboard.
        accountCodeField = label(accountCode.isEmpty ? "······" : accountCode,
                                     style: "swiftly-codegross")
        let codeButton: Widget! = gtk_button_new()
        gtk_widget_add_css_class(codeButton, "swiftly-blank")
        gtk_button_set_child(asButton(codeButton), accountCodeField)
        // **Full width.** Left-aligned it was only as wide as six digits; the Mac uses
        // `frame(maxWidth: .infinity)` (`ProfileView.swift`).
        gtk_widget_set_halign(codeButton, GTK_ALIGN_FILL)
        gtk_widget_set_hexpand(codeButton, 1)
        gtk_widget_set_margin_top(codeButton, 14)
        gtk_widget_set_tooltip_text(codeButton, translated("Code kopieren"))
        signal(codeButton, "clicked") { [weak self] in
            guard let self, !self.accountCode.isEmpty else { return }
            inClipboard(self.accountCode, an: codeButton)
            self.report(translated("Code kopiert."))
        }
        append(block, codeButton)

        accountStateField = label(accountError, style: "swiftly-zweitzeile", wrap: true)
        gtk_widget_add_css_class(accountStateField, "swiftly-warnung")
        gtk_label_set_xalign(OpaquePointer(accountStateField), 0)
        gtk_widget_set_visible(accountStateField, accountError.isEmpty ? 0 : 1)
        gtk_widget_set_margin_top(accountStateField, 14)
        append(block, accountStateField)

        let back: Widget! = gtk_button_new_with_label(translated("Lieber Name und Passwort"))
        gtk_widget_add_css_class(back, "swiftly-umriss")
        gtk_widget_set_margin_top(back, 22)
        signal(back, "clicked") { [weak self] in
            guard let self else { return }
            self.accountCodeRun?.cancel()
            self.accountCodeRun = nil
            self.accountCode = ""
            self.accountError = ""
            self.accountPerCode = false
            self.subpageOpen(.accountAdd, push: .without)
        }
        append(block, back)

        if accountCode.isEmpty && accountCodeRun == nil { accountCodeFetch() }
    }

    private func separatorWithOr() -> Widget! {
        let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_margin_top(rail, 18)
        let left: Widget! = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL)
        gtk_widget_set_hexpand(left, 1)
        gtk_widget_set_valign(left, GTK_ALIGN_CENTER)
        append(rail, left)
        let word = label(translated("oder"), style: "swiftly-zweitzeile")
        gtk_widget_add_css_class(word, "swiftly-sehrleise")
        append(rail, word)
        let right: Widget! = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL)
        gtk_widget_set_hexpand(right, 1)
        gtk_widget_set_valign(right, GTK_ALIGN_CENTER)
        append(rail, right)
        return rail
    }

}

// MARK: - Switching off never deletes anything unasked

extension App {

    /// **The question appears where the switch was flipped.**
    ///
    /// On the Mac it is a system dialog ("the question belongs to the window, not to a
    /// row in it"). This UI uses no system dialogs; introducing one would be a foreign
    /// body. The choices are the same three: keep, remove everything, cancel.
    func disablePromptShow() {
        guard downloadDisablePrompt != nil else { return }
        wipe(downloadDisablePrompt)

        let b = DownloadRules.allocation(downloads.entries)
        let text = String(format: translated("%d Titel liegen auf diesem Rechner (%@). Was soll damit geschehen?"),
                          b.count, DownloadRules.size(b.bytes))
        let l = label(text, style: "swiftly-zweitzeile", wrap: true)
        gtk_label_set_xalign(OpaquePointer(l), 0)
        append(downloadDisablePrompt, l)

        let buttons = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 10)

        let keep = chip(translated("Behalten"), active: true)
        signal(keep, "clicked") { [weak self] in
            guard let self else { return }
            self.selection.downloadsAn = false
            self.selection.secure()
            self.downloads.allHalt()
            self.mineFill()
            self.disablePromptDistance()
            self.subpageOpen(.settings)
        }
        append(buttons, keep)

        let distance = chip(translated("Alles entfernen"), symbol: "user-trash-symbolic")
        signal(distance, "clicked") { [weak self] in
            guard let self else { return }
            self.downloads.allRemove()
            self.selection.downloadsAn = false
            self.selection.secure()
            self.mineFill()
            self.disablePromptDistance()
            self.subpageOpen(.settings)
        }
        append(buttons, distance)

        let since = chip(translated("Abbrechen"))
        signal(since, "clicked") { [weak self] in
            // The switch already flipped on tap; whoever cancels wants it back.
            self?.disablePromptDistance()
            self?.subpageOpen(.settings)
        }
        append(buttons, since)

        append(downloadDisablePrompt, buttons)
        gtk_widget_set_visible(downloadDisablePrompt, 1)
    }

    func disablePromptDistance() {
        guard downloadDisablePrompt != nil else { return }
        wipe(downloadDisablePrompt)
        gtk_widget_set_visible(downloadDisablePrompt, 0)
    }
}


// MARK: - Update (Windows)

#if os(Windows)
extension App {

    /// **A row that shows its state.** Instead of searching for a label inside
    /// ``wertezeile(symbol:title:unter:value:accent:arrow:checkmark:auswahl:)`` afterwards,
    /// the row is rebuilt when something changes. That is cheaper than it sounds (it is
    /// one row) and keeps the presentation in one place.
    func updateRowFill() {
        guard let space = updateSpace else { return }
        wipe(space)

        switch updateStatus {
        case .unknown:
            append(space, valuesRow(symbol: "software-update-available-symbolic",
                                       title: translated("Nach Updates suchen"),
                                       under: translated("Swiftly fragt bei GitHub, ob es eine neuere Version gibt")) {
                [weak self] in self?.updateSearch()
            })

        case .hunts:
            append(space, valuesRow(symbol: "content-loading-symbolic",
                                       title: translated("Wird gesucht …")))

        case .current:
            append(space, valuesRow(symbol: "object-select-symbolic",
                                       title: translated("Swiftly ist aktuell"),
                                       under: Version.full) {
                [weak self] in self?.updateSearch()
            })

        case .new(let state):
            append(space, valuesRow(symbol: "software-update-available-symbolic",
                                       title: String(format: translated("Swiftly %@ ist da"), state.version),
                                       under: translated("Lädt den Installer und startet ihn. Swiftly beendet sich dabei."),
                                       accent: true) {
                [weak self] in self?.updateInPlay(state)
            })
            append(space, rowsLine())
            append(space, valuesRow(symbol: "text-x-generic-symbolic",
                                       title: translated("Was sich ändert"),
                                       under: firstOutNotes(state.notes)) {
                browser(URL(string: "https://github.com/paulherter/swiftly-player/releases/latest")!)
            })

        case .loads:
            append(space, valuesRow(symbol: "content-loading-symbolic",
                                       title: translated("Wird geladen …"),
                                       under: translated("Das dauert einen Moment. Swiftly startet den Installer von selbst.")))

        case .wentWrong(let reason):
            append(space, valuesRow(symbol: "dialog-warning-symbolic",
                                       title: translated("Hat nicht geklappt"),
                                       under: reason) {
                [weak self] in self?.updateSearch()
            })
        }
    }

    /// The first meaningful line of the release text. Headings and blank lines are no
    /// good as a preview.
    private func firstOutNotes(_ text: String) -> String {
        for row in text.split(separator: "\n") {
            let clean = row.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#*-• "))
            if clean.count > 12 { return String(clean.prefix(120)) }
        }
        return translated("Auf GitHub nachlesen")
    }

    func updateSearch() {
        updateStatus = .hunts
        updateRowFill()
        Task.detached { [self] in
            do {
                let state = try await Update.searching()
                onMainThread {
                    self.updateStatus = state.map { .new($0) } ?? .current
                    AppLog.writeOut("[Update] " + (state.map { "neu: \($0.version)" } ?? "aktuell"))
                    self.updateRowFill()
                }
            } catch Update.Failure.noInstaller {
                // **A release without installer is not a release yet.** Between creating it on
                // GitHub and uploading the `-setup.exe` a few minutes pass; during that time the
                // row said "GitHub is not responding", which is wrong and nothing the user can fix.
                onMainThread {
                    self.updateStatus = .current
                    AppLog.writeOut("[Update] neue Fassung ohne Installer, gilt als aktuell")
                    self.updateRowFill()
                }
            } catch {
                onMainThread {
                    self.updateStatus = .wentWrong(translated("GitHub antwortet nicht."))
                    AppLog.writeOut("[Update] Suche fehlgeschlagen: \(error)")
                    self.updateRowFill()
                }
            }
        }
    }

    func updateInPlay(_ state: Update.Snapshot) {
        updateStatus = .loads
        updateRowFill()
        Task.detached { [self] in
            do {
                let file = try await Update.fetch(state)
                onMainThread {
                    do {
                        try Update.inPlay(file)
                        AppLog.writeOut("[Update] Installer gestartet, Swiftly beendet sich")
                        // The installer cannot replace a running `Swiftly.exe`, so make room.
                        exit(0)
                    } catch {
                        self.updateStatus = .wentWrong(translated("Der Installer ließ sich nicht starten."))
                        self.updateRowFill()
                    }
                }
            } catch {
                onMainThread {
                    self.updateStatus = .wentWrong(translated("Das Herunterladen ist abgebrochen."))
                    AppLog.writeOut("[Update] Herunterladen fehlgeschlagen: \(error)")
                    self.updateRowFill()
                }
            }
        }
    }
}
#endif
