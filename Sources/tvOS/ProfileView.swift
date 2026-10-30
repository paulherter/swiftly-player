import JellyfinKit
import SwiftUI

/// Profile and settings.
///
/// **Two columns: the areas on the left, their rows on the right.** This is how
/// Apple's own tvOS settings are built, and the reason is the path: one long list
/// forces you to wander through it, and three columns of chips side by side are
/// not a structure but a shelf.
///
/// The groups are those of the iPhone version, where they are three pages in a
/// row (Profile, Settings, Playback). Here they sit side by side because there is
/// width and every saved jump counts on a remote.
struct ProfileView: View {
    @AppStorage("bildrateAnpassen") private var frameRateAdapt = true
    @AppStorage("introAbspannAuto") private var skipAutomatic = false
    let model: AppModel

    @State private var section: SectionSelection = .playback
    /// Which value row currently shows its choice.
    @State private var opened: String?
    @AppStorage("titelAlsLogo") private var titleAsLogo = false
    @State private var verification: String?
    /// Shows Quick Connect to add another account.
    @State private var accountRecord = false
    /// A second Jellyfin: address, then Quick Connect.
    @State private var serverRecord = false
    /// Custom headers of the active server (issue #4).
    @State private var ownHeaders = false
    /// Connect Seerr, as a page of its own above everything: three fields and an
    /// on-screen keyboard need room that a row does not have.
    @State private var seerrOpen = false
    /// Connect Trakt: the code and QR code need the same full page.
    @State private var traktOpen = false
    @State private var communityTarget: CommunityTarget?
    /// Open-source licenses: full page, building blocks on the left, text on the right.
    @State private var licensesOpen = false
    /// Support page and icon picker: a local flag, so the root's `presented` cover
    /// is the only one bound to the model.
    @State private var supportStart: TVSupportView.Start?

    /// **Look first, then go in.** When focus moves through the areas on the left,
    /// the right side already shows the respective one, dimmed so it is clear you are
    /// not in yet. OK goes in, and focus then lands on the top row. Back returns to
    /// the same area on the left; only a second Back leaves the page.
    ///
    /// Before, the press switched the area and everything on the right was focusable
    /// at once: a step right landed somewhere in the list, geometrically, and the way
    /// back only worked with Left, because Back left the whole page immediately.
    @FocusState private var left: SectionSelection?
    @State private var inside = false
    @FocusState private var right: RightTarget?
    /// Only the top row on the right is jumped to deliberately; all others carry
    /// `.proceed` so they have the same binding.
    private enum RightTarget { case top, proceed }

    /// All genres the server knows, for "Add genre".
    @State private var allGenres: [String] = []
    /// **"None open" was a lie when the server had not answered.** A settings row has
    /// no room for a full-page notice, but its value can show the same wording as
    /// everywhere else.
    @State private var genresDisturbed = false

    /// Libraries and collections of the server, for "Add library".
    @State private var allLibraries: [Item] = []
    private var freeLibraries: [Item] {
        allLibraries.filter { b in !model.startLibraries.contains { $0.id == b.id } }
    }

    /// Moves a selected library by one position.
    private func move(_ entryRecord: StartLibrary, um step: Int) {
        guard let from = model.startLibraries.firstIndex(of: entryRecord) else { return }
        let to = from + step
        guard model.startLibraries.indices.contains(to) else { return }
        withAnimation(Theme.reveal) { model.startLibraries.swapAt(from, to) }
    }

    private var freeGenres: [String] {
        allGenres.filter { !model.startGenres.contains($0) }
    }

    /// Which fixed rows exist: new movies and shows separately, or the combined one.
    private var visibleRails: [StartRail] {
        model.startRails.filter { $0.fits(disconnected: model.newAccessDisconnected) }
    }

    /// Moving happens in the visible list. What is not shown at the moment (the
    /// combined row when separate, or the reverse) is appended at the end and comes
    /// back there when toggled.
    private func move(_ rail: StartRail, um step: Int) {
        var visible = visibleRails
        guard let from = visible.firstIndex(of: rail) else { return }
        let to = from + step
        guard visible.indices.contains(to) else { return }
        withAnimation(Theme.reveal) {
            visible.swapAt(from, to)
            model.startRails = visible + model.startRails.filter { !visible.contains($0) }
        }
    }

    enum SectionSelection: String, CaseIterable, Identifiable {
        case playback = "wiedergabe", languages = "sprachen", presentation = "darstellung", integration, server, account = "konto", community = "gemeinschaft"
        var id: String { rawValue }
        var name: LocalizedStringKey {
            switch self {
            case .playback:  "Wiedergabe"
            case .languages:    "Sprachen"
            case .presentation: "Darstellung"
            case .integration: "Integration"
            case .server:      "Server"
            case .account:       "Konto"
            case .community: "Swiftly"
            }
        }
    }

    var body: some View {
        page
            // **Come back collapsed.** Otherwise leaving settings and returning later would
            // show the previous choice still open, and a half-expanded list looks like a
            // state you left behind without knowing.
            .onDisappear { opened = nil }
            // **If the page opens in the middle of an account switch** (focus then sits on
            // the profile picture at the top, a press opens the page again), finish the
            // switch immediately: new account active, picture in place. As on the iPhone,
            // `AccountSwitchTransition.complete`.
            .onAppear {
                AccountSwitchTransition.shared.complete()
                AccountSwitchTransition.note("profil offen: angemeldet \(model.session?.userName ?? "-")")
            }
            // Same when changing area: the row that was open does not exist on the new page.
            .onChange(of: section) { _, _ in opened = nil }
            .onChange(of: left) { _, new in
                guard let new else { return }
                section = new
                inside = false
            }
            .defaultFocus($left, section)
            // Once per visit: the server's genre list for "Add genre".
            .task {
                let fetched = await model.genres()
                genresDisturbed = fetched == nil
                if let fetched { allGenres = fetched }
                allLibraries = await model.startSelection()
            }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            // **No header above the columns.** The account stands on the left above the
            // areas: the left is what you choose (who, and which area), the right is what
            // you set. That way the right column starts at the top and all eight "Playback"
            // rows are visible without scrolling.
            HStack(alignment: .top, spacing: 72) {
                VStack(alignment: .leading, spacing: 0) {
                    accountBlock
                    // **A line instead of a second box.** It says where "who" ends and "where"
                    // begins. A box would say the same but look like the list below and the card on
                    // the right.
                    SheetLine()
                        .padding(.leading, 26)
                        .padding(.vertical, 32)
                    GroupsTitle(text: "Bereiche")
                    ForEach(SectionSelection.allCases) { b in
                        Button(b.name) {
                            section = b
                            toInGo()
                        }
                        .buttonStyle(SectionStyle(an: section == b, rests: inside))
                        .focused($left, equals: b)
                    }
                }
                // **Full height, because of the focus engine.** It moves focus only when
                // something focusable *adjoins* in the pressed direction. The column was only as
                // tall as its content; when a value row on the right expands lower than that
                // height ("Skip" is the second), nothing is left of the chips and Left did
                // nothing. Focus was stuck.
                //
                // Nothing changes visibly: the content stays at the top, only the section now
                // reaches the bottom.
                .frame(width: 460, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .focusSection()

                // **The reader is the whole motion.** When a row expands it is scrolled here,
                // and the scrolling itself is the soft movement tvOS brings anyway. Moving the
                // column by hand was hard and had to guess the height of the choice. Nothing is
                // guessed here: the list is as long as it is, and the reader brings the expanded
                // row into view.
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            GroupsTitle(text: section.name)
                            // **On a card, as on iPhone, iPad and Mac.**
                            //
                            // **Clipped to the card, otherwise the names stand in front of their box.** When
                            // a value row expands, card and list grow to the new height over 0.28 s, but the
                            // inserted names are fully there at once with their own, unanimated height.
                            // Without a mask they draw past the lower edge of the still-small card and stand
                            // on the bare background for a moment.
                            //
                            // The clip hangs on the same surface as the fill, so on the same growing height:
                            // the content opens with the box. It comes before the fill, not after, otherwise
                            // it would cut away the fill too and the card would have no reason left.
                            VStack(alignment: .leading, spacing: 0) { rows }
                                .padding(10)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerTile, style: .continuous))
                                .background(Theme.area,
                                            in: RoundedRectangle(cornerRadius: Theme.cornerTile, style: .continuous))
                        }
                    }
                    .scrollIndicators(.hidden)
                    .scrollClipDisabled()
                    .onChange(of: opened) { _, new in
                        guard let new else { return }
                        // Same curve and duration as the expansion, otherwise two motions run against
                        // each other.
                        withAnimation(Theme.motion(.easeInOut(duration: 0.28))) {
                            reader.scrollTo(new, anchor: .top)
                        }
                    }
                }
                // Dimmed means: visible but not active yet. Disabled so that a step right does
                // not already lead in; OK goes in.
                .opacity(inside ? 1 : 0.5)
                .disabled(!inside)
                .focusSection()
                .onExitCommand {
                    inside = false
                    left = section
                }
                // **The safety net under the jump to the right.** `toInGo` sets focus one
                // run later, because the column is still disabled in the same run. If it still
                // has not taken effect one run later, this catches it: `onChange` runs when the
                // new state stands and sets focus again if nothing on the right has it. Setting
                // the same thing twice does no harm.
                .onChange(of: inside) { _, now in
                    if now, right == nil { right = .top }
                }
                .animation(Theme.motion(.easeInOut(duration: 0.2)), value: inside)
            }
        }
        .padding(.horizontal, Theme.edgePage)
        .padding(.vertical, Theme.edgeTop)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .top) {
            if let verification {
                HintStrip(text: verification) { self.verification = nil }
                    .padding(.top, Theme.edgeTop)
            }
        }
        // Side margin: see `HomeView`. The system margin is removed so `edgePage` does
        // not sit on top of it and double.
        .ignoresSafeArea(edges: .horizontal)
        // The look's glow, the same on every main page; the page itself does not scroll.
        .background(alignment: .top) { LookGlowLayer() }
        // **Quick Connect, not a new sign-in form.** A name and password on a remote are
        // an imposition. The code exists anyway, and `sessionAdopt` adds the
        // session to the existing account instead of replacing it.
        .fullScreenCover(isPresented: $accountRecord) {
            QuickConnectView(model: model) { accountRecord = false }
        }
        .fullScreenCover(isPresented: $ownHeaders) {
            TVOwnHeadersPage(model: model) { ownHeaders = false }
        }
        .fullScreenCover(isPresented: $serverRecord) {
            ServerOnboardingView(model: model) { serverRecord = false }
        }
        .fullScreenCover(isPresented: $seerrOpen) {
            SeerrConnectView(model: model, seerr: model.seerr) { seerrOpen = false }
        }
        .fullScreenCover(isPresented: $traktOpen) {
            TraktConnectView(trakt: model.trakt) { traktOpen = false }
        }
        .fullScreenCover(item: $communityTarget) { target in
            CodeSheet(target: target) { communityTarget = nil }
        }
        .fullScreenCover(isPresented: $licensesOpen) {
            TVLicensesView { licensesOpen = false }
        }
        .fullScreenCover(item: $supportStart) { start in
            TVSupportView(start: start) { supportStart = nil }
        }
    }

    /// Go in on the right, focus on the top row.
    ///
    /// **One run later.** In the same run the right column is still disabled, and
    /// focus on something disabled goes nowhere.
    private func toInGo() {
        inside = true
        DispatchQueue.main.async { right = .top }
    }

    // MARK: Account

    /// **Who is signed in, without a box around it.**
    ///
    /// It used to be a card with the same fill, corner and padding as the settings
    /// card on the right, directly above the area list whose selected entry is also a
    /// filled, rounded box. Three filled boxes in one picture for three different
    /// things: who you are, where you are, what you set.
    ///
    /// **Not everything is a card.** The list on the right is one: it is the object
    /// you work on, and now the only filled box on the page. On the left the same
    /// content stands free on the background, on the same edge as "Areas" and the
    /// area names: 26. What the card gave in cohesion is now carried by spacing and a
    /// line.
    ///
    /// **The profile stays the first reach.** Whoever opens settings mostly wants to
    /// switch account, so the account strip stays at the very top and not in the
    /// "Account" area.
    private var accountBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProfileCharacter(name: model.session?.userName ?? "?",
                          image: model.userImageURL(),
                          size: 84)
                .modifier(TVSupporterAvatarBadge(size: 84))
            Text(model.session?.userName ?? "—")
                // Row heading from the ladder.
                .font(Theme.rail)
                .tracking(Theme.lockRail)
                .foregroundStyle(Theme.font)
                .lineLimit(1)
                .padding(.top, 18)
            // Server data, not catalog text.
            Text(verbatim: serverRow)
                .font(Theme.small)
                .foregroundStyle(Theme.fontQuiet)
                .lineLimit(1)
                .padding(.top, 4)
            // The line that was here separated name from accounts inside the card. Without
            // the card it would be the second in a column that needs one, and the one is
            // further down, before "Areas". The accounts belong to the name above.
            AccountsStrip(model: model) { accountRecord = true }
                .padding(.top, 28)
        }
        .padding(.leading, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var serverRow: String {
        [model.serverName, model.serverVersion].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Rows per area

    @ViewBuilder
    private var rows: some View {
        switch section {
        case .playback:
            // If the server does not transcode there is nothing to choose: Direct Play is
            // fixed on, bitrate is disabled, as on the other versions.
            let free = model.convertAllowed
            let directPlay = model.alwaysDirectPlay || !free
            // **The anchor hangs on the topmost row that is actually available.** It was
            // fixed on this one, which is disabled when the server forbids transcoding.
            // Focus on something disabled goes nowhere, so it stayed on the left: OK on
            // "Playback" did nothing visible, while it worked in all seven other areas,
            // whose top row is never disabled.
            //
            // If it is disabled here, Direct Play and bitrate move out together
            // (`directPlay` is then fixed on) and "Buffer" is the first row you can touch.
            ToggleRow(title: "Immer Direct Play", an: directPlay) {
                model.alwaysDirectPlay.toggle()
            }
            .disabled(!free)
            .focused($right, equals: free ? .top : .proceed)
            SeparatorLine()
            valueRow("Höchste Bitrate", value: Bitrate.text(model.bitratesLimit),
                      entries: Bitrate.levels, label: { Bitrate.text($0.value) },
                      an: { $0.value == model.bitratesLimit },
                      select: { model.bitratesLimit = $0.value })
            .disabled(directPlay)
            SeparatorLine()
            // **Sits next to the bitrate because it is the same kind of decision:** what the
            // viewer knows about their connection and the app cannot measure.
            //
            // The labels come from `BufferLevel.name` and so from the package catalog.
            // Nothing is rebuilt here, otherwise the same three words would stand in two
            // catalogs and drift apart.
            valueRow("Puffer", value: model.bufferLevel.name,
                      entries: BufferLevel.allCases, label: \.name,
                      an: { $0 == model.bufferLevel },
                      select: { model.bufferLevel = $0 })
            .focused($right, equals: free ? .proceed : .top)
            SeparatorLine()
            ToggleRow(title: "Untertitel automatisch", an: model.subtitleAutomatic) {
                model.subtitleAutomatic.toggle()
            }
            SeparatorLine()
            // **The switch for frame-rate matching.**
            //
            // The same episode plays smoothly in Swiftfin, which does not switch the frame
            // rate. Here it visibly stuttered while every counter stood at zero: no dropped
            // frame, none late, nothing damaged. The only tangible difference was this
            // switch.
            //
            // 24 Hz native is right on paper: every frame stands equally long. On a TV whose
            // motion processing smooths at 60 Hz it can still look worse. That depends on
            // the device, not the file, so the viewer decides. On stays the default.
            ToggleRow(title: "Bildrate an den Film anpassen",
                          an: frameRateAdapt) {
                frameRateAdapt.toggle()
            }
            SeparatorLine()
            ToggleRow(title: "Nächste Folge automatisch", an: model.nextAutomatic) {
                model.nextAutomatic.toggle()
            }
            SeparatorLine()
            ToggleRow(title: "Intro und Abspann automatisch überspringen", an: skipAutomatic) {
                skipAutomatic.toggle()
            }
            SeparatorLine()
            valueRow("Zurückspulen", value: "\(model.backSeconds) s",
                      entries: Span.levels, label: { "\($0.value) s" },
                      an: { $0.value == model.backSeconds },
                      select: { model.backSeconds = $0.value })
            SeparatorLine()
            valueRow("Vorspulen", value: "\(model.forwardSeconds) s",
                      entries: Span.levels, label: { "\($0.value) s" },
                      an: { $0.value == model.forwardSeconds },
                      select: { model.forwardSeconds = $0.value })

        case .languages:
            valueRow("Ton",
                      value: model.audioLanguage.isEmpty ? String(localized: "Wie die Datei")
                                                     : model.audioLanguage,
                      entries: LanguageSelection.all, label: \.name,
                      an: { $0.value == model.audioLanguage },
                      select: { model.audioLanguage = $0.value }, top: true)
            SeparatorLine()
            valueRow("Untertitel",
                      value: model.subtitleLanguage.isEmpty ? String(localized: "Aus")
                                                            : model.subtitleLanguage,
                      entries: LanguageSelection.all(from: String(localized: "Aus")),
                      label: \.name,
                      an: { $0.value == model.subtitleLanguage },
                      select: { model.subtitleLanguage = $0.value })

        case .presentation:
            // **"Your look" first**, where the profile has one to show (see `TVLookEntry`).
            let looksShown = TVLookEntry.shown
            if looksShown {
                TVLookEntryRow()
                    .focused($right, equals: .top)
                SeparatorLine()
            }
            ToggleRow(title: "Fortschritt auf Kacheln", an: model.progressOnTiles) {
                model.progressOnTiles.toggle()
            }
            .focused($right, equals: looksShown ? nil : .top)
            SeparatorLine()
            ToggleRow(title: "Merkliste", an: model.watchlistShown) {
                model.watchlistShown.toggle()
            }
            SeparatorLine()
            ToggleRow(title: "Alphabetische Suche in Listen", an: model.alphabetShown) {
                model.alphabetShown.toggle()
            }
            SeparatorLine()
            ToggleRow(title: "Titel als Logo", an: titleAsLogo) { titleAsLogo.toggle() }
            SeparatorLine()

            // **Which rows are on the home page, and in which order.** They are moved with
            // the arrows on the right: dragging a row by a handle is a pointer gesture, and
            // the remote has none. Focus goes right to the arrows and a press moves the row.
            GroupsTitle(text: "Startseite")
                .padding(.horizontal, 26)
                .padding(.top, 18)
            ForEach(visibleRails) { rail in
                RailsRow(name: rail.name,
                            an: !model.startOut.contains(rail),
                            canHigh: visibleRails.first != rail,
                            canGoDown: visibleRails.last != rail,
                            toggle: {
                                if model.startOut.contains(rail) { model.startOut.remove(rail) }
                                else { model.startOut.insert(rail) }
                            },
                            shove: { step in move(rail, um: step) })
                SeparatorLine()
            }
            ToggleRow(title: "Neuzugänge getrennt", an: model.newAccessDisconnected) {
                model.newAccessDisconnected.toggle()
            }
            SeparatorLine()

            // **Own rows from the server**: libraries and collections, in the order of this
            // list, after the fixed rows.
            GroupsTitle(text: "Bibliotheken und Sammlungen")
                .padding(.horizontal, 26)
                .padding(.top, 18)
            ForEach(model.startLibraries) { entryRecord in
                StartLibraryRow(
                    name: entryRecord.name,
                    canHigh: model.startLibraries.first != entryRecord,
                    canGoDown: model.startLibraries.last != entryRecord,
                    remove: {
                        withAnimation(Theme.reveal) {
                            model.startLibraries.removeAll { $0.id == entryRecord.id }
                        }
                    },
                    shove: { step in move(entryRecord, um: step) })
                SeparatorLine()
            }
            valueRow("Bibliothek hinzufügen",
                      value: freeLibraries.isEmpty ? String(localized: "Keins offen") : "",
                      entries: freeLibraries,
                      label: \.name,
                      an: { _ in false },
                      select: { model.startLibraries.append(StartLibrary($0)) })
            SeparatorLine()

            // **One list, two forms.** Which genres is set once; whether they show as rows
            // below or as chips on top is only the form.
            GroupsTitle(text: "Genres")
                .padding(.horizontal, 26)
                .padding(.top, 18)
            valueRow("Form", value: model.genreChips ? String(localized: "Als Chips")
                                                     : String(localized: "Als Reihen"),
                      entries: GenreShape.allCases, label: \.name,
                      an: { $0.chips == model.genreChips },
                      select: { model.genreChips = $0.chips })
            ForEach(model.startGenres, id: \.self) { name in
                SeparatorLine()
                ActionRow(name: name, value: String(localized: "Entfernen")) {
                    withAnimation(Theme.reveal) {
                        model.startGenres.removeAll { $0 == name }
                    }
                }
            }
            SeparatorLine()
            valueRow("Genre hinzufügen",
                      value: genresDisturbed && allGenres.isEmpty
                            ? String(localized: "Server ist abgetaucht")
                            : (freeGenres.isEmpty ? String(localized: "Keins offen") : ""),
                      entries: freeGenres.map { GenreSelection(name: $0) },
                      label: \.name,
                      an: { _ in false },
                      select: { model.startGenres.append($0.name) })

        case .integration:
            // **A second service, not a second server**, hence a category of its own and not
            // under "Server". And an extra: whoever connects nothing sees nothing of it
            // except this row.
            DisplayRow(title: "Seerr",
                         value: model.seerr.connected ? String(localized: "Verbunden")
                                                     : String(localized: "Nicht verbunden"))
            SeparatorLine()
            ActionRow(title: model.seerr.connected ? "Ändern" : "Anbinden") {
                seerrOpen = true
            }
            .focused($right, equals: .top)
            // **One row, not two as with Seerr.** Two "Connect" rows stacked would leave
            // open which service is meant; here the name stands first and the state behind
            // it. Only with credentials in the build (`TraktAccess`).
            if model.trakt.available {
                SeparatorLine()
                ActionRow(name: "Trakt",
                               value: model.trakt.connected
                                   ? (model.trakt.user ?? String(localized: "Verbunden"))
                                   : String(localized: "Nicht verbunden")) {
                    traktOpen = true
                }
            }

        case .community:
            // **As a code, not a link**: the TV has no browser.
            // First and prominent: the entry App Review is pointed to, always here.
            // The support page is the shared one (`SupportModel.presented`, drawn by
            // `TVSupportPage`), and a supporter sees the status first.
            if SupportModel.shared.isSupporter {
                TVSupportStatusRow()
                SeparatorLine()
            }
            TVSupportEntryRow {
                SupportModel.shared.prepare()
                SupportModel.shared.open()
            }
            .focused($right, equals: .top)
            SeparatorLine()
            TVAppIconRow { supportStart = .icons }
            SeparatorLine()
            ActionRow(title: "Swiftly bewerten") { communityTarget = .rate }
            SeparatorLine()
            ActionRow(title: "Discord beitreten") { communityTarget = .discord }
            SeparatorLine()
            ActionRow(title: "Fehler melden") { communityTarget = .error }
            SeparatorLine()
            // Last, because it sets nothing: it shows what is in the app and where the
            // source of VLCKit is (LGPL).
            ActionRow(title: "Open-Source-Lizenzen") { licensesOpen = true }

        case .server:
            DisplayRow(title: "Adresse", value: model.serverName ?? "—")
            SeparatorLine()
            DisplayRow(title: "Fassung", value: model.serverVersion.map { "Jellyfin \($0)" } ?? "—")
            // **Without this row nobody can say what they are using.** A bug report hangs on
            // the build number, and the TV showed only the Jellyfin version.
            TVVersionRow()
            SeparatorLine()
            // **Multiple servers.** The bundle holds more than one server; this row is the
            // way to add one.
            ActionRow(title: "Server hinzufügen") { serverRecord = true }
            SeparatorLine()
            // For servers behind a service like Cloudflare Access (issue #4).
            ActionRow(title: "Eigene Header") { ownHeaders = true }
            SeparatorLine()
            ActionRow(title: "Verbindung prüfen") {
                Task { verification = await model.connectionCheck(deadline: .seconds(12)) }
            }
            .focused($right, equals: .top)

        case .account:
            // Settings follow the account to every device (`SettingsSyncRun`).
            ToggleRow(title: "Einstellungen auf allen Geräten gleich halten",
                      an: model.settingsSync.on) {
                model.settingsSync.on.toggle()
            }
            .focused($right, equals: .top)
            SeparatorLine()
            // **"Add another account" is the plus in the account card**, where the accounts
            // stand. "Add server" in the Server area is the same path.
            ActionRow(title: "Server hinzufügen") { serverRecord = true }
            SeparatorLine()
            // The way back from "off" in the cold-start picker.
            AskAtLaunchRow()
            SeparatorLine()
            // **Affects only the active account.** If others exist, the app switches to the
            // next one; only at the last one does it go back to sign-in. That logic lives in
            // the state holder, not here.
            ActionRow(title: "Abmelden") { model.signOut() }
        }
    }

    /// Row with a value on the right. Pressing expands the choice below it instead of
    /// putting it in a sheet, which costs extra steps.
    private func valueRow<E: Identifiable>(_ title: LocalizedStringKey, value: String,
                                            entries: [E],
                                            label: @escaping (E) -> String,
                                            an: @escaping (E) -> Bool,
                                            select: @escaping (E) -> Void,
                                            top: Bool = false) -> some View {
        let key = String(describing: title)
        return VStack(alignment: .leading, spacing: 0) {
            ActionRow(title: title, value: value,
                           expanded: opened == key) {
                // **One transaction for the whole list, not one per row.** A `.animation(…,
                // value: offen)` on every value row animates each on its own: the two directly
                // below jumped to their new place at once, those further down slid after slowly,
                // and in between they overlapped. A `withAnimation` on the change itself puts
                // them all in **one** movement; the list moves as one piece.
                withAnimation(Theme.motion(.easeInOut(duration: 0.28))) {
                    opened = opened == key ? nil : key
                }
            }
            .focused($right, equals: top ? .top : .proceed)

            if opened == key {
                // **The same row shape, just indented.** A choice in a settings list looks like
                // the list, with a checkmark on the selected one, as every app does it.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entryRecord in
                        Button {
                            select(entryRecord)
                            opened = nil
                        } label: {
                            HStack(spacing: 24) {
                                Image(systemName: an(entryRecord)
                                      ? "checkmark" : "")
                                    .font(.system(size: 26, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 34)
                                // Interpolated, not as a key: "30 s" is a value and would otherwise appear as a
                                // gap in the catalog.
                                Text("\(label(entryRecord))")
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(RowsStyle())
                        // The `checkmark` says what applies; as a symbol without a label it tells
                        // VoiceOver nothing. The trait belongs on the button.
                        .accessibilityAddTraits(an(entryRecord) ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(.leading, 26)
                .focusSection()
                .transition(.opacity)
            }
        }
        // Target for the reader so the expanded row comes into view.
        .id(key)
    }
}

// MARK: - Rows

/// An area in the left column. Selected is accent, focused is the calm surface:
/// The same rule as everywhere.
struct SectionStyle: ButtonStyle {
    let an: Bool
    /// **Selected but handed off.** Whoever presses OK works on the right; the area
    /// on the left is then no longer what you are doing, only a note of where you
    /// came from. If it kept the accent, both columns would stand equally loud and it
    /// would look as if something on the left were still open.
    var rests = false

    func makeBody(configuration: Configuration) -> some View {
        ContentBody(configuration: configuration, an: an, rests: rests)
    }

    private struct ContentBody: View {
        let configuration: ButtonStyleConfiguration
        let an: Bool
        let rests: Bool
        @Environment(\.isFocused) private var focus

        var body: some View {
            configuration.label
                // **The weight stays.** The color turns gray, not the position: you should find
                // where you were when going back, and a change of weight would also shift the
                // row.
                // **Selected is accent type and tint here, and VoiceOver sees neither.** The
                // main navigation of settings said its choice only through color; without this
                // trait the open area sounds like any other. The filter chip and `BarsStyle`
                // already do it this way.
                .accessibilityAddTraits(an ? [.isButton, .isSelected] : .isButton)
                .font(.system(size: 30, weight: an || focus ? .semibold : .medium))
                .foregroundStyle(fontColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 26)
                .frame(height: Theme.rowsHeight)
                .background(reason, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .animation(Theme.focusAnimation, value: focus)
        }

        /// **Four states, four looks.** Selected used to be a filled accent surface, the
        /// only place in the app where accent carried a surface, and when focus was on
        /// it, it looked the same: you could not see where you stood. Now accent carries
        /// type and tint, as in the sidebar on iPad and Mac, focus carries the light
        /// surface, and both together the stronger tint.
        private var fontColor: Color {
            guard an else { return Theme.font }
            return rests ? Theme.fontQuiet : Theme.accent
        }

        private var reason: Color {
            switch (an, focus) {
            case (true, true):   Theme.accent.opacity(0.26)
            // Handed off: the calm surface instead of the tint. The row stays recognizable
            // as a place but stops pushing forward.
            case (true, false):  rests ? Theme.area : Theme.accent.opacity(0.15)
            case (false, true):  Theme.focusArea
            case (false, false): .clear
            }
        }
    }
}

/// Row without action: information only.
struct DisplayRow: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(spacing: 24) {
            Text(title).font(.system(size: 30, weight: .medium))
            Spacer(minLength: 40)
            Text(value).font(Theme.button).foregroundStyle(Theme.fontQuiet)
        }
        .foregroundStyle(Theme.font)
        .padding(.horizontal, 26)
        .frame(height: Theme.rowsHeight)
    }
}

/// Row that triggers something, with or without a value on the right.
struct ActionRow: View {
    var title: LocalizedStringKey = ""
    /// **When the label comes from the server**: a genre is called what it is called
    /// and must not go through the translation table.
    var name: String? = nil
    var value: String?
    var expanded = false
    let action: () -> Void
    /// **Disabled means dimmed, on the right too.** `RowsStyle` dims the label;
    /// value and arrow set their own color and stayed brighter than the title. The
    /// bitrate row looked half operable at "Always Direct Play", and the value was
    /// louder than its name.
    @Environment(\.isEnabled) private var operable

    var body: some View {
        Button(action: action) {
            HStack(spacing: 24) {
                if let name { Text(verbatim: name) } else { Text(title) }
                Spacer(minLength: 40)
                if let value {
                    Text(value)
                        .foregroundStyle(operable ? Theme.fontQuiet
                                                   : Theme.fontVeryQuiet)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Theme.fontVeryQuiet)
                        .opacity(operable ? 1 : 0.5)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(RowsStyle())
        // The arrow says whether the choice is open; VoiceOver does not see it. Only
        // where there is something to expand: without a value the row is an ordinary
        // action.
        .accessibilityHint(value == nil ? Text("")
                           : (expanded ? Text("Zuklappen") : Text("Aufklappen")))
    }
}

/// Row with a switch on the right.
///
/// No `Toggle`: Apple's switch brings its own dimensions, radius and animation,
/// the same reasoning as on the iPhone. On tvOS focus also sits on the whole row,
/// not the switch; the row is what is pressed.
struct ToggleRow: View {
    let title: LocalizedStringKey
    let an: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 24) {
                Text(title)
                Spacer(minLength: 40)
                ToggleSwitch(an: an)
            }
        }
        .buttonStyle(RowsStyle())
        .accessibilityRepresentation {
            Toggle(isOn: .constant(an)) { Text(title) }
        }
    }
}

/// **A home-page row: on or off, and where it belongs.**
///
/// Three targets side by side instead of a drag handle. With a pointer you drag a
/// row; with the remote there is nothing to grab. Focus goes right to the arrows,
/// and a press moves the row one place.
struct RailsRow: View {
    let name: LocalizedStringKey
    let an: Bool
    let canHigh: Bool
    let canGoDown: Bool
    let toggle: () -> Void
    let shove: (Int) -> Void

    var body: some View {
        HStack(spacing: 24) {
            Button(action: toggle) {
                HStack(spacing: 24) {
                    Text(name)
                    Spacer(minLength: 40)
                    ToggleSwitch(an: an)
                }
            }
            .buttonStyle(RowsStyle())
            .accessibilityRepresentation {
                Toggle(isOn: .constant(an)) { Text(name) }
            }

            SlideButton(symbol: "chevron.up", an: canHigh) { shove(-1) }
            SlideButton(symbol: "chevron.down", an: canGoDown) { shove(1) }
        }
        .padding(.trailing, 26)
    }
}

/// An arrow to the right of a row that can be moved.
///
/// **Disabled instead of hidden.** If the arrow disappeared on the top row, the
/// neighbors' buttons would shift sideways and focus would jump to the wrong
/// column when moving up.
struct SlideButton: View {
    let symbol: String
    let an: Bool
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
        }
        // **Not `.buttonStyle(.card)`.** Apple's card brings shadow, parallax and a
        // flash; `tvOS/Style.swift` excludes it in its header. `ThemedButtonStyle` carries the
        // same three states as every other button in the app, the disabled one included.
        .buttonStyle(ThemedButtonStyle(onlySymbol: true, height: 56))
        .disabled(!an)
        .accessibilityLabel(symbol == "chevron.up" ? Text("Nach oben") : Text("Nach unten"))
    }
}

/// A selected library or collection: a press on the name removes it, the arrows
/// move it in the home-page order.
struct StartLibraryRow: View {
    let name: String
    let canHigh: Bool
    let canGoDown: Bool
    let remove: () -> Void
    let shove: (Int) -> Void

    var body: some View {
        HStack(spacing: 24) {
            ActionRow(name: name, value: String(localized: "Entfernen"), action: remove)
            SlideButton(symbol: "chevron.up", an: canHigh) { shove(-1) }
            SlideButton(symbol: "chevron.down", an: canGoDown) { shove(1) }
        }
        .padding(.trailing, 26)
    }
}

/// Whether genres appear as rows of their own or as chips on top.
struct GenreShape: Identifiable, CaseIterable {
    let chips: Bool
    var id: Bool { chips }
    var name: String {
        chips ? String(localized: "Als Chips über den Reihen")
              : String(localized: "Als eigene Reihen")
    }
    static var allCases: [GenreShape] { [.init(chips: false), .init(chips: true)] }
}

/// A server genre in the choice list.
struct GenreSelection: Identifiable {
    let name: String
    var id: String { name }
}

/// The switch itself: display only, the row is what is pressed.
struct ToggleSwitch: View {
    let an: Bool
    /// **Disabled means dimmed, here too.** `RowsStyle` dims the type, but the
    /// switch next to it stayed in full accent, and the row looked half operable. The
    /// state comes from the environment, so the `.disabled` at the call site is
    /// enough and there is no second flag that can drift apart.
    @Environment(\.isEnabled) private var operable

    var body: some View {
        ZStack(alignment: an ? .trailing : .leading) {
            Capsule()
                .fill(track)
                .frame(width: 84, height: 50)
            Circle()
                .fill(grip)
                .frame(width: 40, height: 40)
                .padding(.horizontal, 5)
        }
        .animation(operable ? Theme.motion(.easeInOut(duration: 0.15)) : nil, value: an)
    }

    /// Dimmed, not translucent: the switch keeps its position, so you still see
    /// whether it is on, just not that you could flip it.
    private var track: Color {
        guard operable else {
            return an ? Theme.accent.opacity(0.35) : Color.white.opacity(0.08)
        }
        return an ? Theme.accent : Color.white.opacity(0.16)
    }

    private var grip: Color {
        guard operable else { return Color.white.opacity(0.35) }
        return an ? Theme.reason : Color.white
    }
}

/// Hairline between rows.
struct SeparatorLine: View {
    var body: some View {
        Rectangle().fill(Theme.line)
            .frame(height: 2)
            .padding(.horizontal, 26)
    }
}

/// The other accounts and the plus, at the bottom of the account card.
///
/// **The signed-in account is no longer in it.** It stands large above; as a
/// circle in the row it would appear twice. A press on another account switches,
/// the plus adds one via Quick Connect. The plus is always there, so even with a
/// single account there is something to focus that does something.
private struct AccountsStrip: View {
    let model: AppModel
    let record: () -> Void

    private let size: CGFloat = 60

    /// Where the profile pictures are, globally: the account switch lifts the
    /// selected one from there. In a plain class so focus steps do not rebuild at
    /// every frame, as on the iPhone.
    @State private var circles = CircleStore()
    private final class CircleStore {
        var frameRect: [String: CGRect] = [:]
    }

    /// **Switch, with motion**, see `AccountSwitchTransition`. The picture flies as a
    /// finished layer from here to the profile picture at the top right, the page
    /// fades out, the home page comes in staggered.
    private func switchTo(toward account: Session) {
        let from = circles.frameRect[account.accountKey] ?? .zero
        let address = model.userImageURL(for: account)
        let withoutImage = address.map { ImageCache.shared.image($0) == nil } ?? true
        AccountSwitchTransition.shared.start(
            account: account.accountKey,
            image: ProfileCharacter(name: account.userName, image: address,
                                size: max(from.width, 1) * 1.06, withoutImage: withoutImage),
            from: from, area: Theme.reason, address: address) {
            model.switchAccount(toward: account.accountKey)
        }
    }

    var body: some View {
        HStack(spacing: 20) {
            // **All accounts, not only this server's.** The bundle holds several servers;
            // with two you find both here. They are told apart by `accountKey`, because
            // the same user ID can exist on two servers.
            ForEach(model.accounts.filter { $0.accountKey != model.session?.accountKey },
                    id: \.accountKey) { account in
                Button {
                    switchTo(toward: account)
                } label: {
                    ProfileCharacter(name: account.userName,
                                  image: model.userImageURL(for: account),
                                  size: size)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                            circles.frameRect[account.accountKey] = $0
                        }
                }
                .buttonStyle(AccountStripStyle(size: size))
                .accessibilityLabel(Text("Zu \(account.userName) wechseln"))
            }

            Button(action: record) {
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.fontQuiet)
                    // **A field on `area`, not a dashed circle**, as on Mac and iPhone (a button
                    // without a label is square). Same size as the circles next to it, corner from
                    // the token.
                    .frame(width: size, height: size)
                    .background(Theme.area,
                                in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            }
            .buttonStyle(AccountStripStyle(size: size, square: true))
            .accessibilityLabel(Text("Weiteres Konto hinzufügen"))
        }
        .focusSection()
        #if DEBUG
        // **Self-test** (`-kontowechsellauf`): the same path as a press, without
        // operation; a second press in the middle of the switch must go nowhere.
        .task {
            guard AccountSwitchRun.an, !AccountSwitchRun.wasTapped else { return }
            AccountSwitchRun.wasTapped = true
            try? await Task.sleep(for: .milliseconds(1500))
            guard let s = model.session,
                  let target = model.accounts(on: s.serverURL)
                      .first(where: { $0.accountKey != s.accountKey })
            else { return }
            AccountSwitchTransition.note("selbsttest: druck auf \(target.userName)")
            switchTo(toward: target)
            try? await Task.sleep(for: .milliseconds(200))
            AccountSwitchTransition.note("selbsttest: zweiter druck")
            switchTo(toward: target)
        }
        #endif
    }
}

/// Focus as a white ring and some enlargement: the same language as the tiles,
/// just round because a profile picture is an image.
private struct AccountStripStyle: ButtonStyle {
    let size: CGFloat
    var square = false

    func makeBody(configuration: Configuration) -> some View {
        ContentBody(configuration: configuration, size: size, square: square)
    }

    private struct ContentBody: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        let square: Bool
        @Environment(\.isFocused) private var focus

        var body: some View {
            configuration.label
                .overlay {
                    Group {
                        if square {
                            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                                .strokeBorder(Color.white, lineWidth: 4)
                        } else {
                            Circle().strokeBorder(Color.white, lineWidth: 4)
                        }
                    }
                    .opacity(focus ? 1 : 0)
                }
                .frame(width: size, height: size)
                // No shadow, see `PlayerScreen`. The magnification says it. One value for the
                // same 60 pt circle here and at `ProfileStyle`: the small level.
                .scaleEffect(focus ? Theme.focusMagnifierSmall : 1)
                .animation(Theme.focusAnimation, value: focus)
        }
    }
}
