import AppKit
import JellyfinKit
import SwiftUI

/// The home page: Continue Watching, Next Up, Recently Added.
///
/// **No header gradient.** On iPhone and TV a gradient sits at the top because the
/// clock, battery and wordmark overlap scrolling content and must stay readable.
/// In a window there is nothing there; the wordmark sits in the sidebar. A
/// gradient over empty space would be decoration with no job.
///
/// A tile in "Weiterschauen" (Continue Watching) starts **immediately** at the
/// saved position, "Nächste Folge" (Next Up) starts from the beginning, and
/// "Zuletzt hinzugefügt" (Recently Added) opens the detail page, since nothing
/// has been started there. These are the same rules as the iPhone version.
struct HomeView: View {
    let model: AppModel
    @Environment(PlayControls.self) private var controls
    @Environment(Navigator.self) private var navigator
    @Environment(\.section) private var section

    /// **The shared state, not a separate one.**
    ///
    /// The state lives in `MainView` and survives switching tabs. It is the shared
    /// `HomeModel`; a separate copy would drift apart (for example by calling
    /// `nextEpisode()` without an argument, which lists Continue Watching titles
    /// again under Next Up), and clearing the whole row on a single failed request is
    /// exactly what the comment in the shared model warns against.
    let state: HomeModel

    private var proceed: [Item] { state.continueWatching }
    private var next: [Item] { state.nextEpisode }
    private var new: [Item] { state.recent }
    private var loaded: Bool { state.loaded }

    /// Where the page is scrolled to, as its own object so a scroll tick does not
    /// re-evaluate the whole body. See `HeaderState`.
    @State private var headerState = HeaderState()
    /// The running load. **There is only ever one.** Account switch, a setting,
    /// returning to the window and the end of playback each used to start their own,
    /// and they ran side by side.
    @State private var loadTask: Task<Void, Never>?

    /// **An account switch is in progress**, as on iPhone: the rows are hidden and
    /// only appear once there is content and the image has landed, then staggered
    /// (``Reihenauftritt``).
    @State private var change = false
    @State private var structure = false
    /// The rows are shown and no switch is in progress. On click in the profile
    /// page they disappear immediately, before the account changes.
    private var showItem: Bool { !change && !AccountSwitchTransition.shared.waits && !outdated }
    /// **The switch happened while the home page was not in the view tree** (the
    /// user was on Movies or Series). Its `onChange` did not see it, so it came back
    /// with the old account's rows, which then gave way to placeholders and the new
    /// content. Handled like a live switch: hide rows, load, staggered fade-in.
    @State private var firstRunSelection = true
    private var outdated: Bool { state.loaded && state.outdated(model) }
    /// The rows are in the tree, except between click and release: anything
    /// arriving mid-flight is neither set nor decrypted.
    private var built: Bool { showItem || structure }
    /// There is something to show and nothing in front of it.
    private var released: Bool {
        (!state.allEmpty || state.loaded) && !AccountSwitchTransition.shared.waits
    }

    private var libraries: [Home.LibraryRail] {
        state.libraryRails(for: model.startLibraries)
    }

    /// The posters of a row from a genre or library.
    @ViewBuilder
    private func postern(_ items: [Item]) -> some View {
        ForEach(items, id: \.id) { title in
                            Button { navigator.openIt(.title(title), in: section) } label: {
                                PosterCell(title: title.name,
                                             secondLine: title.productionYear.map { "\($0)" },
                                             image: model.imageURL(for: title, portrait: true),
                                             progress: progress(title),
                                             symbolText: symbolText(title),
                                             prefetch: {
                SeriesCache.shared.prefetch(title, with: model)
                PlanPreAdvice.prefetch(title, with: model)
            })
                            }
                            .buttonStyle(Theme.PressButton())
                            .tileMenu(title, model: model)
                        }
    }

    private var fixedRails: [StartRail] {
        model.startRails.filter {
            !model.startOut.contains($0) && $0.fits(disconnected: model.newAccessDisconnected)
        }
    }

    var body: some View {
        ScrollView {
            // **No color glow.** It was announced in the code as an experiment that could be
            // reverted, and it broke the rule that surfaces are flat: the only color gradient
            // in the app on a side surface, built from raw white values. Removed after
            // checking it on the Mac. With it, the `ZStack` is gone too, since there is
            // nothing left to overlay.
            VStack(alignment: .leading, spacing: Theme.railsSpacing) {

                // **The home page has a heading too.**
                //
                // Movies, Series, Search, Watchlist and Downloads have one, so the home page
                // starts with a 28 pt title, not with "Weiterschauen" at 20 pt. That also makes
                // `reihenkopfAusgleich` unnecessary: it existed so that a 20 pt line would sit as
                // high as a 28 pt title.
                Text("Startseite")
                    .font(Theme.titleLarge)
                    .tracking(Theme.lockTitle)
                    .foregroundStyle(Theme.font)
                    .padding(.horizontal, Theme.edgeSpacing)

                // **Genres as chips at the very top**, when enabled. An entry point, not
                // content: a click opens the genre.
                if built {
                if model.genreChips, !model.startGenres.isEmpty {
                    genreChips.railEntrance(0, present: showItem)
                }

                // **The fixed rows in the configured order**, without the hidden ones
                // (Settings > Appearance > Home).
                ForEach(Array(fixedRails.enumerated()), id: \.element) { i, rail in
                    pinned(rail).railEntrance(i + 1, present: showItem)
                }

                // **The chosen libraries and collections** (Appearance > Home > "+"): the title is
                // their name, the header opens them. After that the genres as rows of their own.
                ForEach(Array(libraries.enumerated()), id: \.element.id) { j, r in
                    Rail(name: r.name, header: {
                        let entryRecord = model.startLibraries.first { $0.id == r.id }?.item
                            ?? Item(id: r.id, name: r.name)
                        navigator.openIt(.collection(entryRecord, art: nil), in: section)
                    }) { postern(r.items) }
                    .railEntrance(fixedRails.count + 1 + j, present: showItem)
                }
                ForEach(Array(state.genreRails.enumerated()), id: \.element.id) { j, genre in
                    Rail(name: genre.name) {
                        postern(genre.items)
                    }
                    .railEntrance(fixedRails.count + libraries.count + 1 + j, present: showItem)
                }
                }

                // **Failed is not empty.** The model knows the difference
                // (`HomeModel.disrupted`). When a server does not answer, showing "Hier
                // ist noch nichts" (nothing here yet) would be a false statement and would send
                // the user to the server instead of the network. Wording and icon are the server
                // message used identically everywhere.
                if loaded, state.disrupted {
                    EmptyState(
                        symbol: "externaldrive.badge.xmark",
                        headerLine: "Server ist abgetaucht",
                        text: "\(model.serverAddress ?? String(localized: "Der Server")) antwortet nicht. Läuft er noch, oder hängt das WLAN?",
                        primaryButton: ("Erneut versuchen", { Task { await load() } }))
                        .padding(.top, 120)
                } else if loaded, state.allEmpty {
                    // `allEmpty` instead of three separate checks: the same statement, and it
                    // lives in the shared `HomeModel`.
                    EmptyState(symbol: "tray", headerLine: "Hier ist noch nichts",
                                text: "Sobald der Server Titel hat, stehen sie hier.")
                        .padding(.top, 120)
                }
            }
            // **The rows disappear on click immediately, without animation.** Otherwise they
            // would be caught in the sideways push of the profile page, which slides out right
            // after, and would fade out underneath it.
            .transaction(value: built) { if !$0.disablesAnimations, !built { $0.animation = nil } }
            .padding(.top, Theme.contentTop)
            .padding(.bottom, 40)
            // **Full width, even without rows.** If the rows leave the tree on click in the
            // profile page, only the title remained and the whole home page shrank to its
            // width (173 instead of 1131 pt, measured). Under the outgoing profile page there
            // was then a narrow block with a scrim instead of the page.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        // The same fixed title as on Movies, Series and Watchlist.
        .overlay(alignment: .top) {
            StateBar(title: "Startseite", state: headerState)
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, new in
            headerState.offset = new
        }
        // **The frosted bar at the top edge.** macOS 26 places it over every scroll view
        // by itself; it was never in our code, so it is easy to look in the wrong place.
        // Over the image it disappeared, and on plain background it showed up as a bar.
        //
        // What the framework adds unasked has to be turned off just like what we write
        // ourselves.
        .pagesScroll()
        // Two rows in their own shape instead of a ring.
        .overlay(alignment: .topLeading) {
            if !loaded {
                VStack(alignment: .leading, spacing: Theme.railsSpacing) {
                    RailsPlaceholder(landscape: true)
                    RailsPlaceholder()
                }
                .padding(.horizontal, Theme.edgeSpacing)
                // Below the title, like the rows it replaces.
                .padding(.top, Theme.contentTop + 33 + Theme.railsSpacing)
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .animation(Theme.reveal, value: loaded)
        .task { await load() }
        .onAppear {
            if outdated {
                change = true
                Task {
                    await allRefresh()
                    if change, released { reveal() }
                }
            }
        }
        // **The setting takes effect immediately, not on next open.**
        //
        // Toggling it changes which rows exist at all, and that is only known after a
        // new request. Without this, users saw their own setting only on the next launch
        // and thought it had no effect.
        .task(id: "\(model.newAccessDisconnected)|\(model.genreChips)|\(model.startGenres.joined(separator: "|"))|\(model.startLibraries.map(\.id).joined(separator: "|"))") {
            // If an account switch is running, that one loads, not the appearance that
            // coincides with it (which would still fetch the old account).
            if AccountSwitchTransition.shared.waits { return }
            // **The first run belongs to `load()`.** Both tasks start on first appearance at
            // the same time; the second one cancelled the first and sent all requests again.
            // If the page is already loaded (returning via the tab bar), it stays a refresh.
            if firstRunSelection {
                firstRunSelection = false
                if !state.loaded { return }
            }
            await allRefresh()
        }
        // **The account switch is not tied to `phase`.**
        //
        // Listening to `model.phase` looks obvious, but at the switch it is already
        // `.ready` and does not change, so the home page never reloaded and kept showing
        // the previous account's titles. `.task` does not help either: the view stays in
        // place and does not appear anew. The counter in `AppModel` is the only thing that
        // reliably changes.
        //
        // It goes through `auffrischen()`, not `load()`, which would bounce off
        // `state.loaded`. Nothing is cleared: `HomeModel` replaces the rows
        // itself once the new ones arrive.
        // **First hide, then load, then fade in staggered**, as on iPhone.
        .onChange(of: model.accountSwitch) { _, _ in
            AccountSwitchTransition.note("wechsel: startseite blendet aus")
            change = true
            Task {
                await allRefresh()
                if change, released { reveal() }
            }
        }
        .onChange(of: released) { _, now in
            if now, change { reveal() }
        }
        // **Also when coming back to the window.**
        //
        // `.task` covers "view appears", that is tab switches and closing the player.
        // It does not cover the case this rule exists for: finishing an episode on the TV
        // and then picking up the Mac. Otherwise the episode would still be listed in
        // Continue Watching.
        //
        // On iOS the counterpart is `scenePhase`; on the Mac `didBecomeActiveNotification`
        // is more precise, because `scenePhase` also flips when only another window of the
        // same app comes to the front.
        //
        // The 30 second grace period is in `Refresh`, not here.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            guard state.needsRefresh else { return }
            newRefresh()
        }
        // **And when the player closes**, the second half of the rule.
        //
        // `.task` does not cover this: the player is an `.overlay` over the home page,
        // which **stays in the tree**, and `close()` only sets `wish = nil`. The
        // view does not reappear. Without a refresh, someone who finished an episode and
        // closed the player would still see the old tile with the old progress bar in
        // Continue Watching, until a window switch after thirty seconds or an account
        // switch.
        //
        // **Without the grace period**, as on Linux (`Spieler.playerClose`): something
        // has just happened that changes the state.
        //
        // **After the end report, not on close.** On close it is still in flight, and the
        // query would get the state of the last tick. See `AppModel.playbackEnded`.
        .onChange(of: model.pagesRefresh) { _, _ in newRefresh() }
    }

    /// A fixed row: the same layout as before, but retrievable individually so
    /// the order from the settings applies.
    @ViewBuilder
    private func pinned(_ rail: StartRail) -> some View {
        switch rail {
        case .continueWatching:
            if !proceed.isEmpty {
                Rail(title: "Weiterschauen", landscape: true) {
                    ForEach(proceed, id: \.id) { title in
                        // **The line shows the remaining time**, as on iPhone: "S2 · F5 · noch 12 Min."
                        // (season 2, episode 5, 12 min left). The image stays free, and the text sits where
                        // the season/episode label was anyway.
                        LandscapeTile(title: header(title),
                                   secondLine: title.continueWatchingRow ?? title.contextLine,
                                   // **If the landscape image is missing, the poster steps in**: cropped, but still
                                   // the cover and not a still frame. Same as on iPhone.
                                   image: model.landscapeImageURL(for: title)
                                       ?? model.imageURL(for: title, portrait: true),
                                   progress: progress(title),
                                   symbolText: symbolText(title),
                                   pick: { controls.launch(title) },
                                   prefetch: {
                SeriesCache.shared.prefetch(title, with: model)
                PlanPreAdvice.prefetch(title, with: model)
            })
                            // A click starts playback; the detail page is in the menu.
                            .tileMenu(title, model: model, continueWatching: true,
                                         overview: { navigator.openIt(.title(title), in: section) })
                    }
                }
            }
        case .nextEpisode:
            if !next.isEmpty {
                // **Portrait, and the click opens the detail page.**
                //
                // Next Up opens the overview and does not start playback; only Continue Watching
                // jumps straight to playback. The iPhone version states the same rule at the same
                // place. Landscape tiles likewise belong to Continue Watching alone: iOS says so
                // explicitly, tvOS calls the row with `landscape: false`.
                Rail(title: "Nächste Folge") {
                    ForEach(next, id: \.id) { episode in
                        Button { navigator.openIt(.title(episode), in: section) } label: {
                            PosterCell(title: header(episode),
                                         secondLine: episode.episodeCode,
                                         image: model.imageURL(for: episode, portrait: true),
                                         symbolText: symbolText(episode),
                                         prefetch: {
                SeriesCache.shared.prefetch(episode, with: model)
                PlanPreAdvice.prefetch(episode, with: model)
            })
                        }
                        .buttonStyle(Theme.PressButton())
                        .tileMenu(episode, model: model)
                    }
                }
            }
        // **New movies and new series separately**, so they can be reordered
        // independently: someone who wants series on top and movies below can have that.
        // Whether they exist is decided by "Neuzugänge getrennt" (new additions split).
        case .newMovies:
            newAccessRail(title: "Zuletzt hinzugefügte Filme", state.newMovies)
        case .newSeries:
            newAccessRail(title: "Zuletzt hinzugefügte Serien", state.newSeries)
        case .newArrivals:
            newAccessRail(title: "Zuletzt hinzugefügt", new)
        }
    }

    @ViewBuilder
    private func newAccessRail(title: LocalizedStringKey, _ items: [Item]) -> some View {
        if !items.isEmpty {
            Rail(title: title) {
                ForEach(items, id: \.id) { entryRecord in
                    Button { navigator.openIt(.title(entryRecord), in: section) } label: {
                        // **The series name, not the episode name**, as in `Tile` on iPhone.
                        // `Items/Latest` returns episodes, which would otherwise show the episode title.
                        PosterCell(title: entryRecord.seriesName ?? entryRecord.name,
                                     secondLine: entryRecord.newArrivalsRow,
                                     image: model.imageURL(for: entryRecord, portrait: true),
                                     symbolText: symbolText(entryRecord),
                                     prefetch: {
                SeriesCache.shared.prefetch(entryRecord, with: model)
                PlanPreAdvice.prefetch(entryRecord, with: model)
            })
                    }
                    .buttonStyle(Theme.PressButton())
                    .tileMenu(entryRecord, model: model)
                }
            }
        }
    }

    /// Your genres as chips, the same ones that would otherwise appear as rows.
    /// Corner like a button, not round: round is for images.
    private var genreChips: some View {
        // Fixed height, for the same reason as in `Rail`: a horizontal `ScrollView`
        // takes vertically whatever the stack offers it. 4 + 34 + 4.
        PagingRail(widthJePiece: 120, imageHeight: 34) {
            ForEach(model.startGenres, id: \.self) { name in
                Button { navigator.openIt(.genre(name), in: section) } label: {
                    // From the server, so not translated.
                    // Same as on iPhone: 13 medium, `area`, continuous corner, **no border**. 14 is
                    // not on the type scale, and a border would say a second time what the surface
                    // already says.
                    Text(verbatim: name)
                        .font(Theme.tile)
                        .foregroundStyle(Theme.font)
                        // Genre names come from the server. The chip has a fixed height; a wrapping
                        // name would be clipped at top and bottom.
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(Theme.area,
                                    in: RoundedRectangle(cornerRadius: Theme.corner,
                                                         style: .continuous))
                }
                .buttonStyle(Theme.PressButton())
            }
        }
        .frame(height: 42)
    }

    private func header(_ title: Item) -> String {
        title.seriesName ?? title.name
    }

    /// **From `Item.watchedShare`** (`Sources/Shared/TitleDetails.swift`).
    ///
    /// The same calculation used to be repeated here. One difference: the shared
    /// version returns `nil` at zero percent, this one returned `0.0`. Harmless,
    /// because `ImageArea` only draws the bar `if progress > 0`, so neither case
    /// draws one.
    private func progress(_ title: Item) -> Double? { title.watchedShare }

    /// TV for everything belonging to a series, film strip otherwise. Same
    /// distinction as the iPhone version.
    private func symbolText(_ title: Item) -> String { title.tileCharacter }

    private func load() async {
        guard !state.loaded else { return }
        await allRefresh()
    }

    /// Restarts `auffrischen()` and cancels the previous run.
    /// Build the rows once invisibly, then show them staggered, as on iPhone.
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

    private func newRefresh() {
        Task { await allRefresh() }
    }

    /// `auffrischen()` as the only run: the previous one is cancelled, and if this
    /// one is cancelled (`.task(id:)`), the cancellation propagates.
    private func allRefresh() async {
        loadTask?.cancel()
        let task = Task { await refresh() }
        loadTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// Fetches anew without clearing the rows first: the old state stays until the
    /// new one arrives.
    private func refresh() async {
        // Prefetching the series happens in `HomeModel.load`, where the rows
        // are built, so every platform gets it instead of three having to implement it
        // separately. `recent` is included; without that line the normal case fell
        // through, because `newSeries` is only filled when the rows are split.
        await state.load(model)
    }

}

/// A horizontal row with a heading.
struct Rail<ContentBody: View>: View {
    var title: LocalizedStringKey = ""
    /// Instead of `title` when the heading comes from the server; a genre is not
    /// translated.
    var name: String? = nil
    /// When set, a click on the heading opens the page behind it.
    var header: (() -> Void)? = nil
    /// Horizontal tiles, only for "Weiterschauen" (Continue Watching).
    var landscape = false
    @ViewBuilder let content: ContentBody

    /// **The height is fixed, not measured**, the same calculation as `Rail` on
    /// iPhone.
    ///
    /// **This avoids a bug that showed up three ways at once.** A horizontal
    /// `ScrollView` is vertically **flexible**: it takes what it is offered. In a
    /// `VStack` inside a vertical `ScrollView` it gets a *share* of the window height,
    /// which has nothing to do with the tile inside. A `ScrollView` clips its content:
    /// if the share was too small, the tile's second text line was missing and the
    /// descenders of the first were cut off; if it was too large, a gap opened below
    /// the row that had nothing to do with the tile height. This is most visible in
    /// Continue Watching, where the flat landscape tiles are.
    ///
    /// Title line (20 pt, about 24 line height) · 12 spacing · 4 (the vertical margin
    /// of the paging row) · image height · 8 spacing · text block (13 and 12 pt with 1
    /// between, about 32) · 4.
    private var railsHeightValue: CGFloat {
        let image = landscape ? Theme.landscapeHeight : Theme.tileHeight
        return 24 + 12 + 4 + image + 8 + 32 + 4
    }

    var body: some View {
        // 12, not 11: the same role uses 12 on the detail page.
        VStack(alignment: .leading, spacing: 12) {
            // The shared `RailTitle` sets no margin (`edgeSpacing` does not exist on
            // tvOS), so the margin belongs to the caller. The same goes for the width:
            // without it the title slides to the center.
            Group {
                if let header {
                    Button(action: header) { RailTitle(text: title, name: name) }
                        .buttonStyle(Theme.PressButton())
                } else {
                    RailTitle(text: title, name: name)
                }
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.edgeSpacing)
            // **Each row with its own measurements.** Previously the poster row also used
            // the landscape width, so it paged too far, and the arrows sat at the height of a
            // landscape tile.
            PagingRail(widthJePiece: (landscape ? Theme.landscapeWidth : Theme.tileWidth)
                            + Theme.tileSpacing,
                         imageHeight: landscape ? Theme.landscapeHeight : Theme.tileHeight) { content }
        }
        // Top-aligned, so a tile without a subtitle does not hang in the middle.
        .frame(height: railsHeightValue, alignment: .top)
    }
}

