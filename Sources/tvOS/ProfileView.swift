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

    /// ProfileView is only ever drawn in the settings look.
    private var look: Bool { true }
    @State private var section: SectionSelection = .playback
    /// Which value row currently shows its choice.
    @State private var opened: String?
    @AppStorage("titelAlsLogo") private var titleAsLogo = false
    @AppStorage(PlayerEndTime.key) private var showsEnd = PlayerEndTime.standard
    @State private var verification: String?
    /// Shows Quick Connect to add another account.
    @State private var accountRecord = false
    /// A new server or a second account on a known Plex/Emby server: the kind picker
    /// (or straight the kind's page), then its sign-in. `ServerRoute` says which.
    @State private var serverRoute: ServerRoute?
    /// Custom headers of the active server (issue #4).
    @State private var ownHeaders = false
    /// Connect Seerr, as a page of its own above everything: three fields and an
    /// on-screen keyboard need room that a row does not have.
    @State private var seerrOpen = false
    @State private var communityTarget: CommunityTarget?
    /// Open-source licenses: full page, building blocks on the left, text on the right.
    @State private var licensesOpen = false
    /// Subtitle look: full page, picture on the left, rows on the right.
    @State private var subtitleLookOpen = false
    /// Support page and icon picker: a local flag, so the root's `presented` cover
    /// is the only one bound to the model.

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
        case playback = "wiedergabe", presentation = "darstellung", integration, server, account = "konto", community = "gemeinschaft"
        var id: String { rawValue }
        /// Areas that compose their own boxes (see `rows`).
        var hasGroups: Bool { self == .playback || self == .presentation }
        var name: LocalizedStringKey {
            switch self {
            case .playback:  "Wiedergabe"
            case .presentation: "Darstellung"
            case .integration: "Integration"
            case .server:      "Server"
            case .account:       "Konto"
            case .community: "Swiftly"
            }
        }
        /// The same symbols as the iPhone's settings list.
        var icon: String {
            switch self {
            case .playback:     "play"
            case .presentation: "square.grid.2x2"
            case .integration:  "powerplug"
            case .server:       "externaldrive.connected.to.line.below"
            case .account:      "person"
            case .community:    "info.circle"
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
            #if DEBUG
            // `-zeige einstellungen`: the page opens with focus on the first row on the right
            // ("Immer Direct Play", area "Wiedergabe" selected), the state of the design picture.
            .task {
                let args = ProcessInfo.processInfo.arguments
                guard let i = args.firstIndex(of: "-zeige"), args.indices.contains(i + 1),
                      args[i + 1] == "einstellungen" else { return }
                try? await Task.sleep(for: .milliseconds(1200))
                toInGo()
            }
            #endif
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            // **No header above the columns.** The account stands on the left above the
            // areas: the left is what you choose (who, and which area), the right is what
            // you set. That way the right column starts at the top and all eight "Playback"
            // rows are visible without scrolling.
            HStack(alignment: .top, spacing: TVSpec.columnGap) {
                VStack(alignment: .leading, spacing: 0) {
                    accountBlock
                    // Hairline between "who" and "where": margin 28 above and below (design).
                    SheetLine()
                        .padding(.vertical, SettingsLook.hairlineMargin)
                    SettingsHeading(text: "Bereiche")
                        .padding(.bottom, SettingsLook.leftHeadingBottom)
                    VStack(alignment: .leading, spacing: SettingsLook.sectionGap) {
                        ForEach(SectionSelection.allCases.filter { $0 != .integration || showsIntegration }) { b in
                            Button {
                                section = b
                                toInGo()
                            } label: {
                                HStack(spacing: 24) {
                                    Image(icon: b.icon, size: TVSpec.rowSymbol)
                                        .font(.app(size: TVSpec.rowSymbol))
                                        .frame(width: TVSpec.rowSymbolColumn)
                                        .accessibilityHidden(true)
                                    Text(b.name)
                                }
                            }
                            .buttonStyle(SectionStyle(an: section == b, rests: false))
                            .focused($left, equals: b)
                        }
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
                .frame(width: TVSpec.sectionColumnWidth, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .focusSection()

                // **The reader is the whole motion.** When a row expands it is scrolled here,
                // and the scrolling itself is the soft movement tvOS brings anyway. Moving the
                // column by hand was hard and had to guess the height of the choice. Nothing is
                // guessed here: the list is as long as it is, and the reader brings the expanded
                // row into view.
                ScrollViewReader { reader in
                    ScrollView {
                        // **Each group is its own box with its title above on the bare background,
                        // like the groups on iPhone** ("Startseite", "Genres" were titles inside one
                        // big box). Areas with a single group get the area name as the title.
                        VStack(alignment: .leading, spacing: TVSpec.groupGap) {
                            if section.hasGroups {
                                rows
                            } else {
                                TVGroup(title: section.name) { rows }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .scrollClipDisabled()
                    .environment(\.settingsLook, true)
                    .environment(\.settingsActive, inside)
                    .onChange(of: opened) { _, new in
                        guard let new else { return }
                        // Same curve and duration as the expansion, otherwise two motions run against
                        // each other.
                        withAnimation(Theme.motion(.easeInOut(duration: TVSpec.valueExpandDuration))) {
                            reader.scrollTo(new, anchor: .top)
                        }
                    }
                }
                // Not active yet means disabled, so that a step right does not already lead in;
                // OK goes in. The design shows the right column at full brightness when focus
                // is on it, and the area list on the left already says which one it is, so
                // the column is no longer dimmed.
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
                .animation(Theme.motion(.easeInOut(duration: TVSpec.valueDimDuration)), value: inside)
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
        .ignoresSafeArea(edges: [.horizontal, .top])
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
        .fullScreenCover(item: $serverRoute) { route in
            TVAddServerFlow(model: model, route: route) { serverRoute = nil }
        }
        .fullScreenCover(isPresented: $seerrOpen) {
            SeerrConnectView(model: model, seerr: model.seerr) { seerrOpen = false }
        }
        .fullScreenCover(item: $communityTarget) { target in
            CodeSheet(target: target) { communityTarget = nil }
        }
        .fullScreenCover(isPresented: $subtitleLookOpen) {
            TVSubtitleLookView(model: model) { subtitleLookOpen = false }
        }
        .fullScreenCover(isPresented: $licensesOpen) {
            TVLicensesView { licensesOpen = false }
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
                          size: TVSpec.accountAvatar)
                .modifier(TVSupporterAvatarBadge(size: TVSpec.accountAvatar))
            Text(model.session?.userName ?? "—")
                // Row heading from the ladder.
                .font(Theme.rail)
                .tracking(Theme.lockRail)
                .foregroundStyle(Theme.font)
                .lineLimit(1)
                .padding(.top, TVSpec.accountNameTop)
            // Server data, not catalog text.
            Text(verbatim: serverRow)
                .font(Theme.small)
                .foregroundStyle(Theme.fontVeryQuiet)
                .lineLimit(1)
                .padding(.top, TVSpec.accountServerTop)
            // The line that was here separated name from accounts inside the card. Without
            // the card it would be the second in a column that needs one, and the one is
            // further down, before "Areas". The accounts belong to the name above.
            AccountsStrip(model: model) {
                // Another account on the connected server, by its kind: Jellyfin through
                // Quick Connect, Emby and Plex on their own sign-in pages.
                switch model.session?.kind {
                case .plex?, .emby?:
                    serverRoute = ServerRoute(preset: model.session?.serverURL, kind: model.session?.kind)
                default:
                    accountRecord = true
                }
            }
                .padding(.top, SettingsLook.accountStripTop)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var serverRow: String {
        [model.serverName, model.serverVersion.map { "\(kindName) \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// The kind of the active server as the user reads it ("Plex (Beta)"), as on the iPhone.
    private var kindName: String { (model.session?.kind ?? .jellyfin).shownName }

    /// Seerr signs in with the media server's account, which not every kind has.
    /// Without it the area would be empty (`SettingsView`).
    private var showsIntegration: Bool { model.can(.seerr) }

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
            // Same three boxes as on iPhone: quality, language, behaviour.
            TVGroup(title: "Qualität") {
            ToggleRow(icon: "play", title: "Immer Direct Play", an: directPlay) {
                model.alwaysDirectPlay.toggle()
            }
            .disabled(!free)
            .focused($right, equals: free ? .top : .proceed)
            SeparatorLine()
            valueRow("Höchste Bitrate", icon: "speedometer", value: Bitrate.text(model.bitratesLimit),
                      entries: Bitrate.levels, label: { Bitrate.text($0.value) },
                      an: { $0.value == model.bitratesLimit },
                      select: { model.bitratesLimit = $0.value })
            .disabled(directPlay)
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
            ToggleRow(icon: "film", title: "Bildrate an den Film anpassen",
                          an: frameRateAdapt) {
                frameRateAdapt.toggle()
            }
            }
            TVGroup(title: "Sprache") {
            // The topmost row you can touch when Direct Play is fixed (`free` is false).
            valueRow("Ton", icon: "speaker.wave.2",
                      value: model.audioLanguage.isEmpty ? String(localized: "Wie die Datei")
                                                     : model.audioLanguage,
                      entries: LanguageSelection.all, label: \.name,
                      an: { $0.value == model.audioLanguage },
                      select: { model.audioLanguage = $0.value }, top: !free)
            SeparatorLine()
            valueRow("Untertitel", icon: "captions.bubble",
                      value: model.subtitleLanguage.isEmpty ? String(localized: "Aus")
                                                            : model.subtitleLanguage,
                      entries: LanguageSelection.all(from: String(localized: "Aus")),
                      label: \.name,
                      an: { $0.value == model.subtitleLanguage },
                      select: { model.subtitleLanguage = $0.value })
            SeparatorLine()
            ToggleRow(icon: "text.alignleft", title: "Untertitel automatisch", an: model.subtitleAutomatic) {
                model.subtitleAutomatic.toggle()
            }
            SeparatorLine()
            ActionRow(icon: "textformat.size", title: "Aussehen der Untertitel", value: model.subtitleLook.entryValue) {
                subtitleLookOpen = true
            }
            }
            TVGroup(title: "Verhalten") {
            ToggleRow(icon: "forward.end", title: "Nächste Folge automatisch", an: model.nextAutomatic) {
                model.nextAutomatic.toggle()
            }
            SeparatorLine()
            ToggleRow(icon: "forward.end.alt", title: "Intro und Abspann automatisch überspringen", an: skipAutomatic) {
                skipAutomatic.toggle()
            }
            SeparatorLine()
            valueRow("Zurückspulen", icon: "gobackward", value: "\(model.backSeconds) s",
                      entries: Span.levels, label: { "\($0.value) s" },
                      an: { $0.value == model.backSeconds },
                      select: { model.backSeconds = $0.value })
            SeparatorLine()
            valueRow("Vorspulen", icon: "goforward", value: "\(model.forwardSeconds) s",
                      entries: Span.levels, label: { "\($0.value) s" },
                      an: { $0.value == model.forwardSeconds },
                      select: { model.forwardSeconds = $0.value })
            SeparatorLine()
            // Applies from the next title; the same place and words as on iPhone.
            // Shared setting (`PlayerEndTime`): the player shows "Endet um …" instead of the
            // remaining time. tvOS has no "Technische Daten" row, so it sits under "Player".
            ToggleRow(icon: "clock", title: "Endzeit im Player", an: showsEnd) {
                showsEnd.toggle()
            }
            }

        case .presentation:
            // **"Your look" first**, where the profile has one to show (see `TVLookEntry`).
            let looksShown = TVLookEntry.shown
            TVGroup(title: "Darstellung") {
            if looksShown {
                TVLookEntryRow()
                    .focused($right, equals: .top)
                SeparatorLine()
            }
            ToggleRow(icon: "chart.bar", title: "Fortschritt auf Kacheln", an: model.progressOnTiles) {
                model.progressOnTiles.toggle()
            }
            .focused($right, equals: looksShown ? nil : .top)
            SeparatorLine()
            ToggleRow(icon: "bookmark", title: "Merkliste", an: model.watchlistShown) {
                model.watchlistShown.toggle()
            }
            SeparatorLine()
            if model.watchersPluginHere {
                ToggleRow(icon: "eye", title: "Gesehen von",
                          under: "Zeigt auf Titelseiten, wer einen Titel gesehen hat",
                          an: model.watchersShown) {
                    model.watchersShown.toggle()
                }
                SeparatorLine()
            }
            ToggleRow(icon: "textformat.abc", title: "Alphabetische Suche in Listen", an: model.alphabetShown) {
                model.alphabetShown.toggle()
            }
            SeparatorLine()
            ToggleRow(icon: "textformat", title: "Titel als Logo", an: titleAsLogo) { titleAsLogo.toggle() }
            }

            // **Which rows are on the home page, and in which order.** They are moved with
            // the arrows on the right: dragging a row by a handle is a pointer gesture, and
            // the remote has none. Focus goes right to the arrows and a press moves the row.
            TVGroup(title: "Startseite") {
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
            ToggleRow(icon: "square.split.2x1", title: "Neuzugänge getrennt", an: model.newAccessDisconnected) {
                model.newAccessDisconnected.toggle()
            }
            }

            // **Own rows from the server**: libraries and collections, in the order of this
            // list, after the fixed rows.
            TVGroup(title: "Bibliotheken und Sammlungen") {
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
            valueRow("Bibliothek hinzufügen", icon: "plus",
                      value: freeLibraries.isEmpty ? String(localized: "Keins offen") : "",
                      entries: freeLibraries,
                      label: \.name,
                      an: { _ in false },
                      select: { model.startLibraries.append(StartLibrary($0)) })
            }

            // **One list, two forms.** Which genres is set once; whether they show as rows
            // below or as chips on top is only the form.
            TVGroup(title: "Genres") {
            valueRow("Form", icon: "capsule", value: model.genreChips ? String(localized: "Als Chips")
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
            valueRow("Genre hinzufügen", icon: "plus",
                      value: genresDisturbed && allGenres.isEmpty
                            ? String(localized: "Server ist abgetaucht")
                            : (freeGenres.isEmpty ? String(localized: "Keins offen") : ""),
                      entries: freeGenres.map { GenreSelection(name: $0) },
                      label: \.name,
                      an: { _ in false },
                      select: { model.startGenres.append($0.name) })
            }

        case .integration:
            // **A second service, not a second server**, hence a category of its own and not
            // under "Server". And an extra: whoever connects nothing sees nothing of it
            // except this row.
            if model.can(.seerr) {
                DisplayRow(title: "Seerr",
                             value: model.seerr.connected ? String(localized: "Verbunden")
                                                         : String(localized: "Nicht verbunden"))
                SeparatorLine()
                ActionRow(icon: "sparkle.magnifyingglass", title: model.seerr.connected ? "Ändern" : "Anbinden") {
                    seerrOpen = true
                }
                .focused($right, equals: .top)
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
            ActionRow(icon: "star", title: "Swiftly bewerten") { communityTarget = .rate }
            SeparatorLine()
            ActionRow(icon: "bubble.left.and.bubble.right", title: "Discord beitreten") { communityTarget = .discord }
            SeparatorLine()
            ActionRow(icon: "ladybug", title: "Fehler melden") { communityTarget = .error }
            SeparatorLine()
            // Last, because it sets nothing: it shows what is in the app and where the
            // source of VLCKit is (LGPL).
            ActionRow(icon: "text.book.closed", title: "Open-Source-Lizenzen") { licensesOpen = true }

        case .server:
            DisplayRow(title: "Adresse", value: model.serverName ?? "—")
            SeparatorLine()
            DisplayRow(title: "Fassung", value: model.serverVersion.map { "\(kindName) \($0)" } ?? "—")
            // **Without this row nobody can say what they are using.** A bug report hangs on
            // the build number, and the TV showed only the Jellyfin version.
            TVVersionRow()
            SeparatorLine()
            // **Multiple servers.** The bundle holds more than one server; this row is the
            // way to add one.
            ActionRow(icon: "plus", title: "Server hinzufügen") { serverRoute = ServerRoute() }
            SeparatorLine()
            // For servers behind a service like Cloudflare Access (issue #4).
            ActionRow(icon: "key", title: "Eigene Header") { ownHeaders = true }
            SeparatorLine()
            ActionRow(icon: "wifi", title: "Verbindung prüfen") {
                Task { verification = await model.connectionCheck(deadline: .seconds(12)) }
            }
            .focused($right, equals: .top)

        case .account:
            // Settings follow the account to every device (`SettingsSyncRun`).
            // Only servers that keep display preferences (`ServerCapability.settingsSync`).
            if model.can(.settingsSync) {
                ToggleRow(icon: "arrow.triangle.2.circlepath", title: "Einstellungen auf allen Geräten gleich halten",
                          an: model.settingsSync.on) {
                    model.settingsSync.on.toggle()
                }
                .focused($right, equals: .top)
                SeparatorLine()
            }
            // **"Add another account" is the plus in the account card**, where the accounts
            // stand. "Add server" in the Server area is the same path.
            ActionRow(icon: "plus", title: "Server hinzufügen") { serverRoute = ServerRoute() }
                .focused($right, equals: model.can(.settingsSync) ? nil : .top)
            SeparatorLine()
            // The way back from "off" in the cold-start picker.
            AskAtLaunchRow()
            SeparatorLine()
            // **Affects only the active account.** If others exist, the app switches to the
            // next one; only at the last one does it go back to sign-in. That logic lives in
            // the state holder, not here.
            ActionRow(icon: "rectangle.portrait.and.arrow.right", title: "Abmelden") { model.signOut() }
        }
    }

    /// Row with a value on the right. Pressing expands the choice below it instead of
    /// putting it in a sheet, which costs extra steps.
    private func valueRow<E: Identifiable>(_ title: LocalizedStringKey, icon: String? = nil, value: String,
                                            entries: [E],
                                            label: @escaping (E) -> String,
                                            an: @escaping (E) -> Bool,
                                            select: @escaping (E) -> Void,
                                            top: Bool = false) -> some View {
        let key = String(describing: title)
        return VStack(alignment: .leading, spacing: 0) {
            ActionRow(icon: icon, title: title, value: value,
                           expanded: opened == key) {
                // **One transaction for the whole list, not one per row.** A `.animation(…,
                // value: offen)` on every value row animates each on its own: the two directly
                // below jumped to their new place at once, those further down slid after slowly,
                // and in between they overlapped. A `withAnimation` on the change itself puts
                // them all in **one** movement; the list moves as one piece.
                withAnimation(Theme.motion(.easeInOut(duration: TVSpec.valueExpandDuration))) {
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
                                Image(icon: an(entryRecord)
                                      ? "checkmark" : "")
                                    .font(.app(size: TVSpec.valueIcon, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: TVSpec.choiceCheckWidth)
                                // Interpolated, not as a key: "30 s" is a value and would otherwise appear as a
                                // gap in the catalog.
                                Text("\(label(entryRecord))")
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(SettingsRowsStyle())
                        // The `checkmark` says what applies; as a symbol without a label it tells
                        // VoiceOver nothing. The trait belongs on the button.
                        .accessibilityAddTraits(an(entryRecord) ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(.leading, look ? TVSpec.rowSymbolColumn + SettingsLook.rowGap : TVSpec.rowInset)
                .focusSection()
                .transition(.opacity)
            }
        }
        // Target for the reader so the expanded row comes into view.
        .id(key)
    }
}

// MARK: - Group

/// **One box of settings with its title above on the bare background**, like a group on
/// iPhone. Clipped to the box, otherwise the names of an expanding row stand on the bare
/// background for a moment while the box is still growing.
private struct TVGroup<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content
    @Environment(\.settingsLook) private var look

    var body: some View {
        if look {
            // Design: title 44/700 on the bare background, group 20 below it, #1E1E1E, r24,
            // 26 inside on both sides and none above or below (the rows are 84 high).
            VStack(alignment: .leading, spacing: SettingsLook.groupTitleGap) {
                SettingsHeading(text: title)
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.horizontal, SettingsLook.groupInset)
                    .background(Theme.groupsArea,
                                in: RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous))
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                GroupsTitle(text: title)
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(TVSpec.listCardInset)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerTile, style: .continuous))
                    .background(Theme.area,
                                in: RoundedRectangle(cornerRadius: Theme.cornerTile, style: .continuous))
            }
        }
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
                .font(.app(size: 30, weight: .semibold))
                .foregroundStyle(fontColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, TVSpec.rowInset)
                .frame(height: Theme.rowsHeight)
                .background(reason, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .settingsLift(focus)
                .scaleEffect(focus ? Theme.focusMagnifierWide : 1)
                .animation(Theme.focusAnimation, value: focus)
        }

        /// **Four states, four looks.** Selected used to be a filled accent surface, the
        /// only place in the app where accent carried a surface, and when focus was on
        /// it, it looked the same: you could not see where you stood. Now accent carries
        /// type and tint, as in the sidebar on iPad and Mac, focus carries the light
        /// surface, and both together the stronger tint.
        private var fontColor: Color {
            if focus { return Theme.reason }
            guard an else { return Theme.font }
            return rests ? Theme.fontQuiet : Theme.accent
        }

        private var reason: Color {
            switch (an, focus) {
            // **Focus is white**, as on every other control; the accent tint is the choice.
            case (_, true):      .white
            // Handed off: the calm surface instead of the tint. The row stays recognizable
            // as a place but stops pushing forward.
            case (true, false):  rests ? Theme.area : Theme.accent.opacity(TVSpec.sectionSelectedOpacity)
            case (false, false): .clear
            }
        }
    }
}

/// Row without action: information only.
struct DisplayRow: View {
    let title: LocalizedStringKey
    let value: String
    @Environment(\.settingsLook) private var look

    var body: some View {
        HStack(spacing: look ? SettingsLook.rowGap : 24) {
            Text(title).font(.app(size: 30, weight: .medium))
            Spacer(minLength: 40)
            Text(value).font(look ? .app(size: 30, weight: .medium) : Theme.button)
                .foregroundStyle(look ? Theme.fontVeryQuiet : Theme.fontQuiet)
        }
        .foregroundStyle(Theme.font)
        .padding(.horizontal, look ? 0 : TVSpec.rowInset)
        .frame(minHeight: Theme.rowsHeight)
    }
}


/// **The symbol column of a settings row**, as on iPhone (symbol 20 in a 26 column there,
/// double here). White like the title: the symbol names the row, it states nothing.
private struct RowSymbol: View {
    let icon: String?
    var body: some View {
        if let icon {
            Image(icon: icon, size: TVSpec.rowSymbol)
                .font(.app(size: TVSpec.rowSymbol))
                .frame(width: TVSpec.rowSymbolColumn)
                .accessibilityHidden(true)
        }
    }
}

/// Row that triggers something, with or without a value on the right.
struct ActionRow: View {
    var icon: String? = nil
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
    @Environment(\.settingsLook) private var look

    var body: some View {
        Button(action: action) {
            HStack(spacing: look ? SettingsLook.rowGap : 24) {
                RowSymbol(icon: icon)
                if let name { Text(verbatim: name) } else { Text(title) }
                Spacer(minLength: 40)
                if let value {
                    SettingsValue(value: value, expanded: expanded, operable: operable, look: look)
                }
            }
        }
        .buttonStyle(SettingsRowsStyle())
        // The arrow says whether the choice is open; VoiceOver does not see it. Only
        // where there is something to expand: without a value the row is an ordinary
        // action.
        .accessibilityHint(value == nil ? Text("")
                           : (expanded ? Text("Zuklappen") : Text("Aufklappen")))
    }
}

/// Value and arrow at the right end of a row. A view of its own so that it can read focus: on the
/// design's white focus surface both turn dark.
private struct SettingsValue: View {
    let value: String
    let expanded: Bool
    let operable: Bool
    let look: Bool
    @Environment(\.isFocused) private var focus

    var body: some View {
        HStack(spacing: look ? SettingsLook.valueGap : 24) {
            Text(value)
                .foregroundStyle(ink)
            Image(icon: expanded ? "chevron.up" : "chevron.down")
                .font(.app(size: 24, weight: .semibold))
                .foregroundStyle(look ? ink : Theme.fontVeryQuiet)
                .opacity(operable || look ? 1 : 0.5)
                .accessibilityHidden(true)
        }
    }

    private var ink: Color {
        guard look else { return operable ? Theme.fontQuiet : Theme.fontVeryQuiet }
        return focus ? Theme.reason : Theme.fontVeryQuiet
    }
}

/// Row with a switch on the right.
///
/// No `Toggle`: Apple's switch brings its own dimensions, radius and animation,
/// the same reasoning as on the iPhone. On tvOS focus also sits on the whole row,
/// not the switch; the row is what is pressed.
struct ToggleRow: View {
    var icon: String? = nil
    let title: LocalizedStringKey
    /// A quiet line under the title.
    var under: LocalizedStringKey? = nil
    let an: Bool
    let action: () -> Void

    @Environment(\.settingsLook) private var look

    var body: some View {
        Button(action: action) {
            HStack(spacing: look ? SettingsLook.rowGap : 24) {
                RowSymbol(icon: icon)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                    if let under {
                        Text(under).font(Theme.small).foregroundStyle(Theme.fontQuiet)
                    }
                }
                Spacer(minLength: 40)
                ToggleSwitch(an: an)
            }
        }
        .buttonStyle(SettingsRowsStyle())
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
    @Environment(\.settingsLook) private var look

    var body: some View {
        HStack(spacing: 24) {
            Button(action: toggle) {
                HStack(spacing: 24) {
                    Text(name)
                    Spacer(minLength: 40)
                    ToggleSwitch(an: an)
                }
            }
            .buttonStyle(SettingsRowsStyle())
            .accessibilityRepresentation {
                Toggle(isOn: .constant(an)) { Text(name) }
            }

            SlideButton(symbol: "chevron.up", an: canHigh) { shove(-1) }
            SlideButton(symbol: "chevron.down", an: canGoDown) { shove(1) }
        }
        .padding(.trailing, look ? 0 : TVSpec.rowInset)
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
            Image(icon: symbol)
                .font(.app(size: TVSpec.valueIcon, weight: .semibold))
        }
        // **Not `.buttonStyle(.card)`.** Apple's card brings shadow, parallax and a
        // flash; `tvOS/Style.swift` excludes it in its header. `ThemedButtonStyle` carries the
        // same three states as every other button in the app, the disabled one included.
        .buttonStyle(ThemedButtonStyle(onlySymbol: true, height: TVSpec.iconButtonHeight))
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
    @Environment(\.settingsLook) private var look

    var body: some View {
        HStack(spacing: 24) {
            ActionRow(name: name, value: String(localized: "Entfernen"), action: remove)
            SlideButton(symbol: "chevron.up", an: canHigh) { shove(-1) }
            SlideButton(symbol: "chevron.down", an: canGoDown) { shove(1) }
        }
        .padding(.trailing, look ? 0 : TVSpec.rowInset)
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
    @Environment(\.settingsLook) private var look
    @Environment(\.settingsActive) private var active
    @Environment(\.isFocused) private var focus

    /// In the settings the column itself is switched off until you go in; that is not a dimmed switch.
    private var dimmed: Bool { !operable && (!look || active) }

    var body: some View {
        ZStack(alignment: an ? .trailing : .leading) {
            Capsule()
                .fill(track)
                .frame(width: TVSpec.toggleWidth, height: TVSpec.toggleHeight)
            Circle()
                .fill(grip)
                .frame(width: look ? SettingsLook.toggleKnob : TVSpec.toggleKnob,
                       height: look ? SettingsLook.toggleKnob : TVSpec.toggleKnob)
                .padding(.horizontal, look ? SettingsLook.toggleInset : TVSpec.toggleInset)
        }
        .animation(operable ? Theme.motion(.easeInOut(duration: TVSpec.toggleDuration)) : nil, value: an)
    }

    /// Dimmed, not translucent: the switch keeps its position, so you still see
    /// whether it is on, just not that you could flip it.
    private var track: Color {
        guard !dimmed else {
            return an ? Theme.accent.opacity(TVSpec.toggleTrackOnDisabledOpacity) : Color.white.opacity(TVSpec.toggleTrackOffDisabledOpacity)
        }
        if look {
            // Design: off is white 18 %, on a focused row dark 18 %; on is the accent.
            if an { return Theme.accent }
            return focus ? Theme.reason.opacity(0.18) : Color.white.opacity(0.18)
        }
        return an ? Theme.accent : Color.white.opacity(TVSpec.toggleTrackOffOpacity)
    }

    private var grip: Color {
        guard !dimmed else { return Color.white.opacity(TVSpec.toggleKnobDisabledOpacity) }
        // Design: the knob is white in both states.
        if look { return .white }
        return an ? Theme.reason : Color.white
    }
}

/// Hairline between rows.
struct SeparatorLine: View {
    @Environment(\.settingsLook) private var look

    var body: some View {
        if look {
            // Design: the hairline is the last pixel inside the 84 high row, so the line takes no
            // height of its own.
            Color.clear
                .frame(height: 0)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.line).frame(height: 1).offset(y: -1)
                }
        } else {
            Rectangle().fill(Theme.line)
                .frame(height: TVSpec.hairline)
                .padding(.horizontal, TVSpec.rowInset)
        }
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

    private let size: CGFloat = TVSpec.accountStripCircle

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
        HStack(spacing: SettingsLook.accountStripSpacing) {
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
                Image(icon: "plus")
                    .font(.app(size: 30, weight: .semibold))
                    .foregroundStyle(Theme.font)
                    // Design: a round field, white 10 %, the same size as the circles next to it.
                    .frame(width: size, height: size)
                    .background(Color.white.opacity(0.10), in: Circle())
            }
            .buttonStyle(AccountStripStyle(size: size))
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

// MARK: - Settings look

/// **The measures of the settings page as the approved design draws them** (`screens.mjs`,
/// `einstellungen`). Kept here, next to the page, because only the settings use them.
enum SettingsLook {
    /// Gap between symbol column, title and value in a row.
    static let rowGap: CGFloat = 28
    /// Gap between a value and its arrow.
    static let valueGap: CGFloat = 12
    /// Inside a group, left and right; the focus surface reaches over it by the same amount.
    static let groupInset: CGFloat = 26
    /// Between a group title and its box.
    static let groupTitleGap: CGFloat = 20
    static let hairlineMargin: CGFloat = 28
    static let leftHeadingBottom: CGFloat = 16
    static let sectionGap: CGFloat = 4
    static let accountStripTop: CGFloat = 22
    static let accountStripSpacing: CGFloat = 16
    static let toggleKnob: CGFloat = 42
    static let toggleInset: CGFloat = 4
}

private struct SettingsLookKey: EnvironmentKey { static let defaultValue = false }
private struct SettingsActiveKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    /// The rows are drawn in the settings design (white focus surface over the group, hairline in the row).
    var settingsLook: Bool {
        get { self[SettingsLookKey.self] }
        set { self[SettingsLookKey.self] = newValue }
    }
    /// The right column is entered. Before that it is switched off, which must not look dimmed.
    var settingsActive: Bool {
        get { self[SettingsActiveKey.self] }
        set { self[SettingsActiveKey.self] = newValue }
    }
}

extension View {
    /// The one tvOS lift (`lift`). The design's `0 28 56 .6` read as heavy on the device.
    func settingsLift(_ on: Bool) -> some View {
        lift(on)
    }
}

/// A group title of the settings: 44/700, no inset.
private struct SettingsHeading: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .font(Theme.rail)
            .tracking(Theme.lockRail)
            .foregroundStyle(Theme.font)
    }
}

/// **A row in the settings, drawn as the design has it**, or the old `RowsStyle` anywhere the
/// settings look is not switched on (the rows are shared with other pages).
///
/// Design row: 84 high at least, 30/500 white, no surface at rest. In focus a white surface that
/// reaches 26 over the group on both sides, r16, dark type, 1.03 larger, with the lift shadow.
struct SettingsRowsStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ContentBody(configuration: configuration)
    }

    private struct ContentBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.settingsLook) private var look
        @Environment(\.settingsActive) private var active
        @Environment(\.isEnabled) private var released
        @Environment(\.isFocused) private var focus

        var body: some View {
            if look {
                configuration.label
                    .font(.app(size: 30, weight: .medium))
                    .foregroundStyle(focus ? Theme.reason : Theme.font)
                    .frame(maxWidth: .infinity, minHeight: Theme.rowsHeight, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                            .fill(Color.white)
                            .padding(.horizontal, -SettingsLook.groupInset)
                            .settingsLift(true)
                            .opacity(focus ? 1 : 0)
                    }
                    // A row that does not apply right now (bitrate with Direct Play) is muted; the
                    // whole column being switched off before you enter it is not that.
                    .opacity(released || !active ? 1 : 0.4)
                    .scaleEffect(focus ? Theme.focusMagnifierWide : 1)
                    .animation(Theme.focusAnimation, value: focus)
            } else {
                RowsStyle().makeBody(configuration: configuration)
            }
        }
    }
}
