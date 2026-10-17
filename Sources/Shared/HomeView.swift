import JellyfinKit
import SwiftUI

/// The home page. Rows of portrait posters, with whatever is in progress first.
struct HomeView: View {
    let model: AppModel

    @Environment(\.wide) private var wide
    @Environment(\.windowButtons) private var windowButtons
    @Environment(\.scenePhase) private var lifeStatus

    /// Loading and ordering live in `HomeModel`, shared with the tvOS
    /// version.
    @State private var state = HomeModel()
    @State private var play: PlayRequest?
    @State private var prepares = false
    @State private var message: String?
    /// Switching server signs out: ask for confirmation first.
    @State private var signOutSheet = false
    /// None of the requests succeeded.
    @State private var loadsNew = false
    /// How far the page has scrolled, **only for the header gradient.**
    @State private var distance = ScrollDistance()
    /// **An account switch is running** (experiment `experiment-glas`): the rows are
    /// off and only return once there is content and the profile page is closed,
    /// then staggered (``Reihenauftritt``).
    @State private var change = false

    /// The rows are showing; no switch in progress. On a tap in the profile picker
    /// they go off immediately, before the account changes.
    private var showItem: Bool { !change && !AccountSwitchTransition.shared.waits }
    /// The rows are in the tree, except between the tap and the release.
    private var built: Bool { showItem || structure }
    @State private var structure = false

    /// There is something to show and nothing in front of it anymore.
    private var released: Bool {
        (!state.allEmpty || state.loaded) && !AccountSwitchTransition.shared.waits
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.reason.ignoresSafeArea()

            content
                // The switch pulls in the scroll area; the header above stays fixed, see
                // `areaContent()`.
                // The backdrop is empty: a colored glow used to sit behind the content here. It
                // is gone; the home page carries the same dark header gradient as every other
                // page.
                .areaContent {
                    EmptyView()
                }
                // Below the header and the takeover selection, above the content; see
                // `sectionBar()`.
                .sectionBar()

            header

            if let message {
                HintStrip(text: message) { self.message = nil }
                    .padding(.bottom, wide ? 0 : Theme.stripHeight)
            }

            // **`allEmpty`, not three separate checks.** This used to check Continue
            // Watching, Next Episode and the combined new-additions row, but not the
            // separate "New Movies" and "New Series" rows. With "split new additions" on and
            // nothing in progress, "Nothing here yet" was laid **over** a full home page:
            // `recent` is always empty then, because the titles are in the separate rows.
            // Mac and TV have always asked `allEmpty`; only this older copy remained here.
            if state.loaded, state.allEmpty {
                // The "when" for the "how" from `Leerzustand`: without an animated insertion,
                // the `.transition` there has no effect.
                notPresent
                    .padding(.bottom, wide ? 0 : Theme.stripHeight)
                    .animation(Theme.reveal, value: state.loaded)
        // The "when" for the "how" above: the genre rows cross-fade when they arrive.
        .animation(Theme.reveal, value: state.genreRails.map(\.name))
        .animation(Theme.reveal, value: libraries.map(\.id))
            }
        }
        // **Refetch after watching, with no grace period.**
        //
        // When someone returns from the player they have just moved the position, so
        // "Continue Watching" is certainly stale, and the episode may be finished and no
        // longer belong in the row.
        // **The setting takes effect immediately, not on the next pull.**
        //
        // Toggling changes which rows exist at all, and those are only known after a new
        // fetch. Without this, the setting only showed after a manual reload and looked
        // like it did nothing.
        //
        // **One `task`, not two**, as on tvOS. There was an additional plain
        // `.task { if !state.loaded … }`; both ran on appearing, the second still saw
        // `loaded` as false and fetched all rows a second time (two runs in the same
        // millisecond).
        .task(id: "\(model.newAccessDisconnected)|\(model.genreChips)|\(model.startGenres.joined(separator: "|"))|\(model.startLibraries.map(\.id).joined(separator: "|"))") {
            // If an account switch is running, it does the loading, not the return to the
            // page that coincides with it (otherwise it would fetch the old account again).
            if AccountSwitchTransition.shared.waits { return }
            await load()
        }
        // **Do not hang it on `phase`.** During an account switch it is already
        // `.ready` and does not change, so the home page never reloaded and showed the
        // previous account's titles. On tvOS this is exactly what `accountSwitch` is for:
        // the counter exists for this.
        .onChange(of: model.accountSwitch) { _, _ in
            // First off, then load, then staggered in (experiment `experiment-glas`).
            AccountSwitchTransition.note("wechsel: startseite blendet aus")
            change = true
            Task {
                await load()
                if change, released { reveal() }
            }
        }
        .onChange(of: released) { _, now in
            if now, change { reveal() }
        }
        // Refetch happens after the end report, not on closing: when closing, it is
        // still in flight (`AppModel.playbackEnded`).
        .catchUp(at: model.pagesRefresh) { Task { await load() } }
        // Return to the foreground (30 s grace): someone who kept
        // watching on another device does not see yesterday's state.
        .onChange(of: lifeStatus) { _, new in
            guard new == .active, state.needsRefresh,
                  !AccountSwitchTransition.shared.waits else { return }
            Task { await load() }
        }
        .overlay(alignment: .topTrailing) {
            ActionSheet(opened: $signOutSheet,
                           title: String(localized: "Abmelden von \(model.session?.userName ?? "")"),
                           actions: [
                TitleAction(symbol: "rectangle.portrait.and.arrow.right",
                              text: "Abmelden", cautionary: true) { model.signOut() },
            ])
        }
        .playerCover(item: $play) { wish in
            PlayerScreen(model: model, item: wish.item,
                         plan: wish.plan, startAt: wish.startAt)
        }
    }

    /// Wordmark on the left, profile picture on the right.
    ///
    /// Content visibly scrolls underneath instead of being cut off at a hard black
    /// edge. The magnifier is gone; Search is now its own section in the bar below.
    @ViewBuilder private var header: some View {
        if wide {
            // **No gradient.** On iPhone it carries the top header bar; here the bar is on
            // the left, and above the content there is nothing for it to run under. A
            // gradient without a header bar is decoration, which this design does not have.
            EmptyView()
        } else {
            headerLine
        }
    }

    private var headerLine: some View {
        // **The gradient only pulls in when scrolling.** At rest there is no content
        // under the header yet, so it covers nothing. `headerLine` only exists in narrow
        // layout anyway.
        HeaderReader(distance: distance) {
            HStack(alignment: .center, spacing: 0) {
                Wordmark(height: 30)
                Spacer(minLength: 0)

                // **Three symbols, one language.**
                //
                // The offer was a circle with fill and border. That was right as long as it
                // stood alone next to the profile picture: it is an offer, not a permanent
                // button, and should stand out. Once Watchlist was added, the same circle next
                // to a bare symbol read as two different kinds of button.
                //
                // What sets it apart is now not the **shape** but the **color**, which is our
                // rule anyway: the accent carries state, not surfaces.
                //
                // **The offer is no longer here** but in `HeaderTargets` itself: it belongs with
                // Watchlist and Profile and so on every root page, not just this one.
                HeaderTargets(name: model.session?.userName ?? "?",
                          image: model.userImageURL())
            }
            .foregroundStyle(Theme.font)
        }
    }

    /// Instead of an empty black screen: say what is going on and offer a way back.
    ///
    /// The text names the server address. That is the real gain: it shows at a
    /// glance whether the server is down or you are on the wrong network. Before, it
    /// only said something had failed.
    @ViewBuilder private var notPresent: some View {
        if state.disrupted {
            EmptyState.serverDived(model, loads: loadsNew,
                                         retry: { newTry() },
                                         switchTo: { signOutSheet = true })
        } else {
            EmptyState(
                symbol: "tray",
                headerLine: "Hier ist noch nichts",
                text: "Sobald in Jellyfin etwas liegt, taucht es hier auf.",
                quietButton: ("Aktualisieren", { newTry() }))
        }
    }

    /// **The empty state accounts for the nav bar.**
    ///
    /// It is centered in the whole window, and when narrow the bottom 54 pt of that
    /// lie under the bar: the block sat visibly too low, while it was centered on the
    /// library page. The same number the scroll areas keep free as `contentMargins`.

    private func newTry() {
        loadsNew = true
        Task {
            await load()
            loadsNew = false
        }
    }

    private var content: some View {
        ScrollView {
            // **Full stack.** It fixed the reported bug: the lazy one estimates the height
            // of unloaded rows, and since rows are not equally tall, the last one appeared
            // too late and vanished again when scrolling up.
            //
            // It was suspected of crashing the app for one build. It was not: the crashes
            // came from the library, not from here. What remains of the suspicion is correct
            // and stays: the row uses a `LazyHStack`, and every image is decoded only as
            // large as it is shown.
            VStack(alignment: .leading, spacing: Theme.railsSpacing) {
                // **The rows stand before they have content.** Instead of a spinner in the
                // middle of the page: two rows in their shape that cross-fade once the titles
                // are there. You see at once what kind of page it will be.
                // Not during an account switch: the page stays empty until the rows come in
                // staggered.
                if !state.loaded, showItem {
                    RailsPlaceholder(landscape: true)
                    RailsPlaceholder()
                }
                // **Genres as chips, at the very top**, when enabled. An entry point, not
                // content: a tap opens the genre.
                // **Not built at all during the switch** (experiment `experiment-glas`): on tap
                // the old account's rows are gone immediately, so nothing flashes behind the
                // page going back, and whatever arrives mid-flight is neither set nor decoded.
                // Only after landing.
                if built {
                if model.genreChips, !model.startGenres.isEmpty {
                    genreChips.railEntrance(0, present: showItem)
                }
                // **The fixed rows in the configured order**, without the hidden ones;
                // Settings → Appearance → Home.
                ForEach(Array(fixedRails.enumerated()), id: \.element.id) { i, rail in
                    pinned(rail).railEntrance(i + 1, present: showItem)
                }
                // The chosen genres as their own rows, after the fixed ones.
                //
                // **They fade in instead of appearing.** They arrive one network round trip
                // after the fixed rows; without a transition there was first nothing and then
                // everything at once.
                // **Before them, the chosen libraries and collections** (Appearance → Home →
                // "+"): the title is their name, the header opens them. With no selection the
                // list is empty and this line costs nothing.
                ForEach(Array(libraries.enumerated()), id: \.element.id) { j, r in
                    Rail(model: model, title: "", name: r.name, items: r.items,
                          target: CollectionRoute(collection: model.startLibraries.first { $0.id == r.id }?.item
                                                ?? Item(id: r.id, name: r.name), art: nil))
                        .transition(.opacity)
                        .railEntrance(fixedRails.count + 1 + j, present: showItem)
                }
                ForEach(Array(state.genreRails.enumerated()), id: \.element.id) { j, r in
                    Rail(model: model, title: "", name: r.name, items: r.items)
                        .transition(.opacity)
                        .railEntrance(fixedRails.count + libraries.count + 1 + j, present: showItem)
                }
                }
                // The "Libraries" row is gone; Movies and Series are now in the bar below.
            }
            .padding(.top, 8)
            // **As wide as the page, even without content.** The scroll area takes its
            // width from its content; measured in the simulator: with an empty home page it
            // shrank to zero, and the bar below, which sits on it as an overlay, with it.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(Theme.reveal, value: state.loaded)
        // The "when" for the "how" above: the genre rows cross-fade when they arrive.
        .animation(Theme.reveal, value: state.genreRails.map(\.name))
        .scrollIndicators(.hidden)
        // Run under the blurred header at the top, end above the bar at the bottom.
        //
        // When wide there is no bar at the bottom; it is on the left. The space
        // `stripHeight` keeps free would be an empty strip there.
        .contentMargins(.top, (wide ? Theme.headerTop + 20 : 58)
                        + (windowButtons ? WindowButtons.height : 0),
                        for: .scrollContent)
        .contentMargins(.bottom, wide ? 24 : Theme.stripHeight + 12,
                        for: .scrollContent)
        // Zero at rest: `contentOffset` starts at minus the top inset, and what is
        // needed here is the distance traveled.
        .onScrollGeometryChange(for: CGFloat.self) {
            $0.contentOffset.y + $0.contentInsets.top
        } action: { _, new in
            // **Not every frame, and not beyond 240.** The offset used to be `@State` in
            // this view; every scroll step rebuilt the whole scroll area including
            // `refreshable` and `contentMargins`, and on iOS 18 the page bounced up and down.
            // Now only the header reads it, and above 240 nothing visibly changes anymore.
            let value = min(max(new, 0), 240)
            if abs(value - distance.value) >= 0.5 { distance.value = value }
        }
        .refreshable { await load() }
    }

    /// From the continue rows straight into the episode, without an intermediate
    /// page.
    private func launch(_ item: Item) {
        guard !prepares else { return }
        prepares = true
        // On press, not after the answer (see `Theme.jerk`).
        Theme.jerk(.medium)
        // **No spinner on the tile.** Dimmed with a spinner the start looked jerky; the
        // player should simply open.
        Task {
            defer { prepares = false }
            // Fetch fresh: the position in the list entry is often stale.
            // The plan does not depend on the fresh entry: fetch both side by side, not one
            // after the other.
            async let freshValue = model.item(id: item.id)
            async let planFetch = model.plan(for: item.id)
            let current = await freshValue ?? item
            guard let plan = await planFetch else {
                // Instead of silence: say that it failed.
                message = String(localized: "Der Server hat keine Datei zu diesem Titel.")
                return
            }
            play = PlayRequest(item: current, plan: plan,
                                      startAt: current.resumeFrom ?? 0)
        }
    }

    /// One fixed row: the same layout as before, but fetchable individually so the
    /// order from Settings applies.
    @ViewBuilder
    private func pinned(_ rail: StartRail) -> some View {
        switch rail {
        case .continueWatching:
            if !state.continueWatching.isEmpty {
                Rail(model: model, title: "Weiterschauen",
                      items: state.continueWatching, landscape: true, remainingTime: true, direct: launch)
            }
        case .nextEpisode:
            if !state.nextEpisode.isEmpty {
                // Without 'direkt': an episode not yet started should be looked at first, not
                // started immediately. Only 'Weiterschauen' jumps straight into playback.
                Rail(model: model, title: "Nächste Folge", items: state.nextEpisode)
            }
        // Here the tap leads to the page: what you have not started you want to look at
        // first.
        case .newMovies:
            if !state.newMovies.isEmpty {
                Rail(model: model, title: "Zuletzt hinzugefügte Filme",
                      items: state.newMovies, newAccess: true)
            }
        case .newSeries:
            if !state.newSeries.isEmpty {
                Rail(model: model, title: "Zuletzt hinzugefügte Serien",
                      items: state.newSeries, newAccess: true)
            }
        case .newArrivals:
            if !state.recent.isEmpty {
                Rail(model: model, title: "Zuletzt hinzugefügt",
                      items: state.recent, newAccess: true)
            }
        }
    }

    /// Your genres as chips, the same ones that would otherwise be rows.
    /// Corner like a button, not round: round is what an image is.
    private var genreChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.startGenres, id: \.self) { name in
                    NavigationLink(value: GenreRoute(name: name)) {
                        // From the server, so not translated.
                        Text(verbatim: name)
                            // `tile` is 13 medium; the number stood here.
                            .font(Theme.tile)
                            .foregroundStyle(Theme.font)
                            .padding(.horizontal, 14)
                            // `minHeight`: a fixed height would clip the genre name once the system font
                            // grows.
                            .frame(minHeight: 34)
                            .background(Theme.area, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                    }
                    .buttonStyle(Theme.PressButton())
                }
            }
            .padding(.horizontal, Theme.margin(wide: wide))
        }
    }

    private func load() async {
        AccountSwitchTransition.note("startseite: laden (konto \(model.accountSwitch))")
        let interval = AccountSwitchTransition.symbolText.beginInterval("startseiteLaden")
        let a = CACurrentMediaTime()
        await state.load(model)
        AccountSwitchTransition.symbolText.endInterval("startseiteLaden", interval)
        AccountSwitchTransition.note("startseite: geladen nach \(Int((CACurrentMediaTime() - a) * 1000)) ms")
    }

    private var libraries: [Home.LibraryRail] {
        state.libraryRails(for: model.startLibraries)
    }

    private var fixedRails: [StartRail] {
        model.startRails.filter {
            !model.startOut.contains($0) && $0.fits(disconnected: model.newAccessDisconnected)
        }
    }

    /// Build first (invisible), show in the next pass; otherwise newly inserted rows
    /// would stand at their destination immediately, without the stagger.
    private func reveal() {
        // Release and end of loading can both lead here.
        guard !structure else { return }
        AccountSwitchTransition.note("wechsel 6: reihen werden gebaut")
        structure = true
        Task { @MainActor in
            // One frame of air so the rows stand invisible once.
            try? await Task.sleep(for: .milliseconds(20))
            AccountSwitchTransition.note("wechsel 7: reihen kommen gestaffelt")
            change = false
            structure = false
        }
    }
}

/// A horizontally scrolling row.
private struct Rail: View {
    @Environment(\.wide) private var wide
    let model: AppModel
    let title: LocalizedStringKey
    /// Instead of `title`, when the heading comes from the server; a genre is not
    /// translated.
    var name: String? = nil
    let items: [Item]
    /// Set means: the heading leads to the page behind it.
    var target: CollectionRoute? = nil
    /// Landscape tiles instead of portrait, only for "Continue Watching".
    var landscape = false
    /// Shows *what* was newly added instead of the episode number.
    var newAccess = false
    /// Shows below the tile how long it still runs, for "Continue Watching".
    var remainingTime = false
    /// Set means: tapping starts immediately instead of leading to the page.
    var direct: ((Item) -> Void)? = nil
    /// The tile that is starting: dimmed, with a spinner.
    var loads: String? = nil
    // After "watched/unwatched" the home page refreshes itself: it listens to
    // `pagesRefresh` (`nachholen` above). A separate call here loaded it a
    // second time.

    /// **The height is fixed, not measured.**
    ///
    /// Title line (20 pt, about 24 line height) · 12 spacing · image height · 7
    /// spacing · text block (13 and 12 pt with 1 between, about 32). None of the
    /// values grow with the system font; the tile stays fixed.
    ///
    /// It is set here so `LazyVStack` does not have to estimate. Its estimate was the
    /// reason the last row appeared too late and vanished again when scrolling up.
    private var railsHeightValue: CGFloat {
        let image = landscape ? Theme.railsLandscapeHeight(wide: wide)
                        : Theme.railsHeight(wide: wide)
        return 24 + 12 + image + 7 + 32
    }

    var body: some View {
        // 12, not 11: the same role (section label above a row) used 12 on the detail
        // page and 11 here, both next to the grid scale.
        VStack(alignment: .leading, spacing: 12) {
            // **The same margin as the tiles below.** Since extraction the component sets
            // none of its own; tvOS has no `edgeSpacing`. It must read `rand(wide:)` here,
            // or the heading is narrower than its row on iPad.
            // **One component, not a copy of it.** The server case used to be its own
            // `Text` chain with tracking −0.3, while `RailTitle` uses −0.24. Same level,
            // two values, and the component has been able to handle `name` itself since its
            // extraction.
            Group {
                if let target {
                    NavigationLink(value: target) { RailTitle(text: title, name: name) }
                        .buttonStyle(Theme.PressButton())
                } else {
                    RailTitle(text: title, name: name)
                }
            }
            .padding(.horizontal, Theme.margin(wide: wide))

            ScrollView(.horizontal, showsIndicators: false) {
                // Align top: without it the stack centers, and a tile with only one text line
                // (a movie without an episode code) sits lower than the series beside it.
                // **`LazyHStack`, not `HStack`.** A row can hold twenty posters, three are
                // visible. Creating them all cost over sixty images in one second in the log,
                // each between 650 KB and 1.7 MB.
                LazyHStack(alignment: .top, spacing: Theme.tileSpacing) {
                    ForEach(items) { item in
                        if let direct {
                            Button { direct(item) } label: {
                                Tile(model: model, item: item, landscape: landscape, newAccess: newAccess, remainingTime: remainingTime)
                                    .opacity(loads == item.id ? 0.5 : 1)
                                    .overlay {
                                        if loads == item.id {
                                            ProgressView().tint(Theme.font)
                                        }
                                    }
                            }
                            .buttonStyle(Theme.PressButton())
                            // The series is still reachable, just no longer on the playback path: "Go to
                            // overview" is in the tile menu, along with everything every tile can do.
                            .tileMenu(item, model: model, continueWatching: true, landscape: landscape)
                        } else {
                            NavigationLink(value: item) {
                                Tile(model: model, item: item, landscape: landscape, newAccess: newAccess, remainingTime: remainingTime)
                            }
                            .buttonStyle(Theme.PressButton())
                            .tileMenu(item, model: model, landscape: landscape)
                        }
                    }
                }
                .padding(.horizontal, Theme.margin(wide: wide))
            }
            .scrollIndicators(.hidden)
        }
        // So `LazyVStack` does not have to estimate; the reasoning is at `railsHeightValue`.
        // Aligned top so a tile without a subtitle does not hang in the middle.
        .frame(height: railsHeightValue, alignment: .top)
    }
}

private struct Tile: View {
    @Environment(\.wide) private var wide
    let model: AppModel
    let item: Item
    var landscape = false
    var newAccess = false
    var remainingTime = false

    /// Horizontal 16:9, as wide as two posters side by side; otherwise the row looks
    /// empty.
    private var width: CGFloat {
        landscape ? Theme.railsLandscapeWidth(wide: wide) : Theme.railsWidth(wide: wide)
    }
    private var height: CGFloat {
        landscape ? Theme.railsLandscapeHeight(wide: wide) : Theme.railsHeight(wide: wide)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Picture(url: landscape ? model.landscapeImageURL(for: item)
                           : model.imageURL(for: item, maxHeight: 500, portrait: true),
                 width: width, height: height, corner: Theme.cornerTile,
                 progress: progress) {
                // If the title has no landscape image, the poster steps in: cropped, but still
                // the cover and not a still.
                Picture(url: model.imageURL(for: item, maxHeight: 500, portrait: true),
                     width: width, height: height, corner: Theme.cornerTile) {
                    // **And if that is missing too, a symbol instead of emptiness.**
                    //
                    // A blank surface looks like a bug in the app, and was reported exactly that
                    // way. A symbol says: an image belongs here, the server has none.
                    Theme.area.overlay {
                        Image(systemName: item.tileCharacter)
                            .font(.system(size: 22))
                            .foregroundStyle(Theme.fontVeryQuiet)
                    }
                }
            }
            #if DEBUG
            // Debug build only: in the shipped version this would be a built address per
            // tile, for nothing.
            .onAppear {
                guard landscape, model.landscapeImageURL(for: item) == nil else { return }
                AppLog.writeOut("[Bild] \(item.seriesName ?? item.name): kein Querbild — "
                    + "eigen=\(item.imageTags?.keys.sorted().joined(separator: ",") ?? "-") "
                    + "Serienposter=\(item.seriesPrimaryImageTag != nil) "
                    + "Serienhintergrund=\(item.parentBackdropImageTags?.count ?? 0) "
                    + "Serienvorschau=\(item.parentThumbImageTag != nil)")
            }
            #endif

            VStack(alignment: .leading, spacing: 1) {
                Text(item.seriesName ?? item.name)
                    .font(Theme.tile)
                    .foregroundStyle(Theme.font)
                    .lineLimit(1)
                if let abbreviation = subline {
                    Text(abbreviation)
                        .font(Theme.small)
                        .monospacedDigit()
                        .foregroundStyle(Theme.fontQuiet)
                        .lineLimit(1)
                }
            }
            .frame(width: width, alignment: .leading)
        }
        // One announcement per tile instead of three fragments, and progress is
        // included. It is a drawing in the image and was missing entirely for
        // VoiceOver. Only from one percent: "zero percent watched" is no information.
        //
        // The announcement comes from `Item.tileAnnouncement` (title, year or season and
        // episode), the state from `tileState`, identical on all Apple platforms.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: item.tileAnnouncement))
        .accessibilityValue(Text(verbatim: item.tileState))
    }

    private var progress: Double? {
        guard let percent = item.userData?.playedPercentage, percent > 0 else { return nil }
        return percent / 100
    }

    /// The quiet line under the name. For "Continue Watching" with the remaining
    /// time, "S2 · E5 · 12 min left": the image stays free, the detail sits where
    /// the code stood anyway.
    private var subline: String? {
        if remainingTime, let row = item.continueWatchingRow { return row }
        return newAccess ? item.newArrivalsRow : item.episodeCode
    }
}


/// **How far the home page has scrolled, outside the page.**
///
/// As `@State` in `HomeView` every scroll step rebuilt the whole page. As an
/// observed object, only the views that actually read `value` are rebuilt: the
/// header.
@Observable
final class ScrollDistance {
    var value: CGFloat = 0

    /// **Only write when someone sees it.** The detail header varies between 150 and
    /// 220 pt; beyond that and for fractions of a point the value stays put and
    /// nobody is rebuilt. The bounds themselves are always reached so the header
    /// never stops half-way.
    func setDown(_ new: CGFloat, until: CGFloat = 240) {
        let clamped = min(max(new, 0), until)
        guard clamped != value else { return }
        if abs(clamped - value) >= 0.5 || clamped == 0 || clamped == until {
            value = clamped
        }
    }
}

/// The detail header, which reads the scroll distance itself so the whole movie
/// or series page does not.
struct DetailHeaderReader<Right: View>: View {
    let title: String
    let distance: ScrollDistance
    let back: () -> Void
    /// What sits on the right in the bar; on most pages nothing.
    @ViewBuilder var right: () -> Right

    var body: some View {
        DetailHeader(title: title, offset: distance.value, back: back,
                   right: AnyView(right()))
    }
}

extension DetailHeaderReader where Right == EmptyView {
    init(title: String, distance: ScrollDistance, back: @escaping () -> Void) {
        self.init(title: title, distance: distance, back: back) { EmptyView() }
    }
}

/// The home page header, which reads the scroll distance itself so `HomeView`
/// does not.
private struct HeaderReader<ContentBody: View>: View {
    let distance: ScrollDistance
    @ViewBuilder var content: () -> ContentBody

    var body: some View {
        // **The same edge as on Movies and Series.** With `offset`, `BlurHeader`
        // puts the full background under the header and fades in the thin line below it
        // when scrolling; before, the home page was the only one with a soft colored
        // gradient.
        BlurHeader(offset: distance.value, content: content)
    }
}
