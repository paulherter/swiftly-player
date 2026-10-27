import JellyfinKit
import SwiftUI

/// Which section the sidebar shows. The same four as the bottom bar on iPhone.
enum Region: String, Hashable, CaseIterable {
    case start, movies = "filme", seriesList = "serien", watchlist = "merkliste", downloads, search = "suche"

    /// What the sidebar contains. without the switch there is no downloads row.
    ///
    /// Downloads sits **at the top with the sections**, not below with the collections,
    /// unlike the watchlist. The watchlist is a library whose boundary is the checkmark;
    /// downloads are not a selection from the server but what lies on this machine. On
    /// iPhone it is a tab for the same reason, not a destination in the header.
    /// **At the top, what the server has.** Four rows.
    static let topGroup: [Region] = [.start, .movies, .seriesList, .search]

    /// **Below that, what is mine.**
    ///
    /// Six equal rows in one list read as a list where nothing belongs together. But
    /// watchlist and downloads are not the same kind of place as Movies and Shows: those
    /// are **collections on the server**, these two are **mine** (what I saved and what I
    /// fetched to this machine). The separation was already there, just not visible.
    ///
    /// Empty while downloads and the watchlist are both off; then the section does not
    /// exist.
    static func mineGroup(downloads: Bool, watchlist: Bool = true) -> [Region] {
        (watchlist ? [.watchlist] : []) + (downloads ? [.downloads] : [])
    }

    var symbol: String {
        switch self {
        case .start:     "house"
        case .movies:     "film"
        case .seriesList:    "tv"
        case .search:     "magnifyingglass"
        case .downloads: "arrow.down.circle"
        case .watchlist: "bookmark.fill"
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .start:     "Start"
        case .movies:     "Filme"
        case .seriesList:    "Serien"
        case .search:     "Suche"
        case .downloads: "Downloads"
        case .watchlist: "Merkliste"
        }
    }
}

/// The window: sidebar on the left, content on the right.
///
/// The iPhone's bottom bar moves to the side here. Not a matter of taste: at the bottom
/// it was in thumb reach and assumed a fixed screen height. Neither applies in a
/// window.
struct MainView: View {
    let model: AppModel

    @State private var section: Region = .start
    @State private var controls: PlayControls
    @State private var navigator = Navigator()

    /// **The state of the four sections lives here, not in the views.**
    ///
    /// The root carries `.id(section)`, so it is discarded and rebuilt on a switch. If its
    /// state lived inside, it was gone too: the home page stood black for a second and the
    /// shelves showed their loading bar again although everything had long been fetched.
    @State private var home = HomeModel()
    /// Is something playing on another device? See ``TakeoverModel``.
    @State private var takeover = TakeoverModel()
    /// With more than one device, ask instead of guessing.
    @State private var selectionOpen = false
    /// The running handover: **only one counts.** If the user chooses twice before the
    /// first answer arrives, the first is cancelled; its late answer must not overwrite the
    /// newer choice.
    @State private var handoffTask: Task<Void, Never>?
    /// Watch together: one for the whole app, see ``SharedModel``.
    @State private var gemeinsam = SharedModel.shared
    @State private var movieShelf = LibraryModel(rememberName: "movies")
    @State private var seriesShelf = LibraryModel(rememberName: "tvshows")
    /// What the title menu of the two sections has selected: All, Collections or a library.
    /// Lives here for the same reason as the shelves.
    ///
    /// The other libraries are in the title menu as on iPhone, not a sidebar section.
    @State private var movieSelection: SectionSelection = .all
    @State private var seriesSelection: SectionSelection = .all

    init(model: AppModel) {
        self.model = model
        _controls = State(initialValue: PlayControls(model: model))
    }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model, section: $section,
                         continueWatching: takeover.offerings,
                         adopt: { badgePressed() },
                         toProfile: { toProfile() },
                         inAccount: navigator.inAccount(section),
                         sectionSelect: { sectionSelect($0) })
            // **The title bar safe area is ignored on the left just as on the right.** Previously
            // only the content area ignored it, so the bar sat about thirty points lower than the
            // window, taking its fill and edge with it. On top of that it reserves `signalHeight` at
            // the top again, so the offset was applied twice.
            .ignoresSafeArea(.container, edges: .vertical)

            // **The edge is a column of its own, not an overlay.**
            //
            // As an `.overlay` on the bar it hung on the bar's frame and ended where that frame
            // ended, not at the window edge. Here it is a separate full-height column that ignores
            // the safe area.
            Rectangle()
                .fill(Theme.line)
                .frame(width: 1)
                .frame(maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .vertical)
            // **The bar sits on top, visually and for clicks.**
            //
            // In an `HStack` the later child draws over the earlier, and the bar comes first. That
            // did not matter as long as the content stayed in its column. It does not: when a page
            // opens, `wurzel` gets `withGait`, i.e. **minus thirty percent of the content width**,
            // and so reached under the bar, on top of it because it is declared later. A click on
            // a sidebar row then hit whatever poster lay beneath, and clicks on "Serien" switched
            // nothing because the bar never received them.
            .zIndex(1)

            ZStack {
                Theme.reason
                content
            }
            // "Leave movie night / rejoin" after the player closes: bottom center of the content,
            // where hints usually go. Above it, what went wrong with the group.
            .overlay(alignment: .bottom) {
                VStack(spacing: 10) {
                    // In the player it shows itself.
                    if controls.wish == nil {
                        SharedError()
                        // What a tile menu failed to do.
                        TileMessageStrip()
                    }
                    if let alt = gemeinsam.lastLeave {
                        ReturnPathStrip(name: alt.name) { gemeinsam.againJoin() }
                            .transition(.opacity)
                    }
                }
                .padding(.bottom, Theme.edgeSpacing)
            }
            .animation(Theme.reveal, value: gemeinsam.lastLeave?.id)
            // **The content also stays in its column for clicks.**
            //
            // `clipped()` was used first. That clips only the **image**: the root was cut cleanly
            // at the hairline, but a click on "Filme" still reached the grid behind it. The
            // accessibility tree showed the root's chips at **x = -117**, under the bar, and a
            // click on a bar row was delivered to the scroll view.
            //
            // `clipShape` also clips the **hit area**; Apple's documentation says so explicitly,
            // `clipped()` does not. The offset itself stays, as it is the motion that creates the
            // impression of layers.
            .clipShape(Rectangle())
            // **The sidebar switch is not cross-faded.**
            //
            // `.animation(Theme.timePage, value: section)` used to be here. An animation with
            // `value:` applies to **everything** that changes in that pass, not only the root
            // swap. A sidebar switch also changes more: pages of the old section vanish, offset
            // and scrim fall to the new section's values. All of it animated, which looked like a
            // page slide with shadow edge where nothing should move.
            //
            // On the Mac a fade is out of place anyway: a sidebar switches immediately (Finder,
            // Mail, System Settings). The fade came from the iPhone version, where the switch
            // sits in the bottom bar.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // **The title bar safe area is removed here, not on each page separately.**
            //
            // Measured: the scroll view sat 32 pt low and had a 32 pt inset at the top, which was
            // the black bar. It also did not apply everywhere: the backdrop ended up at 0 or 32,
            // shifting the movie and series pages against each other by exactly that amount. An
            // inset that is half removed in several places is worse than one that is everywhere.
            //
            // Pages set their own top spacing (`contentTop`).
            .ignoresSafeArea(.container, edges: .top)
        }
        .background(Theme.reason)
        .environment(controls)
        // **The socket without which the Mac is not a session.**
        //
        // iOS and tvOS start it in their own `MainView`; the Mac's never did. Without it
        // Jellyfin reports `SupportsRemoteControl: false`, so the Mac could neither be
        // controlled remotely nor take over playback, and the buttons stayed grey in the
        // dashboard. It went unnoticed because the app itself worked fine.
        .task { await model.remoteControlStart() }
        // **What downloads do not know about the server**. A downloaded title
        // otherwise never learns that it has since been watched or no longer exists there, and
        // without that the low-space fallback stayed empty and the hint unshown although both
        // are drawn.
        //
        // One request per launch. If it fails, nothing happens: offline is the normal case for
        // downloads, and "no longer on the server" would be the wrong answer for every title.
        .task { await model.downloadsCatchUp() }
        .onDisappear { Task { await model.remoteControlEnd() } }
        // **Only while no player is running:** the bar is gone in the player, and the server
        // would get a request every ten seconds on top.
        .task(id: controls.wish == nil) {
            if controls.wish == nil { takeover.start(model) }
            else { takeover.finish() }
        }
        .onDisappear { takeover.finish() }
        // **The card grows out of the badge** (as on iPhone): instead of fading in mid-window
        // it comes from the sidebar row that was clicked and shrinks back there on close. The
        // scrim only fades.
        .overlay {
            if selectionOpen {
                TakeoverSelection.scrim { selectionOpen = false }
                    .transition(.opacity)
                TakeoverCard(sessions: takeover.offerings,
                                select: { hereContinueWatching($0) },
                                cancel: { selectionOpen = false })
                    .transition(.outPoint(BadgeOrigin.point))
            }
        }
        .animation(Theme.spring, value: selectionOpen)
        // Create, join and the selection. Above everything except the player, because any
        // page can open it.
        .overlay { SharedPanel(takeover: takeover.offerings,
                                   continueWatching: { hereContinueWatching($0) }) }
        .task { gemeinsam.start(model) }
        .onDisappear { gemeinsam.finish() }
        // **The group starts the player, not the page.** Whoever creates it, whoever joins,
        // and when someone in the group sets a new title: it always arrives as a queue from
        // the server.
        .onChange(of: gemeinsam.wish?.id) { _, new in
            guard new != nil, let wish = gemeinsam.wish else { return }
            gemeinsam.wish = nil
            controls.wish = wish
        }
        .environment(navigator)
        .environment(\.section, section)
        // **the page stack belongs to the account.** After a switch, whatever lies on it
        // belongs to the previous account: a detail page hangs on `.task(id: title.id)`, a
        // series page on the season, search on the term, and none of these ids change. The
        // user would see the other account's checkmarks and progress bars, and Play would
        // resume from its position.
        //
        // Done here and not in each page: that would be five places, and the next new page
        // would forget it.
        // **Switched off while open, the watchlist must not stay on screen** without its row
        // in the sidebar.
        .onChange(of: model.watchlistShown) { _, shown in
            if !shown, section == .watchlist { sectionSelect(.start) }
        }
        .onChange(of: model.accountSwitch) { _, _ in
            // Already cleared from the profile page, at the click (see below). Do not ask
            // `waits`: opening the profile mid-flight completes the flight, and clearing would
            // remove the page again (see ``Kontowechselflug/stackAlreadyEmpty()``).
            guard !AccountSwitchTransition.shared.stackAlreadyEmpty() else { return }
            navigator.emptyAll()
        }
        // **"Go to the home page"** (the looks from the profile or Appearance, "Show me my
        // Home" on the thank-you page): the pages above the home page close, the person
        // stays on the home page.
        .onChange(of: GiftFlow.shared.homeRequests) { _, _ in
            section = .start
            navigator.back(in: .start, until: 0)
        }
        // **On the click in the profile page** (design D, as on iPhone) the page itself slides
        // out, profile included, and the picture flies into the sidebar. See
        // ``AccountSwitchStage``.
        .onChange(of: AccountSwitchTransition.shared.back) { _, _ in navigator.clearEverything() }
        // The flying profile picture: above page and sidebar, below the player.
        .overlay { AccountSwitchImage() }
        // The player takes the whole window, sidebar included.
        .overlay {
            if let wish = controls.wish {
                PlayerScreen(model: model, wish: wish) { controls.close() }
                    // The overlay lies outside `.environment(controls)` above; without that the
                    // episode level crashed, since `EpisodesRow` reads the controller from the
                    // environment.
                    .environment(controls)
                    .environment(navigator)
                    // **Cross-fade as on iPhone and Apple TV:** the same motion on every device, the
                    // player fades in and out.
                    .transition(.opacity)
            }
        }
        // **The light strip was not paint but an inset.**
        //
        // The overlay is laid out in the safe area, i.e. below the title bar: the image started
        // there and the bar stayed visible above it. An `.ignoresSafeArea()` **inside** the
        // player did not help: the overlay itself was already inset, and a child cannot reopen
        // its parent's frame.
        //
        // There is a known regression in macOS 26 where the title bar is drawn despite
        // `titlebarAppearsTransparent`, triggered by exactly this layout (a scroll view with
        // a view next to it on the left). It is fixed since 26.1, so the cause was our own
        // layout.
        .ignoresSafeArea()
        // `Theme.einblenden` instead of a custom curve: same duration, and with reduced motion
        // the fade becomes a short switch.
        .animation(Theme.reveal, value: controls.wish?.id)
        .focusedSceneValue(\.playerOpen, controls.wish != nil)
        .focusedSceneValue(\.downloadsAn, model.downloadsAn)
        .focusedSceneValue(\.watchlistShown, model.watchlistShown)
        .onReceive(NotificationCenter.default.publisher(for: CommandPost.name)) { post in
            guard let command = CommandPost.receive(post) else { return }
            execute(command)
        }
    }

    /// How many pages are **shown**. Deliberately not the same as
    /// `navigator.seiten(section).count`: when going deeper the value lags one frame
    /// behind, and that is the trick.
    ///
    /// **Why.** With `.transition(.move)` SwiftUI inserts the new page and moves it in the
    /// same frame. The whole build of the detail page (backdrop, header, cast, similar)
    /// falls into that one frame; the frame arrives late, the motion starts with a jump, and
    /// no curve fixes that. A `UINavigationController` does it the other way: the new view
    /// goes into the container, is laid out, and **only then** the animator starts.
    ///
    /// So: insert the page offset by one full width to the right, wait one frame, then
    /// slide. Going back needs no wait, since everything is already in place.
    /// **Per section.** There used to be a single number for all four sections. Leaving a
    /// page open in "Filme" and switching to "Start" reset it from 1 to 0, and because the
    /// parent has `.animation(timePage, value: section)`, that reset ran as a motion: the
    /// root undid its `withGait` and the scrim faded out. **That was the odd fade with the
    /// dark gradient on sidebar switches.**
    ///
    /// The stack lives per section in `Navigator`; this number belongs next to it.
    @State private var shownDeep: [Region: Int] = [:]

    /// How many pages are shown in the **current** section.
    private var depth: Int { shownDeep[section] ?? 0 }

    /// What the root currently is. If it changes, the root is rebuilt.
    private var rootId: String { section.rawValue }

    private var content: some View {
        GeometryReader { space in
            let width = space.size.width
            // How far the page beneath moves along. One third, as system navigation does; it
            // gives the impression of layers rather than a rectangle sliding past.
            let withGait = -width * 0.3

            ZStack {
                // The section root always lies at the bottom.
                // **`withGait` and the scrim belong *under* the id.**
                //
                // Above it they applied to the outgoing root as well as the new one, and both read the
                // *new* section's `depth`. After leaving a page open in "Filme" and switching to
                // "Start", the old root undid its `withGait` and the scrim faded out: a motion with a
                // dark gradient that has no business there. It went unnoticed for Movies and Shows
                // because a page lay on top and hid it.
                //
                // Under the id they belong to their own root. The outgoing one keeps its state and
                // just fades out.
                root
                    // **The switch cross-fades, and only the root.**
                    //
                    // Without it the other libraries appeared abruptly while everything else fades in.
                    //
                    // **Order matters.** The animation sits directly on the root, i.e. before the offset
                    // and scrim around it. Previously the parent had `.animation(value: section)`, which
                    // applied to *everything* that changed in the same pass, including `depth`: the
                    // outgoing root undid its `withGait` and the scrim faded out. That was the odd fade with
                    // the dark gradient, and it is why the animation sits inside here.
                    .transition(.opacity)
                    .animation(Theme.reveal, value: rootId)
                    .offset(x: depth > 0 ? withGait : 0)
                    .overlay {
                        // From `reason`, not `Color.black`: pure black exists in exactly one place, behind the
                        // image in the player.
                        Theme.reason.opacity(depth > 0 ? 0.28 : 0)
                            .allowsHitTesting(false)
                    }
                    // **Whatever lies under a page takes no clicks.**
                    //
                    // This is the actual rule; the scrim above already says it: the root is covered, so it
                    // is not operable. Without this line it stayed operable, and because `withGait` pushes
                    // it thirty percent to the left, its chips and posters lay **under the sidebar**. In the
                    // running window the "Serien" filter chip sat at x = 4 and the "Filme" sidebar row at
                    // x = 12, and the click went to the chip. That is the "I click on the left and a title
                    // opens" bug, and also "the bar reacts to nothing": it never received the click.
                    //
                    // `clipped()` and `clipShape` did not help: both clip the image, and the children's hit
                    // area stays where it is.
                    .allowsHitTesting(depth == 0)
                    // **And out of the accessibility tree as well.** A covered page does not belong there;
                    // VoiceOver would walk through buttons nobody sees. Same statement as
                    // `allowsHitTesting`, for the second way in; without it the root stayed in the tree,
                    // with chips at x = 4 under the sidebar.
                    .accessibilityHidden(depth > 0)
                    .id(section)
                    // **The root explicitly lies at the bottom.** Without fixed layers the page slid in
                    // under the home page's tiles, which looked like transparency.
                    .zIndex(0)

                // **The page stack as a whole, with its own id.**
                //
                // Without it the `ForEach` sat directly in this stack. On a sidebar switch its content
                // changed from one section's pages to another's, and SwiftUI played the **slide-out
                // motion** for each vanishing page, from the right with the shadow edge on top. After
                // leaving a page open in "Filme" and going to "Start" the user saw a page slide where
                // only a cross-fade was intended.
                //
                // With `.id(section)` the stack is swapped as **one** piece. Then that piece's
                // cross-fade applies, and the motions inside it are reserved for going deeper, which
                // is what they are for.
                ZStack {
                    ForEach(Array(navigator.pages(section).enumerated()), id: \.element.id) { slot, target in
                        let uppermost = slot == depth - 1
                        let shown = slot < depth

                        ZStack {
                            Theme.reason
                            page(target)
                        }
                        // Off to the right until it is its turn; pages beneath move along a little.
                        .offset(x: shown ? (uppermost ? 0 : withGait) : width)
                        .overlay {
                            Theme.reason.opacity(shown && !uppermost ? 0.28 : 0)
                                .allowsHitTesting(false)
                        }
                        // The drop shadow on the leading edge. A narrow gradient **beside** the page, not
                        // `.shadow`: a shadow around a screen-sized view forces it into its own offscreen
                        // buffer, which the system rebuilds every frame.
                        .overlay(alignment: .leading) {
                            LinearGradient(colors: [Theme.reason.opacity(0.45), .clear],
                                           startPoint: .trailing, endPoint: .leading)
                                .frame(width: 28)
                                .offset(x: -28)
                                .allowsHitTesting(false)
                        }
                        // Same rule one level up: of the pages in the stack only the top one takes clicks.
                        // The ones below carry the same scrim as the root, and what waits off to the right
                        // is not there at all.
                        .allowsHitTesting(uppermost)
                        .accessibilityHidden(!uppermost)
                        .zIndex(Double(slot + 1))
                        // **Start sliding once the page is really in place.**
                        //
                        // This used to wait with `Task.sleep(16 ms)`. That was a race: at 120 Hz a frame is a
                        // bit over eight milliseconds, so the wakeup came either before or after the layout.
                        // If before, insert and slide fell into the same transaction and the page jumped to
                        // its place without motion. **That is the intermittent "sometimes smooth, sometimes
                        // abrupt".** It was never the curve.
                        //
                        // `DispatchQueue.main.async` from `onAppear` is guaranteed to run after the current
                        // transaction completes. No timer, no milliseconds, no race.
                        .onAppear {
                            // If the page is already in place, this is a return from a sidebar switch, and it
                            // does not slide again.
                            guard slot >= depth else { return }
                            // From now on it slides; responses wait (`InTravel`).
                            InTravel.begins()
                            // **Only this one write.** There used to be a second, unanimated one next to it
                            // (`ruht = false`). Both are state of the same view and land in one update pass, for
                            // which SwiftUI picks *one* transaction. If it picks the empty one, the offset is set
                            // without motion. It was the only place in the tree where a running motion could be
                            // broken.
                            DispatchQueue.main.async {
                                withAnimation(Theme.timePagesPush) { shownDeep[section] = slot + 1 }
                            }
                        }
                        // **Only sliding out is a transition.** Sliding in is done by the offset above so the
                        // page is fully laid out beforehand. Nothing fades here: transparent while moving
                        // looks like a bug.
                        .transition(.asymmetric(insertion: .identity,
                                                removal: .move(edge: .trailing)))
                }
                .zIndex(1)
                }
            }
            // **Otherwise the root steps over the edge.** `withGait` pushes it one third to the
            // left; without clipping that third lands over the sidebar and home page and sidebar
            // are visible on top of each other.
            .clipped()
            // **The section as a whole, with one id.**
            //
            // Root and page stack used to carry one each. Then an open page stack vanishes abruptly
            // while the root beneath still fades. A section is one piece: whatever was open in it
            // goes with it. **The open library belongs in this id.**
            //
            // `section` alone used to be here. Switching between the other libraries does not
            // change the section, so the id stayed the same, the piece was not swapped, and the
            // fade-through never ran.
            //
            // Putting it on the root itself, one level deeper, cannot work: on a switch the root
            // is discarded and rebuilt with its modifiers, so an `.animation` on it does not know
            // about its own appearance. Insert and remove animations belong on what stays, which
            // is this piece.
            .id(rootId)
            // First the old goes, then the new comes, one after the other, opacity only. The
            // numbers and the reasoning are at `Theme.timeSectionToOut`.
            .transition(.sectionSwitch)
            // **Only here, not on the parent.** That is exactly why the first attempt failed: an
            // animation with `value:` applies to everything that changes below it, and then also
            // moved page offset and scrim, visible as a page slide with shadow edge where nothing
            // should move. Here it sits on the piece being swapped; there is nothing inside to
            // move, since the old one keeps its state and the new one is drawn fresh.
            .animation(.default, value: rootId)
        }
        .onChange(of: navigator.pages(section).count, initial: true) { alt, new in
            guard new != depth else { return }
            if new > alt {
                // Going deeper is done by the page itself, see `onAppear` above.
            } else {
                // Going back: `Navigator.back` already animates the removal; `withGait` has to go
                // back in the same step.
                withAnimation(Theme.timePagesPush) { shownDeep[section] = new }
            }
        }
        // **Switching section does not leave the profile in the old one.** Otherwise it was on
        // top again on return. No motion, since the old section is already gone; the shown
        // depth goes along in the same step, or the root would undo its `withGait` on the next
        // visit (see `shownDeep`).
        //
        // Done here and not in the sidebar: Command-1 to -4 and the collections also switch
        // section.
        .onChange(of: section) { alt, _ in
            guard navigator.inAccount(alt) else { return }
            navigator.closeAccountBranch(in: alt, animated: false)
            shownDeep[alt] = navigator.pages(alt).count
        }
    }

    private var root: some View { sectionRoot }

    @ViewBuilder
    private var sectionRoot: some View {
        switch section {
        case .start:  HomeView(model: model, state: home)
        case .movies:  LibraryView(model: model, art: "movies", title: "Filme",
                                     shelf: movieShelf, choice: $movieSelection)
        case .seriesList: LibraryView(model: model, art: "tvshows", title: "Serien",
                                     shelf: seriesShelf, choice: $seriesSelection)
        case .search:  SearchView(model: model)
        case .downloads: DownloadsView(model: model)
        case .watchlist: WatchlistView(model: model)
        }
    }

    @ViewBuilder
    private func page(_ target: PagesTarget) -> some View {
        switch target {
        // A collection from search or watchlist: no section, so everything in it, as on
        // iPhone.
        case let .title(item) where item.type == "BoxSet":
            CollectionDetailPage(model: model, collection: item, art: nil) { close(target) }
        case let .title(item) where item.type == "Playlist":
            PlaylistPage(model: model, playlist: item, art: nil) { close(target) }
        case let .title(item):  DetailView(model: model, item: item) { close(target) }
        case let .playlist(item, art):
            PlaylistPage(model: model, playlist: item, art: art) { close(target) }
        case let .collection(item, art):
            CollectionDetailPage(model: model, collection: item, art: art) { close(target) }
        case let .downloadSeries(id, title):
            DownloadSeriesOverviewPage(model: model, seriesIdentifier: id, title: title) { close(target) }
        case .seerr:            SeerrSettingsView(model: model, seerr: model.seerr) { close(target) }
        case .trakt:            TraktSettingsView(trakt: model.trakt) { close(target) }
        case let .seerrTitle(t): SeerrDetailView(model: model, hit: t) { close(target) }
        // No longer reachable: a library is a root. The case stays so a restored old stack
        // does not break.
        case .library: Color.clear.onAppear { close(target) }
        case .profile:           ProfileView(model: model) { close(target) }
        // No longer reachable: the watchlist is a section. The case stays so a restored old
        // stack does not break; it simply closes.
        case .watchlist:        Color.clear.onAppear { close(target) }
        case .settings:    SettingsView(model: model) { close(target) }
        case .playback:       PlaybackSettingsView(model: model) { close(target) }
        case .presentation:      PresentationView(model: model) { close(target) }
        case .licenses:         LicensesView { close(target) }
        case let .license(id):
            if let component = LicenseState.shared?.component(id: id) {
                LicenseView(component: component) { close(target) }
            } else {
                Color.clear.onAppear { close(target) }
            }
        case .licenseOffering:    LicenseOfferingView { close(target) }
        case .genreSelection:        GenreSelectionView(model: model) { close(target) }
        case .librarySelection:  LibrarySelectionView(model: model) { close(target) }
        case .quickConnect:     QuickConnectView(model: model) { close(target) }
        case .accountAdd: AccountAddView(model: model) { close(target) }
        case let .serverAdd(url):
            ServerOnboardingView(model: model, preset: url) { close(target) }
        case let .person(person, origin):
            PersonView(model: model, person: person, origin: origin) { close(target) }
        case let .genre(name):
            GenreView(model: model, name: name) { close(target) }
        }
    }

    private func back() { navigator.back(in: section) }

    /// **Each subpage closes itself, not "the top one".** See
    /// `Navigator.close(_:in:)`; the difference caused the crash when adding a second
    /// server.
    private func close(_ target: PagesTarget) { navigator.close(target, in: section) }

    // MARK: Account branch

    /// A section from the sidebar or keyboard.
    ///
    /// **Clicking the open section closes the profile.** The profile page lies on the stack
    /// of the section it was opened from, usually "Start". Clicking "Start" then set the
    /// value it already had and nothing happened. The only way out was another section, and
    /// coming back to "Start" the profile was on top again. The second part is handled by
    /// `.onChange(of: section)`.
    private func sectionSelect(_ new: Region) {
        if new == section {
            // On the Mac, clicking the active row goes to the root (as in Finder); if the account
            // branch lies on it, that closes first.
            if navigator.inAccount(section) {
                toAccountBranch(animated: true)
            } else {
                navigator.back(in: section, until: 0)
            }
        }
        section = new
    }

    /// Closes the account branch in the visible section.
    ///
    /// With motion when the section stays, so it is a back and looks like one. Without when
    /// the root is swapped anyway; then the shown depth goes along in the same step.
    private func toAccountBranch(animated: Bool) {
        guard navigator.inAccount(section) else { return }
        navigator.closeAccountBranch(in: section, animated: animated)
        if !animated { shownDeep[section] = navigator.pages(section).count }
    }

    /// The account at the bottom of the sidebar.
    ///
    /// **If the profile is already open, this goes back to it** instead of pushing a second
    /// one: two identical pages in a stack are an error here, not a cosmetic problem (see
    /// Command-comma in `ausfuehren`). If only Settings lies on top (via Command-comma,
    /// without a profile below), they leave without motion and the profile slides in.
    private func toProfile() {
        if let i = navigator.pages(section).firstIndex(of: .profile) {
            navigator.back(in: section, until: i + 1)
            return
        }
        toAccountBranch(animated: false)
        navigator.openIt(.profile, in: section)
    }

    private func execute(_ command: AppCommand) {
        // Behind a running player no menu command applies.
        guard controls.wish == nil else { return }
        switch command {
        case .start:  sectionSelect(.start)
        case .movies:  sectionSelect(.movies)
        case .seriesList: sectionSelect(.seriesList)
        case .watchlist: if model.watchlistShown { sectionSelect(.watchlist) }
        // **Only if it exists.** Without downloads switched on, the section is not in the
        // sidebar; then a shortcut must not open it either.
        case .downloads: if model.downloadsAn { sectionSelect(.downloads) }
        case .search:  sectionSelect(.search)
        case .back:
            back()
        case .settings:
            // **Never twice on the stack.** Pages are distinguished by their id, and two equal
            // ones in a `ForEach` are an error, not a cosmetic problem. If the page lies somewhere
            // already, it stays as it is, since it is open.
            navigator.openIt(.settings, in: section)
        // These belong to the player; here, behind no movie, they do nothing.
        case .playToggle, .playBack, .playForward, .playFullscreen,
             .playPause, .louder, .quieter, .muted:
            break
        }
    }
}

// MARK: - Sidebar

extension MainView {

    /// With one entry, immediately; with several, ask first (design A): devices only, the
    /// device picker; a group alone, straight to "Beitreten"; otherwise the picker with
    /// both.
    fileprivate func badgePressed() {
        let groups = gemeinsam.group == nil && gemeinsam.mayJoin ? gemeinsam.offerings : []
        if groups.isEmpty {
            if takeover.multiplePresent { selectionOpen = true }
            else if let a = takeover.offering { hereContinueWatching(a) }
        } else if takeover.offerings.isEmpty, groups.count == 1, let g = groups.first {
            gemeinsam.sheet = .join(g)
        } else {
            gemeinsam.sheet = .pick
        }
    }

    /// End it over there, continue here at the same position.
    ///
    /// Command first, then start: if ending fails, nothing happens here. Otherwise two
    /// audio tracks would play in the room.
    ///
    /// **The card grows from the row immediately** (design B, as on iPhone); the player
    /// opens under it without a fade (``HandoffStage``).
    fileprivate func hereContinueWatching(_ session: RemoteSession) {
        selectionOpen = false
        let stage = HandoffStage.shared
        handoffTask?.cancel()
        stage.start(title: session.running, model: model)
        handoffTask = Task {
            let wish = await takeover.wish(for: session, model: model)
            // Superseded: the newer choice belongs to the stage, not this response.
            guard !Task.isCancelled else { return }
            guard let wish else {
                stage.cancel("kein Plan oder Stopp abgelehnt")
                return
            }
            stage.playerComes(wish.item.id)
            var without = Transaction()
            without.disablesAnimations = true
            withTransaction(without) { controls.wish = wish }
        }
    }
}

struct Sidebar: View {
    let model: AppModel
    @Binding var section: Region
    /// What is playing on other devices; empty if nothing.
    var continueWatching: [RemoteSession] = []
    var adopt: () -> Void
    let toProfile: () -> Void
    /// The profile or something from it is open. Then no row at the top carries the
    /// selection, but the account at the bottom, the same rule as on iPad. Previously
    /// "Start" stayed highlighted while the profile was visible.
    var inAccount = false
    /// Not the binding itself: a click on the already open section must close the account
    /// branch, and the binding's value does not change in that case.
    let sectionSelect: (Region) -> Void

    @State private var gemeinsam = SharedModel.shared
    /// Where the offer row sits, globally; the picker grows from there.
    @State private var offeringFrame: CGRect = .zero

    /// Groups that can be joined; not if already in one.
    private var groups: [SyncPlayGroup] {
        gemeinsam.group == nil && gemeinsam.mayJoin ? gemeinsam.offerings : []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Space for the window controls, which sit above the sidebar.
            Color.clear.frame(height: Theme.signalHeight)

            Wordmark(height: 28)
                .padding(.horizontal, 20)
                .padding(.bottom, 18)

            VStack(spacing: 2) {
                ForEach(Region.topGroup, id: \.self) { fall in
                    SidebarRow(symbol: fall.symbol,
                                       label: fall.label,
                                       active: section == fall && !inAccount) {
                        sectionSelect(fall)
                    }
                }
            }
            .padding(.horizontal, 12)

            let mine = Region.mineGroup(downloads: model.downloadsAn, watchlist: model.watchlistShown)
            if !mine.isEmpty {
                SidebarCategory(text: "Meins")
                    .padding(.horizontal, 12)
                    .padding(.top, 26)
                    .padding(.bottom, 8)

                VStack(spacing: 2) {
                    ForEach(mine, id: \.self) { fall in
                        SidebarRow(symbol: fall.symbol,
                                           label: fall.label,
                                           active: section == fall && !inAccount) {
                            sectionSelect(fall)
                        }
                    }
                }
                .padding(.horizontal, 12)
            }

            // **No "Bibliotheken" section anymore.** The other libraries were here and opened as
            // their own root. They are now in the title menu of Movies and Shows as on
            // iPhone, together with "Alle" and "Sammlungen".

            Spacer(minLength: 0)

            // **Above the divider, not below.** The Mac has no profile picture at the top right;
            // the sidebar ends with the account. The offer belongs next to it, where the eye goes
            // anyway: the same place as the badge on iPhone and TV, in the shape of this bar.
            //
            // **Open groups count too** (design A): one row, one counter, not a second row that
            // pushes the account down.
            if !continueWatching.isEmpty || !groups.isEmpty {
                Button {
                    // The picker grows from this row (``Abzeichenursprung``).
                    BadgeOrigin.point = CGPoint(x: offeringFrame.midX, y: offeringFrame.midY)
                    adopt()
                } label: {
                    OfferingRow(continueWatching: continueWatching, groups: groups)
                }
                // Press feedback like any button; `PressRow` would put a rectangle under the
                // capsule.
                .buttonStyle(Theme.PressButton())
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    offeringFrame = $0
                }
                // **One inset on all sides it touches:** left, right and bottom use the same value.
                // Bottom used to be 4 against 12 at the sides, so the badge sat lower than it was
                // inset. The card grows from its center (`offeringFrame`), so it follows along.
                .padding([.horizontal, .bottom], Theme.badgeEdge)
                .transition(.opacity)
                // `Angebotszeile` provides the spoken label itself (title and what is playing).
            }

            // `Divider` brings Apple's own color and weight; the overlay only painted over it.
            // `SheetLine` is the app's one hairline and runs edge to edge.
            SheetLine()

            // Not a `NavigationLink`: the sidebar lies **beside** the stack, not inside it, so it
            // pushes the destination onto the visible section's stack itself.
            Button { toProfile() } label: { ProfileRow(model: model, active: inAccount) }
                .buttonStyle(Theme.PressRow())
                .padding(12)
        }
        .frame(width: Theme.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.area)
        .animation(Theme.leap, value: continueWatching.map(\.id))
        .animation(Theme.leap, value: groups.map(\.id))
        .task { if model.views.isEmpty { await model.loadViews() } }
    }
}

/// Who is signed in, and where. At the bottom of the sidebar; on iPhone the same sits
/// at the top right as the profile icon.
struct ProfileRow: View {
    let model: AppModel
    /// The profile or something from it is open: this row then carries the selection, in
    /// the same form as a section row.
    var active = false
    @State private var hovers = false

    var body: some View {
        HStack(spacing: 10) {
            symbolText
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: model.session?.userName ?? "—")
                    .font(Theme.tileTitleText)
                    .foregroundStyle(active ? Theme.accent : Theme.font)
                    .lineLimit(1)
                Text(verbatim: model.serverName ?? "")
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        // `accentQuiet` is exactly this tone, precomputed.
        .background(active ? Theme.accentQuiet
                          : hovers ? Theme.hoverArea : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .accessibilityAddTraits(active ? .isSelected : [])
        .onHover { hovers = $0 }
        .animation(Theme.timeFloat, value: hovers)
    }

    /// **With several accounts, two circles overlap.** The active one in front with an
    /// accent ring, the next one partly hidden behind it; a border in the sidebar color cuts
    /// it free, like a group of participant avatars.
    ///
    /// There is always just **one** second circle, even with more accounts. The message
    /// down here is "there is another one"; which and how many is on the profile page, one
    /// click away.
    @ViewBuilder
    private var symbolText: some View {
        let more = model.accounts.first { $0.userID != model.session?.userID }
        HStack(spacing: -9) {
            let image = model.userImageURL()
            ProfileCharacter(name: model.session?.userName ?? "?",
                          image: image, size: 26,
                          highlighted: more != nil,
                          withoutImage: image.map { AccountSwitchTransition.shared.withoutImage.contains($0) } ?? false)
                // **The account switch lands here** (design D): a separate view per image URL, or the
                // old picture would show briefly on landing; and while the new one flies here, there is
                // none yet.
                .id(image)
                .opacity(AccountSwitchTransition.shared.transition.map { $0.replaced } ?? true ? 1 : 0)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frameRect in
                    AccountSwitchTransition.shared.targetInBarReport(frameRect, size: 26, contentOff: 0)
                }
                // **The connected account lies on top.** An `HStack` with negative spacing draws in
                // layout order, so the second would otherwise lie on top, showing the picture of an
                // account nobody is signed into.
                .zIndex(1)
                // The upper circle is cut free, not the lower: a two-point seam in the sidebar color so
                // the circles do not touch. It lies behind the picture, otherwise it would cover the
                // accent ring.
                .background { Circle().fill(Theme.area).padding(-2) }
            if let more {
                ProfileCharacter(name: more.userName,
                              image: model.userImageURL(for: more),
                              size: 26)
                    .opacity(0.55)
            }
        }
    }

}

