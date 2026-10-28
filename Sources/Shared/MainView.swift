import JellyfinKit
import SwiftUI

/// The frame around everything: four sections and the bar at the bottom.
struct MainView: View {
    let model: AppModel

    @State private var section: Region = .start
    /// Only visited sections are built. Creating all four at launch would
    /// load every library immediately.
    @State private var visited: Set<Region> = [.start]
    /// Where a swipe right from search leads back to.
    @State private var previousSection: Region = .start
    /// **One per section, derived rather than counted.**
    ///
    /// They used to be listed individually, on the theory that `allCases.count`
    /// would grow silently without anyone looking at the spot. That caution
    /// caused a crash on tvOS: it stayed at four entries when the watchlist
    /// added the fifth section, and tapping "Search" went nowhere. Growing
    /// silently means it works; not growing means it breaks, and only at the
    /// last tab.
    @State private var paths = Array(repeating: NavigationPath(),
                                     count: Region.allCases.count)
    /// **Where the profile branch starts**: in which stack, at what depth.
    /// `nil` means closed. Sidebar only: while it is open, the profile icon
    /// holds the selection instead of one of the sections.
    ///
    /// Kept as its own state because a `NavigationPath` cannot be queried for
    /// what is on top. **The depth is part of it.** With only a flag, the
    /// branch could not be taken off again: tapping "Home" with the profile
    /// open set the section that was already selected, and nothing happened.
    /// Leaving via "Movies" left the profile on top on return.
    @State private var profileBranch: ProfileBranch?
    private struct ProfileBranch { let section: Region; let depth: Int }
    private var inProfile: Bool { profileBranch != nil }
    /// **The second tap on the already open tab.** See
    /// `tabStillTimes` in the environment.
    @State private var anotherTime = 0

    /// **Is something playing on another device?** See ``TakeoverModel``.
    ///
    /// Lives here and not on the home page because the badge sits in
    /// ``Kopfziele`` and thus on every root page: **one** holder polling on
    /// a timer, not five. The player hangs here for the same reason: tapping
    /// the badge starts it, and that must work from every section.
    @State private var takeover = TakeoverModel()
    /// With more than one device, ask instead of guessing.
    @State private var selectionOpen = false
    /// What the handover should start. Separate state next to the players of
    /// the individual pages, which start from their list; this one starts from
    /// the header.
    @State private var takeoverRequest: PlayRequest?
    /// Watch together: one for the whole app, see ``SharedModel``.
    @State private var gemeinsam = SharedModel.shared
    /// What a tile menu requests, see ``Kachelwunsch``.
    @State private var tileRequest = TileRequest.shared

    @Environment(\.wide) private var wide
    @Environment(\.duoColumn) private var duoColumn

    /// The symbol bar of the Duo, see ``Sidebar``.
    private var rightBar: some View {
        Sidebar(selected: Binding(
                    get: { section },
                    set: { new in
                        if new == section { closeProfileBranch() }
                        section = new
                    }),
                inProfile: inProfile,
                name: model.session?.userName ?? "?",
                image: model.userImageURL(),
                onRight: true) { toProfile() }
            .ignoresSafeArea(.keyboard)
    }

    /// Stop it over there, continue here at the same position.
    ///
    /// Command first, then plan, then start: if stopping fails, nothing
    /// happens. Otherwise two audio tracks would play in the room.
    ///
    /// **The card grows out of the badge immediately** and runs alongside the
    /// network; the player opens beneath it without its own cover and becomes
    /// visible once the card has zoomed onto its first frame
    /// (``HandoffStage``).
    private func hereContinueWatching(_ session: RemoteSession) {
        selectionOpen = false
        let stage = HandoffStage.shared
        stage.start(title: session.running, model: model)
        Task {
            guard let wish = await takeover.wish(for: session, model: model) else {
                stage.cancel("kein Plan oder Stopp abgelehnt")
                return
            }
            stage.playerComes(wish.item.id)
            var without = Transaction()
            without.disablesAnimations = true
            withTransaction(without) { takeoverRequest = wish }
        }
    }

    /// The profile icon in the sidebar.
    ///
    /// **If the branch is already open, it goes back to the profile** instead of
    /// opening a second one; before, two taps left profile on top of profile.
    private func toProfile() {
        let i = section.rawValue
        if let branch = profileBranch, branch.section == section {
            let above = paths[i].count - (branch.depth + 1)
            if above > 0 { paths[i].removeLast(above) }
            return
        }
        closeProfileBranch()
        profileBranch = ProfileBranch(section: section, depth: paths[i].count)
        paths[i].append(ProfileRoute())
    }

    /// Removes the profile branch; whatever lay beneath it stays.
    private func closeProfileBranch() {
        guard let branch = profileBranch else { return }
        let i = branch.section.rawValue
        let above = paths[i].count - branch.depth
        if above > 0 { paths[i].removeLast(above) }
        profileBranch = nil
    }


    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.reason.ignoresSafeArea()

            // **The bar sits outside the content, so the switch must too.** The value
            // used to hang on the inner `ZStack`, i.e. only on the content; the
            // `Seitenleiste` next to it got the default ("off") and dropped the wide
            // Downloads tab even when it was enabled in settings. Now it wraps both.
            HStack(spacing: 0) {
                if wide && !Theme.innerDisplay && !duoColumn {
                    // **Not `$section`.** A tap on the already open section writes the same
                    // value; only a custom binding sees it and can close the profile.
                    Sidebar(selected: Binding(
                                     get: { section },
                                     set: { new in
                                         if new == section { closeProfileBranch() }
                                         section = new
                                     }),
                                 inProfile: inProfile,
                                 name: model.session?.userName ?? "?",
                                 image: model.userImageURL()) { toProfile() }
                    // The bar stays fixed; only the content next to it yields to the
                    // keyboard.
                    .ignoresSafeArea(.keyboard)
                }

                ZStack {
                    ForEach(Region.allCases) { b in
                        if visited.contains(b) {
                            stack(b)
                                .opacity(section == b ? 1 : 0)
                                // **The pull-in happens one level deeper**, in `sectionBar()`;
                                // otherwise the bar moves along. Here we only decide which one is in
                                // front.
                                .environment(\.sectionActive, section == b)
                                .allowsHitTesting(section == b)
                        }
                    }
                }
                // **No cross-fade.** Opacity used to run on the same curve, so during the
                // switch *both* sides were half transparent: the black backdrop showed
                // through, around the Dynamic Island at the top and as tiles sliding
                // through the bar at the bottom.
                //
                // Without animation, opacity switches hard, which leaves what was
                // intended: the incoming page draws in by two points. You feel it, you
                // don't see it. Root views place the bar themselves, see
                // `sectionBar()`. Here we only decide where a tap on it goes.
                // **Not `$section` but a custom binding.** The bar writes on tap even if
                // the same section is already open, and that is the only way to detect
                // the second tap. With `$section` it is lost because the value does not
                // change.
                .environment(\.sectionSelection, Binding(
                    get: { section },
                    set: { new in
                        if new == section { anotherTime += 1 } else { section = new }
                    }))
                .environment(\.tabStillTimes, anotherTime)
                // **Whoever flips the switch while on the page must not stay there.** The
                // tab disappears, and the page would be left without a way back.
                .onChange(of: model.downloadsAn) { _, an in
                    if !an, section == .downloads { section = .start }
                }
                // The same for the watchlist: it exists only in the wide layout. Someone
                // in landscape who narrows the window would otherwise be stuck in a
                // section the bar no longer shows.
                .onChange(of: wide) { _, nowWide in
                    if !nowWide, section == .watchlist { section = .start }
                }
                // And when the watchlist is switched off in Appearance.
                .onChange(of: model.watchlistShown) { _, shown in
                    if !shown, section == .watchlist { section = .start }
                }


                // **Duo landscape: the bar stands right of the content**, symbols only.
                if wide && Theme.innerDisplay && !duoColumn { rightBar }
            }
            // **Duo upright: the system keeps a status column at the right edge and the
            // bar stands in it**, below the clock, instead of at the bottom.
            .overlay(alignment: .trailing) {
                if duoColumn {
                    rightBar
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .ignoresSafeArea()
                }
            }
            .environment(\.downloadBar,
                         DownloadBar(an: model.downloadsAn,
                                        runningCount: model.downloads.entries
                                            .filter { $0.state == .loads || $0.state == .waits }
                                            .count))


            // **Own sheet instead of `confirmationDialog`.** The system dialog adds
            // its own very bright scrim, which barely stands out above a dark page
            // full of posters.
            //
            // **The card grows out of the badge** (experiment `experiment-glas`):
            // instead of fading in mid-screen it emerges from the tapped icon and
            // shrinks back there on close. The scrim only fades.
            if selectionOpen {
                TakeoverSelection.scrim { selectionOpen = false }
                    .transition(.opacity)
                    .zIndex(5)
                TakeoverCard(sessions: takeover.offerings,
                                select: { hereContinueWatching($0) },
                                cancel: { selectionOpen = false })
                    .transition(.outPoint(BadgeOrigin.point))
                    .zIndex(5.1)
            }

            // Create, join, selection and the way back after leaving. On top of
            // everything because every page can open them.
            SharedSheets(takeover: takeover.offerings,
                              continueWatching: { hereContinueWatching($0) },
                              confirming: takeover.confirming,
                              endConfirm: { takeover.confirming = nil },
                              send: { title, output in
                                  Task { await PlayOutputs.shared.send(title, to: output, model: model) }
                              })
                .zIndex(6)

            // **What a tile menu ordered** (``TileMenu``): the loading sheet and a
            // short message. Here because not every page with tiles has its own
            // loading sheet.
            if let job = tileRequest.load {
                LoadSheet(opened: $tileRequest.loadSheetOpen, model: model,
                          entries: [job.entries], title: job.title,
                          images: job.images, qualitySelect: true)
                    .zIndex(7)
            }
            if let message = tileRequest.message {
                HintStrip(text: message) { tileRequest.message = nil }
                    .zIndex(8)
            }
        }
        .environment(takeover)
        .animation(Theme.spring, value: selectionOpen)
        // A flag instead of a closure from the environment, see
        // `TakeoverModel.angetippt`.
        .onChange(of: takeover.tapped) { _, an in
            guard an else { return }
            takeover.tapped = false
            if takeover.multiplePresent { selectionOpen = true }
            else if let a = takeover.offering { takeover.confirming = a }
        }
        .task { takeover.start(model) }
        // **"Go to the home page"** (the looks from the profile, "Show me my Home" on the
        // thank-you page): whatever lies above the home page is popped, so the profile slides
        // away to the right like on "back", and the person stays on the home page.
        .onChange(of: GiftFlow.shared.homeRequests) { _, _ in
            closeProfileBranch()
            paths[Region.start.rawValue] = NavigationPath()
            section = .start
        }
        #if DEBUG
        .task {
            guard AccountSwitchRun.an else { return }
            try? await Task.sleep(for: .seconds(4))
            AccountSwitchTransition.note("selbsttest: profil oeffnen")
            paths[section.rawValue].append(ProfileRoute())
        }
        .onChange(of: AccountSwitchTransition.shared.back) { _, _ in
            guard AccountSwitchRun.an, let ms = AccountSwitchRun.profileTip else { return }
            Task { @MainActor in
                // `back` steps one pass after the tap.
                try? await Task.sleep(for: .milliseconds(max(0, ms - 5)))
                AccountSwitchTransition.note("selbsttest: profil oben angetippt (+\(ms) ms)")
                paths[section.rawValue].append(ProfileRoute())
            }
        }
        #endif
        .task { gemeinsam.start(model) }
        // **The group starts the player, not the page.** Whoever creates or
        // joins, or whenever someone in the group sets a new title, it always
        // arrives as a queue from the server.
        .onChange(of: gemeinsam.wish?.id) { _, new in
            guard new != nil, let wish = gemeinsam.wish else { return }
            gemeinsam.wish = nil
            takeoverRequest = wish
        }
        // Play from a tile menu: the same player as above.
        .onChange(of: tileRequest.play?.id) { _, new in
            guard new != nil, let wish = tileRequest.play else { return }
            tileRequest.play = nil
            takeoverRequest = wish
        }
        // **Sent from another device**: the same player again, from every section.
        .onChange(of: model.playArrival?.id) { _, new in
            guard new != nil, let arrival = model.playArrival else { return }
            model.playArrival = nil
            Task { await PlayRequest.received(arrival.order, model: model) { takeoverRequest = $0 } }
        }
        #if DEBUG && os(iOS)
        .task {
            guard JumpRun.an else { return }
            try? await Task.sleep(for: .seconds(3))
            guard let wish = await JumpRun.wish(model) else { return }
            takeoverRequest = wish
            await JumpRun.flow(model) { takeoverRequest = nil }
        }
        .task {
            guard BatteryRun.an, BatteryRun.withServer else { return }
            try? await Task.sleep(for: .seconds(3))
            guard let wish = await BatteryRun.wish(model) else { return }
            takeoverRequest = wish
            await BatteryRun.flow(model) { takeoverRequest = nil }
        }
        .task {
            guard SwitchRun.an else { return }
            try? await Task.sleep(for: .seconds(3))
            guard let wish = await SwitchRun.wish(model) else { return }
            takeoverRequest = wish
            await SwitchRun.flow(model) { takeoverRequest = nil }
        }
        .task {
            guard OfflineRun.an else { return }
            try? await Task.sleep(for: .seconds(3))
            guard let wish = await OfflineRun.wish(model) else {
                await OfflineRun.cleanUp(model)
                return
            }
            takeoverRequest = wish
            await OfflineRun.flow(model) { takeoverRequest = nil }
        }
        #endif
        .onDisappear { takeover.finish() }
        .playerCover(item: $takeoverRequest) { wish in
            PlayerScreen(model: model, item: wish.item,
                         plan: wish.plan, startAt: wish.startAt, tracks: wish.tracks)
        }
        // Deliberately without a transition: the bar should stay fixed and
        // simply be there again on return, like the content behind it. Faded in,
        // it looked like a separate sheet.
        .task { await model.remoteControlStart() }
        // **Once on opening, not continuously.** One request per launch is
        // enough: it says what has been watched and what the server no
        // longer has. Neither changes by the minute, and on the road it
        // fails anyway, in which case everything stays as is.
        .task { await model.downloadsCatchUp() }
        // Otherwise the socket stays open when the view goes away, e.g. on
        // sign-out, where `RootView` switches to the sign-in screen.
        //
        // **But not because the player is on top.** On iPhone UIKit shows the
        // player in its own frame (`PlayerFrame`, `.fullScreen`), so this view
        // disappears for SwiftUI. If the socket closed then, the server would no
        // longer treat the session as controllable, and other devices would see
        // the iPhone not at all or as "playing nothing" exactly during playback,
        // with no "Continue here". On iPad (`fullScreenCover`) this never
        // happened.
        .onDisappear {
            guard PlayerFrame.active == nil else { return }
            Task { await model.remoteControlEnd() }
            gemeinsam.finish()
        }
        .onChange(of: section) { alt, new in
            visited.insert(new)
            if alt != .search { previousSection = alt }
            // **The profile does not stay in the old section**, or it would be on top
            // again on return. The old stack is hidden now; whatever navigates back
            // there is not seen.
            closeProfileBranch()
        }
        // **Back to below the profile means: the branch is closed.** Before, it
        // meant "the stack is empty"; if a detail page lay under the profile, the
        // icon stayed highlighted although the profile was long gone.
        .onChange(of: paths.map(\.count)) { _, numbers in
            if let branch = profileBranch, numbers[branch.section.rawValue] <= branch.depth {
                profileBranch = nil
            }
        }
        // **the side stack is emptied on account switch.**
        //
        // A stack belongs to one account; what lies on it belongs to the previous
        // one. A detail page hangs on `.task(id: title.id)`, a series page on its
        // season, search on its term, and **none** of these identifiers changes on
        // the switch. Without emptying, checkmarks and progress bars of the
        // previous account would show, and pressing Play would resume from its
        // position and report it to the new account.
        //
        // Deliberately here and not in each page: that would be five places per
        // platform, and the next new page forgets it. Found by the Mac version.
        .onChange(of: model.accountSwitch) { _, _ in
            // Already emptied from the profile selection, on tap, see below.
            guard !AccountSwitchTransition.shared.stackAlreadyEmpty() else { return }
            emptyStack()
        }
        // **On tap in the profile selection** (experiment `experiment-glas`,
        // design D) a still image of the page slides away; beneath it the stack
        // jumps back without animation, so nothing of it is visible.
        .onChange(of: AccountSwitchTransition.shared.back) { _, _ in
            var without = Transaction()
            without.disablesAnimations = true
            withTransaction(without) { emptyStack() }
        }
        .background { keysAbbreviation }
        .preferredColorScheme(.dark)
    }

    /// **The same shortcuts as on the Mac** (`MenuBar`): ⌘1–5 for the
    /// sections, ⌘F for search, ⌘, for settings. iPad with keyboard had no
    /// shortcut at all; holding ⌘ now shows them in the system overview.
    ///
    /// Invisible buttons because no visible counterpart is needed: every entry
    /// already has its own in the bar. Watchlist and Downloads only where the
    /// bar shows them.
    private var keysAbbreviation: some View {
        VStack {
            sectionKey("Start", .start, "1")
            sectionKey("Filme", .movies, "2")
            sectionKey("Serien", .seriesList, "3")
            if wide, model.watchlistShown { sectionKey("Merkliste", .watchlist, "4") }
            if model.downloadsAn { sectionKey("Downloads", .downloads, "5") }
            sectionKey("Suchen", .search, "f")
            Button("Einstellungen") { toSettings() }
                .keyboardShortcut(",", modifiers: .command)
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func sectionKey(_ title: LocalizedStringKey, _ target: Region,
                               _ keyButton: KeyEquivalent) -> some View {
        Button(title) { section = target }
            .keyboardShortcut(keyButton, modifiers: .command)
    }

    /// Open the profile, then settings on it: the path a tap also takes.
    private func toSettings() {
        toProfile()
        paths[section.rawValue].append(SettingsRoute())
    }

    private func emptyStack() {
        for i in paths.indices where !paths[i].isEmpty {
            paths[i] = NavigationPath()
        }
        profileBranch = nil
    }

    @ViewBuilder
    private func stack(_ b: Region) -> some View {
        NavigationStack(path: $paths[b.rawValue]) {
            Group {
                switch b {
                case .start:
                    HomeView(model: model)
                case .movies:
                    LibraryView(model: model, art: "movies", title: "Filme")
                case .seriesList:
                    LibraryView(model: model, art: "tvshows", title: "Serien",
                                   filter: [.all, .begun, .watchlist])
                case .search:
                    SearchView(model: model, active: section == .search) {
                        section = previousSection
                    }
                case .downloads:
                    DownloadsView(model: model)
                case .watchlist:
                    // **Wide, it is a place, not a path.** Narrow, it slides in from the
                    // right because it hangs on the icon at the top right; wide, it sits in
                    // the bar, and what sits in a bar does not slide in. Hence no back arrow
                    WatchlistView(model: model)
                }
            }
            .targetPlace(model: model)
        }
    }

}

// MARK: - Shared destinations

extension View {
    /// The jump destinations hang on the stack, not on the individual page;
    /// otherwise every section would have to know them separately.
    func targetPlace(model: AppModel) -> some View {
        self
            // **`LibraryRoute` has no destination here anymore.**
            //
            // `ItemListView` hung on it and was dead code: no caller ever created
            // the route, and the page used Apple's `ContentUnavailableView` instead
            // of our empty state, so it would have looked out of place had anyone
            // opened it. The type itself stays: Mac and TV use it, where it leads to
            // a library page of its own.
            .navigationDestination(for: SeerrHit.self) { hit in
                SeerrDetailView(model: model, hit: hit)
            }
            .navigationDestination(for: Item.self) { item in
                if item.type == "Series" {
                    SeriesDetailView(model: model, series: item)
                } else if item.type == "Playlist" {
                    PlaylistView(model: model, playlist: item, art: nil)
                } else if item.type == "BoxSet" {
                    // A collection from search or watchlist: no section, so everything in it.
                    CollectionView(model: model, collection: item, art: nil)
                } else if item.type == "Episode" {
                    // Episodes get no page of their own; they lead to their season. A page
                    // for a single episode would carry nothing the list does not already show.
                    SeasonTarget(model: model, episode: item)
                } else {
                    ItemDetailView(model: model, item: item)
                }
            }
            .navigationDestination(for: CollectionRoute.self) { route in
                CollectionView(model: model, collection: route.collection, art: route.art)
            }
            .navigationDestination(for: PlaylistRoute.self) { route in
                PlaylistView(model: model, playlist: route.playlist, art: route.art)
            }
            .navigationDestination(for: WatchlistRoute.self) { _ in
                WatchlistView(model: model)
            }
            .navigationDestination(for: DownloadSeriesRoute.self) { route in
                DownloadSeriesView(model: model, route: route)
            }
            .navigationDestination(for: ProfileRoute.self) { _ in
                ProfileView(model: model)
            }
            .navigationDestination(for: QuickConnectRoute.self) { _ in
                QuickConnectView(model: model)
            }
            .navigationDestination(for: SettingsRoute.self) { _ in
                SettingsView(model: model)
            }
            .navigationDestination(for: SeerrRoute.self) { _ in
                SeerrSettingsView(model: model, seerr: model.seerr)
            }
            .navigationDestination(for: TraktRoute.self) { _ in
                TraktSettingsView(trakt: model.trakt)
            }
            .navigationDestination(for: PlaybackRoute.self) { _ in
                PlaybackSettingsView(model: model)
            }
            .navigationDestination(for: SeasonRoute.self) { route in
                SeasonView(model: model, series: route.series, season: route.season)
            }
            .navigationDestination(for: PersonRoute.self) { route in
                PersonView(model: model, route: route)
            }
            .navigationDestination(for: GenreRoute.self) { route in
                GenreView(model: model, name: route.name)
            }
            .navigationDestination(for: PresentationRoute.self) { _ in
                PresentationView(model: model)
            }
            .navigationDestination(for: LicensesRoute.self) { _ in
                LicensesView()
            }
            .navigationDestination(for: LicenseRoute.self) { route in
                if let b = LicenseState.shared?.component(id: route.id) { LicenseView(component: b) }
            }
            .navigationDestination(for: LicenseOfferingRoute.self) { _ in
                LicenseOfferingView()
            }
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            // The modifier above applies to the root; pushed destinations each carry
            // it individually. That is not enough: it only takes effect after the
            // first frame, and until then a system back button showed at the top.
            // `SystemBarDistance` hides the bar on the navigation host, i.e. for the
            // whole stack.
            .background(SystemBarDistance())
            #endif
    }
}

// MARK: - Movies and series

/// A whole library as its own section.
struct LibraryView: View {
    let model: AppModel
    let art: String
    let title: LocalizedStringKey
    /// For series the third filter is named differently: "unwatched" helps
    /// little there, "new episodes" is the question people actually have.
    var filter: [LibraryFilter] = LibraryFilter.allCases
    @Environment(\.watchlistShown) private var watchlistShown

    /// What the pills offer: without the watchlist when it is switched off.
    private var offeredFilter: [LibraryFilter] {
        LibraryFilter.offered(filter, watchlist: watchlistShown)
    }

    /// Paging, filtering and sorting live in `LibraryModel`, shared with
    /// the tvOS version.
    @State private var state: LibraryModel
    /// The letter strip: where to scroll, which titles are on screen, and the letter of
    /// the topmost one.
    @State private var jump: ScrollJump?
    @State private var onScreen = OnScreenTiles()
    @State private var topLetter: String?
    @State private var sortListOpen = false
    @State private var filterListOpen = false

    /// **The persistence name must be fixed at creation.**
    ///
    /// Sort order and filter come from the store and must be correct on the
    /// first pass, otherwise the chip row shows "A–Z" for a moment and then
    /// jumps. A `@State` with an initial value can do that, setting it
    /// afterwards cannot.
    init(model: AppModel, art: String, title: LocalizedStringKey,
         filter: [LibraryFilter] = LibraryFilter.allCases) {
        self.model = model
        self.art = art
        self.title = title
        self.filter = filter
        _state = State(initialValue: LibraryModel(rememberName: art))
    }
    /// How far it has scrolled; the hairline under the header depends on it.
    @State private var offset: CGFloat = 0
    /// How tall the header is. **Measured, not typed.**
    ///
    /// This used to be `112`, computed for title plus chip row. Once the
    /// server name was added under the title, the number was wrong, and it
    /// would be wrong again after the next addition: the first row of tiles
    /// disappeared under the header with no build warning.
    /// Which library of this kind is shown.
    ///
    /// A server can have several movie libraries (for example one on an
    /// external disk and one local). Before, the view silently took the first
    /// and the second was unreachable.
    ///
    /// **More than one library:** "All" at the top, then "Collections", then
    /// the libraries; the rule is in ``SectionOffering``. With only one movie
    /// and one series library and no collections there is no menu and
    /// everything looks as before.
    @State private var choice: SectionSelection = .all
    @State private var libraryListOpen = false
    /// The running load: **there is only ever one.** It is triggered from four
    /// places (identifier, library choice, late offer, "Try again"); before,
    /// they ran side by side.
    @State private var loadTask: Task<Void, Never>?
    /// An account switch is running: content, counter and error message hold
    /// still.
    @State private var change = false

    @Environment(\.wide) private var wide
    /// Is this section in front? Only then does what the scroll view reports
    /// count.
    @Environment(\.sectionActive) private var sectionActive
    @Environment(\.tabStillTimes) private var anotherTime

    /// The column count follows the width, and tiles fill their column.
    ///
    /// This used to be three fixed ones. `.adaptive` had been rejected before,
    /// rightly: with a 112 pt minimum width only two fit side by side on 390
    /// (3 × 112 + 2 × 12 is 360, but the content is only 354), leaving a gap of
    /// half a tile on the right.
    ///
    /// `Theme.columns(usableNow:)` instead works from a target width and lets the
    /// tiles stretch. On every iPhone this yields exactly the previous three.
    private func columns(_ count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Theme.tileSpacing),
              count: count)
    }

    var body: some View {
        // The width must be known before the grid: `LazyVGrid` takes its columns
        // as an argument, not as a result.
        GeometryReader { frameRect in
            content(usableNow: frameRect.size.width - Theme.margin(wide: wide) - trailingLane)
        }
        // **Before the sheets.** The order is the whole point: content, bar,
        // sheet. The reason is at `sectionBar()`.
        .sectionBar()
        // **The sheets belong on the page, not on the header.**
        //
        // They used to hang on `header`. An overlay gets the frame of what it lies
        // on, which was about a hundred points tall. The sheet therefore sat at
        // the top without a scrim, and its list got no height: only "Sort" and
        // "Cancel" were visible.
        //
        // Reproduced in the simulator. The bug is **older** than the rework of the
        // sheet motion; it was unchanged after reverting to the verified state.
        // **Without `if`: the container stays, the sheet gates itself.** Only so
        // do the transitions of scrim and card run separately.
        .shelfSheets(state: state, filter: offeredFilter,
                       filterOpen: $filterListOpen, sortingOpen: $sortListOpen)
        // No `Menu`. The same `SelectionSheet` as for sorting; the
        // "Libraries" section separates the libraries from "All" and
        // "Collections", which are not libraries.
        .overlay(alignment: .topTrailing) {
                SelectionSheet(opened: $libraryListOpen,
                             title: title,
                             entries: offering.entries,
                             label: { label($0) },
                             isSelected: { $0 == choice },
                             select: { new in
                                 guard new != choice else { return }
                                 model.sectionSelect(new, art: art)
                                 choice = new
                                 newLoad()
                             },
                             category: { $0 == offering.firstLibrary ? "Bibliotheken" : nil })
        }
        // **The library does not belong in the identifier.**
        //
        // It was in there once, and that was a bug: `load()` sets the choice
        // itself on the first run, which changes the identifier and cancels its
        // own task. The cancelled request came back as a failure, and the page
        // showed "No contact to the server" above the posters the second run had
        // just loaded.
        //
        // It only changes on tap, which also reloads.
        //
        // **The account switch belongs in the identifier.** It carried only sort
        // and filter; on a switch neither changes, and the library kept showing
        // the previous account's titles. On the Mac this is exactly what
        // happened. `LibraryModel.veraltet(_:)` refuses appending, so the
        // view must trigger the reload, and `.task(id:)` is where it already does
        // so for sort and filter.
        //
        // Via the identifier and not an extra `onChange`: that way the running
        // request of the old account is cancelled instead of continuing next to
        // the new one. `load()` explains why a cancellation is not a failure
        // here.
        .task(id: "\(state.identifier)|\(model.accountSwitch)") { await loadAlone() }
        // **Libraries can arrive after the page.**
        //
        // `load()` picks one from `model.views` on the first run; if the list
        // is still empty then (cold start, slow server), the choice stays `nil`:
        // the title has no name and the page shows all kinds mixed until someone
        // switches by hand. Nothing triggered a second run.
        //
        // Via the identifiers and not the count: if one library disappears and a
        // new one appears, the count stays the same.
        //
        // The same applies to collections and mixed libraries: they arrive later
        // from `offeringLoad()`. If that changes what "All" reads or what may be
        // selected, it reloads.
        // Watched or bookmark changes elsewhere: reload quietly, otherwise the
        // tiles show stale bars and checkmarks.
        .catchUp(at: model.listenRefresh) { newLoad() }
        .onChange(of: offeringId) { _, _ in
            let new = model.sectionSelection(art: art)
            guard new != choice || source?.key != loadedSource else { return }
            choice = new
            newLoad()
        }
    }

    private func content(usableNow: CGFloat) -> some View {
        let count = Theme.columns(usableNow: usableNow, wide: wide)
        return ZStack(alignment: .top) {
            Theme.reason.ignoresSafeArea()

            ScrollViewReader { reader in
            ScrollView {
                // **Placeholder instead of a spinner.** While nothing is there, the grid
                // already shows its shape, so the page looks empty, not waiting. It
                // cross-fades once the titles arrive.
                if state.items.isEmpty, state.loads, !listChoice {
                    GridPlaceholder(columns: count)
                        .padding(.horizontal, Theme.margin(wide: wide))
                        .padding(.top, 8)
                        .transition(.opacity)
                }

                LazyVGrid(columns: columns(count), alignment: .leading, spacing: 20) {
                    if choice == .collections {
                        collectionTiles
                    } else if choice == .playlists {
                        playlistTiles
                    } else {
                    ForEach(state.items) { item in
                        NavigationLink(value: item) {
                            PosterTile(model: model, item: item, width: nil)
                        }
                        .buttonStyle(Theme.PressButton())
                        .tileMenu(item, model: model)
                        .id(item.id)
                        // Load more as soon as the third-to-last row appears, so the next batch
                        // is ready before the bottom is reached.
                        .onAppear {
                            onScreen.ids.insert(item.id)
                            updateTopLetter()
                            guard state.solvesLoadMoreOut(item.id, columns: count),
                                  let source else { return }
                            Task { await state.loadMore(model, from: source) }
                        }
                        .onDisappear {
                            onScreen.ids.remove(item.id)
                            updateTopLetter()
                        }
                    }
                    }
                }
                .padding(.leading, Theme.margin(wide: wide))
                .padding(.trailing, trailingLane)
                .padding(.top, 8)
                .opacity(state.items.isEmpty && !listChoice ? 0 : 1)

                // **No spinner when loading more.** The next row arrives on its own
                // anyway; a spinner below would only say something is running, which
                // should go unnoticed.
                if state.stillMorePresent, !listChoice, state.loadMoreFailed,
                   let source {
                    Button("Erneut versuchen") {
                        Task { await state.loadMore(model, from: source) }
                    }
                    .buttonStyle(Theme.PressButton())
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                    .padding(.top, 12)
                } else if state.stillMorePresent, !listChoice {
                    GridPlaceholder(columns: count, rails: 1)
                        .padding(.horizontal, Theme.margin(wide: wide))
                        .padding(.top, 20)
                }
            }
            .scrollIndicators(.hidden)
            .animation(Theme.reveal, value: state.items.isEmpty)
            // On account switch like the home page: old content disappears at once,
            // the new one fades in staggered.
            .accountSwitchFade(model: model,
                                ready: !state.outdated(model) && (!state.items.isEmpty || !state.loads) && !state.disrupted,
                                change: $change)
            // New order means start at the top; so does the second tap on the tab
            // you are already in.
            .toTop(order: "\(state.identifier)|\(choice)", anotherTime: anotherTime,
                      active: sectionActive)
            // **A plain reader, not scroll targets.** `scrollTargetLayout` made the scroll
            // view anchor on tiles and, when the list changed (library, filter), centre them
            // sideways: the grid ended up off to the left. `.topLeading` never moves it
            // sideways either.
            // A short glide from letter to letter; while sliding along the strip each new
            // letter simply takes over the glide.
            .onChange(of: jump) { _, new in
                guard let new else { return }
                let anchor = jumpAnchor(for: new.id, columns: count, usableNow: usableNow)
                withAnimation(Motion.select) {
                    reader.scrollTo(new.id, anchor: anchor)
                }
            }
            .overlay(alignment: .trailing) {
                if let alphabet = shownAlphabet {
                    // **Appears at once, with the margin and the columns.** An animated relayout
                    // of a long grid is what pushed it sideways.
                    AlphabetRail(index: alphabet, current: topLetter) { letter in
                        Task {
                            guard let source,
                                  let id = await state.jumpTarget(letter, model: model, from: source)
                            else { return }
                            jump = ScrollJump(id: id, serial: (jump?.serial ?? 0) + 1)
                        }
                    }
                    .padding(.trailing, (trailingLane - AlphabetRail.width) / 2)
                    .padding(.top, 8)
                    .padding(.bottom, wide ? 24 : Theme.stripHeight + 12)
                }
            }
            .task(id: "\(state.identifier)|\(source?.key ?? "")|\(model.accountSwitch)|\(model.alphabetShown)") {
                guard model.alphabetShown, !listChoice else { return }
                await state.loadAlphabet(model, from: source)
            }
            // The finger's path, not the offset adjusted for the edge; why is
            // explained in `HeaderScrollDistance` in the package.
            .scrollDistance(active: sectionActive) { offset = $0 }
            .contentMargins(.bottom, wide ? 24 : Theme.stripHeight + 12,
                            for: .scrollContent)
            // Only the scroll area draws in on the switch; the header above sits
            // fixed like the bar below.
            // The look's glow, the same on every main page; goes up with the content.
            .lookGlow()
            .areaContent()
            // **The header is a safe-area inset, not an overlay.**
            //
            // Before, it hung above as an overlay, and its top margin came from its
            // own measurement: `onGeometryChange` wrote the height into a state that
            // fed back into **the same** area as `contentMargins(.top,)`. That is a
            // cycle, and it oscillated: the server name only appears once fetched,
            // the header grows by a line, the margin changes, the content shifts, the
            // geometry changes again.
            //
            // Two dampings were tried first and both were wrong: a threshold does not
            // catch it because the jump is a whole line, and "only grow" turns a
            // single oversized measurement into a permanent huge gap, which was the
            // hole afterwards.
            //
            // `safeAreaInset` measures nothing. SwiftUI places the header at the top,
            // adjusts the inset itself and lets content run underneath: the same
            // image without feedback. There is no number left that could be wrong.
            .safeAreaInset(edge: .top, spacing: 0) { header }
            }


            if listChoice {
                // The list is already in memory: "Collections" appears in the menu only if
                // there are any. No loading, no empty state.
            } else if change || AccountSwitchTransition.shared.waits {
                // On account switch neither error nor empty state: just empty.
            } else if state.disrupted {
                // The same text as on the home page, including the server address.
                // Before it said "Nothing here yet": the same cause with two diagnoses,
                // and the wrong one sends you to the server instead of the network.
                EmptyState.serverDived(model, retry: { newLoad() })
                    .padding(.bottom, Theme.stripHeight)
            } else if state.items.isEmpty, !state.loads {
                // **`!loads` is not decoration.** It was here while a spinner hung next
                // to it; when the spinner was removed, it dropped out too, and since then
                // "Nothing here yet" flashed for a second on first open before the titles
                // arrived. Reporting an empty library before having asked is a false
                // statement.
                EmptyState(
                    symbol: state.filter == .all ? "tray" : "line.3.horizontal.decrease",
                    headerLine: state.filter == .all ? "Hier ist noch nichts"
                                                 : "Nichts gefunden",
                    text: state.filter == .all
                        ? "Sobald in dieser Bibliothek etwas liegt, taucht es hier auf."
                        : "Unter \u{201E}\(state.filter.label)\u{201C} liegt gerade nichts. Nimm einen anderen Filter.",
                    quietButton: state.filter == .all
                        ? ("Aktualisieren", { newLoad() })
                        : ("Filter zurücksetzen", { state.filter = .all }))
                    .padding(.bottom, wide ? 0 : Theme.stripHeight)
            }
        }
    }

    /// No switching on the road and no fly-in: header icon and content stand
    /// still.
    private var present: Bool { !change && !AccountSwitchTransition.shared.waits }

    private var header: some View {
        BlurHeader(offset: offset) {
            // No spacing in the stack: the 14 between title and value row is carried
            // by `ValueRail` itself so it disappears with it.
            VStack(alignment: .leading, spacing: 0) {
                // **Centered, not top.** While the server name still sat under the title,
                // `.top` was right: the block was two lines tall, and the icons on the
                // right should hang on the first. Without the second line the title sits
                // at the top and the icons beside it lower, on different lines.
                // Feedback: "they are not on the same line as the profile picture".
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        // **A menu only from two libraries.**
                        //
                        // Whoever has one (almost everyone) sees exactly what they saw before: a
                        // heading, no icon, no tap target. A switcher with nothing to switch is a
                        // question without an answer.
                        if offering.isMenu {
                            // No `Menu`. The same `SelectionSheet` as for sorting, and it
                            // takes the label as a `String`, which is needed here: library names
                            // come from the server.
                            //
                            // **"All" is simply called "Movies".** The title says where you are;
                            // "All movies" appears only in the menu.
                            Button { libraryListOpen = true } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Group {
                                        if choice == .all { Text(title) }
                                        else { Text(verbatim: label(choice)) }
                                    }
                                        .font(Theme.titleLarge).tracking(Theme.lockTitle)
                                    Image(systemName: "chevron.down")
                                        .font(Theme.listTitle)
                                        .foregroundStyle(Theme.fontQuiet)
                                        .accountSwitchPart(present: present)
                                }
                            }
                            .buttonStyle(Theme.PressButton())
                        } else {
                            Text(title).font(Theme.titleLarge).tracking(Theme.lockTitle)
                        }

                        // **No server name under the title.**
                        //
                        // It was here so that two accounts' libraries could be told apart. On the
                        // device the line costs more than it brings: it pushes the filter pills
                        // and the grid down, and the page title gets a base no other root page
                        // has. Whoever wants to know which server they are on finds it in the
                        // profile, where it is shown anyway.
                    }
                    Spacer(minLength: 0)
                    // **Wide, the count sits up here, not in the chip row**, just as on the
                    // Mac, where it sits next to the title. If it stayed below, something
                    // stood after the sort chips and the two gaps shared the space equally:
                    // the chips ended up in the middle instead of on the right.
                    if wide, shown > 0 {
                        CountMark(count: shown).accountSwitchPart(present: present)
                    }
                    // Wide, the profile icon sits in the sidebar, for all four sections. Here
                    // it would be the second. The same group as on the home page: watchlist
                    // and profile belong together, so they stand together everywhere. The
                    // "continue watching here" offer stays with the home page: a tap on it
                    // starts playback, and the player hangs there.
                    if !wide {
                        HeaderTargets(name: model.session?.userName ?? "?",
                                  image: model.userImageURL())
                    }
                }
                .foregroundStyle(Theme.font)

                // **Wide, it stays open.** There they are chips instead of pills, they
                // sit in a sidebar composition with plenty of room, and the header does
                // not take half a row of tiles. Collapsing solves a problem that does not
                // exist wide.
                ShelfControls(state: state, filter: offeredFilter,
                               filterOpen: $filterListOpen,
                               sortingOpen: $sortListOpen,
                               offset: offset,
                               onlyCount: listChoice ? shown : nil)
                    .accountSwitchPart(present: present)
            }
        }
    }

    // The control row lives in `ShelfControls` (CollectionPage.swift); the
    // collection page needs the same one.

    /// Restarts `load()` and cancels the previous run.
    private func newLoad() {
        Task { await loadAlone() }
    }

    /// `load()` as the only run: the previous one is cancelled, and if this
    /// one is cancelled (`.task(id:)`), the cancellation propagates.
    private func loadAlone() async {
        loadTask?.cancel()
        let task = Task { await load() }
        loadTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func load() async {
        if model.views.isEmpty { await model.loadViews() }
        // Collections and mixed libraries arrive on the side; the page does not
        // wait for them. When they arrive, `offeringId` signals it and the
        // choice is rechecked.
        Task { await model.offeringLoad() }
        // **The remembered choice belongs to an account.** It is checked against
        // the signed-in account's offer on every load; a library of the previous
        // account does not exist in it, and the page falls back to "All" instead
        // of requesting a foreign identifier.
        choice = model.sectionSelection(art: art)
        guard !listChoice else { return }
        loadedSource = source?.key
        await state.load(model, from: source)
    }

    /// What the title offers as choices. From two entries it becomes a menu.
    private var offering: SectionOffering { model.sectionOffering(art: art) }

    /// If this changes, the choice is rechecked, via the identifiers and not
    /// the count: if one library disappears and a new one appears, the count
    /// stays the same.
    private var offeringId: String {
        offering.entries.map(\.rememberValue).joined(separator: ",") + "|"
            + offering.allSources.joined(separator: "+")
    }

    /// What the grid reads from. `nil`: there is nothing in this section.
    private var source: ShelfSource? {
        switch choice {
        case .all:
            // From one library as before the rework; from several, filtered to one
            // per title (``TitleFilter``).
            offering.hasInventory
                ? ShelfSource(parent: offering.allOut, art: art,
                              onlyOut: offering.allOut == nil ? offering.allSources : [])
                : nil
        case .library(let id):
            ShelfSource(parent: id, art: art)
        case .collections, .playlists:
            nil
        }
    }
    @State private var loadedSource: String?

    private var collectionList: [ItemCollection] {
        model.collectionDirectory?.collections(art: art) ?? []
    }

    /// What the counter badge shows.
    private var shown: Int {
        switch choice {
        case .collections: collectionList.count
        case .playlists:   playlistList.count
        default:           state.total
        }
    }

    /// "Collections" and "Playlists" come from memory, not from a query.
    private var listChoice: Bool { choice == .collections || choice == .playlists }

    /// The strip only where it means something: switched on, sorted A–Z, a grid of titles,
    /// and more than one letter.
    private var shownAlphabet: AlphabetIndex? {
        guard model.alphabetShown, state.sorting == .name, !listChoice,
              let alphabet = state.alphabet, alphabet.isUseful else { return nil }
        return alphabet
    }

    /// The anchor that jumps to a tile without moving the grid sideways
    /// (``ScrollJump/anchor(index:columns:leading:trailing:usable:spacing:)``).
    private func jumpAnchor(for id: String, columns: Int, usableNow: CGFloat) -> UnitPoint {
        guard let index = state.items.firstIndex(where: { $0.id == id }) else { return .top }
        return ScrollJump.anchor(index: index, columns: columns, leading: Theme.margin(wide: wide),
                                 trailing: trailingLane, usable: usableNow, spacing: Theme.tileSpacing)
    }

    /// **The right margin makes room for the strip** and centres it, so the gap to the
    /// screen edge and the gap to the posters are the same. On iPhone the margin grows
    /// from 18 to the strip's width; on iPad the wide margin already fits it. Without the
    /// strip (not "By name", or switched off) the margin is the usual one again.
    private var trailingLane: CGFloat {
        let margin = Theme.margin(wide: wide)
        return shownAlphabet == nil ? margin : max(margin, AlphabetRail.width)
    }

    /// The letter of the first loaded title on screen (the grid keeps a row or so beyond
    /// the edge alive, so the top row or the one just above it). **Written only when it
    /// changes**: tiles come and go on every scroll, and a state change per tile would
    /// redraw the whole page each time.
    private func updateTopLetter() {
        guard shownAlphabet != nil,
              let item = state.items.first(where: { onScreen.ids.contains($0.id) }) else { return }
        let letter = AlphabetIndex.letter(name: item.name, sortName: item.sortName)
        if letter != topLetter { topLetter = letter }
    }

    private var playlistList: [VideoPlaylist] {
        model.playlistDirectory?.playlists(art: art) ?? []
    }

    /// **Playlists in the same grid, with the same tile**, as collections are. Under
    /// the name it shows how many entries there are in this section.
    @ViewBuilder
    private var playlistTiles: some View {
        ForEach(playlistList) { list in
            NavigationLink(value: PlaylistRoute(playlist: list.item, art: art)) {
                PosterTile(model: model, item: list.item, width: nil,
                           inquiry: String(localized: "\(list.count(art: art)) Titel"))
            }
            .buttonStyle(Theme.PressButton())
        }
    }

    /// **Collections in the same grid, with the same tile.** Under the name,
    /// instead of the year, it shows how many movies or series are in it.
    @ViewBuilder
    private var collectionTiles: some View {
        ForEach(collectionList) { collection in
            NavigationLink(value: CollectionRoute(collection: collection.item, art: art)) {
                PosterTile(model: model, item: collection.item, width: nil,
                           inquiry: countText(collection.count(art: art)),
                           mosaicSource: (collection, art))
            }
            .buttonStyle(Theme.PressButton())
        }
    }

    private func countText(_ n: Int) -> String {
        ItemCollection.countText(art: art, count: n)
    }

    private func label(_ w: SectionSelection) -> String {
        switch w {
        case .all:
            art == "tvshows" ? String(localized: "Alle Serien") : String(localized: "Alle Filme")
        case .collections:
            String(localized: "Sammlungen")
        case .playlists:
            String(localized: "Wiedergabelisten")
        case .library(let id):
            offering.library(id)?.name ?? ""
        }
    }
}

// MARK: - Detour from an episode to its series

/// Fetches the series for the episode and shows the **series page**, with
/// the episode's season already selected.
///
/// Not the bare episode list: the same page as from "Recently added" was
/// intended, with hero image, play button, Direct Play and the tabs. List
/// entries carry only `seriesId`, not the series itself, hence this
/// intermediate step.
struct SeasonTarget: View {
    let model: AppModel
    let episode: Item

    @State private var series: Item?

    /// **What is prefetched is there immediately**, so the empty page never
    /// appears.
    ///
    /// Supplied later, the value would come too late: the empty pass has
    /// already happened, and that is exactly what you see. The same reasoning
    /// as `Backdrop` on tvOS, and literally the path the Mac version takes.
    @MainActor init(model: AppModel, episode: Item) {
        self.model = model
        self.episode = episode
        _series = State(initialValue: SeriesCache.shared.series(for: episode, with: model))
    }
    /// **Fetch the season fresh, don't trust the tile's.**
    ///
    /// The list entry carries the season it had when the home page loaded.
    /// Someone who finishes a season and adds the next one still has the old
    /// one there: the page then opened with "Play S6E1" on top and season 5 in
    /// the episode list. The same pattern as the resume point in
    /// `HomeView.starte`, with the same remedy.
    @State private var freshSeasonID: String?

    var body: some View {
        ZStack {
            Theme.reason.ignoresSafeArea()
            if let series {
                SeriesDetailView(model: model, series: series,
                                 startSeasonID: freshSeasonID ?? episode.seasonId,
                                 startSeasonNumber: episode.parentIndexNumber)
            } else if disrupted {
                // Fetching the series failed: otherwise a black page would remain, with
                // only the back swipe as a way out.
                DisturbHint(model: model, retry: { Task { await seriesFetch() } },
                             spacingTop: 120)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                // No spinner: the page arrives on its own shortly.
                Color.clear
            }
        }
        #if os(iOS)
        // **Must be set here, not only in the series page.**
        //
        // This view is an intermediate step: it shows a spinner until the series
        // has been fetched. Without the line, Apple's bar shows in the meantime,
        // and the system button flashes before ours replaces it. Every jump
        // destination must set it itself; one that forgets will flash.
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        #endif
        .task { await seriesFetch() }
    }

    /// Fetching the series failed, not cancelled.
    @State private var disrupted = false

    private func seriesFetch() async {
        guard let id = episode.seriesId else { return }
        disrupted = false
        async let freshValue = model.item(id: episode.id)
        if series == nil {
            let fetched = await model.item(id: id)
            // So the next path to the same series does not take it again: search,
            // "Similar", a second attempt.
            if let fetched { SeriesCache.shared.remember(fetched) }
            if fetched == nil, Task.isCancelled { return }
            series = fetched
            disrupted = fetched == nil
        }
        freshSeasonID = await freshValue?.seasonId
    }
}
