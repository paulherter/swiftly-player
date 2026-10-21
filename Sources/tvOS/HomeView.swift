import JellyfinKit
import SwiftUI

/// The home page: horizontal rows like on iPhone, only larger and driven by focus.
struct HomeView: View {
    let model: AppModel
    /// The player lives in the frame, not here; see `MainView`.
    @Environment(\.playRequest) private var play

    /// Loading and ordering live in `HomeModel`, shared with the iPhone version.
    @State private var state = HomeModel()
    /// Blocks double triggers while the plan is being fetched.
    @State private var prepares = false
    @FocusState private var atTitle: TileMark?
    /// The last tile that really had focus. Survives a trip to a detail page; see `current`.
    @State private var lastAtTitle: TileMark?
    /// The title whose image is currently shown; follows the focus with a delay.
    @State private var inImage: Item?
    @State private var imageSwitch: Task<Void, Never>?
    /// Whether the initial focus has been set once. Do not test `atTitle == nil` instead:
    /// tvOS sets focus itself before any `onAppear` runs, so that check would skip exactly
    /// the case it should catch.
    @State private var startFocusSet = false
    /// What is at the front of each row, i.e. under its title. Focus lands on it when it
    /// enters a row from above or below.
    /// A box, not state: as an `@State` dictionary every focus step inside a row redrew the
    /// whole page (the row scrolls, reports its leading edge, the dictionary changes). It is
    /// only read when focus changes rows, so nobody needs to redraw when it changes.
    @State private var frontmost = PreEdges()
    /// The last write for the Top Shelf; see `shelfWrite`.
    @State private var shelfTask: Task<Void, Never>?

    @Environment(\.scenePhase) private var phase

    /// An account switch is running: the rows are off and return once content has arrived
    /// and the transition has landed, staggered (``Reihenauftritt``). The old content is gone
    /// when the switch starts, not when the new content arrives.
    @State private var change = false
    /// The rows are showing; no switch in progress.
    private var showItem: Bool { !change && !AccountSwitchTransition.shared.waits }
    /// The rows are in the tree except between the switch and its release. Then nothing
    /// invisible can take focus; it stays on the profile image at the top.
    private var built: Bool { showItem || structure }
    @State private var structure = false
    /// There is something to show and nothing is in front of it.
    private var released: Bool {
        (!state.allEmpty || state.loaded) && !AccountSwitchTransition.shared.waits
    }

    var body: some View {
        ZStack {
            if !state.loaded, AccountSwitchTransition.shared.waits {
                // Nothing between the switch and the landing, not even a placeholder that would look
                // like the old account.
                Color.clear
            } else if !state.loaded {
                // No spinner: two rows in their final shape are shown and cross-fade once the titles arrive.
                VStack(alignment: .leading, spacing: Theme.railsSpacing) {
                    RailsPlaceholder(landscape: true)
                    RailsPlaceholder()
                }
                .padding(.horizontal, Theme.edgePage)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, Theme.barBottom + 40)
                .transition(.opacity)
            } else if state.disrupted {
                // Same wording as on every other device: names the server address and asks the
                // question that helps, which "check the connection" does not.
                EmptyState(symbol: "externaldrive.badge.xmark",
                            title: "Server ist abgetaucht",
                            hint: "\(model.serverAddress ?? String(localized: "Der Server")) antwortet nicht. Läuft er noch, oder hängt das WLAN?",
                            button: ("Erneut versuchen", { Task { await load() } }))
            } else if state.allEmpty {
                EmptyState(symbol: "play.rectangle",
                            title: "Hier ist noch nichts",
                            hint: "Sobald auf dem Server etwas liegt, taucht es hier auf.")
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Also on return, not only on appear. `.task` does not cover the player closing: the
        // player is a layer over the home page, which stays in place and does not reappear.
        // That is covered by `AppModel.playbackEnded`. Foregrounding does not cover it
        // either: someone who finishes an episode on the phone and then turns on the TV would
        // still see it under "Continue Watching".
        //
        // On tvOS `scenePhase` is the right trigger, unlike on the Mac, where it also flips when
        // a second window of the app comes forward (macOS uses `didBecomeActiveNotification`).
        // A TV has no second window; `.active` means the viewer is back. The player uses the
        // same trigger to pause on leaving.
        //
        // The 30 second grace period lives in `Refresh` and is tested there; without it
        // every brief switch away would reload.
        // During an account switch the phase stays `ready`; without this guard the previous
        // account's content would remain on screen.
        .onChange(of: model.accountSwitch) { _, _ in
            // Off first, then load, then staggered in. Image and focus belong to the old account:
            // drop them so neither its backdrop stays up top nor focus wants to return to a tile
            // that no longer exists.
            AccountSwitchTransition.note("wechsel: startseite blendet aus")
            change = true
            inImage = nil
            lastAtTitle = nil
            Task {
                await load()
                if change, released { reveal() }
            }
        }
        .onChange(of: released) { _, now in
            if now, change { reveal() }
        }
        .onChange(of: model.pagesRefresh) { _, _ in Task { await load() } }
        // The setting applies immediately: toggling changes which rows exist, which is only
        // known after a new query.
        // One `task`, not two. It carries both the run on appear and the one due when rows are
        // rearranged (toggling changes which rows exist, known only after a new query). A second,
        // plain `task` next to it made everything run twice on open.
        .task(id: "\(model.newAccessDisconnected)|\(model.genreChips)|\(model.startGenres.joined(separator: "|"))|\(model.startLibraries.map(\.id).joined(separator: "|"))") {
            // While an account switch runs it does the loading, not the return to the page that
            // coincides with it.
            if AccountSwitchTransition.shared.waits { return }
            await load()
        }
        .onChange(of: phase) { _, new in
            guard new == .active, state.needsRefresh else { return }
            Task { await load() }
        }
    }

    /// What the readout describes: derived, not set.
    ///
    /// It used to be state written by `firstShow` on appear. When focus landed elsewhere
    /// than expected (tvOS sets it before any `onAppear` runs), the readout stayed on the
    /// old title: the header said "Episode 4" while another title was highlighted. Derived,
    /// it cannot do that.
    ///
    /// The fallback is the last focused tile, not the first. `atTitle` becomes `nil` when
    /// focus leaves the page, which happens whenever a detail page opens. Returning from the
    /// fourth movie used to flash the first title until focus came back.
    ///
    /// The fallback must tell two `nil` cases apart: never focused (the first title is
    /// right) and focus currently elsewhere (the last state still holds).
    ///
    /// Look in the one row, not all: the marker names its row. A list over all rows was
    /// rebuilt on every draw, i.e. every focus step.
    private var current: Item? {
        if let atTitle, let t = title(toward: atTitle) { return t }
        if let lastAtTitle, let t = title(toward: lastAtTitle) { return t }
        return firstTitle
    }

    private func title(toward mark: TileMark) -> Item? {
        list(mark.rail).first { $0.id == mark.title }
    }

    /// The backdrop currently shown. Same URL as on the detail page (`width: 1600`) so the
    /// image is already cached there.
    private var backdropsURL: URL? {
        guard let t = inImage else { return nil }
        return model.landscapeImageURL(for: t, width: 1600) ?? model.headerImageURL(for: t)
    }

    /// What the page opens on: the first "Continue Watching" entry, else the first at all.
    private var firstTitle: Item? {
        state.continueWatching.first ?? state.nextEpisode.first ?? state.recent.first
            ?? state.newMovies.first ?? state.newSeries.first
            ?? state.genreRails.lazy.compactMap(\.items.first).first
    }

    private func list(_ rail: RailsId) -> [Item] {
        switch rail {
        case .continueWatching: state.continueWatching
        case .nextEpisode: state.nextEpisode
        case .recent:       state.recent
        case .newMovies:     state.newMovies
        case .newSeries:    state.newSeries
        case let .genre(name):
            state.genreRails.first { $0.name == name }?.items ?? []
        case let .library(id):
            libraries.first { $0.id == id }?.items ?? []
        }
    }

    /// Which fixed rows exist right now; order and selection come from settings
    /// (Profile, Appearance).
    private var fixedRails: [StartRail] {
        model.startRails.filter {
            !model.startOut.contains($0) && $0.fits(disconnected: model.newAccessDisconnected)
        }
    }

    /// The chosen libraries and collections that currently have titles.
    private var libraries: [Home.LibraryRail] {
        state.libraryRails(for: model.startLibraries)
    }

    /// The focus identifier for a configured row.
    private func identifier(_ rail: StartRail) -> RailsId {
        switch rail {
        case .continueWatching: .continueWatching
        case .nextEpisode: .nextEpisode
        case .newMovies:     .newMovies
        case .newSeries:    .newSeries
        case .newArrivals:   .recent
        }
    }

    /// The front tile of a row: the one currently under its title. If the row has reported
    /// nothing yet, the first one.
    private func frontmostMark(_ rail: RailsId) -> TileMark? {
        let entries = list(rail)
        guard !entries.isEmpty else { return nil }
        let front = frontmost.je[rail]
        let title = entries.contains { $0.id == front } ? front! : entries[0].id
        return TileMark(rail: rail, title: title)
    }

    /// The same tile as a focus marker, including its row; otherwise it is ambiguous.
    private var startMark: TileMark? {
        // The first row that exists, not "Continue Watching": whoever reorders or hides a row
        // expects focus at the top, and something else is there then.
        for rail in fixedRails {
            let k = identifier(rail)
            if let t = list(k).first { return .init(rail: k, title: t.id) }
        }
        for g in state.genreRails where !g.items.isEmpty {
            return .init(rail: .genre(g.name), title: g.items[0].id)
        }
        return nil
    }

    /// Apple's structure, with a fixed header zone in front.
    ///
    /// A hand-built row header (a `VStack` of row title and strip) was the problem here.
    /// tvOS only knows a row title when it is declared as a `Section` header (WWDC24,
    /// "Migrate your TVML app to SwiftUI"): the title moves out of the way as lockups gain
    /// focus so it is not occluded.
    ///
    /// The focus engine frees up the tile. A title in an ordinary stack counts as decoration
    /// for that calculation and slides under the window edge whenever focus jumps into a row.
    /// No margin, inset or clip could compensate, because the title was never counted.
    ///
    /// No `viewAligned`, deliberately. Apple's session adds it, but it only stops where a
    /// section sits flush at the top. For the last section that position lies beyond the
    /// scroll limit and is reachable only with a large empty area below the last row, which
    /// we do not want. With `viewAligned` the bottom row was not reachable at all.
    ///
    /// The header zone is a sibling, not an inset. It shows what is highlighted below, so it
    /// must not scroll. As a sibling in the `VStack`, the scroll view below has its own
    /// correct geometry: its window is the space under the header zone, and nothing covers
    /// it or takes space from it unannounced.
    ///
    ///     window = 1080 - heroHeight = 570
    ///     poster row = 24 + 45 + 16 + (20 + 390 + 20) + 28 = 543
    ///
    /// So one section fits in the window, which is the condition for the focus engine to
    /// free header and tiles together.
    private var content: some View {
        VStack(spacing: 0) {
            heroZone
                .railEntrance(0, present: showItem)
            if built {
                rails
            } else {
                Spacer(minLength: 0)
            }
        }
        // The side margin is applied once, not twice. tvOS already keeps 80 pt free on the left
        // and right, and the page adds `Theme.edgePage` (also 80): 160 together, twice the
        // design, which measures from 80. So the system margin is dropped here and `edgePage`
        // measures from the screen edge.
        //
        // On each side individually, not on the frame: set on the frame it has no effect, because
        // the `NavigationStack` in `stack(b)` resets the safe area for its content (measured:
        // the wordmark moved, the content below did not).
        .ignoresSafeArea()
        // The same tinted background as on the detail pages, so opening one changes nothing
        // about the background and there is nothing to cross-fade or twitch.
        //
        // It hangs on the debounced image, not on focus; otherwise every intermediate step
        // while holding the remote would compute its own tint.
        .imageReason(url: backdropsURL)
        // Only the image needs state, because it is debounced.
        .onChange(of: current?.id) { _, _ in
            if let t = current { switchImage(toward: t) }
        }
        .onAppear { firstShow() }
        // The gift and "What's new" wait for a home page that is up (see `GiftFlow`).
        .onChange(of: state.loaded, initial: true) { _, loaded in GiftFlow.shared.homeVisible(loaded) }
        .onDisappear { GiftFlow.shared.homeVisible(false) }
        .onChange(of: state.continueWatching.first?.id) { _, _ in firstShow() }
        // Pull focus from the top bar into the first row.
        //
        // `defaultFocus` only says what is preselected inside the scroll view. Whether the home
        // page or the top bar gets focus on open is decided one level up by tvOS, and it took
        // the "Start" tab.
        //
        // `initial: true` also runs on appear; if nothing is loaded yet `firstTitle` is nil and
        // it runs again once the first title exists.
        //
        // Vertically, focus falls on the front tile of the row. Not the same column and not the
        // first overall: the row keeps its scroll position and focus takes whatever is under the
        // row title. Someone who scrolled far in "Recently Added" finds the row as they left it.
        //
        // Corrected afterwards rather than preselected: tvOS only asks for a preference
        // (`prefersDefaultFocus`) when entering a region without direction. On a press down,
        // geometry alone decides, and it cannot be right here: "Continue Watching" tiles are
        // 448 wide, posters 208, and landscape tile 1 overlaps posters 1 and 2, so there is no
        // shared column. So the system move runs and is then adjusted.
        // Remember while focus is here. `nil` is deliberately not taken over; that is the point.
        .onChange(of: atTitle) { _, now in
            if let now { lastAtTitle = now }
        }
        #if DEBUG
        .onChange(of: atTitle) { _, now in
            if AccountSwitchRun.an { AccountSwitchTransition.note("fokus: startseite \(now.map { "\($0.rail)" } ?? "-")") }
        }
        #endif
        .onChange(of: atTitle) { before, now in
            guard let now, let before, before.rail != now.rail else { return }
            if let target = frontmostMark(now.rail), target != now { atTitle = target }
        }
        .onChange(of: startMark, initial: true) { _, mark in
            guard !startFocusSet, let mark else { return }
            startFocusSet = true
            atTitle = mark
        }
        // Focus does not return from the player by itself.
        //
        // `play` is a sibling in the frame, not a child; the home page stays mounted while
        // playing, only `disabled`. `disabled` resets `atTitle` to `nil` (the tile cannot hold
        // focus meanwhile), and when the player is removed tvOS does not ask for `defaultFocus`
        // again: it does so only on the first evaluation of a focus region, which has existed
        // uninterrupted since the page started. Without this line the focus engine searches
        // anew and lands geometrically at the top, on the first top-bar tab.
        //
        // The assignment acts like a key press: with `atTitle` set while the tile is focusable
        // again, focus moves there, the same path `.focused(_:equals:)` takes otherwise.
        .onChange(of: play.wrappedValue == nil) { before, closed in
            guard closed, before == false, atTitle == nil, let target = lastAtTitle
            else { return }
            atTitle = target
        }
    }

    /// The rows: each a `Section`, nothing hand-built.
    ///
    /// `VStack`, not `LazyVStack`, although Apple's example uses the lazy stack. That is for
    /// catalogs with hundreds of rows; here there are three and it only costs.
    ///
    /// Why it hurts here: a section is 543 high, the window 570. With focus on row 2, row 3
    /// begins exactly on the window edge. The lazy stack creates what intersects the visible
    /// area, so the row is sometimes one point in, sometimes one point out. If it does not
    /// exist, the focus engine finds nothing and "down" does nothing. Afterwards it exists
    /// and stays, so the second attempt worked.
    ///
    /// Order dependent, so a successful pass proves nothing. The lazy stack also estimated
    /// row heights and accumulated a focus offset.
    private var rails: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                // Genres as chips at the very top, when enabled. An entry point, not content: a press
                // opens the genre.
                if model.genreChips, !model.startGenres.isEmpty {
                    genreChips.railEntrance(1, present: showItem)
                }

                // The fixed rows in the configured order, without hidden ones (Profile, Appearance,
                // Home). Staggered after an account switch (``Reihenauftritt``).
                ForEach(Array(fixedRails.enumerated()), id: \.element) { i, rail in
                    pinned(rail).railEntrance(i + 2, present: showItem)
                }

                // The chosen libraries and collections, then the genres.
                ForEach(Array(libraries.enumerated()), id: \.element.id) { j, bib in
                    railsSection {
                        RailTitle(name: bib.name)
                    } content: {
                        Strip(model: model, items: bib.items,
                                 rail: .library(bib.id),
                                 atTitle: $atTitle, frontmost: frontmost)
                    }
                    .railEntrance(fixedRails.count + 2 + j, present: showItem)
                }
                ForEach(Array(state.genreRails.enumerated()), id: \.element.id) { j, genre in
                    if !genre.items.isEmpty {
                        railsSection {
                            RailTitle(name: genre.name)
                        } content: {
                            Strip(model: model, items: genre.items,
                                     rail: .genre(genre.name),
                                     atTitle: $atTitle, frontmost: frontmost)
                        }
                        .railEntrance(fixedRails.count + libraries.count + 2 + j, present: showItem)
                    }
                }
                // Only after the last row, and only when it is due.
                if SupportModel.shared.cardVisible {
                    TVSupportCard()
                        .padding(.horizontal, Theme.edgePage)
                        .padding(.top, Theme.railsSpacing)
                        .transition(.opacity)
                }
            }
            // So the bottom row at the scroll limit has the same distance to the screen edge as two
            // rows have to each other. See `completionPadding`.
            .padding(.bottom, Theme.completionPadding)
        }
        .scrollIndicators(.hidden)
        // Where focus stands on open is stated, not hoped for.
        //
        // While the lazy stack had created only the first row, focus landed there by default.
        // With all three rows tvOS picks one itself, and it picked "Recently Added".
        //
        // Setting it afterwards did not work: `firstShow` only set while focus was nowhere,
        // and tvOS is faster than any `onAppear`. `userInitiated` beats the system's choice;
        // `automatic` would only be a suggestion.
        //
        // Going back means returning to where one was, not to the top.
        //
        // The default focus pointed at `startMark`, the first tile of the first row. tvOS applies
        // it every time the page reappears, not just the first: after going back focus jumped to
        // the top and the scroll view followed.
        //
        // `lastAtTitle` records where focus really was (it exists already because the readout
        // above needs the same fallback). On first open it is empty and `startMark` applies.
        .defaultFocus($atTitle, lastAtTitle ?? startMark, priority: .userInitiated)
        // Clipping here is intended. The tile's zoom is absorbed by the strip with `railsPadding`
        // inside its own bounds, so the vertical scroll view may clip, and only so can no tile
        // ever reach into the header zone.
    }

    /// A fixed row: same structure as before, individually callable so the order from
    /// settings applies.
    @ViewBuilder
    private func pinned(_ rail: StartRail) -> some View {
        switch rail {
        case .continueWatching:
            if !state.continueWatching.isEmpty {
                // "Continue Watching" starts immediately, without an intermediate page. The others lead
                // to the overview.
                segment("Weiterschauen") {
                    Strip(model: model, items: state.continueWatching,
                             rail: .continueWatching, landscape: true,
                             direct: launch, atTitle: $atTitle,
                             frontmost: frontmost)
                }
            }
        case .nextEpisode:
            if !state.nextEpisode.isEmpty {
                segment("Nächste Folge") {
                    Strip(model: model, items: state.nextEpisode,
                             rail: .nextEpisode, atTitle: $atTitle,
                             frontmost: frontmost)
                }
            }
        case .newMovies:
            newAccessRail("Zuletzt hinzugefügte Filme", state.newMovies, .newMovies)
        case .newSeries:
            newAccessRail("Zuletzt hinzugefügte Serien", state.newSeries, .newSeries)
        case .newArrivals:
            newAccessRail("Zuletzt hinzugefügt", state.recent, .recent)
        }
    }

    @ViewBuilder
    private func newAccessRail(_ title: LocalizedStringKey, _ items: [Item],
                                 _ rail: RailsId) -> some View {
        if !items.isEmpty {
            segment(title) {
                Strip(model: model, items: items, rail: rail,
                         newAccess: true, atTitle: $atTitle, frontmost: frontmost)
            }
        }
    }

    /// Your genres as chips, the same ones that would otherwise appear as rows.
    private var genreChips: some View {
        strip {
            ForEach(model.startGenres, id: \.self) { name in
                NavigationLink(value: GenreRoute(name: name)) {
                    // From the server, so not translated.
                    //
                    // One line. The pill has a fixed height; a long genre name wrapped and ran out of it
                    // at top and bottom.
                    Text(verbatim: name)
                        .lineLimit(1)
                }
                .buttonStyle(ThemedButtonStyle(height: Theme.chipHeight))
            }
        }
        .padding(.bottom, Theme.railsSpacing - Theme.railsPadding)
    }

    /// A row section. The spacing lives in `railsSection`, shared by the home, movie and
    /// series pages; only the label is here.
    private func segment<ContentBody: View>(_ title: LocalizedStringKey,
                                         @ViewBuilder _ content: () -> ContentBody) -> some View {
        railsSection { RailTitle(text: title) } content: { content() }
    }

    // MARK: Kopfzone

    /// Landscape image and readout; the first child of the scroll view.
    ///
    /// Not clipped. The landscape image may extend below the 560 mark; its own gradient ends
    /// it. Clipped, it produced a hard edge that showed as a light stripe across the screen.
    /// The first row draws over it anyway, being the next sibling.
    private var heroZone: some View {
        ZStack(alignment: .topLeading) {
            // No `Theme.reason`: the page background is the tinted gradient (see `imageReason`), and an
            // opaque surface in front would hide it exactly in the header zone.
            landscapeImage
                .frame(maxWidth: .infinity, alignment: .trailing)
            // Only a soft shadow under the bar, no long header gradient: the bar stays legible
            // without making the page look different from a detail page. It sits under the text;
            // above it, it tinted the title grey.
            HeaderShadow()
            inquiry
                .padding(.leading, Theme.edgePage)
                .padding(.top, Theme.contentTop)
        }
        // Full 510, measured from the screen edge.
        //
        // The outer stack leaves out the top margin, so the zone starts at zero and the
        // design dimensions apply unchanged, including the 196 where the
        // readout starts.
        //
        // Not clipped: the landscape image is 700 high and ends with its own gradient. Cut at
        // 510 it would show the hard edge that once lay across the image as a light stripe. The
        // rows draw over it, being the next sibling.
        .frame(height: Theme.heroHeight, alignment: .topLeading)
    }

    /// The image changes debounced and cross-faded.
    ///
    /// Holding the remote moves focus every tenth of a second. A new image with a new
    /// identity per step means empty box, network fetch, image: it flashes on every key
    /// press. Debouncing by half a second and cross-fading, with the old image staying until
    /// the new one is there, avoids that.
    private func switchImage(toward title: Item) {
        imageSwitch?.cancel()
        imageSwitch = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            inImage = title
        }
    }

    /// From "Continue Watching" straight into the episode, without an intermediate page.
    /// Before the first focus, the top shows what the viewer most likely wants: the first
    /// "Continue Watching" entry.
    private func firstShow() {
        // Only the image. Focus is set declaratively by `defaultFocus`. An assignment after
        // 120 ms used to be here; it only took effect while focus was still nowhere, and tvOS
        // was faster, so it never worked when it mattered.
        guard inImage == nil else { return }
        inImage = firstTitle
    }

    /// The landscape image on the right, 1180 wide.
    ///
    /// The fade is the same as on the detail page (`BackdropsFade`), a precondition for
    /// nothing visibly changing on open.
    @ViewBuilder
    private var landscapeImage: some View {
        // The same building block as on the detail page, not just the same dimensions.
        //
        // A second version used to be here with its own `AsyncImage`, frame, fade and padding.
        // It looked the same and was not. When a detail page opened, SwiftUI cross-faded one
        // into the other, and whatever did not match showed as a twitch.
        //
        // It was strong going in and barely visible going back; that was the hint: on return the
        // home page is long since built and rebuilds nothing. The difference arises on the page
        // that is created.
        //
        // `id` and cross-fade stay outside; they belong to the home page, where focus moves
        // from title to title. The detail page does not need them.
        ZStack {
            if let t = inImage {
                Backdrop(url: model.landscapeImageURL(for: t, width: 1600)
                             ?? model.headerImageURL(for: t))
                    .id(t.id)
                    .transition(.opacity)
            }
        }
        .animation(Theme.motion(.easeInOut(duration: 0.3)), value: inImage?.id)
    }

    /// Title, details and description for the title under focus.
    @ViewBuilder
    private var inquiry: some View {
        Group {
            if let t = current {
                // The same building block as on the detail page. The structure used to be here a
                // second time and the two had already drifted apart: genres there, remaining time here.
                // See `HeaderInfo`.
                HeaderInfo(item: t,
                             secondLine: t.type == "Episode" ? t.name : nil,
                             series: series(toward: t)) {
                    // The remaining time also jumps on title change instead of gliding; see `DetailsRail`.
                    RemainingTimeMark(item: t)
                        .id(t.id)
                        .transaction { $0.animation = nil }
                }
                // The series comes from the cache the home page fills per row in a batch
                // (`prefetchBundle`): no fetch under the focus, the change is complete at once.
            }
        }
    }

    /// The series of an episode if already known, from the cache or from the state of an
    /// already visited series page.
    private func series(toward t: Item) -> Item? {
        guard t.type == "Episode" else { return nil }
        return SeriesCache.shared.series(for: t, with: model)
            ?? t.seriesId.flatMap { SeriesCache.shared.state($0, with: model)?.series }
    }


    private func launch(_ item: Item) {
        // Fetch fresh: the entry in the list item is often stale.
        PlayRequest.start(item, freshValue: true, model: model, prepares: $prepares,
                              play: { play.wrappedValue = $0 })
    }

    private func load() async {
        AccountSwitchTransition.note("startseite: laden (konto \(model.accountSwitch))")
        let a = Date()
        await state.load(model)
        AccountSwitchTransition.note("startseite: geladen nach \(Int(Date().timeIntervalSince(a) * 1000)) ms")
        // Failed query and nothing there: do not overwrite a good preview with an empty one.
        if !(state.disrupted && state.allEmpty) { shelfWrite() }
    }

    /// Build first (invisible), show in the next pass; otherwise newly inserted rows would
    /// appear at their destination at once, without the stagger.
    private func reveal() {
        guard !structure else { return }
        AccountSwitchTransition.note("wechsel 6: reihen werden gebaut")
        structure = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            AccountSwitchTransition.note("wechsel 7: reihen kommen gestaffelt")
            change = false
            structure = false
        }
    }

    /// Stores for the Top Shelf what the home page currently shows.
    ///
    /// The same three categories in the same order; empty ones are omitted. So the home
    /// screen shows the same as the app, and someone with only "Continue Watching" sees only
    /// that.
    ///
    /// Eight entries per category: the Top Shelf shows no more at a glance, and the file
    /// stays small.
    private func shelfWrite() {
        func entries(_ items: [Item], landscape: Bool) -> [ShelfEntry] {
            items.prefix(8).map { item in
                ShelfEntry(
                    id: item.id,
                    title: item.seriesName ?? item.name,
                    subline: item.episodeCode,
                    image: landscape ? (model.landscapeImageURL(for: item, width: 900)
                                  ?? model.imageURL(for: item, maxHeight: 600, portrait: true))
                               : model.imageURL(for: item, maxHeight: 600, portrait: true),
                    progress: item.watchedShare)
            }
        }

        var categories: [ShelfCategory] = []
        if !state.continueWatching.isEmpty {
            categories.append(.init(title: String(localized: "Weiterschauen"), landscape: true,
                                  entries: entries(state.continueWatching, landscape: true)))
        }
        if !state.nextEpisode.isEmpty {
            categories.append(.init(title: String(localized: "Nächste Folge"), landscape: false,
                                  entries: entries(state.nextEpisode, landscape: false)))
        }
        if !state.recent.isEmpty {
            categories.append(.init(title: String(localized: "Zuletzt hinzugefügt"), landscape: false,
                                  entries: entries(state.recent, landscape: false)))
        }
        // Separate new additions: `recent` is then empty, the home page shows movies and series
        // individually, and so does the shelf.
        if !state.newMovies.isEmpty {
            categories.append(.init(title: String(localized: "Zuletzt hinzugefügte Filme"), landscape: false,
                                  entries: entries(state.newMovies, landscape: false)))
        }
        if !state.newSeries.isEmpty {
            categories.append(.init(title: String(localized: "Zuletzt hinzugefügte Serien"), landscape: false,
                                  entries: entries(state.newSeries, landscape: false)))
        }
        // Off the main actor. Reading, comparing and writing the file used to sit on the main
        // actor after every home page load, exactly while the rows fade in.
        let preview = ShelfPreview(categories: categories)
        let numbers = categories.map(\.entries.count)
        // One after another, never two at once: each round waits for the previous one;
        // otherwise two fast loads wrote the same file.
        let previous = shelfTask
        shelfTask = Task.detached(priority: .utility) {
            await previous?.value
            Shelf.write(preview)
            AppLog.writeOut("[Regal] \(numbers.count) Rubriken, \(numbers) Eintraege · \(Shelf.finding())")
        }
    }
}

// MARK: - Focus marker

/// The leading edge of each row; deliberately not observable, see `HomeView.frontmost`.
@MainActor
private final class PreEdges {
    var je: [RailsId: String] = [:]
}

/// Which row; only for telling markers apart, not for display.
private enum RailsId: Hashable {
    case continueWatching, nextEpisode, recent
    /// New movies and new series separately, when "separate new additions" is on.
    case newMovies, newSeries
    /// A chosen genre. The name is the identifier; two rows of the same genre do not exist.
    case genre(String)
    /// A chosen library or collection; the server's identifier.
    case library(String)
}

/// What focus refers to on the home page: row and title.
///
/// The title identifier alone is not enough, as measured: the same movie regularly
/// appears in "Continue Watching" and in "Recently Added". Both tiles then carried the
/// same marker. When it is set, tvOS has two candidates and picks one; it picked the
/// lower, and the page opened in the middle of the last row.
///
/// With the row in it the marker is unique, without the categories having to coordinate.
/// (That `HomeModel` delivers the same titles twice is shared logic and belongs
/// to be checked on iOS first; the display must not depend on it.)
private struct TileMark: Hashable {
    let rail: RailsId
    let title: String
}

// MARK: - Row

/// A horizontally scrolling row.
///
/// `scrollClipDisabled` is a precondition, not polish: the focus ring sits 10 pt outside
/// the tile and the scroll view would cut it at its edge, top and bottom.
private struct Strip: View {
    let model: AppModel
    let items: [Item]
    /// Distinguishes this row's focus markers from those of other rows.
    let rail: RailsId
    var landscape = false
    var newAccess = false
    /// If set, clicking starts playback immediately instead of leading to the page.
    var direct: ((Item) -> Void)?
    /// Reports upward which title is under focus.
    @FocusState.Binding var atTitle: TileMark?
    /// Registers here what is at the front of this row.
    let frontmost: PreEdges

    /// The tile at the leading edge, reported by the scroll view.
    @State private var ahead: String?

    /// Only the tiles. The title is the `Section` header above: tvOS only knows it that way
    /// and frees it on focus. Hand-built, it slides under the window edge.
    var body: some View {
        ScrollView(.horizontal) {
            // `HStack`, not `LazyHStack`, for the same reason as vertically, and here it is required.
            //
            // The row change is corrected afterwards (see `content`), and an assignment to
            // `@FocusState` only moves focus if the target tile exists. The lazy stack creates only
            // what is visible. If the row is shifted by two tiles, tile 1 does not exist, the
            // assignment fizzles, and focus stays on the third, every time, because the offset is
            // fixed.
            //
            // The cost: rows load their images at once, at most 24 per row
            // (`AppModel.lastAdded`). Small posters, in exchange for predictable focus.
            HStack(alignment: .top, spacing: Theme.tileSpacing) {
                ForEach(items) { item in
                    Group {
                        if let direct {
                            Button { direct(item) } label: { tile(item) }
                                // Long press on the remote, as in Apple's TV app; `contextMenu` does that on tvOS
                                // itself. The same menu as on iPhone (`TileMenu`), here with "To overview" and
                                // "Remove from Continue Watching".
                                .tileMenu(item, model: model,
                                             continueWatching: rail == .continueWatching, landscape: landscape)
                        } else {
                            // On every tile since 1.0.5, not only on "Continue Watching", as on iPhone.
                            NavigationLink(value: item) { tile(item) }
                                .tileMenu(item, model: model, landscape: landscape)
                        }
                    }
                    .buttonStyle(TileStyle())
                    .focused($atTitle, equals: .init(rail: rail, title: item.id))
                }
            }
            .padding(.horizontal, Theme.edgePage)
            // Room for the zoom. The focused tile grows by 1.08 beyond its layout size. This
            // padding absorbs that inside the row, so the vertical scroll view above may clip
            // without cutting a tile.
            .padding(.vertical, Theme.railsPadding)
            // Marks the tiles as reference points so `scrollPosition` can say which is at the
            // front. No `scrollTargetBehavior` on purpose: nothing should snap, only be reported.
            .scrollTargetLayout()
        }
        .scrollPosition(id: $ahead, anchor: .leading)
        .onChange(of: ahead, initial: true) { _, id in frontmost.je[rail] = id }
        .scrollClipDisabled()
        .scrollIndicators(.hidden)
        // Each row is its own section.
        //
        // Without it tvOS looks vertically for a tile in the same column. "Next Up" often has
        // fewer entries than "Continue Watching"; from the third tile focus found nothing there
        // and jumped two rows down. As a section the row counts as a whole and is targeted
        // regardless of its width.
        .focusSection()
    }

    private func tile(_ item: Item) -> some View {
        TileContent(image: imageUrl(item),
                     title: item.seriesName ?? item.name,
                     subline: subline(item),
                     landscape: landscape,
                     progress: progress(item),
                     symbolText: item.tileCharacter)
    }

    private func imageUrl(_ item: Item) -> URL? {
        landscape ? (model.landscapeImageURL(for: item, width: 900)
                ?? model.imageURL(for: item, maxHeight: 600, portrait: true))
             : model.imageURL(for: item, maxHeight: 600, portrait: true)
    }

    /// The quiet line under the name. For "Continue Watching" it carries the remaining time,
    /// "S2 · E5 · 12 min left": the image stays clear and the detail sits where the
    /// abbreviation was anyway. The line comes from the package (`continueWatchingRow`).
    private func subline(_ item: Item) -> String? {
        if rail == .continueWatching, let row = item.continueWatchingRow { return row }
        return newAccess ? item.newArrivalsRow : item.episodeCode
    }

    private func progress(_ item: Item) -> Double? { item.watchedShare }
}
