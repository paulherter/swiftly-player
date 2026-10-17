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

    enum Subpage: Hashable { case profile, quickConnect, playback, seerr, trakt, settings, accountAdd, serverOnboarding, presentation, genreSelection, librarySelection, licenses, licenseText(String) }

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
        let formSheet: Set<Subpage> = [.serverOnboarding, .accountAdd, .quickConnect,
                                          .profile, .seerr, .trakt]
        if twoColumned.contains(was) {
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
        case .trakt:          traktPageBuild(block)
        case .settings:  settingsBuild(block)
        case .accountAdd: accountAddBuild(block)
        case .serverOnboarding:   serverOnboardingBuild(block)
        case .presentation:      presentationBuild(block)
        case .genreSelection:        genreSelectionBuild(block)
        case .librarySelection:  librarySelectionBuild(block)
        case .licenses:         licensesBuild(block)
        case .licenseText(let id): licenseTextBuild(block, id: id)
        }

        let scroller = pagesScroller()
        gtk_scrolled_window_set_child(OpaquePointer(scroller), block)
        // Settings: **each column ends at `formWidth`** (`SettingsView.swift`),
        // i.e. two columns plus 48 spacing.
        if was == .settings {
            cap(block, in: scroller, on: Theme.formWidth * 2 + Theme.edgeSpacing * 2)
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
        } else {
            subpageOpen(.profile, push: .back)
        }
    }

    // MARK: Profile

    private func profileBuild(_ block: Widget!) {
        // **With title.** It carries the header like every other subpage
        // (`ProfileView.swift`), flush with the cards.
        append(block, subpageHeader(translated("Profil")))

        let imageBlock = stack(GTK_ORIENTATION_VERTICAL, spacing: 14)
        // 10 above, 20 below (`Sources/macOS/ProfileView.swift`).
        gtk_widget_set_margin_top(imageBlock, 10)
        gtk_widget_set_margin_bottom(imageBlock, 20)
        append(imageBlock, accountsCards())
        append(block, imageBlock)

        let g1 = rowsGroup()
        append(g1.space, valuesRow(symbol: "dialog-password-symbolic", title: translated("Quick Connect"),
                                      under: translated("Code vom Fernseher eingeben"),
                                      accent: true, arrow: true) { [weak self] in
            self?.subpageOpen(.quickConnect)
        })
        append(block, g1.outer)

        // 18 between the groups (`Sources/macOS/ProfileView.swift`).
        append(block, paddingHigh(18))

        let g2 = rowsGroup()
        append(g2.space, valuesRow(symbol: "media-playback-start-symbolic",
                                      title: translated("Wiedergabe"),
                                      under: translated("Sprache, Untertitel, Tempo"),
                                      arrow: true) { [weak self] in
            self?.subpageOpen(.playback)
        })
        append(g2.space, rowsLine())
        // Between playback and settings, the Mac's order.
        append(g2.space, valuesRow(symbol: "view-app-grid-symbolic",
                                      title: translated("Darstellung"),
                                      under: translated("Startseite, Reihen, Genres"),
                                      arrow: true) { [weak self] in
            self?.subpageOpen(.presentation)
        })
        append(g2.space, rowsLine())
        append(g2.space, valuesRow(symbol: "emblem-system-symbolic",
                                      title: translated("Einstellungen"), arrow: true) { [weak self] in
            self?.subpageOpen(.settings)
        })
        append(block, g2.outer)

        append(block, paddingHigh(18))

        let g3 = rowsGroup()
        // **"Add another account" is not here.** The plus in the account card does the
        // same, right where the accounts are.
        //
        // **"Add server" is here**, and that is different: a second Jellyfin with its own
        // accounts, not a second account on the same one.
        append(g3.space, valuesRow(symbol: "network-server-symbolic",
                                      title: translated("Server hinzufügen"),
                                      under: translated("Ein zweiter Jellyfin, eigene Konten"),
                                      arrow: true) { [weak self] in
            self?.serverOnboardingOpen(nil)
        })
        append(g3.space, rowsLine())
        append(g3.space, valuesRow(symbol: "application-exit-symbolic",
                                      title: translated("Abmelden")) { [weak self] in
            self?.signOff()
        })
        append(block, g3.outer)

        append(block, paddingHigh(18))

        // **Rate, Discord, report a bug: at the very bottom**, below server and sign out.
        // (In settings they were hardly noticed.)
        // **No "rate":** there is no store where a rating could land. The URLs live in
        // the package.
        let g4 = rowsGroup()
        append(g4.space, valuesRow(symbol: "user-available-symbolic",
                                      title: translated("Discord beitreten"),
                                      under: translated("Fragen stellen und sagen, was fehlt")) {
            browser(Community.discord)
        })
        append(g4.space, rowsLine())
        append(g4.space, valuesRow(symbol: "dialog-warning-symbolic",
                                      title: translated("Fehler melden"),
                                      under: translated("Auf GitHub, deine App-Version ist schon eingetragen")) {
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
                                      title: translated("Protokoll teilen"),
                                      under: translated("Die letzte Stunde, ohne Zugangsdaten")) {
            guard let file = LogFile.write() else { return }
            fileManagerShow(file)
        })
        // **Required, not decoration:** libVLC is LGPL, which requires the license text,
        // authors and source inside the app itself.
        append(g4.space, rowsLine())
        append(g4.space, valuesRow(symbol: "text-x-generic-symbolic",
                                      title: translated("Open-Source-Lizenzen"),
                                      under: translated("Was in Swiftly steckt und woher der Quelltext kommt"),
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
        append(block, g4.outer)

        let footer = label(Version.full, style: "swiftly-zweitzeile")
        gtk_widget_add_css_class(footer, "swiftly-fuss")
        gtk_label_set_xalign(OpaquePointer(footer), 0)
        gtk_widget_set_margin_top(footer, 26)
        append(block, footer)
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
                do { try await client.quickConnectShare(code: code); good = true }
                catch { good = false }
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
        let q = settingGroup(translated("Qualität"))
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
        append(left, sp.outer)

        // MARK: Behavior
        let v = settingGroup(translated("Verhalten"))
        append(v.space, toggleRow(symbol: "media-skip-forward-symbolic",
                                        title: translated("Nächste Folge automatisch"),
                                        an: nextAutomatic) { [weak self] an in
            self?.selection.nextAutomaticSelected = an
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
        append(block, subpageHeader(translated("Einstellungen")))

        // "Lock landscape in the player" does **not** exist here: a window has no
        // orientation to lock. A setting without a counterpart, not an omission.
        // **"Appearance" is its own page**, reached from the profile, as on the Mac
        // (`ProfileView.swift`). Keeping it as a group inside settings would put the same
        // settings in two places in different forms.

        // **Two columns, like the Mac** (`SettingsView.swift`): left, offline and
        // integration; right, server. One narrow 560 pt column would look like a phone view
        // in the middle of a wide window.
        let (left, right) = twoColumn(in: block)

        let o = settingGroup(translated("Offline"))
        append(o.space, toggleRow(symbol: "folder-download-symbolic",
                                        title: translated("Downloads"),
                                        under: translated("Titel auf diesen Rechner laden und offline schauen"),
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
            append(o.space, valuesRow(symbol: "drive-harddisk-symbolic",
                                         title: translated("Speicher"),
                                         under: numberWord(downloads.entries.count,
                                                         one: translated("1 Titel auf diesem Rechner"),
                                                         many: translated("%d Titel auf diesem Rechner")),
                                         value: DownloadRules.size(b.bytes)))
        }
        append(left, o.outer)

        // **Sits between offline and server, on purpose.** It is a second service, not a
        // second server, and an extra: whoever connects nothing sees nothing of it besides
        // this one row. Same reasoning as on the Mac (`SettingsView.integration`).
        let i = settingGroup(translated("Integration"))
        append(i.space, valuesRow(symbol: "edit-find-symbolic",
                                     title: translated("Seerr"),
                                     under: translated("Anfragen, was noch nicht da ist"),
                                     value: seerrPresent ? translated("Verbunden") : nil,
                                     // Value **or** arrow, not both, as on the Mac.
                                     arrow: !seerrPresent) { [weak self] in
            self?.subpageOpen(.seerr)
        })
        // Trakt next to Seerr; only with credentials in the build (`Trakt.swift`).
        traktRow(i.space)
        // **Here and not under "Playback".** The rows there say *how* something runs;
        // this one is the only one that gives something to the outside. It belongs next to
        // the other external service.
        append(i.space, rowsLine())
        append(i.space, toggleRow(symbol: "user-available-symbolic",
                                        title: translated("Discord"),
                                        under: translated("Zeigt im Profil, was gerade läuft"),
                                        an: selection.discordShow) { [weak self] an in
            guard let self else { return }
            self.selection.discordShow = an
            self.selection.secure()
            if !an { DiscordState.tidyAway() }
        })
        append(left, i.outer)

        let s = settingGroup(translated("Server"))
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
                                    under: running ? nil : checkResult,
                                    value: running ? checkResult : nil,
                                    pick: running ? nil : { [weak self] in
                                        self?.connectionCheck()
                                    })
        append(s.space, checkRow)
        append(right, s.outer)
        append(right, ownHeadersBuild())

        let footer = label("\(Version.full) · libVLC \(VLCVersion.text)",
                                style: "swiftly-zweitzeile")
        gtk_widget_add_css_class(footer, "swiftly-fuss")
        gtk_label_set_xalign(OpaquePointer(footer), 0)
        gtk_widget_set_margin_top(footer, 26)
        append(block, footer)
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

    private func subpageArrow() -> Widget! {
        let arrow: Widget! = gtk_button_new()
        gtk_widget_add_css_class(arrow, "swiftly-zurueck")
        caption(arrow, translated("Zurück"))
        gtk_button_set_child(asButton(arrow),
                             gtk_image_new_from_icon_name("go-previous-symbolic"))
        gtk_widget_set_halign(arrow, GTK_ALIGN_START)
        // No negative margin: GTK does not allow it. The arrow already sits within the
        // block's 24 margin.
        gtk_widget_set_margin_start(arrow, 0)
        signal(arrow, "clicked") { [weak self] in self?.subpageBack() }
        return arrow
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
        append(rail, subpageArrow())
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
        guard let bundle else { return column }
        let server = bundle.server.sorted { a, _ in isActiveServer(a) }
        if server.isEmpty {
            append(column, accountCard(nil, bundle: bundle))
        } else {
            for url in server { append(column, accountCard(url, bundle: bundle)) }
        }
        return column
    }

    private func isActiveServer(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.absoluteString.lowercased()
            == bundle?.activeOne.serverURL.absoluteString.lowercased()
    }

    private func accountCard(_ server: URL?, bundle: AccountBundle) -> Widget! {
        let all = server.map { bundle.accounts(on: $0) } ?? bundle.accounts
        let active = isActiveServer(server)
        // On the connected server the signed-in account comes first; on another server the
        // first account there, and a click switches to it.
        let front: Session? = active ? bundle.activeOne : all.first
        let other = all.filter { $0.accountKey != front?.accountKey }

        let card = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_add_css_class(card, "swiftly-kontokarte")
        // **Accent border only when there is something to distinguish.** With a single
        // server it would be a highlight without a counterpart.
        if active, bundle.server.count > 1 {
            gtk_widget_add_css_class(card, "swiftly-aktiv")
        }
        append(card, cardsHeader(front, active: active, server: server))
        let stroke: Widget! = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
        gtk_widget_add_css_class(stroke, "swiftly-trennlinie")
        gtk_widget_set_size_request(stroke, -1, 1)
        append(card, stroke)
        append(card, cardsRail(other, active: active, server: server))
        return card
    }

    /// Avatar 56, next to it name, server and version. On another server the whole row
    /// is a button, on the connected one plain text.
    private func cardsHeader(_ account: Session?, active: Bool, server: URL?) -> Widget! {
        let row = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 14)
        gtk_widget_set_margin_start(row, 16)
        gtk_widget_set_margin_end(row, 16)
        gtk_widget_set_margin_top(row, 16)
        gtk_widget_set_margin_bottom(row, 16)

        let moreCompartment = (bundle?.server.count ?? 0) > 1
        let parts = profileCharacter(name: account?.userName ?? "?", border: 56,
                                  style: active && moreCompartment ? "swiftly-kontoaktiv"
                                                          : "swiftly-profilgross",
                                  fontStyle: "swiftly-zeichen72")
        append(row, parts.wrapper)
        if let account {
            profileImageLoad(parts, url: addresses?.user(account.userID, border: 200),
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
        // others the address is shown.
        let second = active ? (serverName.isEmpty ? (server?.host() ?? "") : serverName)
                           : (server?.host() ?? "")
        let z = label(second, style: "swiftly-zweitzeile")
        gtk_widget_add_css_class(z, "swiftly-leise")
        gtk_label_set_xalign(OpaquePointer(z), 0)
        gtk_label_set_ellipsize(OpaquePointer(z), PANGO_ELLIPSIZE_END)
        append(texts, z)

        if active, !serverVersion.isEmpty {
            let f = label("Jellyfin \(serverVersion)", style: "swiftly-zweitzeile")
            gtk_widget_add_css_class(f, "swiftly-leise")
            gtk_label_set_xalign(OpaquePointer(f), 0)
            append(texts, f)
        } else if !active {
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
    private func cardsRail(_ other: [Session], active: Bool, server: URL?) -> Widget! {
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
            profileImageLoad(parts, url: addresses?.user(account.userID, border: 200),
                            key: "konto-\(account.userID)")
            let key = account.accountKey
            let image = parts.wrapper
            signal(button, "clicked") { [weak self] in
                self?.accountSwitchWithTransition(toward: key, account: account, from: image)
            }
            append(rail, button)
        }

        // **The plus is on every card** and adds an account on *this* server. On the
        // connected one it is the usual sign-in; on another one it is the same as when
        // adding a server, with the address already filled in.
        let plus: Widget! = gtk_button_new()
        gtk_widget_add_css_class(plus, "swiftly-kontoplus")
        gtk_widget_set_size_request(plus, 40, 40)
        gtk_button_set_child(asButton(plus), gtk_image_new_from_icon_name("list-add-symbolic"))
        gtk_widget_set_tooltip_text(plus, translated("Weiteres Konto hinzufügen"))
        caption(plus, translated("Weiteres Konto hinzufügen"))
        signal(plus, "clicked") { [weak self] in
            guard let self else { return }
            if active { self.subpageOpen(.accountAdd) }
            else if let server { self.serverOnboardingOpen(server) }
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
        append(ga.space, toggleRow(symbol: "format-text-bold-symbolic",
                                         title: translated("Titel als Logo"),
                                         under: translated("Auf Film- und Serienseiten, wenn dein Server eins hat"),
                                         an: selection.titleAsLogo) { [weak self] an in
            self?.selection.titleAsLogo = an
            self?.selection.secure()
        })
        append(left, ga.outer)
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
        let g0 = settingGroup(translated("Reihen"))
        let visible = StartRailsEpisode.applicable(stored: selection.startRails)
            .filter { $0.fits(disconnected: selection.newArrivalsDisconnected) }
        for (spot, rail) in visible.enumerated() {
            if spot > 0 { append(g0.space, rowsLine()) }
            append(g0.space, railsRow(rail, spot: spot, from: visible.count))
        }
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
        // **Between the fixed rows and the genres**, as on Apple: custom rows from the
        // server, reorderable only among themselves.
        let gb = settingGroup(translated("Bibliotheken und Sammlungen"))
        let choice = selection.startLibraries
        for (spot, entryRecord) in choice.enumerated() {
            if spot > 0 { append(gb.space, rowsLine()) }
            append(gb.space, libraryRow(entryRecord, spot: spot, from: choice.count))
        }
        if !choice.isEmpty { append(gb.space, divider()) }
        append(gb.space, valuesRow(symbol: "list-add-symbolic",
                                      title: translated("Bibliothek hinzufügen"),
                                      accent: true,
                                      arrow: true) { [weak self] in
            self?.subpageOpen(.librarySelection)
        })
        append(right, gb.outer)
        append(right, paddingHigh(26))

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
            self?.railMove(rail, um: -1)
        }
        append(row, up)
        let down = listArrow("go-down-symbolic", name: translated("Nach unten"), an: spot < from - 1) { [weak self] in
            self?.railMove(rail, um: 1)
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

    private func railMove(_ rail: StartRail, um step: Int) {
        selection.startRails = StartRailsEpisode.shifted(rail, um: step,
                                                         stored: selection.startRails,
                                                         disconnected: selection.newArrivalsDisconnected)
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
            self?.libraryMove(entryRecord.id, um: -1)
        })
        append(row, listArrow("go-down-symbolic", name: translated("Nach unten"), an: spot < from - 1) { [weak self] in
            self?.libraryMove(entryRecord.id, um: 1)
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

    private func libraryMove(_ id: String, um step: Int) {
        var list = selection.startLibraries
        guard let from = list.firstIndex(where: { $0.id == id }) else { return }
        let to = from + step
        guard to >= 0, to < list.count else { return }
        let e = list.remove(at: from)
        list.insert(e, at: to)
        selection.startLibraries = list
        selection.secure()
        loaded.remove(.start)
        subpageOpen(.presentation, push: .without)
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
        let container = held(space)
        Task.detached { [self] in
            let all = (try? await client.genres()) ?? []
            onMainThread {
                defer { letGo(container) }
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
                    append(container.widget, valuesRow(symbol: "tag-symbolic", title: name) {
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
        accountPerCode = false
        subpageOpen(.serverOnboarding)
    }

    /// **Check the address, then sign in: in the window, not as a sheet.**
    ///
    /// On the Mac both are stacked on one page (`macOS/ServerOnboardingView.swift`), and
    /// the reason applies here too: a sheet over a half-filled form would hide which
    /// server one is signing in to.
    private func serverOnboardingBuild(_ block: Widget!) {
        let newServer = !serverOnboardingPreGiven
        append(block, subpageHeader(newServer ? translated("Server hinzufügen")
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

        let inputField = inputRow(symbol: "network-server-symbolic",
                                placeholder: translated("jellyfin.beispiel.de"), stretches: true)
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

        serverOnboardingButton = primaryButton(translated("Weiter"))
        let button: Widget! = serverOnboardingButton
        gtk_widget_set_margin_top(button, 22)
        gtk_widget_set_sensitive(button, serverOnboardingAddress.isEmpty ? 0 : 1)
        append(block, button)

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
